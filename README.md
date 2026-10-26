# 지역별 QR 출결

대구·대전·부산 교육생이 교육장 와이파이에 연결한 뒤 QR로 접속하고, 이름과 전화번호 뒷자리로 본인을 확인해 입실·외출·복귀·퇴실을 기록하는 보조 출결 시스템입니다. 공식 LMS 출석 판정을 대신하지 않습니다.

- 앱: Next.js(모바일 웹) — 학생 화면 `/c/<교육장 QR 코드>`, 운영자 화면 `/admin`
- DB: 직접 설치한 Supabase 의 Postgres, 전용 스키마 `attendance`

## 구성

```
학생 휴대폰 / 운영자 PC
      │ HTTPS
      ▼
웹서버 ── Caddy (HTTPS, 실제 접속 IP를 X-Real-IP 로 덮어씀)
      └─ 출결 앱 컨테이너 (외부 포트 없음)
              │ Tailscale 사설 주소 (100.x)
              ▼
집 PC ── Supabase Postgres (attendance 스키마)
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

npm run db:migrate            # 스키마·함수 생성
npm run db:seed:dev           # 예시 데이터 (운영 DB에는 실행하지 않음)
npm run db:test               # DB 함수 검증 → ALL TESTS PASSED
psql "$DATABASE_ADMIN_URL" -c "alter role attendance_app login password 'dev'"

npm run dev
```

- 학생 화면: http://localhost:3000/c/dev-daejeon-a — 이름 `예시학생01`, 뒷자리 `0123`
- 운영자 화면: http://localhost:3000/admin — 대전 `daejeon-dev`, 총괄 `super-dev`
- 개발 서버는 IP 헤더가 없으면 `DEV_CLIENT_IP`(127.0.0.1)를 씁니다. 예시 데이터는 127.0.0.1 을 대전 교육장 A 의 허용 주소로 등록해 둡니다.
- 와이파이가 아닌 경우를 보려면 `DEV_CLIENT_IP=8.8.8.8` 로 바꿔 실행합니다.

## 운영 준비

### 1. 집 PC Supabase 에 스키마 적용

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
# 웹서버에 Docker·Tailscale 설치 후, 집 PC(100.67.186.67)에 접속되는지 확인
cd deploy
cp ../.env.example .env      # DATABASE_URL 은 100.x 주소, STUDENT_MATCH_SECRET 은 openssl rand -hex 32
DOMAIN=attend.example.com docker compose up -d --build
```

- 도메인 DNS 를 웹서버 공인 IP로 연결하면 Caddy 가 HTTPS 인증서를 자동으로 받습니다.
- 앱 컨테이너는 외부 포트를 열지 않습니다. 이 조건이 깨지면 IP 헤더를 위조할 수 있습니다.
- 배포 후 운영자 화면의 **현재 접속 IP 확인**에 휴대폰 LTE 주소 등 실제 공인 IP가 보이는지 확인합니다. Docker 게이트웨이 주소(172.x)가 보이면 프록시 구성을 점검해야 합니다.
- `STUDENT_MATCH_SECRET` 을 잃어버리거나 바꾸면 명단 대조 값을 모두 다시 등록해야 합니다. 따로 백업해 두세요.

### 4. 교육장 IP 등록

1. 운영자가 교육장 와이파이에 연결한 상태에서 `/admin/networks` 의 **현재 접속 IP 확인**을 누릅니다.
2. 그 주소를 **시험 등록**으로 저장합니다.
3. 현장 휴대폰으로 확인한 뒤 **사용 중**으로 바꿉니다.
4. IPv6 를 쓰는 회선이면 휴대폰에서 IPv6 주소로도 확인해 함께 등록합니다.

## 디렉터리

```
db/migrations/0001_init.sql   스키마·함수·권한
db/seed/dev.sql               로컬 예시 데이터
db/tests/attendance_test.sql  DB 함수 검증 (순서·중복·IP·지역 권한·IP 관리)
scripts/admin.mjs             지역·교육장·과정·비밀번호·명단 관리
src/app/c/[code]              학생 화면
src/app/admin                 운영자 화면 (출결 현황, 교육장·IP)
src/app/api                   API (DB 함수 호출만 함)
deploy/                       Caddy + Docker Compose
```

## 다음 단계 (요구서 기준 미구현)

- 학생별 월간 기록 화면 (F13)
- 정정 요청·승인 (F15) — 테이블만 준비됨
- 교육생 명단 화면과 웹 일괄 등록 (F10·F11) — 현재는 관리 스크립트
- 누락 확인 목록 (F14), 변경 이력 화면 (F18), CSV 내보내기 (F17)
- 총괄 전체 현황 화면 (F12 WF12) — 현재는 총괄이 지역을 전환해서 조회
- 백업·복구 절차 (F20)
