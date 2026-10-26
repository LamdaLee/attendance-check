-- DB 함수 검증. dev 시드가 들어간 DB에서 실행하며, 끝나면 모두 되돌린다.
--   psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/tests/attendance_test.sql
-- 실패하면 에러로 멈춘다. 마지막에 'ALL TESTS PASSED' 가 출력되면 통과.

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

do $$ begin perform set_config('test.hmac0123', encode(extensions.hmac('0123', 'dev-only-secret', 'sha256'), 'hex'), false); end $$;

-- 앱 역할로 실행해서 권한까지 확인한다.
set role attendance_app;

do $$
declare
  ok_ip    inet := '127.0.0.1';
  bad_ip   inet := '8.8.8.8';
  hmac0123 text := current_setting('test.hmac0123');
  tok      bytea := '\x01';
  req1     uuid := gen_random_uuid();
  r        jsonb;
begin
  -- A02 · 교육장 정보와 네트워크 판정
  r := attendance.api_campus_info('dev-daejeon-a', ok_ip);
  perform pg_temp.eq('campus ok', r->>'networkOk', 'true');
  r := attendance.api_campus_info('dev-daejeon-a', bad_ip);
  perform pg_temp.eq('campus bad ip', r->>'networkOk', 'false');
  r := attendance.api_campus_info('nope', ok_ip);
  perform pg_temp.eq('campus missing', r->>'code', 'campus_not_found');

  -- F03 · 본인 대조
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생01', hmac0123, bad_ip, tok, 600);
  perform pg_temp.eq('verify bad ip', r->>'code', 'network_denied');
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생01', 'wrong', ok_ip, tok, 600);
  perform pg_temp.eq('verify wrong last4', r->>'code', 'not_found');
  -- A06 · 다른 지역 QR
  r := attendance.api_student_verify('dev-busan-a', '예시학생01', hmac0123, ok_ip, tok, 600);
  perform pg_temp.eq('verify other region', r->>'code', 'network_denied');
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생01', hmac0123, ok_ip, tok, 600);
  perform pg_temp.eq('verify ok', r->>'ok', 'true');
  perform pg_temp.eq('verify name', r->>'studentName', '예시학생01');

  r := attendance.api_student_today(tok);
  perform pg_temp.eq('today status', r->>'status', 'not_in');
  r := attendance.api_student_today('\x99');
  perform pg_temp.eq('today bad token', r->>'code', 'session_expired');

  -- A09 · 순서 검증
  r := attendance.api_student_action(tok, 'go_out', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('go_out before check_in', r->>'code', 'invalid_transition');
  r := attendance.api_student_action(tok, 'check_out', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('check_out before check_in', r->>'code', 'invalid_transition');

  -- A03 · 저장 시점의 IP 재확인
  r := attendance.api_student_action(tok, 'check_in', gen_random_uuid(), bad_ip);
  perform pg_temp.eq('action bad ip', r->>'code', 'network_denied');

  -- A08 · 재시도는 한 건만
  r := attendance.api_student_action(tok, 'check_in', req1, ok_ip);
  perform pg_temp.eq('check_in', r->>'status', 'in_class');
  r := attendance.api_student_action(tok, 'check_in', req1, ok_ip);
  perform pg_temp.eq('check_in replay', r->>'replayed', 'true');
  r := attendance.api_student_action(tok, 'go_out', req1, ok_ip);
  perform pg_temp.eq('request id reuse', r->>'code', 'request_conflict');
  r := attendance.api_student_action(tok, 'check_in', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('double check_in', r->>'code', 'invalid_transition');

  r := attendance.api_student_action(tok, 'go_out', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('go_out', r->>'status', 'out');
  r := attendance.api_student_action(tok, 'check_out', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('check_out while out', r->>'code', 'invalid_transition');
  r := attendance.api_student_action(tok, 'return', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('return', r->>'status', 'in_class');
  r := attendance.api_student_action(tok, 'go_out', gen_random_uuid(), ok_ip);
  r := attendance.api_student_action(tok, 'return', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('second go_out/return', r->>'status', 'in_class');
  r := attendance.api_student_action(tok, 'check_out', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('check_out', r->>'status', 'checked_out');
  r := attendance.api_student_action(tok, 'check_in', gen_random_uuid(), ok_ip);
  perform pg_temp.eq('re-check_in after check_out', r->>'code', 'invalid_transition');

  r := attendance.api_student_today(tok);
  perform pg_temp.eq('today events', jsonb_array_length(r->'events'), 6);

  -- 세션 해제
  perform attendance.api_session_revoke(tok);
  r := attendance.api_student_today(tok);
  perform pg_temp.eq('revoked session', r->>'code', 'session_expired');
end $$;

-- 앱 역할은 테이블을 직접 읽거나 쓸 수 없다.
do $$
begin
  begin
    perform 1 from attendance.attendance_events;
    raise exception 'FAIL app role can read attendance_events';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into attendance.attendance_events default values;
    raise exception 'FAIL app role can insert attendance_events';
  exception when insufficient_privilege then null;
  end;
  begin
    perform attendance.match_network(1, '127.0.0.1');
    raise exception 'FAIL app role can call internal helper';
  exception when insufficient_privilege then null;
  end;
end $$;

-- 운영자
do $$
declare
  ok_ip  inet := '127.0.0.1';
  op_dj  bytea := '\x10';
  op_bs  bytea := '\x11';
  op_sp  bytea := '\x12';
  r      jsonb;
  dj_campus bigint;
  net1 jsonb;
  net2 jsonb;
begin
  r := attendance.api_operator_login('daejeon', 'wrong', '예시 운영자', ok_ip, op_dj, 3600);
  perform pg_temp.eq('login wrong', r->>'code', 'invalid_credentials');
  r := attendance.api_operator_login('daejeon', 'daejeon-dev', '', ok_ip, op_dj, 3600);
  perform pg_temp.eq('login no name', r->>'code', 'name_required');
  r := attendance.api_operator_login('daejeon', 'daejeon-dev', '예시 운영자', ok_ip, op_dj, 3600);
  perform pg_temp.eq('login daejeon', r->>'scope', 'region');
  r := attendance.api_operator_login('busan', 'busan-dev', '부산 운영자', ok_ip, op_bs, 3600);
  perform pg_temp.eq('login busan', r->>'regionCode', 'busan');
  r := attendance.api_operator_login('super', 'super-dev', '총괄', ok_ip, op_sp, 3600);
  perform pg_temp.eq('login super', r->>'scope', 'super');

  r := attendance.api_operator_me(op_dj);
  perform pg_temp.eq('me regions', jsonb_array_length(r->'regions'), 1);
  r := attendance.api_operator_me(op_sp);
  perform pg_temp.eq('super regions', jsonb_array_length(r->'regions'), 3);

  -- A05 · 다른 지역 요청 거부
  r := attendance.api_operator_daily(op_dj, 'busan', (now() at time zone 'Asia/Seoul')::date);
  perform pg_temp.eq('daily other region', r->>'code', 'forbidden');
  r := attendance.api_operator_daily(op_dj, null, (now() at time zone 'Asia/Seoul')::date);
  perform pg_temp.eq('daily own rows', jsonb_array_length(r->'rows'), 4);
  r := attendance.api_operator_daily(op_sp, 'daejeon', (now() at time zone 'Asia/Seoul')::date);
  perform pg_temp.eq('daily super', jsonb_array_length(r->'rows'), 4);
  r := attendance.api_operator_daily(op_sp, 'nowhere', (now() at time zone 'Asia/Seoul')::date);
  perform pg_temp.eq('daily super unknown', r->>'code', 'forbidden');

  r := attendance.api_operator_networks(op_dj, null);
  dj_campus := (r->'campuses'->0->>'id')::bigint;
  net1 := r->'campuses'->0->'networks'->0;
  net2 := r->'campuses'->0->'networks'->1;
  perform pg_temp.eq('networks count', jsonb_array_length(r->'campuses'->0->'networks'), 2);

  -- 다른 지역 교육장에 등록 시도
  r := attendance.api_operator_network_save(op_bs, null, dj_campus, 'x', '198.51.100.7/32', 'testing', null, null, null, null, false);
  perform pg_temp.eq('save other region campus', r->>'code', 'not_found');
  r := attendance.api_operator_network_save(op_bs, (net1->>'id')::bigint, null, 'x', '198.51.100.7/32', 'paused', null, null, 'test', 1, false);
  perform pg_temp.eq('update other region network', r->>'code', 'not_found');

  -- 형식·범위·중복
  r := attendance.api_operator_network_save(op_dj, null, dj_campus, '전체', '0.0.0.0/0', 'testing', null, null, null, null, false);
  perform pg_temp.eq('range too wide', r->>'code', 'range_too_wide');
  r := attendance.api_operator_network_save(op_dj, null, dj_campus, '중복', '127.0.0.1/32', 'testing', null, null, null, null, false);
  perform pg_temp.eq('duplicate', r->>'code', 'duplicate');
  r := attendance.api_operator_network_save(op_dj, null, dj_campus, '본관', '198.51.100.24/32', 'testing', null, null, null, null, false);
  perform pg_temp.eq('create', r->>'ok', 'true');

  -- A12 · 다른 지역과 겹치면 총괄만 활성화
  r := attendance.api_operator_networks(op_bs, null);
  r := attendance.api_operator_network_save(op_bs, null, (r->'campuses'->0->>'id')::bigint, '부산', '198.51.100.0/24', 'active', null, null, null, null, false);
  perform pg_temp.eq('overlap requires super', r->>'code', 'overlap_requires_super');

  -- 변경 사유·버전 충돌
  r := attendance.api_operator_network_save(op_dj, (net1->>'id')::bigint, null, net1->>'label', (net1->>'network')::cidr, 'paused', null, null, '', 1, false);
  perform pg_temp.eq('reason required', r->>'code', 'reason_required');
  r := attendance.api_operator_network_save(op_dj, (net1->>'id')::bigint, null, net1->>'label', (net1->>'network')::cidr, 'paused', null, null, '테스트', 99, false);
  perform pg_temp.eq('version conflict', r->>'code', 'version_conflict');

  -- A11 · 마지막 활성 주소
  r := attendance.api_operator_network_save(op_dj, (net1->>'id')::bigint, null, net1->>'label', (net1->>'network')::cidr, 'paused', null, null, '테스트', 1, false);
  perform pg_temp.eq('pause first', r->>'ok', 'true');
  r := attendance.api_operator_network_save(op_dj, (net2->>'id')::bigint, null, net2->>'label', (net2->>'network')::cidr, 'deleted', null, null, '테스트', 1, false);
  perform pg_temp.eq('last active warning', r->>'code', 'last_active_network');
  r := attendance.api_operator_network_save(op_dj, (net2->>'id')::bigint, null, net2->>'label', (net2->>'network')::cidr, 'deleted', null, null, '테스트', 1, true);
  perform pg_temp.eq('last active confirmed', r->>'ok', 'true');

  -- 허용 주소가 0개면 학생 입력 차단
  r := attendance.api_campus_info('dev-daejeon-a', ok_ip);
  perform pg_temp.eq('no active network', r->>'networkOk', 'false');
end $$;

reset role;

-- 감사 기록과 원본 보존
do $$
begin
  perform pg_temp.eq('audit rows', (select count(*) from attendance.audit_logs), 3::bigint);
  begin
    update attendance.attendance_events set action = 'check_in';
    raise exception 'FAIL events are mutable';
  exception when raise_exception then
    if sqlerrm not like '%append-only%' then raise; end if;
  end;
end $$;

-- A07 · 같은 이름·뒷자리 중복은 자동 선택하지 않음
do $$
declare
  r jsonb;
begin
  update attendance.allowed_networks set status = 'active' where network = '127.0.0.1/32';
  insert into attendance.enrollments (student_id, region_id, course_id, name_key, last4_hmac)
  select student_id, region_id, course_id, name_key, last4_hmac
    from attendance.enrollments where name_key = '예시학생02';
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생02',
         encode(extensions.hmac('4567', 'dev-only-secret', 'sha256'), 'hex'), '127.0.0.1', '\x20', 600);
  perform pg_temp.eq('ambiguous', r->>'code', 'ambiguous');
end $$;

rollback;
\echo 'ALL TESTS PASSED'
