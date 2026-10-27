-- 훈련 상태(훈련중·중도탈락·조기취업·수료), 공가, 출결 일보
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0005_reports.sql
--
--   * 교육생은 지우지 않는다. 중도탈락·조기취업·수료는 훈련 상태와 그 날짜(status_on)로 남긴다.
--     그 날짜부터 재적에서 빠지고, 본인 확인과 출결 입력이 막힌다 (status = 'ended').
--   * 공가(병결·면접·예비군 등)는 교육생이나 운영자가 등록해 두는 기록이다. 증빙 서류는 LMS에 직접
--     올리므로 여기서는 확인 절차 없이 등록·취소만 한다. 출결 원본 기록은 바꾸지 않는다.
--   * 출결 일보는 과정 시간(class_start, class_end, 지각 기준 late_after_minutes)과 그 날 기록으로
--     지각·조퇴·결석을 계산하고, 운영자가 교육생별 사유를 적는다. 공식 출석 인정은 LMS 판정을 따른다.
--   * 인원 구분: 정원 = 수강 명단 전체(중도탈락·조기취업 포함), 재적 = 그 중 훈련중,
--     현인원 = 지금 강의장에 있는 인원(교육 중 상태).

begin;

-- ---------------------------------------------------------------------------
-- 훈련 상태
-- ---------------------------------------------------------------------------

alter table attendance.enrollments
  add column training_status text not null default 'training'
    check (training_status in ('training', 'dropped', 'employed', 'completed')),
  -- 중도탈락·조기취업·수료 일자. 이 날부터 재적에서 빠진다.
  add column status_on date;

-- 기존에 종료로 둔 수강은 수료로 옮긴다.
update attendance.enrollments
   set training_status = 'completed',
       status_on = coalesce(ends_on, (updated_at at time zone 'Asia/Seoul')::date)
 where status = 'ended';

alter table attendance.enrollments
  add constraint enrollments_training_status_on check ((training_status = 'training') = (status_on is null)),
  add constraint enrollments_training_ended check ((training_status = 'training') = (status <> 'ended'));

-- 그 날짜 기준 훈련 상태
create function attendance.training_state(p_training_status text, p_status_on date, p_date date)
returns text
language sql immutable as $$
  select case when p_status_on is not null and p_status_on <= p_date then p_training_status else 'training' end
$$;

-- ---------------------------------------------------------------------------
-- 과정 시간 (지각·조퇴 판단 기준)
-- ---------------------------------------------------------------------------

alter table attendance.courses
  add column class_start time not null default '09:00',
  add column class_end time not null default '18:00',
  -- 시작 후 이 분(分)부터 지각. 기본 10분: 09:09 입실은 정상, 09:10 입실부터 지각.
  add column late_after_minutes smallint not null default 10 check (late_after_minutes between 0 and 120),
  -- 점심시간은 수업 시간에서 빼고, 이 사이의 외출은 외출로 세지 않는다.
  add column lunch_start time not null default '12:00',
  add column lunch_end time not null default '13:00',
  add constraint courses_class_hours check (class_start < class_end and lunch_start <= lunch_end);

-- ---------------------------------------------------------------------------
-- 공가
-- ---------------------------------------------------------------------------

create table attendance.leaves (
  id             bigint generated always as identity primary key,
  enrollment_id  bigint not null references attendance.enrollments (id),
  region_id      smallint not null references attendance.regions (id),
  starts_on      date not null,
  ends_on        date not null,
  -- 병결 · 면접 · 예비군/민방위 · 경조사 · 기타
  kind           text not null check (kind in ('sick', 'interview', 'reserve', 'family', 'other')),
  -- full: 하루 전체(결석) / partial: 일부 시간(지각·조퇴·외출)
  part           text not null default 'full' check (part in ('full', 'partial')),
  reason         text not null,
  status         text not null default 'registered' check (status in ('registered', 'cancelled')),
  created_by     text not null check (created_by in ('student', 'operator')),
  created_name   text,
  session_id     uuid,
  created_at     timestamptz not null default now(),
  cancelled_at   timestamptz,
  cancelled_by   text,
  cancel_note    text,
  version        int not null default 1,
  check (ends_on >= starts_on and ends_on - starts_on <= 13)
);

