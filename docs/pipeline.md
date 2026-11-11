# How xless builds an app

xless takes an app's source and produces what Apple's own tools would:

- **iOS and iPadOS:** a signed `.ipa`, uploaded to App Store Connect and delivered to TestFlight.
- **macOS:** a Developer ID signed, notarized and stapled `.app` inside a `.zip`. A Tauri v2 macOS app gets a `.dmg`
  instead ([tauri.md](tauri.md#macos), [cargo.md](cargo.md#macos)). There is no Mac App Store `.pkg` ([why](research/mas-pkg.md)) and no upload
  step for macOS.

It does this on Linux, without Xcode on the build machine. The Darwin SDK comes from an Xcode release you download
from Apple ([apple-requirements.md](apple-requirements.md)). Two Xcode releases are supported: 27.0 (27A266a) and
26.2 (17C52).

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
  release whose version matches that Xcode's Swift (6.4 for 27.0, 6.2.3 for 26.2; Apple's own toolchain is never in
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
| React Native | Every `.dSYM` Swift Build wrote ([react-native.md](react-native.md#dsyms)) | `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` (Expo's Release default) |
| `xless.yml` iOS, Cargo, Tauri | None (not supported yet, [below](#dsyms-of-rust-apps)) | |

A dSYM is kept only when its UUIDs are those of a binary the app ships (`dwarfdump --uuid` shows both), so a dSYM an
earlier build left behind (Swift Build's derived data is kept between builds) never ends up in the zip. On macOS the
dSYM is named after the app, `<App>.app.dSYM`, with its DWARF file named after the app's executable. Signing,
`finalize` and stripping do not change a Mach-O's UUID. Each `build` replaces the directory, and one that keeps no dSYM
removes it; the build log's `dSYMs:` line says what was kept, or why nothing was.

### dSYMs of Rust apps

Cargo and Tauri apps get no dSYM yet, even with debug info in the release profile:

- cargo asks rustc for `-C split-debuginfo=unpacked` on Apple targets whenever the profile has debug info, so rustc
  does not run `dsymutil` and leaves no `<bin>.dSYM`;
- the executable is linked with `-Wl,-x` (local symbols dropped, in place of a `strip` that could leave a Mach-O dyld
  refuses), and `ld64.lld -x` also drops the debug map entries of local and hidden functions. Measured with LLD 15: the
  dSYM `dsymutil` then makes describes `main` and nothing else, and nearly every Rust function is local or hidden.

A useful dSYM needs a link without `-x` and the local symbols stripped after `dsymutil` has run. iOS apps built from an
`xless.yml` (xtool) and Tauri iOS apps (which xless links itself) are not covered either.

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
