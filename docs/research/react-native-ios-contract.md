# React Native / Expo iOS build contract (Expo SDK 57, React Native 0.86.2, CocoaPods 1.15.2)

What the native-project half of an Expo (CNG) iOS build does, measured on Linux in the `xless-rn` image, so xless's
`prepare` stage can do the same (m3 spec §3.5, gate G1). Later sections (the Swift Build side) are added by the
tasks that measure them.

Versions measured (all from the acceptance app's lockfiles, none chosen by xless):
`expo` 57.0.11, `@expo/cli` 57.0.13, `expo-modules-autolinking` 57.0.9, `react-native` 0.86.2,
`hermes-compiler`/`hermes-engine` 250829098.0.16, CocoaPods 1.15.2 (`xcodeproj` 1.27.0) from the app's `Gemfile.lock`,
pnpm 10.28.1 (corepack, from `packageManager`); image: Ruby 3.4.8, Bundler 2.7.2, Node 24.22.0, Ubuntu 22.04 arm64.
Another Expo SDK or React Native minor is off-contract until re-measured.

`xless-rn`, `xless-tauri` and `xless-base` below are the images of xless 0.10 and older, which these measurements ran in.
What `xless-rn` held is now the xless image (Swift Build, the shims) and the `react-native` kit on it
([images.md](../images.md)).

## Method

A local script (not committed; it names the private app) runs one `xless-rn:local-arm64` container:

1. The app checkout is mounted read-only. Its tracked files (`git ls-files -z | rsync -a --from0 --files-from=-`)
   are copied to a work copy in a docker volume (ext4, rather than the case-insensitive macOS host filesystem). The
   checkout's
   `git status --porcelain --ignored | shasum` is identical before and after every run.
2. Caches are separate volumes: corepack, the pnpm store (inside the work volume, so pnpm can hard-link),
   `BUNDLE_PATH`, `~/.cocoapods` (spec CDN), `~/Library/Caches/CocoaPods`.
3. Recording stand-ins for `xcodebuild`, `xcrun`, `clang`, `plutil`, `PlistBuddy`, `defaults`, `xcode-select`,
   `sw_vers`, `security` sit first on `PATH`. Each logs argv, cwd, parent and grandparent command lines, then answers
   (see below) or refuses with exit 127. `strace -f -e trace=execve` over prebuild and `pod install` catches
   absolute-path calls and failed `PATH` lookups that the stand-ins cannot see.
4. The procedure below, then checks: `Pods/Manifest.lock` equals `Podfile.lock`, the `.xcworkspace` exists, the
   Podfile's own `post_install` edits are in the generated xcconfigs, and React Native's post-install ran.

## Procedure (successful)

From the monorepo root of the work copy:

```sh
unset SWIFT_VERSION                                      # see "Env-only fixes" 1
export TAR_OPTIONS='--warning=no-unknown-keyword --exclude=._*'   # 2
export PATH=<stand-ins>:$PATH                            # 3–5
export <the app's own variant variables> EXPO_NO_TELEMETRY=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0

pnpm install --frozen-lockfile --store-dir <volume>/.pnpm-store
<the app's own config-generator script>                 # no secrets needed for a staging build
pnpm --filter mobile exec expo prebuild --platform ios --no-install
cd apps/mobile/ios
bundle install                                           # Gemfile is in apps/mobile; gems into BUNDLE_PATH
bundle exec pod install
```

`pod install` ends with "157 dependencies from the Podfile and 195 total pods installed". No tracked file of the
work copy changes (`rsync -nc` against the checkout lists nothing): prebuild reports "Updated package.json | no
changes", and `Gemfile.lock`/`pnpm-lock.yaml` are untouched.

The app's own `expo:prebuild` script is `expo prebuild --no-install --no-clean && node <a team-fixup script>
&& pnpm dlx pod-install ios`. The middle step rewrites `DEVELOPMENT_TEAM = $(DEVELOPMENT_TEAM);` in the generated
`project.pbxproj` to the quoted team ID taken from an environment variable (or empty), because an unquoted `$(…)` value makes the pbxproj
unparseable for CocoaPods. In this version the config plugin already writes it quoted
(`DEVELOPMENT_TEAM = "$(DEVELOPMENT_TEAM)";`, extension target only), so `pod install` parses the project without
the step. It only sets the signing team, which xless overrides as a build setting anyway, so xless does not run it.
`pnpm dlx pod-install` is `pod install` through Bundler when a Gemfile is present, i.e. the command above.

## Darwin tool calls (prebuild and `pod install`)

`expo prebuild` invokes none of `xcodebuild`, `xcrun`, `plutil`, `PlistBuddy`, `defaults`. It executes `node`,
`pnpm`, `npm config -g get prefix`, `yarn global dir`, `pnpm root -g`, and looks up `bun` and `sharp` on `PATH`
(absent; optional, it falls back to its JS image code).

`pod install`, complete list:

| Call | Caller | Without a fix on Linux | Answer used |
|---|---|---|---|
| `xcodebuild -version` | React Native `Xcodebuild.version` (`scripts/cocoapods/helpers.rb`) from `ReactNativePodsUtils.check_minimum_required_xcode`, inside `use_react_native!` | Ruby backtick raises ENOENT: `[!] Invalid Podfile file: No such file or directory - xcodebuild` | `Xcode 27.0` / `Build version 27A266a`, from the SDK's toolchain metadata (`xcodeVersion` 2700, `xcodeBuild`). React Native only checks ≥ 16.1 |
| `/usr/bin/xcrun clang` (absolute) | CocoaPods `verify_xcode_license_approved!` (output scanned for "license") | ENOENT; output has no "license", check passes | none needed |
| `clang -x c - -dynamiclib -o …/ExpoModulesJSI.xcframework/.stub-binary -install_name @rpath/ExpoModulesJSI.framework/ExpoModulesJSI` (twice) | `expo-modules-jsi/apple/scripts/create-stub-xcframework.sh`, run by `expo-modules-autolinking`'s `ensure_expo_modules_jsi_stub_xcframework` and again as the podspec's `prepare_command` | host clang builds an ELF executable: `undefined reference to 'main'`, `pod install` aborts | retargeted: `clang -target arm64-apple-ios16.4 -isysroot <iPhoneOS SDK> -fuse-ld=<bundle ld64.lld> -mlinker-version=907 <args>` → Mach-O `MH_DYLIB`; the stand-in itself then calls `xcrun --show-sdk-path` and `xcrun -f ld` (xless shim) |
| `command -v ccache` | React Native `set_ccache_compiler_and_linker_build_settings` (post-install), a Ruby backtick | Ruby execs `command` directly; Linux has no `/usr/bin/command` (macOS ships one): `No such file or directory - command` | an executable `command` script (`#!/bin/sh` / `command "$@"`) |
| `/usr/sbin/sysctl -n hw.optional.arm64` | React Native `SysctlChecker` (Rosetta warning) | prints an error, `to_i` → 0, no warning | none needed |
| `sw_vers` | CocoaPods error report only (after a crash) | — | none needed |

Not called during prebuild or `pod install`: `plutil`, `PlistBuddy`, `defaults`, `xcode-select`, `security`, any
other `xcrun` form. Other executables: `node` (71 runs: `require.resolve` probes, autolinking, React Native codegen,
reanimated/worklets version checks), `curl` + `tar`/`gzip` (downloads), `git --version`, `bash` (prepare commands).

## Env-only fixes

1. **`SWIFT_VERSION` must not be in the environment.** The Swift base image exports `SWIFT_VERSION=swift-6.4.0-RELEASE`.
   `Xcodeproj` resolves a build setting as `[defaults, project, config, setting, ENV[key]]`, the environment last and
   winning (`xcodeproj/project/object/build_configuration.rb`), so CocoaPods reads the user target's `SWIFT_VERSION`
   as `swift-6.4.0-RELEASE` and dies: `ArgumentError - Malformed version number string`. Generally: every environment
   variable named like a build setting overrides the project during `pod install`; the prepare stage must run with a
   scrubbed environment (`SWIFT_*` from the base image removed).
2. **`TAR_OPTIONS='--warning=no-unknown-keyword --exclude=._*'`.** Expo's precompiled-module tarballs (shipped inside
   the npm packages under `prebuilds/output/debug/xcframeworks/*.tar.gz`) were made with bsdtar on macOS:
   - `LIBARCHIVE.xattr.com.apple.provenance` pax headers make GNU tar print a warning on stderr. Expo reads
     `tar xOzf <tarball> <…/Info.plist>` with stdout and stderr merged (`Open3.capture2e`) and fails to parse the plist
     (`[Expo-precompiled] Failed to read expo-xcframework-info….plist: Found additional characters after parsing the
     root plist object`), once per module.
   - AppleDouble `._*` members: GNU tar extracts them as plain files (647 across the seven precompiled
     xcframeworks, e.g. `ExpoImage.framework/Modules/._module.modulemap`); macOS bsdtar folds them into xattrs. They
     would be copied into the app's embedded frameworks. CocoaPods caches extracted pods, so a cache filled without
     the option keeps them until those `External/Expo*` cache entries are removed.
3. **`xcodebuild -version`** answered from the SDK metadata (table above). xless: an `xcodebuild` shim that answers
   exactly `-version` and refuses everything else loudly.
4. **`command`** as an executable on `PATH` (table above). xless: ship one in the image.
5. **`clang` retarget for Darwin-only flags.** A `-dynamiclib`/`-install_name` compile with no `-target` can only mean
   Darwin. xless: a prepare-stage `clang` stand-in that adds the iOS target, SDK and linker and passes everything
   else through unchanged. (The stub is only inspected by CocoaPods to classify the framework as dynamic; see
   "Build-time notes" for the real build.)

Also set: `EXPO_NO_TELEMETRY=1` (prebuild otherwise spawns a detached telemetry upload),
`COREPACK_ENABLE_DOWNLOAD_PROMPT=0`. Node needs no path fix: CocoaPods writes `ios/.xcode.env.local` with
`export NODE_BINARY=/opt/node/bin/node` (from `node --print process.argv[0]`), and `.xcode.env` uses
`$(command -v node)`.

## Network and artifacts

Downloaded during a cold run (sizes as stored):

