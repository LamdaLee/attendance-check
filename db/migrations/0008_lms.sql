-- 바로가기: 과정별 LMS 출결 주소(출결 기록 뒤 바로 넘어가기)와 지역별 학생 화면 바로가기 링크
-- 실행: psql "$DATABASE_ADMIN_URL" -v ON_ERROR_STOP=1 -f db/migrations/0008_lms.sql
--
--   * 주소만 저장한다. LMS 계정·토큰은 다루지 않는다(교육생 브라우저의 LMS 로그인 상태를 그대로 쓴다).
--   * 지역 바로가기(예: LMS 로그인, 런치패스)는 본인 확인 전에도 학생 화면에 보인다. 개인정보가 아니다.

begin;

alter table attendance.courses
  add column lms_url text not null default '' check (lms_url = '' or (lms_url ~ '^https://\S+$' and length(lms_url) <= 500));

create table attendance.quick_links (
  id          bigint generated always as identity primary key,
  region_id   smallint not null references attendance.regions (id),
  label       text not null check (length(label) between 1 and 30),
  url         text not null check (url ~ '^https://\S+$' and length(url) <= 500),
  sort_order  smallint not null default 0,
  created_at  timestamptz not null default now()
);

create index quick_links_region_idx on attendance.quick_links (region_id, sort_order, id);

-- 교육장 QR 기준 지역 바로가기 (본인 확인 전에도 보여 준다)
create function attendance.api_campus_links(p_qr_code text)
returns jsonb
language sql stable security definer set search_path = attendance, pg_temp as $$
  select jsonb_build_object('ok', true, 'links', coalesce((
    select jsonb_agg(jsonb_build_object('label', l.label, 'url', l.url) order by l.sort_order, l.id)
      from quick_links l join campuses c on c.region_id = l.region_id
     where c.qr_code = p_qr_code and c.is_active
  ), '[]'::jsonb))
$$;

create function attendance.api_operator_links(p_token_hash bytea, p_region_code text)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'links', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'label', label, 'url', url, 'sortOrder', sort_order) order by sort_order, id)
      from quick_links where region_id = v_region
  ), '[]'::jsonb));
end $$;

-- 바로가기 추가·변경(p_id 가 null 이면 추가)·삭제(p_delete)
create function attendance.api_operator_link_save(
  p_token_hash bytea, p_region_code text, p_id bigint, p_label text, p_url text, p_sort int, p_delete boolean
) returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
  v_before quick_links;
  v_label  text := trim(coalesce(p_label, ''));
  v_url    text := trim(coalesce(p_url, ''));
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  if p_id is not null then
    select * into v_before from quick_links where id = p_id and region_id = v_region for update;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'not_found');
    end if;
  end if;
  if coalesce(p_delete, false) then
    if p_id is null then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    delete from quick_links where id = p_id;
  else
    if length(v_label) not between 1 and 30 then
      return jsonb_build_object('ok', false, 'code', 'invalid_input');
    end if;
    if v_url !~ '^https://\S+$' or length(v_url) > 500 then
      return jsonb_build_object('ok', false, 'code', 'invalid_url');
    end if;
    if p_id is null then
      insert into quick_links (region_id, label, url, sort_order) values (v_region, v_label, v_url, coalesce(p_sort, 0));
    else
      update quick_links set label = v_label, url = v_url, sort_order = coalesce(p_sort, sort_order) where id = p_id;
    end if;
  end if;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_region, v_op.scope, v_op.operator_name, 'link.save', 'quick_links', p_id::text,
          case when v_before.id is not null then to_jsonb(v_before) end,
          case when coalesce(p_delete, false) then null else jsonb_build_object('label', v_label, 'url', v_url) end);
  return jsonb_build_object('ok', true);
end $$;

-- 학생: 본인 과정의 바로가기 주소
create function attendance.api_student_links(p_token_hash bytea)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_s sessions;
begin
  v_s := student_session(p_token_hash);
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  return jsonb_build_object('ok', true, 'lmsUrl', (
    select nullif(co.lms_url, '') from enrollments e join courses co on co.id = e.course_id where e.id = v_s.enrollment_id));
end $$;

-- 운영자: 과정 LMS 주소 저장 (빈 값이면 바로가기 숨김)
create function attendance.api_operator_course_lms(p_token_hash bytea, p_course_id bigint, p_url text)
returns jsonb
language plpgsql security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_before courses;
  v_url    text := trim(coalesce(p_url, ''));
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  select * into v_before from courses where id = p_course_id for update;
  if not found or not operator_owns(v_op.scope, v_op.region_id, v_before.region_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if v_url <> '' and (v_url !~ '^https://\S+$' or length(v_url) > 500) then
    return jsonb_build_object('ok', false, 'code', 'invalid_url');
  end if;
  update courses set lms_url = v_url where id = v_before.id;
  insert into audit_logs (region_id, actor_scope, actor_name, action, target_table, target_id, before, after)
  values (v_before.region_id, v_op.scope, v_op.operator_name, 'course.lms', 'courses', v_before.id::text,
          jsonb_build_object('lmsUrl', v_before.lms_url), jsonb_build_object('lmsUrl', v_url));
  return jsonb_build_object('ok', true);
end $$;

create or replace function attendance.api_operator_courses(p_token_hash bytea, p_region_code text)
returns jsonb
language plpgsql stable security definer set search_path = attendance, pg_temp as $$
declare
  v_op     record;
  v_region smallint;
begin
  select * into v_op from operator_session(p_token_hash);
  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;
  v_region := operator_region(v_op.scope, v_op.region_id, p_region_code);
  if v_region is null then
    return jsonb_build_object('ok', false, 'code', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'courses', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', co.id, 'name', co.name, 'fullName', co.full_name, 'isActive', co.is_active,
             'startsOn', co.starts_on, 'endsOn', co.ends_on,
             'classStart', to_char(co.class_start, 'HH24:MI'), 'classEnd', to_char(co.class_end, 'HH24:MI'),
             'lateAfter', co.late_after_minutes, 'trainingMinutes', co.training_minutes, 'lmsUrl', co.lms_url,
             'students', (select count(*) from enrollments e where e.course_id = co.id and e.training_status = 'training')
           ) order by co.name)
      from courses co where co.region_id = v_region
  ), '[]'::jsonb));
end $$;

revoke execute on all functions in schema attendance from public;

grant execute on function
  attendance.api_student_links(bytea),
  attendance.api_campus_links(text),
  attendance.api_operator_links(bytea, text),
  attendance.api_operator_link_save(bytea, text, bigint, text, text, int, boolean),
  attendance.api_operator_course_lms(bytea, bigint, text)
to attendance_app;

commit;
