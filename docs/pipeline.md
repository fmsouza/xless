# How xless builds an app

xless takes an app's source and produces what Apple's own tools would:

- **iOS and iPadOS:** a signed `.ipa`, uploaded to App Store Connect and delivered to TestFlight.
- **macOS:** a Developer ID signed, notarized and stapled `.app` inside a `.zip`. A Tauri v2 macOS app gets a `.dmg`
  instead ([tauri.md](tauri.md#macos), [cargo.md](cargo.md#macos)). There is no Mac App Store `.pkg` ([why](research/mas-pkg.md)) and no upload
  step for macOS.

It does this on Linux, without Xcode on the build machine. The Darwin SDK comes from an Xcode release you download
from Apple ([apple-requirements.md](apple-requirements.md)). Nine Xcode releases are supported: 27.2 (27B52), 27.1
(27A9275), 27.0 (27A266a), 26.4 (17E192), 26.3 (17C529), 26.2 (17C52), 26.1.1 (17B100), 26.1 (17B55) and 26.0.1 (17A400).

## Where things run

```
┌─ your Linux machine, once per Xcode release ──────────────────────────────┐
│ xless setup --xcode Xcode_27.xip                  (native, the default)    │
│   → xtool, rcodesign and the Xcode's open-source Swift, pinned downloads   │
│   → xtool (open source) unpacks the SDK from the .xip; installed for Swift │
│ xless setup --docker --xcode Xcode_27.xip         (or: the images)         │
│   → images xless-base, xless, xless-tauri, xless-rn (:local-<arch>…)       │
└───────────────────────────────────────────────────────────────────────────┘
┌─ every build ─────────────────────────────────────────────────────────────┐
│ xless run <project-dir>                           (native)                 │
│ xless run --docker <project-dir>  or  --docker --config <overlay.yml>      │
│   → xless ship:                                                            │
│     [prepare →] build → assets → finalize → sign → package → upload        │
└───────────────────────────────────────────────────────────────────────────┘
```

- **The native install.** `xless setup` installs the toolset and the SDK under your home directory, with no Docker
  ([native-install.md](native-install.md)). It builds `xless.yml` projects.
- **The images.** `xless setup --docker` builds them from the `.xip` ([images.md](images.md) shows each step, for building them
  by hand). `xless-base` holds xless, xtool and rcodesign; `xless` adds the Darwin SDK and the open-source Swift
  release whose version matches that Xcode's Swift (6.4.2 for 27.2, 6.4 for 27.1 and 27.0, 6.3 for 26.4, 6.2.4 for 26.3, 6.2.3 for 26.2, 6.2.1 for 26.1.1 and 26.1, 6.2 for 26.0.1; Apple's own toolchain is never in
  an image); `xless-tauri` adds Node, pnpm and Rust; `xless-rn` adds Ruby, Bundler, Swift Build, Hermes and the Xcode
  tool replacements a React Native build calls. They are tagged `<image>:local-<arch>-xcode<version>` (for
  example `xless:local-arm64-xcode26.2`), and also plain `<image>:local-<arch>` for Xcode 27.0, the default.
- **`xless run`** runs a build, natively or, with `--docker`, in those images (`xless docker` is `xless run --docker`).
  With a project directory (an `xless.yml` project) it runs `xless ship` in one process or container. With `--config <overlay.yml>` (a Tauri, plain Cargo or React Native app) it runs three containers,
  so that the app's own build code never runs next to a signing key ([signing-and-testflight.md](signing-and-testflight.md#the-three-step-split)).
  The options after the project or overlay go to `xless ship`, for example `--to finalize` or `--from sign`.

## The project

An `xless.yml` project is a Swift package with an `xless.yml` next to `Package.swift` ([xless-yml.md](xless-yml.md)).
The installed sample `~/.local/share/xless/samples/HelloShip` is one. A Tauri, plain Cargo or React Native app is described by an
**overlay** file that lives outside the app's repository and points at it: the app's repository is never changed
([tauri.md](tauri.md), [cargo.md](cargo.md), [react-native.md](react-native.md)).

## Stages

`xless ship` runs the stages in order. Each stage reads only the previous stage's directory under
`.xless/build/<platform>/` and writes only its own, so you can resume a failed run with `--from <stage>`, stop after a
stage with `--to <stage>`, or run one stage on its own (`xless build`, `xless sign`, …). A stage builds into
`<dir>.partial` and renames it only on success, so a stage directory exists only if that stage succeeded; a failed
stage also removes its previous output.

| Stage | Command | Output | Exit code on failure |
|---|---|---|---|
| prepare | `xless prepare` | Overlays only: the work copy, the app's dependencies and toolchains (React Native: `expo prebuild`, `pod install`) | 19 |
| build | `xless build` | `app/`: the unsigned bundle | 12 |
| assets | `xless assets` | `assets/` (iOS: `Assets.car`; macOS: `.icns`) | 13 |
| finalize | `xless finalize` | `final/`: Xcode's metadata stamped into Info.plist, binaries patched. The app is complete but unsigned. | 14 |
| sign | `xless sign` | `signed/` | 15 |
| package | `xless package` | `out/`: the `.ipa`, the notarized `.zip`, (Tauri and Cargo macOS) the notarized and stapled `.dmg`, or (App-Store macOS) the `.pkg`; next to it, `<App>.app.dSYM.zip` when the build kept dSYMs ([below](#dsyms)) | 16 |
| upload | `xless upload` | `upload.json` (iOS only; rewritten at every state change, so it keeps the build ID if processing fails or times out). With a [`testflight:` block](xless-yml.md#testflight) it then delivers the processed build to your TestFlight groups. | 17 |

Config errors exit 10 and SDK errors exit 11. `xless run` itself exits 2 for a usage or configuration error of its
own (a missing project, overlay or secret file). Errors are printed as `[stage] cause — fix`.

All stage commands take `--platform ios|macos`, `--project <dir>` (default `.`) and `--build-number`; overlays take
`--config <overlay.yml>` and `--source <dir>` instead of `--project`. Sign, package and upload need an Apple Developer
account and its keys ([signing-and-testflight.md](signing-and-testflight.md)); the stages before them need none.

## dSYMs

A crash reporter (Crashlytics' `upload-symbols`, `sentry-cli debug-files upload`) symbolicates a crash with the dSYM of
the build that crashed. `build` keeps the build's dSYMs in `.xless/build/<platform>/dSYMs/`, and `package` zips them
into `out/<App>.app.dSYM.zip`, the name fastlane's `gym` gives it, next to the `.ipa`, the notarized `.zip`, the `.dmg`
or the `.pkg`. xless uploads nothing: App Store Connect gets no dSYM from it.

| App | Where the dSYM comes from | When there is one |
|---|---|---|
| `xless.yml`, macOS | Swift Build's `<name>.dSYM` next to each architecture's executable, merged into one universal dSYM | When Swift Build writes one (it does for the release build in the xless image) |
| `xless.yml`, iOS | xtool's build: Swift Build's `<Product>-App.dSYM` (xtool builds with Swift Build from Swift 6.4), else `dsymutil` on the app's executable | When the executable has a debug map (SwiftPM's release builds have debug info) |
| React Native | Every `.dSYM` Swift Build wrote ([react-native.md](react-native.md#dsyms)) | `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` (Expo's Release default) |
| Cargo (iOS, macOS), Tauri macOS | The linker wrapper's debug link ([below](#dsyms-of-rust-apps)), one per architecture | When the release profile has debug info |
| Tauri iOS | `dsymutil` on the executable xless links | When the release profile has debug info for the app crate |

A dSYM is kept only when its UUIDs are those of a binary the app ships (`dwarfdump --uuid` shows both), so a dSYM an
earlier build left behind (Swift Build's derived data is kept between builds) never ends up in the zip. The dSYM is
named after the app, `<App>.app.dSYM`, with its DWARF file named after the app's executable (React Native keeps every
dSYM under its own name). Signing, `finalize` and stripping do not change a Mach-O's UUID. Each `build` replaces the
directory, and one that keeps no dSYM removes it; the build log's `dSYMs:` line says what was kept, or why nothing was.
`dsymutil` is the one in the SDK's toolset (`toolset/bin/dsymutil`, which xtool installs next to `ld64.lld`, the same
LLVM), in the images and in a native install alike.

### dSYMs of Rust apps

A Rust app gets a dSYM when its release profile has debug info for the app's crate. Set it in the `Cargo.toml` of the
workspace root (cargo reads profiles only there; for Tauri usually `src-tauri/Cargo.toml`):

```toml
[profile.release]
debug = "line-tables-only"   # enough for a crash reporter: function names, files and lines; `true` adds variables
```

A plain Cargo app can instead leave the repository untouched and set it in the overlay:
`env: { CARGO_PROFILE_RELEASE_DEBUG: line-tables-only }`. Without debug info nothing changes (the build log says
`dSYMs: none (… compiled without debug info …)`). With it, the build takes longer (a second link and `dsymutil`) and
the work copy holds the debug links.

**Cargo apps and Tauri macOS apps** (cargo links the executable through xless's linker wrapper). Two things keep a
plain `dsymutil` from working on the executable cargo builds:

- cargo asks rustc for `-C split-debuginfo=unpacked` on Apple targets whenever the profile has debug info, so the DWARF
  stays in rustc's object files and rustc writes no `<bin>.dSYM`;
- the executable is linked with `-Wl,-x` (local symbols dropped, in place of a `strip` that could leave a Mach-O dyld
  refuses), and `ld64.lld -x` also drops the debug map entries of local and hidden functions, nearly every Rust
  function. A dSYM made from that executable describes almost nothing of the app's code.

So when the crate's own object files carry DWARF, the wrapper links twice: first exactly as without debug info, with
`-x` (that executable is the one cargo gets and the app ships, the same bytes as before), then the same arguments
without `-x` into `.xless/dsym/<target>/` in the work copy, and runs `dsymutil` on that second link while rustc's
objects still exist. The two links hold the same code and data; only their symbol tables and UUIDs differ. After
cargo, xless checks that every section of the second link equals the shipped executable's, sets the dSYM's UUID to the
shipped one, and keeps it (one per architecture, merged for a universal app). Every link of the crate replaces its
earlier debug links, and a link without debug info leaves only a record that it had none (`<crate>-<hash>.nodebug`).
cargo links an executable only when something changed (the work copy keeps the source's file times), so a build it
does not link again reuses the last debug link; when the directory has no record of the executable at all (the first
build with this xless, or after the directory was removed), xless removes cargo's linked executable from
`target/<target>/release/deps/` so that cargo links it once more, through the wrapper. A failure of the second link
or of `dsymutil` (recorded as `<crate>-<hash>.failed`, with rustc's warning showing the wrapper's message), an SDK
whose toolset has no `dsymutil`, and a link whose arguments rustc passed in a response file (`@file`, only when the
command line is too long for the system) leave the app without a dSYM; none of them fails the build.

**Tauri iOS apps.** xless links the executable itself, without `-x`, so its debug map is whole: `dsymutil` runs on it
when the map names an object of the app crate. The Rust standard library's objects always carry line tables (rustup
ships them that way), so a debug map alone does not mean the app's code has debug info.

## Other commands

- `xless inspect <bundle> --platform <p>` prints Info.plist and Mach-O build versions as JSON (useful when comparing
  with an Xcode build); `xless inspect --config <overlay>` prints what a React Native or Tauri overlay's build would do (not a cargo one).
- `xless next-build --config <overlay>` (React Native and cargo) and `xless tauri next-build --config <overlay>` print the build
  number the next run would use (a read-only App Store Connect query).
- `xless sdk meta|install` manage a native SDK install ([native-install.md](native-install.md)).
- `xless storyboard compile` compiles a launch storyboard without ibtool ([xless-yml.md](xless-yml.md#launch-storyboard)).
- `xless sign bootstrap` creates signing keys and certificates ([bootstrap.md](bootstrap.md)).
- `xless clean` removes the images, volumes and cache xless made, to free disk space ([uninstall.md](uninstall.md)).
- `xless help <command>` describes any command.
