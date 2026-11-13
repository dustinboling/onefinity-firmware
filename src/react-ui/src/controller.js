import { useEffect, useRef, useState, useCallback } from "react";

// P-01: the server gates the destructive / admin endpoints behind the
// controller's OS password (X-Admin-Password header, loopback exempt).
// From another browser on the LAN those calls come back 401, so on a
// 401 from a gated call we ask the operator for the password once,
// keep it for this browser session only (sessionStorage — never
// localStorage, never a cookie) and retry the call once.  A password
// that still gets a 401 is forgotten again, so a wrong entry surfaces
// as the call's normal error instead of prompting in a loop.  The
// header is attached only to gated calls, so normal machine operation
// (jog, home, run, e-stop) never carries or prompts for it.
const ADMIN_PASSWORD_KEY = "bbctrl-admin-password";
const ADMIN_PATHS = new Set([
  "reboot", "shutdown", "hostname", "network", "remote/username",
  "remote/password", "config/restore", "config/reset",
  "firmware/update", "upgrade", "screen-rotation", "time",
]);

function isAdminCall(method, url) {
  if (method === "GET") return false;
  const path = url.split("?")[0].replace(/^\//, "");
  // FileHandler gates only DELETE; uploads and downloads stay open.
  if (path === "file" || path.startsWith("file/")) return method === "DELETE";
  return ADMIN_PATHS.has(path);
}

function storedAdminPassword() {
  try { return sessionStorage.getItem(ADMIN_PASSWORD_KEY) || ""; } catch { return ""; }
}

function clearAdminPassword() {
  try { sessionStorage.removeItem(ADMIN_PASSWORD_KEY); } catch { /* no storage */ }
}

function askAdminPassword() {
  const password = window.prompt(
    "This action needs the controller password. Enter it to continue:");
  if (password) {
    try { sessionStorage.setItem(ADMIN_PASSWORD_KEY, password); } catch { /* no storage */ }
  }
  return password || "";
}

async function fetchApi(method, url, opts, retried = false, password = "") {
  const headers = { ...(opts.headers || {}) };
  if (isAdminCall(method, url)) {
    const adminPassword = password || storedAdminPassword();
    if (adminPassword) headers["X-Admin-Password"] = adminPassword;
  }
  const r = await fetch(`/api/${url}`, { ...opts, method, headers });
  if (r.status === 401 && isAdminCall(method, url)) {
    clearAdminPassword();
    const entered = retried ? "" : askAdminPassword();
    if (entered) return fetchApi(method, url, opts, true, entered);
  }
  return r;
}

// Raw variant for callers that need the Response itself (they check
// r.ok and read the body their own way), e.g. config restore.
export const apiFetch = (url, opts = {}) =>
  fetchApi((opts.method || "GET").toUpperCase(), url, opts);

async function call(method, url, body) {
  const opts = { cache: "no-cache", headers: {} };
  if (body !== undefined) {
    if (body instanceof Blob || body instanceof FormData) opts.body = body;
    else { opts.headers["Content-Type"] = "application/json; charset=utf-8"; opts.body = JSON.stringify(body); }
  }
  const r = await fetchApi(method, url, opts);
  if (!r.ok) throw new Error(await r.text());
  const text = await r.text();
  try { return JSON.parse(text); } catch { return text; }
}
export const api = {
  get: (u) => call("GET", u),
  put: (u, b) => call("PUT", u, b),
  del: (u) => call("DELETE", u),
};

export const MACRO_PREFIX = "EgZjaHJvbWUqCggBEAAYsQMYgAQyBggAEEUYOTIKCAE";
export const DELETE_LIST_PREFIX = "DINCAIQABiDARixAxiABDIHCAMQABiABDIHCAQQABiABDIH";

const abortError = () => { const e = new Error("Aborted"); e.name = "AbortError"; return e; };
const waitOrAbort = (ms, signal) => new Promise((resolve, reject) => {
  if (signal && signal.aborted) { reject(abortError()); return; }
  const t = setTimeout(resolve, ms);
  if (signal) signal.addEventListener("abort", () => { clearTimeout(t); reject(abortError()); }, { once: true });
});

// Polls the planner until the path is ready. Bounded (3 minutes) and cancellable through
// the caller's AbortSignal: a wedged plan used to leave a poller running against the
// controller for the life of the page on every file selection, with the tabs stuck on
// "Planning the tool path…" and no failure ever shown.
export async function loadPath(file, signal) {
  const deadline = Date.now() + 3 * 60 * 1000;
  for (;;) {
    if (signal && signal.aborted) throw abortError();
    const info = await api.get(`path/${encodeURIComponent(file)}`);
    if (info.progress === undefined || info.progress === 1) {
      const [p, s] = await Promise.all(
        ["positions", "speeds"].map((k) =>
          fetch(`/api/path/${encodeURIComponent(file)}/${k}`, { signal }).then((r) => r.arrayBuffer())
        )
      );
      return { bounds: info.bounds, time: info.time, lines: info.lines, positions: new Float32Array(p), speeds: new Float32Array(s) };
    }
    if (Date.now() > deadline) throw new Error("The controller took too long to plan this program.");
    await waitOrAbort(500, signal);
  }
}

import { recordDown, recordUp } from "./drops.js";
import { linkVerdict, WATCH_MS } from "./linkwatch.js";
import { ME, readUi, uiSet, uiClose, useUiTick } from "./shared.js";

// Live machine state over the controller's raw websocket.
export function useController() {
  const [state, setState] = useState({});
  const [online, setOnline] = useState(false);
  const [logs, setLogs] = useState([]);
  const [lastError, setLastError] = useState(null);
  const ws = useRef(null);
  const listeners = useRef(new Set());
  const storeRev = useRef(null);

  useEffect(() => {
    let closed = false, timer, lastMsg = Date.now(), everUp = false, lastTick = Date.now();
    // Close a silent link so it reconnects and the drop is logged (linkwatch.js, 1.31.2: 20 s, and a
    // late check is skipped because then this page was frozen, not the link).
    const watch = setInterval(() => {
      const now = Date.now(), s = ws.current;
      const v = linkVerdict({ now, lastTick, lastMsg, open: !!s && s.readyState === 1, hidden: document.hidden });
      lastTick = now;
      if (v === "dead") { recordDown(`No data for ${Math.round((now - lastMsg) / 1000)} s`); setOnline(false); s.close(); }
    }, WATCH_MS);
    const connect = () => {
      const proto = location.protocol === "https:" ? "wss" : "ws";
      const s = new WebSocket(`${proto}://${location.host}/websocket`);
      ws.current = s;
      s.onopen = () => { lastMsg = Date.now(); everUp = true; recordUp(); setOnline(true); };
      s.onmessage = (e) => {
        lastMsg = Date.now();
        let d; try { d = JSON.parse(e.data); } catch { return; }
        setOnline(true);
        delete d.heartbeat;
        if (!Object.keys(d).length) return;
        listeners.current.forEach((f) => f(d));
        // Another screen saved a shared document (notes, history, settings): re-read it here too.
        if (d.store_rev && typeof d.store_rev === "object") {
          const prev = storeRev.current; storeRev.current = d.store_rev;
          for (const [name, n] of Object.entries(d.store_rev)) {
            if (prev && prev[name] !== n) { try { window.dispatchEvent(new Event(`next-store:${name}`)); } catch { /* old browser */ } }
          }
        }
        if (d.log) {
          const m = { ...d.log, level: d.log.level || "info", id: Math.random() };
          setLogs((l) => {
            if (l.length && l[0].msg === m.msg && l[0].level === m.level) return [{ ...l[0], repeat: (l[0].repeat || 1) + 1 }, ...l.slice(1)];
            return [m, ...l].slice(0, 256);
          });
          if (m.level === "error" || m.level === "critical") setLastError({ ...m, at: Date.now() });
        }
        setState((prev) => {
          if (d.sid && prev.sid && d.sid !== prev.sid) location.reload();
          return { ...prev, ...d };
        });
      };
      s.onclose = () => { setOnline(false); if (!closed && everUp) recordDown("Connection closed"); if (!closed) timer = setTimeout(connect, 2000); };
    };
    connect();
    return () => { closed = true; clearTimeout(timer); clearInterval(watch); ws.current && ws.current.close(); };
  }, []);

  // true when the command went to the controller, false when it could not be sent (1.29.0: before, a
  // command typed or sent while the connection was down was dropped without a word).
  const send = useCallback((gcode) => {
    if (!ws.current || ws.current.readyState !== 1) return false;
    try { ws.current.send(gcode); return true; } catch { return false; }
  }, []);
  const subscribe = useCallback((fn) => { listeners.current.add(fn); return () => listeners.current.delete(fn); }, []);
  return { state, online, send, subscribe, logs, clearLogs: () => setLogs([]), lastError, clearError: () => setLastError(null) };
}

const clone = (o) => JSON.parse(JSON.stringify(o));

function fixVersion(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:[-.]?(.*))?$/.exec((v || "").trim());
  if (!m) return v || "";
  let out = `${m[1]}.${m[2]}.${m[3]}`;
  if (m[4]) {
    const b = /([a-zA-Z])(\d+)/.exec(m[4]);
    out += b && b[1] === "b" ? `-beta.${b[2]}` : `-${m[4]}`;
  }
  return out;
}

