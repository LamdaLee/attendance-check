-- 데모용 과거 기록 (dev.sql 다음에 실행). 운영 DB에는 실행하지 않는다.
-- 대전에 예시 교육생을 더하고, 최근 평일 기록을 만든다. 일부러 누락 사례를 섞는다.
--   최근 평일 기준 예시학생03: 1일 전 기록 없음 / 예시학생02: 2일 전 퇴실 없음 / 예시학생04: 3일 전 복귀 없음

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
      -- 기본: 입실 → 점심 외출·복귀 → 퇴실
      v_plan := array['check_in', 'go_out', 'return', 'check_out'];
      v_times := array[time '08:40' + make_interval(mins => (v_e.n * 7 + v_k * 3) % 25),
                       time '12:00' + make_interval(mins => (v_e.n * 5) % 10),
                       time '12:50' + make_interval(mins => (v_e.n * 3) % 9),
                       time '18:00' + make_interval(mins => (v_e.n * 11 + v_k) % 15)];
      if v_k = 1 and v_e.n = 3 then continue; end if;                         -- 기록 없음
      if v_k = 2 and v_e.n = 2 then v_plan := v_plan[1:3]; end if;            -- 퇴실 없음
      if v_k = 3 and v_e.n = 4 then v_plan := v_plan[1:2]; end if;            -- 복귀 없음
      if v_e.n > 4 and (v_e.n + v_k) % 4 = 0 then v_plan := array['check_in', 'check_out']; v_times := array[v_times[1], v_times[4]]; end if;

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

commit;
