# App Store Connect configuration review — browser prompt

Paste into a browser agent extension with App Store Connect already signed in.
It reads and reports; it changes nothing. Nothing below identifies the account
holder — every fact it needs to check against is published at the press-kit URL,
which is why this file can live in a public repository.

---

You are reviewing the App Store Connect configuration for **HeartRate
Broadcaster** (bundle `xyz.atsignhandle.heart-rate-broadcaster`, Apple ID
`6797897649`). Version **1.0** is in review. **Do not change anything.** Report
only.

The reference copy is published as JSON. Fetch these first and compare against
what the browser shows:

- `https://heart-rate.atsignhandle.xyz/press/listing/listing.json` — every
  locale's name, subtitle, description, keywords, promotional text and the three
  URLs, keyed by App Store Connect locale code.
- `https://heart-rate.atsignhandle.xyz/press/manifest.json` — the screenshot set
  and the app icon, with the capture date.

Check and report on each of the following. For each, say **match**, **differs**
(quote both sides) or **cannot see**.

1. **Version state.** What state is 1.0 in, and what does the submission banner
   say? If it has been rejected, quote the resolution centre message in full.

2. **Localizations present.** List every locale App Store Connect shows for the
   version. `listing.json` has 25. Name any locale that is in one and not the
   other, in either direction.

3. **Per-locale copy.** For each locale present in both, compare name, subtitle,
   description, keywords and promotional text against `listing.json`. Report
   only the ones that differ. Keywords are the field that most often silently
   truncates — flag any that appear cut off.

4. **URLs.** Marketing, support and privacy policy URLs, per locale. They should
   all be `https://heart-rate.atsignhandle.xyz/...`. Any remaining
   `*.workers.dev` URL is stale and should be reported with its locale.

5. **Screenshots.** For each display size, how many are uploaded, and does any
   show an upload error or a "processing" state? Compare the count against
   `manifest.json`. Note which localizations have screenshots and which fall back
   to the base localization — the localized screenshot sets are deliberately not
   uploaded yet, so the expected answer is that only the base locale has them.

6. **App Information.** Category (primary and secondary), age rating summary,
   content rights declaration, and whether the app is marked as containing
   third-party content.

7. **Pricing and availability.** Price tier and the number of territories
   selected. Flag any territory that is excluded.

8. **App Privacy.** List every data type declared collected, and for each, the
   stated purpose and whether it is linked to identity or used for tracking.
   The app's own position is that heart rate data never leaves the device except
   over the local Bluetooth broadcast, and that nothing is collected by the
   developer — report any declaration that contradicts that.

9. **Export compliance.** What the build shows for encryption. It should be
   answered, not blank.

10. **Anything the review would trip on.** Missing demo account, missing review
    notes, an unanswered question, a warning triangle anywhere on the page.

Finish with a short list of the specific things that need fixing, most blocking
first, and say plainly if there are none.
