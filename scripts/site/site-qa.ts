#!/usr/bin/env bun
/**
 * Renders the built site in a real browser at phone, tablet and desktop widths,
 * in every language, and reports what does not fit.
 *
 * The checks are the ones a screenshot would show you and a static reader
 * cannot: whether the page scrolls sideways, whether a line of text is clipped
 * by the box around it, whether an image 404ed, whether the nav row wrapped.
 * Twenty-five languages is exactly the case where eyeballing does not scale —
 * the layout was designed against English, and English is the shortest of them.
 *
 *   bun scripts/site-qa.ts                  # every language, every viewport
 *   bun scripts/site-qa.ts --lang de,ar     # only these
 *   bun scripts/site-qa.ts --shots          # also write PNGs to .qa/
 *
 * Uses the Chromium that Playwright has already downloaded rather than pulling
 * its own: the browser is 150 MB and this script is not worth that twice.
 */

import { chromium } from "playwright-core";
import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { LOCALES } from "../lib/locales";

const DIST = "web/dist";
const CHROME = `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;

/**
 * Three widths, chosen where the layout actually changes rather than at round
 * numbers: 390 is the iPhone the page is mostly read on, 768 is an iPad in
 * portrait and the width the nav row was measured against, 1440 is a laptop.
 * The iPad in landscape is the desktop layout at a shorter height and is
 * covered by 1440.
 */
const VIEWPORTS = [
  { name: "phone", width: 390, height: 844, dsf: 3 },
  { name: "ipad", width: 768, height: 1024, dsf: 2 },
  { name: "desktop", width: 1440, height: 900, dsf: 2 },
];

const argv = process.argv.slice(2);
const arg = (flag: string) => {
  const i = argv.indexOf(flag);
  return i === -1 ? undefined : argv[i + 1];
};
const only = arg("--lang")?.split(",");
const shots = argv.includes("--shots");

if (!existsSync(DIST)) throw new Error(`${DIST} does not exist — run scripts/site.ts first`);
if (!existsSync(CHROME)) throw new Error(`no Chromium at ${CHROME}`);

const server = Bun.serve({
  port: 0,
  async fetch(req) {
    let p = new URL(req.url).pathname;
    if (p.endsWith("/")) p += "index.html";
    const file = Bun.file(join(DIST, decodeURIComponent(p)));
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
  },
});
const origin = `http://localhost:${server.port}`;

const langs = (only ?? ["en", ...LOCALES.map((l) => l.ios).filter((c) => c !== "en")]).filter(
  (c) => c === "en" || existsSync(join(DIST, c)),
);
const PAGES = readdirSync(DIST).filter((f) => f.endsWith(".html"));

/**
 * Runs in the page. Everything it reports is a measurement, not a judgement —
 * the caller decides what counts as a failure, so that a threshold can be
 * changed without reopening a browser.
 */
const MEASURE = `(() => {
  const vw = window.innerWidth;
  const doc = document.scrollingElement;
  const wide = [];
  const clipped = [];
  const broken = [];
  const tiny = [];
  const sel = (el) => {
    const id = el.id ? '#' + el.id : '';
    const cls = typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\\s+/).join('.') : '';
    return el.tagName.toLowerCase() + id + cls;
  };
  for (const el of document.querySelectorAll('body *')) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') continue;
    const r = el.getBoundingClientRect();
    if (!r.width && !r.height) continue;
    // Off the right edge. 1px of tolerance: sub-pixel layout rounds up.
    if (r.right > vw + 1 && cs.position !== 'fixed') wide.push({ s: sel(el), over: Math.round(r.right - vw) });
    // Text wider than the box drawn around it. Only leaf-ish elements: a
    // scrolling container is doing that on purpose, and so is a <pre>.
    if (!el.children.length && el.scrollWidth > el.clientWidth + 1 && cs.overflowX !== 'auto' && cs.overflowX !== 'scroll') {
      clipped.push({ s: sel(el), over: el.scrollWidth - el.clientWidth, t: (el.textContent || '').trim().slice(0, 40) });
    }
    // \`complete\` first: every screenshot on this page is \`loading="lazy"\`, so
    // one that has not been scrolled to yet has no natural width and is not
    // broken. Without the guard the check reports all sixteen of them, on
    // every page, in every language, and means nothing.
    if (el.tagName === 'IMG' && el.complete && !el.naturalWidth) broken.push({ s: sel(el), src: el.getAttribute('src') });
    // Tap targets, phone only — the caller filters. 44px is Apple's own floor,
    // and it is a floor for controls. A link inside a sentence is as tall as
    // the sentence and always will be; flagging those buries the buttons.
    // Prose is decided by what surrounds the link, not by the tag it sits in:
    // the footer's "(c) ... . Home . FAQ . Privacy" is a run of text in a bare
    // div, and a 44px box around those would collide with the lines above and
    // below. A link whose parent holds text of its own is being read; a link
    // that is the only thing in its parent is being tapped.
    const prose = el.tagName === 'A' && el.parentElement &&
      el.parentElement.textContent.replace(/[\s\u00b7|,;\/-]/g, '').length >
        Array.from(el.parentElement.querySelectorAll('a'))
          .reduce((n, a) => n + a.textContent.replace(/\s/g, '').length, 0);
    const control = el.tagName === 'BUTTON' || el.tagName === 'SUMMARY' ||
      (el.tagName === 'A' && !prose);
    if (control && r.height > 0 && r.height < 44) {
      tiny.push({ s: sel(el), h: Math.round(r.height), t: (el.textContent || '').trim().slice(0, 24) });
    }
  }
  const nav = document.querySelector('header.nav');
  return {
    scrollWidth: doc.scrollWidth,
    innerWidth: vw,
    navHeight: nav ? Math.round(nav.getBoundingClientRect().height) : 0,
    wide, clipped, broken, tiny,
  };
})()`;

