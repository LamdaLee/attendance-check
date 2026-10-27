# 지역별 QR 출결

대구·대전·부산 교육생이 교육장 와이파이에 연결한 뒤 QR로 접속하고, 이름과 전화번호 뒷자리로 본인을 확인해 입실·외출·복귀·퇴실을 기록하는 보조 출결 시스템입니다. 공식 LMS 출석 판정을 대신하지 않습니다.

- 앱: Next.js(모바일 웹) — 학생 화면 `/c/<교육장 QR 코드>`, 운영자 화면 `/admin`
- DB: 직접 설치한 Supabase 의 Postgres, 전용 스키마 `attendance`

## 기능

| 화면 | 내용 |
| --- | --- |
| 학생 `/c/<코드>` | 이름+뒷자리 본인 확인, 입실·외출·복귀·퇴실, 오늘 기록, 지각·결석·조퇴 예정 알림, 정정 요청 |
| 운영자 · 출결 현황 | 날짜·과정·상태·이름 조회, 15초 자동 갱신, 사전 알림·정정 표시, 인쇄, CSV |
| 운영자 · 사전 알림 | 오늘부터 14일까지의 지각·결석·조퇴 예정 목록 |
| 운영자 · 누락 확인 | 지난 날짜의 퇴실 없음·복귀 없음·기록 없음 (결석으로 단정하지 않음) |
| 운영자 · 정정 요청 | 원본과 반영 기록 비교, 승인하며 정정, 반려, 직권 정정 |
| 운영자 · 교육생 | 명단 조회, 한 명 추가, CSV 일괄 등록(검증 후 저장), 중지·종료·과정 변경·뒷자리 재등록 |
| 운영자 · 학생별 기록 | 월별 기록, 날짜별 상세와 정정 이력 |
| 운영자 · 교육장 · IP | 허용 IP 추가·변경·중지·삭제, 교육장 QR, 막힌 접속 바로 허용, 오늘의 출석코드 |
| 운영자 · 변경 이력 | IP·명단·정정·내보내기·비밀번호 변경 기록 |
| 총괄 · 총괄 현황 | 세 지역 현황, 허용 IP 없는 교육장 경고, 지역 전환 |

**교육장 공인 IP가 바뀌거나 와이파이가 안 될 때**
- 막힌 접속: 본인 확인된 교육생이 허용되지 않은 IP에서 막히면 IP별로 모아 보여 줍니다. 같은 새 IP에서 여러 명(3명 이상)이 막히면 "IP 변경 의심"으로 표시하고, 운영자가 [이 IP 허용]으로 바로 복구합니다. 출결 현황 상단에도 경고가 뜹니다.
- 오늘의 출석코드: 운영자가 교육장별로 켜는 6자리 코드(그날만 유효). 강의장에 안내하면 교육장 회선으로 확인되지 않는 교육생도 코드로 출결할 수 있습니다. 코드로 남긴 기록은 "코드"로 표시되고, 새 코드를 발급하면 이전 코드는 바로 무효가 됩니다. 메신저로 전달하면 밖에서도 쓸 수 있으므로 필요할 때만 켭니다.

**대리 출석 표시**: 브라우저에 무작위 기기 표시(쿠키 `att_d`, 해시만 저장)를 남겨, 하루에 한 기기에서 여러 교육생이 출결하면 출결 현황에 "같은 기기 n명"으로 표시합니다. 막지는 않습니다(휴대폰을 빌려 쓰는 경우). 브라우저를 바꾸면 피할 수 있는 보조 신호입니다.

**교육장 밖에서 할 수 있는 것**: 본인 확인 후 사전 알림과 정정 요청만 가능합니다. 출결 버튼과 오늘 기록 보기는 교육장 회선에서만 됩니다(다른 사람의 이름·뒷자리를 아는 사람이 기록을 엿보지 못하게).

## 구성

