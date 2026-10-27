-- 운영 화면 확장: 학생별 기록, 정정 요청·처리, 명단 관리, 누락 확인, 변경 이력, 내보내기, 총괄 현황
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0002_screens.sql
--
-- 정정 원칙
--   * 원본 이벤트(attendance_events)는 그대로 둔다.
--   * 승인된 정정은 그 날의 "정정 후 타임라인" 전체를 attendance_corrections.after 에 저장한다.
--   * 화면에 쓰는 타임라인 = 가장 최근 정정의 after + 그 정정 이후에 들어온 원본 이벤트.
--   * 검토 화면을 연 뒤 기록이나 정정이 바뀌었으면(attendance_days.version) 저장하지 않는다.

begin;

alter table attendance.attendance_days add column corrected boolean not null default false;

alter table attendance.correction_requests
  add column decided_by text,
  add column decision_note text,
  add column session_id uuid;

-- 같은 날짜에 처리 대기 중인 요청은 하나만
create unique index correction_requests_one_pending
  on attendance.correction_requests (enrollment_id, edu_date) where status = 'pending';
create index correction_requests_region_idx
  on attendance.correction_requests (region_id, status, created_at desc);

alter table attendance.attendance_corrections add column day_version int;
create index attendance_corrections_day_idx
  on attendance.attendance_corrections (enrollment_id, edu_date, id desc);

-- ---------------------------------------------------------------------------
-- 내부 도우미
-- ---------------------------------------------------------------------------

create function attendance.operator_owns(p_scope text, p_session_region smallint, p_region smallint)
returns boolean
language sql immutable as $$
  select p_scope = 'super' or p_session_region = p_region
$$;

create function attendance.next_status(p_status text, p_action text)
returns text
language sql immutable as $$
  select case
    when p_status = 'not_in'   and p_action = 'check_in'  then 'in_class'
    when p_status = 'in_class' and p_action = 'go_out'    then 'out'
    when p_status = 'in_class' and p_action = 'check_out' then 'checked_out'
    when p_status = 'out'      and p_action = 'return'    then 'in_class'
  end
$$;

-- 화면에 쓰는 하루 타임라인 [{action, at, source}]
create function attendance.effective_timeline(p_enrollment_id bigint, p_date date)
returns jsonb
language sql stable as $$
  with c as (
    select after, created_at
      from attendance.attendance_corrections
     where enrollment_id = p_enrollment_id and edu_date = p_date
     order by id desc
     limit 1
  )
  select coalesce((select after from c), '[]'::jsonb) || coalesce((
    select jsonb_agg(jsonb_build_object('action', e.action, 'at', e.occurred_at, 'source', 'original')
                     order by e.occurred_at)
      from attendance.attendance_events e
     where e.enrollment_id = p_enrollment_id
       and e.edu_date = p_date
       and e.occurred_at > coalesce((select created_at from c), '-infinity'::timestamptz)
  ), '[]'::jsonb)
$$;

-- 타임라인 검증과 요약. 시각은 해당 교육일(한국시간) 안이고 증가해야 하며, 상태 순서를 지켜야 한다.
create function attendance.eval_timeline(p_date date, p_items jsonb)
returns jsonb
language plpgsql stable as $$
declare
  v_item     jsonb;
  v_at       timestamptz;
  v_prev     timestamptz;
  v_status   text := 'not_in';
  v_next     text;
  v_first    timestamptz;
  v_last_out timestamptz;
  v_action   text;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    begin
      v_at := (v_item->>'at')::timestamptz;
    exception when others then
      return jsonb_build_object('ok', false, 'code', 'timeline_time');
    end;
    if v_at is null or (v_at at time zone 'Asia/Seoul')::date <> p_date or v_at > now()
       or (v_prev is not null and v_at <= v_prev) then
      return jsonb_build_object('ok', false, 'code', 'timeline_time');
    end if;
    v_action := v_item->>'action';
    v_next := attendance.next_status(v_status, v_action);
    if v_next is null then
      return jsonb_build_object('ok', false, 'code', 'timeline_order');
    end if;
    if v_action = 'check_in' then v_first := coalesce(v_first, v_at); end if;
    if v_action = 'check_out' then v_last_out := v_at; end if;
    v_status := v_next;
    v_prev := v_at;
  end loop;
  return jsonb_build_object(
    'ok', true, 'status', v_status, 'firstIn', v_first, 'lastOut', v_last_out,
    'lastAction', v_action, 'lastAt', v_prev
  );
