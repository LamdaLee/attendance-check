-- 첫 화면: 접속 IP 로 교육장을 찾아 바로 들어가고, 못 찾으면 교육장 목록을 보여 준다.
-- 같은 회선을 여러 지역이 쓰면 오늘 그 장소 일정이 있는 지역만 고르게 한다.
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0010_entry.sql
--
--   * 교육장 이름과 QR 식별자는 공개 정보다(QR 에 그대로 들어간다). 개인정보는 다루지 않는다.

begin;

create function attendance.api_entry(p_ip inet)
returns jsonb
language sql stable security definer set search_path = attendance, pg_temp as $$
  select jsonb_build_object(
    'ok', true,
    -- 지금 접속한 회선이 허용 IP 로 등록된 교육장.
    -- 여러 지역이 같은 회선을 쓰는 곳(평택 러닝센터)은 오늘 그 장소로 일정이 잡힌 지역만 남긴다
    -- (과정·일정의 날짜별 장소 = 교육장 이름). 그런 일정이 하나도 없으면 회선이 맞는 곳을 모두 보여 준다.
    'matched', coalesce((
      with m as (
        select c.qr_code, c.name, r.name as region_name, r.id as rid, c.id as cid,
               exists (select 1 from course_days x join courses co on co.id = x.course_id
                        where co.region_id = c.region_id and co.is_active and x.kind = 'class'
                          and x.edu_date = edu_date_now() and x.place = c.name) as scheduled
          from campuses c join regions r on r.id = c.region_id
         where p_ip is not null and c.is_active and r.is_active and (match_network(c.id, p_ip)).id is not null
      )
      select jsonb_agg(jsonb_build_object('code', qr_code, 'name', name, 'regionName', region_name) order by rid, cid)
        from m
       where scheduled or not exists (select 1 from m where scheduled)
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
