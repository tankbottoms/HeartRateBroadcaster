# Free → paid, for a $4.99 app

Written for version 1.1. Version 1.0 ships paid-only, which is the right first
release: it is one SKU, one price, nothing to test, and it does not block on
anything below.

## The short answer

**One app, free to download, with a single non-consumable in-app purchase that
unlocks it.** Not two apps. Not a third-party processor. Not redeem codes.

Everything else in this document is why.

## Why not two apps

The obvious shape — `HeartRate Broadcaster` and `HeartRate Broadcaster Pro` — is
the one to avoid:

- **No upgrade path.** Someone on the free app who wants to pay has to find the
  other app, buy it, install it, and set it up again. Every step loses people.
  That is the opposite of a low barrier.
- **Two of everything.** Two listings, two sets of screenshots, two review
  queues, two privacy questionnaires, and — for this app — two sets of metadata
  in twenty-five languages. The translation pipeline doubles.
- **Search competes with itself.** Two results for the same name splits the
  ratings and the ranking.
- **Apple discourages it.** Duplicate apps that differ only in feature gating
  are a guideline 4.3 risk.

Two SKUs make sense when the audiences are genuinely different — a consumer app
and an enterprise app. Not here.

## Why not a third-party processor

It is not permitted, and it would not be simpler.

Unlocking functionality inside an iOS app is digital content. Guideline 3.1.1
requires in-app purchase for it. Stripe, Paddle, Gumroad and a licence-key box
in the settings screen are a rejection, not a discount. This is the rule that
Kindle and Spotify famously live under.

There are narrow exceptions and they do not help:

- **Reader apps** — apps whose content was bought elsewhere, like a magazine
  app. This app has no external content.
- **External purchase link entitlements** — jurisdiction-specific, applied for
  separately, and they carry their own disclosure sheets, reporting
  obligations, and (outside the US) commission anyway. Terms have moved
  repeatedly; check the current App Review guidelines before assuming anything.
  For a $4.99 utility the paperwork costs more than the commission.
- **Custom App Distribution** — for apps sold to organisations, not the public.

Even if it were allowed, a processor means a server to issue and validate keys,
a key to store, a support burden when someone loses it, and a privacy policy
that stops being able to say "no server". Right now this app makes no network
requests at all. That is worth keeping.

**Redeem codes**, specifically: App Store *offer codes* only exist for
subscriptions. For a non-consumable the equivalent is *promo codes* — up to 100
per app version, free, generated in App Store Connect, redeemed in the App
Store. Fine for press and friends. Not a purchase mechanism.

## The recommended shape

### One product

| | |
|---|---|
| App price | Free |
| Product | Non-consumable IAP, `xyz.atsignhandle.heart-rate-broadcaster.unlock` |
| Price | $4.99 (Tier 5) |
| Restores | Yes — non-consumables must offer Restore Purchases |
| Family Sharing | On. Costs nothing, removes a support email. |

A non-consumable, not a subscription: it is bought once and it stays bought.
Subscriptions bring renewal handling, grace periods, billing retry, and a much
harsher review of whether recurring value is being delivered. None of that
applies to a Bluetooth bridge.

### What the free tier gives away

The barrier has to be low enough that someone can find out whether the app
works with *their* head unit before paying, because that is the only real
question they have. If they cannot answer it for free, they will not pay.

Recommended gate: **broadcasting stops after 15 minutes per session.**

- Everything works. The watch link, AirPods, the test signal, pairing,
  diagnostics, the Live Activity — all of it, unrestricted.
- Fifteen minutes is long enough to pair a Garmin, confirm the number matches,
  and complete a warm-up. It is not long enough to train on.
- When it stops, it says why, and offers the unlock in the same sheet.

Alternatives considered and rejected: a 7-day trial (a cyclist who rides twice
a week gets two rides and a countdown, which reads as pressure); test-signal
only (does not answer the only question that matters); ads (no).

The cap is one timer and one check. It is not a separate build.

### Grandfathering the people who already paid

This is the part that must not be got wrong. Anyone who bought 1.0 at $4.99
paid for the whole app and must not be asked again.

StoreKit 2 answers this directly: `AppTransaction.originalAppVersion` is the
version of the app that account *first* downloaded. Anyone whose original
version is below the first free build bought the paid app.

```swift
// Grant the unlock to anyone who bought the app back when the app itself was
// the purchase. `originalAppVersion` is the build number on iOS, and it is the
// version that account first acquired — not the version they are running.
func hasLegacyEntitlement() async -> Bool {
    guard case .verified(let receipt) = try? await AppTransaction.shared else { return false }
    return (Int(receipt.originalAppVersion) ?? .max) < firstFreeBuild
}
```

Set `firstFreeBuild` to the build number of the first free release, hard-coded,
and never change it. Test it before shipping by installing 1.0 from TestFlight
and then upgrading — this is the single path most worth rehearsing.

### The implementation, roughly

StoreKit 2, no dependencies, one small observable:

```swift
@Observable final class Store {
    private(set) var isUnlocked = false
    private(set) var product: Product?
    private let id = "xyz.atsignhandle.heart-rate-broadcaster.unlock"

    func start() async {
        product = try? await Product.products(for: [id]).first
        await refresh()
        // A purchase made on another device, a refund, or a Family Sharing
        // grant all arrive here rather than through `purchase()`.
        for await update in Transaction.updates {
            if case .verified(let t) = update { await t.finish(); await refresh() }
        }
    }

    func refresh() async {
        if await hasLegacyEntitlement() { isUnlocked = true; return }
        isUnlocked = await Transaction.currentEntitlement(for: id) != nil
    }

    func buy() async throws {
        guard let product else { return }
        if case .success(.verified(let t)) = try await product.purchase() {
            await t.finish()
            await refresh()
        }
    }
}
```

Restore is `try await AppStore.sync()` behind a button — required, one line.

Local testing uses a `.storekit` configuration file in the scheme, so the whole
flow including refunds and Ask to Buy can be exercised in the simulator without
App Store Connect. Sandbox accounts come after that, real purchase last.

### App Store Connect work

1. Create the in-app purchase, non-consumable, and set the price.
2. Localise its display name and description — twenty-five languages, same
   pipeline as everything else. A missing localisation shows the product with
   no name in that storefront.
3. Attach a review screenshot of the purchase sheet. Missing this is the
   commonest IAP rejection.
4. Submit the IAP **with** the build. A first IAP is reviewed alongside the app,
   not separately.
5. Change the app price to free in the same version, not before it.

### Sequence

1. Ship 1.0 paid. (In review now.)
2. Build the gate and the store code behind it while 1.0 is live.
3. Test the grandfathering path from a real 1.0 install.
4. Ship 1.1: app free, IAP live, legacy buyers unlocked silently.

Step 3 is the one that cannot be skipped. Everything else recovers from a
mistake with a patch release; charging an existing customer twice does not.

## Not worth doing

- **A subscription.** Wrong instrument for a one-time utility.
- **A lifetime tier alongside a subscription.** Two products, one app, $4.99.
- **A paid watch-only companion.** The watch app is not separable.
- **Tip jar.** Consumables need their own handling and earn approximately
  nothing at this scale.