end $$;

-- 운영자 세션을 확인하고, 수강 정보가 운영자 범위 안인지 확인한다. 범위 밖이면 null.
create function attendance.operator_enrollment(p_scope text, p_session_region smallint, p_enrollment_id bigint)
returns attendance.enrollments
language sql stable as $$
  select e.* from attendance.enrollments e
   where e.id = p_enrollment_id
     and attendance.operator_owns(p_scope, p_session_region, e.region_id)
$$;

-- 날짜 범위 확인 (최대 31일)
create function attendance.valid_range(p_from date, p_to date)
returns boolean
language sql immutable as $$
  select p_from is not null and p_to is not null and p_from <= p_to and p_to - p_from <= 30
$$;

-- ---------------------------------------------------------------------------
-- 날짜별 현황 (정정 여부 추가)
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
               'corrected', coalesce(d.corrected, false)
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

-- ---------------------------------------------------------------------------
-- 학생별 기록
-- ---------------------------------------------------------------------------

-- 월별 요약. p_month 는 그 달의 아무 날짜.
create function attendance.api_operator_student(p_token_hash bytea, p_enrollment_id bigint, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op    record;
  v_e     enrollments;
  v_from  date := date_trunc('month', p_month)::date;
  v_to    date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
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
    'student', (
      select jsonb_build_object(
               'enrollmentId', v_e.id, 'name', st.name, 'course', co.name, 'status', v_e.status,
               'regionName', r.name, 'startsOn', v_e.starts_on, 'endsOn', v_e.ends_on, 'createdAt', v_e.created_at)
        from students st, courses co, regions r
       where st.id = v_e.student_id and co.id = v_e.course_id and r.id = v_e.region_id
    ),
    'month', to_char(v_from, 'YYYY-MM'),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
               'date', d.edu_date, 'status', d.status, 'firstCheckInAt', d.first_check_in_at,
               'lastCheckOutAt', d.last_check_out_at, 'lastAction', d.last_action, 'corrected', d.corrected
             ) order by d.edu_date desc)
        from attendance_days d
       where d.enrollment_id = v_e.id and d.edu_date between v_from and v_to
         and (d.last_event_at is not null or d.corrected)
    ), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object('id', q.id, 'date', q.edu_date, 'status', q.status) order by q.edu_date desc)
        from correction_requests q
       where q.enrollment_id = v_e.id and q.edu_date between v_from and v_to
    ), '[]'::jsonb)
  );
end $$;

-- 하루 상세: 원본, 화면 반영 타임라인, 정정 이력, 정정 요청
create function attendance.api_operator_day(p_token_hash bytea, p_enrollment_id bigint, p_date date)
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
      select jsonb_agg(jsonb_build_object('action', ev.action, 'at', ev.occurred_at) order by ev.occurred_at)
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
-- 정정
-- ---------------------------------------------------------------------------

-- 학생 정정 요청
create function attendance.api_student_correction_request(p_token_hash bytea, p_date date, p_reason text)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if p_date is null or p_date > edu_date_now() or p_date < edu_date_now() - 30 then
    return jsonb_build_object('ok', false, 'code', 'invalid_date');
  end if;
  if length(trim(coalesce(p_reason, ''))) < 2 or length(p_reason) > 500 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  begin
    insert into correction_requests (enrollment_id, region_id, edu_date, reason, session_id)
    values (v_s.enrollment_id, v_s.region_id, p_date, trim(p_reason), v_s.id);
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'already_pending');
  end;
  return jsonb_build_object('ok', true);
end $$;

