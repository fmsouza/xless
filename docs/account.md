# Your Apple account from the terminal, by task

xless can set up and run everything an app needs on your Apple developer account and in App Store Connect: API
keys, bundle IDs and capabilities, certificates and their private keys, profiles, app groups and iCloud containers,
push notification keys, the app record, the App Store listing with its screenshots, App Privacy, pricing, TestFlight,
users, the review submission and the release. This page goes through it by task. Every command, option and JSON shape
is in the reference, [apple-account.md](apple-account.md); what xless keeps, where, and what it sends to which host is
in [security.md](security.md).

> **Status.** These commands are tested against recorded Apple answers, not yet end to end on a real Apple account:
> that acceptance is [#105](https://github.com/fmsouza/xless/issues/105). The parts that use the Apple ID web session
> (marked *web session* below) rely on Apple's undocumented web interfaces and are the most likely to need a fix
> once tried for real. If something fails, the error says which interface it was and which page to use in a browser
> meanwhile; please report it.

## Before you start

You need:

- an **Apple Developer Program** membership, and an Apple ID that is its **Account Holder**, or an **Admin** the
  Account Holder allowed to generate API keys, with two-factor authentication by code (hardware security keys are not
  supported);
- xless installed on a Linux machine ([README](../README.md)).

A few things only a person can do, in a browser, and xless never does for you:

| Once | Where |
|---|---|
| Enrol in the Developer Program, and renew it | <https://developer.apple.com/programs/> |
| Accept Apple's agreements (the Program License Agreement, the Paid Apps agreement for a paid app or in-app purchases), tax and banking | [developer.apple.com/account](https://developer.apple.com/account), [App Store Connect > Business](https://appstoreconnect.apple.com/agreements). When terms wait, xless stops and names the page. |
| Request access to the App Store Connect API (the Account Holder, the first time) | App Store Connect > Users and Access > Integrations |
| Create Developer ID Installer certificates (not in the API) | [Certificates](https://developer.apple.com/account/resources/certificates) |
| Remove devices once a membership year renews (Apple never deletes one otherwise) | [Devices](https://developer.apple.com/account/resources/devices/list) |
| Assign an Apple Pay merchant ID to a bundle ID | [Identifiers](https://developer.apple.com/account/resources/identifiers/list) |

## Your first app, from zero

`xless provision` does the account's part in one go, from what the project already declares: `xless.yml` (or an
overlay for Tauri, Cargo and React Native apps) and the `appstore/` listing next to it.

**1. A secret store and an API key.** Everything xless creates for you goes into the encrypted store, so make it
first. The first API key can only be made with your Apple ID (*web session*):

```sh
xless secrets init                          # asks a new passphrase, twice; it cannot be recovered
xless auth login --keep 30m                 # sign in once (Apple ID, password, the two-factor code); lists your teams
xless team use ABCDE12345                   # your team ID, from that list
xless auth api-key create --role ADMIN      # the key goes straight into the store, checked, never on disk in clear
```

`--keep 30m` keeps the session in the kernel keyring for the next commands of your login session (at most an hour;
`xless auth logout` drops it); without it each web-session command signs in again. `--role ADMIN` because provisioning (bundle IDs, certificates, profiles, devices)
and users need it; a key that only ships builds, edits the listing and releases can be `APP_MANAGER`, the default
([roles](apple-account.md#xless-auth-api-key)).

**2. The project.** In `xless.yml` (or the overlay), set `teamID` to that team and `bundleID` to the app's identifier
([xless-yml.md](xless-yml.md)). The entitlements you list there (push notifications, app groups, iCloud, Sign in with
Apple…) are what `provision` reads to decide the capabilities, groups, containers and keys.

**3. The listing, at least its name.** A new app record takes its name, primary locale and first version from
`appstore/`:

```text
appstore/
  app.yml          primaryLocale: en-US
                   version: "1.0"
                   sku: EXAMPLE1          (optional; default: the bundle ID)
  en-US/
    name.txt       Example
```

Add what you already have (the description, keywords, support and privacy URLs, screenshots, price, App Privacy
answers): [appstore-manifest.md](appstore-manifest.md) has every file and key. `xless store validate --draft` checks it
without contacting Apple. Without `appstore/`, `provision` leaves the app record, the listing, App Privacy and TestFlight
out, with a note; `xless apps create` makes the record by hand ([below](#an-app-record-without-provision)).

**4. Plan, then apply.**

```sh
xless provision plan                                  # what the account lacks; reads only
xless provision apply --company-name "Example Ltd"    # asks, then does it; --company-name for the team's first app
```

`plan` lists the steps by area (bundle IDs, capabilities, app groups, iCloud containers, certificates, keys,
profiles, the app record, the listing, App Privacy, TestFlight groups), marks the ones that need the web session, and
says what blocks it and what differs from the project without being changed (drift). `apply` runs them in that order
in one process: one passphrase, at most one Apple ID sign-in. A new signing key is generated into the store before
its certificate is requested; an APNs key is created and stored when an entitlement uses push notifications. It
never deletes or revokes anything; running it again does only what is left, so after a failure, fix the cause and run
it again. Details: [`xless provision`](apple-account.md#xless-provision).

**5. Build and ship.** Install the SDK once (`xless setup --xcode Xcode_27.xip`, [README](../README.md#set-up)), then:

```sh
xless secrets lock; xless auth logout   # see below
xless run .                             # build, sign, upload, deliver to the TestFlight groups of xless.yml
```

Before a native build, drop what is kept: `xless secrets lock` and `xless auth logout`. The build runs the project's
SwiftPM plugins and macros as you, in your login session, where they could read a remembered unlock or a kept Apple
ID session ([security.md](security.md#the-build-and-your-secrets)). The keys come from the store: one passphrase per run, nothing in a secrets file
([signing-and-testflight.md](signing-and-testflight.md#one-command-testflight)). For CI, export what it needs once
(`xless secrets export ASC_KEY_P8@ABCDE12345 --out key.p8`, and the same for `XLESS_DIST_KEY@…`), put the contents into
the CI's secret store, and delete the files ([CI](signing-and-testflight.md#continuous-integration)).

When the app is ready for the App Store, see [Release a version](#release-a-version).

### An app record without `provision`

```sh
xless apps create --bundle-id com.example.app --name "Example" --sku EXAMPLE1 --locale en-US   # web session
```

It reports an app that already exists instead of creating a second one, and offers to register the bundle ID when it
is not registered yet ([`xless apps`](apple-account.md#xless-apps)). The step-by-step version of everything
`provision` does is [bootstrap.md](bootstrap.md).

## An app that already exists

Pull its listing into `appstore/`, commit it, and `provision` takes it from there:

```sh
xless store pull --app com.example.app     # writes appstore/ from App Store Connect
xless store privacy pull --app com.example.app   # App Privacy too (web session)
xless provision plan                       # what is still missing for this project (often only signing)
```

Certificates made elsewhere have private keys xless does not have: `provision` makes a new key and certificate for
this machine, and leaves the others alone. To use a key you already have instead, import it before planning:
`xless secrets import XLESS_DIST_KEY@ABCDE12345 --file dist-key.pem --team-id ABCDE12345` ([secrets.md](secrets.md)).

## Add a device

Development and ad hoc builds run only on the devices their profile lists; App Store and TestFlight builds need none.

```sh
xless devices register "Ada's iPhone" 00008030-001A35E80C42802E     # registering twice registers once
xless profiles list --type ios-app-adhoc --bundle-id com.example.app
xless profiles delete 8U3T4X5YZA                                     # asks first
xless profiles create --type ios-app-adhoc --bundle-id com.example.app   # every enabled iPhone and iPad, every fitting certificate
```

A profile cannot be edited, and `xless profiles renew` keeps the devices it had, so a profile that should include the
new device is created again: delete it, then create it (the name is the same, `xless <bundle ID> IOS_APP_ADHOC`). Apple
allows 100 devices of each kind per membership year; `xless devices list` warns from 90
([`xless devices`](apple-account.md#xless-devices), [`xless profiles`](apple-account.md#xless-profiles)).

## Rotate a certificate

Certificates expire after a year or more; `xless provision plan` notes one that expires within 30 days, and
`xless certs list --expiring 30` lists them with the store entry that holds each private key.

```sh
xless certs list --type distribution --expiring 30
xless secrets export XLESS_DIST_KEY@ABCDE12345 --out old-dist.pem   # a copy, in case the next steps fail
xless secrets rm XLESS_DIST_KEY@ABCDE12345          # forget the old key in the store; its certificate stays valid
xless certs create --type distribution              # a new key into the store, then its certificate
rm old-dist.pem                                     # once the new certificate exists
xless run .                                         # sign replaces its profile with one that holds the new certificate
xless certs revoke 8U3T4X5YZA                       # optional, once nothing uses the old one; asks first
```

`certs create` refuses while the store still holds the key `sign` would read for the team, hence the `secrets rm`
first; the exported copy is in clear, so delete it as soon as the new certificate exists (if `certs create` fails, put
it back with `xless secrets import XLESS_DIST_KEY@ABCDE12345 --file old-dist.pem --team-id ABCDE12345`, which offers to
delete the file). `sign` finds the new certificate by its key and, when its own profile (`xless <bundle ID> IOS_APP_STORE`) does
not hold it, creates one that does. Other profiles keep the certificates they were made with (`xless profiles renew`
too): delete them and create them again, as for a [new device](#add-a-device). For a certificate that already expired
or was revoked, `xless provision apply` is enough: it requests a new certificate for the key already in the store.

- **Apple Distribution:** apps already on the App Store keep working when its certificate is revoked; ad hoc builds
  signed with it stop installing.
- **Developer ID:** do not revoke a Developer ID Application certificate you shipped with: every app signed with it
  stops opening on users' Macs. Let it expire; Apple allows five at a time, so the new one can be created alongside.
  Creating them needs the Account Holder.
- **CI:** export the new key (`xless secrets export XLESS_DIST_KEY@ABCDE12345 --out key.pem`), replace the CI's
  `XLESS_DIST_KEY` secret with its contents, and delete the file.

## Push notifications and other keys

An entitlement that uses push notifications makes `provision` create an APNs key into the store, unless this machine
already has one for the team (one key serves every app; Apple allows two). By hand, and for Sign in with Apple,
DeviceCheck and MusicKit (*web session*):

```sh
xless keys create --service apns                    # stored as XLESS_APNS_KEY@<TEAM_ID>, its .p8 never on disk
xless keys list
xless secrets export XLESS_APNS_KEY@ABCDE12345 --out AuthKey.p8   # for your push server; delete it afterwards
```

[`xless keys`](apple-account.md#xless-keys). App groups and iCloud containers named by the entitlements are created
and assigned by `provision`; by hand, [`xless app-groups` and `xless icloud-containers`](apple-account.md#xless-app-groups-and-xless-icloud-containers).

## Invite a tester

**Internal testers** (up to 100, every build at once, no review) must be App Store Connect users of the team. Invite
them with an Admin key, then add them to a group once they accepted Apple's email:

```sh
xless users invite ada@example.com --first-name Ada --last-name Lovelace --role developer --app com.example.app
xless users invitations list                       # until Ada accepts
xless testflight testers add ada@example.com --group Internal --app com.example.app
```

Or list them in `xless.yml`, and every `xless ship` adds the missing ones to its groups:

```yaml
testflight:
  groups: [Internal]
  testers: [ada@example.com]
```

**External testers** can be anyone; Apple emails them once beta app review approved the build:

```sh
xless testflight groups create "Public Beta" --external --app com.example.app
xless testflight testers add grace@example.com --group "Public Beta" --app com.example.app
xless testflight builds add 1.0+42 --group "Public Beta" --app com.example.app
xless testflight beta-review submit 1.0+42 --app com.example.app
xless testflight public-link enable "Public Beta" --app com.example.app --limit 500   # or a link to share
```

`testflight.external` in `xless.yml` does the same at every ship, with the beta information and review contact
([xless-yml.md](xless-yml.md#testflight), [`xless users`](apple-account.md#xless-users),
[`xless testflight`](apple-account.md#xless-testflight)).

## Release a version

The listing lives in `appstore/`: change it there, review it like code, push it.

```sh
xless store validate                          # what a submission needs, offline
xless store push --dry-run                    # what would change on App Store Connect
xless store push                              # sends only what differs; asks before deleting anything
xless run .                                   # build and upload 1.1 (42)
xless builds wait 1.1+42 --app com.example.app
xless release submit --build 1.1+42 --release manual --dry-run   # the pre-flight: every problem at once
xless release submit --build 1.1+42 --release manual
xless release status                          # waiting for review, in review, approved…
xless release publish                         # once approved, when you choose
```

`store push` creates the App Store version from app.yml's `version` when it does not exist yet (`xless release create
1.1` does it on its own). `release submit` checks first, and sends nothing when something is missing: the listing in
every locale, screenshots, App Privacy published, a price and territories, the build valid with its export compliance
answered, the App Review contact. Run it again after fixing: it resumes where it stopped. `--release auto` releases on
approval, a date (`2026-12-01`) not before then, and `--phased` spreads an update over seven days (`xless release phased
pause|resume|complete`). App Review's reasons for a rejection are not in the API: Apple emails them
([`xless release`](apple-account.md#xless-release)).

## Which credential each command uses

| Credential | Commands |
|---|---|
| App Store Connect API key (from the environment, a `_FILE` variable or the store) | `devices`, `bundle-ids`, `merchant-ids`, `certs`, `profiles`, `apps list/show/update/price-points`, `store pull/push` (but App Privacy), `builds`, `users`, `testflight`, `release`, `provision plan` (mostly), `api`, and the pipeline (`sign`, `upload`, TestFlight delivery) |
| Apple ID web session (*web session*) | `auth login`, `team list`, `auth api-key create/list/revoke`, `apps create`, `store privacy`, `app-groups`, `icloud-containers`, `keys`, and the steps of `provision apply` that need them |
| Neither | `auth status`, `auth logout`, `team use`, `secrets`, `store validate` |

Once an app exists, only new apps, new keys and App Privacy answers need the Apple ID: the rest of a release runs on
the API key, including in CI. Why, and what each sends where: [security.md](security.md#the-apple-id-web-session).

## Signing out and cleaning up

```sh
xless auth logout            # forget the kept Apple ID session
xless secrets lock           # forget a remembered store unlock
xless auth status            # which credentials resolve now, from where; reads no secret
```

Revoking what you no longer use and removing everything xless keeps: [security.md](security.md#wiping-everything).
