-- LG전자 K뉴딜 아카데미 2기 초기 등록 (운영 DB, 마이그레이션 0001~0007 적용 후 1회)
--   psql "$DB" -v ON_ERROR_STOP=1 -f db/setup/lg_knewdeal_2.sql
--
-- 들어가는 것: 지역 3곳, 지역별 교육장(본 교육장·평택 연수원), 과정·기간·기본 시간,
--             평택 입소 주간(1주차·5주차) 날짜별 시간, 공휴일 휴강, 출석확인서 기관명.
-- 들어가지 않는 것: 운영자 비밀번호(따로 설정), 교육장 허용 IP(현장에서 등록), 교육생 명단(관리 화면에서 등록).
--
-- 평택 입소 주간 (1주차·5주차)
--   1일차(월) 11:00~17:00 (부산 11:30~17:30) / 2~4일차 08:00~17:00
--   5일차(금) 1주차 08:00~15:00, 5주차 08:00~12:00
-- 하루 훈련시간은 점심 1시간을 뺀 값으로 넣었다(09:00~18:00 = 8시간). 다르면 과정·일정 화면에서 고친다.
-- 이미 있는 지역·교육장·과정·날짜는 건너뛴다(여러 번 실행해도 안전).

begin;

insert into attendance.regions (code, name) values
  ('daegu', '대구'), ('daejeon', '대전'), ('busan', '부산')
on conflict (code) do nothing;

update attendance.regions set institution_name = 'LG전자' where code in ('daegu', 'daejeon', 'busan');

insert into attendance.campuses (region_id, name)
select r.id, v.name
  from attendance.regions r
 cross join (values ('본 교육장'), ('평택 연수원')) v(name)
 where r.code in ('daegu', 'daejeon', 'busan')
   and not exists (select 1 from attendance.campuses c where c.region_id = r.id and c.name = v.name);

-- 과정: 짧은 이름은 명단 CSV 의 course 열과 같아야 한다.
insert into attendance.courses (region_id, name, full_name, starts_on, ends_on, class_start, class_end,
                                late_after_minutes, training_minutes)
select r.id, v.name, 'LG전자 K뉴딜 아카데미 ' || v.full_name, v.starts_on, v.ends_on, '09:00', '18:00', 10, 480
  from (values
          ('busan',   'AX', 'AX 워크플로우',   date '2026-11-09', date '2027-01-25'),
          ('busan',   'SF', '스마트팩토리',     date '2026-11-09', date '2027-01-25'),
          ('busan',   'DM', '디지털마케팅',     date '2026-11-09', date '2027-01-25'),
          ('daegu',   'AX', 'AX 워크플로우',   date '2026-11-02', date '2027-01-18'),
          ('daegu',   'SF', '스마트팩토리',     date '2026-11-02', date '2027-01-18'),
          ('daejeon', 'AX', 'AX 워크플로우',   date '2026-11-02', date '2027-01-18'),
          ('daejeon', 'DM', '디지털마케팅',     date '2026-11-02', date '2027-01-18')
       ) v(region, name, full_name, starts_on, ends_on)
  join attendance.regions r on r.code = v.region
on conflict (region_id, name) do nothing;

-- 평택 입소 주간: 과정 시작일(월) 기준 1주차와 5주차
insert into attendance.course_days (course_id, edu_date, kind, class_start, class_end, training_minutes, place, note, updated_by)
select co.id, co.starts_on + (wk * 7) + d.offs, 'class', d.st, d.en,
       -- 점심 1시간 제외 (4시간 이하는 그대로)
       (extract(epoch from (d.en - d.st)) / 60 - case when d.en - d.st > interval '4 hours' then 60 else 0 end)::int,
       '평택 연수원', case when wk = 0 then '1주차 입소' else '5주차 입소' end, 'setup'
  from attendance.courses co
  join attendance.regions r on r.id = co.region_id
 cross join (values (0), (4)) w(wk)
 cross join lateral (values
          (0, case when r.code = 'busan' then time '11:30' else time '11:00' end,
              case when r.code = 'busan' then time '17:30' else time '17:00' end),
          (1, time '08:00', time '17:00'),
          (2, time '08:00', time '17:00'),
          (3, time '08:00', time '17:00'),
          (4, time '08:00', case when wk = 0 then time '15:00' else time '12:00' end)
       ) d(offs, st, en)
 where r.code in ('daegu', 'daejeon', 'busan') and co.starts_on is not null
on conflict (course_id, edu_date) do nothing;

-- 공휴일 휴강 (과정 기간 안의 평일)
insert into attendance.course_days (course_id, edu_date, kind, note, updated_by)
select co.id, h.d, 'off', h.note, 'setup'
  from attendance.courses co
  join attendance.regions r on r.id = co.region_id
 cross join (values (date '2026-12-25', '성탄절'), (date '2027-01-01', '신정')) h(d, note)
 where r.code in ('daegu', 'daejeon', 'busan') and h.d between co.starts_on and co.ends_on
on conflict (course_id, edu_date) do nothing;

commit;

-- 확인: 과정과 교육장 QR 주소
select r.name as 지역, co.name as 과정, co.full_name as 정식이름, co.starts_on as 시작, co.ends_on as 종료,
       (select count(*) from attendance.course_days x where x.course_id = co.id and x.kind = 'class') as 평택일수,
       (select count(*) from attendance.course_days x where x.course_id = co.id and x.kind = 'off') as 휴강
  from attendance.courses co join attendance.regions r on r.id = co.region_id order by r.id, co.name;
select r.name as 지역, c.name as 교육장, '/c/' || c.qr_code as qr주소
  from attendance.campuses c join attendance.regions r on r.id = c.region_id order by r.id, c.id;