-- 학생 본인 정정 요청과 결과 (최근 90일)
create function attendance.api_student_corrections(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  return jsonb_build_object('ok', true, 'requests', coalesce((
    select jsonb_agg(jsonb_build_object(
             'date', q.edu_date, 'reason', q.reason, 'status', q.status,
             'createdAt', q.created_at, 'note', q.decision_note
           ) order by q.id desc)
      from correction_requests q
     where q.enrollment_id = v_s.enrollment_id and q.created_at > now() - interval '90 days'
  ), '[]'::jsonb));
end $$;

-- 정정 요청 목록
create function attendance.api_operator_corrections(p_token_hash bytea, p_region_code text, p_status text)
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
  return jsonb_build_object('ok', true, 'requests', coalesce((
    select jsonb_agg(x.obj order by x.created_at desc)
      from (
        select q.created_at, jsonb_build_object(
                 'id', q.id, 'enrollmentId', q.enrollment_id, 'name', st.name, 'course', co.name,
                 'date', q.edu_date, 'reason', q.reason, 'status', q.status, 'createdAt', q.created_at,
                 'decidedAt', q.decided_at, 'decidedBy', q.decided_by, 'note', q.decision_note
               ) as obj
          from correction_requests q
          join enrollments e on e.id = q.enrollment_id
          join students st on st.id = e.student_id
          join courses co on co.id = e.course_id
         where q.region_id = v_region
           and (p_status is null or p_status = '' or q.status = p_status)
         order by q.created_at desc
         limit 200
      ) x
  ), '[]'::jsonb));
end $$;

-- 정정 저장 (요청 승인 또는 운영자 직권 정정)
--   p_timeline: [{action, at}] 정정 후 하루 전체 타임라인
--   p_expected_version: 검토 화면을 열 때 받은 version
create function attendance.api_operator_correction_save(
  p_token_hash bytea, p_enrollment_id bigint, p_date date, p_timeline jsonb, p_basis text,
  p_request_id bigint, p_expected_version int
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op      record;
  v_e       enrollments;
  v_req     correction_requests;
  v_day     attendance_days;
  v_before  jsonb;
  v_after   jsonb;
  v_eval    jsonb;
  v_corr_id bigint;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_e := operator_enrollment(v_op.scope, v_op.region_id, p_enrollment_id);
  if v_e.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if length(trim(coalesce(p_basis, ''))) = 0 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if p_date is null or p_date > edu_date_now() then
    return jsonb_build_object('ok', false, 'code', 'invalid_date');
  end if;

  if p_request_id is not null then
    select * into v_req from correction_requests where id = p_request_id for update;
    if not found or v_req.enrollment_id <> v_e.id or v_req.edu_date <> p_date then
      return jsonb_build_object('ok', false, 'code', 'not_found');
    end if;
    if v_req.status <> 'pending' then
      return jsonb_build_object('ok', false, 'code', 'already_decided');
    end if;
  end if;

  insert into attendance_days (enrollment_id, edu_date, region_id)
  values (v_e.id, p_date, v_e.region_id)
  on conflict do nothing;
  select * into v_day from attendance_days where enrollment_id = v_e.id and edu_date = p_date for update;
  if p_expected_version is distinct from v_day.version then
    return jsonb_build_object('ok', false, 'code', 'version_conflict');
  end if;

  v_eval := eval_timeline(p_date, p_timeline);
  if not (v_eval->>'ok')::boolean then
    return v_eval;
  end if;

  v_before := effective_timeline(v_e.id, p_date);
  select coalesce(jsonb_agg(jsonb_build_object(
           'action', i->>'action',
           'at', (i->>'at')::timestamptz,
           'source', case when exists (
             select 1 from attendance_events ev
              where ev.enrollment_id = v_e.id and ev.edu_date = p_date
                and ev.action = i->>'action' and ev.occurred_at = (i->>'at')::timestamptz
           ) then 'original' else 'corrected' end
         ) order by ord), '[]'::jsonb)
    into v_after
    from jsonb_array_elements(p_timeline) with ordinality t(i, ord);

  if v_after = v_before then
    return jsonb_build_object('ok', false, 'code', 'no_change');
  end if;

  insert into attendance_corrections (request_id, enrollment_id, region_id, edu_date, before, after, basis,
                                      operator_scope, operator_name, day_version)
  values (p_request_id, v_e.id, v_e.region_id, p_date, v_before, v_after, trim(p_basis),
          v_op.scope, v_op.operator_name, v_day.version + 1)
  returning id into v_corr_id;

  update attendance_days
     set status = v_eval->>'status',
         first_check_in_at = (v_eval->>'firstIn')::timestamptz,
         last_check_out_at = (v_eval->>'lastOut')::timestamptz,
         last_action = v_eval->>'lastAction',
         last_event_at = (v_eval->>'lastAt')::timestamptz,
         corrected = true,
         version = version + 1
   where enrollment_id = v_e.id and edu_date = p_date;

  if p_request_id is not null then
    update correction_requests
       set status = 'approved', decided_at = now(), decided_by = v_op.operator_name, decision_note = trim(p_basis)
     where id = p_request_id;
  end if;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after, reason)
  values (v_e.region_id, v_op.scope, v_op.operator_name,
          case when p_request_id is null then 'correction.direct' else 'correction.approve' end,
          'attendance_corrections', v_corr_id::text,
          jsonb_build_object('enrollmentId', v_e.id, 'date', p_date, 'timeline', v_before),
          jsonb_build_object('enrollmentId', v_e.id, 'date', p_date, 'timeline', v_after),
          trim(p_basis));

  return jsonb_build_object('ok', true, 'correctionId', v_corr_id, 'version', v_day.version + 1);
end $$;

-- 정정 요청 반려
create function attendance.api_operator_correction_reject(p_token_hash bytea, p_request_id bigint, p_note text)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op  record;
  v_req correction_requests;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if length(trim(coalesce(p_note, ''))) = 0 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  select * into v_req from correction_requests where id = p_request_id for update;
  if not found or not operator_owns(v_op.scope, v_op.region_id, v_req.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_req.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'already_decided');
  end if;
  update correction_requests
     set status = 'rejected', decided_at = now(), decided_by = v_op.operator_name, decision_note = trim(p_note)
   where id = p_request_id;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after, reason)
  values (v_req.region_id, v_op.scope, v_op.operator_name, 'correction.reject', 'correction_requests',
          v_req.id::text, jsonb_build_object('status', 'pending'), jsonb_build_object('status', 'rejected'), trim(p_note));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 명단 관리
