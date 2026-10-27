-- 0002·0003 기능 검증: 정정, 명단, 누락 확인, 변경 이력, 내보내기, 총괄 현황, 사전 알림
-- dev 시드가 들어간 DB에서 실행하며, 끝나면 모두 되돌린다.
--   psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/tests/screens_test.sql

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

-- 준비: 어제 예시학생01 은 입실만 하고 퇴실 없음, 같은 AX 과정 예시학생03 은 기록 없음
do $$
declare
  y    date := (now() at time zone 'Asia/Seoul')::date - 1;
  e1   bigint := (select id from attendance.enrollments where name_key = '예시학생01');
  net  attendance.allowed_networks := (select n from attendance.allowed_networks n where network = '127.0.0.1/32');
  at1  timestamptz := (y + time '09:00') at time zone 'Asia/Seoul';
begin
  update attendance.enrollments set created_at = now() - interval '30 days';
  insert into attendance.attendance_events (enrollment_id, region_id, campus_id, action, occurred_at, edu_date,
                                            client_ip, network_id, network_version, request_id)
  values (e1, (select region_id from attendance.campuses where id = net.campus_id), net.campus_id, 'check_in', at1, y, '127.0.0.1', net.id, net.version, gen_random_uuid());
  insert into attendance.attendance_days (enrollment_id, edu_date, region_id, status, first_check_in_at,
                                          last_event_at, last_action, version)
  values (e1, y, (select region_id from attendance.campuses where id = net.campus_id), 'in_class', at1, at1, 'check_in', 1);

  perform set_config('t.y', y::text, false);
  perform set_config('t.e1', e1::text, false);
  perform set_config('t.e2', (select id from attendance.enrollments where name_key = '예시학생02')::text, false);
  perform set_config('t.e3', (select id from attendance.enrollments where name_key = '예시학생03')::text, false);
  perform set_config('t.at1', to_jsonb(at1)::text, false);
  perform set_config('t.h0123', encode(extensions.hmac('0123', 'dev-only-secret', 'sha256'), 'hex'), false);
  perform set_config('t.h8901', encode(extensions.hmac('8901', 'dev-only-secret', 'sha256'), 'hex'), false);
end $$;

set role attendance_app;

-- 사전 알림 · 교육장 밖 확인
do $$
declare
  stu   bytea := '\x40';
  today date := (now() at time zone 'Asia/Seoul')::date;
  r     jsonb;
  nid   bigint;
begin
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생01', current_setting('t.h0123'), '8.8.8.8', stu, 600);
  perform pg_temp.eq('off-network verify', r->>'networkVerified', 'false');

  r := attendance.api_student_notice(stu, today, 'late', '10:30', '병원 진료 후 도착');
  perform pg_temp.eq('notice late', r->>'ok', 'true');
  r := attendance.api_student_notice(stu, today, 'late', '11:00', '다시');
  perform pg_temp.eq('notice duplicate', r->>'code', 'already_noticed');
  r := attendance.api_student_notice(stu, today + 1, 'absent', '10:00', '예비군');
  perform pg_temp.eq('absent with time', r->>'code', 'invalid_input');
  r := attendance.api_student_notice(stu, today + 20, 'absent', null, '먼 날짜');
  perform pg_temp.eq('notice too far', r->>'code', 'invalid_notice_date');
  r := attendance.api_student_notice(stu, today - 1, 'absent', null, '지난 날짜');
  perform pg_temp.eq('notice past', r->>'code', 'invalid_notice_date');
  r := attendance.api_student_notice(stu, today + 2, 'early_leave', '15:00', '면접');
  perform pg_temp.eq('notice early leave', r->>'ok', 'true');

  r := attendance.api_student_notices(stu);
  perform pg_temp.eq('notices listed', jsonb_array_length(r->'notices'), 2);
  nid := (r->'notices'->0->>'id')::bigint;  -- 가장 먼 날짜(조퇴)
  r := attendance.api_student_notice_cancel(stu, nid);
  perform pg_temp.eq('notice cancel', r->>'ok', 'true');
  r := attendance.api_student_notice_cancel(stu, nid);
  perform pg_temp.eq('notice cancel twice', r->>'code', 'not_found');

  -- 정정 요청도 교육장 밖에서 가능
  r := attendance.api_student_correction_request(stu, current_setting('t.y')::date, '어제 퇴실 체크를 못 했습니다');
  perform pg_temp.eq('correction request', r->>'ok', 'true');
  r := attendance.api_student_correction_request(stu, current_setting('t.y')::date, '한 번 더');
  perform pg_temp.eq('correction request duplicate', r->>'code', 'already_pending');
  r := attendance.api_student_correction_request(stu, today + 1, '미래');
  perform pg_temp.eq('correction request future', r->>'code', 'invalid_date');
  r := attendance.api_student_correction_request(stu, current_setting('t.y')::date - 1, '그제 기록 확인 부탁');
  perform pg_temp.eq('second request', r->>'ok', 'true');
  r := attendance.api_student_corrections(stu);
  perform pg_temp.eq('student requests', jsonb_array_length(r->'requests'), 2);
