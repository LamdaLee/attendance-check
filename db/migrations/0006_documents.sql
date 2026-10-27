-- 공가 서류 제출·승인, 단위기간 출석부, 출석확인서, 점심시간 제거
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0006_documents.sql
--
--   * 점심시간 구분을 없앤다. 수업 시간 = 교육 시작~종료 전체.
--   * 공가: 신청(registered) → 서류 제출(submitted) → 승인(approved) / 반려(rejected), 취소(cancelled).
--     교육생이 서류(JPG·PNG·PDF, 5MB, 3개까지)를 올리면 운영자가 확인해 승인한다.
--     승인된 공가 날은 출석으로 인정한다(하루 전체 공가, 또는 일부 시간 공가로 입실한 날).
--     승인 전 공가는 판정에 반영하지 않는다.
--   * 서류 파일은 DB에 보관하고, 해당 지역 운영자만 열 수 있다. 열람은 변경 이력에 남긴다.
--   * 단위기간 출석부: 과정·기간(최대 62일)별 교육생 × 수업일 판정표.
--   * 출석확인서: 교육생이 기간을 골라 출력. 교육장 회선이나 출석코드로 확인된 세션에서만 만든다.
--     생년월일은 출력할 때 입력만 하고 저장하지 않는다. 발급번호와 요약은 기록한다.

begin;

-- ---------------------------------------------------------------------------
-- 점심시간 제거
-- ---------------------------------------------------------------------------

drop function attendance.api_operator_course_hours(bytea, bigint, time, time, int, time, time);
alter table attendance.courses drop constraint courses_class_hours;
alter table attendance.courses drop column lunch_start, drop column lunch_end;
alter table attendance.courses add constraint courses_class_hours check (class_start < class_end);
drop function attendance.class_minutes_in(timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz);

-- 하루 평가: 화면 타임라인(정정 반영)으로 계산한다. 끝나지 않은 구간은 종료 시각(오늘이면 지금)까지로 본다.
create or replace function attendance.day_eval(p_enrollment_id bigint, p_date date, p_course attendance.courses)
returns jsonb
language plpgsql stable as $$
declare
  v_s        timestamptz := (p_date + p_course.class_start) at time zone 'Asia/Seoul';
  v_e        timestamptz := (p_date + p_course.class_end) at time zone 'Asia/Seoul';
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
  v_class := attendance.overlap_minutes(v_s, v_e, v_s, v_e);
  for v_item in select value from jsonb_array_elements(attendance.effective_timeline(p_enrollment_id, p_date)) loop
    v_at := (v_item->>'at')::timestamptz;
    v_action := v_item->>'action';
    if v_action in ('check_in', 'return') then
      if v_action = 'check_in' then v_first := coalesce(v_first, v_at); end if;
      if v_out_from is not null then
        if attendance.overlap_minutes(v_out_from, v_at, v_s, v_e) > 0 then v_outs := v_outs + 1; end if;
        v_out_from := null;
      end if;
      v_in_from := v_at;
      v_status := 'in_class';
    elsif v_action in ('go_out', 'check_out') then
      if v_in_from is not null then
        v_att := v_att + attendance.overlap_minutes(v_in_from, v_at, v_s, v_e);
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
    v_att := v_att + attendance.overlap_minutes(v_in_from, v_cap, v_s, v_e);
  end if;
  if v_out_from is not null and v_cap > v_out_from and attendance.overlap_minutes(v_out_from, v_cap, v_s, v_e) > 0 then
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

-- 과정 시간 변경 (지각·조퇴 판단 기준). p_late_after: 시작 후 몇 분부터 지각인지
create function attendance.api_operator_course_hours(
  p_token_hash bytea, p_course_id bigint, p_start time, p_end time, p_late_after int
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
  if p_start is null or p_end is null or p_start >= p_end or p_late_after is null or p_late_after not between 0 and 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_hours');
  end if;
  if v_before.class_start = p_start and v_before.class_end = p_end and v_before.late_after_minutes = p_late_after then
    return jsonb_build_object('ok', false, 'code', 'no_change');
  end if;
  update courses set class_start = p_start, class_end = p_end, late_after_minutes = p_late_after where id = v_before.id;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_before.region_id, v_op.scope, v_op.operator_name, 'course.hours', 'courses', v_before.id::text,
          jsonb_build_object('course', v_before.name, 'start', to_char(v_before.class_start, 'HH24:MI'),
                             'end', to_char(v_before.class_end, 'HH24:MI'), 'lateAfter', v_before.late_after_minutes),
          jsonb_build_object('course', v_before.name, 'start', to_char(p_start, 'HH24:MI'),
                             'end', to_char(p_end, 'HH24:MI'), 'lateAfter', p_late_after));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 공가 상태 · 서류