-- ---------------------------------------------------------------------------

create function attendance.api_operator_courses(p_token_hash bytea, p_region_code text)
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
  return jsonb_build_object('ok', true, 'courses', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'isActive', is_active) order by name)
      from courses where region_id = v_region
  ), '[]'::jsonb));
end $$;

-- 명단. 본인 대조 값(HMAC)은 돌려주지 않고, 같은 지역 활성 수강생과의 중복 여부만 알려준다.
create function attendance.api_operator_roster(p_token_hash bytea, p_region_code text)
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
  return jsonb_build_object('ok', true, 'students', coalesce((
    select jsonb_agg(jsonb_build_object(
             'enrollmentId', e.id, 'name', st.name, 'course', co.name, 'courseId', co.id, 'status', e.status,
             'startsOn', e.starts_on, 'endsOn', e.ends_on, 'createdAt', e.created_at, 'updatedAt', e.updated_at,
             'conflict', e.status = 'active' and exists (
               select 1 from enrollments o
                where o.region_id = e.region_id and o.id <> e.id and o.status = 'active'
                  and o.name_key = e.name_key and o.last4_hmac = e.last4_hmac),
             'lastAttendance', (select max(d.edu_date) from attendance_days d
                                 where d.enrollment_id = e.id and d.last_event_at is not null)
           ) order by co.name, st.name)
      from enrollments e
      join students st on st.id = e.student_id
      join courses co on co.id = e.course_id
     where e.region_id = v_region
  ), '[]'::jsonb));
end $$;

