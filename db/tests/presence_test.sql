-- 0004 기능 검증: 오늘의 출석코드, 막힌 접속, 같은 기기 여러 명 출결
-- dev 시드만 들어간 DB에서 실행하며, 끝나면 모두 되돌린다.
--   psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/tests/presence_test.sql

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

do $$
begin
  perform set_config('t.h0123', encode(extensions.hmac('0123', 'dev-only-secret', 'sha256'), 'hex'), false);
  perform set_config('t.h4567', encode(extensions.hmac('4567', 'dev-only-secret', 'sha256'), 'hex'), false);
  perform set_config('t.campus', (select id from attendance.campuses where qr_code = 'dev-daejeon-a')::text, false);
end $$;

set role attendance_app;

do $$
declare
  dj      bytea := '\x60';
  bs      bytea := '\x61';
  s1      bytea := '\x70';
  s2      bytea := '\x71';
  dev     bytea := '\xd1';
  campus  bigint := current_setting('t.campus')::bigint;
  code    text;
  wrong   text;
  r       jsonb;
begin
  perform attendance.api_operator_login('daejeon', 'daejeon-dev', '대전 담당', '127.0.0.1', dj, 3600);
  perform attendance.api_operator_login('busan', 'busan-dev', '부산 담당', '127.0.0.1', bs, 3600);

  -- 출석코드: 처음에는 꺼져 있음
  r := attendance.api_campus_info('dev-daejeon-a', '8.8.8.8');
  perform pg_temp.eq('code mode off', r->>'codeMode', 'false');
  r := attendance.api_operator_codes(dj, null);
  perform pg_temp.eq('no code yet', r->'campuses'->0->>'code', null);

  -- 다른 지역 운영자는 켤 수 없음
  r := attendance.api_operator_code_set(bs, campus, 'on');
  perform pg_temp.eq('busan cannot set', r->>'code', 'not_found');

  r := attendance.api_operator_code_set(dj, campus, 'on');
  code := r->>'code';
  perform pg_temp.eq('code format', code ~ '^[0-9]{6}$', true);
  wrong := lpad(((code::int + 1) % 1000000)::text, 6, '0');
  r := attendance.api_campus_info('dev-daejeon-a', '8.8.8.8');
  perform pg_temp.eq('code mode on', r->>'codeMode', 'true');

  -- 교육장 밖에서 본인 확인 → 막힌 접속 기록, 기록 안 보임
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생01', current_setting('t.h0123'), '8.8.8.8', s1, 600, dev);
  perform pg_temp.eq('verify off network', r->>'networkVerified', 'false');
  perform pg_temp.eq('verify tells code mode', r->>'codeMode', 'true');
  r := attendance.api_student_today(s1);
  perform pg_temp.eq('no presence yet', r->>'presence', null);
  perform pg_temp.eq('status hidden', r ? 'status', false);
  r := attendance.api_student_action(s1, 'check_in', gen_random_uuid(), '8.8.8.8');
  perform pg_temp.eq('action blocked', r->>'code', 'network_denied');

  -- 출석코드
  r := attendance.api_student_code(s1, wrong, '8.8.8.8');
  perform pg_temp.eq('wrong code', r->>'code', 'invalid_code');
  r := attendance.api_student_code(s1, code, '8.8.8.8');
  perform pg_temp.eq('right code', r->>'ok', 'true');
  r := attendance.api_student_today(s1);
  perform pg_temp.eq('presence code', r->>'presence', 'code');
  perform pg_temp.eq('status shown', r->>'status', 'not_in');
  r := attendance.api_student_action(s1, 'check_in', gen_random_uuid(), '8.8.8.8');
  perform pg_temp.eq('check_in by code', r->>'method', 'code');

  -- 같은 기기로 두 번째 교육생
  r := attendance.api_student_verify('dev-daejeon-a', '예시학생02', current_setting('t.h4567'), '8.8.8.8', s2, 600, dev);
  r := attendance.api_student_code(s2, code, '8.8.8.8');
  r := attendance.api_student_action(s2, 'check_in', gen_random_uuid(), '8.8.8.8');
  perform pg_temp.eq('second check_in', r->>'ok', 'true');

  r := attendance.api_operator_daily(dj, null, (now() at time zone 'Asia/Seoul')::date);
  perform pg_temp.eq('via code flag',
    (select (x->>'viaCode')::boolean from jsonb_array_elements(r->'rows') x where x->>'name' = '예시학생01'), true);
  perform pg_temp.eq('shared device',
    (select x->'sharedDevice'->>0 from jsonb_array_elements(r->'rows') x where x->>'name' = '예시학생01'), '예시학생02');
  perform pg_temp.eq('no shared for others',
    (select jsonb_array_length(x->'sharedDevice') from jsonb_array_elements(r->'rows') x where x->>'name' = '예시학생03'), 0);

  r := attendance.api_operator_codes(dj, null);
  perform pg_temp.eq('code usage', (r->'campuses'->0->>'students')::int, 2);

  -- 막힌 접속: 8.8.8.8 에서 2명
  r := attendance.api_operator_blocked(dj, null, 60);
  perform pg_temp.eq('blocked ip', r->'items'->0->>'ip', '8.8.8.8');
  perform pg_temp.eq('blocked students', (r->'items'->0->>'students')::int, 2);
  r := attendance.api_operator_blocked(bs, null, 60);
  perform pg_temp.eq('busan sees none', jsonb_array_length(r->'items'), 0);

  -- 운영자가 그 IP를 허용하면 목록에서 빠짐
  r := attendance.api_operator_network_save(dj, null, campus, '새 공인 IP', '8.8.8.8/32', 'active', null, null, null, null, false);
  perform pg_temp.eq('allow blocked ip', r->>'ok', 'true');
  r := attendance.api_operator_blocked(dj, null, 60);
  perform pg_temp.eq('blocked cleared', jsonb_array_length(r->'items'), 0);

  -- 코드를 새로 바꾸면 이전 코드로 확인한 세션은 다른 IP에서 막힘
  r := attendance.api_operator_code_set(dj, campus, 'on');
  perform pg_temp.eq('renewed', (r->>'code') ~ '^[0-9]{6}$', true);
  r := attendance.api_student_action(s1, 'go_out', gen_random_uuid(), '9.9.9.9');
  perform pg_temp.eq('old code session blocked', r->>'code', 'network_denied');
  r := attendance.api_student_code(s1, code, '9.9.9.9');
  perform pg_temp.eq('old code rejected', r->>'code', 'invalid_code');

  -- 끄기
  r := attendance.api_operator_code_set(dj, campus, 'off');
  r := attendance.api_campus_info('dev-daejeon-a', '9.9.9.9');
  perform pg_temp.eq('code mode off again', r->>'codeMode', 'false');
  r := attendance.api_student_code(s1, code, '9.9.9.9');
  perform pg_temp.eq('code inactive', r->>'code', 'code_inactive');
end $$;

reset role;

-- 코드 값은 변경 이력에 남지 않고, 원본 이벤트의 기록 방법이 맞게 남는다
do $$
begin
  perform pg_temp.eq('audit code actions',
    (select count(*) from attendance.audit_logs where action in ('code.on', 'code.renew', 'code.off')), 3::bigint);
  perform pg_temp.eq('audit has no code value',
    (select count(*) from attendance.audit_logs where action like 'code.%' and (after ? 'code' or before ? 'code')), 0::bigint);
  perform pg_temp.eq('events by code',
    (select count(*) from attendance.attendance_events where method = 'code' and code_id is not null and network_id is null), 2::bigint);
  begin
    insert into attendance.attendance_events (enrollment_id, region_id, campus_id, action, edu_date, client_ip, request_id, method)
    values (1, 1, 1, 'check_in', current_date, '1.1.1.1', gen_random_uuid(), 'network');
    raise exception 'FAIL network event without network accepted';
  exception when check_violation then null;
  end;
end $$;

rollback;
\echo 'PRESENCE TESTS PASSED'
