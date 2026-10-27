-- 데모용 과거 기록 (dev.sql 다음에 실행). 운영 DB에는 실행하지 않는다.
-- 대전에 예시 교육생을 더하고, 최근 평일 기록을 만든다. 일부러 누락 사례를 섞는다.
--   최근 평일 기준 예시학생03: 1일 전 기록 없음 / 예시학생02: 2일 전 퇴실 없음 / 예시학생04: 3일 전 복귀 없음
--   판정 예시: 예시학생05 지각·외출·지각, 09 외출, 11 조퇴(1일 전), 06 수업 50% 미만(2일 전)
--   0005 이후: 예시학생12 1일 전 자 중도탈락, 예시학생10 1일 전 자 조기취업 (그 날부터 기록 없음),
--             예시학생03 1일 전 병결 공가(승인), 예시학생05 다음 주 예비군 공가(서류 미제출),
--             예시학생07 오늘 면접 공가(일부 시간, 서류 제출·확인 대기)

begin;

with s as (
  insert into attendance.students (name)
  select '예시학생' || lpad(n::text, 2, '0') from generate_series(5, 12) n
  returning id, name
)
insert into attendance.enrollments (student_id, region_id, course_id, name_key, last4_hmac, created_at)
select s.id, r.id, co.id, s.name,
       encode(extensions.hmac(lpad((1000 + right(s.name, 2)::int * 111)::text, 4, '0'), 'dev-only-secret', 'sha256'), 'hex'),
       now() - interval '60 days'
  from s
  join attendance.regions r on r.code = 'daejeon'
  join attendance.courses co on co.region_id = r.id and co.name = case when right(s.name, 2)::int % 2 = 0 then 'SF' else 'AX' end;

update attendance.enrollments set created_at = now() - interval '60 days';

do $$
declare
  v_today  date := (now() at time zone 'Asia/Seoul')::date;
  v_day    date;
  v_ago    int;
  v_k      int := 0;
  v_net    attendance.allowed_networks;
  v_region smallint;
  v_e      record;
  v_plan   text[];
  v_times  time[];
  v_status text;
  v_first  timestamptz;
  v_out    timestamptz;
  v_last   timestamptz;
  v_at     timestamptz;
  i        int;
begin
  select n.* into v_net from attendance.allowed_networks n where n.network = '127.0.0.1/32';
  select region_id into v_region from attendance.campuses where id = v_net.campus_id;

  for v_ago in 1..7 loop
    v_day := v_today - v_ago;
    continue when extract(isodow from v_day) > 5;
    v_k := v_k + 1;
    for v_e in
      select e.id, right(st.name, 2)::int as n
        from attendance.enrollments e join attendance.students st on st.id = e.student_id
       where e.region_id = v_region
    loop
      -- 기본: 입실 → 퇴실. 외출은 아래 예시에서만 넣는다(외출은 수업 시간 중이면 1회로 센다).
      v_plan := array['check_in', 'check_out'];
      v_times := array[time '08:40' + make_interval(mins => (v_e.n * 7 + v_k * 3) % 25),
                       time '18:00' + make_interval(mins => (v_e.n * 11 + v_k) % 15)];
      if v_k = 1 and v_e.n = 3 then continue; end if;                         -- 기록 없음
      if v_k = 1 and v_e.n in (10, 12) then continue; end if;                 -- 중도탈락·조기취업 이후
      if v_k = 2 and v_e.n = 2 then v_plan := array['check_in']; end if;      -- 퇴실 없음
      if v_k = 3 and v_e.n = 4 then                                           -- 복귀 없음
        v_plan := array['check_in', 'go_out']; v_times[2] := time '15:00';
      end if;
      -- 판정 예시: 예시학생05 지각·외출·지각 (3회 → 결석 1회 환산), 09 외출, 11 조퇴, 06 수업 50% 미만
      if v_k = 1 and v_e.n = 5 then v_times[1] := time '09:25'; end if;
      if v_k = 3 and v_e.n = 5 then v_times[1] := time '09:15'; end if;
      if (v_k = 2 and v_e.n = 5) or (v_k = 1 and v_e.n = 9) then
        v_plan := array['check_in', 'go_out', 'return', 'check_out'];
        v_times := array[v_times[1], time '15:00', time '15:40', v_times[2]];
      end if;
      if v_k = 1 and v_e.n = 11 then v_times[2] := time '15:00'; end if;
      if v_k = 2 and v_e.n = 6 then v_times[2] := time '11:30'; end if;

      v_status := 'not_in'; v_first := null; v_out := null; v_last := null;
      for i in 1..array_length(v_plan, 1) loop
        v_at := (v_day + v_times[i]) at time zone 'Asia/Seoul';
        insert into attendance.attendance_events (enrollment_id, region_id, campus_id, action, occurred_at, edu_date,
                                                  client_ip, network_id, network_version, request_id)
        values (v_e.id, v_region, v_net.campus_id, v_plan[i], v_at, v_day, '127.0.0.1', v_net.id, v_net.version, gen_random_uuid());
        v_status := attendance.next_status(v_status, v_plan[i]);
        if v_plan[i] = 'check_in' then v_first := v_at; end if;
        if v_plan[i] = 'check_out' then v_out := v_at; end if;
        v_last := v_at;
      end loop;
      insert into attendance.attendance_days (enrollment_id, edu_date, region_id, status, first_check_in_at,
                                              last_check_out_at, last_event_at, last_action, version)
      values (v_e.id, v_day, v_region, v_status, v_first, v_out, v_last, v_plan[array_length(v_plan, 1)],
              array_length(v_plan, 1));
    end loop;
  end loop;
