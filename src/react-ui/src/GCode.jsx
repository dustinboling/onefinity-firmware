import React, { memo, useEffect, useMemo, useRef, useState } from "react";
import { getPrefs } from "./checkpoint.js";
import { colorLines } from "./gcodeColor.js";

// A real CAM program is 10k–500k lines, so the list is windowed: only the lines around the
// scroll position (plus an overscan) become DOM nodes, with spacer blocks holding the height
// of the rest — the job the legacy viewer did with Clusterize. Rows are a fixed height (the
// .code font's line height) so the window maths is exact. The component takes only the props
// it renders (line, selected, lines) and is memoised, so unrelated controller state ticks
// don't re-render it while a job runs.
const ROW_H = 22.4; // 14px font at line-height 1.6, see .code in styles.css
const OVERSCAN = 60;

function GCode({ line, selected, lines, tooLarge }) {
  const box = useRef(null);
  const [colors, setColors] = useState(false);
  const [view, setView] = useState({ top: 0, height: 600 });
  useEffect(() => { getPrefs().then((p) => setColors(!!p.gcodeColors)); }, []);
  const tagged = useMemo(() => (colors ? colorLines(lines) : null), [colors, lines]);

  // Follow the running line: bring it into view when it leaves the window, without
  // forcing a scroll (and layout of the whole list) on every line tick.
  useEffect(() => {
    const el = box.current;
    if (!el || !line) return;
    const top = (line - 1) * ROW_H;
    if (top < el.scrollTop || top + ROW_H > el.scrollTop + el.clientHeight) {
      el.scrollTop = Math.max(0, top - el.clientHeight / 2);
      setView({ top: el.scrollTop, height: el.clientHeight });
    }
  }, [line, lines]);

  useEffect(() => {
    const el = box.current;
    if (!el) return undefined;
    const measure = () => setView((v) => ({ top: el.scrollTop, height: el.clientHeight || v.height }));
    measure();
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [lines]);

  if (!selected) return <p className="empty">Pick a program in Files to read its G-code here.</p>;
  if (tooLarge) return <p className="empty">This program is too large to show here (over 20 MB) — the G-code view is disabled for it, as in the classic interface. It can still be run.</p>;

  const start = Math.min(Math.max(0, Math.floor(view.top / ROW_H) - OVERSCAN), Math.max(0, lines.length - 1));
  const end = Math.min(lines.length, start + Math.ceil(view.height / ROW_H) + OVERSCAN * 2);
  return (
    <pre className="code" ref={box} onScroll={() => { const el = box.current; if (el) setView({ top: el.scrollTop, height: el.clientHeight }); }}>
      {start > 0 && <div style={{ height: start * ROW_H }} />}
      {lines.slice(start, end).map((l, j) => {
        const i = start + j;
        const t = tagged && tagged[i];
        const cls = [i + 1 === line ? "now" : "", t && t.marker ? "tag-marker" : ""].filter(Boolean).join(" ");
        return (
          <div key={i} className={cls} style={{ height: ROW_H, ...(t && t.color ? { color: t.color } : {}) }}>
            <span>{i + 1}</span>{t ? t.text : l}
          </div>
        );
      })}
      {end < lines.length && <div style={{ height: (lines.length - end) * ROW_H }} />}
    </pre>
  );
}

export default memo(GCode);