create index leaves_region_idx on attendance.leaves (region_id, starts_on);
create index leaves_enrollment_idx on attendance.leaves (enrollment_id, starts_on);

-- 그 날짜에 걸린 공가 (취소 제외)
create function attendance.leave_on(p_enrollment_id bigint, p_date date)
returns jsonb
language sql stable as $$
  select jsonb_build_object('id', l.id, 'kind', l.kind, 'part', l.part, 'status', l.status, 'reason', l.reason,
                            'startsOn', l.starts_on, 'endsOn', l.ends_on)
    from attendance.leaves l
   where l.enrollment_id = p_enrollment_id
     and p_date between l.starts_on and l.ends_on
     and l.status = 'registered'
   order by l.id desc
   limit 1
$$;

create function attendance.leave_overlaps(p_enrollment_id bigint, p_from date, p_to date)
returns boolean
language sql stable as $$
  select exists (
    select 1 from attendance.leaves l
     where l.enrollment_id = p_enrollment_id
       and l.status = 'registered'
       and l.starts_on <= p_to and l.ends_on >= p_from)
$$;

-- ---------------------------------------------------------------------------
-- 하루 판정과 누적
--   * 수업 시간 = 교육 시작~종료에서 점심시간을 뺀 시간
--   * 그 날 교육 중이었던 시간이 수업 시간의 50% 미만이면 결석 (지각·조퇴·외출은 성립하지 않음)
--   * 지각: 첫 입실이 시작 + late_after_minutes 이후 / 조퇴: 퇴실로 끝났고 마지막 퇴실이 종료 전
--   * 외출: 외출~복귀 구간이 수업 시간(점심 제외)에 걸친 경우 1회
--   * 지각·조퇴·외출 합계 3회 = 결석 1회로 환산 (공가 등록된 날은 세지 않음)
-- ---------------------------------------------------------------------------

-- [a,b) 와 [c,d) 가 겹치는 분
create function attendance.overlap_minutes(a timestamptz, b timestamptz, c timestamptz, d timestamptz)
returns numeric
language sql immutable as $$
  select greatest(0, extract(epoch from (least(b, d) - greatest(a, c))) / 60)
$$;

-- [a,b) 중 수업 시간 [s,e) 안이면서 점심 [ls,le) 밖인 분
create function attendance.class_minutes_in(
  a timestamptz, b timestamptz, s timestamptz, e timestamptz, ls timestamptz, le timestamptz
) returns numeric
language sql immutable as $$
  select attendance.overlap_minutes(a, b, s, e) - attendance.overlap_minutes(a, b, greatest(ls, s), least(le, e))
$$;

-- 하루 평가: 화면 타임라인(정정 반영)으로 계산한다. 끝나지 않은 구간은 종료 시각(오늘이면 지금)까지로 본다.
create function attendance.day_eval(p_enrollment_id bigint, p_date date, p_course attendance.courses)
returns jsonb
language plpgsql stable as $$
declare
  v_s        timestamptz := (p_date + p_course.class_start) at time zone 'Asia/Seoul';
  v_e        timestamptz := (p_date + p_course.class_end) at time zone 'Asia/Seoul';
  v_ls       timestamptz := (p_date + p_course.lunch_start) at time zone 'Asia/Seoul';
  v_le       timestamptz := (p_date + p_course.lunch_end) at time zone 'Asia/Seoul';
  v_cap      timestamptz;
  v_item     jsonb;
  v_at       timestamptz;
  v_action   text;
  v_in_from  timestamptz;
  v_out_from timestamptz;
  v_first    timestamptz;
  v_last_out timestamptz;
  v_status   text := 'not_in';
  v_att      numeric := 0;
  v_outs     int := 0;
  v_class    numeric;
