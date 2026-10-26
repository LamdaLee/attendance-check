-- 지역별 QR 출결 시스템 · 초기 스키마
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0001_init.sql
--
-- 원칙
--   * 모든 테이블은 전용 스키마 attendance 에 둔다. Supabase Data API(PostgREST)에 노출하지 않는다.
--   * 앱은 attendance_app 역할로 접속하며, 테이블 권한 없이 아래 함수 실행 권한만 갖는다.
--   * 출결 시각은 DB 서버 시각(now())을 쓰고, 교육일자는 한국시간 기준으로 계산한다.
--   * 원본 출결 이벤트는 수정·삭제하지 않는다.

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists attendance;
revoke all on schema attendance from public;

-- 함수는 기본적으로 PUBLIC 실행 권한이 붙으므로 이 스키마에서는 끈다.
alter default privileges in schema attendance revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- 지역 · 교육장 · 허용 네트워크
-- ---------------------------------------------------------------------------

create table attendance.regions (
  id          smallint generated always as identity primary key,
  code        text not null unique check (code ~ '^[a-z][a-z0-9_]*$'),
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table attendance.campuses (
  id          bigint generated always as identity primary key,
  region_id   smallint not null references attendance.regions (id),
  name        text not null,
  -- QR 주소에 들어가는 공개 식별자. 개인정보나 인증 정보가 아니다.
  qr_code     text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table attendance.allowed_networks (
  id           bigint generated always as identity primary key,
  campus_id    bigint not null references attendance.campuses (id),
  label        text not null check (length(trim(label)) > 0),
  network      cidr not null,
  -- testing: 등록만 하고 학생 출결에는 아직 쓰지 않음 / active: 사용 중 / paused: 중지 / deleted: 삭제 이력
  status       text not null default 'testing' check (status in ('testing', 'active', 'paused', 'deleted')),
  valid_from   timestamptz,
  valid_until  timestamptz,
  version      int not null default 1,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- 모든 주소를 허용하는 넓은 범위는 등록하지 못한다.
  constraint allowed_networks_not_too_wide check (
    (family(network) = 4 and masklen(network) >= 24) or
    (family(network) = 6 and masklen(network) >= 48)
  ),
  constraint allowed_networks_valid_period check (valid_until is null or valid_from is null or valid_until > valid_from)
);

create index allowed_networks_campus_idx on attendance.allowed_networks (campus_id) where status <> 'deleted';

-- ---------------------------------------------------------------------------
-- 과정 · 교육생 · 수강
-- ---------------------------------------------------------------------------

create table attendance.courses (
  id          bigint generated always as identity primary key,
  region_id   smallint not null references attendance.regions (id),
  -- 특정 교육장에서만 출결해야 하는 과정이면 지정한다.
  campus_id   bigint references attendance.campuses (id),
  name        text not null,
  starts_on   date,
  ends_on     date,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (region_id, name)
);

create table attendance.students (
  id          bigint generated always as identity primary key,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table attendance.enrollments (
  id           bigint generated always as identity primary key,
  student_id   bigint not null references attendance.students (id),
  -- 수강 당시의 지역을 남겨, 학생의 이후 이동이 과거 기록의 지역을 바꾸지 않게 한다.
  region_id    smallint not null references attendance.regions (id),
  course_id    bigint not null references attendance.courses (id),
  -- 본인 대조 값. 이름은 공백 제거·NFC 정규화한 값, 뒷자리는 서버 비밀값 HMAC.
  name_key     text not null,
  last4_hmac   text not null,
  status       text not null default 'active' check (status in ('active', 'paused', 'ended')),
  starts_on    date,
  ends_on      date,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index enrollments_match_idx on attendance.enrollments (region_id, name_key, last4_hmac) where status = 'active';
create index enrollments_course_idx on attendance.enrollments (course_id);

-- ---------------------------------------------------------------------------
-- 출결
-- ---------------------------------------------------------------------------

create table attendance.attendance_events (
  id               bigint generated always as identity primary key,
  enrollment_id    bigint not null references attendance.enrollments (id) on delete restrict,
  region_id        smallint not null references attendance.regions (id) on delete restrict,
  campus_id        bigint not null references attendance.campuses (id) on delete restrict,
  action           text not null check (action in ('check_in', 'go_out', 'return', 'check_out')),
  occurred_at      timestamptz not null default now(),
  edu_date         date not null,
  client_ip        inet not null,
  network_id       bigint not null references attendance.allowed_networks (id) on delete restrict,
  network_version  int not null,
  request_id       uuid not null unique,
  session_id       uuid
);

create index attendance_events_day_idx on attendance.attendance_events (region_id, edu_date, enrollment_id);
create index attendance_events_enrollment_idx on attendance.attendance_events (enrollment_id, occurred_at);

-- 원본 이벤트는 수정·삭제 금지
create function attendance.forbid_event_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'attendance_events is append-only';
end $$;

create trigger attendance_events_append_only
  before update or delete on attendance.attendance_events
  for each row execute function attendance.forbid_event_mutation();

-- 학생별 하루 요약. 원본 이벤트(와 이후 승인된 정정)로 다시 만들 수 있는 값이다.
-- 행이 없으면 미입실이다.
create table attendance.attendance_days (
  enrollment_id      bigint not null references attendance.enrollments (id),
  edu_date           date not null,
  region_id          smallint not null references attendance.regions (id),
  status             text not null default 'not_in' check (status in ('not_in', 'in_class', 'out', 'checked_out')),
  first_check_in_at  timestamptz,
  last_check_out_at  timestamptz,
  last_event_at      timestamptz,
  last_action        text,
  version            int not null default 0,
  primary key (enrollment_id, edu_date)
);

create index attendance_days_region_idx on attendance.attendance_days (region_id, edu_date);

-- 정정 (1차는 테이블만 준비. 화면·함수는 다음 단계)
create table attendance.correction_requests (
  id             bigint generated always as identity primary key,
  enrollment_id  bigint not null references attendance.enrollments (id),
  region_id      smallint not null references attendance.regions (id),
  edu_date       date not null,
  reason         text not null,
  status         text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at     timestamptz not null default now(),
  decided_at     timestamptz
);

create table attendance.attendance_corrections (
  id                bigint generated always as identity primary key,
  request_id        bigint references attendance.correction_requests (id),
  enrollment_id     bigint not null references attendance.enrollments (id),
  region_id         smallint not null references attendance.regions (id),
  edu_date          date not null,
  before            jsonb not null,
  after             jsonb not null,
  basis             text not null,
  operator_scope    text not null,
  operator_name     text not null,
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 운영자 접근 · 세션 · 감사 · 시도 제한
-- ---------------------------------------------------------------------------

create table attendance.operator_access (
  id              smallint generated always as identity primary key,
  scope           text not null check (scope in ('region', 'super')),
  region_id       smallint unique references attendance.regions (id),
  password_hash   text not null,
  access_version  int not null default 1,
  updated_at      timestamptz not null default now(),
  check ((scope = 'region') = (region_id is not null))
);

create unique index operator_access_single_super on attendance.operator_access (scope) where scope = 'super';

create table attendance.sessions (
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null check (kind in ('student', 'operator')),
  token_hash          bytea not null unique,
  enrollment_id       bigint references attendance.enrollments (id),
  campus_id           bigint references attendance.campuses (id),
  operator_access_id  smallint references attendance.operator_access (id),
  operator_name       text,
  access_version      int,
  region_id           smallint references attendance.regions (id),
  created_at          timestamptz not null default now(),
  expires_at          timestamptz not null,
  revoked_at          timestamptz,
  check ((kind = 'student') = (enrollment_id is not null and campus_id is not null)),
  check ((kind = 'operator') = (operator_access_id is not null and operator_name is not null))
);

create index sessions_expires_idx on attendance.sessions (expires_at);

create table attendance.audit_logs (
  id            bigint generated always as identity primary key,
  region_id     smallint references attendance.regions (id),
  actor_scope   text not null,
  actor_name    text not null,
  action        text not null,
  target_table  text not null,
  target_id     text,
  before        jsonb,
  after         jsonb,
  reason        text,
  created_at    timestamptz not null default now()
);

create index audit_logs_region_idx on attendance.audit_logs (region_id, created_at desc);

create table attendance.rate_limit_buckets (
  key           text not null,
  window_start  timestamptz not null,
  count         int not null default 0,
  primary key (key, window_start)
);

-- ---------------------------------------------------------------------------
-- 내부 도우미
-- ---------------------------------------------------------------------------

create function attendance.edu_date_now() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Seoul')::date
$$;

-- 10분 창 기준 실패 횟수 집계. p_increment=false 면 조회만 한다.
create function attendance.rate_hit(p_key text, p_increment boolean) returns int
language plpgsql as $$
declare
  v_window timestamptz := date_bin('10 minutes', now(), timestamptz '2000-01-01');
  v_count  int;
begin
  if p_increment then
    insert into attendance.rate_limit_buckets as b (key, window_start, count)
    values (p_key, v_window, 1)
    on conflict (key, window_start) do update set count = b.count + 1;
  end if;
  select coalesce(sum(count), 0) into v_count
    from attendance.rate_limit_buckets
   where key = p_key and window_start >= v_window - interval '10 minutes';
  return v_count;
end $$;

-- 교육장에서 지금 유효한 허용 네트워크를 찾는다. 없으면 null.
create function attendance.match_network(p_campus_id bigint, p_ip inet)
returns attendance.allowed_networks
language sql stable as $$
  select n.*
    from attendance.allowed_networks n
   where n.campus_id = p_campus_id
     and n.status = 'active'
     and n.network >>= p_ip
     and (n.valid_from is null or n.valid_from <= now())
     and (n.valid_until is null or n.valid_until > now())
   order by masklen(n.network) desc
   limit 1
$$;

create function attendance.student_session(p_token_hash bytea)
returns attendance.sessions
language sql stable as $$
  select s.*
    from attendance.sessions s
   where s.token_hash = p_token_hash
     and s.kind = 'student'
     and s.revoked_at is null
     and s.expires_at > now()
$$;

-- 운영자 세션. 비밀번호가 바뀌면(access_version 증가) 기존 세션은 무효.
create function attendance.operator_session(p_token_hash bytea)
returns table (session_id uuid, scope text, region_id smallint, operator_name text)
language sql stable as $$
  select s.id, a.scope, a.region_id, s.operator_name
    from attendance.sessions s
    join attendance.operator_access a on a.id = s.operator_access_id
   where s.token_hash = p_token_hash
     and s.kind = 'operator'
     and s.revoked_at is null
     and s.expires_at > now()
     and s.access_version = a.access_version
$$;

-- 운영자가 볼 수 있는 지역인지 판정하고, 확정된 지역 id 를 돌려준다.
-- 지역 운영자는 요청 값과 관계없이 자기 지역으로 고정된다.
create function attendance.operator_region(p_scope text, p_session_region smallint, p_requested_code text)
returns smallint
language plpgsql stable as $$
declare
  v_id smallint;
begin
  if p_scope = 'region' then
    if p_requested_code is not null and p_requested_code <> '' and not exists (
      select 1 from attendance.regions where id = p_session_region and code = p_requested_code
    ) then
      return null;
    end if;
    return p_session_region;
  end if;
  select id into v_id from attendance.regions where code = p_requested_code;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 앱이 호출하는 함수 (security definer)
-- 모든 함수는 jsonb {ok: boolean, code: text, ...} 를 돌려준다.
-- ---------------------------------------------------------------------------

-- QR 접속 시 교육장 정보와 네트워크 확인 결과
create function attendance.api_campus_info(p_qr_code text, p_ip inet)
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
    'networkOk', (match_network(v_campus.id, p_ip)).id is not null
  );
end $$;

-- 이름 + 뒷자리 대조 후 학생 세션 생성
create function attendance.api_student_verify(
  p_qr_code text, p_name_key text, p_last4_hmac text, p_ip inet, p_token_hash bytea, p_ttl_seconds int
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_campus   record;
  v_rate_key text := 'verify:' || host(p_ip);
  v_matches  bigint[];
  v_enr      record;
  v_session  uuid;
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

  if (match_network(v_campus.id, p_ip)).id is null then
    return jsonb_build_object('ok', false, 'code', 'network_denied');
  end if;

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
    -- 같은 지역에 이름·뒷자리가 같은 활성 교육생이 둘 이상: 자동 선택하지 않는다.
    return jsonb_build_object('ok', false, 'code', 'ambiguous');
  end if;

  insert into sessions (kind, token_hash, enrollment_id, campus_id, region_id, expires_at)
  values ('student', p_token_hash, v_matches[1], v_campus.id, v_campus.region_id,
          now() + make_interval(secs => p_ttl_seconds))
  returning id into v_session;

  select s.name as student_name, co.name as course_name into v_enr
    from enrollments e join students s on s.id = e.student_id join courses co on co.id = e.course_id
   where e.id = v_matches[1];

  return jsonb_build_object('ok', true, 'studentName', v_enr.student_name, 'courseName', v_enr.course_name);
end $$;

-- 본인 오늘 상태와 기록
create function attendance.api_student_today(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_s     sessions;
  v_info  record;
  v_day   attendance_days;
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

  select * into v_day from attendance_days
   where enrollment_id = v_s.enrollment_id and edu_date = edu_date_now();

  return jsonb_build_object(
    'ok', true,
    'studentName', v_info.student_name,
    'courseName', v_info.course_name,
    'campusName', v_info.campus_name,
    'campusCode', v_info.qr_code,
    'regionName', v_info.region_name,
    'eduDate', edu_date_now(),
    'status', coalesce(v_day.status, 'not_in'),
    'sessionExpiresAt', v_s.expires_at,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('action', ev.action, 'at', ev.occurred_at) order by ev.occurred_at)
        from attendance_events ev
       where ev.enrollment_id = v_s.enrollment_id and ev.edu_date = edu_date_now()
    ), '[]'::jsonb)
  );
end $$;

-- 입실 · 외출 · 복귀 · 퇴실
create function attendance.api_student_action(p_token_hash bytea, p_action text, p_request_id uuid, p_ip inet)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s        sessions;
  v_net      allowed_networks;
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

  -- 같은 학생의 같은 날 요청은 이 행 잠금으로 한 줄로 세운다.
  insert into attendance_days (enrollment_id, edu_date, region_id)
  values (v_s.enrollment_id, v_date, v_s.region_id)
  on conflict do nothing;

  select * into v_day from attendance_days
   where enrollment_id = v_s.enrollment_id and edu_date = v_date
   for update;

  -- 재시도: 같은 요청 식별자는 이미 저장된 결과를 그대로 돌려준다.
  select * into v_prev from attendance_events where request_id = p_request_id;
  if found then
    if v_prev.enrollment_id <> v_s.enrollment_id or v_prev.action <> p_action then
      return jsonb_build_object('ok', false, 'code', 'request_conflict');
    end if;
    return jsonb_build_object('ok', true, 'replayed', true, 'action', v_prev.action,
                              'at', v_prev.occurred_at, 'status', v_day.status);
  end if;

  -- 버튼을 누를 때마다 허용 네트워크를 다시 확인한다.
  v_net := match_network(v_s.campus_id, p_ip);
  if v_net.id is null then
    return jsonb_build_object('ok', false, 'code', 'network_denied');
  end if;

  if not exists (
    select 1 from enrollments e join courses co on co.id = e.course_id
     where e.id = v_s.enrollment_id and e.status = 'active' and co.is_active
  ) then
    return jsonb_build_object('ok', false, 'code', 'enrollment_inactive');
  end if;

  v_next := case
    when v_day.status = 'not_in'   and p_action = 'check_in'  then 'in_class'
    when v_day.status = 'in_class' and p_action = 'go_out'    then 'out'
    when v_day.status = 'in_class' and p_action = 'check_out' then 'checked_out'
    when v_day.status = 'out'      and p_action = 'return'    then 'in_class'
  end;
  if v_next is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_transition', 'status', v_day.status);
  end if;

  insert into attendance_events (enrollment_id, region_id, campus_id, action, edu_date, client_ip,
                                 network_id, network_version, request_id, session_id)
  values (v_s.enrollment_id, v_s.region_id, v_s.campus_id, p_action, v_date, p_ip,
          v_net.id, v_net.version, p_request_id, v_s.id)
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
                            'at', v_event.occurred_at, 'status', v_next);
end $$;

-- 세션 종료 (학생·운영자 공통)
create function attendance.api_session_revoke(p_token_hash bytea)
returns jsonb
language sql security definer set search_path = attendance, pg_temp as $$
  update sessions set revoked_at = now() where token_hash = p_token_hash and revoked_at is null;
  select jsonb_build_object('ok', true);
$$;

-- 운영자 입장. p_scope_code 는 지역 코드(daegu 등) 또는 'super'.
create function attendance.api_operator_login(
  p_scope_code text, p_password text, p_operator_name text, p_ip inet, p_token_hash bytea, p_ttl_seconds int
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_rate_key text := 'login:' || host(p_ip);
  v_access   operator_access;
  v_region   regions;
begin
  if rate_hit(v_rate_key, false) >= 10 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  if length(trim(coalesce(p_operator_name, ''))) = 0 then
    return jsonb_build_object('ok', false, 'code', 'name_required');
  end if;

  if p_scope_code = 'super' then
    select * into v_access from operator_access where scope = 'super';
  else
    select a.* into v_access
      from operator_access a join regions r on r.id = a.region_id
     where r.code = p_scope_code and r.is_active;
  end if;

  if v_access.id is null or v_access.password_hash <> extensions.crypt(p_password, v_access.password_hash) then
    perform rate_hit(v_rate_key, true);
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials');
  end if;

  insert into sessions (kind, token_hash, operator_access_id, operator_name, access_version, region_id, expires_at)
  values ('operator', p_token_hash, v_access.id, trim(p_operator_name), v_access.access_version,
          v_access.region_id, now() + make_interval(secs => p_ttl_seconds));

  select * into v_region from regions where id = v_access.region_id;
  return jsonb_build_object('ok', true, 'scope', v_access.scope,
                            'regionCode', v_region.code, 'regionName', v_region.name);
end $$;

-- 운영자 본인 정보와 볼 수 있는 지역 목록
create function attendance.api_operator_me(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op record;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  return jsonb_build_object(
    'ok', true,
    'scope', v_op.scope,
    'operatorName', v_op.operator_name,
    'regions', coalesce((
      select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name) order by r.id)
        from regions r
       where r.is_active and (v_op.scope = 'super' or r.id = v_op.region_id)
    ), '[]'::jsonb)
  );
end $$;

-- 날짜별 현황
create function attendance.api_operator_daily(p_token_hash bytea, p_region_code text, p_date date)
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
               'lastEventAt', d.last_event_at
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

-- 교육장과 허용 네트워크 목록
create function attendance.api_operator_networks(p_token_hash bytea, p_region_code text)
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

  return jsonb_build_object('ok', true, 'campuses', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id,
             'name', c.name,
             'qrCode', c.qr_code,
             'networks', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', n.id, 'label', n.label, 'network', n.network::text, 'status', n.status,
                        'validFrom', n.valid_from, 'validUntil', n.valid_until,
                        'version', n.version, 'updatedAt', n.updated_at
                      ) order by n.status, n.id)
                 from allowed_networks n
                where n.campus_id = c.id and n.status <> 'deleted'
             ), '[]'::jsonb)
           ) order by c.id)
      from campuses c
     where c.region_id = v_region and c.is_active
  ), '[]'::jsonb));
