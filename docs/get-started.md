# Get started

Find the line that is you, and follow its section to the end.

| | |
|---|---|
| [I have nothing yet](#i-have-nothing-yet) | from an empty account to an app on the App Store |
| [I have an app on App Store Connect](#i-have-an-app-on-app-store-connect) | its listing in files, and the next version from the terminal |
| [I only want to build](#i-only-want-to-build) | an app on your machine, no Apple account |
| [I only want to automate the account](#i-only-want-to-automate-the-account) | listings, testers, releases and keys, no build |
| [CI](#ci) | the same without anybody to ask |

What works on your system: [systems.md](systems.md). What xless keeps and sends, and what it protects from whom:
[security.md](security.md).

## I have nothing yet

You need an Apple Developer Program membership, and a few things that only a person can do in a browser:
[before you start](account.md#before-you-start). Then [install xless](../README.md#install). Building needs a Mac, Linux, or
[WSL 2](build.md#in-wsl-2); the rest runs on Windows too.

`xless provision` does the account's part in one go, from what the project already declares: `xless.yml` (or an
overlay for Tauri, Cargo and React Native apps) and the `appstore/` listing next to it.

### 1. A secret store and an API key

Everything xless creates for you goes into the encrypted store, so make it
first. The first API key can only be made with your Apple ID (*web session*):

```sh
xless secrets init                          # asks a new passphrase, twice; it cannot be recovered
xless auth login --keep                     # sign in once (Apple ID, password, the two-factor code); lists your teams
xless team use ABCDE12345                   # your team ID, from that list
xless auth api-key create --role ADMIN      # the key goes straight into the store, checked, never on disk in clear
```

`--keep` keeps the session in memory, nothing of it on disk, for the next commands of this terminal (8 hours, at most 2
without use; `--keep 30m` for less, `xless auth logout` drops it) and asks whether to keep the store unlocked too, once
its passphrase is typed. With a yes, everything below asks each secret **once**: the passphrase at `api-key create`, and
no more sign-in ([how it is kept, and for whom](secrets.md#staying-unlocked)). Without it each command asks for itself,
once. (On Windows nothing is kept: leave `--keep` out.) `--role ADMIN` because provisioning (bundle IDs, certificates,
profiles, devices) and users need it; a key that only ships builds, edits the listing and releases can be `APP_MANAGER`,
the default ([roles](apple-account.md#xless-auth-api-key)).

### 2. The project

A Swift app is a Swift package with an `xless.yml`; a Tauri, Cargo or React Native app has an overlay
([tauri.md](tauri.md), [cargo.md](cargo.md), [react-native.md](react-native.md)). With no app yet, start from the sample that
xless installs:

```sh
cp -r ~/.local/share/xless/samples/HelloShip ~/MyApp && cd ~/MyApp
```

In `xless.yml` (or the overlay), set `teamID` to that team and `bundleID` to the app's identifier
([xless-yml.md](xless-yml.md)). The entitlements you list there (push notifications, app groups, iCloud, Sign in with
Apple…) are what `provision` reads to decide the capabilities, groups, containers and keys. An iOS app that embeds
app extensions declares each one, with its bundle ID and entitlements, under `platforms.ios.extensions`
([xless-yml.md](xless-yml.md#app-extensions)); a React Native app's come from its last build.

For TestFlight, name a group and its testers; they must be App Store Connect users of the team, as you are
([testflight.md](testflight.md)):

```yaml
testflight:
  groups: [Internal]
  testers: [ada@example.com]
```

### 3. The listing, at least its name

A new app record takes its name, primary locale and first version from
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
answers): [appstore-manifest.md](appstore-manifest.md) has every file and key, and
[the acceptance sample](../samples/m7-acceptance/appstore) is a whole listing. `xless store validate --draft` checks it
without contacting Apple. Without `appstore/`, `provision` leaves the app record, the listing, App Privacy and TestFlight
out, with a note; `xless apps create` makes the record by hand ([how](account.md#an-app-record-without-provision)).

### 4. Plan, then apply

```sh
xless provision plan                                  # what the account lacks; reads only
xless provision apply --company-name "Example Ltd"    # asks, then does it; --company-name for the team's first app
```

(With the session still kept, `apply` asks nothing but to go ahead.) `plan` lists the steps by area (bundle IDs,
capabilities, app groups, iCloud containers, certificates, keys, profiles, the app record, the listing, App Privacy,
TestFlight groups), marks the ones that need the web session, and says what blocks it and what differs from the project
without being changed (drift). `apply` runs them in that order in one process: one passphrase, at most one Apple ID
sign-in, both before the first step. A new signing key is generated into the store before its certificate is requested;
an APNs key is created and stored when an entitlement uses push notifications. It never deletes or revokes anything;
running it again does only what is left, so after a failure, fix the cause and run it again. Details: [`xless
provision`](apple-account.md#xless-provision).

The same without `provision`, one command at a time: [bootstrap.md](bootstrap.md).

### 5. Build and ship

Get the machine ready once: [on a Mac](build.md#on-a-mac) Xcode, opened once; [on Linux](build.md#on-linux) `xless
setup`; [Docker](build.md#in-docker) for an overlay. The build runs the project's SwiftPM plugins and macros as you, but
in a session and an empty keyring of their own and without the secret variables: a held unlock or a kept Apple ID
session is out of their reach ([security.md](security.md#the-build-and-your-secrets)); in WSL read [In
WSL](security.md#in-wsl) first. Then:

```sh
xless run .                             # build, sign, upload, deliver to the TestFlight groups of xless.yml
```

The keys come from the store: one passphrase per run, nothing in a secrets file
([signing-and-testflight.md](signing-and-testflight.md#one-command-testflight), which has the command for an overlay too).
`sign` prints what it makes on the account (a bundle ID, a capability, a profile) before it makes it, and after `provision
apply` that is nothing; `--no-provisioning-updates` refuses instead
([what `sign` changes](signing-and-testflight.md#what-sign-changes-on-the-account)). At its end the run prints the
`xless release submit` command of the build it uploaded.

### 6. The App Store

Try the build in TestFlight. Then complete the listing and send that build:

```sh
xless store push                        # the listing and the App Store version of appstore/
xless release submit --release manual --dry-run   # the pre-flight: every problem at once; names the build
xless release submit --release manual             # to App Review
xless release status                              # waiting for review, in review, approved…
xless release publish                             # once approved, when you choose
```

Nothing is sent to App Review but by `release submit`: not by `run`, `ship` or `provision`. Which build it takes, and the other ways to
release: [release.md](release.md).

## I have an app on App Store Connect

1. [Install xless](../README.md#install), and read [before you start](account.md#before-you-start).
2. Make the store and give xless an API key: [a new one](#1-a-secret-store-and-an-api-key), or a `.p8` you already have, checked
   against App Store Connect first:

   ```sh
   xless secrets init                      # asks a new passphrase, twice; it cannot be recovered
   xless auth api-key import --p8-file AuthKey_<KEY_ID>.p8 --issuer-id <ISSUER_ID>
   ```

3. In the project's directory, pull the listing into `appstore/` and commit it:

   ```sh
   xless store pull --app com.example.app           # writes appstore/ from App Store Connect
   xless store privacy pull --app com.example.app   # App Privacy too (web session)
   ```

   From now on you change the listing there, and `xless store push` sends what differs
   ([pulling and pushing listings](automate.md#pulling-and-pushing-listings)). To only manage the app, stop here and go on
   with [testers](testflight.md) and [releases](release.md).
4. To build it with xless, the app needs an [`xless.yml`](xless-yml.md) or an overlay ([the project](#2-the-project)), and build
   numbers above those that Apple has of it ([how they are chosen](signing-and-testflight.md#build-numbers)).
5. See what is missing for signing, then make it:

   ```sh
   xless provision plan       # what is still missing for this project (often only signing)
   xless provision apply      # asks, then does it
   ```

   Certificates made elsewhere have private keys xless does not have: `provision` makes a new key and certificate for
   this machine, and leaves the others alone. To use a key you already have instead, import it before planning:
   `xless secrets import XLESS_DIST_KEY@ABCDE12345 --file dist-key.pem --team-id ABCDE12345` ([secrets.md](secrets.md)).
6. [Build and ship](#5-build-and-ship), then [release the version](release.md).

## I only want to build

1. [Install xless](../README.md#install).
2. Follow [build.md](build.md): [on a Mac](build.md#on-a-mac), [on Linux](build.md#on-linux), or [in Docker](build.md#in-docker)
   for a React Native, Expo, Tauri or Cargo app.
3. The project: a Swift package with an [`xless.yml`](xless-yml.md), or an overlay. `teamID` may stay a placeholder.

It ends with an unsigned `.app`, and needs no Apple account.

## I only want to automate the account

This runs on every system, Windows included, and needs no Xcode.

1. [Install xless](../README.md#install), and read [before you start](account.md#before-you-start).
2. Make the store and an API key: [step 1 above](#1-a-secret-store-and-an-api-key). For listings and releases alone, the default role
   (leave out `--role ADMIN`) is enough ([roles](apple-account.md#xless-auth-api-key)).
3. Look: `xless apps list`, `xless builds list --app com.example.app`, `xless release status --app com.example.app`.
4. Go on by task: [account.md](account.md), [testflight.md](testflight.md), [release.md](release.md).
5. Script it: [automate.md](automate.md) has several apps, checking, listings, `--json` and runs that nobody answers.

## CI

[ci.md](ci.md): which secrets a job needs, how to export them from your store once, the flags that make a run fail
instead of asking, and an example workflow.