// Configuration: the saved copy from the controller plus the operator's unsaved edits.
// Unsaved edits are part of the shared session ("cfg-draft"): a setting changed on the PC shows as unsaved on
// the touchscreen too, and Save or Discard on any screen finishes it everywhere.
export function useConfig(state) {
  useUiTick();
  const [draft, setDraft] = useState(null);
  const [template, setTemplate] = useState(null);
  const [net, setNet] = useState({});
  const [modified, setModified] = useState(false);
  const modRef = useRef(false);
  modRef.current = modified;

  const reload = useCallback(async (force) => {
    const c = await api.get("config/load");
    c.full_version = fixVersion(c.full_version);
    if (force || !modRef.current) { setDraft(c); setModified(false); }
    api.get("wifi").then((w) => setNet({ ip: w.ipAddresses, wifi: w.wifi })).catch(() => {});
    return c;
  }, []);

  useEffect(() => {
    reload(true).then(() => {
      // Another screen has unsaved edits: show them here as well.
      const sh = sharedRef.current;
      if (sh && sh.by !== ME && sh.draft) { setDraft(sh.draft); setModified(true); }
    }).catch(() => {});
    fetch("/config-template.json", { cache: "no-cache" }).then((r) => r.json()).then(setTemplate).catch(() => {});
  }, [reload]);

  const shareTimer = useRef(null);
  const shareDraft = useCallback((c) => {
    clearTimeout(shareTimer.current);
    shareTimer.current = setTimeout(() => uiSet("cfg-draft", { by: ME, draft: c, at: Date.now() }).catch(() => {}), 300);
  }, []);
  const edit = useCallback((fn) => {
    setDraft((d) => { if (!d) return d; const c = clone(d); fn(c); shareDraft(c); return c; });
    setModified(true);
  }, [shareDraft]);

  // Follow edits made on another screen, and its Save or Discard.
  const shared = readUi(state, "cfg-draft").v;
  const sharedRef = useRef(null);
  useEffect(() => {
    const prev = sharedRef.current; sharedRef.current = shared;
    if (shared && shared.by !== ME && shared.draft) {
      setDraft((d) => (JSON.stringify(d) === JSON.stringify(shared.draft) ? d : shared.draft));
      setModified(true);
    } else if (!shared && prev && modRef.current) {
      clearTimeout(shareTimer.current);
      reload(true).catch(() => {});
    }
  }, [shared && shared.at, !!shared]); // eslint-disable-line react-hooks/exhaustive-deps
  // Saved on another screen: take the new saved copy unless there are edits here.
  useEffect(() => {
    const f = () => { if (!modRef.current) reload(true).catch(() => {}); };
    window.addEventListener("next-store:config", f);
    return () => window.removeEventListener("next-store:config", f);
  }, [reload]);

  const patch = useCallback((fn) => {
    setDraft((d) => { if (!d) return d; const c = clone(d); fn(c); return JSON.stringify(c) === JSON.stringify(d) ? d : c; });
  }, []);

  const save = useCallback(async (extra) => {
    const c = clone(draft);
    for (const k of ["macros", "macros_list", "non_macros_list", "gcode_list"]) if (state[k]) c[k] = clone(state[k]);
    if (extra) extra(c);
    const sel = c.tool && c.tool["selected-tool"];
    if (sel) {
      const saveModbus = sel !== "pwm" && sel !== "laser" && sel !== "router";
      const tool = { ...c.tool }; delete tool["tool-type"];
      c["selected-tool-settings"] = c["selected-tool-settings"] || {};
      c["selected-tool-settings"][sel] = { tool, "pwm-spindle": { ...c["pwm-spindle"] }, "modbus-spindle": saveModbus ? { ...c["modbus-spindle"] } : undefined };
    }
    await api.put("config/save", c);
    clearTimeout(shareTimer.current);
    setModified(false);
    uiClose("cfg-draft");
    await reload(true);
  }, [draft, state, reload]);

  // Change only the program lists (folders, files) in the saved settings. Unsaved edits to other settings,
  // on this screen or another, are not saved by it and stay unsaved.
  // The server offers no compare-and-set for the config, so this narrows the read-modify-write
  // window instead: the lists are re-read immediately before the save, and if another screen
  // changed them in the meantime the mutation is re-applied to that fresh copy and retried —
  // never blindly saved over the top (which used to resurrect files another screen had deleted,
  // or drop folders it had just created). If the lists keep changing, it gives up loudly.
  const saveLists = useCallback(async (fn) => {
    const LIST_KEYS = ["gcode_list", "non_macros_list", "macros_list"];
    const snap = (c) => JSON.stringify(LIST_KEYS.map((k) => c[k] || null));
    let base = await api.get("config/load");
    for (let attempt = 0; attempt < 3; attempt++) {
      const c = clone(base);
      fn(c);
      const fresh = await api.get("config/load");
      if (snap(fresh) !== snap(base)) { base = fresh; continue; }
      await api.put("config/save", c);
      const after = await api.get("config/load");
      after.full_version = fixVersion(after.full_version);
      setDraft((d) => (!d || !modRef.current ? after : { ...d, gcode_list: after.gcode_list, non_macros_list: after.non_macros_list, macros_list: after.macros_list }));
      return;
    }
    throw new Error("The program lists changed on another screen each time this tried to save. Nothing was overwritten — try again.");
  }, []);
  const discard = useCallback(() => { clearTimeout(shareTimer.current); uiClose("cfg-draft"); return reload(true); }, [reload]);
  return { config: draft, template, net, modified, edit, patch, save, saveLists, reload, discard };
}

export const metricOf = (config) => !config || (config.settings?.units || "METRIC") === "METRIC";