```
학생 휴대폰 / 운영자 PC
      │ HTTPS
      ▼
웹서버 ── Caddy (HTTPS, 실제 접속 IP를 X-Real-IP 로 덮어씀)
      └─ 출결 앱 컨테이너 (외부 포트 없음)
              │ Tailscale 사설 주소 (100.x)
              ▼
사설 DB 서버 ── Supabase Postgres (attendance 스키마)
```

### 보안 원칙

| 항목 | 구현 |
| --- | --- |
| DB 권한 | 앱은 `attendance_app` 역할로 접속. 테이블 권한 없이 `attendance.api_*` 함수 실행 권한만 가짐 |
| Supabase Data API | `attendance` 스키마를 노출하지 않음. `anon`·`authenticated` 권한 회수 |
| 교육장 IP 검사 | 본인 확인과 **버튼을 누를 때마다** DB 함수에서 허용 주소(`inet`/`cidr`)와 비교 |
| IP 위조 | 브라우저 값은 쓰지 않고 프록시가 덮어쓴 단일 헤더(`CLIENT_IP_HEADER`)만 읽음. 콤마가 섞이면 거부 |
| 출결 순서·중복 | 학생·교육일자 행을 잠그고 상태를 검사. `request_id` 고유 제약으로 재시도는 한 건만 저장 |
| 시각 | DB 서버 `now()` 로 저장, 교육일자는 `Asia/Seoul` 기준 |
| 원본 보존 | `attendance_events` 는 수정·삭제 트리거로 차단 |
| 전화번호 | 뒷자리 4자리의 HMAC(`STUDENT_MATCH_SECRET`)만 저장. 전체 번호는 받지 않음 |
| 세션 | 학생 10분, 운영자 8시간. httpOnly·SameSite=Strict 쿠키, DB에는 토큰 해시만 저장 |
| 지역 권한 | 지역 운영자는 DB 함수에서 자기 지역으로 고정. 요청의 지역·ID를 바꿔도 다른 지역 접근 불가 |
| 시도 제한 | 본인 확인·운영자 로그인 실패를 IP별 10분 10회로 제한 |

## 로컬 개발 (맥북)

준비물: Node 22, Postgres 16(또는 Supabase CLI 로컬)

```bash
npm install
cp .env.example .env          # DATABASE_URL, DATABASE_ADMIN_URL 수정

npm run db:migrate            # db/migrations/*.sql 을 번호 순서대로 적용
npm run db:seed:dev           # 예시 데이터 + 지난 평일 기록 (운영 DB에는 실행하지 않음)
npm run db:test               # DB 함수 검증 → ALL / SCREENS / PRESENCE TESTS PASSED
                              # (테스트는 seed/dev.sql 만 넣은 DB에서 실행)
psql "$DATABASE_ADMIN_URL" -c "alter role attendance_app login password 'dev'"

npm run dev
```

- 학생 화면: http://localhost:3000/c/dev-daejeon-a — 이름 `예시학생01`, 뒷자리 `0123`
- 운영자 화면: http://localhost:3000/admin — 대전 `daejeon-dev`, 총괄 `super-dev`
- 개발 서버는 IP 헤더가 없으면 `DEV_CLIENT_IP`(127.0.0.1)를 씁니다. 예시 데이터는 127.0.0.1 을 대전 교육장 A 의 허용 주소로 등록해 둡니다.
- 와이파이가 아닌 경우를 보려면 `DEV_CLIENT_IP=8.8.8.8` 로 바꿔 실행합니다.

## 운영 준비

### 1. 사설 DB(Supabase)에 스키마 적용

```bash
# Supabase .env 의 POSTGRES_PASSWORD 로 접속
export DATABASE_ADMIN_URL=postgres://postgres:<비밀번호>@100.67.186.67:5432/postgres
npm run db:migrate
psql "$DATABASE_ADMIN_URL" -c "alter role attendance_app login password '<앱 전용 비밀번호>'"
```

