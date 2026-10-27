-- 0005 기능 검증: 훈련 상태, 공가, 출결 일보, 사유, 과정 시간
-- dev 시드만 들어간 DB에서 실행하며, 끝나면 모두 되돌린다.
--   psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/tests/report_test.sql

\set QUIET on
begin;

create function pg_temp.eq(p_label text, p_actual anyelement, p_expected anyelement) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_label, p_expected, p_actual;
  end if;
end $$;
grant execute on function pg_temp.eq(text, anyelement, anyelement) to attendance_app;

-- 준비: 어제 기준
--   예시학생01(AX) 09:20 입실 · 18:00 퇴실 → 지각
--   예시학생03(AX) 09:00 입실 · 16:00 퇴실 → 조퇴
--   예시학생02(SF) 기록 없음 → 결석 (공가 신청 예정)
--   예시학생04(SF) 09:00 입실 · 18:00 퇴실 → 출석
do $$
declare
  y    date := (now() at time zone 'Asia/Seoul')::date - 1;
  net  attendance.allowed_networks := (select n from attendance.allowed_networks n where network = '127.0.0.1/32');
  reg  smallint := (select region_id from attendance.campuses where id = net.campus_id);
  rec  record;
begin
  update attendance.enrollments set created_at = now() - interval '30 days';
  for rec in select * from (values ('예시학생01', time '09:20', time '18:00'),
                                   ('예시학생03', time '09:00', time '16:00'),
                                   ('예시학생04', time '09:00', time '18:00')) v(n, t_in, t_out) loop
    insert into attendance.attendance_days (enrollment_id, edu_date, region_id, status, first_check_in_at,
                                            last_check_out_at, last_event_at, last_action, version)
    select e.id, y, reg, 'checked_out', (y + rec.t_in) at time zone 'Asia/Seoul', (y + rec.t_out) at time zone 'Asia/Seoul',
           (y + rec.t_out) at time zone 'Asia/Seoul', 'check_out', 2
      from attendance.enrollments e where e.name_key = rec.n;
  end loop;

  perform set_config('t.y', y::text, false);
  perform set_config('t.e1', (select id from attendance.enrollments where name_key = '예시학생01')::text, false);
  perform set_config('t.e2', (select id from attendance.enrollments where name_key = '예시학생02')::text, false);
  perform set_config('t.e3', (select id from attendance.enrollments where name_key = '예시학생03')::text, false);
  perform set_config('t.e4', (select id from attendance.enrollments where name_key = '예시학생04')::text, false);
  perform set_config('t.ax', (select id from attendance.courses where name = 'AX' and region_id = reg)::text, false);
  perform set_config('t.h4567', encode(extensions.hmac('4567', 'dev-only-secret', 'sha256'), 'hex'), false);
  perform set_config('t.h2345', encode(extensions.hmac('2345', 'dev-only-secret', 'sha256'), 'hex'), false);
end $$;

set role attendance_app;

do $$
declare
  dj    bytea := '\x80';
  bs    bytea := '\x81';
  stu   bytea := '\x90';
  stu4  bytea := '\x91';
  y     date := current_setting('t.y')::date;
  today date := (now() at time zone 'Asia/Seoul')::date;
  e1    bigint := current_setting('t.e1')::bigint;
  e2    bigint := current_setting('t.e2')::bigint;
  e3    bigint := current_setting('t.e3')::bigint;
  e4    bigint := current_setting('t.e4')::bigint;
  r     jsonb;
  row   jsonb;
  lid   bigint;
  lid2  bigint;
