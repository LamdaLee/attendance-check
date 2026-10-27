-- 공가 종류 정리: 병결 / 면접 / 시험 / 공민권(예비군·민방위·투표 등) / 기타(경조사 포함)
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0009_leave_kinds.sql
--
--   * 병결과 공가(면접·시험·공민권·기타)는 승인되면 똑같이 출석으로 인정한다. 집계만 나눠 보여 준다.
--   * 예전 종류는 옮긴다: 예비군·민방위(reserve) → 공민권(civic), 경조사(family) → 기타(other).

begin;

alter table attendance.leaves drop constraint leaves_kind_check;
update attendance.leaves set kind = 'civic' where kind = 'reserve';
update attendance.leaves set kind = 'other' where kind = 'family';
alter table attendance.leaves
  add constraint leaves_kind_check check (kind in ('sick', 'interview', 'exam', 'civic', 'other'));

create or replace function attendance.api_student_leave(
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
  if p_kind not in ('sick', 'interview', 'exam', 'civic', 'other') or p_part not in ('full', 'partial') then
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

create or replace function attendance.api_operator_leave_create(
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
  if p_kind not in ('sick', 'interview', 'exam', 'civic', 'other') or p_part not in ('full', 'partial') then
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

-- 누적: 승인 공가 출석을 병결과 그 밖의 공가로 나눠 센다
create or replace function attendance.course_tally(p_enrollment_id bigint, p_course attendance.courses, p_from date, p_to date)
returns jsonb
language plpgsql stable as $$
declare
  v_day    date;
  v_j      jsonb;
  v_absent int := 0;
  v_leave  int := 0;
  v_sick   int := 0;
  v_lv     jsonb;
  v_late   int := 0;
  v_early  int := 0;
  v_outs   int := 0;
  v_days   int := 0;
  v_conv   int;
begin
  for v_day in select attendance.class_days(p_course.id, p_from, p_to) loop
    v_days := v_days + 1;
    v_lv := attendance.leave_on(p_enrollment_id, v_day);
    v_j := attendance.day_judge(attendance.day_eval(p_enrollment_id, v_day, p_course), v_lv);
    if (v_j->>'absent')::boolean then
      v_absent := v_absent + 1;
    else
      if (v_j->>'leaveAttend')::boolean then
        if v_lv->>'kind' = 'sick' then v_sick := v_sick + 1; else v_leave := v_leave + 1; end if;
      end if;
      v_late := v_late + (v_j->>'late')::boolean::int;
      v_early := v_early + (v_j->>'early')::boolean::int;
      v_outs := v_outs + (v_j->>'outs')::int;
    end if;
  end loop;
  v_conv := (v_late + v_early + v_outs) / 3;
  return jsonb_build_object(
    'days', v_days, 'absent', v_absent, 'leaveAttend', v_leave + v_sick, 'sickAttend', v_sick, 'otherAttend', v_leave,
    'late', v_late, 'early', v_early, 'outs', v_outs,
    'converted', v_conv, 'totalAbsent', v_absent + v_conv,
    'attended', v_days - v_absent - v_conv,
    'rate', case when v_days > 0 then round(100.0 * (v_days - v_absent - v_conv) / v_days, 1) end
  );
end $$;

-- 출석확인서: 병결·공가 출석을 나눠 적는다
create or replace function attendance.certificate_build(p_enrollment_id bigint, p_from date, p_to date, p_issued_by text)
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
  v_sick   int := 0;
  v_late   int := 0;
  v_early  int := 0;
  v_outs   int := 0;
  v_mins   int := 0;
  v_amins  int := 0;
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
    v_mins := v_mins + coalesce((v_cell->>'minutes')::int, 0);
    if not (v_cell->>'absent')::boolean then v_amins := v_amins + coalesce((v_cell->>'minutes')::int, 0); end if;
    if (v_cell->>'absent')::boolean then
      v_absent := v_absent + 1;
    else
      v_leave := v_leave + (v_cell->>'leaveAttend')::boolean::int;
      if (v_cell->>'leaveAttend')::boolean and v_cell->>'leaveKind' = 'sick' then v_sick := v_sick + 1; end if;
      v_late := v_late + (v_cell->>'late')::boolean::int;
      v_early := v_early + (v_cell->>'early')::boolean::int;
      v_outs := v_outs + (v_cell->>'outs')::int;
    end if;
    v_days := v_days || jsonb_build_array(v_cell || jsonb_build_object('date', v_day));
  end loop;
  v_conv := (v_late + v_early + v_outs) / 3;
  v_sum := jsonb_build_object(
    'days', v_n, 'attended', v_n - v_absent, 'absent', v_absent, 'leaveAttend', v_leave, 'sickAttend', v_sick, 'otherAttend', v_leave - v_sick,
    'late', v_late, 'early', v_early, 'outs', v_outs, 'converted', v_conv,
    'trainingMinutes', v_mins, 'attendedMinutes', v_amins,
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
    'name', v_info.student_name, 'course', coalesce(nullif(v_course.full_name, ''), v_course.name), 'institution', v_info.institution_name,
    'regionName', v_info.region_name,
    'courseStartsOn', coalesce(v_course.starts_on, enrollment_start(v_e, v_course)), 'courseEndsOn', v_course.ends_on,
    'classStart', to_char(v_course.class_start, 'HH24:MI'), 'classEnd', to_char(v_course.class_end, 'HH24:MI'),
    'from', p_from, 'to', p_to, 'days', v_days, 'summary', v_sum);
end $$;

commit;