- 자체 호스팅 Supabase 의 5432 포트는 보통 연결 풀러(Supavisor)입니다. 이때 사용자 이름은 `postgres.<POOLER_TENANT_ID>`, `attendance_app.<POOLER_TENANT_ID>` 형식입니다.
- Supabase 포트(5432, 8000)는 공유기 포트포워딩 없이 Tailscale 로만 접근하게 둡니다.

### 2. 지역·교육장·과정·명단 등록

```bash
npm run admin -- add-region daegu 대구          # 대구·대전·부산
npm run admin -- add-campus daejeon 교육장 A    # QR 주소가 출력됨
npm run admin -- add-course daejeon AX
npm run admin -- set-password daejeon           # 지역 비밀번호 (10자 이상)
npm run admin -- set-password super             # 총괄 비밀번호
npm run admin -- import-students daejeon 명단.csv          # 검증만
npm run admin -- import-students daejeon 명단.csv --apply  # 저장
```

명단 CSV 는 `name,last4,course` 머리글을 씁니다. 엑셀에서 만들 때 뒷자리 열을 텍스트로 두어야 `0123` 의 앞자리 0이 유지됩니다. 같은 지역에 이름·뒷자리가 같은 수강생이 있으면 등록을 멈추고 알려줍니다.

### 3. 웹서버 배포

```bash
# 웹서버에 Docker·Tailscale 설치 후, 사설 DB 서버(Tailscale 주소 100.x)에 접속되는지 확인
cd deploy
cp ../.env.example .env      # DATABASE_URL 은 100.x 주소, STUDENT_MATCH_SECRET 은 openssl rand -hex 32
DOMAIN=attend.example.com docker compose up -d --build
```

- 도메인 DNS 를 웹서버 공인 IP로 연결하면 Caddy 가 HTTPS 인증서를 자동으로 받습니다.
- 앱 컨테이너는 외부 포트를 열지 않습니다. 이 조건이 깨지면 IP 헤더를 위조할 수 있습니다.
- 배포 후 운영자 화면의 **현재 접속 IP 확인**에 휴대폰 LTE 주소 등 실제 공인 IP가 보이는지 확인합니다. Docker 게이트웨이 주소(172.x)가 보이면 프록시 구성을 점검해야 합니다.
- `STUDENT_MATCH_SECRET` 을 잃어버리거나 바꾸면 명단 대조 값을 모두 다시 등록해야 합니다. 따로 백업해 두세요.
- 도메인에 IPv6(AAAA) 레코드는 아직 넣지 않습니다. Docker 기본 설정에서는 IPv6 로 들어온 접속의 주소가 Docker 내부 주소로 바뀌어 교육장 IP 판정이 틀어집니다. IPv6 가 필요해지면 Docker IPv6 설정 후 추가합니다.

### 데모 실행 (도메인·사설 DB 없이)

서버 안에 임시 Postgres 를 띄우고, 무료 주소 `<IP를-대시로>.sslip.io` 로 HTTPS 를 받아 전체 흐름을 먼저 시험합니다. 예시 데이터(예시학생01 / 0123, 대전 교육장 A)가 들어갑니다.

```bash
cd ~/attendance-check/deploy
IP=$(curl -s -4 https://checkip.amazonaws.com)
ADMIN_PW=$(openssl rand -base64 12 | tr -d '/+=')
cat > .env <<EOF
DOMAIN=${IP//./-}.sslip.io
DEMO_DB_ADMIN_PASSWORD=$(openssl rand -hex 16)
APP_DB_PASSWORD=$(openssl rand -hex 16)
DEMO_ADMIN_PASSWORD=$ADMIN_PW
EOF
chmod 600 .env
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --build
echo "주소: https://${IP//./-}.sslip.io/admin   운영자 비밀번호(모든 지역 공통): $ADMIN_PW"
```