-- ---------------------------------------------------------------------------

alter table attendance.leaves drop constraint leaves_status_check;
alter table attendance.leaves
  add constraint leaves_status_check check (status in ('registered', 'submitted', 'approved', 'rejected', 'cancelled')),
  add column decided_at timestamptz,
  add column decided_by text,
  add column decision_note text;

create table attendance.leave_docs (
  id           bigint generated always as identity primary key,
  leave_id     bigint not null references attendance.leaves (id),
  file_name    text not null check (length(file_name) between 1 and 120),
  mime         text not null check (mime in ('image/jpeg', 'image/png', 'application/pdf')),
  size_bytes   int not null check (size_bytes between 1 and 5242880),
  content      bytea not null,
  uploaded_at  timestamptz not null default now()
);

create index leave_docs_leave_idx on attendance.leave_docs (leave_id);

-- 살아 있는 공가 = 신청·서류 제출·승인
create or replace function attendance.leave_on(p_enrollment_id bigint, p_date date)
returns jsonb
language sql stable as $$
  select jsonb_build_object('id', l.id, 'kind', l.kind, 'part', l.part, 'status', l.status, 'reason', l.reason,
                            'startsOn', l.starts_on, 'endsOn', l.ends_on)
    from attendance.leaves l
   where l.enrollment_id = p_enrollment_id
     and p_date between l.starts_on and l.ends_on
     and l.status in ('registered', 'submitted', 'approved')
   order by l.status = 'approved' desc, l.id desc
   limit 1
$$;

create or replace function attendance.leave_overlaps(p_enrollment_id bigint, p_from date, p_to date)
returns boolean
language sql stable as $$
  select exists (
    select 1 from attendance.leaves l
     where l.enrollment_id = p_enrollment_id
       and l.status in ('registered', 'submitted', 'approved')
       and l.starts_on <= p_to and l.ends_on >= p_from)
$$;

create or replace function attendance.sick_days_used(p_enrollment_id bigint)
returns int
language sql stable as $$
  select coalesce(sum(attendance.weekdays_between(l.starts_on, l.ends_on)), 0)::int
    from attendance.leaves l
   where l.enrollment_id = p_enrollment_id and l.kind = 'sick'
     and l.status in ('registered', 'submitted', 'approved')
$$;

-- 하루 판정 (평가 + 공가). 승인된 공가만 반영한다.
--   absent: 결석으로 셈 (입실 없음 또는 50% 미만, 승인 공가로 인정되지 않은 경우)
--   leaveAttend: 승인 공가로 출석 인정 (하루 전체 공가, 또는 일부 시간 공가로 입실한 날)
--   late·early·outs: 성립한 지각·조퇴·외출 (승인 공가 날은 세지 않음)
--   excused: 승인 공가 날 / pending: 승인 전 공가가 걸린 날
create or replace function attendance.day_judge(p_eval jsonb, p_leave jsonb)
returns jsonb
language sql immutable as $$
  with x as (
    select coalesce((p_eval->>'enough')::boolean, false) as enough,
           p_eval->>'firstIn' is not null as came,
           coalesce(p_leave->>'status', '') = 'approved' as appr,
           coalesce(p_leave->>'part', '') as part
  )
  select jsonb_build_object(
    'absent', not enough and not (appr and (part = 'full' or came)),
    'leaveAttend', not enough and appr and (part = 'full' or came),
    'insufficient', came and not enough,
    'late', enough and not appr and coalesce((p_eval->>'late')::boolean, false),
    'early', enough and not appr and coalesce((p_eval->>'early')::boolean, false),
    'outs', case when enough and not appr then coalesce((p_eval->>'outs')::int, 0) else 0 end,
    'excused', appr,
    'pending', p_leave is not null and not appr
  ) from x
