import type { MetadataRoute } from "next";

// 홈 화면 바로가기(설치) 정보. 첫 화면(/)이 접속한 교육장으로 바로 이어 준다.
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "교육장 출결",
    short_name: "출결",
    description: "교육장 와이파이로 확인하는 입실·퇴실 기록",
    start_url: "/",
    scope: "/",
    display: "standalone",
    background_color: "#f3f4fa",
    theme_color: "#6d6ff7",
    lang: "ko",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
      { src: "/icons/maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
