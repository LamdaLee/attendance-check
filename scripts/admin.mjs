#!/usr/bin/env node
// 운영 준비용 관리 스크립트. DB 관리자 계정(DATABASE_ADMIN_URL)으로 실행한다.
//
//   npm run admin -- set-password <daegu|daejeon|busan|super>
//   npm run admin -- add-region <code> <이름>
//   npm run admin -- add-campus <지역코드> <교육장 이름>
//   npm run admin -- add-course <지역코드> <과정 이름>
//   npm run admin -- import-students <지역코드> <파일.csv> [--apply]
//
// CSV 형식(첫 줄 머리글): name,last4,course
//   홍길동,0123,AX
// --apply 없이 실행하면 검증 결과만 보여주고 저장하지 않는다.

import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import pg from "pg";

const [command, ...args] = process.argv.slice(2);

function die(message) {
  console.error(message);
  process.exit(1);
}

function env(name) {
  const v = process.env[name];
  if (!v) die(`환경 변수 ${name} 이(가) 필요합니다. .env 를 확인해 주세요.`);
  return v;
}

// src/lib/crypto.ts 와 같은 규칙이어야 한다.
const normalizeName = (name) => name.normalize("NFC").replace(/\s+/g, "");
const last4Hmac = (last4) => createHmac("sha256", env("STUDENT_MATCH_SECRET")).update(last4).digest("hex");

function askHidden(question) {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl._writeToOutput = (s) => {
      if (s.includes(question)) process.stdout.write(s);
    };
    rl.question(question, (answer) => {
      rl.close();
      process.stdout.write("\n");
      resolve(answer);
    });
  });
}