end $$;

-- 운영자: 정정
do $$
declare
  dj    bytea := '\x50';
  bs    bytea := '\x51';
  sp    bytea := '\x52';
  e1    bigint := current_setting('t.e1')::bigint;
  y     date := current_setting('t.y')::date;
  at1   jsonb := current_setting('t.at1')::jsonb;
  out1  text := to_jsonb((y + time '18:00') at time zone 'Asia/Seoul') #>> '{}';
  r     jsonb;
  req   bigint;
  req2  bigint;
  ver   int;
begin
  perform attendance.api_operator_login('daejeon', 'daejeon-dev', '대전 담당', '127.0.0.1', dj, 3600);
  perform attendance.api_operator_login('busan', 'busan-dev', '부산 담당', '127.0.0.1', bs, 3600);
  perform attendance.api_operator_login('super', 'super-dev', '총괄', '127.0.0.1', sp, 3600);

  r := attendance.api_operator_corrections(dj, null, 'pending');
  perform pg_temp.eq('pending requests', jsonb_array_length(r->'requests'), 2);
  req := (select (x->>'id')::bigint from jsonb_array_elements(r->'requests') x where (x->>'date')::date = y);
  req2 := (select (x->>'id')::bigint from jsonb_array_elements(r->'requests') x where (x->>'date')::date = y - 1);
  r := attendance.api_operator_corrections(bs, null, 'pending');
  perform pg_temp.eq('busan sees none', jsonb_array_length(r->'requests'), 0);

  -- 다른 지역 학생 상세는 거부
  r := attendance.api_operator_day(bs, e1, y);
  perform pg_temp.eq('busan day forbidden', r->>'code', 'not_found');
  r := attendance.api_operator_student(bs, e1, y);
  perform pg_temp.eq('busan student forbidden', r->>'code', 'not_found');

  r := attendance.api_operator_day(dj, e1, y);
  ver := (r->>'version')::int;
  perform pg_temp.eq('day version', ver, 1);
  perform pg_temp.eq('day timeline', jsonb_array_length(r->'timeline'), 1);
  perform pg_temp.eq('day requests', jsonb_array_length(r->'requests'), 1);

  -- 검증
  r := attendance.api_operator_correction_save(dj, e1, y,
         jsonb_build_array(jsonb_build_object('action', 'check_out', 'at', out1)), '확인', req, ver);
  perform pg_temp.eq('timeline order', r->>'code', 'timeline_order');
  r := attendance.api_operator_correction_save(dj, e1, y,
         jsonb_build_array(jsonb_build_object('action', 'check_in', 'at', at1),
                           jsonb_build_object('action', 'check_out', 'at', now() + interval '1 day')), '확인', req, ver);
  perform pg_temp.eq('timeline future', r->>'code', 'timeline_time');
  r := attendance.api_operator_correction_save(dj, e1, y,
         jsonb_build_array(jsonb_build_object('action', 'check_in', 'at', at1),
                           jsonb_build_object('action', 'check_out', 'at', out1)), '', req, ver);
  perform pg_temp.eq('basis required', r->>'code', 'reason_required');
  r := attendance.api_operator_correction_save(dj, e1, y,
         jsonb_build_array(jsonb_build_object('action', 'check_in', 'at', at1),
                           jsonb_build_object('action', 'check_out', 'at', out1)), '확인', req, ver + 5);
  perform pg_temp.eq('stale version', r->>'code', 'version_conflict');
  r := attendance.api_operator_correction_save(dj, e1, y,
         jsonb_build_array(jsonb_build_object('action', 'check_in', 'at', at1)), '확인', req, ver);
  perform pg_temp.eq('no change', r->>'code', 'no_change');

  -- 승인
  r := attendance.api_operator_correction_save(dj, e1, y,
         jsonb_build_array(jsonb_build_object('action', 'check_in', 'at', at1),
                           jsonb_build_object('action', 'check_out', 'at', out1)),
         '현장 확인 자료와 대조', req, ver);
  perform pg_temp.eq('approve', r->>'ok', 'true');
  r := attendance.api_operator_correction_save(dj, e1, y,
         jsonb_build_array(jsonb_build_object('action', 'check_in', 'at', at1)), '재처리', req, ver + 1);
  perform pg_temp.eq('approve twice', r->>'code', 'already_decided');

  r := attendance.api_operator_day(dj, e1, y);
  perform pg_temp.eq('original kept', jsonb_array_length(r->'original'), 1);
  perform pg_temp.eq('timeline after', jsonb_array_length(r->'timeline'), 2);
  perform pg_temp.eq('first source', r->'timeline'->0->>'source', 'original');
  perform pg_temp.eq('second source', r->'timeline'->1->>'source', 'corrected');
  perform pg_temp.eq('request approved', r->'requests'->0->>'status', 'approved');

  r := attendance.api_operator_student(dj, e1, y);
  perform pg_temp.eq('month day corrected',
    (select (x->>'corrected')::boolean from jsonb_array_elements(r->'days') x where (x->>'date')::date = y), true);
  perform pg_temp.eq('month day status',
    (select x->>'status' from jsonb_array_elements(r->'days') x where (x->>'date')::date = y), 'checked_out');

  -- 반려
  r := attendance.api_operator_correction_reject(bs, req2, '부산에서 반려');
  perform pg_temp.eq('busan reject', r->>'code', 'not_found');
  r := attendance.api_operator_correction_reject(dj, req2, '');
  perform pg_temp.eq('reject note', r->>'code', 'reason_required');
  r := attendance.api_operator_correction_reject(dj, req2, '해당 날짜 수업 없음');
  perform pg_temp.eq('reject', r->>'ok', 'true');

  -- 누락 확인: 예시학생01 은 정정으로 퇴실 처리되어 빠지고, 예시학생03 은 무기록
  r := attendance.api_operator_issues(dj, null, y - 6, y);
  perform pg_temp.eq('no_checkout gone',
    (select count(*) from jsonb_array_elements(r->'items') x where x->>'kind' = 'no_checkout'), 0::bigint);
  perform pg_temp.eq('no_record e3',
    (select count(*) from jsonb_array_elements(r->'items') x
      where x->>'kind' = 'no_record' and (x->>'enrollmentId')::bigint = current_setting('t.e3')::bigint), 1::bigint);
  r := attendance.api_operator_issues(dj, null, y - 60, y);
  perform pg_temp.eq('issues range', r->>'code', 'range_too_long');

  -- 직권 정정: 예시학생03 어제 입실·퇴실 추가
  r := attendance.api_operator_day(dj, current_setting('t.e3')::bigint, y);
  r := attendance.api_operator_correction_save(dj, current_setting('t.e3')::bigint, y,
         jsonb_build_array(jsonb_build_object('action', 'check_in', 'at', at1),
                           jsonb_build_object('action', 'check_out', 'at', out1)),
         '출석부 확인', null, (r->>'version')::int);
  perform pg_temp.eq('direct correction', r->>'ok', 'true');
  r := attendance.api_operator_issues(dj, null, y - 6, y);
  perform pg_temp.eq('no issues left', jsonb_array_length(r->'items'), 0);

  -- 날짜별 현황의 정정 표시와 사전 알림
  r := attendance.api_operator_daily(dj, null, y);
  perform pg_temp.eq('daily corrected',
    (select count(*) from jsonb_array_elements(r->'rows') x where (x->>'corrected')::boolean), 2::bigint);
  r := attendance.api_operator_daily(dj, null, (now() at time zone 'Asia/Seoul')::date);
  perform pg_temp.eq('daily notice',
    (select x->'notices'->0->>'expectedTime' from jsonb_array_elements(r->'rows') x where x->>'name' = '예시학생01'), '10:30');
  r := attendance.api_operator_notices(dj, null, y, y + 14);
  perform pg_temp.eq('operator notices', jsonb_array_length(r->'notices'), 2);
  r := attendance.api_operator_notices(bs, 'daejeon', y, y + 14);
  perform pg_temp.eq('busan notices forbidden', r->>'code', 'forbidden');
