# The Docker images

`xless setup --docker --xcode <Xcode.xip>` builds the image that `xless run --docker` builds and signs apps in (without
`--docker`, `xless setup` installs natively instead: [native-install.md](native-install.md)). Everything is built on your
machine: xless never pulls an image of its own from a registry, and never pushes one.

## What there is

**One image per Xcode and architecture**, `xless:local-<arch>-xcode<version>` (for example
`xless:local-arm64-xcode27.0`). It holds what xless does, for any app: Swift and the open-source Swift release that
matches that Xcode's Swift, `xless`, xtool, rcodesign, the Darwin SDK exported from the Xcode, Swift Build, stand-ins for
Xcode's command-line tools (`docker/shims`), LLVM's binutils and the DMG tools. A Swift-only project builds in it.

**A kit for the apps that need other toolchains**, a small image on top of that one:

| Kit | Image | For | What it adds |
|---|---|---|---|
| `tauri` | `xless:local-<arch>-xcode<version>-tauri` | Tauri and Cargo apps | Node, pnpm (corepack) and Rust's installer |
| `react-native` | `xless:local-<arch>-xcode<version>-react-native` | React Native and Expo apps | Node, pnpm (corepack), Ruby, Bundler and `hermesc` |

You never have to know about the kits: `xless run --docker` builds the one an app needs when it is missing or older than
xless's Dockerfile or image, says so, and uses it from then on. To build them ahead of that, for example on a machine
that will be offline:

```sh
xless setup --docker --with tauri,react-native                       # on the image that is there (the newest Xcode's)
xless setup --docker --xcode ~/Downloads/Xcode_27.xip --with tauri    # with the image itself
```

`cargo` and `expo` are other names of the two. For Xcode 26.6 on arm64, the image takes 13 GB, the kits 0.3 and 0.7 GB more,
and from the `.xip` they take about 11 minutes, half a minute and 3 minutes on 4 CPUs.

**Which one a run uses:** the image of the Xcode that the project pins (`xcode: "26.2"`), and without a pin the image
of the newest Xcode there is one of. The run says which.

**Which step runs where:** the app's build (and nothing else) runs in the kit's image, without any secret. The steps
that hold a secret (the next build number, signing, the upload) run in the xless image, where no toolchain of another
language is. A Swift-only project's `xless ship` is one container of the xless image
([security.md](security.md)).

## An image of your own

When an app needs something more (a system library, a code generator), write a Dockerfile on the local image, or on a
kit's, and build it:

```Dockerfile
ARG XLESS_IMAGE
FROM ${XLESS_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler && rm -rf /var/lib/apt/lists/*
```

```sh
docker build --pull=false --build-arg XLESS_IMAGE=xless:local-arm64-xcode27.0-tauri -t my-app-image ./image
```

Then name it in xless.yml or the overlay, or with the environment variable, which wins over the file:

```yaml
image: my-app-image
```

```sh
XLESS_IMAGE=my-app-image xless run --docker --config app.yml
```

- It is used for the build step alone: the steps with the secrets run in the xless image of the same Xcode. For a
  Swift-only project this makes the run two containers instead of one, and the one that builds has no secret.
- xless never builds it for you: your project's Dockerfile is code, and building it is your decision. Build it again
  after each `xless setup` of that Xcode and after each new xless.
- It must be built on the local image of the Xcode the project pins, as that image is now. xless checks the labels that
  it stamps on its images and a derived image inherits (`docker image inspect my-app-image`): `dev.xless.sdk` (the
  Xcode build whose SDK it holds), `dev.xless.xcode`, `dev.xless.arch` and `dev.xless.version`; and that the xless image's
  layers are the first layers of it. Another Xcode or architecture, an older xless, or labels without the layers are
  refused (exit 2) with the command that fixes it. Labels are a consistency check, not a proof of where an image comes
  from: anybody can write one.
- It holds Apple's SDK, as every image built on the xless one. Never push it to a registry others can read.

`docker/tauri/Dockerfile` and `docker/react-native/Dockerfile` in `~/.local/share/xless` are ordinary Dockerfiles of the
same form: copy one to start from it, for example for a React Native release that needs another `hermesc`
(`HERMES_TAG`).

## Building the image by hand

This is what `xless setup --docker` runs, as plain commands, for when you want to see what each one does or change the
Dockerfile. Everything uses the files the release installed in `~/.local/share/xless`; no source checkout is needed. To
see the exact commands for your machine, with your paths, run it with `--dry-run`:

```sh
xless setup --docker --xcode ~/Downloads/Xcode_27.xip --dry-run
```