$$;

-- 기간 누적. 수업일 = 같은 과정 교육생 누구라도 기록이 있는 평일.
create or replace function attendance.course_tally(p_enrollment_id bigint, p_course attendance.courses, p_from date, p_to date)
returns jsonb
language plpgsql stable as $$
declare
  v_day    date;
  v_j      jsonb;
  v_absent int := 0;
  v_leave  int := 0;
  v_late   int := 0;
  v_early  int := 0;
  v_outs   int := 0;
  v_days   int := 0;
  v_conv   int;
begin
  for v_day in select attendance.class_days(p_course.id, p_from, p_to) loop
    v_days := v_days + 1;
    v_j := attendance.day_judge(attendance.day_eval(p_enrollment_id, v_day, p_course),
                                attendance.leave_on(p_enrollment_id, v_day));
    if (v_j->>'absent')::boolean then
      v_absent := v_absent + 1;
    else
      if (v_j->>'leaveAttend')::boolean then v_leave := v_leave + 1; end if;
      v_late := v_late + (v_j->>'late')::boolean::int;
      v_early := v_early + (v_j->>'early')::boolean::int;
      v_outs := v_outs + (v_j->>'outs')::int;
    end if;
  end loop;
  v_conv := (v_late + v_early + v_outs) / 3;
  return jsonb_build_object(
    'days', v_days, 'absent', v_absent, 'leaveAttend', v_leave,
    'late', v_late, 'early', v_early, 'outs', v_outs,
    'converted', v_conv, 'totalAbsent', v_absent + v_conv,
    'attended', v_days - v_absent - v_conv,
    'rate', case when v_days > 0 then round(100.0 * (v_days - v_absent - v_conv) / v_days, 1) end
  );
end $$;

-- 과정의 수업일 (기록이 있는 평일)
create function attendance.class_days(p_course_id bigint, p_from date, p_to date)
returns setof date
language sql stable as $$
  select distinct d.edu_date
    from attendance.attendance_days d
    join attendance.enrollments o on o.id = d.enrollment_id
   where o.course_id = p_course_id
     and d.edu_date between p_from and p_to
     and (d.last_event_at is not null or d.corrected)
     and extract(isodow from d.edu_date) <= 5
   order by 1
$$;

-- 출석부 칸 하나. 훈련중이 아닌 날은 {state}, 그 외에는 판정 요약과 입·퇴실 시각.
create function attendance.day_cell(p_e attendance.enrollments, p_course attendance.courses, p_date date)
returns jsonb
language plpgsql stable as $$
declare
  v_state text := attendance.training_state(p_e.training_status, p_e.status_on, p_date);
  v_ev    jsonb;
  v_lv    jsonb;
begin
  if v_state <> 'training' then
    return jsonb_build_object('state', v_state);
  end if;
  v_ev := attendance.day_eval(p_e.id, p_date, p_course);
  v_lv := attendance.leave_on(p_e.id, p_date);
  return attendance.day_judge(v_ev, v_lv) || jsonb_build_object(
    'state', 'training',
    'in', to_char((v_ev->>'firstIn')::timestamptz at time zone 'Asia/Seoul', 'HH24:MI'),
    'out', to_char((v_ev->>'lastOut')::timestamptz at time zone 'Asia/Seoul', 'HH24:MI'),
    'leaveKind', v_lv->>'kind',
    'open', p_date = attendance.edu_date_now() and now() < (p_date + p_course.class_end) at time zone 'Asia/Seoul'
  );
end $$;

-- ---------------------------------------------------------------------------
-- 학생: 공가 목록 · 서류 제출 · 취소
-- ---------------------------------------------------------------------------