begin
  v_cap := least(v_e, now());
  v_class := attendance.class_minutes_in(v_s, v_e, v_s, v_e, v_ls, v_le);
  for v_item in select value from jsonb_array_elements(attendance.effective_timeline(p_enrollment_id, p_date)) loop
    v_at := (v_item->>'at')::timestamptz;
    v_action := v_item->>'action';
    if v_action in ('check_in', 'return') then
      if v_action = 'check_in' then v_first := coalesce(v_first, v_at); end if;
      if v_out_from is not null then
        if attendance.class_minutes_in(v_out_from, v_at, v_s, v_e, v_ls, v_le) > 0 then v_outs := v_outs + 1; end if;
        v_out_from := null;
      end if;
      v_in_from := v_at;
      v_status := 'in_class';
    elsif v_action in ('go_out', 'check_out') then
      if v_in_from is not null then
        v_att := v_att + attendance.class_minutes_in(v_in_from, v_at, v_s, v_e, v_ls, v_le);
      end if;
      v_in_from := null;
      if v_action = 'go_out' then
        v_out_from := v_at;
        v_status := 'out';
      else
        v_last_out := v_at;
        v_status := 'checked_out';
      end if;
    end if;
  end loop;
  if v_in_from is not null and v_cap > v_in_from then
    v_att := v_att + attendance.class_minutes_in(v_in_from, v_cap, v_s, v_e, v_ls, v_le);
  end if;
  if v_out_from is not null and v_cap > v_out_from
     and attendance.class_minutes_in(v_out_from, v_cap, v_s, v_e, v_ls, v_le) > 0 then
    v_outs := v_outs + 1;
  end if;

  return jsonb_build_object(
    'status', v_status,
    'firstIn', v_first,
    'lastOut', v_last_out,
    'attendedMinutes', round(v_att)::int,
    'classMinutes', round(v_class)::int,
    'enough', v_first is not null and v_att * 2 >= v_class,
    'late', v_first is not null and v_first >= v_s + make_interval(mins => p_course.late_after_minutes),
    'early', v_status = 'checked_out' and v_last_out < v_e,
    'outs', v_outs
  );
end $$;

-- 하루 판정 (평가 + 공가)
--   absent: 입실 없음 또는 50% 미만 / absentExcused: 하루 전체 공가
--   late·early·outs: 성립한 지각·조퇴·외출 / excused: 공가가 등록된 날이라 누적에 세지 않음
create function attendance.day_judge(p_eval jsonb, p_leave jsonb)
returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'absent', not coalesce((p_eval->>'enough')::boolean, false),
    'insufficient', p_eval->>'firstIn' is not null and not (p_eval->>'enough')::boolean,
    'absentExcused', not coalesce((p_eval->>'enough')::boolean, false) and coalesce(p_leave->>'part', '') = 'full',
    'late', coalesce((p_eval->>'enough')::boolean, false) and (p_eval->>'late')::boolean,
    'early', coalesce((p_eval->>'enough')::boolean, false) and (p_eval->>'early')::boolean,
    'outs', case when coalesce((p_eval->>'enough')::boolean, false) then (p_eval->>'outs')::int else 0 end,
    'excused', p_leave is not null
  )
$$;

-- 기간 누적. 수업일 = 같은 과정 교육생 누구라도 기록이 있는 평일.
create function attendance.course_tally(p_enrollment_id bigint, p_course attendance.courses, p_from date, p_to date)
returns jsonb
language plpgsql stable as $$
declare
  v_day     date;
  v_j       jsonb;
  v_absent  int := 0;
  v_excused int := 0;
  v_late    int := 0;
  v_early   int := 0;
  v_outs    int := 0;
  v_days    int := 0;
begin
  for v_day in
    select distinct d.edu_date
      from attendance.attendance_days d
      join attendance.enrollments o on o.id = d.enrollment_id
     where o.course_id = p_course.id
       and d.edu_date between p_from and p_to
       and (d.last_event_at is not null or d.corrected)
       and extract(isodow from d.edu_date) <= 5
  loop
    v_days := v_days + 1;
    v_j := attendance.day_judge(attendance.day_eval(p_enrollment_id, v_day, p_course),
                                attendance.leave_on(p_enrollment_id, v_day));
    if (v_j->>'absent')::boolean then
      if (v_j->>'absentExcused')::boolean then v_excused := v_excused + 1; else v_absent := v_absent + 1; end if;
    elsif not (v_j->>'excused')::boolean then
      v_late := v_late + (v_j->>'late')::boolean::int;
      v_early := v_early + (v_j->>'early')::boolean::int;
      v_outs := v_outs + (v_j->>'outs')::int;
    end if;
  end loop;
  return jsonb_build_object(
    'days', v_days, 'absent', v_absent, 'absentExcused', v_excused,
    'late', v_late, 'early', v_early, 'outs', v_outs,
    'converted', (v_late + v_early + v_outs) / 3,
    'totalAbsent', v_absent + (v_late + v_early + v_outs) / 3
  );