const browser = await chromium.launch({ executablePath: CHROME });
if (shots) mkdirSync(".qa", { recursive: true });

type Row = { lang: string; page: string; vp: string; issue: string; detail: string };
const rows: Row[] = [];
let checked = 0;

for (const vp of VIEWPORTS) {
  const ctx = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    deviceScaleFactor: vp.dsf,
    // Not en-US: the offer bar only appears for a browser asking for a language
    // we publish, and it would cover the top of every screenshot.
    locale: "en-US",
  });
  const page = await ctx.newPage();
  const errors: string[] = [];
  // The RUM beacon posts to cloudflareinsights.com, which refuses a request
  // from http://localhost — an artifact of serving the site here, not a fault
  // in it. Every other console error is real and is reported.
  const ours = (t: string) => !t.includes("cloudflareinsights.com") && !t.includes("net::ERR_FAILED");
  // Served locally, the RUM beacon's host is either refused by CORS or, on a
  // flaky route, simply unreachable — and the console message for the second
  // names no host to filter on. Answering it here with an empty 204 removes the
  // ambiguity: every console error that survives is the page's own.
  await page.route("**://*.cloudflareinsights.com/**", (r) => r.fulfill({ status: 204, body: "" }));
  page.on("console", (m) => m.type() === "error" && ours(m.text()) && errors.push(m.text()));
  page.on("pageerror", (e) => ours(String(e)) && errors.push(String(e)));

  for (const lang of langs) {
    for (const name of PAGES) {
      const url = lang === "en" ? `${origin}/${name}` : `${origin}/${lang}/${name}`;
      errors.length = 0;
      const res = await page.goto(url, { waitUntil: "load" });
      if (!res || res.status() !== 200) {
        rows.push({ lang, page: name, vp: vp.name, issue: "status", detail: String(res?.status()) });
        continue;
      }
      await page.evaluate(() => document.fonts.ready);
      // Scrolled to the bottom and back so the lazy images actually load —
      // otherwise the only images this checks are the two above the fold.
      await page.evaluate(async () => {
        const step = () => new Promise((r) => setTimeout(r, 30));
        for (let y = 0; y < document.body.scrollHeight; y += 600) {
          window.scrollTo(0, y);
          await step();
        }
        window.scrollTo(0, 0);
      });
      await page.waitForLoadState("networkidle").catch(() => {});
      const m: any = await page.evaluate(MEASURE);
      checked++;

      if (m.scrollWidth > m.innerWidth + 1) {
        rows.push({ lang, page: name, vp: vp.name, issue: "h-scroll", detail: `${m.scrollWidth} > ${m.innerWidth}` });
      }
      for (const w of m.wide.slice(0, 3)) {
        rows.push({ lang, page: name, vp: vp.name, issue: "overflows", detail: `${w.s} +${w.over}px` });
      }
      for (const c of m.clipped.slice(0, 3)) {
        rows.push({ lang, page: name, vp: vp.name, issue: "clipped", detail: `${c.s} +${c.over}px "${c.t}"` });
      }
      for (const b of m.broken) {
        rows.push({ lang, page: name, vp: vp.name, issue: "img-404", detail: b.src });
      }
      if (vp.name === "phone") {
        // No cap: two per page was enough to hide whatever sat third.
        for (const t of m.tiny) {
          rows.push({ lang, page: name, vp: vp.name, issue: "tap<44", detail: `${t.s} ${t.h}px "${t.t}"` });
        }
      }
      // The nav is one row or it is broken. 60px is the bar; anything taller
      // means the links wrapped, which is the failure this page has had before.
      if (m.navHeight > 76) {
        rows.push({ lang, page: name, vp: vp.name, issue: "nav-wrap", detail: `${m.navHeight}px` });
      }
      for (const e of errors.slice(0, 2)) {
        rows.push({ lang, page: name, vp: vp.name, issue: "js-error", detail: e.slice(0, 90) });
      }
      if (shots && name === "index.html") {
        await page.screenshot({ path: `.qa/${vp.name}-${lang}.png`, fullPage: false });
      }
    }
  }
  await ctx.close();
}

await browser.close();
server.stop(true);

const by = new Map<string, Row[]>();
for (const r of rows) by.set(r.issue, [...(by.get(r.issue) ?? []), r]);

console.log(`${checked} page-viewport combinations checked (${langs.length} languages x ${PAGES.length} pages x ${VIEWPORTS.length} widths)`);
if (!rows.length) {
  console.log("no issues");
} else {
  for (const [issue, list] of [...by].sort((a, b) => b[1].length - a[1].length)) {
    console.log(`\n${issue} — ${list.length}`);
    const seen = new Set<string>();
    for (const r of list) {
      const key = `${r.vp}|${r.page}|${r.detail.replace(/\d+/g, "#")}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const also = list.filter((x) => `${x.vp}|${x.page}|${x.detail.replace(/\d+/g, "#")}` === key).map((x) => x.lang);
      console.log(`  ${r.vp} ${r.page} [${also.length > 3 ? also.slice(0, 3).join(",") + ` +${also.length - 3}` : also.join(",")}] ${r.detail}`);
    }
  }
}