end $$;

-- 운영자: 명단
do $$
declare
  dj  bytea := '\x50';
  bs  bytea := '\x51';
  r   jsonb;
  hx  text := encode(sha256('x'), 'hex');
  hy  text := encode(sha256('y'), 'hex');
begin
  r := attendance.api_operator_roster(dj, null);
  perform pg_temp.eq('roster', jsonb_array_length(r->'students'), 4);
  perform pg_temp.eq('roster hides hmac', (r->'students'->0) ? 'last4_hmac', false);
  r := attendance.api_operator_courses(dj, null);
  perform pg_temp.eq('courses', jsonb_array_length(r->'courses'), 2);

  r := attendance.api_operator_enroll(dj, null, jsonb_build_array(
         jsonb_build_object('line', 2, 'name', '새학생', 'nameKey', '새학생', 'hmac', hx, 'course', 'AX'),
         jsonb_build_object('line', 3, 'name', '새 학생', 'nameKey', '새학생', 'hmac', hx, 'course', 'SF'),
         jsonb_build_object('line', 4, 'name', '예시학생03', 'nameKey', '예시학생03', 'hmac', current_setting('t.h8901'), 'course', 'AX'),
         jsonb_build_object('line', 5, 'name', '없는과정', 'nameKey', '없는과정', 'hmac', hy, 'course', 'ZZ')
       ), true);
  perform pg_temp.eq('enroll errors', (r->>'errors')::int, 3);
  perform pg_temp.eq('enroll not applied', r->>'applied', 'false');
  perform pg_temp.eq('dup in file', r->'rows'->1->>'error', 'duplicate_in_file:2');
  perform pg_temp.eq('dup existing', r->'rows'->2->>'error', 'duplicate_match');
  perform pg_temp.eq('bad course', r->'rows'->3->>'error', 'course_not_found');

  r := attendance.api_operator_enroll(dj, null, jsonb_build_array(
         jsonb_build_object('line', 1, 'name', '새학생', 'nameKey', '새학생', 'hmac', hx, 'course', 'AX')), false);
  perform pg_temp.eq('enroll preview', r->>'applied', 'false');
  r := attendance.api_operator_enroll(dj, null, jsonb_build_array(
         jsonb_build_object('line', 1, 'name', '새학생', 'nameKey', '새학생', 'hmac', hx, 'course', 'AX')), true);
  perform pg_temp.eq('enroll apply', r->>'applied', 'true');
  r := attendance.api_operator_roster(dj, null);
  perform pg_temp.eq('roster after', jsonb_array_length(r->'students'), 5);

  r := attendance.api_operator_enrollment_update(dj, current_setting('t.e2')::bigint, 'paused', null, null, '휴학');
  perform pg_temp.eq('pause', r->>'ok', 'true');
  r := attendance.api_operator_enrollment_update(bs, current_setting('t.e2')::bigint, 'active', null, null, '부산');
  perform pg_temp.eq('busan update forbidden', r->>'code', 'not_found');
  r := attendance.api_operator_enrollment_update(dj, current_setting('t.e2')::bigint, 'active', null, null, '');
  perform pg_temp.eq('update reason', r->>'code', 'reason_required');
  -- 예시학생03 의 뒷자리를 다른 학생과 같게 바꿔도, 이름이 다르면 중복이 아니다
  r := attendance.api_operator_enrollment_update(dj, current_setting('t.e3')::bigint, 'active', null, hy, '번호 변경');
  perform pg_temp.eq('last4 change', r->>'ok', 'true');
