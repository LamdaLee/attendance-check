-- 시도 제한을 사람별로: 여럿이 한 IP 를 쓰는 교육장(예: 평택 러닝센터 130명)에서
-- 몇 사람의 오타로 그 IP 전체가 막히던 문제를 고친다.
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0011_rate_limits.sql
--
--   * 본인 확인: 같은 IP·같은 이름 실패 5회, 같은 IP 전체 실패 100회 (10분 단위, 직전 10분 포함)
--   * 출석코드: 같은 교육생 실패 10회, 같은 IP 전체 실패 100회

begin;

create or replace function attendance.api_student_verify(
  p_qr_code text, p_name_key text, p_last4_hmac text, p_ip inet, p_token_hash bytea, p_ttl_seconds int,
  p_device_hash bytea default null
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_campus     record;
  -- 사람별(같은 IP·같은 이름) 5회, IP 전체 100회. 교육장처럼 여럿이 한 IP 를 쓰는 곳에서
  -- 몇 사람의 오타로 모두가 막히지 않게 하고, 한 사람의 뒷자리 맞히기와 대량 시도는 막는다.
  v_rate_key   text := 'verify:' || host(p_ip) || ':' || coalesce(p_name_key, '');
  v_ip_key     text := 'verify-ip:' || host(p_ip);
  v_matches    bigint[];
  v_enr        record;
  v_network_ok boolean;
begin
  if rate_hit(v_rate_key, false) >= 5 or rate_hit(v_ip_key, false) >= 100 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;

  select c.id, c.region_id into v_campus
    from campuses c join regions r on r.id = c.region_id
   where c.qr_code = p_qr_code and c.is_active and r.is_active;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'campus_not_found');
  end if;

  v_network_ok := (match_network(v_campus.id, p_ip)).id is not null;

  select array_agg(e.id) into v_matches
    from enrollments e join courses co on co.id = e.course_id
   where e.region_id = v_campus.region_id
     and e.name_key = p_name_key
     and e.last4_hmac = p_last4_hmac
     and e.status = 'active'
     and co.is_active
     and (co.campus_id is null or co.campus_id = v_campus.id)
     and (e.starts_on is null or e.starts_on <= edu_date_now())
     and (e.ends_on is null or e.ends_on >= edu_date_now());

  if v_matches is null then
    perform rate_hit(v_rate_key, true);
    perform rate_hit(v_ip_key, true);
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if array_length(v_matches, 1) > 1 then
    return jsonb_build_object('ok', false, 'code', 'ambiguous');
  end if;

  if not v_network_ok then
    insert into blocked_attempts (campus_id, region_id, ip, enrollment_id, kind)
    values (v_campus.id, v_campus.region_id, p_ip, v_matches[1], 'verify');
  end if;

  insert into sessions (kind, token_hash, enrollment_id, campus_id, region_id, expires_at, network_verified, device_hash)
  values ('student', p_token_hash, v_matches[1], v_campus.id, v_campus.region_id,
          now() + make_interval(secs => p_ttl_seconds), v_network_ok, p_device_hash);

  select s.name as student_name, co.name as course_name into v_enr
    from enrollments e join students s on s.id = e.student_id join courses co on co.id = e.course_id
   where e.id = v_matches[1];

  return jsonb_build_object('ok', true, 'studentName', v_enr.student_name, 'courseName', v_enr.course_name,
                            'networkVerified', v_network_ok,
                            'codeMode', (active_code(v_campus.id)).id is not null);
end $$;

create or replace function attendance.api_student_code(p_token_hash bytea, p_code text, p_ip inet)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_s        sessions;
  v_code     campus_codes;
  v_rate_key text;
  v_ip_key   text := 'code-ip:' || host(p_ip);
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  -- 사람별 10회, IP 전체 100회 (휴대폰 데이터망은 여럿이 한 IP 를 쓰기도 한다)
  v_rate_key := 'code:' || v_s.enrollment_id;
  if rate_hit(v_rate_key, false) >= 10 or rate_hit(v_ip_key, false) >= 100 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  v_code := active_code(v_s.campus_id);
  if v_code.id is null then
    return jsonb_build_object('ok', false, 'code', 'code_inactive');
  end if;
  if v_code.code <> coalesce(trim(p_code), '') then
    perform rate_hit(v_rate_key, true);
    perform rate_hit(v_ip_key, true);
    return jsonb_build_object('ok', false, 'code', 'invalid_code');
  end if;
  update sessions set presence_code_id = v_code.id where id = v_s.id;
  return jsonb_build_object('ok', true);
end $$;

commit;
