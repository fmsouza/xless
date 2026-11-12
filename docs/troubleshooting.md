# Troubleshooting

xless errors read `[stage] cause — fix`: the last part says what to do. Exit codes: 2 is `xless run`'s own
(arguments, a missing file or secret), 10 config, 11 SDK and `xless setup`, 19 prepare, 12 build, 13 assets,
14 finalize, 15 sign, 16 package, 17 upload ([pipeline.md](pipeline.md#stages)). Tauri and React Native apps have
their own tables: [tauri.md](tauri.md#troubleshooting), [react-native.md](react-native.md#troubleshooting).

## Installing

| Symptom | What to do |
|---|---|
| `xless: command not found` after the install | `~/.local/bin` is not on your `PATH` in this shell. Open a new terminal (many Linux systems add `~/.local/bin` at login once it exists), or run the `export PATH=…` line the installer printed. If a new terminal still cannot find `xless`, add that line to your shell's startup file (`~/.bashrc`, `~/.zshrc` or `~/.profile`). |
| `unsupported OS` or `unsupported architecture` | Releases exist for Linux on x86_64 and arm64 only. On a Mac, use a Linux VM or container. |
| `sha256 mismatch …; nothing was installed` | The download was damaged or changed. Run the install line again; if it keeps failing, report it. |
| `warning: docker is not installed` / `the daemon is not reachable` | xless is installed, but builds need Docker: see the next section. |
| `[sdk] this xless is <x.y.z>, but its share directory … is from xless <a.b.c>` (exit 11) | The `xless` binary and its support files (`share/xless`: the scripts, Dockerfiles and pinned versions it uses) come from different releases, for example because only the binary was replaced. `xless setup`, `xless run`, `xless docker`, `xless sdk meta` and `xless sdk export` refuse to run that way. Install one release of both: run the install line again (with `XLESS_VERSION=<x.y.z>` for the binary's release, and your `XLESS_PREFIX` if you installed elsewhere; the error prints the command). If the share is named `(XLESS_SHARE)`, that variable chose it: unset it, or point it at the binary's release's share directory. A source build (`0.0.0-dev`) uses its own checkout: `XLESS_SHARE=<the checkout>`. `XLESS_ALLOW_SHARE_MISMATCH=1` goes on anyway, with a warning; meant for developing xless itself. |
| `… records no release (no VERSION file, no XLESS_VERSION in versions.env)` or `xless's share directory … does not exist` | The share directory is not a release's or a checkout's (each release's share holds a `VERSION` file). Reinstall, or point `XLESS_SHARE` at a release's share directory or a source checkout. |

To install a given release, set `XLESS_VERSION`; to install somewhere else, set `XLESS_PREFIX` (or pass `--prefix`):

```sh
curl -fsSL https://github.com/fmsouza/xless/releases/latest/download/install.sh | XLESS_VERSION=v0.1.0 XLESS_PREFIX=$HOME/opt/xless sh
```

Running the install line again upgrades xless in place: the binary and `share/xless` together. xless checks that the two
come from the same release (the share's `VERSION` file) whenever it reads the share.

## `xless xcode download`

| Symptom | What to do |
|---|---|
| `signing in to Apple needs an interactive terminal` | Run it in a terminal (not through a pipe, `nohup` or a CI job). It never reads the Apple ID, password or code from anywhere else. |
| `Apple refused the Apple ID or password` | Check them and run it again. A few failed attempts can lock the Apple ID. |
| `Apple says the Apple ID is locked` | Unlock it at <https://iforgot.apple.com>, then run it again. |
| `Apple did not accept the verification code 3 times` | Run it again and type the newest code; with `sms` at the code prompt the code comes by text message instead. |
| `… hardware security key …`, `… old two-step verification …` | xless supports two-factor codes only. Use an Apple ID without security keys, or download in a browser. |
| `Apple refused the download list …`, `Apple wants this Apple ID to accept new terms …` | Sign in once at <https://developer.apple.com/download/all/> in a browser, accept the agreement it shows, and run it again. |
| `Apple offers no Xcode …` | Use the name Apple lists: `xless xcode download --list`. |
| `Apple did not authorise the download of …` | Check in a browser that the Apple ID can download that file, then run it again. |
| `… is incomplete`, `could not reach Apple …`, `N of M Xcode downloads failed: …`, or the download stopped | Each file was already retried twice. Run the same command again: finished `.xip`s are kept and each `.part` file resumes. |
| `… is larger than Apple listed …` | The `.part` was deleted; run it again to download that file from the start. |
| `Apple resumed … at the wrong place …` | Nothing wrong was kept: the `.part` was deleted and the file was retried from the start. If it still fails, run it again. |
| `… is not an Xcode .xip` (an existing file) | A file of that name that is not a `.xip` is in the output directory. Move it away. |

## `xless setup`

Natively (the default):

| Symptom | What to do |
|---|---|
| `a native setup needs python3, unzip, …, which are not on PATH` | Install them; the message prints the `apt-get install` line for Debian and Ubuntu ([native-install.md](native-install.md#what-it-needs)). |
| `the Swift toolchain does not run on this machine: …` | A library Swift's toolchain links against is missing (the cause names it). Install the packages the message lists, then run `xless setup` again (it downloads the toolchain again). |
| `… has sha256 …, not versions.env's …: nothing was installed` | The download is not the pinned file (cut short by a proxy, or changed upstream). Run `xless setup` again; if it persists, report it. |
| `… GB free under … for the native install (…)` | Free some space, or put the native install on a larger disk: `XLESS_NATIVE_HOME=/big/disk/xless-native xless setup …` (set it for `xless run` too). |
| `--arch … needs --docker` | A native setup installs for this machine's architecture only. Drop `--arch`, or build the images with `--docker`. |
| `a native setup runs on Linux only` | On a Mac, build the images: `xless setup --docker --xcode …`. |
| `xcode: "…" is pinned, but … SDK from Xcode …` when building | The native install holds another Xcode. Run `xless setup --xcode <that Xcode's .xip>` (it replaces the installed one), or build in its images with `--docker`. |
| `a --config overlay (Tauri, plain Cargo, React Native) builds in the xless images` | Overlays build in Docker only: `xless setup --docker --xcode …` once, then `xless run --docker --config …`. |

With `--docker`:

| Symptom | What to do |
|---|---|
| `docker is not installed (or not on PATH)`, or `` `docker info` failed `` | Check that `docker info` works in your shell. If Docker is missing, install Docker Engine with the buildx plugin: <https://docs.docker.com/engine/install/>. |
| `Docker refused the connection: permission denied on its socket` | Add yourself to the `docker` group: `sudo usermod -aG docker $USER`, then log out and in again (or run `newgrp docker`). |
| `cannot connect to the Docker daemon` | Start Docker: `sudo systemctl start docker`. |
| `docker buildx is not available` | Install Docker's buildx plugin (the `docker-buildx-plugin` package on Docker's own apt and dnf repositories). |
| `… GB free under … for the cache (the SDK export, …)` | Free some space, or put the cache on a larger disk: `XDG_CACHE_HOME=/big/disk/cache xless setup …`. See the disk check below. |
| `… GB free under … for Docker's data root (…)` | Free some space (`docker system prune`), or move Docker's data root to a larger disk. See the disk check below. |
| `… is not a supported Xcode (supported: Xcode 26.0.1 (17A400), Xcode 26.1 (17B55), Xcode 26.2 (17C52), Xcode 27.0 (27A266a), Xcode 27.1 (27A9275), Xcode 27.2 (27B52))` | The file is not one of the supported downloads: another Xcode version, a beta, or an incomplete download. Download a supported one ([apple-requirements.md](apple-requirements.md#how-to-get-xcode-on-linux)). |
| `… contains ':', which docker cannot mount` | Move or rename the `.xip` so that its path has no `:`. |
| Setup was interrupted | Run the same command again. A half-written SDK export or download is deleted, never reused; installed tools and images already built are kept. |
| `the images *:local-<arch>-xcode<V> are another build of Xcode <V>` | Images from another build of the same Xcode version (a beta) exist. `XLESS_XCODE_RETAG=1 xless setup …` keeps them under a `-xcode<V>-<build>` tag and builds the new ones. |
| `this xless is a development build … there is no release to download the linux-<arch> xless from` | Only with `--arch` for the other architecture and an xless built from source: set `XLESS_BIN_ARM64` or `XLESS_BIN_AMD64` to a Linux `xless` binary of that architecture. |

### The disk check

Before it runs anything, `xless setup` checks the free space in two places, per architecture it builds (`--arch`;
natively, this machine's only):

| Where | Asked for | Why | Set by |
|---|---|---|---|
| The cache: `$XDG_CACHE_HOME/xless`, else `~/.cache/xless` | 17 GB, only when this run exports the SDK | xtool unpacks the `.xip` into the SDK export there (measured peak about 15 GB); about 3.5 GB stays | `XLESS_SETUP_CACHE_GB` |
| The native home: `$XLESS_NATIVE_HOME`, else `~/.local/share/xless-native` (native only) | 10 GB, unless nothing is left to install | the Swift toolchain (about 4 GB unpacked, from a 1.1 GB download), xtool, rcodesign and the installed SDK (about 3.5 GB) | `XLESS_SETUP_NATIVE_GB` |
| Docker's data root (`docker info`, `/var/lib/docker` by default; checked on Linux, with `--docker` only) | 40 GB | the four images and their build cache (measured about 31 GB for the first chain) | `XLESS_SETUP_DOCKER_GB` |

The figures are decimal GB (10^9 bytes), from `versions.env`, measured on first runs from the Xcode 26.2 and 27.0
`.xip`s ([acceptance-m5.md](acceptance-m5.md)). With `--arch arm64 --arch amd64` each is doubled. The refusal names the
directory it checked, the free and the needed space, and the variable. If you know a run needs less, for example
because most image layers are already built, set that variable to the GB per architecture to ask for:
`XLESS_SETUP_DOCKER_GB=10 xless setup …`. `xless setup --dry-run` prints what the check asks for.

A native install needs nothing after an upgrade of xless. To put a newer xless into the images, run
`xless setup --docker` again: the images are rebuilt around the new
`xless` (the SDK export is reused), and the previous ones stay on disk without a tag until `docker image prune`
removes them.

`xless setup --reexport` exports the SDK again even when the cache has it. The cache is
`$XDG_CACHE_HOME/xless`, else `~/.cache/xless`; deleting it costs only a new export.

### Without the .xip

The `.xip` is needed only to export the SDK. Once an export exists, `xless setup` (native or `--docker`) can run
from it instead, for example on a CI runner that kept `~/.cache/xless` but lost its images:

- `xless setup --docker` with neither `--xcode` nor `--sdk` reuses the export in `~/.cache/xless/sdk/` when exactly
  one export there, of a supported Xcode, holds every architecture the run sets up.
- `xless setup --docker --sdk <dir>` names the export: the directory that holds `<arch>/darwin.xtoolsdk` and
  `toolchain-meta.json`, such as `~/.cache/xless/sdk/xcode27.0-27A266a`, which may be anywhere.

The Xcode is read from the export's `toolchain-meta.json` (or, without one, from its `xcode<version>-<build>` name)
and must be one `versions.env` supports. Nothing is exported, so the disk check skips the cache.

| Symptom | What to do |
|---|---|
| `no --xcode, and no SDK export under … to reuse` | Nothing to reuse: pass the Xcode, `xless setup --xcode <Xcode.xip>`. |
| `… holds 2 SDK exports for …` | Pick one with `--sdk <dir>`, or pass `--xcode`. |
| `no SDK export under … holds amd64 …`, or `the SDK export … holds no amd64 SDK` | The export has no SDK for that architecture: pass `--xcode` to export it, or drop that `--arch`. |
| `… holds no SDK export (<arch>/darwin.xtoolsdk)` | `--sdk` takes the export itself, not its `<arch>` directory or the `darwin.xtoolsdk` inside it. |
| `… is an SDK export of Xcode build …, not a supported Xcode` | That Xcode is no longer supported: set up a supported one with `--xcode`. |
| `--reexport exports the SDK again, which needs the Xcode` | Add `--xcode <Xcode.xip>`. |

## Building

| Symptom | What to do |
|---|---|
| `Unable to find image 'xless:local-arm64'` (or `-amd64`), `pull access denied` | With `--docker`, no image for an unpinned project: run `xless setup --docker` with Xcode 27.0, or pin the Xcode you set up in `xless.yml`, for example `xcode: "26.2"`. |
| `… pins xcode: "…", but these images are missing: …` (exit 2) | Build that Xcode's images: `xless setup --docker --xcode <that Xcode's .xip>`. |
| `testflight: set ASC_KEY_ID in the environment or …` (exit 2) | The run includes `sign`. Set up the secrets ([signing-and-testflight.md](signing-and-testflight.md#one-command-testflight)), or stop before signing with `--to finalize`. |
| `testflight: the work copy … is in use by another run (pid …)` (exit 2) | Another `xless run` is building the same project or overlay ([one run per work copy](signing-and-testflight.md#one-command-testflight)). Wait for it to end, or stop it with the `kill` the message names. Its containers are removed when it stops. |
| `==> work copy …: the run that held it (pid …) is gone without cleaning up` | Not an error: an earlier run was killed with SIGKILL (a CI runner's timeout, the OOM killer, `kill -9`). This run stops what it left, its containers or its xless, then builds. |
| `testflight: the step of the run that held the work copy … does not stop` (exit 2) | The killed run's xless ignored SIGTERM for 5 seconds. Stop it with the `kill -9` the message names, then run again. |
| `… /xless.yml not found (is '…' an xless project?)` | `xless run` takes the project directory, the one holding `xless.yml`; overlay apps take `--config <overlay.yml>`. |
| `rm: … Permission denied` in a project you built with `--docker` | The build container runs as root, so the files it creates in the project (`.xless`, `.build`, `.bsp`, `xtool`, `xtool.yml`) belong to root. `sudo rm -rf .xless .build .bsp xtool xtool.yml`, or hand them back: `docker run --rm -v "$PWD":/work -w /work alpine chown -R "$(id -u):$(id -g)" .xless .build .bsp xtool xtool.yml`. |

## App Store Connect

`xless upload` maps App Store Connect errors to explanations; unknown codes are printed verbatim. Network calls retry
only on HTTP 5xx, 429 and transport errors (at most 5 attempts); nothing else is retried.

| Symptom | Meaning and fix |
|---|---|
| 90725 | The SDK version in a binary's `LC_BUILD_VERSION` was not patched. This is an xless bug; report it with `xless inspect` output. |
| 90189, 90062, "bundle version must be higher", "Redundant Binary" | This build number was already uploaded, or is not higher than an earlier upload of this version (from any machine). Use a higher one (`--build-number` / `XLESS_BUILD_NUMBER`, see [build numbers](signing-and-testflight.md#build-numbers)) or bump `version`. |
| 90717 | An app icon has an alpha channel. Re-export it without transparency. |
| 90022, 90023, 90713, 90704 | App icon problem. See [known gaps](research/parity-known-gaps.md). |
| 90135 | A binary carries a secure timestamp. App Store signing must use no timestamp server. This is an xless bug if you see it. |
| 90562 | `Assets.car` is invalid. Retry without `assets:` to isolate it, and report it as an xless bug (AssetKit is vendored in `ThirdParty/AssetKit`). A maintainer can check the file with `xcrun assetutil --validate-file Assets.car` on a Mac (`make parity` does this). See [known gaps](research/parity-known-gaps.md). |
| 90534, 90111, "Invalid Toolchain" | App Store Connect rejected the toolchain metadata. Report it with `xless inspect` output; a maintainer compares it with an Xcode build using `make parity`. |
| 90683 | A usage-description string (`NS…UsageDescription`) is missing. Add it via `infoPlist` in `xless.yml`. |
| 91053, "privacy manifest" | The privacy manifest lacks a required-reason API declaration. Update `PrivacyInfo.xcprivacy`. |
| 90208, "MinimumOSVersion" | Info.plist `MinimumOSVersion` disagrees with the binary. Align the `platforms` in `Package.swift` with `xless.yml`. |

Other things worth knowing:

- Apple's upload requirements (checked 2026-10-13): built with SDK 26 or later; iOS minimum OS 13.0 or later.
  `finalize` refuses older SDKs.
- Loose `.dylib` files are rejected at `finalize`; xless does not wrap them as frameworks.
- `finalize` refuses a Mach-O image whose LINKEDIT tables `dyld` would reject as misaligned (the app would crash at
  launch); `xless inspect` lists them per binary (`linkeditProblems`).
- The App Store Connect app record cannot be created through the API; create it by hand after the bundle ID is
  registered ([bootstrap.md](bootstrap.md) steps 4 and 5).

## Known gaps

- One `Assets.car` difference from Xcode output that matters (no MultiSized Image rendition for the app icon) comes
  from AssetKit; transparent images and colorsets now match actool's (`Opaque`, colour space, scale). See
  [research/parity-known-gaps.md](research/parity-known-gaps.md).
- Single-size app icon sets with dark or tinted variants are not handled. xless falls back to AssetKit's output, and
  the resulting `CFBundleIcons` may be malformed (not verified against App Store Connect). Use a plain single 1024px
  icon.
- Whether App Store Connect accepts the build despite these gaps has not been confirmed (needs a real upload).
- The Apple limits that `sign bootstrap` enforces (3 Distribution, 5 Developer ID certificates per team) are
  unconfirmed against Apple documentation.
- App Store Connect upload API notes: [research/asc-build-uploads.md](research/asc-build-uploads.md).
- The amd64 images have run under Rosetta on an Apple-silicon Mac, not yet on a native x86_64 host
  ([acceptance-m4.md](acceptance-m4.md)).