end $$;

-- 허용 네트워크 추가·변경·중지·삭제
--   p_network_id 가 null 이면 추가, 아니면 변경(p_status='deleted' 면 삭제 이력으로 전환)
--   p_expected_version: 화면을 연 뒤 다른 사람이 바꿨으면 저장하지 않는다.
--   p_confirm_last: 마지막 활성 주소를 내리는 경우 화면에서 재확인했는지
create function attendance.api_operator_network_save(
  p_token_hash bytea, p_network_id bigint, p_campus_id bigint, p_label text, p_network cidr,
  p_status text, p_valid_from timestamptz, p_valid_until timestamptz, p_reason text,
  p_expected_version int, p_confirm_last boolean
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op       record;
  v_campus   campuses;
  v_before   allowed_networks;
  v_after    allowed_networks;
  v_overlap  boolean;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if p_status not in ('testing', 'active', 'paused', 'deleted') then
    return jsonb_build_object('ok', false, 'code', 'invalid_status');
  end if;

  if p_network_id is not null then
    select * into v_before from allowed_networks where id = p_network_id for update;
    if not found or v_before.status = 'deleted' then
      return jsonb_build_object('ok', false, 'code', 'not_found');
    end if;
    if p_expected_version is distinct from v_before.version then
      return jsonb_build_object('ok', false, 'code', 'version_conflict');
    end if;
    if length(trim(coalesce(p_reason, ''))) = 0 then
      return jsonb_build_object('ok', false, 'code', 'reason_required');
    end if;
    select * into v_campus from campuses where id = v_before.campus_id;
  else
    if p_status = 'deleted' then
      return jsonb_build_object('ok', false, 'code', 'invalid_status');
    end if;
    select * into v_campus from campuses where id = p_campus_id and is_active;
  end if;

  -- 지역 운영자는 자기 지역 교육장만. 다른 지역 id 를 넣으면 존재 여부도 알려주지 않는다.
  if v_campus.id is null or (v_op.scope = 'region' and v_campus.region_id <> v_op.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  if p_status <> 'deleted' then
    if p_network is null or length(trim(coalesce(p_label, ''))) = 0 then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    if (family(p_network) = 4 and masklen(p_network) < 24) or (family(p_network) = 6 and masklen(p_network) < 48) then
      return jsonb_build_object('ok', false, 'code', 'range_too_wide');
    end if;
    if exists (
      select 1 from allowed_networks n
       where n.campus_id = v_campus.id and n.status <> 'deleted'
         and n.network = p_network and n.id is distinct from p_network_id
    ) then
      return jsonb_build_object('ok', false, 'code', 'duplicate');
    end if;
    -- 다른 지역 주소와 겹치면 총괄 운영자만 사용 중으로 바꿀 수 있다. 겹친 주소 자체는 알려주지 않는다.
    select exists (
      select 1 from allowed_networks n join campuses c on c.id = n.campus_id
       where c.region_id <> v_campus.region_id and n.status in ('testing', 'active')
         and (n.network >>= p_network or n.network <<= p_network)
    ) into v_overlap;
    if v_overlap and p_status = 'active' and v_op.scope <> 'super' then
      return jsonb_build_object('ok', false, 'code', 'overlap_requires_super');
    end if;
  end if;

  -- 마지막 활성 주소를 내리면 그 교육장의 학생 입력이 멈춘다.
  if v_before.id is not null and v_before.status = 'active' and p_status <> 'active'
     and not coalesce(p_confirm_last, false)
     and not exists (
       select 1 from allowed_networks n
        where n.campus_id = v_campus.id and n.status = 'active' and n.id <> v_before.id
     ) then
    return jsonb_build_object('ok', false, 'code', 'last_active_network');
  end if;

  if v_before.id is null then
    insert into allowed_networks (campus_id, label, network, status, valid_from, valid_until)
    values (v_campus.id, trim(p_label), p_network, p_status, p_valid_from, p_valid_until)
    returning * into v_after;
  elsif p_status = 'deleted' then
    update allowed_networks
       set status = 'deleted', version = version + 1, updated_at = now()
     where id = v_before.id
    returning * into v_after;
  else
    update allowed_networks
       set label = trim(p_label), network = p_network, status = p_status,
           valid_from = p_valid_from, valid_until = p_valid_until,
           version = version + 1, updated_at = now()
     where id = v_before.id
    returning * into v_after;
  end if;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after, reason)
  values (v_campus.region_id, v_op.scope, v_op.operator_name,
          case when v_before.id is null then 'network.create'
               when p_status = 'deleted' then 'network.delete'
               else 'network.update' end,
          'allowed_networks', v_after.id::text,
          case when v_before.id is null then null else to_jsonb(v_before) end,
          to_jsonb(v_after), nullif(trim(coalesce(p_reason, '')), ''));

  return jsonb_build_object('ok', true, 'id', v_after.id, 'version', v_after.version, 'overlap', coalesce(v_overlap, false));
end $$;

-- ---------------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'attendance_app') then
    -- 로그인 비밀번호는 배포 환경에서 따로 지정한다: alter role attendance_app login password '...';
    create role attendance_app nologin;
  end if;
end $$;

revoke all on all tables in schema attendance from public;
revoke execute on all functions in schema attendance from public;

do $$
declare
  r text;
begin
  -- Supabase 기본 역할이 있으면 명시적으로 막는다.
  foreach r in array array['anon', 'authenticated', 'service_role', 'attendance_app'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema attendance from %I', r);
      execute format('revoke execute on all functions in schema attendance from %I', r);
    end if;
  end loop;
end $$;

grant usage on schema attendance to attendance_app;
grant execute on function
  attendance.api_campus_info(text, inet),
  attendance.api_student_verify(text, text, text, inet, bytea, int),
  attendance.api_student_today(bytea),
  attendance.api_student_action(bytea, text, uuid, inet),
  attendance.api_session_revoke(bytea),
  attendance.api_operator_login(text, text, text, inet, bytea, int),
  attendance.api_operator_me(bytea),
  attendance.api_operator_daily(bytea, text, date),
  attendance.api_operator_networks(bytea, text),
  attendance.api_operator_network_save(bytea, bigint, bigint, text, cidr, text, timestamptz, timestamptz, text, int, boolean)
to attendance_app;

commit;
