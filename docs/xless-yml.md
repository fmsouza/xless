# xless.yml reference

`xless.yml` lives in the project directory next to `Package.swift`. Example (the HelloShip sample):

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
| `teamID` | string | yes | Exactly 10 characters, `A-Z` and `0-9`. From developer.apple.com → Membership. `sign` fails if it differs from the team of the App Store Connect key (read from the provisioning profile). |
| `version` | string | yes | Marketing version (`CFBundleShortVersionString`): 1 to 3 dot-separated integers. Quote it if YAML would read it as a number. |
| `build` | string or integer | yes | Build number (`CFBundleVersion`): 1 to 3 dot-separated integers. Overridden by `--build-number` or `XLESS_BUILD_NUMBER`. Each upload of a given `version` needs a higher one than every earlier upload, from any machine (see [build numbers](signing-and-testflight.md#build-numbers)). |
| `platforms` | map | yes | At least one of `ios`, `macos`. Any other key is an error. |
| `assets` | path | required for iOS (app-store) | Asset catalog (`.xcassets`), relative to the project. Compiled to `Assets.car` on iOS and to an `.icns` icon on macOS (macOS has no `Assets.car`). App Store builds fail at `assets` unless it contains an `.appiconset`. |
| `privacyManifest` | path | required for iOS (app-store) | `PrivacyInfo.xcprivacy`, copied into the bundle; `finalize` fails for App Store builds if it is missing. |
| `infoPlist` | path | no | Extra Info.plist keys merged into the generated one (usage descriptions, orientations, export-compliance keys). |
| `usesNonExemptEncryption` | boolean | no | Stamps `ITSAppUsesNonExemptEncryption` (export compliance) into the Info.plist. `finalize` refuses iOS App Store builds whose Info.plist has no such key (they would stall at "Missing Compliance" in TestFlight). Set it here, or put the key in the `infoPlist` file. If both define it with different values, `finalize` refuses. `false` means the app uses no encryption beyond what Apple's OS provides or only exempt encryption. `true` is valid, but App Store Connect then needs an export compliance answer for each build before testers can install it. A non-boolean value in the Info.plist is refused. |
| `xcode` | string | no | The Xcode whose SDK must build the app, e.g. `"26.2"` (Ruling R8; see [react-native.md](react-native.md#pinning-the-xcode-sdk)). `build` refuses an image whose SDK comes from another Xcode, the app compiles with an open-source Swift release matching that Xcode's Swift, `xless docker` runs in the images `xless setup --xcode …` made from it (`xless:local-<arch>-xcode<version>`). Default: the image's SDK. |
| `testflight` | map | no | Deliver uploaded builds to TestFlight groups. See [`testflight`](#testflight). |
| `launchStoryboard` | path | no | iOS only (ignored for macOS). A launch-screen `.storyboard` (must end in `.storyboard`), relative to the project. See [Launch storyboard](#launch-storyboard). |

## `platforms.<ios|macos>` keys

| Key | Type | Required | Notes |
|---|---|---|---|
| `minimumOS` | string | yes | Dotted version such as `"17.0"`. For iOS it must be 13.0 or later (Apple's rule, checked at `finalize`). Keep it equal to the `platforms:` in `Package.swift`. |
| `product` | string | yes | The library product in `Package.swift` that holds the app (e.g. `.library(name: "HelloShip", targets: ["HelloShip"])`). xtool (iOS) and xless (macOS) link it into a generated executable named after it. |
| `entitlements` | path | no | Entitlements plist, relative to the project. Managed and security-sensitive entitlements are gated against the provisioning profile. `$(AppIdentifierPrefix)` and `$(TeamIdentifierPrefix)` become `<teamID>.`; on iOS the values of `keychain-access-groups`, `com.apple.security.application-groups` and `com.apple.developer.associated-domains` must be ones the profile allows, and `aps-environment` takes the profile's value, as Xcode signs. |
| `distribution` | `app-store` or `developer-id` | no | Defaults: iOS `app-store`, macOS `developer-id`. |
| `bundleID` | string | no | Overrides the top-level `bundleID` for this platform. Same format rule. |

## `testflight`

```yaml
testflight:
  groups: ["Internal"]
  whatToTest: "Launch screen built on Linux"
```

| Key | Type | Required | Notes |
|---|---|---|---|
| `groups` | list of strings | yes | Internal TestFlight groups to deliver to. At least one, no blanks or duplicates. |
| `whatToTest` | string | no | The build's "What to Test" text (at most 4000 characters). |
| `locale` | string | no | Locale of `whatToTest`, BCP-47 style with a hyphen (`en-US`, not `en_US`). Default `en-US`. |

After `upload` reaches `VALID`, xless (iOS only; ignored for macOS):

- reuses each group by exact (case-sensitive) name, matched client-side so names containing commas work, or creates it as an **internal** group with automatic distribution (`hasAccessToAllBuilds`). An existing external group with that name is an error. Nothing is ever deleted and existing groups are not modified;
- adds the new build to each group explicitly;
- sets or updates "What to Test" for `locale` when `whatToTest` is given;
- prints the build number, the groups and `available to N testers`, and warns about groups with 0 testers. Internal testers must be App Store Connect users, added once in the web UI (Users and Access, then TestFlight).

A failure here exits 17 as `[upload] …`; the build is already uploaded and processed, so the message says so (ship again with a higher build number, or finish in App Store Connect). One-command usage: [signing-and-testflight.md](signing-and-testflight.md#one-command-testflight).

## Launch storyboard

With `launchStoryboard` set, the iOS `assets` stage compiles the storyboard without ibtool, byte-identical to the ibtool of
the image's Xcode (27A266a or 17C52; any other Xcode is refused, [research/xcode-tools-by-version.md](research/xcode-tools-by-version.md)).
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
  an Xcode newer than 27.0, fails with
  `[assets] launch storyboard <path>: unsupported … at line <n> — …` (exit code 13).

Example: [samples/HelloShipLaunch](../samples/HelloShipLaunch) (`launchStoryboard: Resources/LaunchScreen.storyboard`).
On the Mac, `make ib-parity` ([maintainers.md](maintainers.md#parity-tests)) checks the compiler against ibtool (golden drift, and a simulator screenshot of the sample's
launch screen compiled both ways).

## Validation rules

- `distribution`: iOS must be `app-store`. macOS accepts `app-store` (signs with the Apple Distribution key) or
  `developer-id` (the default, direct distribution); macOS App Store packaging and upload are not wired yet
  (see [research/mas-pkg.md](research/mas-pkg.md)).
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
