-- 첫 화면: 접속 IP 로 교육장을 찾아 바로 들어가고, 못 찾으면 교육장 목록을 보여 준다.
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0010_entry.sql
--
--   * 교육장 이름과 QR 식별자는 공개 정보다(QR 에 그대로 들어간다). 개인정보는 다루지 않는다.

begin;

create function attendance.api_entry(p_ip inet)
returns jsonb
language sql stable security definer set search_path = attendance, pg_temp as $$
  select jsonb_build_object(
    'ok', true,
    -- 지금 접속한 회선이 허용 IP 로 등록된 교육장
    'matched', coalesce((
      select jsonb_agg(jsonb_build_object('code', c.qr_code, 'name', c.name, 'regionName', r.name) order by r.id, c.id)
        from campuses c join regions r on r.id = c.region_id
       where p_ip is not null and c.is_active and r.is_active and (match_network(c.id, p_ip)).id is not null
    ), '[]'::jsonb),
    'campuses', coalesce((
      select jsonb_agg(jsonb_build_object('code', c.qr_code, 'name', c.name, 'regionName', r.name) order by r.id, c.id)
        from campuses c join regions r on r.id = c.region_id
       where c.is_active and r.is_active
    ), '[]'::jsonb)
  )
$$;

revoke execute on all functions in schema attendance from public;
grant execute on function attendance.api_entry(inet) to attendance_app;

commit;