end $$;

-- 병결 사용 일수 (평일, 취소 제외). 과정당 5일까지.
create function attendance.weekdays_between(p_from date, p_to date)
returns int
language sql immutable as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') g where extract(isodow from g) <= 5
$$;

create function attendance.sick_days_used(p_enrollment_id bigint)
returns int
language sql stable as $$
  select coalesce(sum(attendance.weekdays_between(l.starts_on, l.ends_on)), 0)::int
    from attendance.leaves l
   where l.enrollment_id = p_enrollment_id and l.kind = 'sick' and l.status = 'registered'
$$;

-- ---------------------------------------------------------------------------
-- 출결 일보 사유
-- ---------------------------------------------------------------------------

create table attendance.day_notes (
  enrollment_id  bigint not null references attendance.enrollments (id),
  edu_date       date not null,
  region_id      smallint not null references attendance.regions (id),
  note           text not null,
  updated_by     text not null,
  updated_at     timestamptz not null default now(),
  version        int not null default 1,
  primary key (enrollment_id, edu_date)
);

create index day_notes_region_idx on attendance.day_notes (region_id, edu_date);

-- ---------------------------------------------------------------------------
-- 명단: 훈련 상태 표시와 변경
-- ---------------------------------------------------------------------------

create or replace function attendance.api_operator_roster(p_token_hash bytea, p_region_code text)
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
             'trainingStatus', e.training_status, 'statusOn', e.status_on,
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

drop function attendance.api_operator_enrollment_update(bytea, bigint, text, bigint, text, text);

-- 수강 상태 변경, 과정 변경, 뒷자리 재등록, 훈련 상태 변경
--   p_training_status 가 null 이면 훈련 상태는 그대로 둔다.
--   훈련중이 아니면(중도탈락·조기취업·수료) 날짜가 필요하고, 출결 입력이 막힌다(status = 'ended').
create function attendance.api_operator_enrollment_update(
  p_token_hash bytea, p_enrollment_id bigint, p_status text, p_course_id bigint, p_last4_hmac text, p_reason text,
  p_training_status text default null, p_status_on date default null
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op       record;
  v_e        enrollments;
  v_after    enrollments;
  v_hmac     text;
  v_course   bigint;
  v_training text;
  v_on       date;
  v_status   text;
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

  v_training := coalesce(p_training_status, v_e.training_status);
  if v_training not in ('training', 'dropped', 'employed', 'completed') then
    return jsonb_build_object('ok', false, 'code', 'invalid_status');
  end if;
  if v_training = 'training' then
    if p_status not in ('active', 'paused') then
      return jsonb_build_object('ok', false, 'code', 'invalid_status');
    end if;
    v_status := p_status;
    v_on := null;
  else
    v_on := case when p_training_status is null then v_e.status_on else p_status_on end;
    if v_on is null then
      return jsonb_build_object('ok', false, 'code', 'status_date_required');
    end if;
    if v_on > edu_date_now() + 31 then
      return jsonb_build_object('ok', false, 'code', 'status_date_invalid');
    end if;
    v_status := 'ended';
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
  if v_status = 'active' and exists (
    select 1 from enrollments o
     where o.region_id = v_e.region_id and o.id <> v_e.id and o.status = 'active'
       and o.name_key = v_e.name_key and o.last4_hmac = v_hmac
  ) then
    return jsonb_build_object('ok', false, 'code', 'duplicate_match');
  end if;

  update enrollments
     set status = v_status, course_id = v_course, last4_hmac = v_hmac,
         training_status = v_training, status_on = v_on, updated_at = now()
   where id = v_e.id
  returning * into v_after;

  -- 중지·종료되면 남아 있는 학생 세션을 끊는다.
  if v_status <> 'active' then
    update sessions set revoked_at = now()
     where kind = 'student' and enrollment_id = v_e.id and revoked_at is null;
  end if;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after, reason)
  values (v_e.region_id, v_op.scope, v_op.operator_name,
          case when v_training <> v_e.training_status then 'enrollment.training' else 'enrollment.update' end,
          'enrollments', v_e.id::text,
          to_jsonb(v_e) - 'name_key' - 'last4_hmac',
          (to_jsonb(v_after) - 'name_key' - 'last4_hmac')
            || jsonb_build_object('last4Changed', p_last4_hmac is not null and p_last4_hmac <> v_e.last4_hmac),
          trim(p_reason));

  return jsonb_build_object('ok', true);
