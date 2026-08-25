# Web launch — the steps that wait for App Review

The site is deployed and correct, but deliberately invisible. Everything
below is blocked on one event: App Review approving 1.0. Doing any of it
earlier publishes links that 404 and invites a crawl of a page advertising
a product nobody can download.

Deployed today at `heart-rate-broadcaster.atsignhandle.workers.dev`, with
every canonical URL already pointing at `heart-rate.atsignhandle.xyz`.

## 1. Add the custom domain

Cloudflare dashboard → Workers & Pages → `heart-rate-broadcaster` →
Settings → Domains & Routes → Add → Custom Domain → `heart-rate.atsignhandle.xyz`.

The `atsignhandle.xyz` zone is on the same account as the Worker — the
one named by `CLOUDFLARE_ACCOUNT_ID` in `web/.env`, see `web/.env.example`
— so the DNS record and certificate are created automatically. Wait for the certificate to go active before
step 4 — Search Console rejects a host that cannot complete TLS.

Do this **before** unblocking robots.txt. The canonical tags already name
this hostname, and a canonical pointing at a host that does not resolve
is worse than no canonical at all.

## 2. Unblock indexing

`web/robots.txt` — delete the single line:

```
Disallow: /
```

Leave `Disallow: /press/`. That directory is App Store Connect staging,
not content, and it carries its own noindex tag.

## 3. Publish the App Store links

`web/_src/index.html` — the hero and footer download buttons are wrapped
in HTML comments. Uncomment them and replace the placeholder with the
real product URL, which is
`https://apps.apple.com/app/id6797897649` once the app is live.

Edit `web/_src/` and never `web/`. The twenty-five served pages are
generated from those two files; anything typed into `web/index.html`
directly is overwritten by the next build and never reaches the other
twenty-four languages.

While editing, add the App Store URL to the `SoftwareApplication` JSON-LD
block as `"url"`, and bump `lastmod` in `web/sitemap.xml` to the edit
date. An honest date matters more than a fresh one; a sitemap claiming
every page changed today teaches crawlers to ignore the field.

Then rebuild and redeploy:

```
bun scripts/site.ts        # translates the new copy, rewrites all 50 pages
cd web && bunx wrangler deploy
```

New English copy comes back untranslated on the first pass only if the
model rejects it; the script leaves those fragments as English and
picks them up on the next run.

## 4. Submit to Search Console

Add `heart-rate.atsignhandle.xyz` as a property, verify by DNS TXT (the zone is
already on Cloudflare, so this is one record), then submit
`https://heart-rate.atsignhandle.xyz/sitemap.xml`.

Use the Rich Results Test on the homepage afterwards. The `FAQPage`
block should report seven questions. If it reports fewer, an answer has
stopped being visible on the page — the structured data and the rendered
copy have to agree, and a mismatch is grounds for a manual action rather
than a silently dropped rich result.

## Verification

After the redeploy, these should hold:

| Path | Expected |
|---|---|
| `/robots.txt` | `text/plain`, no bare `Disallow: /` |
| `/sitemap.xml` | `application/xml`, 50 URLs |
| `/assets/og.png` | `image/png`, 1200×630 |
| `/no-such-page` | **404** — not the homepage at 200 |
| `/` | canonical and `og:url` both on the custom domain |
| `/ja/` | `<html lang="ja">`, Japanese copy, canonical `/ja/` |
| `/ar/` | `<html lang="ar" dir="rtl">` |
| `/_src/index.html` | **404** — the sources are in `.assetsignore` |
| `/i18n/de.json` | **404** — same |

Every page carries the full twenty-five-entry `hreflang` set plus
`x-default`. Search Console's International Targeting report is where a
broken pair shows up; check it once, a week after the sitemap is
submitted.