begin
  perform attendance.api_operator_login('daejeon', 'daejeon-dev', '대전 담당', '127.0.0.1', dj, 3600);
  perform attendance.api_operator_login('busan', 'busan-dev', '부산 담당', '127.0.0.1', bs, 3600);

  -- 일보: 지각 · 조퇴 · 결석 판정
  r := attendance.api_operator_report(dj, null, y);
  perform pg_temp.eq('report rows', jsonb_array_length(r->'rows'), 4);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('e1 late', row->>'late', 'true');
  perform pg_temp.eq('e1 not early', row->>'early', 'false');
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e3;
  perform pg_temp.eq('e3 early', row->>'early', 'true');
  perform pg_temp.eq('e3 not late', row->>'late', 'false');
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('e2 absent', row->>'firstCheckInAt', null);
  perform pg_temp.eq('e2 training', row->>'state', 'training');
  r := attendance.api_operator_report(bs, 'daejeon', y);
  perform pg_temp.eq('busan report forbidden', r->>'code', 'forbidden');

  -- 과정 시간 변경: AX 시작을 09:30 으로 → 예시학생01 지각 아님
  r := attendance.api_operator_course_hours(dj, current_setting('t.ax')::bigint, '09:30', '18:00');
  perform pg_temp.eq('hours save', r->>'ok', 'true');
  r := attendance.api_operator_course_hours(dj, current_setting('t.ax')::bigint, '18:00', '09:00');
  perform pg_temp.eq('hours invalid', r->>'code', 'invalid_hours');
  r := attendance.api_operator_course_hours(bs, current_setting('t.ax')::bigint, '09:00', '18:00');
  perform pg_temp.eq('hours busan', r->>'code', 'not_found');
  r := attendance.api_operator_report(dj, null, y);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('e1 not late after hours', row->>'late', 'false');

  -- 학생 공가 신청 (교육장 밖에서)
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생02', current_setting('t.h4567'), '8.8.8.8', stu, 600);
  perform pg_temp.eq('verify off', r->>'networkVerified', 'false');
  r := attendance.api_student_leave(stu, y, y, 'sick', 'full', '감기 몸살로 병원 진료');
  perform pg_temp.eq('leave create', r->>'ok', 'true');
  lid := (r->>'id')::bigint;
  r := attendance.api_student_leave(stu, y, y + 1, 'interview', 'partial', '면접');
  perform pg_temp.eq('leave overlap', r->>'code', 'leave_overlap');
  r := attendance.api_student_leave(stu, today - 20, today - 20, 'sick', 'full', '오래전');
  perform pg_temp.eq('leave too old', r->>'code', 'invalid_leave_date');
  r := attendance.api_student_leave(stu, today + 1, today + 20, 'reserve', 'full', '긴 기간');
  perform pg_temp.eq('leave too long', r->>'code', 'invalid_leave_date');
  r := attendance.api_student_leave(stu, today + 3, today + 3, 'reserve', 'full', '예비군 훈련');
  lid2 := (r->>'id')::bigint;
  r := attendance.api_student_leaves(stu);
  perform pg_temp.eq('student leaves', jsonb_array_length(r->'leaves'), 2);
  r := attendance.api_student_leave_cancel(stu, lid2);
  perform pg_temp.eq('student cancel', r->>'ok', 'true');

  -- 일보에 서류 대기 공가 표시
  r := attendance.api_operator_report(dj, null, y);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('e2 leave waiting', row->'leave'->>'status', 'waiting_docs');

  -- 운영자: 목록, 서류 확인
  r := attendance.api_operator_leaves(dj, null, y, today + 7);
  perform pg_temp.eq('op leaves', jsonb_array_length(r->'leaves'), 2);
  r := attendance.api_operator_leaves(bs, null, y, today + 7);
  perform pg_temp.eq('busan leaves', jsonb_array_length(r->'leaves'), 0);
  r := attendance.api_operator_leave_decide(bs, lid, 'approved', null, 1);
  perform pg_temp.eq('busan decide', r->>'code', 'not_found');
  r := attendance.api_operator_leave_decide(dj, lid, 'rejected', '', 1);
  perform pg_temp.eq('reject needs note', r->>'code', 'reason_required');
  r := attendance.api_operator_leave_decide(dj, lid, 'approved', null, 9);
  perform pg_temp.eq('decide version', r->>'code', 'version_conflict');
  r := attendance.api_operator_leave_decide(dj, lid, 'approved', '진료확인서 확인', 1);
  perform pg_temp.eq('approve', r->>'ok', 'true');
  r := attendance.api_student_leave_cancel(stu, lid);
  perform pg_temp.eq('student cannot cancel approved', r->>'code', 'not_found');
  r := attendance.api_operator_report(dj, null, y);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('e2 leave approved', row->'leave'->>'status', 'approved');
  r := attendance.api_operator_leave_decide(dj, lid2, 'approved', null, 2);
  perform pg_temp.eq('cancelled is final', r->>'code', 'already_decided');

  -- 운영자 등록: 바로 인정
  r := attendance.api_operator_leave_create(dj, e3, y, y, 'interview', 'partial', '취업 면접', true);
  perform pg_temp.eq('op leave create', r->>'ok', 'true');
  r := attendance.api_operator_leave_create(bs, e3, today, today, 'interview', 'partial', '취업 면접', true);
  perform pg_temp.eq('busan leave create', r->>'code', 'not_found');

  -- 사유
  r := attendance.api_operator_day_note(dj, e2, y, '진료확인서 제출', 0);
  perform pg_temp.eq('note new', r->>'version', '1');
  r := attendance.api_operator_day_note(dj, e2, y, '덮어쓰기', 0);
  perform pg_temp.eq('note conflict', r->>'code', 'version_conflict');
  r := attendance.api_operator_day_note(dj, e2, y, '진료확인서 제출 (10/27)', 1);
  perform pg_temp.eq('note update', r->>'version', '2');
  r := attendance.api_operator_day_note(bs, e2, y, 'x', 2);
  perform pg_temp.eq('note busan', r->>'code', 'not_found');
  r := attendance.api_operator_report(dj, null, y);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('note in report', row->'note'->>'text', '진료확인서 제출 (10/27)');
  r := attendance.api_operator_day_note(dj, e2, y, '', 2);
  perform pg_temp.eq('note delete', r->>'version', '0');

  -- 훈련 상태: 예시학생04 오늘 자로 중도탈락
  r := attendance.api_operator_enrollment_update(dj, e4, 'active', null, null, '개인 사정', 'dropped', null);
  perform pg_temp.eq('dropped needs date', r->>'code', 'status_date_required');
  perform attendance.api_student_verify('dev-daejeon-a', '예시학생04', current_setting('t.h2345'), '127.0.0.1', stu4, 600);
  r := attendance.api_operator_enrollment_update(dj, e4, 'active', null, null, '개인 사정', 'dropped', today);
  perform pg_temp.eq('dropped', r->>'ok', 'true');
  r := attendance.api_student_today(stu4);
  perform pg_temp.eq('dropped session revoked', r->>'code', 'session_expired');
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생04', current_setting('t.h2345'), '127.0.0.1', '\x92', 600);
  perform pg_temp.eq('dropped cannot verify', r->>'code', 'not_found');
  r := attendance.api_operator_roster(dj, null);
  perform pg_temp.eq('roster keeps dropped',
    (select x->>'trainingStatus' from jsonb_array_elements(r->'students') x where (x->>'enrollmentId')::bigint = e4), 'dropped');
  -- 어제 일보에서는 아직 훈련중, 오늘 일보에서는 중도탈락
  r := attendance.api_operator_report(dj, null, y);
  perform pg_temp.eq('yesterday training',
    (select x->>'state' from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e4), 'training');
  r := attendance.api_operator_report(dj, null, today);
  perform pg_temp.eq('today dropped',
    (select x->>'state' from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e4), 'dropped');
  -- 되돌리기: 훈련중으로
  r := attendance.api_operator_enrollment_update(dj, e4, 'ended', null, null, '복귀', 'training', null);
  perform pg_temp.eq('training must be active or paused', r->>'code', 'invalid_status');
  r := attendance.api_operator_enrollment_update(dj, e4, 'active', null, null, '복귀', 'training', null);
  perform pg_temp.eq('back to training', r->>'ok', 'true');

  -- 수료: 수료일 다음 날 일보에는 나오지 않음
  r := attendance.api_operator_enrollment_update(dj, e1, 'active', null, null, '과정 수료', 'completed', y);
  perform pg_temp.eq('completed', r->>'ok', 'true');
  r := attendance.api_operator_report(dj, null, today);
  perform pg_temp.eq('completed hidden next day', jsonb_array_length(r->'rows'), 3);

  r := attendance.api_operator_audit(dj, null, null, 100);
  perform pg_temp.eq('audit has training',
    exists (select 1 from jsonb_array_elements(r->'items') x where x->>'action' = 'enrollment.training'), true);
  perform pg_temp.eq('audit has leave',
    exists (select 1 from jsonb_array_elements(r->'items') x where x->>'action' = 'leave.approved'), true);
end $$;

reset role;
rollback;
\echo 'REPORT TESTS PASSED'
