# xless.yml reference

`xless.yml` lives in the project directory next to `Package.swift` (as a file: `xless run` in containers refuses a link). Example (the HelloShip sample):

```yaml
bundleID: com.example.helloship
teamID: ABCDE12345
version: 1.0.0
build: 1
platforms:
  ios:   { minimumOS: "17.0", product: HelloShip, entitlements: ios.entitlements }
  macos: { minimumOS: "14.0", product: HelloShip, entitlements: macos.entitlements, distribution: developer-id }
assets: Resources/Assets.xcassets
privacyManifest: Resources/PrivacyInfo.xcprivacy
infoPlist: Resources/Info.plist
```

## Top-level keys

| Key | Type | Required | Notes |
|---|---|---|---|
| `bundleID` | string | yes | Reverse-DNS, e.g. `com.example.app`: dot-separated segments of letters, digits and `-`, at least two segments. |
| `teamID` | string | yes | Exactly 10 characters, `A-Z` and `0-9`. From `xless team list` (or developer.apple.com → Membership). `xless provision` and a project's run use this team's API key and store entries. `sign` fails if it differs from the team of the App Store Connect key (read from the provisioning profile). |
| `version` | string | yes | Marketing version (`CFBundleShortVersionString`): 1 to 3 dot-separated integers. Quote it if YAML would read it as a number. |
| `build` | string or integer | yes | Build number (`CFBundleVersion`): 1 to 3 dot-separated integers. Overridden by `--build-number` or `XLESS_BUILD_NUMBER`. Each upload of a given `version` needs a higher one than every earlier upload, from any machine (see [build numbers](signing-and-testflight.md#build-numbers)). |
| `platforms` | map | yes | At least one of `ios`, `macos`. Any other key is an error. |
| `assets` | path | required for iOS (app-store) | Asset catalog (`.xcassets`), relative to the project. Compiled to `Assets.car` on iOS and to an `.icns` icon on macOS (macOS has no `Assets.car`). App Store builds fail at `assets` unless it contains an `.appiconset`. |
| `privacyManifest` | path | required for iOS (app-store) | `PrivacyInfo.xcprivacy`, copied into the bundle; `finalize` fails for App Store builds if it is missing. |
| `infoPlist` | path | no | Extra Info.plist keys merged into the generated one (usage descriptions, orientations, export-compliance keys). |
| `usesNonExemptEncryption` | boolean | no | Stamps `ITSAppUsesNonExemptEncryption` (export compliance) into the Info.plist. `finalize` refuses iOS App Store builds whose Info.plist has no such key (they would stall at "Missing Compliance" in TestFlight). Set it here, or put the key in the `infoPlist` file. If both define it with different values, `finalize` refuses. `false` means the app uses no encryption beyond what Apple's OS provides or only exempt encryption. `true` is valid, but App Store Connect then needs an export compliance answer for each build before testers can install it. A non-boolean value in the Info.plist is refused. |
| `xcode` | string | no | The Xcode whose SDK must build the app, e.g. `"26.2"` (Ruling R8; see [react-native.md](react-native.md#pinning-the-xcode-sdk)). `build` refuses an image whose SDK comes from another Xcode, the app compiles with an open-source Swift release matching that Xcode's Swift, and `xless run --docker` runs in the image `xless setup --docker --xcode …` made from it (`xless:local-<arch>-xcode<version>`). On a Mac, natively, it chooses among the installed Xcodes ([native-install.md](native-install.md#on-a-mac)). Default: the installed SDK (on a Mac the selected Xcode); with `--docker`, the image of the newest Xcode there is one of. |
| `image` | string | no | Only with `--docker`: an image of your own for the build ([images.md](images.md#an-image-of-your-own)), already built on this machine. The run is then two containers: the build's has no secret, and signing and the upload run in the xless image. `XLESS_IMAGE` wins over it. Default: the xless image. |
| `provisioningUpdates` | boolean | no | `false`: `sign` changes nothing on the Apple account, and fails with exit 24 and the list when it would have to ([signing-and-testflight.md](signing-and-testflight.md#what-sign-changes-on-the-account)). Default `true`; the key without a value is refused. |
| `testflight` | map | no | Deliver uploaded builds to TestFlight groups. See [`testflight`](#testflight). |
| `launchStoryboard` | path | no | iOS only (ignored for macOS). A launch-screen `.storyboard` (must end in `.storyboard`), relative to the project. See [Launch storyboard](#launch-storyboard). |

## `platforms.<ios|macos>` keys

| Key | Type | Required | Notes |
|---|---|---|---|
| `minimumOS` | string | yes | Dotted version such as `"17.0"`. For iOS it must be 13.0 or later (Apple's rule, checked at `finalize`). Keep it equal to the `platforms:` in `Package.swift`. |
| `product` | string | yes | The library product in `Package.swift` that holds the app (e.g. `.library(name: "HelloShip", targets: ["HelloShip"])`). xtool (iOS) and xless (macOS, and iOS on a Mac) link it into a generated executable named after it. Its packages are built in the versions that the project's `Package.resolved` names. |
| `entitlements` | path | no | Entitlements plist, relative to the project. Managed and security-sensitive entitlements are gated against the provisioning profile. `$(AppIdentifierPrefix)` and `$(TeamIdentifierPrefix)` become `<teamID>.`; on iOS the values of `keychain-access-groups`, `com.apple.security.application-groups` and `com.apple.developer.associated-domains` must be ones the profile allows, and `aps-environment` takes the profile's value, as Xcode signs. |
| `distribution` | `app-store` or `developer-id` | no | Defaults: iOS `app-store`, macOS `developer-id`. |
| `bundleID` | string | no | Overrides the top-level `bundleID` for this platform. Same format rule. |
| `extensions` | list | no | iOS only. The app extensions the app embeds: see [App extensions](#app-extensions). |

## App extensions

An iOS app that embeds app extensions declares each one under `platforms.ios.extensions`. The `build` stage does not
build or embed app extensions itself (xtool, Tauri and cargo builds make the app alone): declare only extensions the
built `.app` holds, put there by your own tooling before `sign` (a React Native app's come from its Xcode project
instead, [react-native.md](react-native.md)). The declaration lets the account be prepared before the build and signs
each extension with its own entitlements:

```yaml
platforms:
  ios:
    minimumOS: "17.0"
    product: Example
    entitlements: App.entitlements
    extensions:
      - path: PlugIns/Widget.appex          # where it is in the app (PlugIns/ or Extensions/)
        bundleID: com.example.app.widget    # under the app's bundle ID
        entitlements: Widget.entitlements   # optional, relative to the project like the app's
```

[`xless provision`](apple-account.md#xless-provision) registers each extension's bundle ID, enables the capabilities its
entitlements need, creates and assigns its app groups and iCloud containers and makes its profile, before the first
build. `sign` signs each extension with its own profile and its declared entitlements (prefixes expanded, as for the
app); with extensions declared, the built app must hold exactly those (path and `CFBundleIdentifier`), else `[sign]`
refuses before App Store Connect is called: declaring one the build does not embed stops every `ship` at `sign`. Without `extensions`, an extension found in the app is signed with its own
profile and no entitlements, as before. A path that is not `PlugIns/<Name>.appex` or `Extensions/<Name>.appex`, a
bundle ID outside the app's, a duplicate, or `extensions` under `macos` is a `[config]` error. The same list goes under
`ios:` in a [Tauri](tauri.md) or [cargo](cargo.md) overlay.

## `testflight`

```yaml
testflight:
  groups: ["Internal"]
  whatToTest: "Launch screen built on Linux"
  testers: [ada@example.com, {email: grace@example.com, firstName: Grace, lastName: Hopper}]
  external:
    groups: ["Public Beta"]
    testers: [beta-tester@example.com]
    info:
      description: "A new editor; tell us what breaks."
      feedbackEmail: beta@example.com
      privacyPolicyUrl: https://example.com/privacy
    review:
      contact: {firstName: Ada, lastName: Lovelace, phone: "+1 555 0100", email: review@example.com}
      notes: "Sign in with the demo account."
      demoAccount: {name: demo@example.com, required: true}   # password: the secret XLESS_DEMO_PASSWORD
```

| Key | Type | Required | Notes |
|---|---|---|---|
| `groups` | list of strings | yes, unless `external.groups` | Internal TestFlight groups to deliver to. No blanks or duplicates. |
| `whatToTest` | string | no (yes with `external.submit`) | The build's "What to Test" text (at most 4000 characters). Beta app review needs it. |
| `locale` | string | no | Locale of `whatToTest` and `external.info`, BCP-47 style with a hyphen (`en-US`, not `en_US`). Default `en-US`. |
| `testers` | list | no | Added to every group of `groups`: an email address, or `{email, firstName, lastName}`. They must be App Store Connect users of the team ([`xless users invite`](apple-account.md#xless-users)). |
| `external.groups` | list of strings | yes, with `external` | External groups to deliver to (not also in `groups`). |
| `external.testers` | list | no | Added to every external group: any address (Apple emails them), as in `testers`. |
| `external.submit` | boolean | no | Submit the build for beta app review (default `true`): external testers get a build once Apple approves it. |
| `external.info` | map | no | The beta information of `locale`: `description` (at most 4000 characters), `feedbackEmail`, `marketingUrl`, `privacyPolicyUrl`. |
| `external.review` | map | no | Beta App Review's `contact` (`firstName`, `lastName`, `phone`, `email`), `notes` and `demoAccount` (`name`, `required`, `passwordSecret`: the secret holding the password, default `XLESS_DEMO_PASSWORD`; never the password itself, a key's or token's name, nor a variable the system, the shell or xless uses, such as `PATH`, `HOME`, `ENV` or `XLESS_*`: [config] error). |

After `upload` reaches `VALID`, xless (iOS, and the macOS App Store package):

- reuses each group of `groups` by exact (case-sensitive) name, matched client-side so names containing commas work, or creates it as an **internal** group with automatic distribution (`hasAccessToAllBuilds`). An existing external group with that name is an error. Nothing is ever deleted and existing groups are not modified;
- adds the new build to each group that does not have it yet, as `xless testflight builds add` does;
- sets or updates "What to Test" for `locale` when `whatToTest` is given and differs;
- adds the `testers` missing from each internal group. An address that is not an App Store Connect user of the team is a warning, not a failure (the check needs an Admin key; without one, Apple decides);
- with `external`: sets what differs in `external.info` and `external.review` (the demo account's password, read from its secret, only when the account is new, renamed or newly required; with `xless run --docker` only the container that uploads gets it: [secrets.md](secrets.md#xless-run-and-docker-builds)), reuses or creates each external group (an internal group of that name is an error), adds the build and the missing `external.testers`, and submits the build for beta app review unless it already was or `submit: false`;
- prints the build number, the groups and `available to N testers` (with the testers added), the beta app review state, and warns about groups with 0 testers. Afterwards, [`xless testflight`](apple-account.md#xless-testflight) manages the groups, testers, public links and the review.

[`xless provision apply`](apple-account.md#xless-provision) creates the groups of `groups` and `external.groups` ahead
of the first upload (and reports a group of the other kind as a blocker); the testers, the beta information and the
submission are left to the ship.

A failure here exits 17 as `[upload] …`; the build is already uploaded and processed, so the message says so (ship again with a higher build number, or finish in App Store Connect). One-command usage: [signing-and-testflight.md](signing-and-testflight.md#one-command-testflight).

## Launch storyboard

With `launchStoryboard` set, the iOS `assets` stage compiles the storyboard without ibtool, byte-identical to the ibtool of
the image's Xcode (27B52, 27A9275, 27A266a, 17F113, 17F42, 17E202, 17E192, 17C529, 17C52, 17B100, 17B55 or 17A400; any other Xcode is refused, [research/xcode-tools-by-version.md](research/xcode-tools-by-version.md)).
`xless storyboard compile` is the same compiler as a standalone command (`--xcode-build` picks the Xcode; by default the image's):

- The `--target-device` set comes from `UIDeviceFamily` in the app's Info.plist: `[1]` → iPhone, `[1, 2]` → iPhone + iPad
  (absent → iPhone + iPad). Other families are an error.
- The deployment target is `platforms.ios.minimumOS` (15.0 to 27.x).
- The result is written to `<App>.app/<name>.storyboardc` at the bundle root, where Xcode's link step puts it
  ([research/ib-invocation.md](research/ib-invocation.md)); Info.plist gets `UILaunchStoryboardName = <name>` and loses
  `UILaunchScreen`.
- Images and named colors the storyboard uses must be in the `assets` catalog (e.g. a `Logo.imageset`).
- Only a subset is supported: one view controller (optionally with a storyboard ID) with a root view, image views,
  labels, Auto Layout constraints, colors, safe area and accessibility traits, views nested at most 32 levels deep,
  files up to 4 MiB; this covers Expo's generated `SplashScreen.storyboard`. Anything else, or a storyboard saved by
  an Xcode newer than 27.2, fails with
  `[assets] launch storyboard <path>: unsupported … at line <n> — …` (exit code 13).

Example: [samples/HelloShipLaunch](../samples/HelloShipLaunch) (`launchStoryboard: Resources/LaunchScreen.storyboard`).
On the Mac, `make ib-parity` ([maintainers.md](maintainers.md#parity-tests)) checks the compiler against ibtool (golden drift, and a simulator screenshot of the sample's
launch screen compiled both ways).

## Validation rules

- `distribution`: iOS must be `app-store`. macOS accepts `app-store` (signs with the Apple Distribution key) or
  `developer-id` (the default, direct distribution); with `app-store`, `--to upload` runs the macOS App-Store lane
  ([signing-and-testflight.md](signing-and-testflight.md#macos-app-store-lane-testflight)).
- `xless ship --distribution app-store|developer-id` overrides the platform's `distribution` for that one run
  (macOS; iOS is always app-store and refuses `developer-id`). The config file keeps its own value.
- `platforms.<p>.minimumOS` must parse as a dotted version.
- `launchStoryboard` must end in `.storyboard`.
- `testflight.groups` must be non-empty without blank or duplicate names; `whatToTest` must be non-blank and at most 4000 characters.
- Invalid configs fail in the config stage (exit code 10) with `[config] cause — fix`.

## Environment

| Variable | Effect |
|---|---|
| `XLESS_BUILD_NUMBER` | Overrides `build`. `--build-number` takes precedence. |
| `XLESS_TOOLCHAIN_META` | Path of `toolchain-meta.json`. Default: `/opt/xless/toolchain-meta.json` if present, else `$XDG_CONFIG_HOME/xless/toolchain-meta.json` (`~/.config/xless/toolchain-meta.json` when `XDG_CONFIG_HOME` is unset). |

Secrets (`ASC_*`, `XLESS_DIST_KEY`, `XLESS_DEVID_KEY`) are never part of `xless.yml`; see [signing-and-testflight.md](signing-and-testflight.md#secrets).