end $$;

-- 학생별 기록: 훈련 상태와 그 달 공가 포함
create or replace function attendance.api_operator_student(p_token_hash bytea, p_enrollment_id bigint, p_month date)
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
               'trainingStatus', v_e.training_status, 'statusOn', v_e.status_on,
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
    ), '[]'::jsonb),
    'leaves', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'startsOn', l.starts_on, 'endsOn', l.ends_on, 'kind', l.kind, 'part', l.part,
               'status', l.status, 'reason', l.reason) order by l.starts_on desc)
        from leaves l
       where l.enrollment_id = v_e.id and l.starts_on <= v_to and l.ends_on >= v_from
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- 학생: 공가 신청 (교육장 밖에서도 가능)
-- ---------------------------------------------------------------------------

create function attendance.api_student_leave(
  p_token_hash bytea, p_from date, p_to date, p_kind text, p_part text, p_reason text
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s  sessions;
  v_id bigint;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if p_kind not in ('sick', 'interview', 'reserve', 'family', 'other') or p_part not in ('full', 'partial') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 13
     or p_from < edu_date_now() - 14 or p_to > edu_date_now() + 30 then
    return jsonb_build_object('ok', false, 'code', 'invalid_leave_date');
  end if;
  if length(trim(coalesce(p_reason, ''))) < 2 or length(p_reason) > 300 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if leave_overlaps(v_s.enrollment_id, p_from, p_to) then
    return jsonb_build_object('ok', false, 'code', 'leave_overlap');
  end if;
  if p_kind = 'sick' and sick_days_used(v_s.enrollment_id) + weekdays_between(p_from, p_to) > 5 then
    return jsonb_build_object('ok', false, 'code', 'sick_limit', 'used', sick_days_used(v_s.enrollment_id));
  end if;
  insert into leaves (enrollment_id, region_id, starts_on, ends_on, kind, part, reason, created_by, session_id)
  values (v_s.enrollment_id, v_s.region_id, p_from, p_to, p_kind, p_part, trim(p_reason), 'student', v_s.id)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 본인 공가 (최근 60일부터 앞으로)
create function attendance.api_student_leaves(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  return jsonb_build_object('ok', true, 'sickUsed', sick_days_used(v_s.enrollment_id), 'sickLimit', 5, 'leaves', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'startsOn', l.starts_on, 'endsOn', l.ends_on, 'kind', l.kind, 'part', l.part,
             'reason', l.reason, 'status', l.status, 'cancelNote', l.cancel_note, 'createdAt', l.created_at,
             'cancellable', l.status = 'registered' and l.created_by = 'student' and l.ends_on >= edu_date_now()
           ) order by l.starts_on desc, l.id desc)
      from leaves l
     where l.enrollment_id = v_s.enrollment_id and l.ends_on >= edu_date_now() - 60
  ), '[]'::jsonb));
end $$;

create function attendance.api_student_leave_cancel(p_token_hash bytea, p_leave_id bigint)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  -- 본인이 등록했고 아직 지나지 않은 공가만 취소할 수 있다.
  update leaves set status = 'cancelled', cancelled_at = now(), cancelled_by = '본인', version = version + 1
   where id = p_leave_id and enrollment_id = v_s.enrollment_id and status = 'registered'
     and created_by = 'student' and ends_on >= edu_date_now();
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 운영자: 공가 목록 · 등록 · 취소
-- ---------------------------------------------------------------------------

