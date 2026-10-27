-- 0005·0006 기능 검증: 훈련 상태, 공가(서류·승인), 출결 일보, 사유, 과정 시간, 단위기간 출석부, 출석확인서
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

-- 준비: 기록 넣기 도우미 (원본 이벤트 + 하루 요약)
create function pg_temp.add_day(p_name text, p_date date, p_actions text[], p_times time[]) returns void
language plpgsql as $$
declare
  net  attendance.allowed_networks := (select n from attendance.allowed_networks n where network = '127.0.0.1/32');
  reg  smallint := (select region_id from attendance.campuses where id = net.campus_id);
  e    bigint := (select id from attendance.enrollments where name_key = p_name);
  st   text := 'not_in';
  v_at timestamptz;
  v_first timestamptz;
  v_out timestamptz;
begin
  for i in 1..array_length(p_actions, 1) loop
    v_at := (p_date + p_times[i]) at time zone 'Asia/Seoul';
    insert into attendance.attendance_events (enrollment_id, region_id, campus_id, action, occurred_at, edu_date,
                                              client_ip, network_id, network_version, request_id)
    values (e, reg, net.campus_id, p_actions[i], v_at, p_date, '127.0.0.1', net.id, net.version, gen_random_uuid());
    st := attendance.next_status(st, p_actions[i]);
    if p_actions[i] = 'check_in' then v_first := coalesce(v_first, v_at); end if;
    if p_actions[i] = 'check_out' then v_out := v_at; end if;
  end loop;
  insert into attendance.attendance_days (enrollment_id, edu_date, region_id, status, first_check_in_at,
                                          last_check_out_at, last_event_at, last_action, version)
  values (e, p_date, reg, st, v_first, v_out, v_at, p_actions[array_length(p_actions, 1)], array_length(p_actions, 1));
end $$;

-- 2주 전 월~금, 교육 09:00~18:00 · 09:10 부터 지각
--   예시학생01(AX) 월 09:20 지각 / 화 09:15 지각 / 수 14:00~15:00 외출 / 목 09:00~12:30 (50% 미만 → 결석) / 금 정상
--                  → 누적 지각 2 + 외출 1 = 3 → 결석 1회 환산, 실결석 1 → 합계 2
--   예시학생03(AX) 월 09:00~16:00 조퇴 / 금 12:10~12:50 외출
--   예시학생04(SF) 월 09:09:59 입실 → 지각 아님
--   예시학생02(SF) 기록 없음 → 결석
do $$
declare
  w   date := date_trunc('week', now() at time zone 'Asia/Seoul')::date - 14;
  io  text[] := array['check_in', 'check_out'];
begin
  update attendance.enrollments set created_at = now() - interval '40 days';
  perform pg_temp.add_day('예시학생01', w,     io, array[time '09:20', time '18:00']);
  perform pg_temp.add_day('예시학생01', w + 1, io, array[time '09:15', time '18:00']);
  perform pg_temp.add_day('예시학생01', w + 2, array['check_in', 'go_out', 'return', 'check_out'],
                          array[time '09:00', time '14:00', time '15:00', time '18:00']);
  perform pg_temp.add_day('예시학생01', w + 3, io, array[time '09:00', time '12:30']);
  perform pg_temp.add_day('예시학생01', w + 4, io, array[time '08:55', time '18:00']);
  perform pg_temp.add_day('예시학생03', w,     io, array[time '09:00', time '16:00']);
  perform pg_temp.add_day('예시학생03', w + 4, array['check_in', 'go_out', 'return', 'check_out'],
                          array[time '09:00', time '12:10', time '12:50', time '18:00']);
  perform pg_temp.add_day('예시학생04', w,     io, array[time '09:09:59', time '18:00']);

  perform set_config('t.w', w::text, false);
  perform set_config('t.y', ((now() at time zone 'Asia/Seoul')::date - 1)::text, false);
  perform set_config('t.e1', (select id from attendance.enrollments where name_key = '예시학생01')::text, false);
  perform set_config('t.e2', (select id from attendance.enrollments where name_key = '예시학생02')::text, false);
  perform set_config('t.e3', (select id from attendance.enrollments where name_key = '예시학생03')::text, false);
  perform set_config('t.e4', (select id from attendance.enrollments where name_key = '예시학생04')::text, false);
  perform set_config('t.ax', (select id from attendance.courses where name = 'AX' and region_id =
                              (select id from attendance.regions where code = 'daejeon'))::text, false);
  perform set_config('t.h8901', encode(extensions.hmac('8901', 'dev-only-secret', 'sha256'), 'hex'), false);
  perform set_config('t.h0123', encode(extensions.hmac('0123', 'dev-only-secret', 'sha256'), 'hex'), false);
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
  w     date := current_setting('t.w')::date;
  today date := (now() at time zone 'Asia/Seoul')::date;
  e1    bigint := current_setting('t.e1')::bigint;
  e2    bigint := current_setting('t.e2')::bigint;
  e3    bigint := current_setting('t.e3')::bigint;
  e4    bigint := current_setting('t.e4')::bigint;
  r     jsonb;
  row   jsonb;
  lid   bigint;
  lid2  bigint;
  lid3  bigint;
  ver   int;
  doc   bigint;
  stu1  bytea := '\x93';
  ax    bigint := current_setting('t.ax')::bigint;
