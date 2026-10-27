-- 날짜별 교육 일정(평택 입소 주간·휴강), 하루 훈련시간, 과정 관리, 출석확인서 양식 보강
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0007_schedule.sql
--
--   * 과정 기본 시간(class_start~class_end, 하루 훈련시간 training_minutes) 외에 날짜별 일정을 둔다.
--     course_days: kind = 'class'(그 날만 시간이 다름, 예: 평택 러닝센터) 또는 'off'(휴강·공휴일).
--   * 과정에 시작일(starts_on)이 있으면 수업일 = 기간 안의 평일 − 휴강일 + 따로 지정한 수업일.
--     시작일이 없으면 지금처럼 기록이 있는 평일을 수업일로 본다.
--   * 출석확인서: 날짜별 훈련시간, 총 훈련시간·참여시간, 과정 정식 이름(full_name).

begin;

alter table attendance.courses
  add column training_minutes smallint not null default 480 check (training_minutes between 0 and 1440),
  add column full_name text not null default '';

create table attendance.course_days (
  course_id         bigint not null references attendance.courses (id),
  edu_date          date not null,
  kind              text not null check (kind in ('class', 'off')),
  class_start       time,
  class_end         time,
  training_minutes  smallint check (training_minutes between 0 and 1440),
  place             text not null default '',
  note              text not null default '',
  updated_by        text not null,
  updated_at        timestamptz not null default now(),
  primary key (course_id, edu_date),
  check (kind = 'off' or (class_start is not null and class_end is not null and class_start < class_end
                          and training_minutes is not null))
);

-- 그 날의 과정 값 (날짜별 일정이 있으면 시간·훈련시간을 바꾼 복사본)
create function attendance.course_on(p_course attendance.courses, p_date date)
returns attendance.courses
language plpgsql stable as $$
declare
  v_day attendance.course_days;
  v_c   attendance.courses := p_course;
begin
  select * into v_day from attendance.course_days
   where course_id = p_course.id and edu_date = p_date and kind = 'class';
  if found then
    v_c.class_start := v_day.class_start;
    v_c.class_end := v_day.class_end;
    v_c.training_minutes := v_day.training_minutes;
  end if;
  return v_c;
end $$;

create function attendance.course_place(p_course_id bigint, p_date date)
returns text
language sql stable as $$
  select coalesce((select place from attendance.course_days
                    where course_id = p_course_id and edu_date = p_date and kind = 'class'), '')
$$;

-- 수업일. 시작일이 있는 과정은 일정 기준, 없으면 기록 기준. 오늘 이후는 넣지 않는다.
create or replace function attendance.class_days(p_course_id bigint, p_from date, p_to date)
returns setof date
language sql stable as $$
  with c as (select * from attendance.courses where id = p_course_id)
  select g::date
    from c, generate_series(greatest(p_from, c.starts_on),
                            least(p_to, coalesce(c.ends_on, p_to), attendance.edu_date_now()),
                            interval '1 day') g
   where c.starts_on is not null
     and ((extract(isodow from g) <= 5
           and not exists (select 1 from attendance.course_days x
                            where x.course_id = p_course_id and x.edu_date = g::date and x.kind = 'off'))
          or exists (select 1 from attendance.course_days x
                      where x.course_id = p_course_id and x.edu_date = g::date and x.kind = 'class'))
  union
  select d.edu_date
    from c, attendance.attendance_days d
    join attendance.enrollments o on o.id = d.enrollment_id
   where c.starts_on is null
     and o.course_id = p_course_id
     and d.edu_date between p_from and p_to
     and (d.last_event_at is not null or d.corrected)
     and extract(isodow from d.edu_date) <= 5
   order by 1
$$;

-- 하루 평가: 그 날의 교육 시간(course_on)으로 계산한다.
create or replace function attendance.day_eval(p_enrollment_id bigint, p_date date, p_course attendance.courses)
returns jsonb
language plpgsql stable as $$
declare
  v_c        attendance.courses := attendance.course_on(p_course, p_date);
  v_s        timestamptz := (p_date + v_c.class_start) at time zone 'Asia/Seoul';
  v_e        timestamptz := (p_date + v_c.class_end) at time zone 'Asia/Seoul';
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
    'late', v_first is not null and v_first >= v_s + make_interval(mins => v_c.late_after_minutes),
    'early', v_status = 'checked_out' and v_last_out < v_e,
    'outs', v_outs
  );