create or replace function attendance.api_student_leaves(p_token_hash bytea)
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
             'reason', l.reason, 'status', l.status, 'createdAt', l.created_at,
             'note', coalesce(l.decision_note, l.cancel_note),
             'docs', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.file_name, 'size', d.size_bytes,
                                                                   'uploadedAt', d.uploaded_at) order by d.id)
                                 from leave_docs d where d.leave_id = l.id), '[]'::jsonb),
             'uploadable', l.status in ('registered', 'submitted', 'rejected'),
             'cancellable', l.status in ('registered', 'submitted', 'rejected') and l.created_by = 'student'
           ) order by l.starts_on desc, l.id desc)
      from leaves l
     where l.enrollment_id = v_s.enrollment_id and l.ends_on >= edu_date_now() - 60
  ), '[]'::jsonb));
end $$;

create or replace function attendance.api_student_leave_cancel(p_token_hash bytea, p_leave_id bigint)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  -- 본인이 신청했고 아직 승인되지 않은 공가만 취소할 수 있다.
  update leaves set status = 'cancelled', cancelled_at = now(), cancelled_by = '본인', version = version + 1
   where id = p_leave_id and enrollment_id = v_s.enrollment_id
     and status in ('registered', 'submitted', 'rejected') and created_by = 'student';
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 서류 올리기. 앱이 형식(파일 머리 바이트)과 크기를 확인한 뒤 호출한다. 올리면 "서류 제출" 상태가 된다.
create function attendance.api_student_leave_doc_add(
  p_token_hash bytea, p_leave_id bigint, p_file_name text, p_mime text, p_content bytea
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s     sessions;
  v_leave leaves;
  v_id    bigint;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select * into v_leave from leaves where id = p_leave_id and enrollment_id = v_s.enrollment_id for update;
  if not found or v_leave.status not in ('registered', 'submitted', 'rejected') then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_mime not in ('image/jpeg', 'image/png', 'application/pdf') or p_content is null
     or length(p_content) = 0 or length(p_content) > 5242880 then
    return jsonb_build_object('ok', false, 'code', 'invalid_file');
  end if;
  if (select count(*) from leave_docs where leave_id = v_leave.id) >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_files');
  end if;
  insert into leave_docs (leave_id, file_name, mime, size_bytes, content)
  values (v_leave.id, left(coalesce(nullif(trim(p_file_name), ''), '서류'), 120), p_mime, length(p_content), p_content)
  returning id into v_id;
  update leaves set status = 'submitted', decided_at = null, decided_by = null, decision_note = null,
                    version = version + 1
   where id = v_leave.id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create function attendance.api_student_leave_doc_delete(p_token_hash bytea, p_doc_id bigint)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s     sessions;
  v_leave leaves;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select l.* into v_leave from leave_docs d join leaves l on l.id = d.leave_id
   where d.id = p_doc_id and l.enrollment_id = v_s.enrollment_id for update of l;
  if not found or v_leave.status not in ('registered', 'submitted', 'rejected') then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  delete from leave_docs where id = p_doc_id;
  if not exists (select 1 from leave_docs where leave_id = v_leave.id) and v_leave.status = 'submitted' then
    update leaves set status = 'registered', version = version + 1 where id = v_leave.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 운영자: 공가 목록 · 서류 열람 · 승인/반려 · 취소
-- ---------------------------------------------------------------------------

create or replace function attendance.api_operator_leaves(p_token_hash bytea, p_region_code text, p_from date, p_to date)
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
             'decidedAt', l.decided_at, 'decidedBy', l.decided_by, 'decisionNote', l.decision_note,
             'cancelledAt', l.cancelled_at, 'cancelledBy', l.cancelled_by, 'cancelNote', l.cancel_note, 'version', l.version,
             'docs', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.file_name, 'mime', d.mime,
                                                                   'size', d.size_bytes, 'uploadedAt', d.uploaded_at) order by d.id)
                                 from leave_docs d where d.leave_id = l.id), '[]'::jsonb)
           ) order by l.status <> 'submitted', l.starts_on, co.name, st.name)
      from leaves l
      join enrollments e on e.id = l.enrollment_id
      join students st on st.id = e.student_id
      join courses co on co.id = e.course_id
     where l.region_id = v_region and l.starts_on <= p_to and l.ends_on >= p_from
  ), '[]'::jsonb));
end $$;

