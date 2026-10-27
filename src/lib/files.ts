import "server-only";

export const MAX_DOC_BYTES = 5 * 1024 * 1024;

// 파일 머리 바이트로 형식을 정한다. 브라우저가 보낸 형식이나 확장자는 믿지 않는다.
export function sniffMime(buf: Buffer): "image/jpeg" | "image/png" | "application/pdf" | null {
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "image/jpeg";
  if (buf.length >= 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (buf.length >= 5 && buf.subarray(0, 5).toString("latin1") === "%PDF-") return "application/pdf";
  return null;
}

// 파일 이름에서 경로·제어 문자를 뺀다.
export function cleanFileName(name: string): string {
  const base = name.split(/[\\/]/).pop() ?? "";
  // eslint-disable-next-line no-control-regex
  return base.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 120) || "서류";
}
