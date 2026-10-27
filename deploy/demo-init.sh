#!/bin/sh
# 데모 DB 초기화 마지막 단계 (postgres 이미지가 처음 시작될 때 한 번만 실행)
#  - 앱 접속 역할 비밀번호 지정
#  - 예시 데이터의 공개된 운영자 비밀번호(daejeon-dev 등)를 DEMO_ADMIN_PASSWORD 로 교체
set -eu
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD 가 필요합니다}"
: "${DEMO_ADMIN_PASSWORD:?DEMO_ADMIN_PASSWORD 가 필요합니다}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v app_pw="$APP_DB_PASSWORD" -v admin_pw="$DEMO_ADMIN_PASSWORD" <<'SQL'
alter role attendance_app login password :'app_pw';
update attendance.operator_access
   set password_hash = extensions.crypt(:'admin_pw', extensions.gen_salt('bf')),
       access_version = access_version + 1,
       updated_at = now();
SQL
