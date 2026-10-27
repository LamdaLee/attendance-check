-- 현장 확인 보완: 오늘의 출석코드, 막힌 접속 기록, 같은 기기 여러 명 출결 표시
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0004_presence.sql
--
--   * 오늘의 출석코드: 운영자가 교육장별로 그날만 유효한 6자리 코드를 켠다. 교육장 회선으로
--     확인되지 않는 교육생도 이 코드를 입력하면 그날 출결할 수 있다. 코드로 남긴 기록은 표시된다.
--   * 막힌 접속: 본인 확인이 된 교육생이 허용되지 않은 IP에서 막히면 그 IP를 남긴다.
--     같은 새 IP에서 여러 명이 막히면 교육장 공인 IP가 바뀐 것으로 보고 운영자가 바로 허용한다.
--   * 같은 기기: 브라우저에 남긴 기기 표시(해시)로, 하루에 한 기기에서 여러 명이 출결하면 표시한다.

begin;

-- ---------------------------------------------------------------------------
-- 테이블 변경
-- ---------------------------------------------------------------------------

create table attendance.campus_codes (
  id           bigint generated always as identity primary key,
  campus_id    bigint not null references attendance.campuses (id),
  region_id    smallint not null references attendance.regions (id),
  edu_date     date not null,
  code         text not null check (code ~ '^[0-9]{6}$'),
  status       text not null default 'active' check (status in ('active', 'off')),
  created_by   text not null,
  created_at   timestamptz not null default now(),
  disabled_at  timestamptz
);

create unique index campus_codes_one_active on attendance.campus_codes (campus_id, edu_date) where status = 'active';

alter table attendance.attendance_events
  alter column network_id drop not null,
  alter column network_version drop not null,
  add column method text not null default 'network' check (method in ('network', 'code')),
  add column code_id bigint references attendance.campus_codes (id),
  add column device_hash bytea,
  add constraint attendance_events_method_source check (
    (method = 'network' and network_id is not null and code_id is null) or
    (method = 'code' and network_id is null and code_id is not null)
  );

create index attendance_events_device_idx on attendance.attendance_events (edu_date, device_hash) where device_hash is not null;

alter table attendance.sessions
  add column device_hash bytea,
  add column presence_code_id bigint references attendance.campus_codes (id);

create table attendance.blocked_attempts (
  id             bigint generated always as identity primary key,
  campus_id      bigint not null references attendance.campuses (id),
  region_id      smallint not null references attendance.regions (id),
  ip             inet not null,
  enrollment_id  bigint references attendance.enrollments (id),
  kind           text not null check (kind in ('verify', 'action')),
  created_at     timestamptz not null default now()
);

create index blocked_attempts_campus_idx on attendance.blocked_attempts (campus_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 내부 도우미
-- ---------------------------------------------------------------------------

-- 교육장의 오늘 출석코드 (켜져 있을 때만)
create function attendance.active_code(p_campus_id bigint)
returns attendance.campus_codes
language sql stable as $$
  select c.* from attendance.campus_codes c
   where c.campus_id = p_campus_id and c.edu_date = attendance.edu_date_now() and c.status = 'active'
$$;

-- 세션이 출석코드로 현장 확인을 받았고, 그 코드가 지금도 유효한지
create function attendance.session_code_ok(p_session attendance.sessions)
returns boolean
language sql stable as $$
  select p_session.presence_code_id is not null
     and (attendance.active_code(p_session.campus_id)).id = p_session.presence_code_id
$$;

create function attendance.new_code()
returns text
language sql volatile as $$
  select lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0')
$$;

-- ---------------------------------------------------------------------------
-- 학생
-- ---------------------------------------------------------------------------

create or replace function attendance.api_campus_info(p_qr_code text, p_ip inet)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_campus record;
begin
  select c.id, c.name, r.code as region_code, r.name as region_name
    into v_campus
    from campuses c join regions r on r.id = c.region_id
   where c.qr_code = p_qr_code and c.is_active and r.is_active;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'campus_not_found');
  end if;
  return jsonb_build_object(
    'ok', true,
    'campus', jsonb_build_object('name', v_campus.name, 'regionCode', v_campus.region_code, 'regionName', v_campus.region_name),
    'networkOk', (match_network(v_campus.id, p_ip)).id is not null,
    'codeMode', (active_code(v_campus.id)).id is not null
  );