end $$;

do $$
declare
  v_today  date := (now() at time zone 'Asia/Seoul')::date;
  v_last   date := (now() at time zone 'Asia/Seoul')::date - 1;
  v_region smallint := (select id from attendance.regions where code = 'daejeon');
  v_e3     bigint := (select id from attendance.enrollments where name_key = '예시학생03');
begin
  while extract(isodow from v_last) > 5 loop v_last := v_last - 1; end loop;

  update attendance.enrollments set training_status = 'dropped', status_on = v_last, status = 'ended'
   where name_key = '예시학생12';
  update attendance.enrollments set training_status = 'employed', status_on = v_last, status = 'ended'
   where name_key = '예시학생10';

  insert into attendance.leaves (enrollment_id, region_id, starts_on, ends_on, kind, part, reason, created_by,
                                 status, decided_at, decided_by, decision_note)
  values (v_e3, v_region, v_last, v_last, 'sick', 'full', '장염으로 병원 진료', 'student',
          'approved', now(), '예시 운영자', '진료확인서 확인');
  insert into attendance.leaves (enrollment_id, region_id, starts_on, ends_on, kind, part, reason, created_by, created_name)
  select id, v_region, v_today + (8 - extract(isodow from v_today)::int), v_today + (9 - extract(isodow from v_today)::int), 'reserve', 'full', '예비군 동원훈련', 'operator', '예시 운영자'
    from attendance.enrollments where name_key = '예시학생05';
  insert into attendance.leaves (enrollment_id, region_id, starts_on, ends_on, kind, part, reason, created_by)
  select id, v_region, v_today, v_today, 'interview', 'partial', '14시 기업 면접으로 13시 조퇴 예정', 'student'
    from attendance.enrollments where name_key = '예시학생07';
  -- 예시 서류 (1×1 PNG)
  update attendance.leaves set status = 'submitted'
   where enrollment_id = (select id from attendance.enrollments where name_key = '예시학생07');
  insert into attendance.leave_docs (leave_id, file_name, mime, size_bytes, content)
  select l.id, '면접확인서(예시).png', 'image/png', length(b), b
    from attendance.leaves l,
         decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64') b
   where l.enrollment_id = (select id from attendance.enrollments where name_key = '예시학생07');

  update attendance.regions set institution_name = '예시 교육기관 대전캠퍼스' where id = v_region;

  insert into attendance.day_notes (enrollment_id, edu_date, region_id, note, updated_by)
  values (v_e3, v_last, v_region, '병결, LMS 진료확인서 제출 완료', '예시 운영자');
end $$;

commit;
