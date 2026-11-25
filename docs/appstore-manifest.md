# The App Store listing: `appstore/`

An app's App Store listing (its text in every language, screenshots, previews, categories, age rating, App Review
contact, licence agreement, price and availability, App Privacy, in-app purchases and subscriptions) lives in an
`appstore/` directory next to the
project, reviewed like code, the way fastlane's `deliver` keeps it. [`xless store pull`](#xless-store-pull) writes it
from an app that already exists; [`xless store validate`](#xless-store-validate) checks it without contacting Apple;
[`xless store push`](#xless-store-push) sends what differs, screenshots, previews, price and availability included.
App Privacy has no App Store Connect API: [`xless store privacy`](#app-privacy-xless-store-privacy) pulls and pushes
it through the Apple ID web session.

```text
appstore/
  app.yml                          the app-level values
  eula.txt                         a custom licence agreement, when app.yml says so
  media.lock                       written by xless: which App Store Connect upload each screenshot, preview or attachment is
  review/                          files for App Review, when app.yml's review.attachments lists them
  compliance/                      the export compliance document, when app.yml's encryptionDocument names it
  iap/                             in-app purchases: <productId>.yml each, and its App Review screenshot
  subscriptions/<group>/           a subscription group: group.yml, and <productId>.yml per subscription
  en-US/                           one directory per locale, spelled as App Store Connect spells it
    name.txt                       the app's name (2 to 30 characters)
    subtitle.txt                   30 characters
    privacy_url.txt                the privacy policy URL
    privacy_choices_url.txt        the privacy choices URL
    privacy_policy_text.txt        the privacy policy as text (tvOS)
    description.txt                4000 characters
    keywords.txt                   100 bytes, comma-separated
    promotional_text.txt           170 characters
    whats_new.txt                  4000 characters
    support_url.txt
    marketing_url.txt
    screenshots/APP_IPHONE_67/     one directory per display type
      01-home.png                  file order is display order
      02-settings.png
    previews/IPHONE_67/
      01-intro.mov
  de-DE/
    …
```

## Text files

Each field is one UTF-8 file. Line breaks at the end of a file are not part of the value (editors add one); Windows
line ends read as plain line breaks; a URL file's surrounding spaces are ignored. A missing file and an empty file mean
the same thing: the field is not set. `name`, `subtitle` and the privacy URLs and text belong to the app's information
(they change with a new version's review), the other fields to the App Store version.

Locale directories use App Store Connect's codes exactly: `en-US`, `de-DE`, `fr-FR`, `ja`, `zh-Hans`, `pt-BR`…
(`de-de` is reported, with the right spelling). Every directory of `appstore/` is a locale, except `review/` and
`compliance/` (files `app.yml` names) and `iap/` and `subscriptions/` ([in-app purchases and
subscriptions](#in-app-purchases-and-subscriptions)); other files (a README) may sit at the top.

## Screenshots and previews

`<locale>/screenshots/<display type>/` holds one set: the directory is App Store Connect's `ScreenshotDisplayType`
(`APP_IPHONE_67`, `APP_IPHONE_65`, `APP_IPAD_PRO_3GEN_129`, `APP_DESKTOP`, `APP_APPLE_TV`, `APP_APPLE_VISION_PRO`,
`APP_WATCH_ULTRA`, `IMESSAGE_APP_IPHONE_67`…) and the files are shown in name order, a leading number compared as a
number (`2-…` before `10-…`). PNG or JPEG, no transparency, at most 10 per set, in one of the sizes Apple lists for the
display type ([screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)),
portrait or landscape. `<locale>/previews/<preview type>/` is the same for app previews (`IPHONE_67`, `IPAD_PRO_3GEN_129`,
`DESKTOP`…): `.mov`, `.m4v` or `.mp4`, at most 3 per set, at most 500 MB each. A preview's poster frame is
`app.yml`'s `previewFrames` entry for its path (`HH:MM:SS:FF`); without one, App Store Connect picks it.

App Store Connect never gives back an uploaded file, only a re-encoded copy. `media.lock` records, for each media file,
its MD5 and the checksum Apple keeps of the upload it is (`sourceFileChecksum`). As long as a file is unchanged, it
*is* that upload: `pull` keeps it instead of downloading Apple's copy, and `push` uploads nothing. An upload
`pull` could not download (still processing, or a preview App Store Connect only streams) is recorded without a local
file (`md5` absent), so `push` knows it is there and leaves it alone. xless writes this file; commit it with the rest.

## `app.yml`

Values are App Store Connect's own (`IOS`, `AFTER_APPROVAL`, `UTILITIES`…), so what you read in its API documentation
is what you write here. Every key is optional to read; `validate` says which ones a submission needs. `pull` writes
them in this order:

```yaml
bundleID: com.example.app            # the app; without it, the bundleID of the --config overlay, else of the xless.yml next to appstore/
sku: EXAMPLE1                        # informational: a SKU never changes
platform: IOS                        # IOS, MAC_OS, TV_OS or VISION_OS: the platform this listing's version is for
primaryLocale: en-US
version: "1.1"                       # the App Store version (quote it)
copyright: 2026 Example Inc.
contentRights: DOES_NOT_USE_THIRD_PARTY_CONTENT   # or USES_THIRD_PARTY_CONTENT
categories:
  primary: GAMES                     # category IDs (`xless api GET /v1/appCategories`)
  primarySubcategories: [GAMES_PUZZLE, GAMES_BOARD]   # at most two
  secondary: ENTERTAINMENT
  secondarySubcategories: []
ageRating:                           # the age rating questions, Apple's attribute names and answers
  violenceCartoonOrFantasy: NONE
  gambling: false
  # …
release:
  type: AFTER_APPROVAL               # MANUAL, AFTER_APPROVAL or SCHEDULED
  earliestDate: "2026-12-01T08:00:00Z"   # SCHEDULED only
  phased: true                       # a phased release over 7 days
review:                              # for App Review
  contact: { firstName: Ada, lastName: Lovelace, phone: "+1 555 0100", email: ada@example.com }
  demoAccount:
    required: true
    name: demo@example.com
    passwordSecret: XLESS_DEMO_PASSWORD   # the secret that holds the password, never the password
  notes: |
    Sign in with the demo account; the camera screen needs a QR code: https://example.com/qr
  attachments: [review/walkthrough.mov]   # files for App Review (kept by pull: Apple gives them no download)
encryption:                          # export compliance: the latest encryption declaration's answers
  exempt: true
  containsProprietaryCryptography: false
encryptionDocument: compliance/export.pdf   # the compliance document, when App Store Connect asks for one
accessibility:                       # Accessibility Nutrition Labels, per device family
  IPHONE: { supportsVoiceover: true, supportsDarkInterface: true, supportsLargerText: true }
eula: standard                       # Apple's licence agreement, or a custom one:
# eula: { file: eula.txt, territories: all }
pricing:
  baseTerritory: USA
  price: free                        # or the customer price there, quoted: "0.99"
  territories:                       # manual prices outside the base territory, in their currency (optional)
    JPN: "150"
  changes:                           # scheduled price changes (optional); territory defaults to the base territory
    - { date: "2027-01-01", price: "1.99" }
    - { date: "2027-01-01", territory: JPN, price: "300" }
availability:
  territories: all                   # or a list of territory codes: [USA, CAN, GBR]
  newTerritories: true               # add new App Store territories automatically
previewFrames:                       # a preview's poster frame (HH:MM:SS:FF), by path
  en-US/previews/IPHONE_67/01-intro.mov: "00:00:05:00"
privacy:                             # App Privacy (`xless store privacy pull` writes it)
  collectsData: true                 # false: "Data Not Collected" (and no data:)
  data:
    - category: EMAIL_ADDRESS        # Apple's category IDs
      purposes: [APP_FUNCTIONALITY]  # Apple's purpose IDs
      linkedToYou: true              # linked to the user's identity
      tracking: false                # used to track the user
```

`ageRating`, `encryption` and `accessibility` are written with Apple's attribute names as they are, so questions Apple
adds (such as the 2025 age rating questions) need no new xless. The demo account's password is never in the manifest:
`passwordSecret` names an entry of the [secret store](secrets.md) (or an environment variable) that holds it:

```sh
xless secrets import XLESS_DEMO_PASSWORD --file demo-password.txt --kind password
```

A key xless does not know is reported by `validate` (a typo guard) and kept as it is by `pull`.

**Prices** are customer prices, as a customer sees them: `free`, or the price in the territory's currency (`"0.99"`,
`"150"`), quoted. Each must be one of the app's price points in its territory: `xless apps price-points
com.example.app --territory USA` lists them, and `--price 0.99` shows what that price becomes in every other territory
([apple-account.md](apple-account.md#xless-apps)). Territories without a manual price follow the base price (App Store
Connect's equalization). A change takes effect on its `date` (a day in UTC); once that day has come, `push` treats it
as the current price and `pull` writes it as `price`.

## `xless store pull`

```sh
xless store pull --app com.example.app           # into ./appstore
xless store pull                                  # again: the app is app.yml's bundleID
xless store pull --live                           # the version on the App Store, not the one being prepared
xless store pull --app-version 1.2 --dir listing  # a given version, into ./listing
xless store pull --platform macos
xless store pull --config ../overlays/hello.yml  # a Tauri, cargo or React Native app: into ../overlays/appstore
```

It reads, with the App Store Connect API key (App Manager is enough), only the documented API: the app record; the app
information (categories, age rating, name, subtitle and privacy URLs per locale); one App Store version (copyright,
release type and date, phased release, App Review contact, demo account name and notes, and per locale the
description, keywords, what's new, promotional text, support and marketing URLs, screenshots and previews); the custom
licence agreement; the latest encryption declaration; accessibility declarations; the price schedule (the base
territory's current price, manual prices in other territories, changes to come; past prices are history and left
out); availability; and the in-app purchases and subscriptions ([below](#in-app-purchases-and-subscriptions)). A part the app does not have is left out (or written as its default: `eula: standard`, `phased: false`);
a part the key's role may not read keeps the value `app.yml` already had, with a note.

- **The version** is the one being prepared if there is one, else the one on the App Store, else the newest;
  `--editable`, `--live` or `--app-version` choose. The app information is the live one for the live version, else the
  one being edited.
- **The platform** is `app.yml`'s, else the only one the app has versions for (an app with several gets a note and
  `IOS`); `--platform ios|macos|tvos|visionos` chooses.
- **The app** is `--app` (app ID or bundle ID), else `app.yml`'s `bundleID`, else the project configuration's: the
  overlay given with `--config` (`type: tauri`, `cargo` or `react-native`; for `MAC_OS` its macOS bundle ID), else
  the `xless.yml` next to the directory. With `--config`, the directory defaults to `appstore/` next to the overlay.
  The configuration's `teamID` (overlay or xless.yml) is the team when neither `--team` nor `--app` is given, before
  the team `xless team use` saved; its API key is the one stored for that team, else one stored for no team (as for
  `xless provision`). `validate`,
  `push`, `store privacy` and `xless release` take `--config` the same way. The overlay is only read, not its source.
- **The demo account's password is never read**: xless asks App Store Connect for the review details without it, so it
  is not in memory, in a `--verbose` trace or on disk. A pulled `app.yml` keeps its `passwordSecret`; a first pull of an
  app whose review needs a demo account writes `XLESS_DEMO_PASSWORD` and says how to store it.
- **Screenshots and previews** are downloaded from Apple's delivery URLs (https, no credentials), four at a time and
  written to disk as they arrive (a preview is never held in memory), once the rest is read, and checksummed into
  `media.lock`, except files the lock shows are the local original of the same upload, which are kept. Media still
  processing, and previews App Store Connect only streams, are listed as not downloaded.
- **All at once**: the new directory is built beside the old one and swapped in when everything is read, so a failure
  leaves `appstore/` as it was. Files the format does not own (a README, notes in `iap/`), `app.yml` keys xless does not
  know and the App Privacy answers (`privacy`, read only by [`store privacy pull`](#app-privacy-xless-store-privacy))
  are carried over. It is a pull: the listing's text and media become App Store Connect's, and a
  local screenshot never uploaded is not kept (a note names it).
- **Refusals**: `pull` does not replace a directory that is not a manifest (no `app.yml`, not empty), nor one whose
  `app.yml` cannot be read (its keys would be lost): fix it first (`xless store validate`).

It prints what it wrote (`--json`: `{"appID", "bundleID", "platform", "version", "versionState", "directory",
"locales", "screenshots", "previews", "downloaded", "kept", "skipped"}`). Errors are `[account]` errors, exit code 20
([apple-account.md](apple-account.md#errors)).

## `xless store validate`

```sh
xless store validate              # ./appstore
xless store validate --draft      # what a submission still needs: warnings, not errors
xless store validate --json
```

Offline: it never contacts Apple. Each finding is one line naming the file, what is wrong and how to fix it:

```text
error: [account] appstore/en-US/keywords.txt: 112 bytes, Apple allows 100 — shorten the keywords (comma-separated, counted in UTF-8 bytes)
error: [account] appstore/en-US/screenshots/APP_IPHONE_67/03-wrong.png: 1284x2778 is not a size APP_IPHONE_67 takes — use one of 1260x2736, 2736x1260, 1290x2796, 2796x1290, 1320x2868, 2868x1320
warning: appstore/app.yml: unknown key `primarylocale` — did you mean `primaryLocale`?
appstore/: 2 errors, 1 warning
```

It checks:

- `app.yml`: YAML and value types (naming the key), unknown keys (warning), the bundle ID, platform, primary locale (it
  must have a directory), version, content rights, category IDs (at most two subcategories), release type and date,
  the App Review contact's email, the demo account's `passwordSecret` (a secret name), the custom licence file, the
  review attachments and compliance document (files inside `appstore/`, each listed once, not empty), the preview
  poster frames (`HH:MM:SS:FF`, a preview of the directory), prices (`free` or a number with a dot), territory codes,
  price change dates (`YYYY-MM-DD`, one change per territory and day), and that `pricing.territories` does not list the
  base territory.
- Text: name and subtitle 30 characters, keywords 100 bytes (UTF-8), promotional text 170, description and what's new
  4000; a name of at least 2; URLs are `http(s)` with a host; locale directories are App Store Connect's codes.
- Media: screenshots are PNG or JPEG (read from the file, not its name), without transparency, in a size of their display
  type, at most 10 per set; previews are `.mov`, `.m4v` or `.mp4`, at most 3 per set and 500 MB. An unknown display or
  preview type is a warning.
- What a submission needs: name, description, keywords and support URL in every locale; a privacy policy URL, and
  screenshots for the platform's required display (iPhone 6.9" or 6.5", or iPad 13" for iOS; `APP_DESKTOP` for macOS;
  `APP_APPLE_TV`; `APP_APPLE_VISION_PRO`) in the primary locale; version, copyright, content rights, primary category,
  age rating and the App Review contact. `--draft` turns these into warnings.

It exits with 20 when there is an error, 0 otherwise. `--json` prints `{"valid": bool, "issues": [{"severity", "path",
"message", "fix"}]}`.

## `xless store push`

```sh
xless store push --dry-run                 # the plan: what differs, nothing sent
xless store push                           # send it
xless store push --only text,review        # some parts only
xless store push --only media              # screenshots and previews only
xless store push --only pricing            # price schedule and availability only
xless store push --only privacy            # App Privacy only (Apple ID web session)
xless store push --only iap,subscriptions  # in-app purchases and subscriptions only
xless store push --prune                   # also delete locales, media sets and files the directory does not have
```

`push` makes App Store Connect's listing match `appstore/`, with the API key (App Manager is enough) and only the
documented API. It first checks the directory as `store validate --draft` does (an error stops it before anything is
read from Apple), reads what App Store Connect has, and prints the plan, one line per resource:

```text
com.example.app (IOS 1.1, PREPARE_FOR_SUBMISSION):
  ~ app info en-US: subtitle: "Does things" → "Does more"
  + app info fr-FR: name: "Exemple"
  ~ version text en-US
      description (18 → 110 characters)
      whatsNew: "Fixes." → (none)
  ~ App Review details: demoAccountPassword (from XLESS_DEMO_PASSWORD)
4 changes: 1 to create, 3 to update
```

`--dry-run` stops there. Otherwise it sends the plan, deletions only after asking (or with `--yes`), and says how many
changes it sent. A push that finds nothing to change sends nothing, so `pull` then `push` is a no-op. If a request
fails, what was sent stays sent: re-run `push`, which sends only what still differs.

The parts, in the order they are sent (`--only` chooses):

- **`text`**: the App Store version of `app.yml`'s `version` and `platform`. When App Store Connect has no such
  version, `push` renames the version being prepared, or creates it (with its copyright and release), then plans the
  rest again against the new version (App Store Connect may have copied the live version's text onto it): that second
  plan is printed, and its deletions asked, before it is sent. The version's copyright, release type and date, and phased release; the app's
  primary locale; the categories, checked against App Store Connect's list for the platform; and per locale the app
  information (name, subtitle, privacy policy URL and text, privacy choices URL) and the version's text (description,
  keywords, what's new, promotional text, support and marketing URLs). A version on the App Store, or in review, takes
  only new promotional text; the app information changes only with a new version.
- **`review`**: App Review's contact, notes and demo account, and the files `review.attachments` lists (uploaded
  onto the review details, which are created for them if App Store Connect has none).
- **`declarations`**: the age rating (only the answers `app.yml` gives are compared and sent), the content rights
  declaration, the licence agreement (`standard` deletes a custom one; `territories: all` is every territory App Store
  Connect lists), export compliance (a new encryption declaration when `appDescription`, `availableOnFrenchStore`,
  `containsProprietaryCryptography` or `containsThirdPartyCryptography` differ from the latest one, all four needed;
  `exempt` is App Store Connect's verdict and is not sent), its compliance document (`encryptionDocument`: uploaded
  with a new declaration, or onto the latest one when that has no document yet; App Store Connect does not let a
  declaration's document be replaced, so a changed one waits for the next new declaration) and accessibility
  (per device family in `app.yml`, the draft declaration is updated, or a new one created, and published; a draft that
  already has `app.yml`'s answers is published).
- **`pricing`**: the price schedule and availability, which belong to the app, not to a version (so `--only pricing`
  works before the version exists).
  - **The price schedule** is compared as a whole: the base territory, and each territory's current price and changes
    to come, as numbers (`0.99` is `0.990`, `free` is `0.0`). When anything differs, the whole schedule is sent
    (`POST /v1/appPriceSchedules`: App Store Connect replaces it), with each price resolved to the price point with
    exactly that customer price; a price that is no price point stops the push before anything is sent, naming the
    nearest points. Absent keys are carried over from App Store Connect: no `territories` keeps its manual prices
    outside the base territory, no `changes` keeps its scheduled changes, no `price` keeps the base price (changing
    `baseTerritory` needs a `price`, in that territory's currency; the old base territory's prices are not carried
    over, so it follows the new base unless `territories` gives it one); `territories: {}` and `changes: []` remove
    them. If App Store Connect's schedule has a price xless cannot read, `push` refuses to replace it.
  - **Availability**: an app with none gets one (`territories` and `newTerritories`, which defaults to `true` for
    `territories: all`, else `false`), listing every territory App Store Connect knows as available or not. Afterwards,
    each territory whose availability differs is changed on its own; taking the app off sale in a territory is shown
    as a deletion (`- availability in CAN`) and asked first (or `--yes`). App Store Connect's API sets `newTerritories`
    only when the availability is created: a different value later is a note, not a change. A territory App Store
    Connect does not list for the app stops the push.
- **`privacy`**: the App Privacy answers, through the Apple ID web session, then published; see
  [App Privacy](#app-privacy-xless-store-privacy). Like pricing, it needs no version.
- **`iap`** and **`subscriptions`**: the in-app purchases and subscriptions; see [below](#in-app-purchases-and-subscriptions).
  Like pricing, they need no version.
- **`media`**: per locale and display (or preview) type, the screenshot and preview sets: created when App Store
  Connect has none (in a locale the `text` part creates, too), new and changed files uploaded, the set put in the
  directory's order, and poster frames (`previewFrames`) set.

**Files are uploaded only when App Store Connect lacks them.** Each file's MD5 is compared with the checksum App Store
Connect keeps of each upload (`sourceFileChecksum`, which is the MD5 xless sent) and with `media.lock` (for copies
`pull` downloaded, renamed ones included), so an unchanged set uploads nothing and a renamed file only moves. A file
whose content changed replaces the upload `media.lock` ties its path to; an upload App Store Connect could not process
(FAILED), or one reserved and never finished (an interrupted push), is removed. An upload is App Store Connect's documented protocol: the file is reserved with its name and size,
sent in the parts App Store Connect asks for (read from disk one part at a time, each part retried on its own, no
credentials sent to Apple's storage), committed with its MD5, then watched until App Store Connect has processed it.
Four files go up at a time, across the sets of the push (each locale and display type; a set that must be emptied
before its new files go up is sent on its own), and their processing is
waited for in parallel (checked less often the longer it takes, so many files stay well inside App Store Connect's
hourly request limit); each set is then put in the directory's order, so the result is what one file at a time
would give. A file it refuses fails the push with App Store Connect's message (the failed upload is removed, so a
re-run starts clean): no other file starts going up, those already on their way finish and are recorded, and that
file's set is not reordered. One still processing after ten minutes is a note. `media.lock` is updated with every upload, even when a later
change fails. Screenshots and previews are checked first, as `store validate` does (format, size for the display type,
transparency, how many per set), so nothing App Store Connect would refuse is reserved.

A manifest of the version on the App Store (`pull --live`) is compared with the live app information and the published
accessibility answers, as `pull` read them.

What `push` leaves alone:

- an `app.yml` key that is absent (no `review:`, no `ageRating:`… means App Store Connect keeps what it has), and
  within `review`, a key that is absent (an empty value, `notes: ""`, clears it);
- a locale App Store Connect has and `appstore/` does not: reported, and deleted with `--prune` (never the primary
  locale). In a locale directory that exists, a missing text file clears the field, as `pull` would have written it;
  `name.txt` is never cleared, and a new locale needs one;
- a screenshot or preview set, a file in a set, or an App Review attachment App Store Connect has and `appstore/` does
  not: reported and kept (after the directory's files), and deleted with `--prune`. A set that would then hold more than
  Apple allows (10 screenshots, 3 previews) stops the push before anything is sent. An upload `pull` could not download
  (`media.lock` without `md5`) is part of the directory and stays where it is;
- App Privacy when `app.yml` has no `privacy:`; with one, when no Apple ID session is kept and there is no terminal
  to sign in on (CI): the part is skipped with a note (an error with `--only privacy`) and the rest is pushed. On a terminal
  it signs in once, before anything is planned (a kept session is used instead; `--only` without `privacy` needs none).

**The demo account's password** comes from the secret `review.demoAccount.passwordSecret` names: the secret store's
entry, or the `NAME` / `NAME_FILE` environment variables ([secrets.md](secrets.md)). App Store Connect never gives it
back, so it cannot be compared: `push` sends it when it creates the review details with a required demo account, when
the demo account becomes required or its name changes, and with `--resend-demo-account` (after changing the
password). `passwordSecret` may not name one of xless's keys or anything named like a key or token (`ASC_*`, `*_KEY`,
`*_TOKEN`, `*_P8`, `*_PEM`, `*_SECRET`): its value would be sent to App Store Connect, where App Review reads it. Nor
may it name a variable something else relies on: the system's or the shell's (`PATH`, `HOME`, `ENV`, `IFS`, `LANG`,
`LC_*`, `LD_*`, `XDG_*`, `SSH_*`, …), one of xless's own (`XLESS_*` other than `XLESS_DEMO_PASSWORD`, `*_FILE`) or of its
scripts (`TEAM`, `NAME`, `SIM`, …); case does not matter. It is read once, before anything is sent (with the one passphrase of the command) (a missing secret sends nothing), goes into that one request, sent
once and never retried, and is never printed, written, or shown in a `--verbose` trace or an error, even when App Store
Connect's answer repeats it.

`--json` prints `{"appID", "bundleID", "platform", "version", "versionState", "dryRun", "applied", "changes":
[{"action", "part", "subject", "fields": [{"name", "from", "to", "secret"}]}], "notes"}` (`secret` names the secret a
field's value comes from; the value itself is never there). Errors are `[account]` errors, exit code 20.

## App Privacy: `xless store privacy`

```sh
xless store privacy pull --app com.example.app   # App Store Connect's answers into app.yml's privacy:
xless store privacy push --dry-run               # what differs
xless store privacy push                         # send it, then publish
```

App Privacy (what data the app collects, what for, whether it is linked to the user, whether it is used to track
them) must be answered and published before an app can be submitted, and the App Store Connect API has no App Privacy.
These commands use the [Apple ID web session](apple-account.md#the-apple-id-web-session) (a session kept by
`xless auth login --keep`, else a sign-in on the terminal), as App Store Connect's own App Privacy page does; so does
the `privacy` part of [`store push`](#xless-store-push). They are undocumented by Apple (fastlane and the App Store
Connect CLI use the same requests).

`app.yml` holds one entry per kind of data, with Apple's IDs: categories such as `NAME`, `EMAIL_ADDRESS`,
`PHONE_NUMBER`, `PRECISE_LOCATION`, `COARSE_LOCATION`, `CONTACTS`, `PHOTOS_OR_VIDEOS`, `USER_ID`, `DEVICE_ID`,
`PURCHASE_HISTORY`, `PRODUCT_INTERACTION`, `ADVERTISING_DATA`, `CRASH_DATA`, `PERFORMANCE_DATA`, `HEALTH`, `FITNESS`
and the others App Store Connect lists; purposes `THIRD_PARTY_ADVERTISING`, `DEVELOPERS_ADVERTISING`, `ANALYTICS`,
`PRODUCT_PERSONALIZATION`, `APP_FUNCTIONALITY`, `OTHER_PURPOSES`. Each entry needs `purposes`, `linkedToYou` and
`tracking`; a category is listed once. `validate` checks the section (an ID it does not know is a warning: Apple adds
some); `push` checks every ID against App Store Connect's own lists before sending anything.

- **`pull`** rewrites `app.yml` only (creating the directory, and an `app.yml` with the bundle ID, when there is none);
  the rest of the directory is untouched. An app whose questions were never answered leaves `app.yml` as it is. It
  says when App Store Connect's answers are not published, and leaves out (with a note) answers it cannot read.
- **`push`** checks the section, compares it with App Store Connect's answers and prints the plan, one line per
  category; `--dry-run` stops there. App Store Connect keeps one answer per category, purpose and protection (linked,
  not linked, tracking); xless does not edit one in place: only the answers that differ are deleted and created again (a category's new
  answers before its old ones go, except one a new answer contradicts, linked ↔ not linked, which goes first). Switching to or from `collectsData: false` deletes the old answers first: App
  Store Connect refuses "Data Not Collected" next to collected data. The answers are then published (also when they
  already matched but were not published). Removing a category is not a deletion that asks: it changes the
  declaration, as editing a text does. If a request fails, re-run: it sends only what still differs.

`--json` prints `{"appID", "app", "published", "privacy", "notes"}` for `pull` and `{"appID", "app", "dryRun",
"applied", "changes", "notes"}` for `push`.

## In-app purchases and subscriptions

Paid features are part of the listing: one file per product, pulled and pushed with the rest, and sent to App Review
with the version by [`xless release submit`](apple-account.md#xless-release). Everything goes through the documented
API with the API key (App Manager is enough).

```text
appstore/
  iap/
    com.example.coins100.yml       a consumable, non-consumable or non-renewing subscription, named after its product ID
    com.example.coins100.png       its App Review screenshot, when the file names it
  subscriptions/
    premium/                       one directory per subscription group (any name; pull uses the group's)
      group.yml                    the group
      com.example.monthly.yml      one auto-renewable subscription of the group
      com.example.monthly.png
```

```yaml
# iap/com.example.coins100.yml
type: CONSUMABLE                   # CONSUMABLE, NON_CONSUMABLE or NON_RENEWING_SUBSCRIPTION; fixed once created
referenceName: 100 Coins           # the name only App Store Connect shows
familySharable: false
reviewNote: Buy it from the Store tab.
reviewScreenshot: iap/com.example.coins100.png
pricing:                           # as app.yml's pricing: base territory, price, manual prices, scheduled changes
  baseTerritory: USA
  price: "0.99"
availability:
  territories: all                 # or a list: [USA, CAN]
  newTerritories: true
localizations:                     # what customers see, per locale
  en-US:
    name: 100 Coins                # 35 characters
    description: A pile of coins.  # 55 characters
```

```yaml
# subscriptions/premium/group.yml
referenceName: Premium             # how push finds the group at App Store Connect
localizations:
  en-US:
    name: Premium                  # 75 characters
    customAppName: Example         # optional, 30 characters

# subscriptions/premium/com.example.monthly.yml
referenceName: Premium Monthly
period: ONE_MONTH                  # ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS or ONE_YEAR
groupLevel: 1                      # 1 is the highest level of service in the group
familySharable: false
reviewNote: …
reviewScreenshot: subscriptions/premium/com.example.monthly.png
pricing:
  baseTerritory: USA
  price: "4.99"
  territories:                     # prices of their own; every other territory gets Apple's equivalent of 4.99
    GBR: "3.99"
  preserveCurrentPrice: true       # existing subscribers keep what they pay when a price changes (the default)
availability:
  territories: all
localizations:
  en-US:
    name: Premium Monthly
    description: Everything, every month.
```

As in `app.yml`, a key that is absent is not managed: `push` keeps what App Store Connect has for it. `store validate`
checks the files offline: product IDs (letters, digits, `.`, `-`, `_`; the file name is the product ID, and a product ID
belongs to one file), types and periods, prices and territory codes, locale codes and Apple's text limits, group levels
(one per subscription), and that the screenshot is a PNG or JPEG inside `appstore/`. Without `--draft` it also needs
what App Review needs: a type, a reference name and localized names.

- **`store pull`** writes every product of the app: its text, its current prices (an in-app purchase's schedule as
  `app.yml` writes the app's; a subscription's base territory price, USA when it has one, and the territories whose
  price is not Apple's equivalent of it), its availability, and its App Review screenshot (downloaded, recorded in
  `media.lock`). A subscription group keeps the directory name the manifest already has for it. A product file App
  Store Connect has no product for (never pushed) is not kept: a note names it.
- **`store push`** (parts `iap`, `subscriptions`): a product or group App Store Connect does not have is created
  (`POST /v2/inAppPurchases`, `/v1/subscriptionGroups`, `/v1/subscriptions`) alone, and `push` plans again once it
  exists (its text, screenshot, prices and availability need its ID): `--dry-run` shows the creation and says the rest
  follows. One it has is updated where it differs: the reference name, review note and family sharing (a subscription's
  period and level too); the text per locale (a locale App Store Connect has and the file does not is reported, and
  deleted with `--prune`); the screenshot, uploaded when it differs, the old one deleted first (one per product); an
  in-app purchase's price schedule, sent whole as the app's is (`POST /v1/inAppPurchasePriceSchedules`); a
  subscription's price in each territory it is sold in, one `POST /v1/subscriptionPrices` per territory whose price
  differs, in effect at once (with `preserveCurrentPrice` where it already had a price); and the availability, sent
  whole whenever it differs (the API has no update: `POST /v1/inAppPurchaseAvailabilities`,
  `/v1/subscriptionAvailabilities`). An in-app purchase's type cannot change: a different `type` stops the push. A
  group is found by its `referenceName`; a new name whose subscriptions App Store Connect has in one other group renames
  that group. A subscription cannot move between groups: a file in another group's directory stops the push before
  anything is sent.
- **Never deleted**: a product or group App Store Connect has and `appstore/` does not is reported, never removed.
- **`release submit`** adds each product the manifest lists to the review submission: its version being prepared
  (`inAppPurchaseVersion`, `subscriptionGroupVersion`, `subscriptionVersion` items); a product ready to submit without
  such a version is submitted with the app's version (`POST /v1/inAppPurchaseSubmissions`, `/v1/subscriptionSubmissions`).
  A submission App Review sent back takes them too when it is submitted again. The pre-flight fails when a listed
  product is not on App Store Connect or is missing metadata. `--no-products` leaves them out, check included.

[`xless iap`](apple-account.md#xless-iap-and-xless-subscriptions) and `xless subscriptions` show what App Store Connect
has, and list the price points a file may name.