end $$;

-- 기기 표시 인자를 받도록 바꾼다 (기존 6개 인자 호출도 그대로 동작)
drop function attendance.api_student_verify(text, text, text, inet, bytea, int);

create function attendance.api_student_verify(
  p_qr_code text, p_name_key text, p_last4_hmac text, p_ip inet, p_token_hash bytea, p_ttl_seconds int,
  p_device_hash bytea default null
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_campus     record;
  v_rate_key   text := 'verify:' || host(p_ip);
  v_matches    bigint[];
  v_enr        record;
  v_network_ok boolean;
begin
  if rate_hit(v_rate_key, false) >= 10 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;

  select c.id, c.region_id into v_campus
    from campuses c join regions r on r.id = c.region_id
   where c.qr_code = p_qr_code and c.is_active and r.is_active;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'campus_not_found');
  end if;

  v_network_ok := (match_network(v_campus.id, p_ip)).id is not null;

  select array_agg(e.id) into v_matches
    from enrollments e join courses co on co.id = e.course_id
   where e.region_id = v_campus.region_id
     and e.name_key = p_name_key
     and e.last4_hmac = p_last4_hmac
     and e.status = 'active'
     and co.is_active
     and (co.campus_id is null or co.campus_id = v_campus.id)
     and (e.starts_on is null or e.starts_on <= edu_date_now())
     and (e.ends_on is null or e.ends_on >= edu_date_now());

  if v_matches is null then
    perform rate_hit(v_rate_key, true);
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if array_length(v_matches, 1) > 1 then
    return jsonb_build_object('ok', false, 'code', 'ambiguous');
  end if;

  if not v_network_ok then
    insert into blocked_attempts (campus_id, region_id, ip, enrollment_id, kind)
    values (v_campus.id, v_campus.region_id, p_ip, v_matches[1], 'verify');
  end if;

  insert into sessions (kind, token_hash, enrollment_id, campus_id, region_id, expires_at, network_verified, device_hash)
  values ('student', p_token_hash, v_matches[1], v_campus.id, v_campus.region_id,
          now() + make_interval(secs => p_ttl_seconds), v_network_ok, p_device_hash);

  select s.name as student_name, co.name as course_name into v_enr
    from enrollments e join students s on s.id = e.student_id join courses co on co.id = e.course_id
   where e.id = v_matches[1];

  return jsonb_build_object('ok', true, 'studentName', v_enr.student_name, 'courseName', v_enr.course_name,
                            'networkVerified', v_network_ok,
                            'codeMode', (active_code(v_campus.id)).id is not null);
end $$;

-- 오늘의 출석코드 입력
create function attendance.api_student_code(p_token_hash bytea, p_code text, p_ip inet)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s        sessions;
  v_code     campus_codes;
  v_rate_key text := 'code:' || host(p_ip);
begin
  if rate_hit(v_rate_key, false) >= 10 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_code := active_code(v_s.campus_id);
  if v_code.id is null then
    return jsonb_build_object('ok', false, 'code', 'code_inactive');
  end if;
  if v_code.code <> coalesce(trim(p_code), '') then
    perform rate_hit(v_rate_key, true);
    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;
  update sessions set presence_code_id = v_code.id where id = v_s.id;
  return jsonb_build_object('ok', true);
end $$;

-- 오늘 상태: 교육장 회선 또는 출석코드로 현장 확인된 세션에만 기록을 보여준다.
create or replace function attendance.api_student_today(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_s        sessions;
  v_info     record;
  v_day      attendance_days;
  v_base     jsonb;
  v_presence text;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;

  select st.name as student_name, co.name as course_name, c.name as campus_name, c.qr_code, r.name as region_name
    into v_info
    from enrollments e
    join students st on st.id = e.student_id
    join courses co on co.id = e.course_id
    join campuses c on c.id = v_s.campus_id
    join regions r on r.id = c.region_id
   where e.id = v_s.enrollment_id;

  v_presence := case when v_s.network_verified then 'network' when session_code_ok(v_s) then 'code' end;

  v_base := jsonb_build_object(
    'ok', true,
    'studentName', v_info.student_name,
    'courseName', v_info.course_name,
    'campusName', v_info.campus_name,
    'campusCode', v_info.qr_code,
    'regionName', v_info.region_name,
    'eduDate', edu_date_now(),
    'sessionExpiresAt', v_s.expires_at,
    'networkVerified', v_s.network_verified,
    'presence', v_presence,
    'codeMode', (active_code(v_s.campus_id)).id is not null
  );
  if v_presence is null then
    return v_base;
  end if;

  select * into v_day from attendance_days
   where enrollment_id = v_s.enrollment_id and edu_date = edu_date_now();

  return v_base || jsonb_build_object(
    'status', coalesce(v_day.status, 'not_in'),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('action', ev.action, 'at', ev.occurred_at, 'method', ev.method) order by ev.occurred_at)
        from attendance_events ev
       where ev.enrollment_id = v_s.enrollment_id and ev.edu_date = edu_date_now()
    ), '[]'::jsonb)
  );
