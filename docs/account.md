# Your Apple account from the terminal, by task

xless can set up and run everything an app needs on your Apple developer account and in App Store Connect: API
keys, bundle IDs and capabilities, certificates and their private keys, profiles, app groups and iCloud containers,
push notification keys, the app record, the App Store listing with its screenshots, App Privacy, pricing, TestFlight,
users, the review submission and the release. This page has what you need first, and the account's tasks; a whole first app is in
[get-started.md](get-started.md). Every command, option and JSON shape is in the reference, [apple-account.md](apple-account.md); what xless keeps, where, and what it sends to which host is
in [security.md](security.md).

> **Status.** Most of this was run once on a real Apple account, for one new app, from its first API key to a build on a tester's
> device and the submission to App Review ([the record](acceptance-m7.md#record), 2026-11-24). The approval and `release publish`
> were not ([#181](https://github.com/fmsouza/xless/issues/181)); what that run did not use is tested against recorded Apple
> answers. The parts that use the Apple ID web session (marked *web session* below) rely on Apple's undocumented web interfaces and
> are the most likely to need a fix when Apple changes them. If something fails, the error says which interface it was and which
> page to use in a browser meanwhile; please report it.

## Before you start

You need:

- an **Apple Developer Program** membership, and an Apple ID that is its **Account Holder**, or an **Admin** the
  Account Holder allowed to generate API keys, with two-factor authentication by code or a USB security key
  ([apple-account.md](apple-account.md#signing-in-with-a-security-key));
- xless [installed](../README.md#install), on Linux, macOS or Windows.

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

[Get started: I have nothing yet](get-started.md#i-have-nothing-yet) goes from here to the App Store: the secret store, the API
key, the project, `xless provision`, the first build and the submission.

### An app record without `provision`

```sh
xless apps create --bundle-id com.example.app --name "Example" --sku EXAMPLE1 --locale en-US   # web session
```

It reports an app that already exists instead of creating a second one, and offers to register the bundle ID when it
is not registered yet ([`xless apps`](apple-account.md#xless-apps)). The step-by-step version of everything
`provision` does is [bootstrap.md](bootstrap.md).

## An app that already exists

[Get started: I have an app on App Store Connect](get-started.md#i-have-an-app-on-app-store-connect).

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

[testflight.md](testflight.md): internal testers, external testers, a public link.

## Release a version

[release.md](release.md): the listing, the pre-flight, App Review, publishing.

## Which credential each command uses

| Credential | Commands |
|---|---|
| App Store Connect API key (from the environment, a `_FILE` variable or the store) | `devices`, `bundle-ids`, `merchant-ids`, `certs`, `profiles`, `apps list/show/update/price-points`, `store pull/push` (but App Privacy), `builds`, `users`, `testflight`, `release`, `provision plan` (mostly), `api`, and the pipeline (`sign`, `upload`, TestFlight delivery) |
| Apple ID web session (*web session*) | `auth login`, `team list`, `auth api-key create/list/revoke`, `apps create`, `store privacy`, `app-groups`, `icloud-containers`, `keys`, and the steps of `provision apply` that need them |
| Neither | `auth status`, `auth logout`, `unlock`, `lock`, `session`, `team use`, `secrets`, `store validate` |

**Scripts:** [automate.md](automate.md), and [ci.md](ci.md) for CI.

Once an app exists, only new apps, new keys and App Privacy answers need the Apple ID: the rest of a release runs on
the API key, including in CI. Why, and what each sends where: [security.md](security.md#the-apple-id-web-session).

## Signing out and cleaning up

```sh
xless lock                   # forget everything held: the store's unlock and the kept Apple ID session
xless auth status            # which credentials resolve now, from where, and what is held; reads no secret
```

Revoking what you no longer use and removing everything xless keeps: [security.md](security.md#wiping-everything).
