"use client";

import { useEffect, useState } from "react";

export const LAST_CAMPUS_KEY = "att_last_campus";

type InstallEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };

// 홈 화면에 바로가기 추가. 안드로이드(크롬·삼성 인터넷)는 설치 창을 띄우고, 아이폰은 방법을 안내한다.
// 이미 바로가기로 열었으면 보이지 않는다.
export default function InstallCard() {
  const [installed, setInstalled] = useState(true);
  const [prompt, setPrompt] = useState<InstallEvent | null>(null);
  const [ios, setIos] = useState(false);
  const [showGuide, setShowGuide] = useState(false);

  useEffect(() => {
    const standalone = window.matchMedia("(display-mode: standalone)").matches
      || (navigator as Navigator & { standalone?: boolean }).standalone === true;
    setInstalled(standalone);
    setIos(/iphone|ipad|ipod/i.test(navigator.userAgent));
    const onPrompt = (e: Event) => {
      e.preventDefault();
      setPrompt(e as InstallEvent);
    };
    const onInstalled = () => setInstalled(true);
    window.addEventListener("beforeinstallprompt", onPrompt);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", onPrompt);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);

  if (installed) return null;

  async function install() {
    if (!prompt) {
      setShowGuide(true);
      return;
    }
    await prompt.prompt();
    await prompt.userChoice.catch(() => null);
    setPrompt(null);
  }

  return (
    <div className="card">
      <div className="row between">
        <h2 style={{ margin: 0 }}>홈 화면에 바로가기</h2>
        <button type="button" className="btn ghost sm" onClick={install}>{prompt ? "추가하기" : "방법 보기"}</button>
      </div>
      <p className="small">한 번 추가해 두면 다음부터 QR 없이 아이콘으로 바로 열립니다. 교육장 와이파이에 연결돼 있으면 그 교육장 화면으로 자동으로 들어갑니다.</p>
      {showGuide && (
        <ol className="small" style={{ margin: "8px 0 0", paddingLeft: 18, lineHeight: 1.7 }}>
          {ios ? (
            <>
              <li>사파리 아래쪽의 공유 버튼(네모에 위쪽 화살표)을 누릅니다.</li>
              <li>목록에서 &lsquo;홈 화면에 추가&rsquo;를 누릅니다.</li>
              <li>오른쪽 위 &lsquo;추가&rsquo;를 누르면 홈 화면에 &lsquo;출결&rsquo; 아이콘이 생깁니다.</li>
            </>
          ) : (
            <>
              <li>브라우저 오른쪽 위(또는 아래)의 메뉴(⋮ 또는 ≡)를 누릅니다.</li>
              <li>&lsquo;홈 화면에 추가&rsquo; 또는 &lsquo;앱 설치&rsquo;를 누릅니다.</li>
              <li>&lsquo;추가&rsquo;를 누르면 홈 화면에 &lsquo;출결&rsquo; 아이콘이 생깁니다.</li>
            </>
          )}
        </ol>
      )}
    </div>
  );
}
