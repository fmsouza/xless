# Milestone 7 acceptance — an Apple account from the terminal

Scope: [#105](https://github.com/fmsouza/xless/issues/105), the definition of done of milestone 7
([#80](https://github.com/fmsouza/xless/issues/80)): a new app goes from zero to the App Store from a Linux terminal,
without opening developer.apple.com or appstoreconnect.apple.com. It needs a real Apple Developer Program membership,
so it is run by the maintainer with the kit below; this page explains how, and the kit writes the record at the end
of it. The run of 2026-11-24 got as far as App Review: steps 0 to 5 and 8 passed, and the version was submitted. The
maintainer ended it there; what it did not check is listed [in the record](#what-the-run-did-not-check).

## The kit

- [`samples/m7-acceptance/`](../samples/m7-acceptance/README.md): a one-screen SwiftUI iOS app that needs a capability
  (push notifications), with an `appstore/` listing in two languages (en-US, pt-BR), screenshots for the iPhone 6.9"
  and iPad 13" displays, App Privacy ("Data Not Collected"), a free price and every territory but China mainland
  (its App Compliance declarations have no API). Its bundle ID, team, App
  Store name, SKU and review contact are placeholders the script fills in its own copy.
- [`scripts/acceptance-m7.sh`](../scripts/acceptance-m7.sh): walks #105's checklist in order, records every command and
  its output into this page (between the record markers below, redacted), and is resumable: a step that finished is
  skipped when the script runs again, one that failed starts again.
- `xless live-check` (hidden; `XLESS_LIVE_APPLE=1`): the read-only contract check. It reads the list and get
  endpoints the account commands use (not the report downloads) with xless's own readers and reports each answer, so a response shape Apple changed, or one xless
  guessed wrong, shows up before anything is written. Its connections refuse to send anything but a read.
- [research/m7-live-checklist.md](research/m7-live-checklist.md): every question the M7 pull requests left open, with
  the step (or the command) that answers it.

## Before you start

- A Linux machine (x86_64 or arm64) that has never run xless: no `~/.config/xless`, no secret store, no key file. A
  fresh VM is best (step 1 checks; it asks before going on if the machine is not fresh).
- xless installed from the release candidate ([README](../README.md#install)), the native toolchain set up for step 5
  (`xless setup --xcode <Xcode.xip>`, [README](../README.md#set-up)) and, for step 8, the xless image and the Xcode's pack (`xless setup --docker --xcode <Xcode.xip>`).
- `python3` and `git` (Ubuntu has both); `docker` for step 8. `strings`, `keyctl` and `coredumpctl` are used when
  present.
- This repository at the release candidate's tag, for the script, the sample and this page:
  `git clone --branch <tag> https://github.com/fmsouza/xless && cd xless`.
- The Apple ID of the team's Account Holder or an Admin, with its two-factor device (or security key) at hand, and an
  iPhone or iPad signed in to TestFlight with the tester's Apple ID.
- The agreements of the team accepted (Free Apps is enough): xless detects pending agreements but never accepts them.

## Running it

```sh
export XLESS_M7_TEAM=ABCDE12345                 # the team ID
export XLESS_M7_TESTER=you@example.com          # a user of the team: gets the TestFlight build
export XLESS_M7_CONTACT_FIRST=Ada XLESS_M7_CONTACT_LAST=Lovelace \
       XLESS_M7_CONTACT_PHONE="+1 555 0100" XLESS_M7_CONTACT_EMAIL=you@example.com   # App Review's contact
# optional: XLESS_M7_BUNDLE_ID (default dev.xless.m7.<random>), XLESS_M7_APP_NAME (default "xless M7 <random>"),
#           XLESS_M7_COMPANY (the seller name, for a team's first app), XLESS_M7_DEVICE_UDID (+ _NAME)

scripts/acceptance-m7.sh --contract   # first: the read-only contract check (signs in if need be, keeps the session 30 minutes)
scripts/acceptance-m7.sh              # then the checklist; run it again after each stop
scripts/acceptance-m7.sh --status     # where it stands
scripts/acceptance-m7.sh --cleanup    # at the end: revoke and remove what the run made
```

`--dry-run` prints every step's commands and runs nothing; `--help` lists every variable. The settings are kept in
the state directory (`~/.local/state/xless-m7`, with the app's copy), so later runs need no variable; remove that
directory to start over with a new bundle ID.

The steps (each row of the record's table is one):

| Step | What the script runs | Where a person is needed |
|---|---|---|
| 0 | `XLESS_LIVE_APPLE=1 xless live-check`: at the start (the web session), after step 2 (the new API key) and after step 4 (the app). A `FAIL` stops the run before anything more is written. | The Apple ID sign-in (xless asks on the terminal), when no session is kept |
| 1 | `xless --version`; no `~/.config/xless`, no store, no key file under `$HOME` | Only if the machine is not fresh |
| 2 | `xless secrets init`, `xless unlock --for 1h` (here and before a later step, when the store is locked), `xless auth login --keep 30m --verbose` (when no session is kept; its trace is scanned), `xless team use`, `xless auth api-key create --role ADMIN`, `xless auth status`; the `--verbose` traces of `team list`, `keys list` and `apps list`, scanned | The store's passphrase; the sign-in, if step 0's is over |
| 3 | The sample copied and filled in; its bundle ID checked unregistered; `xless store validate` | — |
| 4 | `xless provision plan`, `xless provision apply --yes`, again, then `xless provision plan --json` must have no step | The sign-in, when the session of step 0 is over (app record, APNs key, App Privacy use the web session) |
| 5 | `xless auth logout`; `xless run <app>` with nothing in the environment (the store only), its processes watched; `xless testflight testers add` | Installing the build from TestFlight on a device |
| 6 | `xless release submit --build <step 5's build> --release manual` (`--dry-run` first), `xless release status` until *Pending Developer Release*, `xless release publish` | Waiting for App Review (days): the script stops with exit code 75; run it again later, or with `--wait` |
| 7 | Key files under `$HOME`; `strings` on the store; the environments of steps 5 and 8; `coredumpctl`; what the scans of the `--verbose` traces found; `xless lock`, then `xless auth status` and the kernel keyring | A sign-in, only if none was traced before |
| 8 | `xless run --docker <app> --to finalize`, then `--from sign`, every container inspected (mounts, variable names). It runs right after step 5: once App Review approves the version, Apple takes no more builds of it. An xless.yml project in Docker is one container that gets the store's secrets when it signs, so the run is split where the build ends | — |
| 9 | — | The answer: was a portal opened in a browser? |

When Apple rejects the version, step 6 stops with exit code 76: read the reason in Apple's email (not in App Store
Connect's web page: that would fail step 9), write it and the fix in this page's record, fix it, and run the script
again: it resubmits. When `live-check` or any step finds that Apple disagrees with xless, fix xless (an issue per
finding, linked from [research/m7-live-checklist.md](research/m7-live-checklist.md)), install the fixed build, and run
the script again.

## What is recorded, and what is not

Every command and its output, through `xless secrets redact` (the rules of `--verbose` traces: keys, tokens, cookies,
session headers, secret fields, presigned URLs) and with the run's personal values hidden: the Apple ID, the team ID
and the names of the Apple ID's teams (an individual's team is their name), the API key's issuer ID, the tester, the
review contact and the device. The team's bundle IDs are checked without being recorded. Paths show the state directory as `<kit>` and the home directory as
`~`. The `--verbose` traces of the sign-in and of step 2 are scanned in memory and never written; only their line counts
and findings are. The watchers of steps 5 and 8 record variable names and process names, never a value. Read the record before
committing it all the same.

Once every row is PASS, commit this page with the record and link it from [README.md](README.md#acceptance-records).

<!-- acceptance-m7:record:begin -->
## Record

- Started: 2026-11-24T13:21:14Z; last updated: 2026-11-24T23:03:53Z
- Machine: Ubuntu 22.04.5 LTS, aarch64, kernel 5.15.0-203-generic
- xless: 0.10.1 (steps 0 to 3, start of 4), 0.10.2 and 0.10.3 (rest of 4), 0.10.4 (4 again, the contract check, start of 5), 0.10.5 (the tester of 5,
  start of 8), 0.10.6 (8, start of 6), 0.10.7 (6 and the cleanup)
- App: bundle ID `dev.xless.m7.a7000e1`, name "xless M7 7000e1"

| # | Criterion | Result |
|---|---|---|
| 0 | Live contract check: the list and get endpoints xless reads, decoded (read-only) | **PASS** — no endpoint failed (again after step 4) |
| 1 | Fresh Linux machine, xless from the release candidate, no ~/.config/xless, no key files | **PASS** — fresh: 0.10.1, no configuration, no store, no key file |
| 2 | xless auth login; xless auth api-key create (key in the store); xless auth logout | **PASS** — API key 2NPPFUZ7VU created and kept in the store; signed out |
| 3 | A new sample app: never-registered bundle ID, push entitlement, appstore/ with two locales and screenshots | **PASS** — dev.xless.m7.a7000e1, push entitlement, en-US and pt-BR, iPhone 6.9" and iPad 13" screenshots, free, every territory |
| 4 | xless provision plan, then apply; a second apply is a no-op | **PASS** — provisioned; a second apply had nothing to do (plan: 0 steps) |
| 5 | xless run ships to TestFlight using only the store; a tester gets the build | **PASS** — build 29925866 shipped with the store only, tester added to "M7 Acceptance", installed on a device |
| 6 | xless release submit --release manual; status to Pending Developer Release; xless release publish | **PARTLY** — submitted (WAITING_FOR_REVIEW, 2026-11-24T22:51Z), then withdrawn by the maintainer before the review; approval and `release publish` not verified |
| 7 | Security: no secret under $HOME but the vault, vault strings, process environments, core dumps, keyring, --verbose | **not run** — the processes watched in steps 5 and 8 had 0 findings; the rest was not checked |
| 8 | Docker: xless run --docker with the store; the build container never sees a secret | **PASS** — build 29925945: the build container had no secret mount or variable; only the signing container read the store |
| 9 | Neither developer.apple.com nor appstoreconnect.apple.com was opened in a browser | **not run** |

### What the run did not check

The maintainer ended the run after the submission, to check the rest with a real app ([#181](https://github.com/fmsouza/xless/issues/181)):

- App Review to *Pending Developer Release*, and `xless release publish` (step 6);
- the security checks of step 7;
- step 9: the person was not asked. Nothing in the steps above needed a portal. Removing the app record at the end does:
  it has no API.

### What was done outside the script

- Before step 1, setting the VM up: `docker-buildx` and `systemd-coredump` installed on top of the runbook's packages,
  and the images of Xcode 27.2 (the runbook names 27.0) tagged by hand as `local-arm64`, the name step 8 runs.
- Step 4: `socialMedia: false` added to the copied `appstore/app.yml` (noted there).
- Step 6: China mainland taken out of the availability of step 3's "every territory" (noted there).
- Step 8: its state removed by hand after its first try (noted there).
- After step 6, with 0.10.7: `xless release cancel` (the version became *Developer Rejected*, the submission *complete*),
  the app made available in no territory (`xless store push --only pricing`, then `xless api` for the last one),
  `xless testflight testers remove`, `xless testflight groups delete`, `xless builds expire` on the three builds. Then
  `--cleanup`, below.

Each failure recorded below is a defect found by the run, fixed in a release, and passed on the next try: #163, #165, #167,
#169 (step 4), #171 (the contract check), #173 (step 5), #175 (step 8, the kit), #177 and #179 (step 6).

### 0. Live contract check: the list and get endpoints xless reads, decoded (read-only)

```console
$ xless auth login --keep 30m
signed in as <redacted>
  TEAM ID     NAME        TYPE
  <redacted>  <redacted> <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T14:12:27Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless live-check --team <redacted>
skip  api  every documented API endpoint              no API key: missing secret ASC_KEY_ID
ok    web  GET /olympus/v1/session                    provider <redacted>, publicProviderId present, 2 provider(s)
ok    web  GET /olympus/v1/contractMessages           0 pending agreements
ok    web  POST QH65B2/account/listTeams.action       1 team
ok    web  app groups (listApplicationGroups.action)  6 app groups
ok    web  iCloud containers (v1/cloudContainers)     0 containers
ok    web  auth keys (account/auth/key/list)          0 key(s)
ok    web  GET /iris/v1/apiKeys                       4 key(s)
ok    web  GET /iris/v1/apiKeys/{id}                  roles DEVELOPER, active
skip  web  the web endpoints of an app                no app to read (re-run with --app <bundle ID> after creating one)

8 ok, 0 to read, 0 failed, 2 skipped
Object 0x235040c05e0 of class _MultiHandle deallocated with non-zero retain count 2. This object's deinit, or something called from it, may have created a strong reference to self which outlived deinit, resulting in a dangling reference.
(exit 134)
```
**Result: FAIL** — an endpoint answered in a way xless cannot read (on its own): fix xless before anything is written (docs/research/m7-live-checklist.md)

```console
$ xless auth login --keep 30m
signed in as <redacted>
  TEAM ID     NAME        TYPE
  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T16:16:59Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless live-check --team <redacted>
skip  api  every documented API endpoint              no API key: missing secret ASC_KEY_ID
ok    web  GET /olympus/v1/session                    provider <redacted>, publicProviderId present, 2 provider(s)
ok    web  GET /olympus/v1/contractMessages           0 pending agreements
ok    web  POST QH65B2/account/listTeams.action       1 team
ok    web  app groups (listApplicationGroups.action)  6 app groups
ok    web  iCloud containers (v1/cloudContainers)     0 containers
ok    web  auth keys (account/auth/key/list)          0 key(s)
ok    web  GET /iris/v1/apiKeys                       4 key(s)
ok    web  GET /iris/v1/apiKeys/{id}                  roles DEVELOPER, active
skip  web  the web endpoints of an app                no app to read (re-run with --app <bundle ID> after creating one)

8 ok, 0 to read, 0 failed, 2 skipped
(exit 0)
```
**Result: PASS** — no endpoint failed (on its own)

_2026-11-24T15:47Z_

```console
$ xless auth login --keep 30m
signed in as <redacted>
  TEAM ID     NAME        TYPE
  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T16:20:26Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless live-check --team <redacted>
skip  api  every documented API endpoint              no API key: missing secret ASC_KEY_ID
ok    web  GET /olympus/v1/session                    provider <redacted>, publicProviderId present, 2 provider(s)
ok    web  GET /olympus/v1/contractMessages           0 pending agreements
ok    web  POST QH65B2/account/listTeams.action       1 team
ok    web  app groups (listApplicationGroups.action)  6 app groups
ok    web  iCloud containers (v1/cloudContainers)     0 containers
ok    web  auth keys (account/auth/key/list)          0 key(s)
ok    web  GET /iris/v1/apiKeys                       4 key(s)
ok    web  GET /iris/v1/apiKeys/{id}                  roles DEVELOPER, active
skip  web  the web endpoints of an app                no app to read (re-run with --app <bundle ID> after creating one)

8 ok, 0 to read, 0 failed, 2 skipped
(exit 0)
```
**Result: PASS** — no endpoint failed

```console
$ xless live-check --team <redacted>
ok    api  GET /v1/apps                                                 3 apps
ok    api  GET /v1/devices                                              2 devices
ok    api  GET /v1/devices/{id}                                         ENABLED
ok    api  GET /v1/bundleIds                                            21 bundle IDs
ok    api  GET /v1/merchantIds                                          0 merchant IDs
warn  api  GET /v1/certificates                                         7 certificates; xless reads activated, never sent
warn  api  GET /v1/certificates/{id}                                    1 certificate; xless reads activated, never sent
ok    api  GET /v1/profiles?include=certificates                        0 profiles
warn  api  GET /v1/profiles?include=bundleId                            13 profiles; xless reads profileContent, never sent
ok    api  GET /v1/profiles/{id}?include=bundleId                       1 profile
ok    api  GET /v1/users                                                2 users
ok    api  GET /v1/users/{id}                                           1 user
ok    api  GET /v1/userInvitations                                      0 invitations
ok    api  GET /v1/sandboxTesters                                       0 sandbox testers
ok    api  GET /v1/territories                                          175 territorys
ok    api  GET /v1/appCategories                                        26 categorys
ok    api  GET /v1/bundleIds/{id}/bundleIdCapabilities                  1 capability
ok    api  GET /v1/apps/{id}                                            1 app
ok    api  GET /v1/apps/{id}/appInfos                                   1 app info
ok    api  GET /v1/appInfos/{id}/appInfoLocalizations                   1 localization
ok    api  GET /v1/appInfos/{id}/ageRatingDeclaration                   32 answers
ok    api  GET /v1/apps/{id}/appStoreVersions                           2 versions
ok    api  GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations   1 localization
ok    api  GET /v1/appStoreVersions/{id}/appStoreReviewDetail           none (404)
ok    api  GET /v1/appStoreVersions/{id}/appStoreVersionPhasedRelease   none (404)
ok    api  GET /v1/appStoreVersions/{id}/build                          no build attached
ok    api  GET /v1/appStoreVersionLocalizations/{id}/appScreenshotSets  0 sets, 0 screenshots
ok    api  GET /v1/appStoreVersionLocalizations/{id}/appPreviewSets     0 preview sets
ok    api  GET /v1/apps/{id}/endUserLicenseAgreement                    none (404)
ok    api  GET /v1/apps/{id}/appEncryptionDeclarations                  0 declarations
ok    api  GET /v1/apps/{id}/accessibilityDeclarations                  0 declarations
ok    api  GET /v1/apps/{id}/appPriceSchedule                           none (404)
ok    api  GET /v1/apps/{id}/appAvailabilityV2                          none (404)
ok    api  GET /v1/apps/{id}/appPricePoints?filter[territory]=USA       801 price points
ok    api  GET /v1/builds?filter[app]                                   20 builds
ok    api  GET /v1/builds/{id}?include=…                                <redacted>, beta IN_BETA_TESTING
ok    api  GET /v1/apps/{id}/betaGroups                                 1 group
ok    api  GET /v1/betaTesters?filter[apps]                             2 testers
ok    api  GET /v1/apps/{id}/betaAppLocalizations                       1 localization
ok    api  GET /v1/apps/{id}/betaAppReviewDetail                        1 review detail
ok    api  GET /v1/apps/{id}/betaLicenseAgreement                       1 licence
ok    api  GET /v1/apps/{id}/appStoreVersions (release)                 1 version
ok    api  GET /v1/reviewSubmissions?filter[app]                        0 submissions
ok    api  GET /v1/apps/{id}/inAppPurchasesV2                           0 in-app purchases
ok    api  GET /v1/apps/{id}/subscriptionGroups                         0 subscription groups
ok    api  GET /v1/apps/{id}/customerReviews                            0 reviews
ok    api  GET /v1/apps/{id}/webhooks                                   0 webhooks
skip  web  every Apple ID web session endpoint                          no session kept by `xless auth login --keep`

44 ok, 3 to read, 0 failed, 1 skipped
(exit 0)
```
**Result: PASS** — no endpoint failed (again after step 2)

```console
$ xless live-check --team <redacted> --app dev.xless.m7.a7000e1
ok    api  GET /v1/apps                                                 4 apps
ok    api  GET /v1/devices                                              2 devices
ok    api  GET /v1/devices/{id}                                         ENABLED
ok    api  GET /v1/bundleIds                                            22 bundle IDs
ok    api  GET /v1/merchantIds                                          0 merchant IDs
warn  api  GET /v1/certificates                                         8 certificates; xless reads activated, never sent
warn  api  GET /v1/certificates/{id}                                    1 certificate; xless reads activated, never sent
ok    api  GET /v1/profiles?include=certificates                        0 profiles
warn  api  GET /v1/profiles?include=bundleId                            14 profiles; xless reads profileContent, never sent
ok    api  GET /v1/profiles/{id}?include=bundleId                       1 profile
ok    api  GET /v1/users                                                2 users
ok    api  GET /v1/users/{id}                                           1 user
ok    api  GET /v1/userInvitations                                      0 invitations
ok    api  GET /v1/sandboxTesters                                       0 sandbox testers
ok    api  GET /v1/territories                                          175 territorys
ok    api  GET /v1/appCategories                                        26 categorys
ok    api  the app dev.xless.m7.a7000e1                                 xless M7 7000e1 (6838797113)
ok    api  GET /v1/bundleIds/{id}/bundleIdCapabilities                  2 capabilitys
ok    api  GET /v1/apps/{id}                                            1 app
ok    api  GET /v1/apps/{id}/appInfos                                   1 app info
ok    api  GET /v1/appInfos/{id}/appInfoLocalizations                   2 localizations
ok    api  GET /v1/appInfos/{id}/ageRatingDeclaration                   32 answers
ok    api  GET /v1/apps/{id}/appStoreVersions                           1 version
ok    api  GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations   2 localizations
ok    api  GET /v1/appStoreVersions/{id}/appStoreReviewDetail           1 review detail
ok    api  GET /v1/appStoreVersions/{id}/appStoreVersionPhasedRelease   none (404)
ok    api  GET /v1/appStoreVersions/{id}/build                          no build attached
warn  api  GET /v1/appStoreVersionLocalizations/{id}/appScreenshotSets  2 sets, 2 screenshots; xless reads previewFrameTimeCode, videoDeliveryState, videoUrl, never sent
ok    api  GET /v1/appStoreVersionLocalizations/{id}/appPreviewSets     0 preview sets
ok    api  GET /v1/apps/{id}/endUserLicenseAgreement                    none (404)
ok    api  GET /v1/apps/{id}/appEncryptionDeclarations                  0 declarations
ok    api  GET /v1/apps/{id}/accessibilityDeclarations                  0 declarations
ok    api  GET /v1/apps/{id}/appPriceSchedule                           1 price
ok    api  GET /v1/apps/{id}/appAvailabilityV2                          175 territorys
ok    api  GET /v1/apps/{id}/appPricePoints?filter[territory]=USA       801 price points
ok    api  GET /v1/builds?filter[app]                                   0 builds
ok    api  GET /v1/apps/{id}/betaGroups                                 1 group
ok    api  GET /v1/betaTesters?filter[apps]                             0 testers
ok    api  GET /v1/apps/{id}/betaAppLocalizations                       0 localizations
ok    api  GET /v1/apps/{id}/betaAppReviewDetail                        1 review detail
FAIL  api  GET /v1/apps/{id}/betaLicenseAgreement                       DecodingError.valueNotFound: Expected value of type Dictionary<String, Any>. Path: data. Debug description: Cannot get keyed decoding container -- found null value instead
ok    api  GET /v1/apps/{id}/appStoreVersions (release)                 1 version
ok    api  GET /v1/reviewSubmissions?filter[app]                        0 submissions
ok    api  GET /v1/apps/{id}/inAppPurchasesV2                           0 in-app purchases
ok    api  GET /v1/apps/{id}/subscriptionGroups                         0 subscription groups
ok    api  GET /v1/apps/{id}/customerReviews                            0 reviews
ok    api  GET /v1/apps/{id}/webhooks                                   0 webhooks
ok    web  GET /olympus/v1/session                                      provider <redacted>, publicProviderId present, 2 provider(s)
ok    web  GET /olympus/v1/contractMessages                             0 pending agreements
ok    web  POST QH65B2/account/listTeams.action                         1 team
ok    web  app groups (listApplicationGroups.action)                    6 app groups
ok    web  iCloud containers (v1/cloudContainers)                       0 containers
ok    web  auth keys (account/auth/key/list)                            1 key(s)
ok    web  auth key (account/auth/key/get)                              APNs
ok    web  GET /iris/v1/apiKeys                                         5 key(s)
ok    web  GET /iris/v1/apiKeys/{id}                                    roles ADMIN, active
ok    web  GET /iris/v1/apps?filter[bundleId]                           app 6838797113
ok    web  v1/bundleIds?filter[identifier]                              bundle ID F25ZC495LQ
ok    web  v1/bundleIds/{id} (APP_GROUPS relationship)                  capability absent
ok    web  v1/bundleIds/{id} (ICLOUD relationship)                      capability absent
ok    web  GET /iris/v1/appDataUsageCategories…                         35 categories, 6 purposes, 4 protections
ok    web  GET /iris/v1/apps/{id}/dataUsages                            1 data usage
ok    web  GET /iris/v1/apps/{id}/dataUsagePublishState                 published: true

58 ok, 4 to read, 1 failed, 0 skipped
(exit 1)
```
**Result: FAIL** — an endpoint answered in a way xless cannot read (again after step 4): fix xless before anything is written (docs/research/m7-live-checklist.md)

```console
$ xless live-check --team <redacted> --app dev.xless.m7.a7000e1
ok    api  GET /v1/apps                                                 4 apps
ok    api  GET /v1/devices                                              2 devices
ok    api  GET /v1/devices/{id}                                         ENABLED
ok    api  GET /v1/bundleIds                                            22 bundle IDs
ok    api  GET /v1/merchantIds                                          0 merchant IDs
warn  api  GET /v1/certificates                                         8 certificates; xless reads activated, never sent
warn  api  GET /v1/certificates/{id}                                    1 certificate; xless reads activated, never sent
ok    api  GET /v1/profiles?include=certificates                        0 profiles
warn  api  GET /v1/profiles?include=bundleId                            14 profiles; xless reads profileContent, never sent
ok    api  GET /v1/profiles/{id}?include=bundleId                       1 profile
ok    api  GET /v1/users                                                2 users
ok    api  GET /v1/users/{id}                                           1 user
ok    api  GET /v1/userInvitations                                      0 invitations
ok    api  GET /v1/sandboxTesters                                       0 sandbox testers
ok    api  GET /v1/territories                                          175 territorys
ok    api  GET /v1/appCategories                                        26 categorys
ok    api  the app dev.xless.m7.a7000e1                                 xless M7 7000e1 (6838797113)
ok    api  GET /v1/bundleIds/{id}/bundleIdCapabilities                  2 capabilitys
ok    api  GET /v1/apps/{id}                                            1 app
ok    api  GET /v1/apps/{id}/appInfos                                   1 app info
ok    api  GET /v1/appInfos/{id}/appInfoLocalizations                   2 localizations
ok    api  GET /v1/appInfos/{id}/ageRatingDeclaration                   32 answers
ok    api  GET /v1/apps/{id}/appStoreVersions                           1 version
ok    api  GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations   2 localizations
ok    api  GET /v1/appStoreVersions/{id}/appStoreReviewDetail           1 review detail
ok    api  GET /v1/appStoreVersions/{id}/appStoreVersionPhasedRelease   none (404)
ok    api  GET /v1/appStoreVersions/{id}/build                          no build attached
warn  api  GET /v1/appStoreVersionLocalizations/{id}/appScreenshotSets  2 sets, 2 screenshots; xless reads previewFrameTimeCode, videoDeliveryState, videoUrl, never sent
ok    api  GET /v1/appStoreVersionLocalizations/{id}/appPreviewSets     0 preview sets
ok    api  GET /v1/apps/{id}/endUserLicenseAgreement                    none (404)
ok    api  GET /v1/apps/{id}/appEncryptionDeclarations                  0 declarations
ok    api  GET /v1/apps/{id}/accessibilityDeclarations                  0 declarations
ok    api  GET /v1/apps/{id}/appPriceSchedule                           1 price
ok    api  GET /v1/apps/{id}/appAvailabilityV2                          175 territorys
ok    api  GET /v1/apps/{id}/appPricePoints?filter[territory]=USA       801 price points
ok    api  GET /v1/builds?filter[app]                                   0 builds
ok    api  GET /v1/apps/{id}/betaGroups                                 1 group
ok    api  GET /v1/betaTesters?filter[apps]                             0 testers
ok    api  GET /v1/apps/{id}/betaAppLocalizations                       0 localizations
ok    api  GET /v1/apps/{id}/betaAppReviewDetail                        1 review detail
ok    api  GET /v1/apps/{id}/betaLicenseAgreement                       none
ok    api  GET /v1/apps/{id}/appStoreVersions (release)                 1 version
ok    api  GET /v1/reviewSubmissions?filter[app]                        0 submissions
ok    api  GET /v1/apps/{id}/inAppPurchasesV2                           0 in-app purchases
ok    api  GET /v1/apps/{id}/subscriptionGroups                         0 subscription groups
ok    api  GET /v1/apps/{id}/customerReviews                            0 reviews
ok    api  GET /v1/apps/{id}/webhooks                                   0 webhooks
ok    web  GET /olympus/v1/session                                      provider <redacted>, publicProviderId present, 2 provider(s)
ok    web  GET /olympus/v1/contractMessages                             0 pending agreements
ok    web  POST QH65B2/account/listTeams.action                         1 team
ok    web  app groups (listApplicationGroups.action)                    6 app groups
ok    web  iCloud containers (v1/cloudContainers)                       0 containers
ok    web  auth keys (account/auth/key/list)                            1 key(s)
ok    web  auth key (account/auth/key/get)                              APNs
ok    web  GET /iris/v1/apiKeys                                         5 key(s)
ok    web  GET /iris/v1/apiKeys/{id}                                    roles ADMIN, active
ok    web  GET /iris/v1/apps?filter[bundleId]                           app 6838797113
ok    web  v1/bundleIds?filter[identifier]                              bundle ID F25ZC495LQ
ok    web  v1/bundleIds/{id} (APP_GROUPS relationship)                  capability absent
ok    web  v1/bundleIds/{id} (ICLOUD relationship)                      capability absent
ok    web  GET /iris/v1/appDataUsageCategories…                         35 categories, 6 purposes, 4 protections
ok    web  GET /iris/v1/apps/{id}/dataUsages                            1 data usage
ok    web  GET /iris/v1/apps/{id}/dataUsagePublishState                 published: true

59 ok, 4 to read, 0 failed, 0 skipped
(exit 0)
```
**Result: PASS** — no endpoint failed (again after step 4)

### 1. Fresh Linux machine, xless from the release candidate, no ~/.config/xless, no key files

_2026-11-24T15:50Z_

```console
$ xless --version
0.10.1
(exit 0)
```

```console
$ uname -srm
Linux 5.15.0-203-generic aarch64
(exit 0)
```
~/.config/xless holds: toolchain-meta.json 
No secret store.
No key file under $HOME.
**Result: PASS** — fresh: 0.10.1, no configuration, no store, no key file

### 2. xless auth login; xless auth api-key create (key in the store); xless auth logout

_2026-11-24T15:51Z_

```console
$ xless secrets init
created the secret store at ~/.local/share/xless/vault/secrets.vault
(exit 0)
```

```console
$ xless auth status
App Store Connect API key, no team selected:
  ASC_KEY_ID     missing
  ASC_ISSUER_ID  missing
  ASC_KEY_P8     missing
  key's role     unknown to xless (see App Store Connect > Users and Access > Integrations)
Apple ID web session:
  kept for <redacted> until 2026-11-24T16:20:26Z (28 min left); `xless auth logout` drops it
(exit 0)
```

```console
$ xless team use <redacted>
the default team is now <redacted> (saved in ~/.config/xless/config.yml)
(exit 0)
```

```console
$ xless auth api-key create --name xless\ M7\ acceptance --role ADMIN --team <redacted> --json
Created API key 2NPPFUZ7VU; downloading its private key (Apple offers it once).
Stored it in the secret store as ASC_KEY_P8@<redacted>; checking it with the documented API.
{
  "allApps" : true,
  "appIDs" : [

  ],
  "entry" : "ASC_KEY_P8@<redacted>",
  "issuerID" : "<redacted>",
  "keyID" : "2NPPFUZ7VU",
  "nickname" : "xless M7 acceptance",
  "roles" : [
    "ADMIN"
  ],
  "team" : "<redacted>",
  "verified" : true
}
(exit 0)
```

```console
$ xless secrets list
NAME                   KIND         TEAM        KEY ID      ISSUER ID                             CERTIFICATE  TYPE  ROLE   SERVICES  CREATED     EXPIRES
ASC_KEY_P8@<redacted>  asc-api-key  <redacted>  2NPPFUZ7VU  <redacted>  -            -     ADMIN  -         2026-11-24  -
(exit 0)
```

```console
$ xless auth status --team <redacted>
App Store Connect API key, team <redacted> (--team):
  ASC_KEY_ID     store (ASC_KEY_P8@<redacted>'s key ID)
  ASC_ISSUER_ID  store (ASC_KEY_P8@<redacted>'s issuer ID)
  ASC_KEY_P8     store (ASC_KEY_P8@<redacted>)
  key's team     <redacted>
  key's role     ADMIN
Apple ID web session:
  kept for <redacted> until 2026-11-24T16:20:26Z (28 min left); `xless auth logout` drops it
(exit 0)
```

```console
$ xless auth logout
forgot the kept Apple ID session
(exit 0)
```
**Result: PASS** — API key 2NPPFUZ7VU created and kept in the store; signed out

### 3. A new sample app: never-registered bundle ID, push entitlement, appstore/ with two locales and screenshots

_2026-11-24T15:52Z_
The app's files:
```text
./PRIVACY.md
./Package.swift
./README.md
./Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
./Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
./Resources/Assets.xcassets/Contents.json
./Resources/Info.plist
./Resources/PrivacyInfo.xcprivacy
./Sources/M7Acceptance/ContentView.swift
./Sources/M7Acceptance/M7AcceptanceApp.swift
./appstore/app.yml
./appstore/en-US/description.txt
./appstore/en-US/keywords.txt
./appstore/en-US/marketing_url.txt
./appstore/en-US/name.txt
./appstore/en-US/privacy_url.txt
./appstore/en-US/promotional_text.txt
./appstore/en-US/screenshots/APP_IPAD_PRO_3GEN_129/01-home.png
./appstore/en-US/screenshots/APP_IPHONE_67/01-home.png
./appstore/en-US/subtitle.txt
./appstore/en-US/support_url.txt
./appstore/pt-BR/description.txt
./appstore/pt-BR/keywords.txt
./appstore/pt-BR/marketing_url.txt
./appstore/pt-BR/name.txt
./appstore/pt-BR/privacy_url.txt
./appstore/pt-BR/promotional_text.txt
./appstore/pt-BR/screenshots/APP_IPAD_PRO_3GEN_129/01-home.png
./appstore/pt-BR/screenshots/APP_IPHONE_67/01-home.png
./appstore/pt-BR/subtitle.txt
./appstore/pt-BR/support_url.txt
./ios.entitlements
./xless.yml
```

```console
$ cat <kit>/app/xless.yml <kit>/app/ios.entitlements
# The M7 acceptance app (#105). scripts/acceptance-m7.sh copies this directory and replaces the placeholders
# dev.xless.m7.a7000e1 (XLESS_M7_BUNDLE_ID: a bundle ID never registered before) and <redacted> (XLESS_M7_TEAM).
bundleID: dev.xless.m7.a7000e1
teamID: <redacted>
version: "1.0"            # the App Store version of appstore/app.yml: release submit attaches this build to it
build: 1
platforms:
  ios: { minimumOS: "17.0", product: M7Acceptance, entitlements: ios.entitlements }
assets: Resources/Assets.xcassets
privacyManifest: Resources/PrivacyInfo.xcprivacy
infoPlist: Resources/Info.plist
testflight:
  groups: ["M7 Acceptance"]
  whatToTest: "Open the app and tap Allow notifications: the M7 acceptance build, made and shipped from Linux."
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>production</string>
</dict>
</plist>
(exit 0)
```
`xless bundle-ids list --json` (not recorded: it names every app of the team): dev.xless.m7.a7000e1 is not registered.

```console
$ xless store validate --dir <kit>/app/appstore
appstore/ is valid
(exit 0)
```
**Result: PASS** — dev.xless.m7.a7000e1, push entitlement, en-US and pt-BR, iPhone 6.9" and iPad 13" screenshots, free, every territory

### 4. xless provision plan, then apply; a second apply is a no-op

_2026-11-24T15:52Z_

```console
$ xless auth login --keep 30m
signed in as <redacted>
   TEAM ID     NAME        TYPE
*  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T16:22:57Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless provision plan --project <kit>/app
Bundle IDs:
  + create dev.xless.m7.a7000e1
      registered as universal (iOS and macOS), named "xless dev xless m7 a7000e1"
Capabilities:
  + enable PUSH_NOTIFICATIONS (Push Notifications) on dev.xless.m7.a7000e1
Certificates:
  + create Apple Distribution
      a new private key, generated and stored as XLESS_DIST_KEY@<redacted> before the request is sent
      the team has 2 other Apple Distribution certificates, whose private keys xless does not have
Keys:
  + create APNs key [web]
      the app's entitlements use push notifications (aps-environment), and neither the secret store nor the environment has an APNs key of team <redacted>
      unless the team has one already (checked when applied); stored as XLESS_APNS_KEY…@<redacted>: Apple offers its private key once
Profiles:
  + create xless dev.xless.m7.a7000e1 IOS_APP_STORE
      iOS App Store Connect for the iOS app, with the Apple Distribution certificate created above
App record:
  + create app record for dev.xless.m7.a7000e1 [web]
      "xless M7 7000e1", SKU XLESSM77000E1, primary locale en-US, IOS version 1.0
App Store listing:
  ~ push appstore/
      planned once the app record exists: text, review details, declarations, price and availability, screenshots and previews
App Privacy:
  ~ push app.yml privacy [web]
      sent once the app record exists
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
9 steps to apply (3 through the Apple ID web session)
(exit 0)
```

```console
$ xless provision apply --project <kit>/app --yes
Bundle IDs:
  + create dev.xless.m7.a7000e1
      registered as universal (iOS and macOS), named "xless dev xless m7 a7000e1"
Capabilities:
  + enable PUSH_NOTIFICATIONS (Push Notifications) on dev.xless.m7.a7000e1
Certificates:
  + create Apple Distribution
      a new private key, generated and stored as XLESS_DIST_KEY@<redacted> before the request is sent
      the team has 2 other Apple Distribution certificates, whose private keys xless does not have
Keys:
  + create APNs key [web]
      the app's entitlements use push notifications (aps-environment), and neither the secret store nor the environment has an APNs key of team <redacted>
      unless the team has one already (checked when applied); stored as XLESS_APNS_KEY…@<redacted>: Apple offers its private key once
Profiles:
  + create xless dev.xless.m7.a7000e1 IOS_APP_STORE
      iOS App Store Connect for the iOS app, with the Apple Distribution certificate created above
App record:
  + create app record for dev.xless.m7.a7000e1 [web]
      "xless M7 7000e1", SKU XLESSM77000E1, primary locale en-US, IOS version 1.0
App Store listing:
  ~ push appstore/
      planned once the app record exists: text, review details, declarations, price and availability, screenshots and previews
App Privacy:
  ~ push app.yml privacy [web]
      sent once the app record exists
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
9 steps to apply (3 through the Apple ID web session)
1/9 registered bundle ID dev.xless.m7.a7000e1
2/9 enabled PUSH_NOTIFICATIONS on dev.xless.m7.a7000e1
Stored the new private key in the secret store as XLESS_DIST_KEY@<redacted>; asking App Store Connect for the certificate.
3/9 created Apple Distribution certificate RZ7BAWUF5K, its key stored as XLESS_DIST_KEY@<redacted>
Created auth key FV9CR85HW2; downloading its private key (Apple offers it once).
4/9 created APNs key FV9CR85HW2, stored as XLESS_APNS_KEY@<redacted>
5/9 created profile xless dev.xless.m7.a7000e1 IOS_APP_STORE (UD2RM82A25)
6/9 created app record 6838797113 for dev.xless.m7.a7000e1
done: registered bundle ID dev.xless.m7.a7000e1; enabled PUSH_NOTIFICATIONS on dev.xless.m7.a7000e1; created Apple Distribution certificate RZ7BAWUF5K, its key stored as XLESS_DIST_KEY@<redacted>; created APNs key FV9CR85HW2, stored as XLESS_APNS_KEY@<redacted>; created profile xless dev.xless.m7.a7000e1 IOS_APP_STORE (UD2RM82A25); created app record 6838797113 for dev.xless.m7.a7000e1
left: App Store listing: push appstore/; App Privacy: push app.yml privacy; TestFlight: create group M7 Acceptance
error: [account] App Store listing, push appstore/: GET /v1/apps/6838797113: App Store Connect HTTP 404 — NOT_FOUND: The specified resource does not exist: There is no resource of type 'apps' with id '6838797113' (6 of 9 steps were done, 3 left) — App Store Connect has no such resource: check the ID and the path (and that the key's team owns it); then re-run `xless provision apply`: it plans again and does only what is left
(exit 20)
```
**Result: FAIL** — xless provision apply stopped (re-run the script to continue from there)

_2026-11-24T15:54Z_

```console
$ xless auth login --keep 30m
signed in as <redacted>
   TEAM ID     NAME        TYPE
*  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T16:25:57Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless provision plan --project <kit>/app
App Store listing:
  ~ push appstore/
      ~ version 1.0 (IOS)
    copyright: "2026 xless contributors"
    releaseType: "AFTER_APPROVAL" → "MANUAL"
      ~ categories
    primaryCategory: "DEVELOPER_TOOLS"
    secondaryCategory: "UTILITIES"
      ~ app info en-US
    subtitle: "Built and shipped from Linux"
    privacyPolicyUrl (0 → 75 characters)
      + app info pt-BR
    name: "xless M7 7000e1"
    subtitle: "Feito e publicado no Linux"
    privacyPolicyUrl (0 → 75 characters)
      ~ version text en-US
    description (0 → 415 characters)
    keywords: "xless,linux,sample,toolchain,developer,push"
    promotionalText: "Made, signed and submitted from a Linux terminal."
    supportUrl: "https://github.com/fmsouza/xless/issues"
    marketingUrl: "https://github.com/fmsouza/xless"
      + version text pt-BR
    description (0 → 464 characters)
    keywords: "xless,linux,exemplo,ferramenta,desenvolvedor,push"
    promotionalText: "Feito, assinado e submetido a partir de um terminal Linux."
    supportUrl: "https://github.com/fmsouza/xless/issues"
    marketingUrl: "https://github.com/fmsouza/xless"
      + App Review details
    contactFirstName: "<redacted>"
    contactLastName: "<redacted>"
    contactPhone: "<redacted>"
    contactEmail: "<redacted>"
    notes (0 → 252 characters)
    demoAccountRequired: "false"
      ~ content rights: contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT"
      ~ age rating
    advertising: "false"
    ageAssurance: "false"
    alcoholTobaccoOrDrugUseOrReferences: "NONE"
    contests: "NONE"
    gambling: "false"
    gamblingSimulated: "NONE"
    gunsOrOtherWeapons: "NONE"
    healthOrWellnessTopics: "false"
    horrorOrFearThemes: "NONE"
    lootBox: "false"
    matureOrSuggestiveThemes: "NONE"
    medicalOrTreatmentInformation: "NONE"
    messagingAndChat: "false"
    parentalControls: "false"
    profanityOrCrudeHumor: "NONE"
    sexualContentGraphicAndNudity: "NONE"
    sexualContentOrNudity: "NONE"
    unrestrictedWebAccess: "false"
    userGeneratedContent: "false"
    violenceCartoonOrFantasy: "NONE"
    violenceRealistic: "NONE"
    violenceRealisticProlongedGraphicOrSadistic: "NONE"
      + price schedule
    baseTerritory: "USA"
    price: "free"
      + availability
    territories: "all"
    newTerritories: "true"
      + screenshots en-US APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots en-US APP_IPHONE_67: 01-home.png: "upload"
      + screenshots pt-BR APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots pt-BR APP_IPHONE_67: 01-home.png: "upload"
App Privacy:
  ~ push app.yml privacy [web]
      + App Privacy: data not collected
      ~ publish the App Privacy answers of dev.xless.m7.a7000e1
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
3 steps to apply (1 through the Apple ID web session)
(exit 0)
```

```console
$ xless provision apply --project <kit>/app --yes
App Store listing:
  ~ push appstore/
      ~ version 1.0 (IOS)
    copyright: "2026 xless contributors"
    releaseType: "AFTER_APPROVAL" → "MANUAL"
      ~ categories
    primaryCategory: "DEVELOPER_TOOLS"
    secondaryCategory: "UTILITIES"
      ~ app info en-US
    subtitle: "Built and shipped from Linux"
    privacyPolicyUrl (0 → 75 characters)
      + app info pt-BR
    name: "xless M7 7000e1"
    subtitle: "Feito e publicado no Linux"
    privacyPolicyUrl (0 → 75 characters)
      ~ version text en-US
    description (0 → 415 characters)
    keywords: "xless,linux,sample,toolchain,developer,push"
    promotionalText: "Made, signed and submitted from a Linux terminal."
    supportUrl: "https://github.com/fmsouza/xless/issues"
    marketingUrl: "https://github.com/fmsouza/xless"
      + version text pt-BR
    description (0 → 464 characters)
    keywords: "xless,linux,exemplo,ferramenta,desenvolvedor,push"
    promotionalText: "Feito, assinado e submetido a partir de um terminal Linux."
    supportUrl: "https://github.com/fmsouza/xless/issues"
    marketingUrl: "https://github.com/fmsouza/xless"
      + App Review details
    contactFirstName: "<redacted>"
    contactLastName: "<redacted>"
    contactPhone: "<redacted>"
    contactEmail: "<redacted>"
    notes (0 → 252 characters)
    demoAccountRequired: "false"
      ~ content rights: contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT"
      ~ age rating
    advertising: "false"
    ageAssurance: "false"
    alcoholTobaccoOrDrugUseOrReferences: "NONE"
    contests: "NONE"
    gambling: "false"
    gamblingSimulated: "NONE"
    gunsOrOtherWeapons: "NONE"
    healthOrWellnessTopics: "false"
    horrorOrFearThemes: "NONE"
    lootBox: "false"
    matureOrSuggestiveThemes: "NONE"
    medicalOrTreatmentInformation: "NONE"
    messagingAndChat: "false"
    parentalControls: "false"
    profanityOrCrudeHumor: "NONE"
    sexualContentGraphicAndNudity: "NONE"
    sexualContentOrNudity: "NONE"
    unrestrictedWebAccess: "false"
    userGeneratedContent: "false"
    violenceCartoonOrFantasy: "NONE"
    violenceRealistic: "NONE"
    violenceRealisticProlongedGraphicOrSadistic: "NONE"
      + price schedule
    baseTerritory: "USA"
    price: "free"
      + availability
    territories: "all"
    newTerritories: "true"
      + screenshots en-US APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots en-US APP_IPHONE_67: 01-home.png: "upload"
      + screenshots pt-BR APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots pt-BR APP_IPHONE_67: 01-home.png: "upload"
App Privacy:
  ~ push app.yml privacy [web]
      + App Privacy: data not collected
      ~ publish the App Privacy answers of dev.xless.m7.a7000e1
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
3 steps to apply (1 through the Apple ID web session)
note: 5 of 15 changes were sent before this failure; re-run `xless store push` to send the rest (it sends only what still differs)
done: nothing
left: App Store listing: push appstore/; App Privacy: push app.yml privacy; TestFlight: create group M7 Acceptance
error: [account] App Store listing, push appstore/: POST /v1/appStoreVersionLocalizations: App Store Connect HTTP 409 — ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE: The provided entity includes an attribute with a value that has already been used: Entity with locale: pt-BR already exists. Try updating. (/data/attributes/locale) (0 of 3 steps were done, 3 left) — App Store Connect refused the value of `locale` (it conflicts with an existing resource or is not allowed): change it, or update the existing resource instead; then re-run `xless provision apply`: it plans again and does only what is left
(exit 20)
```
**Result: FAIL** — xless provision apply stopped (re-run the script to continue from there)

_2026-11-24T16:55Z_

```console
$ xless auth login --keep 30m
signed in as <redacted>
   TEAM ID     NAME        TYPE
*  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T17:47:24Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless provision plan --project <kit>/app
App Store listing:
  ~ push appstore/
      ~ version text pt-BR
    description (0 → 464 characters)
    keywords: "xless,linux,exemplo,ferramenta,desenvolvedor,push"
    promotionalText: "Feito, assinado e submetido a partir de um terminal Linux."
    supportUrl: "https://github.com/fmsouza/xless/issues"
    marketingUrl: "https://github.com/fmsouza/xless"
      + App Review details
    contactFirstName: "<redacted>"
    contactLastName: "<redacted>"
    contactPhone: "<redacted>"
    contactEmail: "<redacted>"
    notes (0 → 252 characters)
    demoAccountRequired: "false"
      ~ content rights: contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT"
      ~ age rating
    advertising: "false"
    ageAssurance: "false"
    alcoholTobaccoOrDrugUseOrReferences: "NONE"
    contests: "NONE"
    gambling: "false"
    gamblingSimulated: "NONE"
    gunsOrOtherWeapons: "NONE"
    healthOrWellnessTopics: "false"
    horrorOrFearThemes: "NONE"
    lootBox: "false"
    matureOrSuggestiveThemes: "NONE"
    medicalOrTreatmentInformation: "NONE"
    messagingAndChat: "false"
    parentalControls: "false"
    profanityOrCrudeHumor: "NONE"
    sexualContentGraphicAndNudity: "NONE"
    sexualContentOrNudity: "NONE"
    unrestrictedWebAccess: "false"
    userGeneratedContent: "false"
    violenceCartoonOrFantasy: "NONE"
    violenceRealistic: "NONE"
    violenceRealisticProlongedGraphicOrSadistic: "NONE"
      + price schedule
    baseTerritory: "USA"
    price: "free"
      + availability
    territories: "all"
    newTerritories: "true"
      + screenshots en-US APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots en-US APP_IPHONE_67: 01-home.png: "upload"
      + screenshots pt-BR APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots pt-BR APP_IPHONE_67: 01-home.png: "upload"
App Privacy:
  ~ push app.yml privacy [web]
      + App Privacy: data not collected
      ~ publish the App Privacy answers of dev.xless.m7.a7000e1
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
3 steps to apply (1 through the Apple ID web session)
(exit 0)
```

```console
$ xless provision apply --project <kit>/app --yes
App Store listing:
  ~ push appstore/
      ~ version text pt-BR
    description (0 → 464 characters)
    keywords: "xless,linux,exemplo,ferramenta,desenvolvedor,push"
    promotionalText: "Feito, assinado e submetido a partir de um terminal Linux."
    supportUrl: "https://github.com/fmsouza/xless/issues"
    marketingUrl: "https://github.com/fmsouza/xless"
      + App Review details
    contactFirstName: "<redacted>"
    contactLastName: "<redacted>"
    contactPhone: "<redacted>"
    contactEmail: "<redacted>"
    notes (0 → 252 characters)
    demoAccountRequired: "false"
      ~ content rights: contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT"
      ~ age rating
    advertising: "false"
    ageAssurance: "false"
    alcoholTobaccoOrDrugUseOrReferences: "NONE"
    contests: "NONE"
    gambling: "false"
    gamblingSimulated: "NONE"
    gunsOrOtherWeapons: "NONE"
    healthOrWellnessTopics: "false"
    horrorOrFearThemes: "NONE"
    lootBox: "false"
    matureOrSuggestiveThemes: "NONE"
    medicalOrTreatmentInformation: "NONE"
    messagingAndChat: "false"
    parentalControls: "false"
    profanityOrCrudeHumor: "NONE"
    sexualContentGraphicAndNudity: "NONE"
    sexualContentOrNudity: "NONE"
    unrestrictedWebAccess: "false"
    userGeneratedContent: "false"
    violenceCartoonOrFantasy: "NONE"
    violenceRealistic: "NONE"
    violenceRealisticProlongedGraphicOrSadistic: "NONE"
      + price schedule
    baseTerritory: "USA"
    price: "free"
      + availability
    territories: "all"
    newTerritories: "true"
      + screenshots en-US APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots en-US APP_IPHONE_67: 01-home.png: "upload"
      + screenshots pt-BR APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots pt-BR APP_IPHONE_67: 01-home.png: "upload"
App Privacy:
  ~ push app.yml privacy [web]
      + App Privacy: data not collected
      ~ publish the App Privacy answers of dev.xless.m7.a7000e1
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
3 steps to apply (1 through the Apple ID web session)
note: 3 of 10 changes were sent before this failure; re-run `xless store push` to send the rest (it sends only what still differs)
done: nothing
left: App Store listing: push appstore/; App Privacy: push app.yml privacy; TestFlight: create group M7 Acceptance
error: [account] App Store listing, push appstore/: PATCH /v1/ageRatingDeclarations/d9e2ff15-e0a3-48f5-9d71-67dcb97e163b: App Store Connect HTTP 409 — ENTITY_ERROR.ATTRIBUTE.REQUIRED: The provided entity is missing a required attribute: You must provide a value for the attribute 'socialMedia' with this request (/data/attributes/socialMedia) (0 of 3 steps were done, 3 left) — App Store Connect refused the value of `socialMedia` (it conflicts with an existing resource or is not allowed): change it, or update the existing resource instead; then re-run `xless provision apply`: it plans again and does only what is left
(exit 20)
```
**Result: FAIL** — xless provision apply stopped (re-run the script to continue from there)

Note (2026-11-24T18:04Z): xless updated from 0.10.2 to 0.10.3 (0.10.1 for steps 0 to 3 and the first two tries of this step); `socialMedia: false` added by hand to this app's appstore/app.yml, as in the sample since #170 (step 3 had already copied it).

_2026-11-24T18:04Z_

```console
$ xless auth login --keep 30m
signed in as <redacted>
   TEAM ID     NAME        TYPE
*  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T19:14:49Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless provision plan --project <kit>/app
App Store listing:
  ~ push appstore/
      ~ age rating
    advertising: "false"
    ageAssurance: "false"
    alcoholTobaccoOrDrugUseOrReferences: "NONE"
    contests: "NONE"
    gambling: "false"
    gamblingSimulated: "NONE"
    gunsOrOtherWeapons: "NONE"
    healthOrWellnessTopics: "false"
    horrorOrFearThemes: "NONE"
    lootBox: "false"
    matureOrSuggestiveThemes: "NONE"
    medicalOrTreatmentInformation: "NONE"
    messagingAndChat: "false"
    parentalControls: "false"
    profanityOrCrudeHumor: "NONE"
    sexualContentGraphicAndNudity: "NONE"
    sexualContentOrNudity: "NONE"
    socialMedia: "false"
    unrestrictedWebAccess: "false"
    userGeneratedContent: "false"
    violenceCartoonOrFantasy: "NONE"
    violenceRealistic: "NONE"
    violenceRealisticProlongedGraphicOrSadistic: "NONE"
      + price schedule
    baseTerritory: "USA"
    price: "free"
      + availability
    territories: "all"
    newTerritories: "true"
      + screenshots en-US APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots en-US APP_IPHONE_67: 01-home.png: "upload"
      + screenshots pt-BR APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots pt-BR APP_IPHONE_67: 01-home.png: "upload"
App Privacy:
  ~ push app.yml privacy [web]
      + App Privacy: data not collected
      ~ publish the App Privacy answers of dev.xless.m7.a7000e1
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
3 steps to apply (1 through the Apple ID web session)
(exit 0)
```

```console
$ xless provision apply --project <kit>/app --yes
App Store listing:
  ~ push appstore/
      ~ age rating
    advertising: "false"
    ageAssurance: "false"
    alcoholTobaccoOrDrugUseOrReferences: "NONE"
    contests: "NONE"
    gambling: "false"
    gamblingSimulated: "NONE"
    gunsOrOtherWeapons: "NONE"
    healthOrWellnessTopics: "false"
    horrorOrFearThemes: "NONE"
    lootBox: "false"
    matureOrSuggestiveThemes: "NONE"
    medicalOrTreatmentInformation: "NONE"
    messagingAndChat: "false"
    parentalControls: "false"
    profanityOrCrudeHumor: "NONE"
    sexualContentGraphicAndNudity: "NONE"
    sexualContentOrNudity: "NONE"
    socialMedia: "false"
    unrestrictedWebAccess: "false"
    userGeneratedContent: "false"
    violenceCartoonOrFantasy: "NONE"
    violenceRealistic: "NONE"
    violenceRealisticProlongedGraphicOrSadistic: "NONE"
      + price schedule
    baseTerritory: "USA"
    price: "free"
      + availability
    territories: "all"
    newTerritories: "true"
      + screenshots en-US APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots en-US APP_IPHONE_67: 01-home.png: "upload"
      + screenshots pt-BR APP_IPAD_PRO_3GEN_129: 01-home.png: "upload"
      + screenshots pt-BR APP_IPHONE_67: 01-home.png: "upload"
App Privacy:
  ~ push app.yml privacy [web]
      + App Privacy: data not collected
      ~ publish the App Privacy answers of dev.xless.m7.a7000e1
TestFlight:
  + create group M7 Acceptance
      internal, with every build (automatic distribution)
3 steps to apply (1 through the Apple ID web session)
1/3 pushed the App Store listing (7 changes)
2/3 sent the App Privacy answers (2 changes)
3/3 created internal TestFlight group M7 Acceptance
applied 3 steps
(exit 0)
```
Made by this run: 1 certificate(s), 1 profile(s), 1 auth key(s).

```console
$ xless provision apply --project <kit>/app --yes
nothing to do: the account has what team <redacted>'s project needs
(exit 0)
```

```console
$ xless provision plan --project <kit>/app --json
{
  "blockers" : [

  ],
  "drift" : [

  ],
  "notes" : [

  ],
  "steps" : [

  ],
  "team" : "<redacted>"
}
(exit 0)
```

```console
$ xless store push --dir <kit>/app/appstore --dry-run
dev.xless.m7.a7000e1 (IOS 1.0, PREPARE_FOR_SUBMISSION):
nothing to push: App Store Connect already matches the manifest
(exit 0)
```
**Result: PASS** — provisioned; a second apply had nothing to do (plan: 0 steps)

Note (2026-11-24T19:33Z): xless updated from 0.10.3 to 0.10.4, which reads an app without a beta license agreement (#172); the contract check is run again.

_2026-11-24T19:33Z_

```console
$ xless auth login --keep 30m
signed in as <redacted>
   TEAM ID     NAME        TYPE
*  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T20:54:02Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless provision plan --project <kit>/app
nothing to do: the account has what team <redacted>'s project needs
(exit 0)
```

```console
$ xless provision apply --project <kit>/app --yes
nothing to do: the account has what team <redacted>'s project needs
(exit 0)
```
Made by this run: 1 certificate(s), 1 profile(s), 1 auth key(s).

```console
$ xless provision apply --project <kit>/app --yes
nothing to do: the account has what team <redacted>'s project needs
(exit 0)
```

```console
$ xless provision plan --project <kit>/app --json
{
  "blockers" : [

  ],
  "drift" : [

  ],
  "notes" : [

  ],
  "steps" : [

  ],
  "team" : "<redacted>"
}
(exit 0)
```

```console
$ xless store push --dir <kit>/app/appstore --dry-run
dev.xless.m7.a7000e1 (IOS 1.0, PREPARE_FOR_SUBMISSION):
nothing to push: App Store Connect already matches the manifest
(exit 0)
```
**Result: PASS** — provisioned; a second apply had nothing to do (plan: 0 steps)

### 5. xless run ships to TestFlight using only the store; a tester gets the build

_2026-11-24T20:26Z_

```console
$ xless run <kit>/app
==> TestFlight: build number 29925866
==> build
xless: SDK: Xcode 27.2 (27B52), iphoneos27.2 SDK (24B8118) (recorded in <kit>/app/.xless/build/ios/sdk.json)
xless: compiler: Swift 6.4.2 (swift-6.4.2-RELEASE) from ~/.local/share/xless-native/toolchains/swift-6.4.2, Xcode's Swift 6.4.2
Building for production...
[Constructing description]
[Planning deferred tasks]
[20 / 32] M7Acceptance
[30 / 96]
[32 / 96]
[34 / 96]
[41 / 96]
[43 / 96]
[44 / 96]
[47 / 96]
[49 / 96]
[52 / 96]
[56 / 96]
[58 / 96]
[60 / 96]
[61 / 96]
[70 / 96]
[72 / 96]
[73 / 96]
[75 / 96]
[76 / 96]
[77 / 96]
[78 / 96]
[81 / 96]
[83 / 96]
[84 / 96]
[85 / 96] M7Acceptance
[94 / 96] M7Acceptance-App-product
[95 / 96] M7Acceptance-App-product
Build complete! (11.45 secs)
Planning...
[LSP] Created .bsp/xtool.json for enhanced IDE support. You may
      need to restart your editor for the change to take effect.
      You can disable this with `skipLSP: true` in xtool.yml.
Wrote to <kit>/app/xtool/M7Acceptance.app
xless: dSYMs: M7Acceptance.app.dSYM
xless: built with Swift 6.4.2 (swift-6.4.2-RELEASE) from ~/.local/share/xless-native/toolchains/swift-6.4.2, Xcode's Swift 6.4.2
xless: stamping from Xcode 27.2 (27B52), iphoneos27.2 SDK (24B8118)
warning: group M7 Acceptance has 0 testers, so nobody can install this build yet. Internal testers must be App Store Connect users (invite them with `xless users invite`); add them with `xless testflight testers add <email> --group "M7 Acceptance" --app dev.xless.m7.a7000e1` or testflight.testers in xless.yml
<kit>/app/.xless/build/ios/app/M7Acceptance.app
==> assets
<kit>/app/.xless/build/ios/assets/M7Acceptance.app
==> finalize
<kit>/app/.xless/build/ios/final/M7Acceptance.app
==> sign
<kit>/app/.xless/build/ios/signed/M7Acceptance.app
==> package
<kit>/app/.xless/build/ios/out/M7Acceptance.ipa
==> upload
build 8620718f-4086-4251-91f2-99f0142d46cf VALID
TestFlight: build 29925866 (8620718f-4086-4251-91f2-99f0142d46cf)
  group M7 Acceptance — available to 0 testers
  what to test (en-US): set
==> TestFlight delivery finished
(exit 0)
```
Processes watched during the run: 27 read, 267 unreadable (gone before they were read, or non-dumpable: xless makes itself so while it holds a secret), 0 finding(s).

```console
$ xless testflight testers add <redacted> --group M7\ Acceptance --app dev.xless.m7.a7000e1 --team <redacted> --yes
error: [account] POST /v1/betaGroups/8f5d0e19-8253-41ef-a418-8af90ee136f7/relationships/betaTesters: App Store Connect HTTP 409 — STATE_ERROR: The request cannot be fulfilled because of the state of another resource.: Tester(s) cannot be assigned — App Store Connect refused the request as conflicting with the resource's current state; see the detail above
(exit 20)
```
**Result: FAIL** — xless testflight testers add failed

_2026-11-24T20:32Z_

```console
$ xless testflight testers add <redacted> --group M7\ Acceptance --app dev.xless.m7.a7000e1 --team <redacted> --yes
error: [account] POST /v1/betaGroups/8f5d0e19-8253-41ef-a418-8af90ee136f7/relationships/betaTesters: App Store Connect HTTP 409 — STATE_ERROR: The request cannot be fulfilled because of the state of another resource.: Tester(s) cannot be assigned — App Store Connect refused the request as conflicting with the resource's current state; see the detail above
(exit 20)
```
**Result: FAIL** — xless testflight testers add failed

_Note: the run continues with xless 0.10.5 (the two tries above were 0.10.4). It fixes the tester lookup (#173)._

_2026-11-24T21:07Z_

```console
$ xless testflight testers add <redacted> --group M7\ Acceptance --app dev.xless.m7.a7000e1 --team <redacted> --yes
added <redacted> to group M7 Acceptance (new tester <redacted>); Apple emails them the invitation
(exit 0)
```

```console
$ xless builds list --app dev.xless.m7.a7000e1 --team <redacted>
ID                                    VERSION  BUILD     PLATFORM  STATE  NON-EXEMPT ENCRYPTION  UPLOADED    EXPIRES
8620718f-4086-4251-91f2-99f0142d46cf  1.0      29925866  ios       valid  no                     2026-11-24  2027-02-22
(exit 0)
```
Person: "Install build 1.0.0 (29925866) of "xless M7 7000e1" from TestFlight (invitation sent to the tester) on a device and open it" — done (2026-11-24T21:09Z).
**Result: PASS** — build 29925866 shipped with the store only, tester added to "M7 Acceptance", installed on a device

### 6. xless release submit --release manual; status to Pending Developer Release; xless release publish

_2026-11-24T21:49Z_

```console
$ xless release submit --dir <kit>/app/appstore --team <redacted> --build 1.0+29925866 --release manual --dry-run
pre-flight of dev.xless.m7.a7000e1 1.0 (ios), build 1.0+29925866:
  ok    manifest        appstore/ is valid
  ok    metadata        App Store Connect matches appstore/
  ok    listing         name, description, keywords and support URL in 2 locales; category, privacy policy URL, content rights
  ok    screenshots     en-US has the screenshots App Review needs
  warn  privacy         App Privacy is not checked: it has no App Store Connect API — keep an Apple ID web session (`xless auth login --keep 30m`) and re-run to check it
  ok    pricing         price set (USA: free)
  ok    availability    available in every territory
  ok    build           build 1.0+29925866 (8620718f-4086-4251-91f2-99f0142d46cf) is valid
  ok    encryption      export compliance is answered
  ok    review contact  <redacted> <<redacted>>
would send:
  attach build 1.0+29925866 (8620718f-4086-4251-91f2-99f0142d46cf)
  create a review submission
  add version 1.0 to it
  submit it
dry run: nothing was sent
(exit 0)
```

```console
$ xless release submit --dir <kit>/app/appstore --team <redacted> --build 1.0+29925866 --release manual
note: 2 of 4 steps were sent before add version 1.0 to it failed; re-run `xless release submit` to resume (it sends only what is missing)
error: [account] POST /v1/reviewSubmissionItems: App Store Connect HTTP 409 — STATE_ERROR.ENTITY_STATE_INVALID: appStoreVersions with id '60c3badf-8055-4036-bc7e-514ba2aa845c' is not in valid state.: This resource cannot be reviewed, please check associated errors to see why. — App Store Connect refused the request as conflicting with the resource's current state; see the detail above
(exit 20)
```
**Result: FAIL** — xless release submit exited with 20

_Note: the run continues with xless 0.10.7 (0.10.6 above), which shows why Apple refused (#177): the app's China mainland declarations (Security Assessment; AI-Generated or Synthetic Content) were unanswered, and they have no API (#179). Between the two runs, outside the script: a build of the #177 fix repeated the refused call and read the reasons; `availability.territories` of the app's copy lists every territory but CHN (as the sample now does), sent with `xless store push --only pricing` (`- availability in CHN`, 1 change); the refused call was then accepted; the version was taken out of the draft again, so the released xless submits it itself._

_2026-11-24T22:50Z_

```console
$ xless release submit --dir <kit>/app/appstore --team <redacted> --build 1.0+29925866 --release manual --dry-run
pre-flight of dev.xless.m7.a7000e1 1.0 (ios), build 1.0+29925866:
  ok    manifest        appstore/ is valid
  ok    metadata        App Store Connect matches appstore/
  ok    listing         name, description, keywords and support URL in 2 locales; category, privacy policy URL, content rights
  ok    screenshots     en-US has the screenshots App Review needs
  warn  privacy         App Privacy is not checked: it has no App Store Connect API — keep an Apple ID web session (`xless auth login --keep 30m`) and re-run to check it
  ok    pricing         price set (USA: free)
  ok    availability    available in 174 territories
  ok    build           build 1.0+29925866 (8620718f-4086-4251-91f2-99f0142d46cf) is valid
  ok    encryption      export compliance is answered
  ok    review contact  <redacted> <<redacted>>
would send:
  add version 1.0 to draft review submission 2edec591-63a0-4d7d-91c5-ec43985f64ab
  submit review submission 2edec591-63a0-4d7d-91c5-ec43985f64ab
dry run: nothing was sent
(exit 0)
```

```console
$ xless release submit --dir <kit>/app/appstore --team <redacted> --build 1.0+29925866 --release manual
pre-flight of dev.xless.m7.a7000e1 1.0 (ios), build 1.0+29925866:
  ok    manifest        appstore/ is valid
  ok    metadata        App Store Connect matches appstore/
  ok    listing         name, description, keywords and support URL in 2 locales; category, privacy policy URL, content rights
  ok    screenshots     en-US has the screenshots App Review needs
  warn  privacy         App Privacy is not checked: it has no App Store Connect API — keep an Apple ID web session (`xless auth login --keep 30m`) and re-run to check it
  ok    pricing         price set (USA: free)
  ok    availability    available in 174 territories
  ok    build           build 1.0+29925866 (8620718f-4086-4251-91f2-99f0142d46cf) is valid
  ok    encryption      export compliance is answered
  ok    review contact  <redacted> <<redacted>>
sent:
  add version 1.0 to draft review submission 2edec591-63a0-4d7d-91c5-ec43985f64ab
  submit review submission 2edec591-63a0-4d7d-91c5-ec43985f64ab
submitted dev.xless.m7.a7000e1 1.0 (ios) for review (review submission 2edec591-63a0-4d7d-91c5-ec43985f64ab, waiting for review)
(exit 0)
```
App Review: WAITING_FOR_REVIEW (2026-11-24T22:51Z).
**Result: PENDING** — in App Review (WAITING_FOR_REVIEW): run the script again later (or with --wait)

### 8. Docker: xless run --docker with the store; the build container never sees a secret

_2026-11-24T21:09Z_

```console
$ xless run --docker <kit>/app --to finalize
==> TestFlight: build number 29925909
==> build
xless: SDK: Xcode 27.2 (27B52), iphoneos27.2 SDK (24B8118) (recorded in /work/.xless/build/ios/sdk.json)
xless: compiler: Swift 6.4.2 (swift-6.4.2-RELEASE) from /opt/xless/toolchains/swift-6.4.2, Xcode's Swift 6.4.2
Building for production...
[Constructing description]
[Planning deferred tasks]
warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/GeneratedModuleMaps-iphoneos/M7Acceptance-Swift.h' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance-Builder.build/Release-iphoneos/M7Acceptance-App-p.build/Objects-normal/arm64/9f65232cb83f8421e3a495a5062eba382369c975104ee97bafc405ab795bfc5e-common-args.resp' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance-Builder.build/Release-iphoneos/M7Acceptance-App-p.build/Objects-normal/arm64/M7Acceptance-App.LinkFileList' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance-Builder.build/Release-iphoneos/M7Acceptance-App-p.build/Objects-normal/arm64/M7Acceptance-App_dependency_info.dat' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance-Builder.build/Release-iphoneos/M7Acceptance-App-p.build/Objects-normal/arm64/M7Acceptance-App_lto.o' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance-Builder.build/Release-iphoneos/M7Acceptance-App-p.build/Objects-normal/arm64/stub.o' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance-Builder.build/Release-iphoneos/M7Acceptance-App-p.build/Objects-normal/arm64/stub.o.scan' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/GeneratedModuleMaps-iphoneos/M7Acceptance.modulemap' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Products/Release-iphoneos/M7Acceptance-App' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/M7Acceptance.modulemap' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Products/Release-iphoneos/M7Acceptance-App.dSYM' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/ContentView.o' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance Swift Compilation Finished' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance-OutputFileMap.json' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance-Swift.h' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance-dependency-scan.dia' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance-primary.swiftconstvalues' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance.LinkFileList' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance.SwiftFileList' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance.abi.json' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance.swiftdoc' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance.swiftmodule' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance.swiftsourceinfo' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7AcceptanceApp.o' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance_const_extract_protocols.json' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance_dependency_info.dat' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Intermediates.noindex/M7Acceptance.build/Release-iphoneos/M7Acceptance-t.build/Objects-normal/arm64/M7Acceptance_lto.o' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Products/Release-iphoneos/M7Acceptance.o' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Products/Release-iphoneos/M7Acceptance.swiftmodule/arm64-apple-ios.abi.json' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Products/Release-iphoneos/M7Acceptance.swiftmodule/arm64-apple-ios.swiftdoc' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Products/Release-iphoneos/M7Acceptance.swiftmodule/arm64-apple-ios.swiftmodule' is located outside of the allowed root paths.

warning: Stale file '<kit>/app/.build/out/Products/Release-iphoneos/M7Acceptance-App.dSYM/Contents/Resources/DWARF/M7Acceptance-App' is located outside of the allowed root paths.

[20 / 32] M7Acceptance
[30 / 96]
[32 / 96]
[38 / 96]
[41 / 96]
[43 / 96]
[44 / 96]
[46 / 96]
[48 / 96]
[49 / 96]
[51 / 96]
[52 / 96]
[56 / 96]
[57 / 96]
[61 / 96]
[69 / 96]
[76 / 96]
[77 / 96]
[78 / 96]
[81 / 96]
[83 / 96]
[85 / 96] M7Acceptance
[94 / 96] M7Acceptance-App-product
[95 / 96] M7Acceptance-App-product
Build complete! (11.17 secs)
Planning...
Wrote to /work/xtool/M7Acceptance.app
xless: dSYMs: M7Acceptance.app.dSYM
xless: built with Swift 6.4.2 (swift-6.4.2-RELEASE) from /opt/xless/toolchains/swift-6.4.2, Xcode's Swift 6.4.2
xless: stamping from Xcode 27.2 (27B52), iphoneos27.2 SDK (24B8118)
/work/.xless/build/ios/app/M7Acceptance.app
==> assets
/work/.xless/build/ios/assets/M7Acceptance.app
==> finalize
/work/.xless/build/ios/final/M7Acceptance.app
==> TestFlight: stopped after finalize (--to), nothing delivered
(exit 0)
```
Containers of the build half:
container f32cd2e8fc68 image=xless:local-arm64 args=[ship --platform ios --to finalize] mounts=/work env=APPIMAGE_EXTRACT_AND_RUN,PATH,SWIFT_BRANCH,SWIFT_DETERMINISTIC_HASHING,SWIFT_PLATFORM,SWIFT_SIGNING_KEY,SWIFT_VERSION,SWIFT_WEBROOT,XDG_CONFIG_HOME,XLESS_BUILD_NUMBER,XLESS_SWIFT_TOOLCHAIN,XLESS_TOOLCHAIN_META secrets=<redacted> material=-
Processes watched during the run: 34 read, 34 unreadable (gone before they were read, or non-dumpable: xless makes itself so while it holds a secret), 0 finding(s).

```console
$ xless run --docker <kit>/app --from sign
==> TestFlight: build number 29925909
==> secrets from the secret store: sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY
==> sign
/work/.xless/build/ios/signed/M7Acceptance.app
==> package
/work/.xless/build/ios/out/M7Acceptance.ipa
==> upload
build b327a008-7cb0-41ca-9371-4b3fcc54edcb VALID
TestFlight: build 29925909 (b327a008-7cb0-41ca-9371-4b3fcc54edcb)
  group M7 Acceptance — available to 1 tester
  what to test (en-US): set
==> TestFlight delivery finished
(exit 0)
```
Containers of the sign half:
container d0d9ede49468 image=xless:local-arm64 args=[ship --platform ios --from sign] mounts=/secrets/store,/work env=APPIMAGE_EXTRACT_AND_RUN,ASC_ISSUER_ID_FILE,ASC_KEY_ID_FILE,ASC_KEY_P8_FILE,PATH,SWIFT_BRANCH,SWIFT_DETERMINISTIC_HASHING,SWIFT_PLATFORM,SWIFT_SIGNING_KEY,SWIFT_VERSION,SWIFT_WEBROOT,XDG_CONFIG_HOME,XLESS_BUILD_NUMBER,XLESS_DIST_KEY_FILE,XLESS_SWIFT_TOOLCHAIN,XLESS_TOOLCHAIN_META secrets=<redacted> material=-
Processes watched during the run: 123 read, 226 unreadable (gone before they were read, or non-dumpable: xless makes itself so while it holds a secret), 0 finding(s).
A build container had a secret mount or variable.
**Result: FAIL** — see the containers above

_Note: the run continues with xless 0.10.6 (0.10.5 above). That failure was the kit: the variable is the swift image's SWIFT_SIGNING_KEY, a public key fingerprint (#175). Step 8 starts again; its state (`shipped.8.build`, `shipped.8.sign`, `build.8`) was removed by hand, as 0.10.6 does itself._

_2026-11-24T21:45Z_

```console
$ xless run --docker <kit>/app --to finalize
==> TestFlight: build number 29925945
==> build
xless: SDK: Xcode 27.2 (27B52), iphoneos27.2 SDK (24B8118) (recorded in /work/.xless/build/ios/sdk.json)
xless: compiler: Swift 6.4.2 (swift-6.4.2-RELEASE) from /opt/xless/toolchains/swift-6.4.2, Xcode's Swift 6.4.2
Building for production...
[Using on-disk description]
[3 / 3] M7Acceptance-App-product
[4 / 4] M7Acceptance-App-product
Build complete! (1.31 secs)
Planning...
Wrote to /work/xtool/M7Acceptance.app
xless: dSYMs: M7Acceptance.app.dSYM
xless: built with Swift 6.4.2 (swift-6.4.2-RELEASE) from /opt/xless/toolchains/swift-6.4.2, Xcode's Swift 6.4.2
xless: stamping from Xcode 27.2 (27B52), iphoneos27.2 SDK (24B8118)
/work/.xless/build/ios/app/M7Acceptance.app
==> assets
/work/.xless/build/ios/assets/M7Acceptance.app
==> finalize
/work/.xless/build/ios/final/M7Acceptance.app
==> TestFlight: stopped after finalize (--to), nothing delivered
(exit 0)
```
Containers of the build half:
container d3e3ecd5f173 image=xless:local-arm64 args=[ship --platform ios --to finalize] mounts=/work env=APPIMAGE_EXTRACT_AND_RUN,PATH,SWIFT_BRANCH,SWIFT_DETERMINISTIC_HASHING,SWIFT_PLATFORM,SWIFT_SIGNING_KEY,SWIFT_VERSION,SWIFT_WEBROOT,XDG_CONFIG_HOME,XLESS_BUILD_NUMBER,XLESS_SWIFT_TOOLCHAIN,XLESS_TOOLCHAIN_META secrets=<redacted> material=-
Processes watched during the run: 16 read, 12 unreadable (gone before they were read, or non-dumpable: xless makes itself so while it holds a secret), 0 finding(s).

```console
$ xless run --docker <kit>/app --from sign
==> TestFlight: build number 29925945
==> secrets from the secret store: sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY
==> sign
/work/.xless/build/ios/signed/M7Acceptance.app
==> package
/work/.xless/build/ios/out/M7Acceptance.ipa
==> upload
build 724ecde5-a485-45fc-ba62-6d59e2d819c9 VALID
TestFlight: build 29925945 (724ecde5-a485-45fc-ba62-6d59e2d819c9)
  group M7 Acceptance — available to 1 tester
  what to test (en-US): set
==> TestFlight delivery finished
(exit 0)
```
Containers of the sign half:
container 23dff06175c5 image=xless:local-arm64 args=[ship --platform ios --from sign] mounts=/secrets/store,/work env=APPIMAGE_EXTRACT_AND_RUN,ASC_ISSUER_ID_FILE,ASC_KEY_ID_FILE,ASC_KEY_P8_FILE,PATH,SWIFT_BRANCH,SWIFT_DETERMINISTIC_HASHING,SWIFT_PLATFORM,SWIFT_SIGNING_KEY,SWIFT_VERSION,SWIFT_WEBROOT,XDG_CONFIG_HOME,XLESS_BUILD_NUMBER,XLESS_DIST_KEY_FILE,XLESS_SWIFT_TOOLCHAIN,XLESS_TOOLCHAIN_META secrets=<redacted> material=-
Processes watched during the run: 225 read, 434 unreadable (gone before they were read, or non-dumpable: xless makes itself so while it holds a secret), 0 finding(s).
**Result: PASS** — build 29925945: the build container had no secret mount or variable; only the signing container read the store

### Cleanup
Cleanup of 2026-11-24T23:03Z:

```console
$ xless auth login --keep 30m
signed in as <redacted>
   TEAM ID     NAME        TYPE
*  <redacted>  <redacted>  Individual
kept the session in the kernel keyring for 30 min (until 2026-11-24T23:33:47Z); `xless auth logout` drops it
(exit 0)
```

```console
$ xless profiles delete UD2RM82A25 --team <redacted> --yes
deleted profile xless dev.xless.m7.a7000e1 IOS_APP_STORE (UD2RM82A25)
(exit 0)
```

```console
$ xless certs revoke RZ7BAWUF5K --team <redacted> --yes
revoked certificate RZ7BAWUF5K
the secret store still holds its private key as XLESS_DIST_KEY@<redacted>: remove it with `xless secrets rm XLESS_DIST_KEY@<redacted>`
(exit 0)
```

```console
$ xless keys revoke FV9CR85HW2 --team <redacted> --yes
revoked auth key FV9CR85HW2
removed XLESS_APNS_KEY@<redacted> from the secret store
(exit 0)
```

```console
$ xless auth api-key revoke 2NPPFUZ7VU --team <redacted> --yes
revoked API key 2NPPFUZ7VU
removed ASC_KEY_P8@<redacted> from the secret store
(exit 0)
```

```console
$ xless secrets list
NAME                       KIND         TEAM        KEY ID  ISSUER ID  CERTIFICATE  TYPE          ROLE  SERVICES  CREATED     EXPIRES
XLESS_DIST_KEY@<redacted>  signing-key  <redacted>  -       -          RZ7BAWUF5K   DISTRIBUTION  -     -         2026-11-24  2027-11-24
(exit 0)
```

```console
$ xless auth logout
forgot the kept Apple ID session
(exit 0)
```
Left in place (Apple has no API to delete them): the app record of dev.xless.m7.a7000e1 and its bundle ID. _Corrected by hand: the kit also named the TestFlight group and the builds, but the group was deleted and the three builds expired before this cleanup._
<!-- acceptance-m7:record:end -->