begin
  perform attendance.api_operator_login('daejeon', 'daejeon-dev', '대전 담당', '127.0.0.1', dj, 3600);
  perform attendance.api_operator_login('busan', 'busan-dev', '부산 담당', '127.0.0.1', bs, 3600);

  -- 일보: 지각 · 조퇴 · 결석 판정 (월요일)
  r := attendance.api_operator_report(dj, null, w);
  perform pg_temp.eq('report rows', jsonb_array_length(r->'rows'), 4);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('e1 late', row->'judge'->>'late', 'true');
  perform pg_temp.eq('e1 not early', row->'judge'->>'early', 'false');
  perform pg_temp.eq('e1 attended', row->'eval'->>'attendedMinutes', '520');
  perform pg_temp.eq('class minutes', row->'eval'->>'classMinutes', '540');
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e3;
  perform pg_temp.eq('e3 early', row->'judge'->>'early', 'true');
  perform pg_temp.eq('e3 not late', row->'judge'->>'late', 'false');
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e4;
  perform pg_temp.eq('e4 within grace', row->'judge'->>'late', 'false');
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('e2 absent', row->'judge'->>'absent', 'true');
  perform pg_temp.eq('e2 training', row->>'state', 'training');
  r := attendance.api_operator_report(bs, 'daejeon', w);
  perform pg_temp.eq('busan report forbidden', r->>'code', 'forbidden');

  -- 수요일 외출 1회 / 목요일 50% 미만 → 결석, 조퇴 아님 / 금요일 외출 1회
  r := attendance.api_operator_report(dj, null, w + 2);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('e1 out', row->'judge'->>'outs', '1');
  r := attendance.api_operator_report(dj, null, w + 3);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('e1 insufficient', row->'judge'->>'insufficient', 'true');
  perform pg_temp.eq('e1 insufficient absent', row->'judge'->>'absent', 'true');
  perform pg_temp.eq('e1 insufficient not early', row->'judge'->>'early', 'false');
  r := attendance.api_operator_report(dj, null, w + 4);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e3;
  perform pg_temp.eq('e3 out', row->'judge'->>'outs', '1');

  -- 누적 (금요일까지): 예시학생01 지각 2 + 외출 1 → 환산 1, 실결석 1 → 합계 2
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('tally late', row->'tally'->>'late', '2');
  perform pg_temp.eq('tally outs', row->'tally'->>'outs', '1');
  perform pg_temp.eq('tally absent', row->'tally'->>'absent', '1');
  perform pg_temp.eq('tally converted', row->'tally'->>'converted', '1');
  perform pg_temp.eq('tally total', row->'tally'->>'totalAbsent', '2');
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('e2 tally absent', row->'tally'->>'absent', '1');  -- SF 수업일(기록이 있는 평일)은 월요일 하루

  -- 지각 기준 변경: AX 를 시작 후 30분부터 지각으로 → 예시학생01(09:20) 지각 아님
  r := attendance.api_operator_course_hours(dj, current_setting('t.ax')::bigint, '09:00', '18:00', 30);
  perform pg_temp.eq('hours save', r->>'ok', 'true');
  r := attendance.api_operator_course_hours(dj, current_setting('t.ax')::bigint, '18:00', '09:00', 10);
  perform pg_temp.eq('hours invalid', r->>'code', 'invalid_hours');
  r := attendance.api_operator_course_hours(dj, current_setting('t.ax')::bigint, '09:00', '18:00', 500);
  perform pg_temp.eq('grace invalid', r->>'code', 'invalid_hours');
  r := attendance.api_operator_course_hours(bs, current_setting('t.ax')::bigint, '09:00', '18:00', 10);
  perform pg_temp.eq('hours busan', r->>'code', 'not_found');
  r := attendance.api_operator_report(dj, null, w);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('e1 not late after hours', row->'judge'->>'late', 'false');
  perform attendance.api_operator_course_hours(dj, current_setting('t.ax')::bigint, '09:00', '18:00', 10);

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

  -- 일보에 공가 표시 (등록 즉시)
  r := attendance.api_operator_report(dj, null, y);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('e2 leave registered', row->'leave'->>'status', 'registered');

  -- 운영자: 목록, 취소
  r := attendance.api_operator_leaves(dj, null, y, today + 7);
  perform pg_temp.eq('op leaves', jsonb_array_length(r->'leaves'), 2);
  r := attendance.api_operator_leaves(bs, null, y, today + 7);
  perform pg_temp.eq('busan leaves', jsonb_array_length(r->'leaves'), 0);
  r := attendance.api_operator_leave_cancel(bs, lid, '취소', 1);
  perform pg_temp.eq('busan cancel', r->>'code', 'not_found');
  r := attendance.api_operator_leave_cancel(dj, lid, '', 1);
  perform pg_temp.eq('cancel needs note', r->>'code', 'reason_required');
  r := attendance.api_operator_leave_cancel(dj, lid, '날짜 착오', 9);
  perform pg_temp.eq('cancel version', r->>'code', 'version_conflict');
  r := attendance.api_operator_leave_cancel(dj, lid2, '이미 취소', 2);
  perform pg_temp.eq('cancelled is final', r->>'code', 'already_decided');

  -- 운영자 등록
  r := attendance.api_operator_leave_create(dj, e3, y, y, 'interview', 'partial', '취업 면접');
  perform pg_temp.eq('op leave create', r->>'ok', 'true');
  r := attendance.api_operator_leave_create(dj, e3, y, y, 'sick', 'full', '중복');
  perform pg_temp.eq('op leave overlap', r->>'code', 'leave_overlap');
  r := attendance.api_operator_leave_create(bs, e3, today, today, 'interview', 'partial', '취업 면접');
  perform pg_temp.eq('busan leave create', r->>'code', 'not_found');

  -- 서류 제출 · 승인: 2주 전 월요일 결석한 예시학생02
  r := attendance.api_operator_leave_create(dj, e2, w, w, 'sick', 'full', '병원 진료');
  lid3 := (r->>'id')::bigint;
  r := attendance.api_operator_report(dj, null, w);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('pending leave still absent', row->'judge'->>'absent', 'true');
  perform pg_temp.eq('pending flag', row->'judge'->>'pending', 'true');
  r := attendance.api_student_leave_doc_add(stu, lid3, 'a.exe', 'application/x-msdownload', '\x00');
  perform pg_temp.eq('bad mime', r->>'code', 'invalid_file');
  r := attendance.api_student_leave_doc_add(stu, lid3, '진료확인서.pdf', 'application/pdf', '\x255044462d');
  perform pg_temp.eq('doc add', r->>'ok', 'true');
  doc := (r->>'id')::bigint;
  perform attendance.api_student_leave_doc_add(stu, lid3, '2.png', 'image/png', '\x89504e47');
  r := attendance.api_student_leave_doc_add(stu, lid3, '3.png', 'image/png', '\x89504e47');
  lid2 := (r->>'id')::bigint;  -- 지울 서류
  r := attendance.api_student_leave_doc_add(stu, lid3, '4.png', 'image/png', '\x89504e47');
  perform pg_temp.eq('max 3 docs', r->>'code', 'too_many_files');
  r := attendance.api_student_leave_doc_delete(stu, lid2);
  perform pg_temp.eq('doc delete', r->>'ok', 'true');
  r := attendance.api_student_leaves(stu);
  perform pg_temp.eq('submitted', (select x->>'status' from jsonb_array_elements(r->'leaves') x where (x->>'id')::bigint = lid3), 'submitted');
  r := attendance.api_operator_leaves(dj, null, w, today);
  select x into row from jsonb_array_elements(r->'leaves') x where (x->>'id')::bigint = lid3;
  perform pg_temp.eq('op sees docs', jsonb_array_length(row->'docs'), 2);
  ver := (row->>'version')::int;
  r := attendance.api_operator_leave_doc(bs, doc);
  perform pg_temp.eq('busan doc', r->>'code', 'not_found');
  r := attendance.api_operator_leave_doc(dj, doc);
  perform pg_temp.eq('doc data', r->>'data', encode('\x255044462d'::bytea, 'base64'));
  r := attendance.api_operator_leave_decide(dj, lid3, 'rejected', '', ver);
  perform pg_temp.eq('reject note', r->>'code', 'reason_required');
  r := attendance.api_operator_leave_decide(dj, lid3, 'rejected', '날짜가 다른 서류입니다', ver);
  perform pg_temp.eq('reject', r->>'ok', 'true');
  r := attendance.api_student_leave_doc_add(stu, lid3, '다시.pdf', 'application/pdf', '\x255044462d');
  perform pg_temp.eq('resubmit', r->>'ok', 'true');
  r := attendance.api_operator_leaves(dj, null, w, today);
  ver := (select (x->>'version')::int from jsonb_array_elements(r->'leaves') x where (x->>'id')::bigint = lid3);
  r := attendance.api_operator_leave_decide(dj, lid3, 'approved', null, ver);
  perform pg_temp.eq('approve', r->>'ok', 'true');
  r := attendance.api_student_leave_cancel(stu, lid3);
  perform pg_temp.eq('approved not cancellable', r->>'code', 'not_found');
  r := attendance.api_student_leave_doc_add(stu, lid3, '추가.pdf', 'application/pdf', '\x255044462d');
  perform pg_temp.eq('approved no upload', r->>'code', 'not_found');
  r := attendance.api_operator_report(dj, null, w);
  select x into row from jsonb_array_elements(r->'rows') x where (x->>'enrollmentId')::bigint = e2;
  perform pg_temp.eq('approved leave attends', row->'judge'->>'leaveAttend', 'true');
  perform pg_temp.eq('approved leave not absent', row->'judge'->>'absent', 'false');

  -- 단위기간 출석부
  r := attendance.api_operator_sheet(dj, null, ax, null, w, w + 4);
  perform pg_temp.eq('sheet days', jsonb_array_length(r->'days'), 5);
  select x into row from jsonb_array_elements(r->'students') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('sheet late', row->'cells'->0->>'late', 'true');
  perform pg_temp.eq('sheet absent', row->'cells'->3->>'absent', 'true');
  perform pg_temp.eq('sheet in time', row->'cells'->0->>'in', '09:20');
  r := attendance.api_operator_sheet(dj, null, null, e2, w, w + 4);
  perform pg_temp.eq('personal sheet', jsonb_array_length(r->'students'), 1);
  perform pg_temp.eq('personal leave', r->'students'->0->'cells'->0->>'leaveAttend', 'true');
  r := attendance.api_operator_sheet(bs, null, null, e2, w, w + 4);
  perform pg_temp.eq('busan sheet', r->>'code', 'not_found');
  r := attendance.api_operator_sheet(dj, null, ax, null, w, w + 70);
  perform pg_temp.eq('sheet range', r->>'code', 'range_too_long');

  -- 출석확인서
  r := attendance.api_operator_institution_set(dj, null, '예시 교육기관');
  perform pg_temp.eq('institution', r->>'ok', 'true');
  r := attendance.api_student_certificate(stu, w, w + 4);
  perform pg_temp.eq('cert needs presence', r->>'code', 'presence_required');
  perform attendance.api_student_verify('dev-daejeon-a', '예시학생01', current_setting('t.h0123'), '127.0.0.1', stu1, 600);
  r := attendance.api_student_certificate(stu1, w, today + 1);
  perform pg_temp.eq('cert future', r->>'code', 'invalid_period');
  r := attendance.api_student_certificate(stu1, w, w + 4);
  perform pg_temp.eq('cert ok', r->>'ok', 'true');
  perform pg_temp.eq('cert institution', r->>'institution', '예시 교육기관');
  perform pg_temp.eq('cert days', r->'summary'->>'days', '5');
  perform pg_temp.eq('cert absent', r->'summary'->>'absent', '1');
  perform pg_temp.eq('cert converted', r->'summary'->>'converted', '1');
  perform pg_temp.eq('cert rate', r->'summary'->>'rate', '60.0');
  perform pg_temp.eq('cert code', length(r->>'code'), 10);
  r := attendance.api_operator_certificate(dj, e2, w, w + 4);
  perform pg_temp.eq('op cert leave', r->'summary'->>'leaveAttend', '1');
  perform pg_temp.eq('op cert rate', r->'summary'->>'rate', '100.0');
  r := attendance.api_operator_certificates(dj, e1);
  perform pg_temp.eq('cert history', jsonb_array_length(r->'certificates'), 1);
  r := attendance.api_operator_certificates(bs, e1);
  perform pg_temp.eq('busan cert history', r->>'code', 'not_found');

  -- 병결은 평일 기준 5일까지
  r := attendance.api_operator_leave_create(dj, e4, today + (8 - extract(isodow from today)::int),
                                            today + (12 - extract(isodow from today)::int), 'sick', 'full', '입원');
  perform pg_temp.eq('sick 5 days', r->>'ok', 'true');
  r := attendance.api_operator_leave_create(dj, e4, today + (15 - extract(isodow from today)::int),
                                            today + (15 - extract(isodow from today)::int), 'sick', 'full', '병원');
  perform pg_temp.eq('sick limit', r->>'code', 'sick_limit');
  perform pg_temp.eq('sick used', r->>'used', '5');
  r := attendance.api_operator_leave_create(dj, e4, today + (15 - extract(isodow from today)::int),
                                            today + (15 - extract(isodow from today)::int), 'interview', 'partial', '면접');
  perform pg_temp.eq('other kinds ok', r->>'ok', 'true');

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
    exists (select 1 from jsonb_array_elements(r->'items') x where x->>'action' = 'leave.create'), true);