end $$;

-- 운영자: 변경 이력 · 내보내기 · 총괄 현황
do $$
declare
  dj  bytea := '\x50';
  bs  bytea := '\x51';
  sp  bytea := '\x52';
  y   date := current_setting('t.y')::date;
  r   jsonb;
begin
  r := attendance.api_operator_export(dj, null, y - 3, y);
  perform pg_temp.eq('export rows', jsonb_array_length(r->'rows'), 2);
  r := attendance.api_operator_export(dj, null, y - 40, y);
  perform pg_temp.eq('export range', r->>'code', 'range_too_long');

  r := attendance.api_operator_audit(dj, null, null, 100);
  perform pg_temp.eq('audit actions',
    (select count(distinct x->>'action') from jsonb_array_elements(r->'items') x
      where x->>'action' in ('correction.approve', 'correction.direct', 'correction.reject',
                             'students.import', 'enrollment.update', 'export.csv')), 6::bigint);
  perform pg_temp.eq('audit hides hmac',
    (select count(*) from jsonb_array_elements(r->'items') x where (x->'before') ? 'last4_hmac'), 0::bigint);
  r := attendance.api_operator_audit(bs, null, null, 100);
  perform pg_temp.eq('busan audit', jsonb_array_length(r->'items'), 0);
  r := attendance.api_operator_audit(sp, null, null, 100);
  perform pg_temp.eq('super audit all', jsonb_array_length(r->'items') >= 7, true);

  r := attendance.api_operator_overview(dj, y);
  perform pg_temp.eq('overview region forbidden', r->>'code', 'forbidden');
  r := attendance.api_operator_overview(sp, y);
  perform pg_temp.eq('overview regions', jsonb_array_length(r->'regions'), 3);
  perform pg_temp.eq('overview daejeon checked_out',
    (select (x->'counts'->>'checked_out')::int from jsonb_array_elements(r->'regions') x where x->>'code' = 'daejeon'), 2);
end $$;

reset role;
rollback;
\echo 'SCREENS TESTS PASSED'
