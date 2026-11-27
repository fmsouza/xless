# Xcode pack relocation: can an installed Darwin SDK be moved and used read-only?

## Decision

**Relocatable.** An SDK installed with `xtool sdk install` holds no absolute path at all: not in any file, not in any
symlink. Moved to another directory and mounted read-only, SwiftPM and Swift Build still found it and the compile phase
ran against it. Tasks proceed as written; no "same path everywhere" rule is needed.

- **Which switch the tools get (Task 6): `--swift-sdks-path <pack>/swiftpm/swift-sdks`, with the user's own (or a
  scratch) writable `XDG_CONFIG_HOME` left alone.** Both ways find the SDK. With `XDG_CONFIG_HOME=<pack>/config` SwiftPM
  and Swift Build also want to create `swiftpm/configuration`, `swiftpm/security`, `swiftpm/swift-sdks/configuration`
  and a `swiftpm/cache` link under it: on a read-only pack they print warnings ("not accessible or not writable,
  disabling user-level cache features"), and with other command lines the mkdirs fail with EROFS. `--swift-sdks-path`
  keeps all of that in the writable XDG directory.
- **Where writes go.** During a build nothing is written under the pack (0 entries in the pack modified; 0 write calls
  that landed there with the command line xless uses). SwiftPM's own state goes to `$XDG_CONFIG_HOME/swiftpm`
  (`configuration`, `security`), its cache to `$XDG_CACHE_HOME`, Swift Build's intermediates to the package's
  `--scratch-path`, temporaries to `/tmp/TemporaryDirectory.*`. Swift Build also **reads** (ENOENT, harmless)
  `$XDG_CONFIG_HOME/{.GlobalPreferences,com.apple.dt.XCBuild,org.swift.swift-build}.plist` and `ByHost/*`: so a
  writable `XDG_CONFIG_HOME` outside the pack is where a user default could be set.
- **The one writer beside an SDK is the installer.** `xtool sdk install` writes the bundle (a 3.1 GB copy of the export)
  and, outside it, lock files under `$HOME/.cache/xtool/pid-*-0.lock` and a temp directory. So a pack is prepared by
  installing into a writable directory and only then mounted read-only; nothing at build time needs `xtool`'s cache.

## Method

`scripts/spikes/pack-relocation.sh <export dir> <arch>`, run on a macOS arm64 host (Docker 29.5.2 through colima, no
`colima-xless` context) in a privileged `linux/arm64` container of `xless:local-arm64-setup` (Swift 6.4, xtool 1.21.0, as
root; strace added with apt). The export is Xcode 26.2 (17C52), `~/.cache/xless/sdk/xcode26.2-17C52/arm64/darwin.xtoolsdk`
(3.0 GB) made with `docs/images.md` steps 1 to 3 from `Xcode_26.2_Universal.xip`.

1. `XDG_CONFIG_HOME=/tmp/p1/config xtool sdk install /export/darwin.xtoolsdk` (straced).
2. (a) `grep -rIl /tmp/p1 /tmp/p1/config`, the same without `-I` (binary files), and
   `find /tmp/p1/config -type l -lname '/*'`.
3. Control C: the build below, where it was installed (`/tmp/p1`, writable, not moved).
4. `mv /tmp/p1 /tmp/p2`, `mount --bind /tmp/p2 /tmp/p2 && mount -o remount,bind,ro /tmp/p2` (`touch` then fails with
   "Read-only file system").
5. (b) Build `samples/HelloShip` (a plain Swift package, copied to a writable directory) with
   `swift build --swift-sdk arm64-apple-ios --build-system swiftbuild --toolset <bundle>/toolset-swb.json` (the form of
   `Sources/XlessBuild/MacBuilder.swift`), `XCODE_EXTRA_PLATFORM_FOLDERS=<bundle>/Developer/Platforms` and `SDKROOT` unset
   (as `SwiftBuildEnvironment.processEnvironment`), twice: X with `XDG_CONFIG_HOME=/tmp/p2/config`; S with
   `--swift-sdks-path /tmp/p2/config/swiftpm/swift-sdks` and `XDG_CONFIG_HOME=/tmp/userxdg` (empty, writable). Cache,
   home and scratch were given directories of their own, so what lands under `/tmp/p2` is the SDK's doing.
6. (c) `strace -f -e trace=openat,mkdir,mkdirat,rename*,symlink*,unlink*,chmod,utimensat,truncate` of each, filtered to
   calls on `/tmp/p2` with a write flag or a mutating call.

## Measurements

### (a) Absolute paths in the installed tree (3.1 GB, 7472 symlinks)

| Query | Result |
|---|---|
| `grep -rIl /tmp/p1 /tmp/p1/config` (text) | none |
| `grep -rl /tmp/p1 /tmp/p1/config` (binary included) | none |
| `find /tmp/p1/config -type l -lname '/*'` | none: all 7472 symlinks are relative (186 of them climb with `../`) |
| whole-string absolute paths in the bundle's JSON (`info.json`, `swift-sdk.json`, `toolset*.json`) | none: `swift-sdk.json` and both toolsets use paths relative to the bundle (`sdkRootPath: Developer/Platforms/iPhoneOS.platform/...`, `rootPath: toolset/bin`) |
| after the move: files still naming `/tmp/p1`; dangling symlinks | 0; 0 |

So no file and no link holds the install path; nothing needs rewriting. The install is a plain copy of the export (relative
symlinks preserved). `swift sdk list` shows `darwin` under both `XDG_CONFIG_HOME=/tmp/p2/config` and `--swift-sdks-path`.
The only absolute paths in a build are produced at run time from where the bundle was found (the `-isysroot`,
`-resource-dir`, `--ld-path` of each command line name `/tmp/p2/...`; xless's `SwiftBuildEnvironment.toolset()` also
builds its `rootPath` from `sdk.bundle`).

Who wrote where during the install (`xtool sdk install`): the bundle under `/tmp/p1/config/swiftpm/swift-sdks/darwin.artifactbundle`;
`$HOME/.cache/xtool/pid-<n>-0{,.lock}` (outside); `/tmp/TemporaryDirectory.*/.keep-directory` (outside).

### (b) Builds

Both X and S, moved and read-only, and the control C, unmoved and writable, end the same way: `swift build` plans the
package, the Swift and C compile steps run against the SDK (in X, strace shows about 17,000 successful opens of files under
`/tmp/p2`, 17,233 of them in the SDK's `SDKs/` trees, and the compiler wrote `HelloShipApp.o` and `ContentView.o`), and the link step
`clang -r ... --ld-path=<bundle>/toolset/bin/ld64.lld` fails ("`HelloShip.o: No such file or directory`", "linker command
failed"). The control fails at the same step with the same message, so this is not about relocation. Probably (not investigated) the plain image
lacks the pieces xless's build adds (the `xless-ld64` linker shim and the toolchain pins of Ruling R10, which are in
`docker/Dockerfile`'s later stages, not in the tools image). The app Swift for Xcode 26.2 (6.2.3) was not downloaded:
nothing measured here depends on it.

| Run | SDK found | Compile phase against the moved read-only SDK | Link |
|---|---|---|---|
| C: `/tmp/p1`, writable, `XDG_CONFIG_HOME=/tmp/p1/config` | yes | ran | fails (image lacks the linker shim) |
| X: `/tmp/p2` read-only, `XDG_CONFIG_HOME=/tmp/p2/config` | yes | ran | fails, same message as C |
| S: `/tmp/p2` read-only, `--swift-sdks-path`, user's own XDG | yes | ran | fails, same message as C |

Earlier iterations of the script gave two more data points: with `--swift-sdk arm64-apple-ios` and no `XCODE_EXTRA_PLATFORM_FOLDERS`,
the build stops with "unable to find platform for 'iphoneos'" in the unmoved control as well (so the platform folder is
named by environment, which xless already does); with the bare `swift build --swift-sdk darwin`, "has multiple target
triples" (a triple is needed).

### (c) Writes attempted under the read-only `/tmp/p2`

| Run | With the final command line (swiftbuild, toolset) | With the first command line (native build system, no toolset; run once before the script was corrected) |
|---|---|---|
| X (`XDG_CONFIG_HOME=/tmp/p2/config`) | 0 write calls; warnings "`/tmp/p2/config/swiftpm/configuration` is not accessible or not writable, disabling user-level cache features" (same for `security`) | 4 calls, all EROFS: `mkdirat swiftpm/configuration`, `mkdirat swiftpm/security`, `mkdirat swiftpm/swift-sdks/configuration`, `symlinkat swiftpm/cache -> $XDG_CACHE_HOME/org.swift.swiftpm`; SwiftPM warns "problem getting custom configuration for SDK: encountered an I/O error (code: 30)" |
| S (`--swift-sdks-path`) | 0 write calls; no warning; `mkdirat` of `swiftpm`, `swiftpm/configuration`, `swiftpm/security` succeeded under `/tmp/userxdg` | 1 call, EROFS: `mkdirat swiftpm/swift-sdks/configuration` (the SDK's own custom-configuration directory, a warning only) |
| C (control, writable `/tmp/p1`) | the same 4 as X's first column, all succeeding: SwiftPM creates its state beside the SDK when `XDG_CONFIG_HOME` is the install directory | |

After all runs: 0 entries in `/tmp/p2` modified since the mount. No tool tried to read `/tmp/p1` after the move (0 reads).
No build wrote anywhere outside its own scratch, cache and home directories, `/tmp/TemporaryDirectory.*`, and the writable XDG directory.
The warning in the first column of X is the difference that decides the switch: only `--swift-sdks-path` leaves nothing
for a read-only pack to refuse.

## What this changes in the plan

- Task 5's relocation test stays "move it, it still works"; no "same path" variant.
- Task 6 gives the tools `--swift-sdks-path <pack>/swiftpm/swift-sdks` and a writable `XDG_CONFIG_HOME`; never `XDG_CONFIG_HOME=<pack>/config`.
- `xtool sdk install` runs only when the pack is made, into a writable directory.
- Not measured: the link step (needs the xless image's linker shim), Swift 6.2.3, and an x86_64 pack (the structure, with no absolute
  path, is by design the same). The raw strace and build logs of the last run are in `~/.cache/xless/spike-out/`.