end $$;

-- 출결 버튼: 교육장 회선이거나, 오늘의 출석코드로 확인된 세션이어야 한다.
create or replace function attendance.api_student_action(p_token_hash bytea, p_action text, p_request_id uuid, p_ip inet)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s        sessions;
  v_net      allowed_networks;
  v_code_id  bigint;
  v_date     date := edu_date_now();
  v_day      attendance_days;
  v_prev     attendance_events;
  v_next     text;
  v_event    attendance_events;
begin
  if p_action not in ('check_in', 'go_out', 'return', 'check_out') then
    return jsonb_build_object('ok', false, 'code', 'invalid_action');
  end if;

  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;

  insert into attendance_days (enrollment_id, edu_date, region_id)
  values (v_s.enrollment_id, v_date, v_s.region_id)
  on conflict do nothing;

  select * into v_day from attendance_days
   where enrollment_id = v_s.enrollment_id and edu_date = v_date
   for update;

  select * into v_prev from attendance_events where request_id = p_request_id;
  if found then
    if v_prev.enrollment_id <> v_s.enrollment_id or v_prev.action <> p_action then
      return jsonb_build_object('ok', false, 'code', 'request_conflict');
    end if;
    return jsonb_build_object('ok', true, 'replayed', true, 'action', v_prev.action,
                              'at', v_prev.occurred_at, 'status', v_day.status);
  end if;

  v_net := match_network(v_s.campus_id, p_ip);
  if v_net.id is null then
    if session_code_ok(v_s) then
      v_code_id := v_s.presence_code_id;
    else
      insert into blocked_attempts (campus_id, region_id, ip, enrollment_id, kind)
      values (v_s.campus_id, v_s.region_id, p_ip, v_s.enrollment_id, 'action');
      return jsonb_build_object('ok', false, 'code', 'network_denied');
    end if;
  end if;

  if not exists (
    select 1 from enrollments e join courses co on co.id = e.course_id
     where e.id = v_s.enrollment_id and e.status = 'active' and co.is_active
  ) then
    return jsonb_build_object('ok', false, 'code', 'enrollment_inactive');
  end if;

  v_next := next_status(v_day.status, p_action);
  if v_next is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_transition', 'status', v_day.status);
  end if;

  insert into attendance_events (enrollment_id, region_id, campus_id, action, edu_date, client_ip,
                                 network_id, network_version, request_id, session_id,
                                 method, code_id, device_hash)
  values (v_s.enrollment_id, v_s.region_id, v_s.campus_id, p_action, v_date, p_ip,
          v_net.id, v_net.version, p_request_id, v_s.id,
          case when v_net.id is null then 'code' else 'network' end, v_code_id, v_s.device_hash)
  returning * into v_event;

  update attendance_days
     set status = v_next,
         first_check_in_at = coalesce(first_check_in_at, case when p_action = 'check_in' then v_event.occurred_at end),
         last_check_out_at = case when p_action = 'check_out' then v_event.occurred_at else last_check_out_at end,
         last_event_at = v_event.occurred_at,
         last_action = p_action,
         version = version + 1
   where enrollment_id = v_s.enrollment_id and edu_date = v_date;

  return jsonb_build_object('ok', true, 'replayed', false, 'action', p_action,
                            'at', v_event.occurred_at, 'status', v_next, 'method', v_event.method);
end $$;

-- ---------------------------------------------------------------------------
-- 운영자: 출석코드
-- ---------------------------------------------------------------------------

