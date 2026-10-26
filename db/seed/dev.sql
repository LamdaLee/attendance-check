-- 로컬 개발용 예시 데이터. 운영 DB에는 실행하지 않는다.
-- 뒷자리 HMAC 은 .env.example 의 STUDENT_MATCH_SECRET(dev-only-secret) 기준이다.
-- 운영자 비밀번호: 대구 daegu-dev / 대전 daejeon-dev / 부산 busan-dev / 총괄 super-dev

begin;

insert into attendance.regions (code, name) values
  ('daegu', '대구'), ('daejeon', '대전'), ('busan', '부산');

insert into attendance.campuses (region_id, name, qr_code)
select id, '교육장 A', 'dev-' || code || '-a' from attendance.regions;

-- 로컬 접속(127.0.0.1, ::1)을 대전 교육장 A 의 허용 회선으로 등록
insert into attendance.allowed_networks (campus_id, label, network, status)
select c.id, v.label, v.network::cidr, 'active'
  from attendance.campuses c, (values ('로컬 IPv4', '127.0.0.1/32'), ('로컬 IPv6', '::1/128')) v(label, network)
 where c.qr_code = 'dev-daejeon-a';

insert into attendance.courses (region_id, name)
select r.id, v.name from attendance.regions r, (values ('AX'), ('SF')) v(name);

with s as (
  insert into attendance.students (name)
  values ('예시학생01'), ('예시학생02'), ('예시학생03'), ('예시학생04')
  returning id, name
)
insert into attendance.enrollments (student_id, region_id, course_id, name_key, last4_hmac)
select s.id, r.id, co.id, s.name,
       encode(extensions.hmac(v.last4, 'dev-only-secret', 'sha256'), 'hex')
  from s
  join (values ('예시학생01', '0123', 'AX'), ('예시학생02', '4567', 'SF'),
               ('예시학생03', '8901', 'AX'), ('예시학생04', '2345', 'SF')) v(name, last4, course) on v.name = s.name
  join attendance.regions r on r.code = 'daejeon'
  join attendance.courses co on co.region_id = r.id and co.name = v.course;

insert into attendance.operator_access (scope, region_id, password_hash)
select 'region', id, extensions.crypt(code || '-dev', extensions.gen_salt('bf')) from attendance.regions;

insert into attendance.operator_access (scope, password_hash)
values ('super', extensions.crypt('super-dev', extensions.gen_salt('bf')));

commit;
