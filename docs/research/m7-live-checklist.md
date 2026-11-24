# M7: what has not been verified against a real Apple account

Every M7 ticket was built without an Apple account: against Apple's OpenAPI document (App Store Connect API 4.6.1,
`openapi.oas.json` of 2026-11-19), the sources of fastlane, the App Store Connect CLI and RevenueCat's CLI, and recorded
or hand-written answers. This page gathers, ticket by ticket, every question their pull requests left open ("not
verified live", "not done"), so the maintainer can close them during [#105](https://github.com/fmsouza/xless/issues/105)
with the [acceptance kit](../acceptance-m7.md). Tick each box with what Apple did; when Apple disagrees, open an issue
and link it.

The run of 2026-11-24 stopped after the App Review submission ([record](../acceptance-m7.md#record)). A ticked box was
answered by it; a note in _italics_ says what it saw. What #105 asked for and the run did not reach is
[#181](https://github.com/fmsouza/xless/issues/181).

Where each one is answered:

- **live-check**: `XLESS_LIVE_APPLE=1 xless live-check` (`scripts/acceptance-m7.sh --contract`, and step 0 of the
  run), read-only. It calls the list and get endpoints xless reads (not the report downloads), with xless's own readers, and prints `ok`,
  `warn` (it decoded, but fields xless reads never came back: read the line), `FAIL` (an error, or an answer xless
  cannot read) or `skip`. It runs again after step 2 (with the new API key) and after step 4 (with the app).
- **step N**: the kit's step N of #105, recorded in [acceptance-m7.md](../acceptance-m7.md).
- **by hand**: a command to run on the same account once the kit is done (its output goes in the issue or the record).
- **not in #105**: needs something the acceptance does not have (a second team, a hardware key, a paid app…); left
  for when it is available.

## Sign-in, teams and the web session (#84, #107)

- [x] `/olympus/v1/session` shape, `publicProviderId` present for the current provider — **live-check** (`warn` when absent)
- [x] `/olympus/v1/contractMessages` shape (pending agreements) — **live-check** — _0 pending agreements_
- [ ] `listTeams.action` shape — **live-check**; `xless team list` — **step 7** (traced) — _live-check: ok_
- [x] 2FA sign-in with `--keep 30m`, then `xless auth logout` — **step 2**
- [x] the kept cookie jar fits the kernel's per-user key quota (`maxbytes` 20000): a failed keep says "run without --keep" — **step 2** (watch for it) — _kept every time_
- [x] the portal's GET-as-POST envelope (`X-HTTP-Method-Override: GET`) — **live-check** (iCloud containers, bundle IDs)
- [x] CSRF priming from `listProvisioningProfiles.action` before a portal write — **step 4** (provision's app group / container / key writes) — _the APNs key was created; no group or container was written_
- [ ] a provider switch on an Apple ID with several App Store Connect teams — **not in #105** (one team)
- [ ] a security key: Apple accepts this CTAP2 stack's assertion (`crossOrigin: true`), a key with a PIN set but not enforced (UV=0), `alwaysUv`, a U2F-only key, two keys, the udev rule over SSH on Debian/Ubuntu/Fedora, `report_descriptor` from sysfs — **by hand** with a hardware key: `xless auth login --keep 10m`; otherwise **not in #105**

## API keys (#85, #141)

- [x] `xless auth api-key create` → key downloaded once, stored, verified with `GET /v1/apps` — **step 2**
- [x] a 404 on the download right after the create (not retried by design) — **step 2** (watch for it) — _not seen_
- [x] `/iris/v1/apiKeys` list shape, `createdBy`/`revokedBy` attribute names — **live-check** (`warn` without `createdBy`)
- [ ] the `visibleApps` relationship for `--app` — **by hand**: `xless auth api-key create --app <app ID> --role DEVELOPER`, then revoke it
- [x] `xless auth status` shows the stored key and its role — **step 2**
- [x] revoke — **--cleanup**
- [ ] a credential helper (GNOME Keyring, KWallet, pass) instead of the vault, and a helper failing after Apple created a key — **not in #105** (the vault is used); by hand with `secrets: { backend: helper }`

## Devices, bundle IDs, capabilities, merchant IDs (#86, #87)

- [ ] devices list shape — **live-check**; register / disable — **step 4** / **--cleanup** when `XLESS_M7_DEVICE_UDID` is set — _read: ok_
- [ ] Apple's wording of the device-limit refusal and of a duplicate UDID (409) — **by hand** (`xless devices register` with an already registered UDID)
- [x] bundle IDs and capabilities list shapes — **live-check**
- [ ] the capability settings encoding (`{key, options: [{key, enabled: true}]}`) accepted — **step 4** (push needs no settings: by hand with `xless bundle-ids capabilities <id> enable ICLOUD --setting …` on a test bundle ID)
- [ ] the iCloud-enabled profile with and without containers; the `NETWORK_CUSTOM_PROTOCOL` entitlement key; Apple's 409 wording for a refused capability — **by hand**, **not in #105**'s app
- [ ] merchant IDs list shape — **live-check**; create/delete — **by hand** — _read: ok, 0 merchant IDs_

## Certificates and profiles (#88, #89, #142)

- [x] certificates list shape — **live-check**; an Apple Distribution certificate made from a PEM CSR, its key stored — **step 4** — _`activated` never came_
- [ ] `csrContent` as PEM for every other type; the Apple Pay and pass type relationship bodies; Apple's 409 wording at a type's limit — **by hand** (`xless certs create --type …`), **not in #105**
- [ ] `GET /v1/profiles?include=certificates` (and `/relationships/certificates` with `limit=200`, `meta.paging.total`) — **live-check** — _answered with 0 profiles_
- [ ] profiles list with `include=bundleId` — **live-check**; `include=bundleId` and `seedId` on a single profile — **by hand**: `xless profiles download <id> --out /tmp/m7.mobileprovision` — _list: ok, `profileContent` never came_
- [x] the profile create body; `profileContent` parsed as CMS — **step 4**, then **step 5** signs with it
- [ ] the create body with `devices`, duplicate profile names, tvOS and visionOS device classes — **by hand** (a development profile), **not in #105**
- [ ] a lost certificate create recovered by its public key; `xless certs link` on a real team — **not in #105** (needs a lost answer)
- [x] revoke — **--cleanup**

## App groups, iCloud containers, auth keys (#90, #91)

- [x] app groups (`listApplicationGroups.action`) and v1 `cloudContainers` list shapes — **live-check** — _6 groups, 0 containers: no container was read_
- [ ] the bundle ID's capability relationships read through `v1/bundleIds/{id}` — **live-check** (after step 4) — _read: ok, the app has neither capability_
- [ ] v1 container create, the PATCH for APP_GROUPS and ICLOUD, legacy assign (replace or add?), a group carried by a regenerated profile — **not in #105**'s app (push only); **by hand** on a test bundle ID: `xless app-groups create group.<id>` and `xless app-groups assign`
- [x] auth keys list shape, `services` included — **live-check** (`warn` when a key comes without services)
- [x] an APNs key created (`v2/create`), downloaded once, stored, revoked — **step 4** / **--cleanup**
- [ ] the download's error envelope; Apple's wording at the APNs limit (2 keys) — **watch in step 4**; **by hand**
- [ ] Sign in with Apple (`identifiers.bundle`) and MusicKit (`identifiers.music`) create shapes — **not in #105**

## The app record, listing, media, pricing, privacy (#92 to #97, #144)

- [x] `xless apps create` (web session): the document accepted; the app then visible to `xless apps show` with the API key — **step 4** — _visible to the API key only after a while: [#165](https://github.com/fmsouza/xless/issues/165)_
- [x] `GET /iris/v1/apps?filter[bundleId]` — **live-check** (after step 4)
- [ ] Apple's wording when a name, SKU or bundle ID is taken — **watch in step 4** (an App Store name is often taken: `XLESS_M7_APP_NAME`)
- [ ] the listing reads: app infos, localizations, `ageRatingDeclaration`, the review detail with its sparse fieldset, the phased release, screenshot and preview sets (`templateUrl`, `videoUrl`), the EULA, `accessibilityDeclarations`, the price schedule (`manualPrices?include=appPricePoint`), `appAvailabilityV2` — **live-check** (after step 4) — _read: ok; the app has no preview, EULA, accessibility declaration or phased release_
- [x] push of text, categories, age rating, review details, release type — **step 4**; `store push --dry-run` then sends nothing — **step 4** — _after [#163](https://github.com/fmsouza/xless/issues/163), [#167](https://github.com/fmsouza/xless/issues/167) and [#169](https://github.com/fmsouza/xless/issues/169)_
- [ ] pull → push zero diff on a real app — **by hand** after step 4: `xless store pull --dir /tmp/m7-pulled --app <bundle ID>`, then `xless store push --dir /tmp/m7-pulled --dry-run`
- [ ] clearing a category with `data: null`; accessibility answers published in the same PATCH; a phased release created `INACTIVE`; what Apple copies onto a new version; `earliestReleaseDate` read-back — **by hand** (needs a second version), **not in #105**
- [ ] screenshots: two sets upload, a second push uploads nothing, Apple's placement and reorder while processing, four uploads at once within the rate limit — **step 4** — _4 uploaded, one per set; a second push uploads nothing_
- [ ] previews, review attachments, the export compliance document — **not in #105**'s app (none)
- [ ] the free price schedule (`${…}` local IDs, `startDate: null`) and availability in every territory; whether availability must come first; the UTC day boundary — **step 4** — _both accepted_
- [x] App Privacy "Data Not Collected" pushed and published (web session) — **step 4**; the usages, catalog (`deleted`) and publish state reads — **live-check** (after step 4)
- [ ] privacy with data types: category-wide tracking without a purpose, `limit=500`, LINKED and NOT_LINKED together — **not in #105**'s app; **by hand** on a test app
- [ ] streamed downloads from Apple's media CDN; `store pull --config` on Tauri, cargo and React Native overlays — **by hand** (`xless store pull`)

## Builds, users, TestFlight, release (#98 to #101, #108)

- [ ] builds list with `filter[preReleaseVersion.version]`, a single build with `include=buildBetaDetail,appEncryptionDeclaration` — **live-check** (builds exist after step 5: run `scripts/acceptance-m7.sh --contract` again then) — _the reads are ok on another app; not run again after step 5_
- [x] `xless builds wait` on a fresh upload — **step 5** (xless run waits for processing)
- [ ] PATCH `expired`, `usesNonExemptEncryption` and the declaration relationship — **by hand** (`xless builds expire`), **not in #105** — _`expired`: three builds expired by hand_
- [ ] users and invitations list shapes — **live-check**; `filter[roles]` with several values, a duplicate invite (409), the `visibleApps` PATCH, invite → accept → list — **by hand** with a second Apple ID — _read: ok, 0 invitations_
- [x] beta groups, testers, localizations, review detail, licence reads — **live-check** (after step 4) — _after [#171](https://github.com/fmsouza/xless/issues/171)_
- [x] an internal group created by provision; a tester added (`POST /v1/betaTesters` for a team user); the build reaches them — **step 5** — _after [#173](https://github.com/fmsouza/xless/issues/173)_
- [ ] tester refusal wording (409/422), app-wide removal, external groups, public links, beta review — **not in #105** (internal testing only); **by hand** with `testflight.external` in xless.yml
- [x] `xless release submit --release manual`: pre-flight, the review submission created, the version added, submitted — **step 6** — _after [#177](https://github.com/fmsouza/xless/issues/177) and [#179](https://github.com/fmsouza/xless/issues/179) (China mainland)_
- [ ] `reviewSubmissions` with `filter[state]` and `include=appStoreVersionForReview`; the items — **live-check** (submissions exist after step 6: run `scripts/acceptance-m7.sh --contract` again then) — _not run again after step 6; `xless release status` and `cancel` read the submission_
- [ ] App Review to Pending Developer Release, or a rejection and a resubmission of `UNRESOLVED_ISSUES` — **step 6** — _withdrawn while waiting for review: [#181](https://github.com/fmsouza/xless/issues/181)_
- [ ] `xless release publish` (the release request's answer) — **step 6** — _[#181](https://github.com/fmsouza/xless/issues/181)_
- [ ] `earliestReleaseDate` for a scheduled release, phased release days — **not in #105** (manual release)
- [ ] in-app purchases and subscriptions: list reads — **live-check**; every write, review screenshots, IAP price schedules, subscription prices, review items for product versions, sandbox history — **not in #105** (a free app with no products) — _read: ok, 0 products_

## Reviews, reports, webhooks (#109)

- [ ] customer reviews and webhooks list shapes — **live-check** — _read: ok, 0 of each_
- [ ] report downloads (gzip, `Accept: application/a-gzip`, 404 wording, redirects, the weekly Sunday) — **by hand**: `xless reports sales download --vendor <number> --date <yesterday> --out /tmp/m7-reports`
- [ ] review filters, a response replacing another, webhook create (secret format, echo) — **not in #105** (a new app has no reviews); **by hand** later
- [ ] the roles each endpoint needs (the kit's key is ADMIN) — **not in #105**

## Provision, the store and the build (#102 to #104, #138 to #143)

- [x] `xless provision plan` → `apply` → an empty plan on a fresh app — **step 4** — _after the fixes above_
- [ ] a provision with products; drift after Apple copies a version; a declared app extension provisioned and signed — **not in #105**
- [x] `xless run <app>` ships to TestFlight with every secret from the store only — **step 5**
- [x] `xless run --docker` with the store: the build container gets no secret — **step 8** (an xless.yml project in Docker is one container that gets the store when it signs; the kit splits the run at `--to finalize` / `--from sign`) — _after [#175](https://github.com/fmsouza/xless/issues/175), the kit_
- [ ] a native run with a remembered unlock: build tools get no keyring, no kept session — **step 7** (process environments, keyring) — _[#181](https://github.com/fmsouza/xless/issues/181)_
- [ ] a real Apple redirect (report downloads, asset uploads) keeps the Authorization header on Apple's host only — **step 4** (uploads), **by hand** (reports) — _the uploads of step 4 worked_
- [ ] the Docker upload container gets the external-review demo password from the store — **not in #105** (no external testing)
- [ ] stores written by older releases on other machines open and are upgraded — **not in #105** (a fresh machine)

## Security (#81, #104)

- [ ] no secret file under `$HOME` but the store; `strings` on the store finds no key material; no secret in a process's environment or command line during a run; no core dump; no xless key in the kernel keyring after `lock` and `logout`; a `--verbose` trace has no token, cookie or key — **step 7** — _[#181](https://github.com/fmsouza/xless/issues/181); the processes watched in steps 5 and 8 had 0 findings_
- [ ] neither portal opened in a browser — **step 9** — _[#181](https://github.com/fmsouza/xless/issues/181)_