-- 서류 내용 (base64). 열람은 변경 이력에 남긴다.
create function attendance.api_operator_leave_doc(p_token_hash bytea, p_doc_id bigint)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op  record;
  v_doc record;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select d.*, l.region_id, l.enrollment_id into v_doc
    from leave_docs d join leaves l on l.id = d.leave_id where d.id = p_doc_id;
  if not found or not operator_owns(v_op.scope, v_op.region_id, v_doc.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, after)
  values (v_doc.region_id, v_op.scope, v_op.operator_name, 'leave.doc_view', 'leave_docs', v_doc.id::text,
          jsonb_build_object('leaveId', v_doc.leave_id, 'file', v_doc.file_name));
  return jsonb_build_object('ok', true, 'name', v_doc.file_name, 'mime', v_doc.mime,
                            'data', encode(v_doc.content, 'base64'));
end $$;

-- 승인(출석 인정) · 반려. 신청·서류 제출·반려 상태에서만. 반려는 사유 필수.
create function attendance.api_operator_leave_decide(
  p_token_hash bytea, p_leave_id bigint, p_decision text, p_note text, p_version int
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
  if p_decision not in ('approved', 'rejected') then
    return jsonb_build_object('ok', false, 'code', 'invalid_status');
  end if;
  if v_before.status not in ('registered', 'submitted', 'rejected') or v_before.status = p_decision then
    return jsonb_build_object('ok', false, 'code', 'already_decided');
  end if;
  if v_before.version <> p_version then
    return jsonb_build_object('ok', false, 'code', 'version_conflict');
  end if;
  if p_decision = 'rejected' and length(trim(coalesce(p_note, ''))) = 0 then
    return jsonb_build_object('ok', false, 'code', 'reason_required');
  end if;

  update leaves
     set status = p_decision, decided_at = now(), decided_by = v_op.operator_name,
         decision_note = nullif(trim(coalesce(p_note, '')), ''), version = version + 1
   where id = v_before.id
  returning * into v_after;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after, reason)
  values (v_before.region_id, v_op.scope, v_op.operator_name,
          case when p_decision = 'approved' then 'leave.approve' else 'leave.reject' end,
          'leaves', v_before.id::text, to_jsonb(v_before), to_jsonb(v_after), nullif(trim(coalesce(p_note, '')), ''));
  return jsonb_build_object('ok', true);
end $$;

