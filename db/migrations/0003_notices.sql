-- 사전 알림(지각·결석·조퇴 예정)과 교육장 밖 본인 확인
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0003_notices.sql
--
--   * 교육장 회선이 아니어도 이름+뒷자리 확인을 허용한다. 이 세션(network_verified=false)으로는
--     사전 알림과 정정 요청만 할 수 있고, 오늘 출결 기록은 보여주지 않는다.
--   * 출결 버튼은 기존대로 누를 때마다 교육장 회선을 확인한다.
--   * 사전 알림은 안내 정보다. 출결 기록을 바꾸지 않는다.

begin;

alter table attendance.sessions add column network_verified boolean not null default true;

create table attendance.notices (
  id             bigint generated always as identity primary key,
  enrollment_id  bigint not null references attendance.enrollments (id),
  region_id      smallint not null references attendance.regions (id),
  edu_date       date not null,
  kind           text not null check (kind in ('late', 'absent', 'early_leave')),
  -- 지각: 도착 예정 시각 / 조퇴: 나갈 예정 시각 (한국시간)
  expected_time  time,
  reason         text not null,
  status         text not null default 'submitted' check (status in ('submitted', 'cancelled')),
  created_at     timestamptz not null default now(),
  cancelled_at   timestamptz,
  session_id     uuid
);

create unique index notices_one_per_kind on attendance.notices (enrollment_id, edu_date, kind) where status = 'submitted';
create index notices_region_date_idx on attendance.notices (region_id, edu_date) where status = 'submitted';

-- ---------------------------------------------------------------------------
-- 학생 본인 확인: 교육장 밖이어도 확인은 하고, 세션에 회선 확인 여부를 남긴다.
-- ---------------------------------------------------------------------------

create or replace function attendance.api_student_verify(
  p_qr_code text, p_name_key text, p_last4_hmac text, p_ip inet, p_token_hash bytea, p_ttl_seconds int
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

  insert into sessions (kind, token_hash, enrollment_id, campus_id, region_id, expires_at, network_verified)
  values ('student', p_token_hash, v_matches[1], v_campus.id, v_campus.region_id,
          now() + make_interval(secs => p_ttl_seconds), v_network_ok);

  select s.name as student_name, co.name as course_name into v_enr
    from enrollments e join students s on s.id = e.student_id join courses co on co.id = e.course_id
   where e.id = v_matches[1];

  return jsonb_build_object('ok', true, 'studentName', v_enr.student_name, 'courseName', v_enr.course_name,
                            'networkVerified', v_network_ok);
end $$;

-- 교육장 밖에서 확인한 세션에는 출결 기록을 보여주지 않는다.
create or replace function attendance.api_student_today(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_s     sessions;
  v_info  record;
  v_day   attendance_days;
  v_base  jsonb;
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

  v_base := jsonb_build_object(
    'ok', true,
    'studentName', v_info.student_name,
    'courseName', v_info.course_name,
    'campusName', v_info.campus_name,
    'campusCode', v_info.qr_code,
    'regionName', v_info.region_name,
    'eduDate', edu_date_now(),
    'sessionExpiresAt', v_s.expires_at,
    'networkVerified', v_s.network_verified
  );
  if not v_s.network_verified then
    return v_base;
  end if;

  select * into v_day from attendance_days
   where enrollment_id = v_s.enrollment_id and edu_date = edu_date_now();

  return v_base || jsonb_build_object(
    'status', coalesce(v_day.status, 'not_in'),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('action', ev.action, 'at', ev.occurred_at) order by ev.occurred_at)
        from attendance_events ev
       where ev.enrollment_id = v_s.enrollment_id and ev.edu_date = edu_date_now()
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- 학생 사전 알림
-- ---------------------------------------------------------------------------

create function attendance.api_student_notice(
  p_token_hash bytea, p_date date, p_kind text, p_expected_time time, p_reason text
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if p_kind not in ('late', 'absent', 'early_leave') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if p_date is null or p_date < edu_date_now() or p_date > edu_date_now() + 14 then
    return jsonb_build_object('ok', false, 'code', 'invalid_notice_date');
  end if;
  if length(trim(coalesce(p_reason, ''))) < 2 or length(p_reason) > 300 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if p_kind = 'absent' and p_expected_time is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  begin
    insert into notices (enrollment_id, region_id, edu_date, kind, expected_time, reason, session_id)
    values (v_s.enrollment_id, v_s.region_id, p_date, p_kind, p_expected_time, trim(p_reason), v_s.id);
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'already_noticed');
  end;
  return jsonb_build_object('ok', true);
end $$;

-- 본인 알림 (어제부터 앞으로)
create function attendance.api_student_notices(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  return jsonb_build_object('ok', true, 'notices', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', n.id, 'date', n.edu_date, 'kind', n.kind, 'expectedTime', to_char(n.expected_time, 'HH24:MI'),
             'reason', n.reason, 'status', n.status, 'createdAt', n.created_at,
             'cancellable', n.status = 'submitted' and n.edu_date >= edu_date_now()
           ) order by n.edu_date desc, n.id desc)
      from notices n
     where n.enrollment_id = v_s.enrollment_id and n.edu_date >= edu_date_now() - 1
  ), '[]'::jsonb));
end $$;

create function attendance.api_student_notice_cancel(p_token_hash bytea, p_notice_id bigint)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  update notices set status = 'cancelled', cancelled_at = now()
   where id = p_notice_id and enrollment_id = v_s.enrollment_id
     and status = 'submitted' and edu_date >= edu_date_now();
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 운영자: 날짜별 현황에 그 날 알림 포함, 알림 목록
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

create function attendance.api_operator_notices(p_token_hash bytea, p_region_code text, p_from date, p_to date)
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
  if not valid_range(p_from, p_to) then
    return jsonb_build_object('ok', false, 'code', 'range_too_long');
  end if;
  return jsonb_build_object('ok', true, 'notices', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', n.id, 'date', n.edu_date, 'enrollmentId', e.id, 'name', st.name, 'course', co.name,
             'kind', n.kind, 'expectedTime', to_char(n.expected_time, 'HH24:MI'), 'reason', n.reason,
             'status', n.status, 'createdAt', n.created_at, 'cancelledAt', n.cancelled_at
           ) order by n.edu_date, co.name, st.name)
      from notices n
      join enrollments e on e.id = n.enrollment_id
      join students st on st.id = e.student_id
      join courses co on co.id = e.course_id
     where n.region_id = v_region and n.edu_date between p_from and p_to
  ), '[]'::jsonb));
end $$;

revoke execute on all functions in schema attendance from public;

grant execute on function
  attendance.api_student_notice(bytea, date, text, time, text),
  attendance.api_student_notices(bytea),
  attendance.api_student_notice_cancel(bytea, bigint),
  attendance.api_operator_notices(bytea, text, date, date)
to attendance_app;

commit;
