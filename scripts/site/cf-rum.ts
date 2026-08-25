// Read-only unless --create. Inventories Cloudflare Web Analytics (RUM) sites
// on the account that owns the Worker, and reports whether either of the
// site's hostnames already has one.
//
//   bun scratchpad/cf-rum.ts            # inventory
//   bun scratchpad/cf-rum.ts --create   # create a site for site.zone if absent
//
// The API token comes from the environment, same as wrangler. Nothing is
// printed that is not already visible in the dashboard.
import { readFileSync } from "node:fs";

const cfg = JSON.parse(readFileSync("apple-project.json", "utf8"));
const token = process.env.CLOUDFLARE_API_TOKEN;
if (!token) throw new Error("CLOUDFLARE_API_TOKEN not set");

const env = readFileSync("web/.env", "utf8");
const account = env.match(/^CLOUDFLARE_ACCOUNT_ID=(.+)$/m)?.[1]?.trim();
if (!account) throw new Error("CLOUDFLARE_ACCOUNT_ID missing from web/.env");

const api = async (method: string, path: string, body?: unknown) => {
  const r = await fetch(`https://api.cloudflare.com/client/v4${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j: any = await r.json();
  if (!j.success) throw new Error(`${method} ${path} -> ${JSON.stringify(j.errors)}`);
  return j.result;
};

// SAFETY: apple-project.json is this repo's own checked-in identifier file, and
// `site.zone` / `site.domains` are required keys of it — every script that reads
// the file, and the site build itself, would fail on a shape without them.
const zone = cfg.site.zone as string;
// SAFETY: same file, same contract as `site.zone` immediately above.
const domains = cfg.site.domains as string[];

const sites = await api("GET", `/accounts/${account}/rum/site_info/list?per_page=50`);
console.log(`rum sites on account: ${sites.length}`);

// The list endpoint returns the ruleset but not the rules; the hostnames a site
// actually covers live one hop away.
const hostsOf = new Map<string, string[]>();
for (const s of sites) {
  let rules: any[] = [];
  try {
    rules = await api("GET", `/accounts/${account}/rum/v2/${s.site_tag}/rule`);
  } catch {
    /* a site with auto_install and no manual rules answers 404 here */
  }
  const hosts = rules.map((r) => `${r.host}${r.paths?.length ? r.paths.join(",") : ""}`);
  hostsOf.set(s.site_tag, rules.map((r) => r.host));
  console.log(
    `  ${s.site_tag}  zone=${s.ruleset?.zone_name ?? "-"}  auto=${s.auto_install}  hosts=${hosts.join(" ") || "(none)"}`,
  );
}

const covers = (s: any) =>
  s.ruleset?.zone_name === zone ||
  (hostsOf.get(s.site_tag) ?? []).some((h) => domains.includes(h) || h === `*.${zone}` || h === zone);
const existing = sites.filter(covers);
console.log(`\nsites covering ${domains.join(" / ")}: ${existing.length}`);
for (const s of existing) console.log(`  site_tag ${s.site_tag}`);

if (process.argv.includes("--create") && existing.length === 0) {
  // One site, both hostnames. Web Analytics records the hostname on every
  // pageview, so a single beacon token still separates the subdomains in the
  // dashboard — two sites would mean two tokens and no way to pick between
  // them in a static build that both hostnames serve.
  const made = await api("POST", `/accounts/${account}/rum/site_info`, {
    zone_tag: null,
    host: zone,
    auto_install: false,
  });
  console.log(`\ncreated site_tag ${made.site_tag}`);
  console.log(`beacon token: ${made.site_tag}`);
}