-- 운영자 취소: 취소되지 않은 공가는 승인된 것도 취소할 수 있다. 사유 필수.
create or replace function attendance.api_operator_leave_cancel(
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
  if v_before.status = 'cancelled' then
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
-- 출결 일보 (점심시간 제거, 공가 승인 반영)
-- ---------------------------------------------------------------------------

create or replace function attendance.api_operator_report(p_token_hash bytea, p_region_code text, p_date date)
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
                              e.id, co, enrollment_start(e, co),
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

-- 수강 시작일 (누적·출석부 기준)
create function attendance.enrollment_start(p_e attendance.enrollments, p_course attendance.courses)
returns date
language sql stable as $$
  select greatest((p_e.created_at at time zone 'Asia/Seoul')::date,
                  coalesce(p_e.starts_on, date '1900-01-01'), coalesce(p_course.starts_on, date '1900-01-01'))
$$;

-- ---------------------------------------------------------------------------
-- 단위기간 출석부 (과정 전체 또는 교육생 한 명)
-- ---------------------------------------------------------------------------

create function attendance.api_operator_sheet(
  p_token_hash bytea, p_region_code text, p_course_id bigint, p_enrollment_id bigint, p_from date, p_to date
) returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_course courses;
  v_days   date[];
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if p_enrollment_id is not null then
    select co.* into v_course from enrollments e join courses co on co.id = e.course_id
     where e.id = p_enrollment_id and operator_owns(v_op.scope, v_op.region_id, e.region_id);
  else
    v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
    select * into v_course from courses where id = p_course_id and region_id = v_region;
  end if;
  if v_course.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 61 then
    return jsonb_build_object('ok', false, 'code', 'range_too_long');
  end if;

  v_days := array(select class_days(v_course.id, p_from, p_to));

  return jsonb_build_object(
    'ok', true,
    'course', jsonb_build_object('id', v_course.id, 'name', v_course.name, 'startsOn', v_course.starts_on,
                                 'endsOn', v_course.ends_on,
                                 'firstDay', (select min(d.edu_date) from attendance_days d
                                                join enrollments o on o.id = d.enrollment_id
                                               where o.course_id = v_course.id)),
    'from', p_from, 'to', p_to,
    'days', to_jsonb(v_days),
    'students', coalesce((
      select jsonb_agg(jsonb_build_object(
               'enrollmentId', e.id, 'name', st.name, 'trainingStatus', e.training_status, 'statusOn', e.status_on,
               'cells', coalesce((select jsonb_agg(day_cell(e, v_course, dd) order by dd)
                                    from unnest(v_days) dd
                                   where dd >= enrollment_start(e, v_course)), '[]'::jsonb),
               'startIndex', (select count(*) from unnest(v_days) dd where dd < enrollment_start(e, v_course))
             ) order by st.name)
        from enrollments e
        join students st on st.id = e.student_id
       where e.course_id = v_course.id
         and (p_enrollment_id is null or e.id = p_enrollment_id)
         and enrollment_start(e, v_course) <= p_to
         and (e.ends_on is null or e.ends_on >= p_from)
         and not (e.training_status <> 'training' and e.training_status <> 'completed' and e.status_on <= p_from)
         and not (e.training_status = 'completed' and e.status_on < p_from)
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- 출석확인서
-- ---------------------------------------------------------------------------

alter table attendance.regions add column institution_name text not null default '';

create table attendance.certificates (
  code           text primary key,
  enrollment_id  bigint not null references attendance.enrollments (id),
  region_id      smallint not null references attendance.regions (id),
  period_from    date not null,
  period_to      date not null,
  issued_at      timestamptz not null default now(),
  issued_by      text not null,
  summary        jsonb not null
);

create index certificates_enrollment_idx on attendance.certificates (enrollment_id, issued_at desc);

create function attendance.certificate_build(p_enrollment_id bigint, p_from date, p_to date, p_issued_by text)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_e      enrollments;
  v_course courses;
  v_info   record;
  v_days   jsonb := '[]'::jsonb;
  v_day    date;
  v_cell   jsonb;
  v_n      int := 0;
  v_absent int := 0;
  v_leave  int := 0;
  v_late   int := 0;
  v_early  int := 0;
  v_outs   int := 0;
  v_conv   int;
  v_sum    jsonb;
  v_code   text;
begin
  select * into v_e from enrollments where id = p_enrollment_id;
  select * into v_course from courses where id = v_e.course_id;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 or p_to > edu_date_now() then
    return jsonb_build_object('ok', false, 'code', 'invalid_period');
  end if;

  for v_day in select class_days(v_course.id, greatest(p_from, enrollment_start(v_e, v_course)), p_to) loop
    v_cell := day_cell(v_e, v_course, v_day);
    continue when v_cell->>'state' <> 'training' or coalesce((v_cell->>'open')::boolean, false);
    v_n := v_n + 1;
    if (v_cell->>'absent')::boolean then
      v_absent := v_absent + 1;
    else
      v_leave := v_leave + (v_cell->>'leaveAttend')::boolean::int;
      v_late := v_late + (v_cell->>'late')::boolean::int;
      v_early := v_early + (v_cell->>'early')::boolean::int;
      v_outs := v_outs + (v_cell->>'outs')::int;
    end if;
    v_days := v_days || jsonb_build_array(v_cell || jsonb_build_object('date', v_day));
  end loop;
  v_conv := (v_late + v_early + v_outs) / 3;
  v_sum := jsonb_build_object(
    'days', v_n, 'attended', v_n - v_absent, 'absent', v_absent, 'leaveAttend', v_leave,
    'late', v_late, 'early', v_early, 'outs', v_outs, 'converted', v_conv,
    'rate', case when v_n > 0 then round(100.0 * (v_n - v_absent - v_conv) / v_n, 1) end);

  v_code := upper(encode(extensions.gen_random_bytes(5), 'hex'));
  insert into certificates (code, enrollment_id, region_id, period_from, period_to, issued_by, summary)
  values (v_code, v_e.id, v_e.region_id, p_from, p_to, p_issued_by, v_sum);
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, after)
  values (v_e.region_id, case when p_issued_by = '본인' then 'student' else 'operator' end, p_issued_by,
          'certificate.issue', 'certificates', v_code,
          jsonb_build_object('enrollmentId', v_e.id, 'from', p_from, 'to', p_to) || v_sum);

  select st.name as student_name, r.name as region_name, r.institution_name into v_info
    from students st, regions r where st.id = v_e.student_id and r.id = v_e.region_id;

  return jsonb_build_object(
    'ok', true, 'code', v_code, 'issuedAt', now(),
    'name', v_info.student_name, 'course', v_course.name, 'institution', v_info.institution_name,
    'regionName', v_info.region_name,
    'courseStartsOn', coalesce(v_course.starts_on, enrollment_start(v_e, v_course)), 'courseEndsOn', v_course.ends_on,
    'classStart', to_char(v_course.class_start, 'HH24:MI'), 'classEnd', to_char(v_course.class_end, 'HH24:MI'),
    'from', p_from, 'to', p_to, 'days', v_days, 'summary', v_sum);
end $$;

-- 교육생 발급: 교육장 회선이나 출석코드로 확인된 세션만
create function attendance.api_student_certificate(p_token_hash bytea, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  if not (v_s.network_verified or session_code_ok(v_s)) then
    return jsonb_build_object('ok', false, 'code', 'presence_required');
  end if;
  if rate_hit('cert:' || v_s.enrollment_id, true) > 20 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  return certificate_build(v_s.enrollment_id, p_from, p_to, '본인');
end $$;

create function attendance.api_operator_certificate(p_token_hash bytea, p_enrollment_id bigint, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
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
  return certificate_build(v_e.id, p_from, p_to, v_op.operator_name);
end $$;

-- 발급 이력 (교육생별)
create function attendance.api_operator_certificates(p_token_hash bytea, p_enrollment_id bigint)
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
  return jsonb_build_object('ok', true, 'certificates', coalesce((
    select jsonb_agg(jsonb_build_object('code', c.code, 'from', c.period_from, 'to', c.period_to,
                                        'issuedAt', c.issued_at, 'issuedBy', c.issued_by, 'summary', c.summary)
                     order by c.issued_at desc)
      from certificates c where c.enrollment_id = v_e.id
  ), '[]'::jsonb));
end $$;

-- 기관명 (출석확인서에 표시)
create function attendance.api_operator_institutions(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op record;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  return jsonb_build_object('ok', true, 'regions', coalesce((
    select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'institution', r.institution_name) order by r.id)
      from regions r where r.is_active and operator_owns(v_op.scope, v_op.region_id, r.id)
  ), '[]'::jsonb));
end $$;

create function attendance.api_operator_institution_set(p_token_hash bytea, p_region_code text, p_name text)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_before text;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if length(trim(coalesce(p_name, ''))) > 80 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  select institution_name into v_before from regions where id = v_region for update;
  update regions set institution_name = trim(coalesce(p_name, '')) where id = v_region;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_region, v_op.scope, v_op.operator_name, 'institution.set', 'regions', v_region::text,
          jsonb_build_object('institution', v_before), jsonb_build_object('institution', trim(coalesce(p_name, ''))));
  return jsonb_build_object('ok', true);
end $$;

revoke execute on all functions in schema attendance from public;

grant execute on function
  attendance.api_operator_course_hours(bytea, bigint, time, time, int),
  attendance.api_student_leave_doc_add(bytea, bigint, text, text, bytea),
  attendance.api_student_leave_doc_delete(bytea, bigint),
  attendance.api_operator_leave_doc(bytea, bigint),
  attendance.api_operator_leave_decide(bytea, bigint, text, text, int),
  attendance.api_operator_sheet(bytea, text, bigint, bigint, date, date),
  attendance.api_student_certificate(bytea, date, date),
  attendance.api_operator_certificate(bytea, bigint, date, date),
  attendance.api_operator_certificates(bytea, bigint),
  attendance.api_operator_institutions(bytea),
  attendance.api_operator_institution_set(bytea, text, text)
to attendance_app;

commit;