create function attendance.api_operator_leaves(p_token_hash bytea, p_region_code text, p_from date, p_to date)
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
  return jsonb_build_object('ok', true, 'leaves', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'enrollmentId', e.id, 'name', st.name, 'course', co.name,
             'startsOn', l.starts_on, 'endsOn', l.ends_on, 'kind', l.kind, 'part', l.part, 'reason', l.reason,
             'status', l.status, 'createdBy', l.created_by, 'createdName', l.created_name, 'createdAt', l.created_at,
             'cancelledAt', l.cancelled_at, 'cancelledBy', l.cancelled_by, 'cancelNote', l.cancel_note, 'version', l.version
           ) order by l.starts_on, co.name, st.name)
      from leaves l
      join enrollments e on e.id = l.enrollment_id
      join students st on st.id = e.student_id
      join courses co on co.id = e.course_id
     where l.region_id = v_region and l.starts_on <= p_to and l.ends_on >= p_from
  ), '[]'::jsonb));
end $$;

-- 운영자 등록
create function attendance.api_operator_leave_create(
  p_token_hash bytea, p_enrollment_id bigint, p_from date, p_to date, p_kind text, p_part text, p_reason text
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op    record;
  v_e     enrollments;
  v_leave leaves;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_e := operator_enrollment(v_op.scope, v_op.region_id, p_enrollment_id);
  if v_e.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_kind not in ('sick', 'interview', 'reserve', 'family', 'other') or p_part not in ('full', 'partial') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 13
     or p_from < edu_date_now() - 90 or p_to > edu_date_now() + 60 then
    return jsonb_build_object('ok', false, 'code', 'invalid_leave_date');
  end if;
  if length(trim(coalesce(p_reason, ''))) < 2 or length(p_reason) > 300 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;
  if leave_overlaps(v_e.id, p_from, p_to) then
    return jsonb_build_object('ok', false, 'code', 'leave_overlap');
  end if;
  if p_kind = 'sick' and sick_days_used(v_e.id) + weekdays_between(p_from, p_to) > 5 then
    return jsonb_build_object('ok', false, 'code', 'sick_limit', 'used', sick_days_used(v_e.id));
  end if;

  insert into leaves (enrollment_id, region_id, starts_on, ends_on, kind, part, reason, created_by, created_name)
  values (v_e.id, v_e.region_id, p_from, p_to, p_kind, p_part, trim(p_reason), 'operator', v_op.operator_name)
  returning * into v_leave;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, after, reason)
  values (v_e.region_id, v_op.scope, v_op.operator_name, 'leave.create', 'leaves', v_leave.id::text,
          to_jsonb(v_leave), trim(p_reason));
  return jsonb_build_object('ok', true, 'id', v_leave.id);
end $$;