-- 명단 등록 (한 명 또는 여러 명)
--   p_rows: [{line, name, nameKey, hmac, course}] — 이름 정규화와 HMAC 계산은 앱이 한다.
--   p_apply=false 면 검증 결과만 돌려준다. 오류가 하나라도 있으면 저장하지 않는다.
create function attendance.api_operator_enroll(p_token_hash bytea, p_region_code text, p_rows jsonb, p_apply boolean)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_seen   jsonb := '{}'::jsonb;
  v_out    jsonb := '[]'::jsonb;
  v_errors int := 0;
  v_course bigint;
  v_key    text;
  v_err    text;
  v_sid    bigint;
  r        jsonb;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0
     or jsonb_array_length(p_rows) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_err := null;
    select id into v_course from courses where region_id = v_region and name = r->>'course' and is_active;
    if v_course is null then
      v_err := 'course_not_found';
    elsif length(coalesce(r->>'nameKey', '')) = 0 or length(coalesce(r->>'hmac', '')) <> 64 then
      v_err := 'invalid_input';
    else
      v_key := (r->>'nameKey') || ':' || (r->>'hmac');
      if v_seen ? v_key then
        v_err := 'duplicate_in_file:' || (v_seen->>v_key);
      elsif exists (select 1 from enrollments
                     where region_id = v_region and status = 'active'
                       and name_key = r->>'nameKey' and last4_hmac = r->>'hmac') then
        v_err := 'duplicate_match';
      end if;
      v_seen := v_seen || jsonb_build_object(v_key, r->>'line');
    end if;
    if v_err is not null then v_errors := v_errors + 1; end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'line', r->'line', 'name', r->>'name', 'course', r->>'course', 'error', v_err));
  end loop;

  if p_apply and v_errors = 0 then
    for r in select value from jsonb_array_elements(p_rows) loop
      insert into students (name) values (trim(r->>'name')) returning id into v_sid;
      insert into enrollments (student_id, region_id, course_id, name_key, last4_hmac)
      select v_sid, v_region, id, r->>'nameKey', r->>'hmac'
        from courses where region_id = v_region and name = r->>'course';
    end loop;
    insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, after)
    values (v_region, v_op.scope, v_op.operator_name, 'students.import', 'enrollments',
            jsonb_build_object('count', jsonb_array_length(p_rows),
                               'names', (select jsonb_agg(value->>'name') from jsonb_array_elements(p_rows))));
  end if;

  return jsonb_build_object('ok', v_errors = 0, 'code', case when v_errors > 0 then 'roster_errors' end,
                            'applied', p_apply and v_errors = 0, 'total', jsonb_array_length(p_rows),
                            'errors', v_errors, 'rows', v_out);
end $$;

-- 수강 상태 변경, 과정 변경, 뒷자리 재등록
create function attendance.api_operator_enrollment_update(
  p_token_hash bytea, p_enrollment_id bigint, p_status text, p_course_id bigint, p_last4_hmac text, p_reason text
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_e      enrollments;
  v_after  enrollments;
  v_hmac   text;
  v_course bigint;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_e := operator_enrollment(v_op.scope, v_op.region_id, p_enrollment_id);
  if v_e.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v_e from enrollments where id = v_e.id for update;
  if p_status not in ('active', 'paused', 'ended') then
    return jsonb_build_object('ok', false, 'code', 'invalid_status');
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if p_last4_hmac is not null and length(p_last4_hmac) <> 64 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  v_course := coalesce(p_course_id, v_e.course_id);
  if not exists (select 1 from courses where id = v_course and region_id = v_e.region_id) then
    return jsonb_build_object('ok', false, 'code', 'course_not_found');
  end if;

  v_hmac := coalesce(p_last4_hmac, v_e.last4_hmac);
  if p_status = 'active' and exists (
    select 1 from enrollments o
     where o.region_id = v_e.region_id and o.id <> v_e.id and o.status = 'active'
       and o.name_key = v_e.name_key and o.last4_hmac = v_hmac
  ) then
    return jsonb_build_object('ok', false, 'code', 'duplicate_match');
  end if;

  update enrollments
     set status = p_status, course_id = v_course, last4_hmac = v_hmac, updated_at = now()
   where id = v_e.id
  returning * into v_after;

  -- 중지·종료되면 남아 있는 학생 세션을 끊는다.
  if p_status <> 'active' then
    update sessions set revoked_at = now()
     where kind = 'student' and enrollment_id = v_e.id and revoked_at is null;
  end if;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after, reason)
  values (v_e.region_id, v_op.scope, v_op.operator_name, 'enrollment.update', 'enrollments', v_e.id::text,
          to_jsonb(v_e) - 'name_key' - 'last4_hmac',
          (to_jsonb(v_after) - 'name_key' - 'last4_hmac')
            || jsonb_build_object('last4Changed', p_last4_hmac is not null and p_last4_hmac <> v_e.last4_hmac),
          trim(p_reason));

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 누락 확인
--   no_checkout: 지난 날짜에 교육 중으로 끝남 (퇴실 없음)
--   no_return:   지난 날짜에 외출 중으로 끝남 (복귀 없음)
--   no_record:   같은 과정의 다른 교육생은 기록이 있는 날인데 기록이 없음
-- 결석으로 단정하지 않는다.
-- ---------------------------------------------------------------------------

