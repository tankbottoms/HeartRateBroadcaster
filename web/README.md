# HRB marketing page

Static site describing the iOS + watchOS app, published in the same
twenty-five languages as the app itself. No network dependencies — Font Awesome
Pro 6 Thin is vendored under `static/fontawesome/`, so the page renders
identically offline and behind a strict CSP.

Three directories, and the split is the whole design: `src/` is written by
hand, `static/` is committed binary and CSS, `dist/` is written by the build and
is the only thing that gets deployed.

```
web/
├── src/                        # hand-written — the only files you edit
│   ├── index.html
│   ├── privacy.html
│   ├── robots.txt
│   └── i18n/<code>.json        # generated: English fragment → translation
├── static/                     # committed assets, grouped by type
│   ├── css/site.css            # all styling
│   ├── img/icon.png, og.png    # icon.png from scripts/make-app-icons.swift
│   ├── img/screens/*.jpg       # from scripts/prepare-screenshots.ts
│   └── fontawesome/            # vendored css/ and webfonts/
├── press/                      # App Store Connect staging area, noindex
├── dist/                       # generated, gitignored — what wrangler deploys
└── wrangler.toml
```

Nothing outside `dist/` is published, so there is no exclusion list to keep in
step. The previous layout deployed the whole of `web/` and relied on
`.assetsignore` to hold back the originals, the dictionaries and this
directory's `wrangler.toml`; that file is gone.

`dist/` is not in git. Run the build before deploying, or wrangler uploads
whatever it last contained.

## Building

```sh
bun scripts/site.ts              # translate anything new, then write all 50 pages
bun scripts/site.ts --build-only # rebuild from the existing i18n files, no model
bun scripts/site.ts --lang de,ja # only these languages
```

The keys in `src/i18n/<code>.json` are the English sentences themselves, exactly
as in the app's String Catalogs. Editing an English sentence therefore
invalidates its translations automatically — which is the point. A fragment with
no translation falls back to English rather than rendering empty.

Preview locally — from `dist/`, so the root-absolute asset paths resolve the way
they will in production:

```sh
cd web/dist && python3 -m http.server 8890
```

## Editing rules

- Edit `src/`, never `dist/`. Everything under `dist/` is deleted and rewritten
  on every build, so anything typed there is lost and never reaches the other
  twenty-four languages.
- Only describe behaviour the app actually has. The page deliberately omits
  anything speculative.
- Icons are `<i class="fat fa-name"></i>` (Font Awesome Pro Thin). Never emoji,
  never a CDN link.
- The ANT+ callout is load-bearing — it is the single most common wrong
  expectation about this app and must not be softened into "coming soon".
- Asset paths in `src/` stay relative; the build rewrites them to root-absolute
  so they resolve from `/de/` as well as from `/`.

## Language handling

The picker in the header is a `<details>` full of ordinary links, so it works
with JavaScript off and a crawler can follow all twenty-five.

The English page also carries a short script that reads `navigator.languages`
and, if it names a language we publish, shows a dismissible bar linking to it.
It offers; it never redirects. An automatic redirect on language is how a Polish
speaker who wants the English page ends up unable to reach it, and how Googlebot
— which crawls from the United States as `en-US` — ends up never seeing
twenty-four of these pages.