-- 운영자 취소 (잘못 등록했거나 일정이 바뀐 경우). 사유 필수.
create function attendance.api_operator_leave_cancel(
  p_token_hash bytea, p_leave_id bigint, p_note text, p_version int
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_before leaves;
  v_after  leaves;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select * into v_before from leaves where id = p_leave_id for update;
  if not found or not operator_owns(v_op.scope, v_op.region_id, v_before.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_before.status <> 'registered' then
    return jsonb_build_object('ok', false, 'code', 'already_decided');
  end if;
  if v_before.version <> p_version then
    return jsonb_build_object('ok', false, 'code', 'version_conflict');
  end if;
  if length(trim(coalesce(p_note, ''))) = 0 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  update leaves
     set status = 'cancelled', cancelled_at = now(), cancelled_by = v_op.operator_name,
         cancel_note = trim(p_note), version = version + 1
   where id = v_before.id
  returning * into v_after;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after, reason)
  values (v_before.region_id, v_op.scope, v_op.operator_name, 'leave.cancel', 'leaves', v_before.id::text,
          to_jsonb(v_before), to_jsonb(v_after), trim(p_note));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 출결 일보
-- ---------------------------------------------------------------------------

-- 그 날 수강 기간에 들어 있던 교육생 전체(중도탈락·취업 포함)와 그 날 평가·판정·공가·알림·사유,
-- 그리고 과정 시작부터 그 날까지의 누적(지각·조퇴·외출과 결석 환산). 판정 기준은 day_eval·day_judge 참고.
-- 오늘 날짜는 교육 종료 시각이 지나야 누적에 넣는다.
create function attendance.api_operator_report(p_token_hash bytea, p_region_code text, p_date date)
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
  if p_date is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  return jsonb_build_object(
    'ok', true,
    'date', p_date,
    'today', edu_date_now(),
    'now', now(),
    'courses', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', co.id, 'name', co.name,
               'classStart', to_char(co.class_start, 'HH24:MI'), 'classEnd', to_char(co.class_end, 'HH24:MI'),
               'lunchStart', to_char(co.lunch_start, 'HH24:MI'), 'lunchEnd', to_char(co.lunch_end, 'HH24:MI'),
               'lateAfter', co.late_after_minutes
             ) order by co.name)
        from courses co
       where co.region_id = v_region and co.is_active
    ), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(x.row order by x.course, x.name)
        from (
          select co.name as course, st.name as name, jsonb_build_object(
                   'enrollmentId', e.id, 'name', st.name, 'course', co.name, 'courseId', co.id,
                   'state', training_state(e.training_status, e.status_on, p_date),
                   'statusOn', e.status_on,
                   'dayStatus', z.ev->>'status',
                   'firstCheckInAt', z.ev->'firstIn',
                   'lastCheckOutAt', z.ev->'lastOut',
                   'corrected', coalesce(d.corrected, false),
                   'eval', z.ev,
                   'judge', day_judge(z.ev, z.lv),
                   'leave', z.lv,
                   'tally', course_tally(
                              e.id, co,
                              greatest((e.created_at at time zone 'Asia/Seoul')::date,
                                       coalesce(e.starts_on, date '1900-01-01'), coalesce(co.starts_on, date '1900-01-01')),
                              least(case when p_date < edu_date_now() or now() >= (p_date + co.class_end) at time zone 'Asia/Seoul'
                                         then p_date else p_date - 1 end,
                                    case when e.training_status in ('dropped', 'employed') then e.status_on - 1
                                         else date '9999-12-31' end)),
                   'sickUsed', sick_days_used(e.id),
                   'notices', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'kind', n.kind, 'expectedTime', to_char(n.expected_time, 'HH24:MI'), 'reason', n.reason
                            ) order by n.id)
                       from notices n
                      where n.enrollment_id = e.id and n.edu_date = p_date and n.status = 'submitted'
                   ), '[]'::jsonb),
                   'note', (select jsonb_build_object('text', dn.note, 'version', dn.version,
                                                      'updatedBy', dn.updated_by, 'updatedAt', dn.updated_at)
                              from day_notes dn where dn.enrollment_id = e.id and dn.edu_date = p_date)
                 ) as row
            from enrollments e
            join students st on st.id = e.student_id
            join courses co on co.id = e.course_id
            left join attendance_days d on d.enrollment_id = e.id and d.edu_date = p_date
            cross join lateral (select day_eval(e.id, p_date, co) as ev, leave_on(e.id, p_date) as lv) z
           where e.region_id = v_region
             and (e.created_at at time zone 'Asia/Seoul')::date <= p_date
             and (e.starts_on is null or e.starts_on <= p_date)
             and (e.ends_on is null or e.ends_on >= p_date)
             -- 수료한 뒤의 날짜에는 넣지 않는다 (수료 당일까지 포함)
             and not (e.training_status = 'completed' and e.status_on < p_date)
        ) x
    ), '[]'::jsonb)
  );
end $$;