create function attendance.api_operator_issues(p_token_hash bytea, p_region_code text, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_to     date;
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
  v_to := least(p_to, edu_date_now() - 1);

  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'date', x.edu_date, 'enrollmentId', x.enrollment_id, 'name', st.name, 'course', co.name,
             'kind', x.kind, 'lastAction', x.last_action, 'lastEventAt', x.last_event_at,
             'requestStatus', (select q.status from correction_requests q
                                where q.enrollment_id = x.enrollment_id and q.edu_date = x.edu_date
                                order by q.id desc limit 1)
           ) order by x.edu_date desc, co.name, st.name)
      from (
        select d.edu_date, d.enrollment_id,
               case d.status when 'in_class' then 'no_checkout' else 'no_return' end as kind,
               d.last_action, d.last_event_at
          from attendance_days d
         where d.region_id = v_region and d.edu_date between p_from and v_to
           and d.status in ('in_class', 'out')
        union all
        select cd.edu_date, e.id, 'no_record', null, null
          from (
            select distinct e2.course_id, d2.edu_date
              from attendance_days d2 join enrollments e2 on e2.id = d2.enrollment_id
             where d2.region_id = v_region and d2.edu_date between p_from and v_to
               and d2.last_event_at is not null
          ) cd
          join enrollments e on e.course_id = cd.course_id and e.region_id = v_region and e.status = 'active'
         where (e.starts_on is null or e.starts_on <= cd.edu_date)
           and (e.ends_on is null or e.ends_on >= cd.edu_date)
           and e.created_at::date <= cd.edu_date
           and not exists (
             select 1 from attendance_days d3
              where d3.enrollment_id = e.id and d3.edu_date = cd.edu_date and d3.last_event_at is not null)
      ) x
      join enrollments e on e.id = x.enrollment_id
      join students st on st.id = e.student_id
      join courses co on co.id = e.course_id
  ), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 변경 이력
-- ---------------------------------------------------------------------------

create function attendance.api_operator_audit(p_token_hash bytea, p_region_code text, p_before_id bigint, p_limit int)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_limit  int := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  -- 총괄은 지역을 비우면 전체를 본다.
  if v_op.scope = 'super' and (p_region_code is null or p_region_code = '') then
    v_region := null;
  else
    v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
    if v_region is null then
      return jsonb_build_object('ok', false, 'code', 'forbidden');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'createdAt', a.created_at, 'regionName', r.name, 'actorScope', a.actor_scope,
             'actorName', a.actor_name, 'action', a.action, 'targetTable', a.target_table,
             'targetId', a.target_id, 'reason', a.reason, 'before', a.before, 'after', a.after
           ) order by a.id desc)
      from (
        select * from audit_logs
         where (v_region is null or region_id = v_region)
           and (p_before_id is null or id < p_before_id)
         order by id desc
         limit v_limit
      ) a
      left join regions r on r.id = a.region_id
  ), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- CSV 내보내기용 기간 자료 (내보낸 사실을 이력에 남긴다)
