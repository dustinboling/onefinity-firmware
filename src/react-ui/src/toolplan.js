import { useEffect, useState } from "react";

// Reads the selected program and finds its tool changes (an M6, with the T word before or on it).
export function parseToolChanges(lines) {
  const out = [];
  let pending = null;
  lines.forEach((raw, i) => {
    const l = raw.replace(/\([^)]*\)/g, "").replace(/;.*$/, "");
    const t = /(?:^|[^A-Za-z])T\s*(\d+)/i.exec(l);
    if (t) pending = Number(t[1]);
    if (/(?:^|[^A-Za-z])M0*6(?!\d)/i.test(l) && pending !== null) out.push({ line: i + 1, tool: pending });
  });
  return out;
}

// Same guard the legacy viewer had: above this the G-code tab is disabled rather than
// splitting (and rendering) a program with hundreds of thousands of lines.
export const MAX_PROGRAM_CHARS = 20e6;

export function useProgram(state) {
  const [doc, setDoc] = useState({ lines: [], tooLarge: false });
  useEffect(() => {
    if (!state.selected) { setDoc({ lines: [], tooLarge: false }); return; }
    let dead = false;
    fetch(`/api/file/${encodeURIComponent(state.selected)}`, { cache: "no-cache" })
      .then((r) => r.text())
      .then((t) => { if (!dead) setDoc(t.length > MAX_PROGRAM_CHARS ? { lines: [], tooLarge: true } : { lines: t.split("\n"), tooLarge: false }); })
      .catch(() => !dead && setDoc({ lines: [], tooLarge: false }));
    return () => { dead = true; };
  }, [state.selected, state.selected_time]);
  return doc;
}