-- 지역의 교육장별 오늘 출석코드와 사용 현황
create function attendance.api_operator_codes(p_token_hash bytea, p_region_code text)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'eduDate', edu_date_now(), 'campuses', coalesce((
    select jsonb_agg(jsonb_build_object(
             'campusId', c.id,
             'code', k.code,
             'createdAt', k.created_at,
             'createdBy', k.created_by,
             'students', (select count(distinct ev.enrollment_id) from attendance_events ev where ev.code_id = k.id)
           ) order by c.id)
      from campuses c
      left join campus_codes k on k.campus_id = c.id and k.edu_date = edu_date_now() and k.status = 'active'
     where c.region_id = v_region and c.is_active
  ), '[]'::jsonb));
end $$;

-- 출석코드 켜기(새 코드)·끄기. p_action: 'on' (켜져 있으면 새 코드로 교체) | 'off'
create function attendance.api_operator_code_set(p_token_hash bytea, p_campus_id bigint, p_action text)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_campus campuses;
  v_old    campus_codes;
  v_new    campus_codes;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if p_action not in ('on', 'off') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select * into v_campus from campuses where id = p_campus_id and is_active;
  if v_campus.id is null or not operator_owns(v_op.scope, v_op.region_id, v_campus.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  select * into v_old from campus_codes
   where campus_id = v_campus.id and edu_date = edu_date_now() and status = 'active'
   for update;
  if v_old.id is not null then
    update campus_codes set status = 'off', disabled_at = now() where id = v_old.id;
  end if;
  if p_action = 'on' then
    insert into campus_codes (campus_id, region_id, edu_date, code, created_by)
    values (v_campus.id, v_campus.region_id, edu_date_now(), new_code(), v_op.operator_name)
    returning * into v_new;
  end if;

  -- 코드 값 자체는 이력에 남기지 않는다.
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_campus.region_id, v_op.scope, v_op.operator_name,
          case when p_action = 'off' then 'code.off' when v_old.id is null then 'code.on' else 'code.renew' end,
          'campus_codes', v_campus.id::text,
          jsonb_build_object('campus', v_campus.name, 'active', v_old.id is not null),
          jsonb_build_object('campus', v_campus.name, 'active', p_action = 'on', 'eduDate', edu_date_now()));

  return jsonb_build_object('ok', true, 'code', v_new.code);
end $$;

-- ---------------------------------------------------------------------------
-- 운영자: 막힌 접속
-- ---------------------------------------------------------------------------

-- 최근 p_minutes 분 동안, 본인 확인된 교육생이 허용되지 않은 IP에서 막힌 기록을 IP별로 묶는다.
-- 이미 허용된 주소는 빼고, 막힌 교육생 수가 많은 순서로 돌려준다.
create function attendance.api_operator_blocked(p_token_hash bytea, p_region_code text, p_minutes int)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op      record;
  v_region  smallint;
  v_minutes int := least(greatest(coalesce(p_minutes, 60), 5), 1440);
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'minutes', v_minutes, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'campusId', g.campus_id, 'campusName', c.name, 'ip', host(g.ip),
             'students', g.students, 'attempts', g.attempts, 'lastAt', g.last_at,
             'names', g.names
           ) order by g.students desc, g.last_at desc)
      from (
        select b.campus_id, b.ip,
               count(distinct b.enrollment_id) as students,
               count(*) as attempts,
               max(b.created_at) as last_at,
               (select jsonb_agg(n.name order by n.name) from (
                  select distinct st.name from blocked_attempts b2
                    join enrollments e on e.id = b2.enrollment_id
                    join students st on st.id = e.student_id
                   where b2.campus_id = b.campus_id and b2.ip = b.ip
                     and b2.created_at > now() - make_interval(mins => v_minutes)
                   limit 8) n) as names
          from blocked_attempts b
         where b.region_id = v_region
           and b.created_at > now() - make_interval(mins => v_minutes)
           and (match_network(b.campus_id, b.ip)).id is null
         group by b.campus_id, b.ip
      ) g
      join campuses c on c.id = g.campus_id
  ), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 운영자: 날짜별 현황에 코드 출결·같은 기기 표시 추가
-- ---------------------------------------------------------------------------