-- 교육생별 사유. 빈 값이면 지운다. version 은 화면을 열 때 본 값(없으면 0).
create function attendance.api_operator_day_note(
  p_token_hash bytea, p_enrollment_id bigint, p_date date, p_note text, p_version int
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_e      enrollments;
  v_before day_notes;
  v_note   text := trim(coalesce(p_note, ''));
  v_ver    int;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_e := operator_enrollment(v_op.scope, v_op.region_id, p_enrollment_id);
  if v_e.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_date is null or p_date > edu_date_now() + 14 or length(v_note) > 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;

  select * into v_before from day_notes where enrollment_id = v_e.id and edu_date = p_date for update;
  if coalesce(v_before.version, 0) <> coalesce(p_version, 0) then
    return jsonb_build_object('ok', false, 'code', 'version_conflict');
  end if;
  if coalesce(v_before.note, '') = v_note then
    return jsonb_build_object('ok', false, 'code', 'no_change');
  end if;

  if v_note = '' then
    delete from day_notes where enrollment_id = v_e.id and edu_date = p_date;
    v_ver := 0;
  elsif v_before.enrollment_id is null then
    insert into day_notes (enrollment_id, edu_date, region_id, note, updated_by)
    values (v_e.id, p_date, v_e.region_id, v_note, v_op.operator_name);
    v_ver := 1;
  else
    update day_notes set note = v_note, updated_by = v_op.operator_name, updated_at = now(), version = version + 1
     where enrollment_id = v_e.id and edu_date = p_date
    returning version into v_ver;
  end if;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_e.region_id, v_op.scope, v_op.operator_name, 'note.save', 'day_notes', v_e.id::text || ':' || p_date,
          case when v_before.enrollment_id is not null then jsonb_build_object('note', v_before.note) end,
          jsonb_build_object('date', p_date, 'note', nullif(v_note, '')));
  return jsonb_build_object('ok', true, 'version', v_ver);
end $$;

-- 과정 시간 변경 (지각·조퇴 판단 기준). p_late_after: 시작 후 몇 분부터 지각인지
create function attendance.api_operator_course_hours(
  p_token_hash bytea, p_course_id bigint, p_start time, p_end time, p_late_after int,
  p_lunch_start time, p_lunch_end time
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_before courses;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select * into v_before from courses where id = p_course_id for update;
  if not found or not operator_owns(v_op.scope, v_op.region_id, v_before.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_start is null or p_end is null or p_start >= p_end or p_late_after is null or p_late_after not between 0 and 120
     or p_lunch_start is null or p_lunch_end is null or p_lunch_start > p_lunch_end then
    return jsonb_build_object('ok', false, 'code', 'invalid_hours');
  end if;
  if v_before.class_start = p_start and v_before.class_end = p_end and v_before.late_after_minutes = p_late_after
     and v_before.lunch_start = p_lunch_start and v_before.lunch_end = p_lunch_end then
    return jsonb_build_object('ok', false, 'code', 'no_change');
  end if;
  update courses
     set class_start = p_start, class_end = p_end, late_after_minutes = p_late_after,
         lunch_start = p_lunch_start, lunch_end = p_lunch_end
   where id = v_before.id;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_before.region_id, v_op.scope, v_op.operator_name, 'course.hours', 'courses', v_before.id::text,
          jsonb_build_object('course', v_before.name, 'start', to_char(v_before.class_start, 'HH24:MI'),
                             'end', to_char(v_before.class_end, 'HH24:MI'), 'lateAfter', v_before.late_after_minutes,
                             'lunch', to_char(v_before.lunch_start, 'HH24:MI') || '~' || to_char(v_before.lunch_end, 'HH24:MI')),
          jsonb_build_object('course', v_before.name, 'start', to_char(p_start, 'HH24:MI'),
                             'end', to_char(p_end, 'HH24:MI'), 'lateAfter', p_late_after,
                             'lunch', to_char(p_lunch_start, 'HH24:MI') || '~' || to_char(p_lunch_end, 'HH24:MI')));
  return jsonb_build_object('ok', true);
end $$;

revoke execute on all functions in schema attendance from public;

grant execute on function
  attendance.api_operator_enrollment_update(bytea, bigint, text, bigint, text, text, text, date),
  attendance.api_student_leave(bytea, date, date, text, text, text),
  attendance.api_student_leaves(bytea),
  attendance.api_student_leave_cancel(bytea, bigint),
  attendance.api_operator_leaves(bytea, text, date, date),
  attendance.api_operator_leave_create(bytea, bigint, date, date, text, text, text),
  attendance.api_operator_leave_cancel(bytea, bigint, text, int),
  attendance.api_operator_report(bytea, text, date),
  attendance.api_operator_day_note(bytea, bigint, date, text, int),
  attendance.api_operator_course_hours(bytea, bigint, time, time, int, time, time)
to attendance_app;

commit;