| What | Source | Size |
|---|---|---|
| npm packages (1,444 package directories in `node_modules/.pnpm`) | npm registry, via `pnpm install` | 3.5 GB pnpm store, 683 MB `node_modules` |
| Gems (CocoaPods and the app's fastlane bundle) | rubygems.org | 98 MB |
| CocoaPods specs | CocoaPods CDN | 33 MB `~/.cocoapods` |
| Pod sources and binaries | GitHub/Google/CDN tarballs and git, plus Maven (below) | 1.5 GB CocoaPods cache, 1.8 GB `Pods/` |
| React Native core, prebuilt (`RCT_USE_PREBUILT_RNCORE=1`) | Maven Central `react-native-artifacts-0.86.2-reactnative-core-debug.tar.gz` | 94.2 MB (release: 29.6 MB) |
| React Native dependencies, prebuilt (`RCT_USE_RN_DEP=1`) | Maven Central `…-reactnative-dependencies-debug.tar.gz` | 17.9 MB (release: 9.9 MB) |
| Hermes | Maven Central `hermes-ios-250829098.0.16-hermes-ios-debug.tar.gz` | 31.2 MB (release: 24.3 MB) |

`pod install` downloads **both** flavours (the table's release sizes): `Pods/ReactNativeCore-artifacts`,
`Pods/ReactNativeDependencies-artifacts` and `Pods/hermes-engine-artifacts` hold `*-debug.tar.gz` and
`*-release.tar.gz`, written seconds apart during `pod install`, and installs the debug one. The "Replace … for the
right configuration" script phases only extract the configuration's tarball from there at build time; they download
nothing (corrected in Task 7: a HelloRN Release build with the network off succeeds). Expo's precompiled modules come
from the npm packages (`file://` downloads), not the network, also as debug, and are switched to release at build
time the same way.

Time (arm64 Colima VM, 8 CPUs): cold `pnpm install` 50 s, prebuild 4 s, first `pod install` about 6 min;
a warm full run (fresh work copy, caches populated) 2.5 min, of which `pod install` 2 min.

### Prebuilt binaries vs sources

Under `Pods/` (`ios-arm64` slice; "dynamic" = Mach-O `MH_DYLIB`, embedded by `[CP] Embed Pods Frameworks`):

| xcframework | Slices | ios-arm64 binary |
|---|---|---|
| `React-Core-prebuilt/React.xcframework` | ios-arm64, ios-arm64_x86_64-simulator, ios-arm64_x86_64-maccatalyst | dynamic, 66 MB |
| `ReactNativeDependencies/…/ReactNativeDependencies.xcframework` | ios, ios-sim, maccatalyst, macos, tvos, tvos-sim, xros, xros-sim | dynamic, 3.4 MB |
| `hermes-engine/destroot/Library/Frameworks/universal/hermesvm.xcframework` | ios, ios-sim, maccatalyst, macos, tvos, tvos-sim, xros, xros-sim | dynamic, 5.8 MB |
| `ExpoModulesCore`, `ExpoFileSystem`, `ExpoFont`, `ExpoImage`, `ExpoMediaLibrary`, `ExpoModulesWorklets`, `ExpoVideo` (`<Pod>/<Pod>.xcframework`) | ios-arm64, ios-arm64_x86_64-simulator | dynamic (0.2–6 MB) |
| `ExpoImage/{SDWebImage,SDWebImageAVIFCoder,SDWebImageSVGCoder,SDWebImageWebPCoder,libavif}.xcframework` (bundled SwiftPM frameworks) | ios-arm64, ios-arm64_x86_64-simulator | dynamic |
| `OpenSSL-Universal/OpenSSL.xcframework` | ios, ios-sim, maccatalyst, macos, tvos, tvos-sim, watchos, watchos-sim, xros, xros-sim | dynamic, 4.9 MB |
| `FirebaseAnalytics`, `GoogleAppMeasurement`, `GoogleAppMeasurementIdentitySupport` (`Frameworks/*.xcframework`) | ios, ios-sim, maccatalyst, macos, tvos, tvos-sim | static archive inside `.framework` (link, do not embed) |
| a vendored static-library xcframework | ios-arm64, ios-arm64_x86_64-simulator | static library `.a`, 86 MB |
| `ExpoModulesJSI.xcframework` (in `node_modules/expo-modules-jsi/apple/Products`, not `Pods/`) | ios, ios-sim, maccatalyst, macos, tvos, tvos-sim | the install-time stub dylib, replaced at build time |

Plain vendored frameworks (not xcframeworks): `MLKitCommon`, `MLKitVision`, `MLImage` (fat x86_64+arm64 static
archives), `MLKitBarcodeScanning` (fat; arm64 slice is one prelinked `MH_OBJECT`). The Podfile's `post_install`
links these only for `[sdk=iphoneos*]`.

Everything else builds from source: 105 static-library pod targets (Swift, Objective-C, C++), including the app's
local `:path` pods and the React Native community modules. `RNReanimated` and `RNSVG` print "prebuilt xcframework
unavailable; building from source" (Expo looks for app-built precompiled tarballs under `packages/precompile/.build`).

## Generated workspace

`ios/` after prebuild + `pod install`:

- `<App>.xcworkspace` → `group:<App>.xcodeproj`, `group:Pods/Pods.xcodeproj`. `<App>` is the variant's display name
  without spaces (Expo CNG); it is also the scheme and app target name.
- `<App>.xcodeproj` (objectVersion 54), configurations Debug/Release, two targets, **no `PBXTargetDependency` at all**:
  - `<App>` — `com.apple.product-type.application`; deployment 16.4, `SWIFT_VERSION` 5.0, bridging header,
    `TARGETED_DEVICE_FAMILY` 1,2, `OTHER_LDFLAGS` `$(inherited) -ObjC -lc++`; base configuration
    `Pods/Target Support Files/Pods-<App>/Pods-<App>.release.xcconfig`; Frameworks phase: `libPods-<App>.a` only.
  - `<Ext>` — `com.apple.product-type.app-extension` (an AutoFill credential provider); deployment 17.0,
    `SWIFT_VERSION` 5.9, bridging header, `DEVELOPMENT_TEAM = "$(DEVELOPMENT_TEAM)"`, no base xcconfig (not in the
    Podfile), `OTHER_LDFLAGS` `$(inherited) -lMMKVCore -lc++ -lz` with `LIBRARY_SEARCH_PATHS`
    `$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/MMKVCore` and `HEADER_SEARCH_PATHS` into
    `Pods/Headers/Public`; Frameworks phase: `AuthenticationServices.framework`, `CryptoKit.framework`, and one
    **Swift package product from an `XCRemoteSwiftPackageReference` pinned to a git revision**.
  - The app embeds the extension through a `Copy Files` phase (`dstSubfolderSpec` 13 = PlugIns).
  - So the build order comes only from Xcode's implicit dependencies: `libPods-<App>.a` → the `Pods-<App>`
    static-library target in `Pods.xcodeproj` (195 target dependencies, one per pod, `MMKVCore` included); the
    `.appex` in Copy Files → `<Ext>`; the extension's `-lMMKVCore` → the `MMKVCore` pod target (the extension
    itself declares no dependency on it).
- Shared scheme `<App>.xcscheme`: `buildImplicitDependencies = YES`, `parallelizeBuildables = YES`, Archive and
  Profile use Release; it also lists a `<App>Tests.xctest` buildable that has no target (dangling, test action only).
- `Pods/Pods.xcodeproj` (objectVersion 54, 93.5k lines): 231 targets = 105 static libraries, 35 resource bundles,
  91 aggregate targets (pods that only vendor binaries or run scripts); `Pods-<App>` is one of the static
  libraries. No shared schemes. `Podfile.lock`: 288 entries (subspecs included; 197 distinct pods), 4,141 lines.
  `Pods/` has 52 downloaded pod directories; the other pods are `:path` pods inside `node_modules`.
- `ios/build/generated/{autolinking/autolinking.json, ios/ReactCodegen/…}`: React Native codegen output written
  during `pod install`.
- `Pods/Target Support Files/Pods-<App>/ExpoModulesProvider.swift` (Expo autolinking; regenerated at build time).

### Script phases of the app target, in order

1. `[CP] Check Pods Manifest.lock` — `diff` of `Podfile.lock` and `Pods/Manifest.lock`.
2. `[Expo] Configure project` — `bash -l -c ./Pods/Target Support Files/Pods-<App>/expo-configure-project.sh`
   (sources `.xcode.env`/`.xcode.env.local`, runs node to regenerate `ExpoModulesProvider.swift`); always out of date.
3. Sources (2 files), Frameworks, Resources (11 files).
4. `Bundle React Native code and images` — sources `.xcode.env*`, `SKIP_BUNDLING` for Debug, resolves the entry
   file and `@expo/cli` with `$NODE_BINARY`, `BUNDLE_COMMAND=export:embed`, then runs React Native's
   `scripts/react-native-xcode.sh` (Metro bundle + Hermes bytecode). Always out of date.
5. `[CP] Copy Pods Resources` — `Pods-<App>-resources.sh`: 35 `.bundle`s via `rsync` (the script's `ibtool`,
   `xcrun momc`/`mapc`, asset-catalog branches are not reached for this app).
6. `[Expo Dev Launcher] Strip Local Network Keys for Release` — `/usr/libexec/PlistBuddy` on the built Info.plist;
   every call guarded, so a missing PlistBuddy silently leaves the dev-launcher Bonjour keys in place.
7. Copy Files → PlugIns (the extension).
8. `[CP] Embed Pods Frameworks` — `Pods-<App>-frameworks.sh`: 17 frameworks (React, ReactNativeDependencies,
   hermesvm, OpenSSL, the 7 Expo precompiled modules + 5 bundled SDWebImage/libavif, ExpoModulesJSI) via `rsync`,
   `lipo -info` (strip invalid archs), `xcrun otool -LX` (Swift runtime check), `/usr/bin/codesign` when a signing
   identity is set.
9. `[CP-User] [RNFB] Core Configuration` — finds `firebase.json`, uses `ruby` and `python3` to read it, writes keys
   (`firebase_json_raw`, data-collection flags) into the built Info.plist and the dSYM Info.plist with
   `/usr/libexec/PlistBuddy -c "Add …"`. Needed for Firebase behaviour.

The extension target has no script phases.

### Script phases in `Pods.xcodeproj` that matter for the build

- `React-Core-prebuilt`: `[RNCore] Replace React Native Core for the right configuration` → `node
  scripts/replace-rncore-version.js -c Release -r 0.86.2 -p $PODS_ROOT` (downloads the release tarball).
- `ReactNativeDependencies`: `[RNDeps] Replace …` → `third-party-podspecs/replace_dependencies_version.js` (same).
- `hermes-engine`: `[Hermes] Replace Hermes for the right configuration` → `sdks/hermes-engine/utils/replace_hermes_version.js`.
- Each Expo precompiled pod: `[Expo] Switch <Pod> XCFramework for build configuration` (node
  `replace-xcframework.js`, `release` unless `GCC_PREPROCESSOR_DEFINITIONS` has `DEBUG=1`) and
  `[Expo] Resolve <Pod> dSYM source maps`.
- `ExpoModulesJSI`: `[CP-User] Build ExpoModulesJSI xcframework` → `scripts/build-xcframework.sh`, before headers,
  always out of date: runs a **nested `xcodebuild -scheme ExpoModulesJSI -destination generic/platform=<…>`** on the
  package's own `Package.swift` (swift-tools-version 6.2), assembles the real xcframework, and calls
  `xcrun swiftc --version`.
- `ReactCodegen`: `[CP-User] Generate Specs` (React Native codegen via `with-environment.sh` + node) and
  `[Expo] Remove duplicate codegen output`.
- `React-RCTFBReactNativeSpec`: `[RN]Check FBReactNativeSpec` (a directory exists).
- `EXConstants`: `[CP-User] Generate app.config for prebuilt Constants.manifest` (`bash -l -c get-app-config-ios.sh`).
- `[CP] Copy XCFrameworks` in each vendored-xcframework pod; `Copy generated compatibility header` in each Swift pod.

## Build-time notes (for gate G3)

- Release builds need the three Maven release tarballs and the Expo release xcframeworks at build time; `pod install`
  already put them in `Pods/` (Task 7 correction: the build itself needs no network).
- `ExpoModulesJSI` is built by a nested `xcodebuild` on a Swift package; xless must answer that (Swift Build on the
  package) or pre-build it. (Task 7: the `xcodebuild` shim builds it; see "Gate G3/G4".)
- `/usr/libexec/PlistBuddy` is called by absolute path (steps 6 and 9); `lipo`, `otool` (via `xcrun`) and `codesign`
  by name. The image has `llvm-lipo-14`/`llvm-otool-14` but no `lipo`/`otool`/`llvm-lipo` on `PATH`.
- Build order relies on implicit dependencies (product references and `-l` flags), and the extension pulls in a
  remote Swift package; both have to be represented in the PIF.

## Acceptance-app run record

Work copy kept for later tasks in the docker volume `xless-m3-work` (`/work/app`, mobile app at
`/work/app/apps/mobile`, workspace in `apps/mobile/ios`); traces in `/work/trace`. Source checkout fingerprint
unchanged across all runs.

## Swift Build on Linux — spike G2

Gate G2 passed: the stock `swbuild` (swift-build `swift-6.4.0-RELEASE`, `/opt/swift-build` in `xless-rn`) builds
an Xcode project's PIF for `iphoneos` with the Darwin SDK. The resulting `.app` passes `xless tauri compare` against
the Xcode 27 reference. The only allowed gaps are the asset-catalog outputs, because there is no `actool`. No
Swift driver program and no patch to swift-build were needed.

### Fixture

`samples/HelloPIF` (neutral, `com.example.hellopif`) has three targets, written with xcodegen
(`project.yml`; the generated `HelloPIF.xcodeproj` is committed as the fixture for the PIF generator):

- `HelloPIF` app: ObjC `main.m`, Swift `AppDelegate.swift`, a bridging header, `INFOPLIST_FILE`, `OTHER_LDFLAGS -ObjC -lc++`;
- `HelloCore` static library: ObjC, with a copy-headers phase into `include/$(PRODUCT_NAME)`;
- `HelloKit` framework: Swift, with a generated Info.plist, embedded through a Copy Files phase into `$(FRAMEWORKS_FOLDER_PATH)`.

The app also has:

- a shell-script phase that writes `build-stamp.txt` into the bundle and declares it as an output;
- a resource (`greeting.txt`);
- `Assets.xcassets` with an AppIcon.

The Mac reference is built with `xcodebuild -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO`. Its report
is `samples/HelloPIF/reference/reference.json`, and the gaps are in `allowed-gaps.txt` next to it. To reproduce:
`scripts/spikes/hellopif-swbuild-linux.sh` (header comment) in `xless-rn`.

### How `swbuild` sees `iphoneos`

Task 1 found that `swbuild` shows only the Linux platforms, even with `DEVELOPER_DIR` set. Use the same environment as
SwiftPM's `--build-system swiftbuild` path in m2b instead:

```sh
B=/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle
unset SDKROOT
export XCODE_EXTRA_PLATFORM_FOLDERS=$B/Developer/Platforms     # read by SWBCore Core.initializePlatformRegistry
export PATH=<dir with the actool stand-in>:$B/toolset/bin:$PATH
swbuild build <app>.pif --target HelloPIF --configuration Release --derivedDataPath <dd> \
  --buildParametersFile params.json                            # or --buildRequestFile, below
```

- With that environment, `swbuild createSession s -- showPlatforms -- showSDKs` lists `iphoneos`, `iphonesimulator`
  and `macosx` 27.0 from the bundle, and the SDKs `iphoneos27.0`, `iphonesimulator27.0` and `macosx27.0`.
- The toolchain stays `org.swift.` at `/`. It compiles with the open-source `/usr/bin/clang` (21) and
  `/usr/bin/swiftc` (6.4), with `-isysroot` set to the bundle's `iPhoneOS27.0.sdk` and `-resource-dir` set to the
  bundle's `XcodeDefault.xctoolchain/usr/lib/swift/clang`.
- `SWIFT_VERSION=swift-6.4.0-RELEASE` from the base image is harmless here. Swift Build does not read environment
  variables as build settings, which is the opposite of the `xcodeproj` gem in "Env-only fixes" 1.

`params.json` is an `SWBBuildParameters` object: `{"configurationName": "Release", "overrides": {"commandLine":
{"table": {…}}}}`. The CLI's `-Name value` arguments are user defaults, not build settings, so overrides go only here.
The overrides needed:

| Setting | Why |
|---|---|
| `SWIFT_SDK_TOOLSETS = $B/toolset-swb.json` | Swift Build maps the toolset itself (`Settings.addSwiftSDKToolsetSettings`):<br>• `librarian` → `LIBTOOL`/`AR` = `toolset/bin/llvm-lib`. This is `llvm-libtool-darwin` 21 under a name that skips the `libtool -V` "Apple Inc. version" probe; without it the build fails with `/opt/swift-build/libtool is not an executable file`.<br>• `linker` → `ALTERNATE_LINKER_PATH` = the `ld64.lld` trampoline.<br>• the toolset's `-use-ld=lld` → `ALTERNATE_LINKER=lld`. |
| `CODE_SIGNING_ALLOWED = NO` | as the reference; signing stays in xless's `sign` stage |
| `LM_SKIP_METADATA_EXTRACTION = YES` | otherwise `ExtractAppIntentsMetadata` runs `appintentsmetadataprocessor` (absent). On the Mac it is a no-op without AppIntents ("Metadata extraction skipped"). The same guard also skips the `appintentsnltrainingprocessor` (SSU) task. |
| `GENERATE_INTERMEDIATE_TEXT_BASED_STUBS = NO` | otherwise each framework gets `tapi stubify` into `EagerLinkingTBDs` (absent; an incremental-build optimisation only) |
| `STRIP_BITCODE_FROM_COPIED_FILES = NO` | otherwise embedding the framework runs `/usr/bin/bitcode_strip` (hard-coded default path, absent). Xcode itself ignores the flag when not signing. |
| `SWIFT_STDLIB_TOOL_STRIP_BITCODE = NO` | otherwise `builtin-swiftStdLibTool` fails with "Passed --strip-bitcode without --strip-bitcode-tool" |

### PIF

The container is the JSON file that `xcodebuild -dumpPIF <file>` writes. `swbuild` loads `.json`/`.pif`
containers directly. `.xcodeproj`/`.xcworkspace` containers shell out to `/usr/bin/xcrun xcodebuild -dumpPIF`, so on
Linux xless must write this file itself. Shape (format `v11`):

- **Top level.** An array of `{"type": "workspace"|"project"|"target", "signature": <string>, "contents": {…}}`.
  The workspace's `projects` and the project's `targets` list signatures; everything inside refers to other objects
  by `guid`.
- **Absolute paths.** Only three: the workspace `path` (`<proj>.xcodeproj/project.xcworkspace`), the project `path`
  and the project's `projectDirectory`. Rewriting those three was enough to move the Mac PIF to Linux. File
  references are relative (`sourceTree: "<group>"`, `path`) inside a `groupTree` of `group`/`file` nodes, and file
  nodes carry a `fileType` (`sourcecode.swift`, `sourcecode.c.objc`, `folder.assetcatalog`, `text`, …).
- **Project.** `buildConfigurations` (`name`, `guid`, `buildSettings` as strings), `defaultConfigurationName`,
  `developmentRegion`, `knownRegions`, `classPrefix`, `appPreferencesBuildSettings`.
- **Target.** These fields:
  - `type: "standard"`, `name`, `guid`, `productTypeIdentifier`;
  - `productReference {guid, name, type: "product"}`;
  - `buildConfigurations`, `buildRules`, `dependencies [{guid, name}]`;
  - `predominantSourceCodeLanguage`;
  - `provisioningSourceData [{configurationName, provisioningStyle, bundleIdentifierFromInfoPlist}]`;
  - `buildPhases`, each with `type` `com.apple.buildphase.{sources,resources,frameworks,copy-files,shell-script,headers}`.
- **Build files.** A build file is `{guid, fileReference}`, or `{guid, targetReference}` for another target's product
  (both the app's Frameworks phase and its embed phase point at targets this way).
- **Copy Files phases.** `destinationSubfolder` (`$(FRAMEWORKS_FOLDER_PATH)`, `<builtProductsDir>`) and
  `destinationSubpath`. Embedded frameworks carry `codeSignOnCopy`/`removeHeadersOnCopy`.
- **Script phases.** `scriptContents`, `shellPath`, `inputFilePaths`/`outputFilePaths`, the file-list variants,
  `alwaysOutOfDate`, `emitEnvironment`, `sandboxingOverride`, `originalObjectID` (used in the script's file name).
- **Booleans** are the strings `"true"`/`"false"`.

### Implicit dependencies

The `build` command's default request sets `useImplicitDependencies = false`
(`SWBServiceConsoleBuildCommand.swift`). The React Native app needs implicit dependencies (no `PBXTargetDependency`
at all, see above), so xless must pass a `--buildRequestFile`, which replaces the whole request.

Verified: with the app target's `dependencies` emptied, this request

```json
{"parameters": {"action": "build", "configurationName": "Release", "overrides": {…}},
 "configuredTargets": [{"guid": "<app target guid>"}], "useImplicitDependencies": true, "dependencyScope": "workspace",
 "useParallelTargets": true, "useDryRun": false, "continueBuildingAfterErrors": false,
 "hideShellScriptEnvironment": true, "showNonLoggedProgress": true, "enableIndexBuildArena": false,
 "useLegacyBuildLocations": false, "buildCommand": {"command": "build", "style": "buildOnly", "skipDependencies": false}}
```

builds the same app. The log reports "Implicit dependency on target 'HelloCore' … via file 'libHelloCore.a' in build
phase 'Link Binary'", and the same for `HelloKit.framework`. All keys are required, because the type uses synthesized
`Codable`. `"action"` must be set, otherwise the build stops with `invalidBuildAction(name: "")`.
`--derivedDataPath` still overrides the request's arena.

### Tools Swift Build invoked (clean Release build, 242 tasks, 4.5 s on the arm64 Colima VM)

`$B` = Darwin SDK bundle, `$P` = `<dd>/Products/Release-iphoneos`, `$I` = the target's intermediates.

| Task | Executable and argv (Linux) | On Linux |
|---|---|---|
| probes (`ExecuteExternalTool`) | `/usr/bin/clang -v -E -dM [-arch arm64] -isysroot <sdk> -x c -c /dev/null`, `/usr/bin/swiftc --version`, `/usr/bin/ld.lld -version_details`, `ld.lld -v`, `actool --version --output-format xml1`, `actool --print-asset-tag-combinations --output-format xml1 <xcassets>` | clang, swiftc and lld are present. **actool is absent, and that is fatal at planning time**: "failed to read asset tags", the build fails before any task runs |
| `CompileC` | `/usr/bin/clang -x objective-c -target arm64-apple-ios16.4 … -isysroot <sdk>` (response file) | ok |
| `SwiftDriver`, `SwiftCompile`, `SwiftExplicitDependencyGeneratePcm`, `PrecompileModule`, `ScanDependencies`, `SwiftGeneratePch`, `SwiftMergeGeneratedHeaders` | in-process (swift-driver library, explicit modules: 63 clang + 63 Swift module builds) over `/usr/bin/swiftc` | ok |
| `Libtool` | `$B/toolset/bin/llvm-lib -static -arch_only arm64 -D -syslibroot <sdk> -L$P -filelist … -dependency_info … -o $P/libHelloCore.a` (Xcode: `libtool`, same arguments) | ok through the toolset; Apple `libtool` is absent |
| `Ld` | `/usr/bin/clang -target arm64-apple-ios16.4 [-dynamiclib] -isysroot <sdk> -resource-dir … -Os -L… -F… -filelist … -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -dead_strip … -fobjc-link-runtime -L/usr/lib/swift … -ObjC -lc++ -ObjC -fuse-ld=lld --ld-path=$B/toolset/bin/ld64.lld -lHelloCore -framework HelloKit -o …` | ok. Compared with Xcode it lacks `-Xlinker -reproducible`, `-Xlinker -no_warn_duplicate_libraries` (both are gated on the discovered ld64 version) and `-L<toolchain>/usr/lib/swift/iphoneos` (toolchain `/`); none of these changed the output |
| `GenerateAssetSymbols` | `actool <xcassets> --compile $P/HelloPIF.app --output-format human-readable-text --notices --warnings --export-dependency-info $I/assetcatalog_dependencies --output-partial-info-plist $I/assetcatalog_generated_info.plist --app-icon AppIcon --compress-pngs --enable-on-demand-resources YES --development-region en --target-device iphone --target-device ipad --minimum-deployment-target 16.4 --platform iphoneos --bundle-identifier com.example.hellopif --generate-swift-asset-symbol-extensions NO --generate-swift-asset-symbols $I/DerivedSources/GeneratedAssetSymbols.swift --generate-objc-asset-symbols $I/DerivedSources/GeneratedAssetSymbols.h --generate-asset-symbol-index $I/DerivedSources/GeneratedAssetSymbols-Index.plist` | **absent** (stand-in) |
| `CompileAssetCatalogVariant thinned` / `unthinned` | `actool <xcassets> --compile $I/assetcatalog_output/{thinned,unthinned} --output-format human-readable-text --notices --warnings --export-dependency-info $I/assetcatalog_dependencies_{thinned,unthinned} --output-partial-info-plist $I/assetcatalog_generated_info.plist_{thinned,unthinned} --app-icon AppIcon --compress-pngs --enable-on-demand-resources YES --development-region en --target-device iphone --target-device ipad --minimum-deployment-target 16.4 --platform iphoneos` | **absent** (stand-in) |
| `LinkAssetCatalog` | `builtin-linkAssetCatalog --thinned … --unthinned … --output $P/HelloPIF.app --plist-output $I/assetcatalog_generated_info.plist` (merges the two variants into the bundle and the Info.plist fragment) | ok (in-process) |
| `PhaseScriptExecution` | `/bin/sh -c $I/Script-<originalObjectID>.sh` | ok; `build-stamp.txt` identical to the Mac's |
| `CpResource`, `Copy` (embed) | `builtin-copy -exclude .DS_Store … -resolve-src-symlinks <src> <dst>`; the framework embed adds `-exclude Headers -exclude PrivateHeaders -exclude Modules -exclude *.tbd -remove-static-executable` | ok (in-process) |
| `ProcessInfoPlistFile` | `builtin-infoPlistUtility <Info.plist> -producttype … -genpkginfo …/PkgInfo -expandbuildsettings -format binary -platform iphoneos -additionalcontentfile $I/assetcatalog_generated_info.plist -requiredArchitecture arm64 -o …` | ok (in-process) |
| `CopySwiftLibs` | `builtin-swiftStdLibTool --copy --scan-executable … --platform iphoneos --toolchain / --destination …/Frameworks --filter-for-swift-os --back-deploy-swift-span` | runs, but warns "Failed to parse executable: Mach-O parsing not supported on this platform" for each binary and copies nothing. The Mac copied nothing either (iOS 16.4 ships the Swift runtime) |
| `GenerateDSYMFile` | `/usr/bin/dsymutil <binary> -o <binary>.dSYM` | ok, but it is LLVM 14's `dsymutil` (toolchain `/usr/bin` comes before `PATH`) |
| `Validate`, `RegisterExecutionPolicyException`, `Touch` | `builtin-validationUtility … -shallow-bundle`, built-in, `/usr/bin/touch -c` | ok |

The Mac build also ran `ExtractAppIntentsMetadata`/`AppIntentsSSUTraining` (disabled here) and `GenerateTAPI`
(disabled here).

Not exercised: `codesign` (signing off), `ibtool`/storyboards, headers phases of frameworks, xcframeworks,
app extensions, Swift packages, `lipo`.

### Result

`xless tauri compare reference.json <dd>/Products/Release-iphoneos/HelloPIF.app --allow-file allowed-gaps.txt`
passes (exit 0):

- **Executable.** The same platform (2, iOS), `minos` 16.4, rpaths (`/usr/lib/swift`, `@executable_path/Frameworks`)
  and set of 24 linked libraries, including `@rpath/HelloKit.framework/HelloKit`. Only the load-command order differs.
  `_HelloCoreGreeting` (from the static library) is defined in the executable.
- **`Frameworks/HelloKit.framework`.** Embedded with the same libraries and rpaths.
- **Other files.** `build-stamp.txt` and `greeting.txt` are present, and `PkgInfo` and `Info.plist` match apart from
  the icon keys.
- **Missing.** Only `Assets.car`, `AppIcon60x60@2x.png`, `AppIcon76x76@2x~ipad.png` and `CFBundleIcons`/`CFBundleIcons~ipad`.

One trap found on the way: with an empty `GeneratedAssetSymbols.swift`, the executable lacked
`libswiftCoreAudio.dylib`. The file the real `actool` generates imports `SwiftUI` (and `UIKit`,
`DeveloperToolsSupport`), and those imports bring in `CoreAudio` and its overlay as autolink entries. So the
asset-symbols file is part of the link contract, and Task 6 must emit it with those imports (the stand-in in
`scripts/spikes/hellopif-swbuild-linux.sh` does).

### Consequences for the next tasks

- **PIF generator (Task 4).** `swbuild` consumes the `-dumpPIF` shape above; the rest is the generator's job.
  - Signatures can be any unique strings, and guids must be consistent.
  - Settings stay unexpanded (`$(inherited)`, xcconfig values), as in the dumped PIF. xcconfig base configurations
    (CocoaPods' `Pods-<App>.release.xcconfig`) still need checking: the dumped PIF of this fixture has none.
  - The build request must turn implicit dependencies on.
- **actool (Task 6).**
  - Without an `actool` on `PATH`, no project with an asset catalog plans at all.
  - Swift Build calls it four ways: the two probes, the `GenerateAssetSymbols` compile, and the thinned/unthinned
    compiles (argv above).
  - Probe answers that satisfy Swift Build: `com.apple.actool.version` → `{bundle-version, short-bundle-version}`, and
    `com.apple.actool.asset-tag-combinations` → `[]`.
  - The compiles must write `--output-partial-info-plist` (the `CFBundleIcons` keys come from there), the
    `--export-dependency-info` file, the icon PNGs and `Assets.car` into `--compile`, and the three symbol files.
- **Mach-O parsing is compiled out of swift-build on Linux.** `SWBUtil/MachO.swift` sits behind `#if canImport(Darwin)`
  for `MH_MAGIC*`; static `ar` archives are still recognised. Two effects:
  - `CopySwiftLibs` cannot find back-deployment libraries (for example `libswiftCompatibilitySpan` with
    `--back-deploy-swift-span` for a deployment target below the Span OS version). xless must check this itself or
    patch swift-build.
  - `builtin-copy -remove-static-executable` cannot recognise an `MH_OBJECT` or fat binary inside an embedded
    framework. Static `.a`-style frameworks are still recognised, and xless links rather than embeds those anyway.
- **Output.** `swbuild build` writes length-prefixed JSON messages to stdout (`taskStarted` carries
  `commandLineDisplayString`, plus `taskDiagnostic`, `error`, `warning`). The llbuild manifest is in
  `<dd>/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/manifest.json`. xless needs a parser to turn this into its
  own build log and errors.

## HelloRN reference

`samples/HelloRN` is the neutral sample for the Linux pipeline (Tasks 5 and 10). It uses the same stack as the
acceptance app, so it exercises the same machinery: Expo SDK 57 CNG with Hermes and Expo autolinking, CocoaPods
through Bundler, and an app extension added by a config plugin.

### The sample

- **Created with** `create-expo-app@5.0.0 HelloRN --template blank-typescript@57.0.13 --no-install`. That template
  version is the one that pins `expo ~57.0.11` and `react-native 0.86.2`.
- **Pins.** Direct dependencies are exact: `expo` 57.0.11, `react-native` 0.86.2, `react` 19.2.3, `expo-haptics`
  57.0.3, `expo-build-properties` 57.0.9 and `expo-status-bar` 57.0.1. `pnpm.overrides` pins `@expo/cli` 57.0.13,
  `expo-modules-autolinking` 57.0.9 and `expo-modules-core` 57.0.10, which are the versions measured above. The other
  Expo packages resolve within 57.0.x (for example `expo-modules-jsi` 57.0.8). `packageManager` is `pnpm@10.28.1`
  (corepack), and `pnpm-lock.yaml` is committed.
- **Ruby.** The `Gemfile` has CocoaPods `~> 1.15.2` plus the default gems that Ruby 3.4 dropped. `Gemfile.lock` uses
  Bundler 2.7.2 and resolves every gem to the acceptance app's version (CocoaPods 1.15.2, `xcodeproj` 1.27.0, `ffi`
  1.17.3, …).
- **IDs.** `com.example.hellorn` (`ios.appleTeamId` `ABCDE12345`, `buildNumber` 1, version 1.0.0). `expo-build-properties`
  sets `ios.deploymentTarget` 16.4, which is also Expo 57's default. `EXPO_USE_PRECOMPILED_MODULES` is left at the
  default that prebuild writes: `Podfile.properties.json` gets `"EXPO_USE_PRECOMPILED_MODULES": "true"`.
- **Native module.** `expo-haptics` is an Expo module, found by Expo autolinking. Its `ExpoHaptics.podspec` has one
  Swift file and builds from source as a static library, because it is not one of Expo's precompiled modules.
- **App extension.** The local config plugin `plugins/withHelloExtension.js` copies `plugins/HelloExtension/` into
  `ios/HelloExtension/` and adds the target `HelloExtension`. It uses the same `xcode` API as community extension
  plugins: `addTarget(…, 'app_extension', …)`, then Sources, Frameworks and Resources phases.
  - The extension is an Action extension (`com.apple.ui-services`) whose principal class is a UIKit view
    controller, so it needs no extra frameworks.
  - Bundle ID `com.example.hellorn.HelloExtension`, deployment target 17.0, `SWIFT_VERSION` 5.9,
    `APPLICATION_EXTENSION_API_ONLY`, and `CODE_SIGN_ENTITLEMENTS` set to an empty entitlements file.
- **Assets.** One opaque 1024 px icon (6 KB). The splash screen is what Expo generates when no splash
  configuration is given.
- `ios/` is not committed (CNG).

### Generated project (prebuild + `pod install`)

`pod install` reports "88 dependencies from the Podfile and 87 total pods installed".

**`HelloRN.xcodeproj`** has two targets and, like the acceptance app, **no `PBXTargetDependency`**:

- `HelloRN` (application):
  - base configurations `Pods-HelloRN.{debug,release}.xcconfig`;
  - Frameworks phase: `libPods-HelloRN.a`, which is a *file* reference in the PIF, not a `targetReference`. The
    implicit dependency on the `Pods-HelloRN` target can only come from the product name;
  - a "Copy Files" phase with `destinationSubfolder` `$(PLUGINS_FOLDER_PATH)`, whose build file is a
    `targetReference` to `HelloExtension`.
- `HelloExtension` (app-extension): no base configuration and no script phases. It still inherits the project-level
  `OTHER_CFLAGS -DRCT_REMOVE_LEGACY_ARCH=1` and `OTHER_SWIFT_FLAGS -D EXPO_CONFIGURATION_RELEASE` that Expo writes.

React Native's post-install (`set_RCTNewArchEnabled_in_info_plist`) adds `RCTNewArchEnabled` to *every* Info.plist
in the user project. The extension's Info.plist is one of them.

**`Pods.xcodeproj`** has 94 targets: 10 static libraries, 6 resource bundles and 78 aggregate targets (pods that only
vendor binaries or headers, or run scripts).

#### Script phases of the app target, in order

1. `[CP] Check Pods Manifest.lock`
2. `[Expo] Configure project` (always out of date)
3. Sources, Frameworks and Resources
4. `Bundle React Native code and images` (always out of date). It writes `main.jsbundle` as Hermes bytecode.
5. `[CP] Copy Pods Resources`
6. Copy Files → PlugIns (`HelloExtension.appex`)
7. `[CP] Embed Pods Frameworks`

Compared with the acceptance app, there is no dev-launcher `PlistBuddy` phase and no Firebase phase.

**Script phases in `Pods.xcodeproj`:**

- `[CP-User] [RNCore] Replace React Native Core …`, `[CP-User] [RNDeps] Replace React Native Dependencies …` and
  `[CP-User] [Hermes] Replace Hermes …`, each with `[CP] Copy XCFrameworks`.
- `[CP-User] [Expo] Switch <Pod> XCFramework for build configuration` and `[CP-User] [Expo] Resolve <Pod> dSYM source
  maps`, for `ExpoModulesCore`, `ExpoFileSystem`, `ExpoFont` and `ExpoModulesWorklets`.
- `[CP-User] Build ExpoModulesJSI xcframework`, the nested `xcodebuild`. It logged "Built xcframework successfully in
  9s".
- `[CP-User] Generate Specs` and `[Expo] Remove duplicate codegen output` (`ReactCodegen`).
- `[CP-User] [RN]Check FBReactNativeSpec`.
- `[CP-User] Generate app.config for prebuilt Constants.manifest` (`EXConstants`).
- `Copy generated compatibility header` for each Swift pod (`Expo`, `ExpoAsset`, `ExpoDomWebView`, `ExpoHaptics`,
  `ExpoKeepAwake`, `ExpoLogBox`, `EXConstants`).

#### xcframeworks the pods vendor

| xcframework | Slices |
|---|---|
| `Pods/React-Core-prebuilt/React.xcframework` | ios-arm64, ios-arm64_x86_64-simulator, ios-arm64_x86_64-maccatalyst |
| `Pods/ReactNativeDependencies/…/ReactNativeDependencies.xcframework` | ios, ios-sim, maccatalyst, macos, tvos, tvos-sim, xros, xros-sim |
| `Pods/hermes-engine/destroot/Library/Frameworks/universal/hermesvm.xcframework` | ios, ios-sim, maccatalyst, macos, tvos, tvos-sim, xros, xros-sim |
| `Pods/{ExpoModulesCore,ExpoFileSystem,ExpoFont,ExpoModulesWorklets}/<Pod>.xcframework` (Expo precompiled) | ios-arm64, ios-arm64_x86_64-simulator |
| `node_modules/…/expo-modules-jsi/apple/Products/ExpoModulesJSI.xcframework` | stub at install time; built at build time |

The app embeds 8 dynamic frameworks: `React`, `ReactNativeDependencies`, `hermesvm`, `ExpoModulesCore`,
`ExpoFileSystem`, `ExpoFont`, `ExpoModulesWorklets` and `ExpoModulesJSI`. Everything else, `ExpoHaptics` included, is
a static library linked into the app executable (`OTHER_LDFLAGS -l"ExpoHaptics" …`).

#### Launch screen

Prebuild copies Expo's template `SplashScreen.storyboard` unchanged (`UILaunchStoryboardName` `SplashScreen`).
It used to be outside xless's storyboard-compiler subset (the `<accessibility>` element with `accessibilityTraits` on
the image view; `storyboardIdentifier` on the view controller; `insetsLayoutMarginsFromSafeArea`,
`userInteractionEnabled` and `userLabel` on the root view). **Task 6b widened the subset**: it now compiles
byte-identically to ibtool 27.0 (corpus case `real-expo-splash-template`, a copy of HelloRN's prebuild output, at
all four corpus flag sets). The compiled `SplashScreen.storyboardc` holds `SplashScreenViewController.nib` (named after
the storyboard ID), `EXPO-VIEWCONTROLLER-1-view-EXPO-ContainerView.nib` and `Info.plist`.

The image view names an image `SplashScreen` that is not in the asset catalog (the storyboard's resources list
`SplashScreenLogo`). ibtool compiles it without a warning (exit 0, no output) into the usual asset placeholder, and so
does xless (`image-missing-other-resource`). Whatever UIKit then shows is the same for both compilers (not
measured on a device).

An app with a configured splash screen (an image and a background color in the `expo-splash-screen` plugin) gets a
different storyboard, rewritten by the plugin: an image view with lowercase `clipsSubviews="true"
userInteractionEnabled="false" translatesAutoresizingMaskIntoConstraints="false"`, sha1 constraint ids, a
`SplashScreenBackground` named color in `toPrecision(15)` spelling with `alpha="1.000"`, and no `<accessibility>`.
That shape compiles byte-identically too (`real-expo-splash-configured`, neutral colours; `real-expo-splash-fullscreen`
for `enableFullScreenImage`). The rules are in docs/research/nib-encoding.md (section 6 and open questions 15–16).

### Mac reference

Run `make rn-reference`, which runs `scripts/rn-reference.sh samples/HelloRN samples/HelloRN/reference`.

1. The script copies the sample's tracked (and untracked, non-ignored) files to a work copy.
2. In the work copy it runs `corepack pnpm install --frozen-lockfile`, `expo prebuild --platform ios --no-install`,
   and `bundle install` plus `bundle exec pod install` (gems in a scratch `BUNDLE_PATH`).
3. It builds with `xcodebuild -workspace HelloRN.xcworkspace -scheme HelloRN -configuration Release -sdk iphoneos
   -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build`.
4. It records:
   - `reference.json`: `xless tauri report` of the app. `BundleReport` lists the `PlugIns/HelloExtension.appex`
     files but does not read the extension's Mach-O or Info.plist.
   - `reference-appex.json`: the same report for each `.appex`, keyed by bundle name.
   - `build-settings.json`: selected `-showBuildSettings -json` keys for both targets, with derived data set to the
     build's.
   - `pif-summary.json`: from `xcodebuild -dumpPIF`, the app project's targets, product types, products, explicit
     dependencies (none), build phases (type, name, frameworks and copy-files members) and base configurations,
     plus the workspace's project list. Not the dump itself.
   - Paths are normalised to `$APP`, `$DERIVED`, `$SDK`, `$DEVELOPER`, `$REFTMP` and `$HOME`.
5. A warm run took 1 min 18 s.

**Xcode.** The reference is recorded with the pinned Xcode 27.0 (27A266a, iPhoneOS SDK 27.0), so `DTPlatformVersion`
and `DTSDKName` read 27.0/`iphoneos27.0`. The script uses `DEVELOPER_DIR` if it is set. Otherwise it defaults to
`~/.cache/xless/Xcode.app/Contents/Developer` when that copy is 27A266a, because an `/Applications` Xcode may
auto-update. Any Xcode build with an `XcodeToolsProfile` entry (`scripts/xcode-tools.sh`; 17C52 and 27A266a) is accepted for
its own SDK (`DEVELOPER_DIR=…`); a build without one is refused.

## XlessXcode: pbxproj → PIF (Task 5)

`Sources/XlessXcode` reads `.xcworkspace`/`.xcodeproj`/shared schemes and writes the PIF above; `xless xcode pif
<workspace> --scheme S --out DIR [--override K=V] [--package IDENTITY=dump-pif.json]` writes `DIR/<name>.pif` and
`DIR/request.json` for `swbuild build <pif> --buildRequestFile request.json`. The mapping was checked against
`xcodebuild -dumpPIF` (27A266a) of HelloPIF, HelloRN's prebuild app project and two neutral fixtures (a
CocoaPods-style workspace; an app + appex + remote Swift package + project reference); the normalised dumps are the
goldens in `Tests/XlessXcodeTests/Fixtures/golden`. How Xcode maps what the subset contains:

| pbxproj | PIF |
|---|---|
| build setting array | one string, elements joined with single spaces, **no quoting** (`"$(SRCROOT)/My Dir"` splits, as in Xcode) |
| `baseConfigurationReference` | `baseConfigurationFileReference` = the xcconfig's file GUID (it must be in the group tree) |
| groups | `group` `{name, path ("" if none), sourceTree, children}`; `children` omitted when empty; name = `name`, else the path's last component, else (main group) the project name |
| `PBXVariantGroup` | `variantGroup`; each child file gets `regionVariantName` = the child's `name` |
| file reference | `file` `{fileType, path, sourceTree}`, no name; `fileType` = `explicitFileType`, else `lastKnownFileType`, else from the extension (also for the `xcode` npm package's `undefined`/`unknown`); `fileTextEncoding` `utf-8` only for `text.*`/`sourcecode.*` types |
| products of the project's own targets | left out of the group tree; a build file naming one becomes `targetReference` |
| `PBXReferenceProxy` (another project's product) | `targetReference` to that project's target (proxy → `remoteGlobalIDString` = the product file → its target) |
| a file reference no group contains (an Expo config plugin can write one) | a synthetic last main-group child `Recovered References` (`path ""`), as Xcode shows it |
| `ATTRIBUTES` | `CodeSignOnCopy`/`RemoveHeadersOnCopy` → `"true"`; `Weak` → `shouldLinkWeakly`; `Public`/`Private` → `headerVisibility`; `Project` → nothing |
| `COMPILER_FLAGS` | `additionalCompilerOptions` (one string) |
| `dstSubfolderSpec` 0/1/6/7/10/11/12/13/15/16 | `destinationSubfolder` `""` (subpath = `dstPath`)/`$(WRAPPER_NAME)`/`$(EXECUTABLE_FOLDER_PATH)`/`$(UNLOCALIZED_RESOURCES_FOLDER_PATH)`/`$(FRAMEWORKS_FOLDER_PATH)`/`$(SHARED_FRAMEWORKS_FOLDER_PATH)`/`$(SHARED_SUPPORT_FOLDER_PATH)`/`$(PLUGINS_FOLDER_PATH)`/`$(JAVA_FOLDER_PATH)`/`<builtProductsDir>` |
| `runOnlyForDeploymentPostprocessing = 1` (copy, script) | `"true"`; the key is absent otherwise |
| `showEnvVarsInLog = 0` | `emitEnvironment "false"` |
| `PBXTargetDependency` to another project | `{guid, name: "<target> (from <project>.xcodeproj)"}` |
| product reference name | the evaluated product name (a literal `PRODUCT_NAME` wins over the product path); Swift Build matches implicit dependencies on it |
| `XCSwiftPackageProductDependency` | dependency + frameworks build file `targetReference` = `PACKAGE-PRODUCT:<identity>_<product>.<product>` of the package's PIF project (below) |

Swift packages: Xcode's PIF contains a `PACKAGE:<identity>` project per resolved package (and one per package it
depends on). `swift package --build-system swiftbuild dump-pif`, run in the package checkout, writes the same
projects with the same product GUIDs; the identity is the checkout directory name, so the checkout must be named by
the identity (the URL's last component, lowercased, without `.git`). xless resolves nothing itself: an unresolved
product is refused. Checked on the acceptance app: its extension's package (pinned revision) cloned into
`<identity>/` plus `dump-pif` gives 4 package projects (the package and its 3 dependencies); the generated
workspace PIF (6 projects, 265 targets) loads in `swbuild`, whose planning then stops only at the absent `actool` and
`ibtool` (`--version` probes, 14 and 5 calls).

End-to-end (`scripts/xcode-pif-linux.sh`, G2 environment):
- **HelloPIF**: built from the generated PIF with a shared scheme and implicit dependencies on; `xless tauri compare`
  against the Mac reference passes (exit 0) with the same allowed gaps as G2. The request's
  `activeRunDestination` (`iphoneos`, arm64) is accepted.
- **PodsStyle fixture** (CocoaPods layout: xcconfig base configurations, a `libPods-App.a` BUILT_PRODUCTS_DIR file
  in a project without target dependencies, `-l"CoreLib"`, a headers phase, `COMPILER_FLAGS`, an aggregate target,
  a resource bundle, script phases with file lists): builds; Swift Build logs "Implicit dependency on target
  'Pods-App' in project 'Pods' via file 'libPods-App.a' in build phase 'Link Binary'" and "… 'CoreLib' … via options
  '-lCoreLib' in build setting 'OTHER_LDFLAGS'"; the `.app` matches the Mac build with no gaps.
- **HelloRN** (prebuild + `pod install` on Linux, then the generated PIF): the target graph (96 targets) resolves,
  including the app → `Pods-HelloRN` (via `libPods-HelloRN.a`) and app → `HelloExtension` (via the `.appex` in Copy
  Files) implicit dependencies. Then:
  1. planning needs an `ibtool` that answers `--version` (the Expo splash storyboard; Task 6);
  2. `/bin/sh` must be bash: Ubuntu's is dash, and React Native's script phases (`shellPath /bin/sh`) use `source`
     (`with-environment.sh: source: not found`); macOS's `/bin/sh` is bash;
  3. with both, the build runs the React Native / Hermes / Expo xcframework switch scripts and `[CP] Copy XCFrameworks`,
     and stops at `[CP-User] Build ExpoModulesJSI xcframework` (nested `xcodebuild`, see "Build-time notes").

## Tool shims (Task 6a)

Swift Build runs Xcode's tools by name (`actool`, `ibtool`, from `PATH`) and the CocoaPods / React Native / Expo / React
Native Firebase build phases run `lipo`, `otool` (also through `xcrun`) and `/usr/libexec/PlistBuddy`. In the
`xless-rn` image these are thin scripts (`docker/shims`) that run `xless shim <tool>`; each implements exactly the
command lines measured here and refuses anything else with exit 70 and the argv (the `XcrunShim` pattern), so an
unmeasured call fails the build loudly instead of being guessed. Expected outputs were taken black-box from Xcode 27.0
(27A266a) tools on our own inputs (`DEVELOPER_DIR=~/.cache/xless/Xcode.app/Contents/Developer`); argv shapes from
swift-build `swift-6.4.0-RELEASE` (`SWBApplePlatform/AssetCatalogCompiler.swift`, `InterfaceBuilderShared.swift`,
`Specs/AssetCatalogCompiler.xcspec`, `IBStoryboardCompiler.xcspec`, `IBStoryboardLinker.xcspec`).

### actool (`ActoolShim`, `AssetSymbols`)

Swift Build calls it in four forms (argv in "Tools Swift Build invoked" above):

| Call | Answer |
|---|---|
| `--version --output-format xml1` (planning) | `com.apple.actool.version` = `{bundle-version 25098, short-bundle-version 27.0}`, actool 27.0's XML |
| `--print-asset-tag-combinations --output-format xml1 <catalogs>` (planning) | `com.apple.actool.asset-tag-combinations` = `[]`; a set with `on-demand-resource-tags` gets a `com.apple.actool.errors` answer (exit 1) |
| `GenerateAssetSymbols` (the compile flags plus `--bundle-identifier`, `--generate-swift-asset-symbol-extensions NO`, `--generate-swift-asset-symbols`, `--generate-objc-asset-symbols`, `--generate-asset-symbol-index`) | only the three symbol files; actool writes no car, no partial Info.plist and no dependency info in this form, and neither does the shim |
| `CompileAssetCatalogVariant thinned` (and `unthinned`, which only runs for previews) | `Assets.car` + loose icons into `--compile`, `--output-partial-info-plist`, `--export-dependency-info` |

Compile: the catalogs (Swift Build passes all of a target's catalogs to one call; they are merged, a name in two of
them is refused) go through `AssetsStage.compileIOSCatalog`, the `assets` stage's own path: AssetKit, the app icon as
Xcode's single-size form from its 1024 px image (a multi-size set uses its marketing/1024 image, m2b R18), the opaque
check (ITMS-90717). Matched behaviours, each checked against actool:

- `--app-icon NAME` compiles that set and writes `NAME60x60@2x.png` and `NAME76x76@2x~ipad.png` (always both) and the
  `CFBundleIcons`/`CFBundleIcons~ipad` keys, with `CFBundleIconName` only for the `--target-device` families. Without
  `--app-icon` the icon set is left out (no loose files, `{}`); a catalog with no other set gives no `Assets.car`.
  A missing set: exit 1, actool's message ("None of the input catalogs contained a matching stickers icon set, app
  icon set, or icon stack named  "NAME"." — two spaces).
- `--accent-color NAME`: `NSAccentColorName` when the color set exists, else actool's warning
  (`<catalog>: warning: Accent color ‘NAME’ is not present in any asset catalogs.` under `/* com.apple.actool.notices */`);
  Expo's template sets `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor` without such a set.
- `--compile` must exist (actool: "The output directory … does not exist."; Swift Build creates it).
- Dependency info: `\0actool-25098\0`, `0x10 <catalog>\0` per input, `0x40 <path>\0` per output (partial plist, loose
  icons, `Assets.car`); stdout `/* com.apple.actool.compilation-results */` + the same outputs + an empty line. Both
  identical to actool's for HelloPIF and a test catalog (paths aside).
- Errors are actool-style (`<catalog>: error: <cause>` under `/* com.apple.actool.errors */` on stdout, exit 1), which
  Swift Build's output parser turns into build errors; xless's cause and fix go to stderr (`xless actool shim: [assets] …
  — <fix>`), as for ibtool.

Asset symbols: the Swift file decides autolinking (an empty one lost `libswiftCoreAudio`, G2), so it reproduces
actool's. Below iOS 17 it imports Foundation and, each behind `canImport`, AppKit, UIKit, SwiftUI and
DeveloperToolsSupport, and declares `ColorResource`/`ImageResource` plus the NSColor/NSImage/UIColor/UIImage/Color/Image
initialisers; from iOS 17 it imports only Foundation and DeveloperToolsSupport and extends that module's types (so an
iOS 17 target links fewer overlays than a 16.4 one, as with Xcode). The Swift, Objective-C and index files are
byte-identical to actool 27.0's for HelloPIF's catalog and a 6-set test catalog (group folder, accent color) at
deployment targets 16.0, 16.4, 17.0 and 18.2, and for a catalog of 19 tricky names as both color and image sets
(camel-case splitting, acronyms, digits, the dropped trailing `Color`/`Image` word, keywords in backticks, `_` before a
leading digit, the `#warning` actool writes when two names map to one symbol) except for its one non-ASCII name (below).
Assets are sorted by name in byte order; group folders flatten. The name table is in `AssetSymbolsTests`.

Refused (exit 70): flags outside the table (e.g. `--include-all-app-icons`, `--alternate-app-icon`,
`--standalone-icon-behavior`, `--filter-for-device-model`, `--asset-pack-output-specifications`), `--platform` other than
`iphoneos`, `--target-device` other than `iphone`/`ipad`, `--output-format` other than `human-readable-text` for compiles,
symbol generation with Swift asset symbol *extensions* (`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS =
YES`, Xcode's new-project default; React Native / Expo projects do not set it), inputs other than `.xcassets`.
Refused as tool errors (exit 1): folders that provide a namespace (AssetKit does not namespace names), app icon sets
inside folders (with or without `--app-icon`), more than one app icon set, asset types AssetKit cannot write. Deviation: a name outside ASCII letters,
digits, space, `-`, `_` gets no symbol (actool writes e.g. `über`) and a warning naming it.

### ibtool (`IbtoolShim`)

- `--version --output-format xml1`: `com.apple.ibtool.version` = `{25098, 27.0}` (Swift Build probes it while
  planning any target with a storyboard).
- CompileStoryboard (`--errors --warnings --notices --module M --output-partial-info-plist P
  --auto-activate-custom-fonts --target-device … --minimum-deployment-target V --output-format human-readable-text
  <in>.storyboard --compilation-directory D`, or `--compile <out>.storyboardc`): `StoryboardCompiler`, output
  `D/<name>.storyboardc`, partial Info.plist `<dict/>`, nothing on stdout. LinkStoryboards (`… --link <dir>
  <in>.storyboardc…`): a copy (ib-invocation.md: byte-identical for a single storyboard; the directory is created).
  For the HelloShipLaunch storyboard the compile and link outputs, partial plist and version answer are byte-identical
  to ibtool 27.0's through the same two command lines.
- A storyboard outside the compiler's subset: exit 1, `/* com.apple.ibtool.errors */` + `<storyboard>: error: <cause>`
  on stdout (a Swift Build error) and `xless ibtool shim: [ib] <cause> — <fix>` on stderr. Expo's
  `SplashScreen.storyboard` stopped here until Task 6b widened the subset; it now compiles and links to ibtool's bytes
  (`expoSplashScreenCompilesLikeIbtool`).
- Refused (exit 70): `--flatten`, `--companion-strings-file`, `--platform`, `--compilation-mode-for-ios`, other
  options, `.xib`, more than one output form, `.lproj` (localized) inputs.

### PlistBuddy (`PlistBuddyShim`, `/usr/libexec/PlistBuddy`)

`-c` commands (repeatable) on one file: `Print [entry]`, `Set entry value`, `Add entry
string|bool|integer|real|array|dict [value]`, `Delete entry`; entries are `:key` / `:array:index` paths (`:array:`
appends). Matches `/usr/libexec/PlistBuddy` for the Expo dev-launcher "Strip Local Network Keys" phase and React
Native Firebase's `ios_config.sh` (`Add :key string '…'`, `Add :key bool 'YES'`): `Print` formats (`Array {` with
4-space indents, `true`/`false`, `%f` reals), the error messages (`Print: Entry, ":k", Does Not Exist`, `Add: ":k" Entry
Already Exists`, `Set: Cannot Perform Set On Containers`) on stderr with exit 1, later commands still run, the file is
rewritten as XML when changed (also a binary Info.plist, as PlistBuddy does), a missing file is reported (`File Doesn't
Exist, Will Create: …`) and created only by an edit. Deviations: `Print` of a dictionary lists keys sorted
(PlistBuddy: hash order); stdout is written before stderr. Refused (exit 70): other commands (`Merge`, `Import`,
`Copy`, `Save`, …), options (`-x`, `-l`), interactive mode, `date`/`data` values, escaped (`\:`) or quoted entries.

### lipo, otool, xcrun

`xcrun [--sdk S] <tool> args…` now runs LLVM's Mach-O-aware binutils for `lipo`, `otool`, `nm`, `ar`, `ranlib` and
`libtool` (`llvm-lipo`, `llvm-otool`, `llvm-nm`, `llvm-ar`, `llvm-ranlib`, `llvm-libtool-darwin`; previously refused),
plus exactly `swiftc --version` (Expo's ExpoModulesJSI build script). Compilers with any other arguments (`xcrun clang
-c …`, `xcrun --sdk iphoneos swiftc x.swift`) and `strip` stay refused (exit 70): run without the SDK's target and
sysroot they would silently produce Linux host output. `lipo`/`otool` on `PATH` go through the same map, because
CocoaPods' `Pods-<App>-frameworks.sh` calls `lipo -info` / `lipo -remove` by name and `xcrun otool -LX`. Ubuntu jammy
installs LLVM 14's tools only as `llvm-lipo-14`/`llvm-otool-14`, so the image links the unsuffixed names to exactly
those (the image build fails if they are missing). Checked on a Mach-O:
`lipo -info` prints Apple's `Non-fat file: … is architecture: arm64` (the script's `rev | cut -d: -f1` gives `arm64`);
`otool -LX` lists the load commands without the header line.

### `/bin/sh` is bash

Ubuntu's `/bin/sh` is dash. React Native's script phases (`shellPath /bin/sh`) and the scripts they run with
`/bin/sh -c` (`with-environment.sh` uses `source`) need bash, which macOS's `/bin/sh` is. A PIF `shellPath` override
would not reach the nested `/bin/sh -c` calls, so the `xless-rn` image switches `/bin/sh` to bash with Debian's own
mechanism (`dash dash/sh boolean false` + `dpkg-reconfigure dash`, which survives dash upgrades). Only `xless-rn`
changes; `xless-tauri` keeps dash.

### Results (xless-rn, G2 environment)

- **HelloPIF with its asset catalog** (gated test `helloPIFWithAssetCatalogMatchesTheMacReference`, `XLESS_SWBUILD_IT=1`):
  PIF writer + stock `swbuild` + the image's `actool`, no stand-in; `GenerateAssetSymbols` and `CompileAssetCatalogVariant
  thinned` run through the shim; the `.app` matches `samples/HelloPIF/reference/reference.json` with **no** allowed gaps
  (`Assets.car`, both loose icons and `CFBundleIcons`/`CFBundleIcons~ipad` equal; `libswiftCoreAudio` linked).
  `allowed-gaps.txt` is now empty.
- **HelloRN** (Task 5's Linux prebuild + `pod install` work copy): planning passes (actool and ibtool probes answered).
  The build stops, as in Task 5, at `[CP-User] Build ExpoModulesJSI xcframework` (nested `xcodebuild`, Task 7). With
  `continueBuildingAfterErrors` it also shows:
  - the app's `GenerateAssetSymbols`, `CompileAssetCatalogVariant thinned` and `LinkAssetCatalog` succeed;
  - `CompileStoryboard SplashScreen.storyboard` fails with the subset refusal (fixed in Task 6b; see "Launch screen");
  - Expo module Swift compiles fail on `no such module 'ExpoModulesJSI'` (then "failed to build module
    'ExpoModulesCore'; this SDK is not supported by the compiler (… Apple Swift version 6.3.1 …)" for the precompiled
    module's interface) — follows from the missing JSI xcframework (Task 7);
  - **new:** copying `HelloExtension.appex` into `PlugIns` strips its executable (`COPY_PHASE_STRIP = YES` in Expo's
    project-level Release configuration) with `/usr/bin/strip -D -S -no_atom_info … -o …`. Swift Build resolves `strip`
    in the toolchain (`/`) before `PATH`, so it runs GNU strip, which fails on Mach-O. Needs an answer in Task 7 (e.g.
    a Mach-O-aware strip in the toolchain directory, or `COPY_PHASE_STRIP = NO` with the strip done elsewhere).
- **Acceptance workspace** (read-only work copy, Task 5's PIF): planning now completes (build description created; the
  only error is swbuild's "-dry-run is not yet supported" for the dry-run request). The `actool` shim compiles its
  catalog (single-size icon, a color set, an image set; the `AccentColor` warning above), and its symbol file declares
  the two sets.
- Not exercised: `codesign` (signing off), `PlistBuddy`/`lipo`/`otool` inside a full build (the phases that call them
  run after the Task 7 stops; each was run on real inputs separately).

## Gate G3/G4: the workspace builds and links on Linux (Task 7)

Swift Build builds a prepared React Native / Expo workspace (after gate G1's `expo prebuild` + `pod install` on
Linux) for `iphoneos` in the `xless-rn` image: a linked app with its embedded `.appex`, the embedded frameworks, and
`main.jsbundle` as Hermes bytecode from the Linux `hermesc`. No step is skipped or stubbed: every build phase runs
(React Native bundle phase, CocoaPods resources/frameworks/xcframework phases, Expo's switches and its nested
ExpoModulesJSI package build, React Native Firebase's configuration), every target compiles and links.
The procedure was a hand-run spike script, `scripts/spikes/rn-workspace-linux.sh <workspace> <scheme> <derived data>`;
Task 8 turned it into the build stage, and Task 10 removed the script (it `eval`ed the Pods' `install_xcframework`
lines, which the build stage parses as shell words instead; see it in git history, commit 694d524). The regression is
`scripts/test-rn-linux.sh` (`make test-rn-linux`): HelloRN from a fresh prepare, then again with `--network none`.

### Results

Both on the rebuilt `xless-rn:local-arm64`, from clean derived data, with the Expo/React Native release switches and
ExpoModulesJSI's nested package build forced to run (arm64 Colima VM, 8 CPUs):

- **HelloRN** (the public regression; Task 5's Linux prebuild + `pod install` work copy), `--network none`: 743 tasks,
  45 s. `xless tauri compare` against `samples/HelloRN/reference/reference.json` exits 0 for the app and against
  `reference-appex.json` for `HelloExtension.appex`, with no allowed gaps (executables, linked libraries, rpaths,
  embedded frameworks, every file, Info.plists). `main.jsbundle` is Hermes bytecode version 98 (magic
  `c6 1f bc 03 c1 03 19 1f`). The ExpoModulesJSI framework the shim built: 502,020 bytes, the same 979 exports as the
  Mac's (508 KB).
- **The acceptance app** (G1's work copy; staging scheme; 265 targets in 6 projects incl. 4 Swift package projects):
  6,422 tasks, 372 s including 9 s to clone and dump its Swift package. Linked arm64 `MH_EXECUTE` app (platform iOS,
  minos 16.4, SDK 27.0, 99 libraries) and extension (minos 17.0, 27 libraries); 17 embedded frameworks; `PlugIns/` holds
  the `.appex`; `main.jsbundle` (24.8 MB) is Hermes bytecode version 98; `BundleReport` of the app and of the extension
  produced without error. Every build phase ran, none with a missing command; no `CodeSign` task.
- Product names: each native target's PIF product name is a product Swift Build built (HelloRN 18/18, acceptance app
  142/142).
- Not compared against a Mac build: the acceptance app (its Mac reference is Task 10's). Not exercised: signing
  (Task 9).

### What each fix is for

In build order. "xless" fixes are code with tests (`XlessXcode`, `XlessCore`, `XlessAssets`) and image changes
(`docker/Dockerfile`, `docker/react-native/Dockerfile`, `docker/shims`); "env" fixes are build settings or environment that Task 8 sets.

**Swift packages** (xless: `xless xcode packages`). The extension of the acceptance app uses one remote package pinned
to a revision. Each is cloned at its revision into a directory named by its identity, and its PIF dumped with
`swift package --build-system swiftbuild --experimental-build-dylibs-as-frameworks --disable-local-rpath dump-pif`
(`XcodebuildShim.dumpPIFArguments`): `--experimental-build-dylibs-as-frameworks` makes dynamic library products
frameworks in `PackageFrameworks/` (Xcode's layout); `--disable-local-rpath` drops the `@loader_path` rpath SwiftPM adds
for `swift run` (Xcode does not; with it the ExpoModulesJSI framework had one rpath more than the Mac's). The
package's own dependencies are resolved by SwiftPM during `dump-pif` (network, prepare time); a CNG workspace has no
`Package.resolved`, so they resolve to the newest allowed versions, as in Xcode; one that has it (`xcshareddata/swiftpm`)
pins them, through a copy in the root package. Requirements other than a revision pin
are refused. The PIF is dumped from an empty root package that depends on the checkout (`.package(path:)`), not in
the checkout: with one root package SwiftPM materializes the root's library products as static archives
(`lib<product>.a`, which the extension then linked as an archive: only referenced members, 548 KB), while a dependency's
library product is a `packageProduct`, whose clients link the package targets' objects as Xcode does (each prelinked
`<target>.o`, force-loaded by the linker shim: 715 KB). The product GUIDs are the same either way.

**Nested `xcodebuild`** (xless: `xless shim xcodebuild`, `docker/shims/xcodebuild`). `expo-modules-jsi`'s
`build-xcframework.sh` runs, from the package directory, under `env -i` (PATH, HOME, PODS_ROOT, RN_ROOT kept):

```
xcodebuild build -scheme ExpoModulesJSI -sdk iphoneos -destination generic/platform=iOS -derivedDataPath <pkg>/.DerivedData
  -configuration Release -quiet -disableAutomaticPackageResolution -skipPackagePluginValidation -skipMacroValidation
  -parallelizeTargets SYMROOT=<dd>/Build/Products OBJROOT=<dd>/Build/Intermediates.noindex BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  SKIP_INSTALL=NO DEBUG_INFORMATION_FORMAT=dwarf-with-dsym COMPILER_INDEX_STORE_ENABLE=NO SWIFT_COMPILATION_MODE=wholemodule
  CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
```

then copies `Build/Products/Release-iphoneos/PackageFrameworks/ExpoModulesJSI.framework`, `ExpoModulesJSI.swiftmodule`,
the `.framework.dSYM` and `Intermediates.noindex/GeneratedModuleMaps-iphoneos/ExpoModulesJSI-Swift.h` into the
xcframework and writes its `Info.plist` itself (no `-create-xcframework`). It also runs `xcrun swiftc --version` for its
cache key (already answered by the xcrun shim). The shim answers exactly this form (any `NAME=VALUE` settings, the four
no-op flags above) and `-version` (`Xcode 27.0` / `Build version 27A266a` from the SDK metadata, which `pod install`
needs too): it dumps the package PIF (above), builds the target SwiftPM names `<scheme>-product` with `swbuild` in the
same environment as the app (below; the shim script restores the image variables `env -i` removed), with the
command-line settings and `SDKROOT=iphoneos` on top, and prints the build's warnings and errors (exit 65 on failure).
The products land where the script reads them. Refused (exit 70): other actions (`archive`, `-showBuildSettings`,
`-create-xcframework`), `-workspace`/`-project`, other SDKs or destinations, a relative or missing
`-derivedDataPath`, a directory holding an Xcode project. Parity: the built `ExpoModulesJSI.framework` binary is
502 KB stripped (Mac: 508 KB), same install name and libraries.

**`<swift/bridging>`** (xless: image `XLESS_TOOLCHAIN_INCLUDE`; env: `OTHER_CFLAGS`, `OTHER_CPLUSPLUSFLAGS`,
`OTHER_SWIFT_FLAGS`). Apple's clang searches its toolchain's `usr/include` after the SDK's (`clang -v`: `…/
XcodeDefault.xctoolchain/usr/include` last); the open-source clang does not add `<install>/../include`. ExpoModulesJSI's
C++ headers include `<swift/bridging>`, which lives there, with a top-level `module.modulemap` that makes it the
`SwiftBridging` module. The image copies `swift/bridging` and `swift/bridging.modulemap` from its own Swift 6.4 toolchain
(identical to Xcode 27's) and writes the one-line `module.modulemap`; every compile gets `-idirafter` that directory.
Without the module map the header was included textually and the C++ types it annotates were attributed to `__ObjC`.

**`AssumeResilientCxxTypes`** (env: `OTHER_SWIFT_FLAGS`). ExpoModulesJSI is built with library evolution and
`extension expo.CppError: Error { public var message … }`. Open-source Swift 6.4 rejects that ("C++ types from imported
module '__ObjC' do not support library evolution"); Xcode 27's Swift 6.4 (swiftlang-6.4.0.34.1) compiles it, also with
`-disable-experimental-feature AssumeResilientCxxTypes`, and also in a five-line repro (a C++ class with a `std::string`
member, a public extension). The check is the same in the open-source 6.3, 6.4.0, 6.4.1 and main sources;
`AssumeResilientCxxTypes` is the switch that turns exactly this diagnostic off (`UNINTERESTING_FEATURE`, no effect on
code or interfaces).

**Prelinked package targets** (xless: `xless-ld64`, `LinkerShim`, the toolset). Swift Build links each package target
`-r` into `<target>.o` (`MACH_O_TYPE = mh_object`), and links the product from those. `ld64.lld` has no `-r`
("Option `-r' is not yet implemented"); the SDK's xtool trampoline writes an `ar` archive instead. Linked as an archive
the members only load when referenced, and a dynamic framework built from them references nothing: the first
ExpoModulesJSI framework was 16 KB with no Swift symbols, and the app failed to link (19 undefined `$s14ExpoModulesJSI`
symbols). The linker shim passes each `*.o` input that is an archive (also in `-filelist`) as `-force_load <path>`,
which loads it as the object it stands for. Swift Build applies a toolset's `linker` after command-line overrides, so
`ALTERNATE_LINKER_PATH` cannot be overridden; xless writes its own toolset (`SwiftBuildEnvironment.toolset()`: the SDK's
`llvm-lib` librarian, the shim as linker) and passes it as `SWIFT_SDK_TOOLSETS`.

**`strip`** (xless: `xless shim strip`, `docker/shims/swift-build/strip`; env: `__XCODE_BUILT_PRODUCTS_DIR_PATHS`;
image: LLVM 21 `llvm-strip`). Swift Build resolves `strip` through its executable search paths, built-products
directories from `__XCODE_BUILT_PRODUCTS_DIR_PATHS` first, then the toolchain (`/usr/bin`: GNU strip), then `PATH`
(`Core.createExecutableSearchPaths`), and runs it in two forms seen here: the copy phase's `strip -D -S -no_atom_info
<src> -o <dst>` (embedding the `.appex` with `COPY_PHASE_STRIP = YES`, Expo's project Release setting; builtin-copy
`-strip-tool`), and the `Strip` task `strip -D -S -T <binary>` (the nested ExpoModulesJSI build's framework). The
environment puts `<shims>/swift-build` first; its `strip` accepts exactly those two option sets (in any order) and runs
`llvm-strip -D -S <src> -o <dst>` / `llvm-strip -D -S -T <file>` (Mach-O images; archives only in the second form, as
measured; `-no_atom_info` dropped after checking the input has no `LC_ATOM_INFO`, which `ld64.lld` never writes). Any
other option set, `-x` included, is refused (exit 70). It must be
LLVM 21's, the toolchain's own (the same LLVM as `ld64.lld`), whose output is closest to Apple's: on the
ExpoModulesJSI framework below, 502,020 bytes against Apple's 502,056 and LLVM 14's 563,020. xless-tauri's `llvm`
package replaced the Swift toolchain's `/usr/bin/llvm-objcopy` with LLVM 14's, so the image copies the Swift image's
`llvm-objcopy` to `/opt/xless/llvm/bin` (`llvm-strip` is a link to it). Checked against Xcode's `strip` on the same unstripped inputs:
- `-D -S` (the appex): the same 87 symbols; Apple's string table is 40 bytes longer.
- `-D -S -T` (ExpoModulesJSI, 850,528 bytes unstripped): 502,020 bytes (Apple: 502,056), the same 979-entry export trie.
  Apple's `-T` removes local and undefined `$s` symbols from the symbol table and keeps the 976 exported ones; LLVM's
  removes the exported ones from the symbol table too (8 external symbols left). Linkers and dyld read exports from the
  trie (the app links against this framework), so only `nm` sees the difference. Without `-T`, LLVM keeps 819 local
  Swift symbols Apple removes (745,924 bytes).
- An archive (`strip -D -S -T lib<package>.a`, a Swift package's static library product): each member stripped; the
  local assembler symbols kept differ from Apple's. `PBXCP_STRIP_TOOL` cannot help: builtin-copy inserts its resolved `strip`
after the setting's `-strip-tool`.

**`embeddedBinaryValidationUtility`** (xless: `xless shim embedded-binary-validation`, `swift-build/`). Swift Build
validates each `.appex` copied into the app (`ValidateEmbeddedBinary`, `<appex> -info-plist-path <app Info.plist>`),
resolving the tool like `strip`. The shim makes Xcode 27's checks with its messages (black-box): the extension's bundle
identifier must start with the app's (plain prefix; error, exit 1, Xcode's two-line detail), else a different
`CFBundleVersion`, else a different `CFBundleShortVersionString`, is a warning (`('x')`, or `(null)` when missing; only
the first). A non-empty `-signing-cert` is refused (signing is xless's sign stage).

**`ditto`** (xless: `xless shim ditto`, on `PATH`). Every Swift pod's "Copy generated compatibility header" phase
`ditto`s the `-Swift.h`, the module map and the umbrella header into the build directory, then appends the `.Swift`
submodule. Without `ditto` the phase still exits 0 (no `set -e`) and leaves a module map with only the submodule; the
next compile fails with "no module named 'EXConstants' found, parent module must be defined before the submodule" and
"redefinition of module 'Swift'". macOS `ditto` black-box: a file source is followed through symbolic links, copied
with parents created and mode and mtime kept; into an existing directory it takes the name of the file the link
resolves to; a directory source is merged into the destination, links inside kept. `xless xcode swbuild` now reports
any "command not found" line of a build phase, the only trace such failures leave.

**`copypng`** (xless: `xless shim copypng`, on `PATH`). Swift Build's `CopyPNGFile` rule is synthesized for every
`.png` resource, so `copypng` runs whatever `COMPRESS_PNG_FILES`/`STRIP_PNG_TEXT` say (`copypng -compress
-strip-PNG-text <in> <out>` by default). Xcode's `copypng` with either option writes iPhone-optimized PNGs for 8-bit RGB
and RGBA (black-box on generated probes and a pod's PNG): BGRA with premultiplied alpha `(c·a + 127) / 255`, color type
6 even for RGB input, raw deflate, a `CgBI` chunk `50 00 20 02` (RGBA source) or `50 00 20 06` (RGB) before `IHDR`,
text chunks dropped; 16-bit RGB and RGBA (also gray, measured but not taken) are left as they are, text chunks
included, with libpng's warning; no option is a plain copy. The shim does that with
swift-png; decoded, its output equals Xcode's for all 65,536 RGBA (color, alpha) pairs and for the pod's PNG (the
compressed bytes differ). Refused: gray and palette input at any bit depth, interlaced input and ancillary chunks other
than text, also at 16 bits (pngcrush adds `cHRM` to `sRGB` images, reorders chunks and drops `tRNS` from RGB: not
reproduced).

**Case-insensitive lookups** (xless: image; env/build-time: framework aliases). macOS file systems are
case-insensitive; Linux's are not. Two cases in the acceptance app:
- `#include <endian.h>` (react-native-quick-crypto's fastpbkdf2): the iOS SDK has `usr/include/Endian.h` only. The
  image adds, in every SDK's `usr/include`, an all-lowercase symbolic link for each header whose name has capitals
  (107 in iPhoneOS27.0), unless that name exists.
- `#include <openssl/bio.h>` against `OpenSSL.framework` (`OpenSSL-Universal` pod) through `FRAMEWORK_SEARCH_PATHS`.
  Before the build, each vendored xcframework CocoaPods installs (`install_xcframework` lines of the Pods'
  `*-xcframeworks.sh`) gets a lowercase link next to where `[CP] Copy XCFrameworks` will put it
  (`XCFrameworkIntermediates/<pod>/openssl.framework -> OpenSSL.framework`; that script's `rsync --delete` does not touch
  it).

**`-Wdocumentation` crash** (env: `CLANG_WARN_DOCUMENTATION_COMMENTS = NO`). The toolchain's clang 21 (swiftlang
`903b9faa`) crashes with SIGSEGV in `ASTContext::getRawCommentForDeclNoCacheImpl` (from `attachCommentsToJustParsedDecls`
at the end of an `@implementation`) on one Objective-C++ file of a React Native Firebase module; deterministic, also
without the VFS overlays, gone with `-Wno-documentation`. The setting only adds warnings; but with
`GCC_TREAT_WARNINGS_AS_ERRORS = YES` a documentation warning fails Xcode's build and not xless's (no such project here).

**`ld64.lld` crash on prelinked objects** (xless: `LinkerShim`). Linking the app crashed `ld64.lld` 21 (SIGSEGV,
`ObjCMethListSection::setUp` → `Reloc::getReferentString`, from the symbolized Swift-toolchain `lld`). Delta debugging
the 176 libraries and frameworks: `-framework MLKitBarcodeScanning` alone, whose arm64 slice is one prelinked
`MH_OBJECT` without `MH_SUBSECTIONS_VIA_SYMBOLS`; it crashes alone in a `-dylib` link, thin or fat, as an object or an
archive; setting the flag avoids it, ignoring linker optimization hints does not. `lld` converts method lists to
relative ones by default (as Xcode's linker: both apps have `__TEXT,__objc_methlist`). The shim adds
`-no_objc_relative_method_lists` to a link that names such a framework (resolved through its `-F` paths), so only that
binary keeps pointer-based method lists, which the Objective-C runtime reads the same way. Setting the flag on the
object would let `-dead_strip` split code that may fall through between symbols, so it is not done. Gap: only
`-framework` binaries are checked; an object without subsections inside an archive (`-l`, a `.a` input, or a
`-filelist` entry) is not, and would crash the link the same way (not seen so far).

**Swift libraries of the toolchain** (env: `SWIFT_LIBRARY_PATH`). With the toolchain at `/`, Swift Build looks for the
platform's Swift libraries in `/usr/lib/swift/iphoneos` (absent; "directory not found"). Xcode links
`<toolchain>/usr/lib/swift/iphoneos`, which holds `libswiftCxx.a`, `libswiftCxxStdlib.a` and the back-deployment
`libswiftCompatibility*.a` that Swift objects autolink. Modules using C++ interop (Nitro modules) need `libswiftCxx.a`
(`$s3Cxx0A8SequenceMp` undefined). `SWIFT_LIBRARY_PATH = <bundle>/Developer/Toolchains/XcodeDefault.xctoolchain/
usr/lib/swift/$(PLATFORM_NAME)` points there (the SDK bundle has them).

**Hermes** (env: build setting `HERMES_CLI_PATH`). React Native's post-install writes `HERMES_CLI_PATH` (the npm
`hermes-compiler`'s macOS `osx-bin/hermesc`) into the project; build settings are exported to script phases and beat the
process environment, so the override must be a build setting: `HERMES_CLI_PATH = /usr/local/bin/hermesc`.
`react-native-xcode.sh` then compiles the Metro bundle with it (`-emit-binary -O`).

**`TAR_OPTIONS` at build time** (env). Expo's `[Expo] Switch <Pod> XCFramework` phases extract the release tarballs
with `tar`; without G1's `TAR_OPTIONS=--warning=no-unknown-keyword --exclude=._*` the app embedded AppleDouble `._*`
files. Swift Build passes its process environment to script phases (unlike build settings, nothing overrides it).

### Carry items from earlier tasks

- **Swift 6.3.1 vs 6.4.** Expo's precompiled frameworks (`ExpoModulesCore` and others) carry `.swiftinterface`s next to
  Apple Swift 6.3.1 binary modules. The open-source 6.4 compiler rebuilds the modules from the interfaces; Task 6a's
  "SDK is not supported by the compiler" was a consequence of the missing ExpoModulesJSI module, gone once it is built.
  `EXPO_USE_PRECOMPILED_MODULES` stays at its default (true): no `pod install` change.
- **Network.** None at build time (HelloRN built with `--network none`); release tarballs come from `pod install`
  (corrected above); remote Swift packages are cloned and resolved before the build.
- **`lipo`/`otool`/`file` in phases.** `[CP] Embed Pods Frameworks` decides with `file` whether a framework binary is
  a dylib (then `lipo -info`, `strip_invalid_archs`) or a dSYM; the image lacked `file` (the only "command not found"
  of the acceptance build, which silently skipped those branches) and now has Ubuntu's, whose descriptions contain the
  phrases the script matches. All embedded frameworks here are thin arm64, so nothing is removed.
- **Product names** (PIFWriter's literal-`PRODUCT_NAME` rule). Every native target's PIF product name matches a product
  Swift Build built (HelloRN 18/18, acceptance app 142/142): CocoaPods writes the real name as the
  product path, so the fallback does not bite.
- **`JSON(foundation:)`.** The package PIFs here (ExpoModulesJSI, the extension's package and its three dependencies)
  contain only strings, objects and arrays: no booleans, numbers or nulls to mistranslate. Not changed.
- **Signing.** With `CODE_SIGNING_ALLOWED = NO`, `[CP] Embed Pods Frameworks` skips `/usr/bin/codesign`
  (`code_sign_if_enabled` needs an identity and `CODE_SIGNING_ALLOWED != NO`) and Swift Build plans no `CodeSign` task.

### Overrides and environment Task 8 sets

`SwiftBuildEnvironment` holds these (Task 8 calls `SwiftBuildRunner` with it); `<B>` is the Darwin SDK bundle
(`/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle`), `<S>` the image's shim directory (`/opt/xless/shims`),
`<dd>` the derived data.

| Build setting (request's command-line table) | Value | Why |
|---|---|---|
| `SWIFT_SDK_TOOLSETS` | `<dd>/xless/toolset.json`: `rootPath <B>/toolset/bin`, `librarian llvm-lib`, `linker <S>/xless-ld64` | G2 (librarian, `ld64.lld`); the linker shim (prelinked package targets, MLKit) |
| `CODE_SIGNING_ALLOWED` | `NO` | signing is the sign stage (Task 9) |
| `LM_SKIP_METADATA_EXTRACTION` | `YES` | G2: no `appintentsmetadataprocessor` |
| `GENERATE_INTERMEDIATE_TEXT_BASED_STUBS` | `NO` | G2: no `tapi` |
| `STRIP_BITCODE_FROM_COPIED_FILES` | `NO` | G2: no `bitcode_strip` |
| `SWIFT_STDLIB_TOOL_STRIP_BITCODE` | `NO` | G2 |
| `OTHER_CFLAGS`, `OTHER_CPLUSPLUSFLAGS` | `$(inherited) -idirafter /opt/xless/toolchain/usr/include` | `<swift/bridging>` |
| `OTHER_SWIFT_FLAGS` | `$(inherited) -Xcc -idirafter -Xcc /opt/xless/toolchain/usr/include -enable-experimental-feature AssumeResilientCxxTypes` | the same for Swift's Clang importer; C++ types in resilient modules |
| `SWIFT_LIBRARY_PATH` | `<B>/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$(PLATFORM_NAME)` | `libswiftCxx.a`, `libswiftCompatibility*.a` |
| `CLANG_WARN_DOCUMENTATION_COMMENTS` | `NO` | clang 21 crash |
| `HERMES_CLI_PATH` | `/usr/local/bin/hermesc` | React Native only (not in `SwiftBuildEnvironment`): Hermes bytecode from the Linux `hermesc` |

| Environment of `swbuild` | Value | Why |
|---|---|---|
| `SDKROOT` | unset | G2 |
| `XCODE_EXTRA_PLATFORM_FOLDERS` | `<B>/Developer/Platforms` | G2: the iOS platform |
| `PATH` | `<B>/toolset/bin:` + the image's (shims first) | G2; `ditto`, `copypng`, `xcodebuild`, `lipo`, `otool`, `actool`, `ibtool` |
| `__XCODE_BUILT_PRODUCTS_DIR_PATHS` | `<S>/swift-build` | `strip`, `embeddedBinaryValidationUtility` found before `/usr/bin` |
| `TAR_OPTIONS` | `--warning=no-unknown-keyword --exclude=._*` | Expo's xcframework switches |
| `XLESS_LLVM_STRIP` | unset; the strip shim's default is `/opt/xless/llvm/bin/llvm-strip` | override only for tests |

A freshly prepared work copy needs no cleanup before its first build (checked on a new G1 copy of the acceptance app:
the seven Expo `artifacts/.last_build_configuration` say `debug`, React Native's three have none, ExpoModulesJSI's
`.build-hash` is the empty stub file, and `Pods/` holds no `._*` file because `pod install` ran with `TAR_OPTIONS`), so
every switch and the package build run. Removing those markers and `._*` files (as the Task 7 runs did) is only needed
to force them again on a copy that was already built, or one prepared without `TAR_OPTIONS`. That fresh copy built with
no cleanup: 6,422 tasks, 361 s, the same structure (17 frameworks, the `.appex`, Hermes bytecode 98).

Before `swbuild`: clone the Swift packages (`xless xcode packages`) and dump each as the dependency of an empty root
package (the root's own `PACKAGE:` project is merged too, unused), and create the lowercase framework aliases in
`XCFrameworkIntermediates`. Image (`xless-rn`): the shims above, `/usr/libexec/PlistBuddy`, LLVM 21
`llvm-strip` in `/opt/xless/llvm/bin`, the toolchain headers (`XLESS_TOOLCHAIN_INCLUDE`), lowercase SDK header links,
`/bin/sh` = bash, `file`.

## The prepare and build stages (Task 8)

`Sources/XlessReactNative` runs the procedure above as the `prepare` and `build` stages of a `type: react-native`
overlay (`ReactNativeBuilder`; schema in `samples/HelloRN/xless.overlay.yml`). Both refuse to run outside the
`xless-rn` image.

**prepare.**
1. Contract: CocoaPods 1.15.2 and Bundler 2.7.2 from the nearest `Gemfile.lock` above `<app>/ios` in the source.
2. The work copy (tracked files only, `WorkCopy`, as for Tauri).
3. The JS install at the nearest directory with a lockfile (a monorepo installs at its root; pnpm's store is
   `<work root>/../.pnpm-store`, next to the work copies), from empty dependency trees after a toolchain change or
   with `XLESS_RN_CLEAN=1` (Ruling R6, below), then React Native 0.86.x and Expo SDK 57 checked as Node
   resolves them from the app, then the overlay's `prepare.run` commands (`sh -c`, in the work copy's root).
4. `node_modules/.bin/expo prebuild --platform ios --no-install` on an empty `ios/` (`CI=1`, `EXPO_NO_GIT_STATUS=1`),
   skipped when the app commits its native project (`ios/Podfile` or an `ios/*.xcodeproj` is tracked in git).
5. `bundle install` and `bundle exec pod install` in `ios/`, then `Pods/Manifest.lock` must equal `Podfile.lock`. With
   a committed native project this always runs (CocoaPods is quick when the pods are current).

Steps 4–5 run with the G1 environment: `SWIFT_*` removed, `TAR_OPTIONS`, and `<shims>/prepare` first on `PATH`,
which holds `command` (as a program) and the `clang` that retargets the stub-dylib compile to iOS
(`PrepareClangShim`; everything else reaches the host clang unchanged). The overlay's `env` applies to every step.
For a generated `ios/`, steps 4–5 are skipped when a SHA-256 of their inputs equals the one recorded after the last
successful prepare (`.xless/rn-prepare.json`) and the pods are installed: the source's `git ls-files -s` and
`git diff`; the overlay's `env`, `app.dir`, `configuration` and `prepare.run`; the xless version; and the toolchain
identity, hashed on its own: the image (`XLESS_IMAGE_ID`, which `scripts/docker-images.sh` bakes into the image from the commit
and `versions.env`), the running xless executable, `node --version`, the package manager's `--version`, `ruby -v` and
`bundle -v` (scheme `xless-rn-prepare-4`). Any change regenerates `ios/` from scratch, as `expo prebuild --clean`
would; `XLESS_RN_CLEAN=1` forces it. Only the overlay's `env:` is part of the fingerprint: a variable the app's tooling
reads from the host environment is not, so a name set in both is reported (the overlay's value wins).

**Toolchain change (Ruling R6).** Packages cache build outputs inside `node_modules`, keyed on their sources only:
`expo-modules-jsi/apple/scripts/build-xcframework.sh` keeps each xcframework slice under
`node_modules/…/expo-modules-jsi/apple/Products/` and keys it on a hash of its sources. After an image change (a
fixed strip shim), the slice the previous, broken toolchain had built was reused, and finalize's LINKEDIT validator
refused the app. A Mac has the same problem after an Xcode upgrade, but xless owns the toolchain. Before step 3's
install, when the toolchain identity differs from the one recorded after the last install (`.xless/rn-toolchain`;
none recorded counts as different), or with `XLESS_RN_CLEAN=1`, `prepare` deletes the work copy's JS dependency
trees. These are the `node_modules` next to each tracked `package.json` at or below the install's root (the root and
the workspace packages; nothing package-specific). The install repopulates them from the store, a cache volume. A
package directory whose real path leaves the work copy is skipped, a `node_modules` symlink is unlinked rather than
followed, and the source checkout is never touched. An `env`-only change keeps the trees.

Until a prepare has succeeded, `Context` uses provisional values (the overlay's app target, its name as product, iOS
16.4); a stale or partial `ios/` (another scheme after an `env` change, an interrupted `pod install`) never stops the
next prepare, which replaces it. XlessXcode's refusals inside `build` are reported as `[build]` errors.

**build.** On the workspace in `<app>/ios`:
1. The scheme's application target and the bundles it embeds (targets whose products its Copy Files phases copy,
   transitively) must be exactly the overlay's `bundleIDs` keys; embedded IDs must extend the app's.
2. Swift packages: cloned at their pinned revisions and dumped as dependencies of an empty root package
   (`SwiftPackageCheckouts`); what SwiftPM resolved for their own dependencies is recorded in `packages.json`.
3. Lowercase framework aliases from the `install_xcframework` lines of the Pods' `*-xcframeworks.sh`, read as shell
   words (double-quoted words whose only expansion is a leading `${PODS_ROOT}`; anything else is refused), never run.
4. The PIF with per-target settings for the app and its embedded bundles (`PRODUCT_BUNDLE_IDENTIFIER`,
   `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), and the request with the Linux overrides plus `DEVELOPMENT_TEAM`
   and `HERMES_CLI_PATH`. Per-target values cannot be command-line overrides, which apply to every target (pods
   included) and win over target settings.
5. `swbuild` with the overlay's `env` added to its environment (Expo's phases evaluate the app config again).
6. A build phase that ran a missing command fails the build (ruling R4): bash's `command not found`, bash's
   `<path>: No such file or directory` for an absolute path, and GNU `env`'s `‘name’: No such file or directory`;
   `allowMissingCommands` names the ones that only warn.
7. The `.app` is copied to `.xless/build/ios/app`. Every bundle's `CFBundleShortVersionString`/`CFBundleVersion` is set
   to the run's version and build number in its built Info.plist (format kept): an Expo app's Info.plist carries
   literal values from the app config that no build setting reaches, while an extension's usually uses
   `$(MARKETING_VERSION)`. Each bundle's `CFBundleIdentifier` must be the overlay's. `entitlements.json` records, per
   bundle path, the bundle ID and the `CODE_SIGN_ENTITLEMENTS` file with build settings expanded, except
   `$(AppIdentifierPrefix)`/`$(TeamIdentifierPrefix)`, which Xcode defines only when signing.

HelloRN through `xless build` with the committed overlay: 743 tasks, 40 s for the clean Swift Build part; the app and
the extension match the Mac reference with no allowed gaps; a second run skips prebuild and pods (inputs unchanged)
and rebuilds incrementally (53 tasks, 8 s).

## The sign stage: app extensions and capabilities (Task 9)

`xless sign` (and `ship --from sign`) for a `type: react-native` overlay reads three things: the finalized `.app`, the
build's `.xless/build/ios/entitlements.json`, and the overlay. It reads no project file and runs no build code, so it
keeps the three-step split of `scripts/testflight.sh`: step 3 mounts the same work cache as step 2, and the JSON lives
next to the `.app` in the work copy's `.xless/build/ios/`. The manifest replaces `platforms.ios.entitlements`; without
one (xless.yml, Tauri) the app's entitlements come from there and an extension, if any, gets none.

**Bundles.** `PlugIns/*.appex` and `Extensions/*.appex` are signed separately, sorted by path, then the app.

Refused, all before App Store Connect is called:
- a watch app (`Watch/*.app`) or an App Clip (`AppClips/*.app`);
- `PlugIns`, `Extensions` or an extension that is not a real directory (a symlink);
- an extension name with `:` or `@`, which rcodesign 0.29 reads as scope syntax (`<scope>:<file>`, `<path>@<slice>`);
- an extension with its own `Frameworks/`. rcodesign's help says a setting scoped to a nested bundle applies to
  everything in it, so the frameworks could get the extension's entitlements. A 0.29.0 probe did not show that, but
  xless relies on neither behaviour;
- an extension bundle ID that does not start with `<app bundle ID>.`. The manifest must describe exactly these bundles:
an entry for every one, each with the bundle ID in that bundle's Info.plist, and no entry for a bundle the app does not
hold. Anything else is a stale manifest, refused before App Store Connect is called.

**Per bundle, extensions first:**
1. Register the bundle ID if needed (UNIVERSAL).
2. Enable the capability types its entitlements need.
3. Get an `IOS_APP_STORE` profile named `xless <bundle ID> IOS_APP_STORE`, new when a capability was just enabled.
4. If the profile does not grant the entitlements (a key absent, or a value it does not allow, other than a
   keychain group), regenerate it once: something enabled or assigned by hand in the portal only reaches a new
   profile (ruling R13).
5. Embed the profile: `embedded.mobileprovision` in the app, `X.appex/embedded.mobileprovision` in an extension.

**Entitlements, in order:**
1. `$(AppIdentifierPrefix)` and `$(TeamIdentifierPrefix)` (also `${…}`) become `<teamID>.` in every string value.
2. The overlay's `entitlements.remove` drops top-level keys.
3. `identifiers.replace` (a top-level overlay key, Ruling R9) rewrites every string value: literal substrings, longest
   match first, one pass, so replaced text is never rewritten again. A key must be a whole identifier (4+ characters
   with a `.`) and a value non-empty. The unreleased `entitlements.replace` is refused at `config` with a pointer to it.
4. Checks, before the bundle is touched:
   - every profile's team is `teamID`;
   - app groups, for all bundles at once;
   - per bundle, key presence and the values below.
5. Merge: xless sets `application-identifier` (`<team>.<bundle ID>`), `com.apple.developer.team-identifier`,
   `get-task-allow: false` and the profile's `beta-reports-active`. `aps-environment` `development`/`production`
   takes the profile's value (`production` in an App Store profile), as Xcode signs.

**Value checks (iOS).**
- `keychain-access-groups`: each value must match one of the profile's patterns (`<team>.*`).
- `com.apple.security.application-groups`: each group must be in the profile's list.
- `com.apple.developer.associated-domains`: the profile's `*` allows any value; otherwise each must be listed.

Other keys need only be present in the profile. macOS keeps key presence only.

**Capability map** (`Capabilities.map`, iOS only):

| Entitlement key | `capabilityType` |
|---|---|
| `aps-environment` | `PUSH_NOTIFICATIONS` |
| `com.apple.developer.associated-domains` | `ASSOCIATED_DOMAINS` |
| `com.apple.developer.authentication-services.autofill-credential-provider` | `AUTOFILL_CREDENTIAL_PROVIDER` |
| `com.apple.security.application-groups` | `APP_GROUPS` |

All four are members of the `CapabilityType` enum in Apple's App Store Connect OpenAPI spec 4.5.1 (`openapi.oas.json`,
the same download as docs/research/asc-build-uploads.md, read as data). None needs `settings`: the only
`CapabilitySetting.key` values are `ICLOUD_VERSION`, `DATA_PROTECTION_PERMISSION_LEVEL` and
`APPLE_ID_AUTH_APP_CONSENT`.

The enum has no type for App Attest (`com.apple.developer.devicecheck.appattest-environment`), Declared Age Range
(`com.apple.developer.declared-age-range`) or the increased memory limit. These keys take the R13 path: one profile
refresh, then a refusal naming the capability and the identifier, e.g. `enable the matching capability (App Attest)
for <id> at developer.apple.com/account/resources/identifiers, then re-run`.

**App groups.** The spec has no app-group resource and no setting that assigns a group, so the API can enable
`APP_GROUPS` on an identifier but can neither create a group nor assign one. A group missing from a profile, after the
refresh, stops `sign` with one error for all bundles. It gives the steps at
developer.apple.com/account/resources/identifiers:
1. Identifiers → + → App Groups → Continue → identifier `<group>` → Register.
2. For each listed bundle ID: App Groups → Configure → select the group → Save.
3. Re-run. The next run regenerates the profiles that predate the assignment.

Both this refusal and the portal-only one end with "Finish every portal step before re-running". Each run that still
finds something missing deletes and recreates the affected profiles.

**An app built under another team.** Its entitlements name that team's identifiers, e.g.:
- `group.<their app ID>`;
- `$(AppIdentifierPrefix)<their app ID>.x`, which passes the keychain check once the prefix is the signing team's.

Map them with `identifiers.replace`, e.g. `{ <their app ID>: <test app ID> }`. Drop a capability the test team
cannot have with `entitlements.remove`.

The app may also read those identifiers at run time from its Info.plist, e.g. a key naming the app group its storage
library opens, or an app extension's app group and keychain group. Measured on the acceptance app in the iOS 27
simulator: with the entitlements mapped and the Info.plist keys not, the JS runtime throws "Container for AppGroup …
not accessible" (containermanager: "client is not entitled") and the app stays on its splash screen. So the same map
applies at `finalize` to every string value (nested arrays and dictionaries included, keys excluded) of the app's own
bundles' `Info.plist`s: the app and its extensions (`PlugIns/*.appex`), and any other bundle (framework, resource
bundle) only when its own `CFBundleIdentifier` is one of the replaced identifiers or starts with one; that bundle ID
is kept. Third-party frameworks are left alone (fix wave ruling M3). A key matches only at the end of an identifier:
the next character is not a letter, digit or `-`, so `com.other.app` never rewrites `com.other.apple`. Each file keeps
its format (binary or XML), a file with nothing to replace is left byte for byte, every replaced value's key path is
logged, and a change to the app's or an extension's `CFBundleIdentifier` is refused (bundle IDs come from
`bundleIDs`). `finalize` runs before `sign`, so the signature seals the rewritten files, and records the map next to
the app (`final/identifiers.json`): `sign` refuses an overlay whose map changed since. A simulator build has no
`finalize`: it applies the map after `build` assembles the app and before the ad-hoc signature. Identifiers compiled
into the JavaScript bundle or native code are not rewritten and still name the original groups at run time.

**rcodesign.** One `rcodesign sign` (0.29.0) per app:
- the app's entitlements are passed unscoped (`--entitlements-xml-file <file>`);
- each extension's are scoped to its path (`--entitlements-xml-file PlugIns/X.appex:<file>`).

`sign --help` ("Settings Scope") says that a scoped setting applies to that path only and an unscoped one to the main
bundle only. Only key, certificate, timestamp, digest and exclude settings reach nested bundles. rcodesign signs nested
bundles before their container ("signing N nested bundles in the following order", then "signing bundle at X.app"),
so the app's `CodeResources` seals the signed extension.

Checked on Linux with HelloRN as built by Task 8:
- self-signed certificate with OU `ABCDE12345`;
- fake App Store Connect;
- `XLESS_SIGN_E2E_APP` in `XlessSignTests`.

`rcodesign verify` passes for both executables. Each signature carries its own identifier,
`application-identifier`, team (`apple_team_id: ABCDE12345`) and entitlements; only the app has `aps-environment`.

## Configuration switches at prepare (Task 10)

Several pods ship one prebuilt framework per configuration and leave the Debug one in place after `pod install`; a
build phase of their own replaces it with the configuration's when the build runs:

| Phase (Pods project) | Script | State after `pod install` |
|---|---|---|
| `[CP-User] [Expo] Switch <Pod> XCFramework for build configuration` (ExpoModulesCore, ExpoFileSystem, ExpoFont, ExpoModulesWorklets in HelloRN) | `expo-modules-autolinking/scripts/ios/replace-xcframework.js`: `rm -rf <Pod>.xcframework`, extract `artifacts/<Pod>-<config>.tar.gz` | `artifacts/.last_build_configuration` = `debug` |
| `[CP-User] [RNCore] Replace React Native Core for the right configuration, if needed` | `react-native/scripts/replace-rncore-version.js`: extract to a temporary directory, delete every directory of `React-Core-prebuilt`, move the new ones in | no state file (taken as Debug) |
| `[CP-User] [RNDeps] Replace React Native Dependencies …` | `react-native/third-party-podspecs/replace_dependencies_version.js`, the same for `ReactNativeDependencies` | no state file |
| `[CP-User] [Hermes] Replace Hermes …` | `react-native/sdks/hermes-engine/utils/replace_hermes_version.js`, the same for `hermes-engine` | no state file |

Each decides Debug or Release from `GCC_PREPROCESSOR_DEFINITIONS` containing `DEBUG=1`, and does nothing when its state
file already names that configuration.

**What went wrong on Linux.** A clean Swift Build of HelloRN starts other targets before these phases run: ExpoLogBox's
Swift module planning, for example, scans `Pods/ExpoModulesCore/ExpoModulesCore.xcframework/…/Headers` (the Debug tree)
about 12 s before ExpoModulesCore's switch replaces it. Swift Build keeps file-system state in its process (the
dependency scanners' shared file-system cache, llbuild's stat information), and on ext4 the replaced files get the
deleted files' inode numbers back at once: across one switch, about 95% of the Debug trees' inode numbers reappear at
other paths, a quarter of them as the other type (a directory where a file was). Measured outcomes of clean builds of
HelloRN (`~/.cache/xless/m3-t10/exp/`):
- builds whose Pods tree is exactly what `pod install` left (restored from a snapshot before each build, derived data
  deleted): 3 failures in 30, each "The Xcode build system has crashed" (llbuild `ErrorOr<basic_file_status>`
  assertion) while the `[RNDeps]` and `[Hermes]` replace phases were running; earlier first builds after `pod install`
  failed twice with `'ExpoModulesCore/CoreModuleHelper.h' file not found` (the scanner, reading
  `XCFrameworkIntermediates/ExpoModulesCore`, "did not find header … in framework") right after ExpoModulesCore's switch;
- with the fix (below; the same snapshot restored before each build, `prepare` switching it): 0 failures in 30; and 10
  runs with every docker volume new (`xless ship --to finalize`, as step 2 of scripts/testflight.sh runs): 0 failures
  (before the fix, 2 of the first 3 such runs had failed).

**What xless does.** `prepare` runs these phases itself after `pod install` (and, as a no-op check, on every prepare),
for the overlay's `configuration`, as Swift Build would run them: each phase whose name matches `[CP-User] [<Tag>]
Switch … XCFramework for build configuration` or `[CP-User] [<Tag>] Replace … for the right configuration, if
needed`, read from `Pods/Pods.xcodeproj` (never hard-coded), with its `shellPath`, in the Pods project's directory, and
with the target's build settings for the configuration in its environment (`$(inherited)` evaluated level by level,
`ConfigurationSwitches`). During the build the same phases then find their state file current and change nothing
("Same config of the previous build. No need to replace …"). The configuration is part of the prepare fingerprint
(since scheme `xless-rn-prepare-3`). HelloRN still matches the Mac reference with no allowed gaps: the Mac build performs the
same switch, only during the build.
