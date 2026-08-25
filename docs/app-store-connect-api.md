# App Store Connect API

What this project drives through the API instead of the browser, what still
needs a human, and the traps that cost time the first time.

The API is at `https://api.appstoreconnect.apple.com`, documented at
<https://developer.apple.com/app-store-connect/api/>. `scripts/asc.ts` is the
client; `scripts/asc-push.ts` is everything this app actually pushes.

## Authentication

An ES256 JWT signed with a `.p8` private key, valid for at most twenty minutes.
Three identifiers, all in `apple-project.json` (gitignored):

| Field | Where it comes from |
|-------|---------------------|
| `issuerId` | Users and Access > Integrations. Per-team. No API returns it. |
| `activeKeyId` | The key's ten-character id. |
| `privateKeyPath` | Directory holding `AuthKey_<id>.p8`. Outside the repo. |

Two failures look identical and are not:

- **Wrong issuer id** → `401 NOT_AUTHORIZED`. Reads like a permissions problem.
  Every key on the team shares one issuer; a key from another team is a 401.
- **DER-encoded signature** → `401`, no detail. Node signs ECDSA as DER by
  default and JWS wants the raw `r‖s` pair. `dsaEncoding: "ieee-p1363"`.

Key roles: **Admin** or **App Manager** to write metadata or upload a build.
**Developer** can archive but not upload.

## What the API can do, and what this project uses

| Task | Endpoint | Used here |
|------|----------|-----------|
| Read versions and their state | `GET /v1/apps/{id}/appStoreVersions` | yes |
| Create a version | `POST /v1/appStoreVersions` | no — done at release time |
| Description, keywords, promo text, URLs | `appStoreVersionLocalizations` | yes |
| Name, subtitle, privacy URL | `appInfoLocalizations` | yes |
| Screenshots | `appScreenshotSets` + `appScreenshots` | yes |
| App previews (video) | `appPreviewSets` + `appPreviews` | no |
| Upload a build | `altool` / Transporter, **not** this API | `scripts/upload-build.sh` |
| Select a build for a version | `PATCH /v1/appStoreVersions/{id}/relationships/build` | no |
| Age rating | `ageRatingDeclarations` | no — set once |
| Pricing and availability | `appPriceSchedules`, `appAvailabilities` | no — free, all territories |
| IDFA declaration | `POST /v1/appStoreVersions/{id}` … `idfaDeclaration` | no — set to false already |
| Submit for review | `POST /v1/reviewSubmissions` + `reviewSubmissionItems` | **no — deliberate** |
| TestFlight groups and testers | `betaGroups`, `betaTesters` | no |
| Sales and finance reports | `salesReports`, `financeReports` | no |

Submission is left to the browser on purpose. `reviewSubmissions` works, but
the last screen is also where export compliance and any new declaration Apple
has added since are answered, and answering those from a script means answering
them without reading them.

## The two-resource split

The listing is not one object. This is the single most confusing thing about
the API and it is not signposted anywhere:

```
app
├── appInfos → appInfoLocalizations       name, subtitle, privacyPolicyUrl
└── appStoreVersions → appStoreVersionLocalizations
                                          description, keywords, promotionalText,
                                          marketingUrl, supportUrl, whatsNew
                       └── appScreenshotSets → appScreenshots
```

`subtitle` sent to a version localization is a 409 naming a field that plainly
exists — on the other resource. `appInfo` is not versioned the way
`appStoreVersion` is; editing it edits the listing for the next release.

A live app has two of each: the released one and the editable one. Both come
back from the same query. Writing to the released one succeeds and changes
nothing anyone will see. Filter on `appStoreState` — editable is
`PREPARE_FOR_SUBMISSION`, `DEVELOPER_REJECTED`, `REJECTED`,
`METADATA_REJECTED`, `INVALID_BINARY`.

Two 409s on `appInfoLocalizations` that both read as permissions problems:

- **`You must provide a value for the attribute 'name'`** on create. There is no
  inherited default — a new language is listed under no name at all unless one
  is sent. The app name is the same in every language, so read it from the live
  English localization rather than hardcoding it; renaming the app in the web UI
  then does not leave twenty-four languages under the old name.
- **`'fr-FR' already exists`** for a language that did not exist a moment ago.
  Creating an `appStoreVersionLocalization` creates the matching
  `appInfoLocalization` as a side effect, so a map of existing languages read
  once before the loop is stale by the second language. Re-read with
  `?filter[locale]=` before deciding to create.

## Character limits

Enforced at upload with a 409 and **no partial write** — one long subtitle
fails the whole language.

| Field | Limit |
|-------|-------|
| `subtitle` | 30 |
| `promotionalText` | 170 |
| `keywords` | 100 |
| `description` | 4000 |
| `whatsNew` | 4000 |

Characters, not bytes: a CJK subtitle of 30 characters is fine at 90 bytes.
`whatsNew` must be **absent**, not empty, on a version that has never shipped.

## Uploading a screenshot

Three calls, all required:

1. `POST /v1/appScreenshots` with `fileSize` and `fileName`, related to a set.
   The response carries `uploadOperations` — a list, because Apple chunks large
   files.
2. `PUT` each operation's `url` with its `requestHeaders` and the byte range
   `[offset, offset + length)`.
3. `PATCH /v1/appScreenshots/{id}` with `uploaded: true` and
   `sourceFileChecksum` (MD5 hex).

Skip the third and the asset sits in the set as "processing" forever, blocking
submission with an error that points at the image rather than the missing call.

Display order is the order of the set's relationship, not upload order and not
filename order:

```
PATCH /v1/appScreenshotSets/{id}/relationships/appScreenshots
{ "data": [ {"type": "appScreenshots", "id": "…"}, … ] }
```

### Display types

Wider than their names. Apple did not add new types for the newer sizes, so
these are historical labels:

| Type | Accepts |
|------|---------|
| `APP_IPHONE_67` | 1290×2796 (6.7"), 1320×2868 (6.9") |
| `APP_IPAD_PRO_3GEN_129` | 2048×2732 (12.9"), 2064×2752 (13") |
| `APP_WATCH_SERIES_10` | 410×502 |

Ten screenshots maximum per set. iPhone 6.9" and iPad 13" are the only two
required for a universal app; the smaller sizes are scaled by the App Store.

## Rate limits

About 3600 requests an hour, per key. A full push of 25 languages is roughly
120 metadata calls and 900 for screenshots (three per image), which fits, but
not twice in an hour. `scripts/asc-push.ts` skips sets that already have
images unless `--replace` is given, so a re-run after a partial failure costs
almost nothing.

## Running it

```bash
bun scripts/asc-push.ts                     # dry run — prints the plan
bun scripts/asc-push.ts --apply             # metadata and screenshots
bun scripts/asc-push.ts --apply --metadata  # text only
bun scripts/asc-push.ts --apply --screenshots --replace
bun scripts/asc-push.ts --apply --lang de,ja
```

Dry run is the default. The version this writes to is the one that goes to
review, and there is no undo.
