import Link from "next/link";

export default function Home() {
  return (
    <main className="m-shell">
      <section className="m-hero">
        <p className="eyebrow">대구 · 대전 · 부산</p>
        <h1>QR 출결</h1>
        <p className="sub">교육장 와이파이에 연결한 뒤 게시된 QR을 스캔해 주세요.</p>
      </section>
      <div className="m-body">
        <div className="card">
          <h2>교육생</h2>
          <p className="small">이 주소로는 출결을 기록할 수 없습니다. 교육장에 붙어 있는 QR로 접속해 주세요.</p>
        </div>
        <div className="card">
          <h2>운영자</h2>
          <Link className="btn ghost block" href="/admin">운영자 화면 입장</Link>
        </div>
      </div>
    </main>
  );
}