end $$;

create or replace function attendance.day_cell(p_e attendance.enrollments, p_course attendance.courses, p_date date)
returns jsonb
language plpgsql stable as $$
declare
  v_state text := attendance.training_state(p_e.training_status, p_e.status_on, p_date);
  v_ev    jsonb;
  v_lv    jsonb;
  v_c     attendance.courses := attendance.course_on(p_course, p_date);
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
    'open', p_date = attendance.edu_date_now() and now() < (p_date + v_c.class_end) at time zone 'Asia/Seoul',
    'start', to_char(v_c.class_start, 'HH24:MI'),
    'end', to_char(v_c.class_end, 'HH24:MI'),
    'minutes', v_c.training_minutes,
    'place', attendance.course_place(p_course.id, p_date)
  );
end $$;

-- 출석확인서: 날짜별 훈련시간과 총 훈련·참여시간, 과정 정식 이름
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

-- 출결 일보: 날짜별 교육 시간 반영
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
               'lateAfter', co.late_after_minutes,
               -- 이 날의 교육 시간 (날짜별 일정 반영)
               'dayStart', to_char((course_on(co, p_date)).class_start, 'HH24:MI'),
               'dayEnd', to_char((course_on(co, p_date)).class_end, 'HH24:MI'),
               'dayPlace', course_place(co.id, p_date),
               'dayOff', exists (select 1 from course_days x where x.course_id = co.id and x.edu_date = p_date and x.kind = 'off')
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
                              least(case when p_date < edu_date_now() or now() >= (p_date + (course_on(co, p_date)).class_end) at time zone 'Asia/Seoul'
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

-- ---------------------------------------------------------------------------
-- 과정 관리: 목록 · 날짜별 일정 · 만들기 · 설정
-- ---------------------------------------------------------------------------

create or replace function attendance.api_operator_courses(p_token_hash bytea, p_region_code text)
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
    select jsonb_agg(jsonb_build_object(
             'id', co.id, 'name', co.name, 'fullName', co.full_name, 'isActive', co.is_active,
             'startsOn', co.starts_on, 'endsOn', co.ends_on,
             'classStart', to_char(co.class_start, 'HH24:MI'), 'classEnd', to_char(co.class_end, 'HH24:MI'),
             'lateAfter', co.late_after_minutes, 'trainingMinutes', co.training_minutes,
             'students', (select count(*) from enrollments e where e.course_id = co.id and e.training_status = 'training')
           ) order by co.name)
      from courses co where co.region_id = v_region
  ), '[]'::jsonb));
end $$;

create function attendance.api_operator_course_days(p_token_hash bytea, p_course_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_course courses;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select * into v_course from courses where id = p_course_id;
  if not found or not operator_owns(v_op.scope, v_op.region_id, v_course.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'days', coalesce((
    select jsonb_agg(jsonb_build_object(
             'date', x.edu_date, 'kind', x.kind,
             'start', to_char(x.class_start, 'HH24:MI'), 'end', to_char(x.class_end, 'HH24:MI'),
             'minutes', x.training_minutes, 'place', x.place, 'note', x.note,
             'updatedBy', x.updated_by, 'updatedAt', x.updated_at
           ) order by x.edu_date)
      from course_days x where x.course_id = v_course.id
  ), '[]'::jsonb));
end $$;

create function attendance.api_operator_course_create(p_token_hash bytea, p_region_code text, p_name text)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_id     bigint;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if length(trim(coalesce(p_name, ''))) not between 1 and 40 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if exists (select 1 from courses where region_id = v_region and name = trim(p_name)) then
    return jsonb_build_object('ok', false, 'code', 'duplicate');
  end if;
  insert into courses (region_id, name) values (v_region, trim(p_name)) returning id into v_id;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, after)
  values (v_region, v_op.scope, v_op.operator_name, 'course.create', 'courses', v_id::text,
          jsonb_build_object('name', trim(p_name)));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 과정 설정 (정식 이름, 기간, 기본 교육 시간, 지각 기준, 하루 훈련시간, 사용 여부)