async function withClient(fn) {
  const client = new pg.Client({ connectionString: env("DATABASE_ADMIN_URL") });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

async function regionId(client, code) {
  const { rows } = await client.query("select id from attendance.regions where code = $1", [code]);
  if (!rows[0]) die(`지역 코드 ${code} 가 없습니다.`);
  return rows[0].id;
}

function parseCsv(text) {
  const lines = text.replace(/^﻿/, "").split(/\r?\n/).filter((l) => l.trim());
  const header = lines.shift()?.split(",").map((h) => h.trim().toLowerCase());
  if (!header || ["name", "last4", "course"].some((h) => !header.includes(h))) {
    die("CSV 첫 줄은 name,last4,course 머리글이어야 합니다.");
  }
  return lines.map((line, i) => {
    const cells = line.split(",").map((c) => c.trim());
    const row = Object.fromEntries(header.map((h, j) => [h, cells[j] ?? ""]));
    return { line: i + 2, ...row };
  });
}

const commands = {
  async "set-password"([scope]) {
    if (!scope) die("사용법: set-password <지역코드|super>");
    const password = await askHidden(`${scope} 새 비밀번호: `);
    if (password.length < 10) die("비밀번호는 10자 이상으로 정해 주세요.");
    if ((await askHidden("한 번 더 입력: ")) !== password) die("비밀번호가 일치하지 않습니다.");
    await withClient(async (c) => {
      const rid = scope === "super" ? null : await regionId(c, scope);
      const hash = (await c.query("select extensions.crypt($1, extensions.gen_salt('bf', 10)) as h", [password])).rows[0].h;
      // access_version 이 바뀌면 기존 운영자 세션은 모두 해제된다.
      const updated = await c.query(
        `update attendance.operator_access
            set password_hash = $1, access_version = access_version + 1, updated_at = now()
          where ${rid === null ? "scope = 'super'" : "region_id = $2"}`,
        rid === null ? [hash] : [hash, rid],
      );
      if (updated.rowCount === 0) {
        await c.query(
          "insert into attendance.operator_access (scope, region_id, password_hash) values ($1, $2, $3)",
          [rid === null ? "super" : "region", rid, hash],
        );
      }
      await c.query(
        `insert into attendance.audit_logs (region_id, actor_scope, actor_name, action, target_table)
         values ($1, 'script', 'admin.mjs', 'access.set_password', 'operator_access')`,
        [rid],
      );
    });
    console.log(`${scope} 비밀번호를 설정했습니다. 기존 세션은 해제됩니다.`);
  },

  async "add-region"([code, name]) {
    if (!code || !name) die("사용법: add-region <code> <이름>");
    await withClient((c) => c.query("insert into attendance.regions (code, name) values ($1, $2)", [code, name]));
    console.log(`지역 ${name}(${code}) 추가`);
  },

  async "add-campus"([code, ...nameParts]) {
    const name = nameParts.join(" ");
    if (!code || !name) die("사용법: add-campus <지역코드> <교육장 이름>");
    const qr = await withClient(async (c) => {
      const { rows } = await c.query(
        "insert into attendance.campuses (region_id, name) values ($1, $2) returning qr_code",
        [await regionId(c, code), name],
      );
      return rows[0].qr_code;
    });
    console.log(`"${name}" 추가 · QR 주소: https://<도메인>/c/${qr}`);
  },

  async "add-course"([code, ...nameParts]) {
    const name = nameParts.join(" ");
    if (!code || !name) die("사용법: add-course <지역코드> <과정 이름>");
    await withClient(async (c) =>
      c.query("insert into attendance.courses (region_id, name) values ($1, $2)", [await regionId(c, code), name]),
    );
    console.log(`과정 ${name} 추가`);
  },

  async "import-students"([code, file, flag]) {
    if (!code || !file) die("사용법: import-students <지역코드> <파일.csv> [--apply]");
    const apply = flag === "--apply";
    const rows = parseCsv(readFileSync(file, "utf8"));

    await withClient(async (c) => {
      const rid = await regionId(c, code);
      const courses = new Map(
        (await c.query("select id, name from attendance.courses where region_id = $1 and is_active", [rid])).rows.map((r) => [r.name, r.id]),
      );
      const existing = new Set(
        (await c.query(
          "select name_key || ':' || last4_hmac as k from attendance.enrollments where region_id = $1 and status = 'active'",
          [rid],
        )).rows.map((r) => r.k),
      );

      const errors = [];
      const seen = new Map();
      const valid = [];
      for (const r of rows) {
        const nameKey = normalizeName(r.name);
        if (!nameKey) errors.push(`${r.line}행: 이름이 비어 있습니다.`);
        else if (!/^\d{4}$/.test(r.last4)) errors.push(`${r.line}행: 뒷자리는 숫자 4자리여야 합니다. (앞의 0 유지, 엑셀이면 텍스트 형식으로 저장)`);
        else if (!courses.has(r.course)) errors.push(`${r.line}행: 과정 "${r.course}" 이(가) 이 지역에 없습니다.`);
        else {
          const key = `${nameKey}:${last4Hmac(r.last4)}`;
          if (existing.has(key)) errors.push(`${r.line}행: ${r.name} — 같은 이름·뒷자리의 수강 중 교육생이 이미 있습니다.`);
          else if (seen.has(key)) errors.push(`${r.line}행: ${r.name} — ${seen.get(key)}행과 이름·뒷자리가 같습니다.`);
          else {
            seen.set(key, r.line);
            valid.push({ ...r, nameKey, hmac: last4Hmac(r.last4), courseId: courses.get(r.course) });
          }
        }
      }

      console.log(`전체 ${rows.length}행 · 등록 가능 ${valid.length}행 · 오류 ${errors.length}행`);
      for (const e of errors) console.log(`  ✗ ${e}`);
      if (errors.length) die("오류를 고친 뒤 다시 실행해 주세요. 아무것도 저장하지 않았습니다.");
      if (!apply) {
        console.log("검증만 했습니다. 저장하려면 --apply 를 붙여 다시 실행하세요.");
        return;
      }

      await c.query("begin");
      try {
        for (const v of valid) {
          const { rows: [s] } = await c.query("insert into attendance.students (name) values ($1) returning id", [v.name.trim()]);
          await c.query(
            `insert into attendance.enrollments (student_id, region_id, course_id, name_key, last4_hmac)
             values ($1, $2, $3, $4, $5)`,
            [s.id, rid, v.courseId, v.nameKey, v.hmac],
          );
        }
        await c.query(
          `insert into attendance.audit_logs (region_id, actor_scope, actor_name, action, target_table, after)
           values ($1, 'script', 'admin.mjs', 'students.import', 'enrollments', $2)`,
          [rid, JSON.stringify({ file, count: valid.length })],
        );
        await c.query("commit");
      } catch (err) {
        await c.query("rollback");
        throw err;
      }
      console.log(`${valid.length}명을 등록했습니다.`);
    });
  },
};

const run = commands[command];
if (!run) die(`알 수 없는 명령입니다. 사용 가능: ${Object.keys(commands).join(", ")}`);
run(args).catch((err) => die(err.message));
