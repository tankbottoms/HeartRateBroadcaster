// Measures the language menu against the viewport at phone widths, in a
// throwaway headless Chrome. Nothing here touches a browser the user is using.
//
//   bun scratchpad/measure-lang.ts [origin]
//
// Prints, per width, where the open menu's box actually lands. The bug this
// exists to catch is a menu that hangs off the LEFT edge — there is no
// horizontal scroll to chase it with, so the languages are simply unreachable.
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ORIGIN = process.argv[2] ?? "https://heart-rate.atsignhandle.xyz";
const CHROME =
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9222 + Math.floor(process.uptime() % 400);
const profile = mkdtempSync(join(tmpdir(), "lang-measure-"));

const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "about:blank",
  ],
  { stdio: "ignore" },
);

const cleanup = () => {
  chrome.kill();
  rmSync(profile, { recursive: true, force: true });
};
process.on("exit", cleanup);

// Chrome needs a moment before /json/version answers.
interface DevToolsVersion {
  webSocketDebuggerUrl: string;
}

let ws = "";
for (let i = 0; i < 40 && !ws; i++) {
  await Bun.sleep(250);
  try {
    // SAFETY: /json/version is the DevTools protocol's own handshake endpoint and
    // always carries the socket URL. A reply without it leaves `ws` empty, which
    // the loop condition treats exactly like a connection refused — retry, then
    // fail on the guard below.
    const version = (await (
      await fetch(`http://127.0.0.1:${PORT}/json/version`)
    ).json()) as DevToolsVersion;
    ws = version.webSocketDebuggerUrl;
  } catch {}
}
if (!ws) throw new Error("headless Chrome never came up");

const sock = new WebSocket(ws);
await new Promise((r) => (sock.onopen = r));

let id = 0;
const pending = new Map<number, (v: any) => void>();
const events = new Map<string, () => void>();
sock.onmessage = (m) => {
  const msg = JSON.parse(String(m.data));
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)!(msg);
    pending.delete(msg.id);
  }
  if (msg.method && events.has(msg.method)) events.get(msg.method)!();
};
const send = (method: string, params: any = {}, sessionId?: string) =>
  new Promise<any>((res) => {
    const n = ++id;
    pending.set(n, res);
    sock.send(JSON.stringify({ id: n, method, params, sessionId }));
  });

const { result: target } = await send("Target.createTarget", { url: "about:blank" });
const { result: attached } = await send("Target.attachToTarget", {
  targetId: target.targetId,
  flatten: true,
});
const session = attached.sessionId;
await send("Page.enable", {}, session);
await send("Runtime.enable", {}, session);

const evaluate = async (expression: string) => {
  const r = await send(
    "Runtime.evaluate",
    { expression, returnByValue: true, awaitPromise: true },
    session,
  );
  if (r.result?.exceptionDetails)
    throw new Error(r.result.exceptionDetails.exception?.description ?? "eval failed");
  return r.result.result.value;
};

const measure = async (width: number, path: string) => {
  const loaded = new Promise<void>((r) => events.set("Page.loadEventFired", () => r()));
  await send("Page.navigate", { url: ORIGIN + path }, session);
  await loaded;
  events.delete("Page.loadEventFired");
  // After the load, not before it: an override applied to the outgoing page
  // does not always survive the navigation, and the measurement then silently
  // describes the previous width.
  await send(
    "Emulation.setDeviceMetricsOverride",
    { width, height: 800, deviceScaleFactor: 2, mobile: true },
    session,
  );
  await Bun.sleep(500);
  return evaluate(`(() => {
    const d = document.querySelector("details.lang");
    if (!d) return { error: "no picker" };
    d.open = true;
    const u = d.querySelector("ul").getBoundingClientRect();
    const s = d.querySelector("summary").getBoundingClientRect();
    return {
      menu: { l: Math.round(u.left), r: Math.round(u.right), w: Math.round(u.width) },
      trigger: { l: Math.round(s.left), r: Math.round(s.right) },
      vw: innerWidth,
      scrollable: document.documentElement.scrollWidth > innerWidth,
    };
  })()`);
};

const cases: [number, string][] = [
  [320, "/"],
  [360, "/"],
  [375, "/"],
  [390, "/about"],
  [430, "/"],
  [640, "/"],
  [720, "/"],
  [375, "/ar/index.html"],
  [375, "/ja/about.html"],
  [320, "/nb/faq.html"],
];

let bad = 0;
for (const [w, path] of cases) {
  const m = await measure(w, path);
  if (m.error) {
    console.log(`${String(w).padStart(4)}px ${path.padEnd(20)} ${m.error}`);
    bad++;
    continue;
  }
  const fits = m.menu.l >= -1 && m.menu.r <= m.vw + 1;
  if (!fits || m.scrollable) bad++;
  console.log(
    `${String(w).padStart(4)}px ${path.padEnd(20)} menu[${String(m.menu.l).padStart(4)}..${String(m.menu.r).padStart(4)}] w=${String(m.menu.w).padStart(3)}  vw=${m.vw}  ${fits ? "on screen" : "OFF SCREEN"}${m.scrollable ? "  H-SCROLL" : ""}`,
  );
}

console.log(bad ? `\n${bad} failing case(s)` : "\nall cases on screen, no horizontal scroll");
sock.close();
cleanup();
process.exit(bad ? 1 : 0);