create or replace function attendance.api_operator_daily(p_token_hash bytea, p_region_code text, p_date date)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;

  return jsonb_build_object(
    'ok', true,
    'date', p_date,
    'regionCode', (select code from regions where id = v_region),
    'generatedAt', now(),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'enrollmentId', e.id,
               'name', st.name,
               'course', co.name,
               'status', coalesce(d.status, 'not_in'),
               'firstCheckInAt', d.first_check_in_at,
               'lastCheckOutAt', d.last_check_out_at,
               'lastAction', d.last_action,
               'lastEventAt', d.last_event_at,
               'corrected', coalesce(d.corrected, false),
               'notices', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'kind', n.kind, 'expectedTime', to_char(n.expected_time, 'HH24:MI'), 'reason', n.reason
                        ) order by n.id)
                   from notices n
                  where n.enrollment_id = e.id and n.edu_date = p_date and n.status = 'submitted'
               ), '[]'::jsonb),
               'viaCode', exists (
                 select 1 from attendance_events ev
                  where ev.enrollment_id = e.id and ev.edu_date = p_date and ev.method = 'code'),
               -- 같은 날 같은 기기에서 출결한 다른 교육생 이름
               'sharedDevice', coalesce((
                 select jsonb_agg(distinct st2.name)
                   from attendance_events ev
                   join attendance_events ev2
                     on ev2.edu_date = ev.edu_date and ev2.device_hash = ev.device_hash
                    and ev2.enrollment_id <> ev.enrollment_id
                   join enrollments e2 on e2.id = ev2.enrollment_id
                   join students st2 on st2.id = e2.student_id
                  where ev.enrollment_id = e.id and ev.edu_date = p_date and ev.device_hash is not null
               ), '[]'::jsonb)
             ) order by co.name, st.name)
        from enrollments e
        join students st on st.id = e.student_id
        join courses co on co.id = e.course_id
        left join attendance_days d on d.enrollment_id = e.id and d.edu_date = p_date
       where e.region_id = v_region
         and (e.status = 'active' or d.last_event_at is not null)
         and (e.starts_on is null or e.starts_on <= p_date)
         and (e.ends_on is null or e.ends_on >= p_date)
    ), '[]'::jsonb)
  );
end $$;

-- 하루 상세의 원본 기록에 기록 방법(교육장 회선·출석코드) 표시
create or replace function attendance.api_operator_day(p_token_hash bytea, p_enrollment_id bigint, p_date date)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op record;
  v_e  enrollments;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_e := operator_enrollment(v_op.scope, v_op.region_id, p_enrollment_id);
  if v_e.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'enrollmentId', v_e.id,
    'name', (select name from students where id = v_e.student_id),
    'course', (select name from courses where id = v_e.course_id),
    'date', p_date,
    'version', coalesce((select version from attendance_days where enrollment_id = v_e.id and edu_date = p_date), 0),
    'original', coalesce((
      select jsonb_agg(jsonb_build_object('action', ev.action, 'at', ev.occurred_at, 'method', ev.method) order by ev.occurred_at)
        from attendance_events ev
       where ev.enrollment_id = v_e.id and ev.edu_date = p_date
    ), '[]'::jsonb),
    'timeline', effective_timeline(v_e.id, p_date),
    'corrections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'createdAt', c.created_at, 'operatorName', c.operator_name, 'operatorScope', c.operator_scope,
               'basis', c.basis, 'before', c.before, 'after', c.after, 'requestId', c.request_id
             ) order by c.id desc)
        from attendance_corrections c
       where c.enrollment_id = v_e.id and c.edu_date = p_date
    ), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', q.id, 'reason', q.reason, 'status', q.status, 'createdAt', q.created_at,
               'decidedAt', q.decided_at, 'decidedBy', q.decided_by, 'note', q.decision_note
             ) order by q.id desc)
        from correction_requests q
       where q.enrollment_id = v_e.id and q.edu_date = p_date
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------------

revoke execute on all functions in schema attendance from public;

grant execute on function
  attendance.api_student_verify(text, text, text, inet, bytea, int, bytea),
  attendance.api_student_code(bytea, text, inet),
  attendance.api_operator_codes(bytea, text),
  attendance.api_operator_code_set(bytea, bigint, text),
  attendance.api_operator_blocked(bytea, text, int)
to attendance_app;

commit;
