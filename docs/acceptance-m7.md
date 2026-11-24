# Milestone 7 acceptance — an Apple account from the terminal

Scope: [#105](https://github.com/fmsouza/xless/issues/105), the definition of done of milestone 7
([#80](https://github.com/fmsouza/xless/issues/80)): a new app goes from zero to the App Store from a Linux terminal,
without opening developer.apple.com or appstoreconnect.apple.com. It needs a real Apple Developer Program membership,
so it is run by the maintainer with the kit below; this page explains how, and the kit writes the record at the end
of it. Until then the record says it has not been run.

## The kit

- [`samples/m7-acceptance/`](../samples/m7-acceptance/README.md): a one-screen SwiftUI iOS app that needs a capability
  (push notifications), with an `appstore/` listing in two languages (en-US, pt-BR), screenshots for the iPhone 6.9"
  and iPad 13" displays, App Privacy ("Data Not Collected"), a free price and every territory. Its bundle ID, team, App
  Store name, SKU and review contact are placeholders the script fills in its own copy.
- [`scripts/acceptance-m7.sh`](../scripts/acceptance-m7.sh): walks #105's checklist in order, records every command and
  its output into this page (between the record markers below, redacted), and is resumable: a step that finished is
  skipped when the script runs again, one that failed starts again.
- `xless live-check` (hidden; `XLESS_LIVE_APPLE=1`): the read-only contract check. It reads every list and get
  endpoint xless uses with xless's own readers and reports each answer, so a response shape Apple changed, or one xless
  guessed wrong, shows up before anything is written. Its connections refuse to send anything but a read.
- [research/m7-live-checklist.md](research/m7-live-checklist.md): every question the M7 pull requests left open, with
  the step (or the command) that answers it.

## Before you start

- A Linux machine (x86_64 or arm64) that has never run xless: no `~/.config/xless`, no secret store, no key file. A
  fresh VM is best (step 1 checks; it asks before going on if the machine is not fresh).
- xless installed from the release candidate ([README](../README.md#install)), the native toolchain set up for step 5
  (`xless setup --xcode <Xcode.xip>`, [README](../README.md#set-up)) and the images for step 8 (`xless setup --docker --xcode <Xcode.xip>`).
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

scripts/acceptance-m7.sh --contract   # first: the read-only contract check (signs in, keeps the session 30 minutes)
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
| 0 | `XLESS_LIVE_APPLE=1 xless live-check`: at the start (the web session), after step 2 (the new API key) and after step 4 (the app). A `FAIL` stops the run before anything more is written. | The Apple ID sign-in (xless asks on the terminal) |
| 1 | `xless --version`; no `~/.config/xless`, no store, no key file under `$HOME` | Only if the machine is not fresh |
| 2 | `xless secrets init`, `xless auth login --keep 30m`, `xless team use`, `xless auth api-key create --role ADMIN`, `xless auth status`, `xless auth logout` | The store's passphrase; the sign-in |
| 3 | The sample copied and filled in; its bundle ID checked unregistered; `xless store validate` | — |
| 4 | `xless provision plan`, `xless provision apply --yes`, again, then `xless provision plan --json` must have no step | The sign-in (app record, APNs key, App Privacy use the web session) |
| 5 | `xless run <app>` with nothing in the environment (the store only), its processes watched; `xless testflight testers add` | Installing the build from TestFlight on a device |
| 6 | `xless release submit --release manual` (`--dry-run` first), `xless release status` until *Pending Developer Release*, `xless release publish` | Waiting for App Review (days): the script stops with exit code 75; run it again later, or with `--wait` |
| 7 | Key files under `$HOME`; `strings` on the store; the environments of steps 5 and 8; `coredumpctl`; the `--verbose` traces of a sign-in, `team list`, `keys list` and `apps list`, scanned (only the findings are recorded); `xless secrets lock`, `xless auth logout`, then the kernel keyring | The sign-in of the traced login |
| 8 | `xless run --docker <app> --to finalize`, then `--from sign`, every container inspected (mounts, variable names) | — |
| 9 | — | The answer: was a portal opened in a browser? |

When Apple rejects the version, step 6 stops with exit code 76: read the reason in Apple's email (not in App Store
Connect's web page: that would fail step 9), write it and the fix in this page's record, fix it, and run the script
again: it resubmits. When `live-check` or any step finds that Apple disagrees with xless, fix xless (an issue per
finding, linked from [research/m7-live-checklist.md](research/m7-live-checklist.md)), install the fixed build, and run
the script again.

## What is recorded, and what is not

Every command and its output, through `xless secrets redact` (the rules of `--verbose` traces: keys, tokens, cookies,
session headers, secret fields, presigned URLs) and with the run's personal values hidden: the Apple ID, the team ID,
the tester, the review contact and the device. Paths show the state directory as `<kit>` and the home directory as
`~`. The `--verbose` traces of step 7 are scanned as they come and never written; only their line counts and findings
are. The watchers of steps 5 and 8 record variable names and process names, never a value. Read the record before
committing it all the same.

Once every row is PASS, commit this page with the record, link it from [README.md](README.md#acceptance-records), and
close #105.

<!-- acceptance-m7:record:begin -->
## Record

Not run yet: the maintainer runs `scripts/acceptance-m7.sh` on a real account (see above); it replaces this section.
<!-- acceptance-m7:record:end -->