end $$;

-- 0007: 날짜별 일정 · 수업일 · 훈련시간
do $$
declare
  dj    bytea := '\x80';
  bs    bytea := '\x81';
  w     date := current_setting('t.w')::date;
  ax    bigint := current_setting('t.ax')::bigint;
  e1    bigint := current_setting('t.e1')::bigint;
  e3    bigint := current_setting('t.e3')::bigint;
  r     jsonb;
  row   jsonb;
begin
  -- 시작일이 없을 때는 기록이 있는 평일만 수업일 (월~금 5일)
  r := attendance.api_operator_sheet(dj, null, ax, null, w, w + 4);
  perform pg_temp.eq('legacy days', jsonb_array_length(r->'days'), 5);

  r := attendance.api_operator_course_save(dj, ax, 'LG전자 K뉴딜 아카데미 AX 워크플로우', w, w + 60, '09:00', '18:00', 10, 480, true);
  perform pg_temp.eq('course save', r->>'ok', 'true');
  r := attendance.api_operator_course_save(bs, ax, '', w, w + 60, '09:00', '18:00', 10, 480, true);
  perform pg_temp.eq('course save busan', r->>'code', 'not_found');
  r := attendance.api_operator_course_save(dj, ax, '', w + 5, w, '09:00', '18:00', 10, 480, true);
  perform pg_temp.eq('course save period', r->>'code', 'invalid_period');
  r := attendance.api_operator_course_day_set(dj, ax, w + 2, 'off', null, null, null, '', '휴강');
  perform pg_temp.eq('day off', r->>'ok', 'true');
  r := attendance.api_operator_course_day_set(dj, ax, w + 1, 'class', '08:00', '17:00', 480, '평택 연수원', '');
  perform pg_temp.eq('day class', r->>'ok', 'true');
  r := attendance.api_operator_course_day_set(dj, ax, w + 3, 'class', '17:00', '08:00', 480, '', '');
  perform pg_temp.eq('day invalid', r->>'code', 'invalid_hours');
  r := attendance.api_operator_course_day_set(bs, ax, w + 3, 'off', null, null, null, '', '');
  perform pg_temp.eq('day busan', r->>'code', 'not_found');
  r := attendance.api_operator_course_days(dj, ax);
  perform pg_temp.eq('days listed', jsonb_array_length(r->'days'), 2);

  -- 일정 기준 수업일: 수요일 휴강 → 4일, 기록 없는 날은 결석
  r := attendance.api_operator_sheet(dj, null, ax, null, w, w + 4);
  perform pg_temp.eq('planned days', jsonb_array_length(r->'days'), 4);
  select x into row from jsonb_array_elements(r->'students') x where (x->>'enrollmentId')::bigint = e3;
  perform pg_temp.eq('no record absent', row->'cells'->1->>'absent', 'true');
  select x into row from jsonb_array_elements(r->'students') x where (x->>'enrollmentId')::bigint = e1;
  perform pg_temp.eq('day start', row->'cells'->1->>'start', '08:00');
  perform pg_temp.eq('day place', row->'cells'->1->>'place', '평택 연수원');
  -- 화요일 09:15 입실 → 08:00 시작 기준 지각
  perform pg_temp.eq('late by day schedule', row->'cells'->1->>'late', 'true');

  r := attendance.api_operator_certificate(dj, e1, w, w + 4);
  perform pg_temp.eq('cert course full name', r->>'course', 'LG전자 K뉴딜 아카데미 AX 워크플로우');
  perform pg_temp.eq('cert days planned', r->'summary'->>'days', '4');
  perform pg_temp.eq('cert training minutes', r->'summary'->>'trainingMinutes', '1920');
  perform pg_temp.eq('cert attended minutes', r->'summary'->>'attendedMinutes', '1440');

  r := attendance.api_operator_course_day_set(dj, ax, w + 2, 'clear', null, null, null, '', '');
  r := attendance.api_operator_sheet(dj, null, ax, null, w, w + 4);
  perform pg_temp.eq('cleared off', jsonb_array_length(r->'days'), 5);

  r := attendance.api_operator_course_create(dj, null, 'AX');
  perform pg_temp.eq('course dup', r->>'code', 'duplicate');
  r := attendance.api_operator_course_create(dj, null, '디지털마케팅');
  perform pg_temp.eq('course create', r->>'ok', 'true');

  -- 0008: LMS 바로가기
  r := attendance.api_operator_course_lms(dj, ax, 'javascript:alert(1)');
  perform pg_temp.eq('lms bad url', r->>'code', 'invalid_url');
  r := attendance.api_operator_course_lms(bs, ax, 'https://lms.example.com/attend');
  perform pg_temp.eq('lms busan', r->>'code', 'not_found');
  r := attendance.api_operator_course_lms(dj, ax, 'https://lms.example.com/attend');
  perform pg_temp.eq('lms save', r->>'ok', 'true');
  r := attendance.api_operator_courses(dj, null);
  perform pg_temp.eq('lms listed', (select x->>'lmsUrl' from jsonb_array_elements(r->'courses') x where (x->>'id')::bigint = ax), 'https://lms.example.com/attend');
  perform attendance.api_student_verify('dev-daejeon-a', '예시학생03', current_setting('t.h8901'), '8.8.8.8', '\x94', 600);
  r := attendance.api_student_links('\x94');
  perform pg_temp.eq('student lms link', r->>'lmsUrl', 'https://lms.example.com/attend');
end $$;

reset role;
rollback;
\echo 'REPORT TESTS PASSED'