Once the SDK is exported (step 2 below), the `.xip` is no longer needed: `xless setup --docker` with no `--xcode`
rebuilds the image from the export in `~/.cache/xless/sdk/`, and `--sdk <dir>` names an export kept elsewhere
([troubleshooting.md](troubleshooting.md#without-the-xip)).

Every download in `docker/Dockerfile` is pinned by sha256 in `versions.env` (the kits' Dockerfiles hold their own pins).
`scripts/docker-images.sh` reads those pins, passes them as build arguments and runs `docker buildx build --load` with
`share/xless` as the build context.

Set the variables once. The values below are for Xcode 27.0 on an arm64 machine; for Xcode 26.2 use `V=26.2` and
`B=17C52`, and on an x86_64 machine `A=amd64`.

```sh
S=~/.local/share/xless                    # the installed share directory
XIP=~/Downloads/Xcode_27.xip              # the Xcode download
A=arm64                                   # Docker architecture: arm64 or amd64
V=27.0 B=27A266a                          # the Xcode's version and build
SDK=~/.cache/xless/sdk/xcode$V-$B         # where the exported SDK goes
```

**1. The tools to export the SDK with**: Swift, xtool and rcodesign, without any Apple file.

```sh
"$S/scripts/docker-images.sh" tools --arch $A      # xless:local-<arch>-setup
```

**2. Export the Darwin SDK.** xtool, which is open source, unpacks the `.xip` inside that image and writes the SDK.
The output directory must exist and be empty, so that Docker does not create it as root. If an earlier export was
interrupted, delete what it left first (`rm -rf "$SDK/$A"`):

```sh
mkdir -p "$SDK/$A"
docker run --rm --pull=never --platform linux/$A --user "$(id -u):$(id -g)" -e HOME=/tmp -w /tmp \
  -v "$XIP":/xcode/Xcode.xip:ro -v "$SDK/$A":/out \
  xless:local-$A-setup xtool sdk build /xcode/Xcode.xip /out
docker image rm xless:local-$A-setup
```

With rootless Docker leave out `--user …`. The result is `$SDK/$A/darwin.xtoolsdk`, about 3 GB (xtool unpacks the `.xip` under `$SDK/$A` first: about 15 GB at the peak).

**3. `toolchain-meta.json`.** xless reads the SDK's version files (no program from the SDK runs) and the
supported-Xcode table in `versions.env`:

```sh
xless sdk meta --from-xtoolsdk "$SDK/$A/darwin.xtoolsdk" --xcode-build $B --out "$SDK/toolchain-meta.json"
```

**4. The image**, with the `xless` binary you installed. The script takes a file named `xless` and uses its directory as
a build context, so copy it into an empty directory first:

```sh
BIN=$(mktemp -d) && cp ~/.local/bin/xless "$BIN/xless"
"$S/scripts/docker-images.sh" image --arch $A --xcode $V --xcode-build $B --sdk-dir "$SDK" --xless-bin "$BIN/xless"
```

The binary must be the Linux `xless` of that architecture (the script checks) and of the share directory's release. For
the other architecture take the binary from that architecture's release tarball. `scripts/xcode-swift.sh` picks the
open-source Swift release that matches the Xcode's Swift (`XCODE_SWIFT_<build>` in `versions.env`). For Xcode 26.2 that
is Swift 6.2.3, which the image downloads.

**5. The kits**, when you need them: `xless setup --docker --with tauri,react-native`. (A kit built by hand has none of the
labels xless knows its own by, so a run builds it again; give a changed one a name of its own, as above.)

## Changing the image

A new release of xless replaces `~/.local/share/xless`. To keep your changes, copy the share directory and build from
the copy:

```sh
cp -r ~/.local/share/xless ~/xless-share
S=~/xless-share
```

Then edit `$S/docker/Dockerfile` (or a pin in `$S/versions.env`) and run step 4 above; the kits on it are built again when
they are needed next. The copy keeps the release's `VERSION` file: if you point `XLESS_SHARE` at it, xless refuses it once
you upgrade ([troubleshooting.md](troubleshooting.md#installing)), so copy the new share and make your changes again. For
something added on top, an [image of your own](#an-image-of-your-own) is simpler.

## Another architecture

`--arch` replaces the default (this machine's architecture): `xless setup --docker --xcode … --arch amd64` builds only the
amd64 image, and `--arch arm64 --arch amd64` builds both. An image for another architecture than the machine's is built
under emulation: 2 to 3 times slower under Rosetta, slower still under QEMU. Use a Docker that runs the other architecture through Rosetta (an Apple-silicon
Mac) or a native host when you can: under QEMU's user-mode emulation gcc and Swift have crashed at random. The `xless`
binary for the other architecture comes from the release tarball (checked against `SHA256SUMS`), or from
`XLESS_BIN_ARM64` / `XLESS_BIN_AMD64` when set.

## From xless 0.10 and older

Those built a chain of four images (`xless-base`, `xless`, `xless-tauri`, `xless-rn`), tagged `local-<arch>` and
`local-<arch>-xcode<version>`. Run `xless setup --docker` once (from the SDK it exported before, so without the `.xip`):
nothing has to be tagged by hand. Then:

- `xless clean --old` removes the old tags (it shows them and asks; `xless setup` says when there are any).
- `XLESS_IMAGE` still works and is checked as [above](#an-image-of-your-own): an image of the old chain has no labels, so
  it is refused. `XLESS_SIGN_IMAGE` still works for React Native, with a notice: nothing needs it any more.
- The tag `xless:local-<arch>`, without an Xcode, is still used for the Xcode its labels name when it has them, with a
  notice; a later release stops looking at it.