create function attendance.api_operator_course_save(
  p_token_hash bytea, p_course_id bigint, p_full_name text, p_starts_on date, p_ends_on date,
  p_start time, p_end time, p_late_after int, p_training_minutes int, p_active boolean
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_before courses;
  v_after  courses;
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
     or p_training_minutes is null or p_training_minutes not between 0 and 1440 then
    return jsonb_build_object('ok', false, 'code', 'invalid_hours');
  end if;
  if p_starts_on is not null and p_ends_on is not null and p_ends_on < p_starts_on then
    return jsonb_build_object('ok', false, 'code', 'invalid_period');
  end if;
  if length(coalesce(p_full_name, '')) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  update courses
     set full_name = trim(coalesce(p_full_name, '')), starts_on = p_starts_on, ends_on = p_ends_on,
         class_start = p_start, class_end = p_end, late_after_minutes = p_late_after,
         training_minutes = p_training_minutes, is_active = coalesce(p_active, is_active)
   where id = v_before.id
  returning * into v_after;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_before.region_id, v_op.scope, v_op.operator_name, 'course.update', 'courses', v_before.id::text,
          to_jsonb(v_before), to_jsonb(v_after));
  return jsonb_build_object('ok', true);
end $$;

-- 날짜별 일정 저장. p_kind = 'class'(그 날 시간 지정) | 'off'(휴강) | 'clear'(지정 해제)
create function attendance.api_operator_course_day_set(
  p_token_hash bytea, p_course_id bigint, p_date date, p_kind text,
  p_start time, p_end time, p_minutes int, p_place text, p_note text
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_course courses;
  v_before course_days;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select * into v_course from courses where id = p_course_id;
  if not found or not operator_owns(v_op.scope, v_op.region_id, v_course.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if p_date is null or p_kind not in ('class', 'off', 'clear') then
    return jsonb_build_object('ok', false, 'code', 'invalid_input');
  end if;
  if p_kind = 'class' and (p_start is null or p_end is null or p_start >= p_end
                           or p_minutes is null or p_minutes not between 0 and 1440) then
    return jsonb_build_object('ok', false, 'code', 'invalid_hours');
  end if;
  select * into v_before from course_days where course_id = v_course.id and edu_date = p_date for update;

  if p_kind = 'clear' then
    delete from course_days where course_id = v_course.id and edu_date = p_date;
  else
    insert into course_days (course_id, edu_date, kind, class_start, class_end, training_minutes, place, note, updated_by)
    values (v_course.id, p_date, p_kind,
            case when p_kind = 'class' then p_start end, case when p_kind = 'class' then p_end end,
            case when p_kind = 'class' then p_minutes end,
            left(trim(coalesce(p_place, '')), 40), left(trim(coalesce(p_note, '')), 100), v_op.operator_name)
    on conflict (course_id, edu_date) do update
       set kind = excluded.kind, class_start = excluded.class_start, class_end = excluded.class_end,
           training_minutes = excluded.training_minutes, place = excluded.place, note = excluded.note,
           updated_by = excluded.updated_by, updated_at = now();
  end if;

  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_course.region_id, v_op.scope, v_op.operator_name, 'course.day', 'course_days',
          v_course.id::text || ':' || p_date,
          case when v_before.course_id is not null then to_jsonb(v_before) end,
          jsonb_build_object('course', v_course.name, 'date', p_date, 'kind', p_kind,
                             'start', p_start, 'end', p_end, 'minutes', p_minutes, 'place', p_place));
  return jsonb_build_object('ok', true);
end $$;

revoke execute on all functions in schema attendance from public;

grant execute on function
  attendance.api_operator_course_days(bytea, bigint),
  attendance.api_operator_course_create(bytea, text, text),
  attendance.api_operator_course_save(bytea, bigint, text, date, date, time, time, int, int, boolean),
  attendance.api_operator_course_day_set(bytea, bigint, date, text, time, time, int, text, text)
to attendance_app;

commit;