- 운영자 화면에서 대전으로 입장 → **교육장 · IP** → 시험할 휴대폰·와이파이에서 **현재 접속 IP 확인** → 그 주소를 사용 중으로 등록 → 화면의 QR 로 학생 흐름을 시험합니다.
- 사설 DB(Supabase)로 옮길 때는 `.env` 에 `DATABASE_URL`, 새 `STUDENT_MATCH_SECRET` 을 넣고 `docker compose up -d` (demo 파일 없이) 로 다시 띄웁니다. 데모 데이터는 옮기지 않습니다.
- 데모 DB 를 지우려면 `docker compose -f docker-compose.yml -f docker-compose.demo.yml down -v`.
- 예시 교육생: `예시학생01`/`0123`, `예시학생02`/`4567`, `예시학생03`/`8901`, `예시학생04`/`2345`, `예시학생05`~`12` 는 `1555`, `1666` … (1000 + 번호×111).

#### 이미 띄운 데모 서버를 새 버전으로 바꾸기

데모 데이터는 버리고 새로 만듭니다(지난 평일 기록이 들어갑니다). 운영자 비밀번호는 `.env` 그대로입니다. 허용 IP 는 다시 등록해야 합니다.

```bash
cd ~/attendance-check && git pull
cd deploy
C="docker compose -f docker-compose.yml -f docker-compose.demo.yml"
$C down -v
nohup $C up -d --build > ~/deploy.log 2>&1 &
tail -f ~/deploy.log
```

데이터를 유지하고 싶다면 `down -v` 대신 `$C up -d db` 후 `$C exec -T db sh -c 'for f in /migrations/0002_screens.sql /migrations/0003_notices.sql /migrations/0004_presence.sql; do psql -v ON_ERROR_STOP=1 -U postgres -d attendance -f $f || exit 1; done'` 로 마이그레이션만 적용하고 앱을 다시 빌드합니다.

### 4. 교육장 IP 등록

1. 운영자가 교육장 와이파이에 연결한 상태에서 `/admin/networks` 의 **현재 접속 IP 확인**을 누릅니다.
2. 그 주소를 **시험 등록**으로 저장합니다.
3. 현장 휴대폰으로 확인한 뒤 **사용 중**으로 바꿉니다.
4. IPv6 를 쓰는 회선이면 휴대폰에서 IPv6 주소로도 확인해 함께 등록합니다.

## 디렉터리

```
db/migrations/0001_init.sql   스키마·출결·IP 관리·권한
db/migrations/0002_screens.sql 학생별 기록·정정·명단·누락 확인·변경 이력·내보내기·총괄 현황
db/migrations/0003_notices.sql 사전 알림, 교육장 밖 본인 확인
db/migrations/0004_presence.sql 오늘의 출석코드, 막힌 접속 기록, 같은 기기 표시
db/seed/dev.sql               로컬 예시 데이터
db/seed/dev_history.sql       데모용 지난 평일 기록
db/tests/attendance_test.sql  DB 함수 검증 (순서·중복·IP·지역 권한·IP 관리)
db/tests/screens_test.sql     DB 함수 검증 (정정·명단·누락·이력·내보내기·총괄·알림)
db/tests/presence_test.sql    DB 함수 검증 (출석코드·막힌 접속·같은 기기)
scripts/admin.mjs             지역·교육장·과정·비밀번호·명단 관리
src/app/c/[code]              학생 화면
src/app/admin                 운영자 화면 (출결 현황, 교육장·IP)
src/app/api                   API (DB 함수 호출만 함)
deploy/                       Caddy + Docker Compose
```

## 남은 일

- 백업·복구 절차와 복구 시험 (F20)
- 지역 간 교육생 이동 화면 (현재는 기존 수강 종료 후 새 지역에 등록)
- 지역·교육장·과정 추가 화면 (현재는 관리 스크립트)
- 사전 알림 도착 시 운영자 알림(메신저 등)