-- ---------------------------------------------------------------------------

create function attendance.api_operator_export(p_token_hash bytea, p_region_code text, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_rows   jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d.edu_date, 'name', st.name, 'course', co.name, 'status', d.status,
           'firstCheckInAt', d.first_check_in_at, 'lastCheckOutAt', d.last_check_out_at,
           'corrected', d.corrected,
           'timeline', effective_timeline(d.enrollment_id, d.edu_date)
         ) order by d.edu_date, co.name, st.name), '[]'::jsonb)
    into v_rows
    from attendance_days d
    join enrollments e on e.id = d.enrollment_id
    join students st on st.id = e.student_id
    join courses co on co.id = e.course_id
   where d.region_id = v_region and d.edu_date between p_from and p_to
     and (d.last_event_at is not null or d.corrected);

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, after)
  values (v_region, v_op.scope, v_op.operator_name, 'export.csv', 'attendance_days',
          jsonb_build_object('from', p_from, 'to', p_to, 'rows', jsonb_array_length(v_rows)));

  return jsonb_build_object('ok', true, 'regionName', (select name from regions where id = v_region),
                            'generatedAt', now(), 'rows', v_rows);
end $$;

-- ---------------------------------------------------------------------------
-- 총괄 현황
-- ---------------------------------------------------------------------------

create function attendance.api_operator_overview(p_token_hash bytea, p_date date)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op record;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if v_op.scope <> 'super' then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'date', p_date, 'generatedAt', now(), 'regions', coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', r.code, 'name', r.name,
             'counts', (
               select jsonb_build_object(
                        'total', count(*),
                        'in_class', count(*) filter (where coalesce(d.status, 'not_in') = 'in_class'),
                        'out', count(*) filter (where d.status = 'out'),
                        'checked_out', count(*) filter (where d.status = 'checked_out'),
                        'not_in', count(*) filter (where coalesce(d.status, 'not_in') = 'not_in'))
                 from enrollments e
                 left join attendance_days d on d.enrollment_id = e.id and d.edu_date = p_date
                where e.region_id = r.id and e.status = 'active'
                  and (e.starts_on is null or e.starts_on <= p_date)
                  and (e.ends_on is null or e.ends_on >= p_date)
             ),
             'campuses', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'name', c.name,
                        'activeNetworks', (select count(*) from allowed_networks n
                                            where n.campus_id = c.id and n.status = 'active')
                      ) order by c.id)
                 from campuses c where c.region_id = r.id and c.is_active
             ), '[]'::jsonb),
             'pendingCorrections', (select count(*) from correction_requests q
                                     where q.region_id = r.id and q.status = 'pending')
           ) order by r.id)
      from regions r where r.is_active
  ), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------------

revoke execute on all functions in schema attendance from public;

grant execute on function
  attendance.api_operator_student(bytea, bigint, date),
  attendance.api_operator_day(bytea, bigint, date),
  attendance.api_student_correction_request(bytea, date, text),
  attendance.api_student_corrections(bytea),
  attendance.api_operator_corrections(bytea, text, text),
  attendance.api_operator_correction_save(bytea, bigint, date, jsonb, text, bigint, int),
  attendance.api_operator_correction_reject(bytea, bigint, text),
  attendance.api_operator_courses(bytea, text),
  attendance.api_operator_roster(bytea, text),
  attendance.api_operator_enroll(bytea, text, jsonb, boolean),
  attendance.api_operator_enrollment_update(bytea, bigint, text, bigint, text, text),
  attendance.api_operator_issues(bytea, text, date, date),
  attendance.api_operator_audit(bytea, text, bigint, int),
  attendance.api_operator_export(bytea, text, date, date),
  attendance.api_operator_overview(bytea, date)
to attendance_app;

commit;
