# Building the images by hand

`xless setup --docker --xcode <Xcode.xip>` is the supported way to build the images (without `--docker`, `xless setup`
installs natively instead: [native-install.md](native-install.md)). This page shows the same steps as plain
commands, for when you want to see what each one does, change a Dockerfile, or build one image again. Everything here
uses the files the release installed in `~/.local/share/xless`; no source checkout is needed.

To see the exact commands `xless setup --docker` would run on your machine, with your paths, run it with `--dry-run`:

```sh
xless setup --docker --xcode ~/Downloads/Xcode_27.xip --dry-run
```

## The chain

Four images, each built on the previous one, per architecture:

| Image | Built from | What it adds |
|---|---|---|
| `xless-base` | `docker/Dockerfile.base` | Swift, the `xless` binary, xtool and rcodesign. No Apple file. |
| `xless` | `docker/Dockerfile.sdk` | The Darwin SDK exported from Xcode, its `toolchain-meta.json`, and the open-source Swift release that matches the Xcode's Swift |
| `xless-tauri` | `docker/Dockerfile.tauri` | Node, pnpm, the Rust installer, LLVM binutils and the DMG tools |
| `xless-rn` | `docker/Dockerfile.rn` | Ruby, Bundler, Swift Build, Hermes `hermesc` and the Xcode tool replacements (`docker/shims`) |

Every download in the Dockerfiles is pinned by sha256 in `versions.env`. `scripts/docker-images.sh` reads those pins,
passes them as build arguments and runs `docker buildx build --load` with `share/xless` as the build context.

## The steps

Set the variables once. The values below are for Xcode 27.0 on an arm64 machine; for Xcode 26.2 use `V=26.2` and
`B=17C52`, and on an x86_64 machine `A=amd64`.

```sh
S=~/.local/share/xless                    # the installed share directory
XIP=~/Downloads/Xcode_27.xip              # the Xcode download
A=arm64                                   # Docker architecture: arm64 or amd64
V=27.0 B=27A266a                          # the Xcode's version and build
SUFFIX=-xcode$V-$B                        # tag suffix: xless-base:local-arm64-xcode27.0-27A266a
SDK=~/.cache/xless/sdk/xcode$V-$B         # where the exported SDK goes
```

**1. `xless-base`**, with the `xless` binary you installed. `scripts/docker-images.sh` takes a file named `xless` and
uses its directory as a build context, so copy it into an empty directory first:

```sh
BIN=$(mktemp -d) && cp ~/.local/bin/xless "$BIN/xless"
"$S/scripts/docker-images.sh" base --arch $A --suffix $SUFFIX --xless-bin "$BIN/xless"
```

The binary must be the Linux `xless` of that architecture (the script checks). For the other architecture take the
binary from that architecture's release tarball.

**2. Export the Darwin SDK.** xtool, which is open source, unpacks the `.xip` inside `xless-base` and writes the SDK.
The output directory must exist and be empty, so that Docker does not create it as root. If an earlier export was
interrupted, delete what it left first (`rm -rf "$SDK/$A"`):

```sh
mkdir -p "$SDK/$A"
docker run --rm --platform linux/$A --user "$(id -u):$(id -g)" -e HOME=/tmp -w /tmp \
  -v "$XIP":/xcode/Xcode.xip:ro -v "$SDK/$A":/out \
  xless-base:local-$A$SUFFIX xtool sdk build /xcode/Xcode.xip /out
```

With rootless Docker leave out `--user …`. The result is `$SDK/$A/darwin.xtoolsdk`, about 3 GB (xtool unpacks the `.xip` under `$SDK/$A` first: about 15 GB at the peak).

**3. `toolchain-meta.json`.** xless reads the SDK's version files (no program from the SDK runs) and the
supported-Xcode table in `versions.env`:

```sh
xless sdk meta --from-xtoolsdk "$SDK/$A/darwin.xtoolsdk" --xcode-build $B --out "$SDK/toolchain-meta.json"
```

**4. `xless`, `xless-tauri` and `xless-rn`:**

```sh
"$S/scripts/docker-images.sh" sdk --arch $A --suffix $SUFFIX --sdk-dir "$SDK" --xcode-build $B
"$S/scripts/docker-images.sh" tauri --arch $A --suffix $SUFFIX
"$S/scripts/docker-images.sh" rn --arch $A --suffix $SUFFIX
```

For the `sdk` image, `scripts/xcode-swift.sh` picks the open-source Swift release that matches the Xcode's Swift
(`XCODE_SWIFT_<build>` in `versions.env`). For Xcode 26.2 that is Swift 6.2.3, which the image downloads.

**5. The tags a build looks for.** A project that pins `xcode: "26.2"` runs in `<image>:local-<arch>-xcode26.2`; a
project without a pin runs in `<image>:local-<arch>`, which `xless setup` gives to the default Xcode (27.0) only:

```sh
for i in xless-base xless xless-tauri xless-rn; do
  docker tag $i:local-$A$SUFFIX $i:local-$A-xcode$V
done
# for Xcode 27.0 only:
for i in xless-base xless xless-tauri xless-rn; do docker tag $i:local-$A$SUFFIX $i:local-$A; done
```

## Changing an image

A new release of xless replaces `~/.local/share/xless`. To keep your changes, copy the share directory and build from
the copy:

```sh
cp -r ~/.local/share/xless ~/xless-share
S=~/xless-share
```

Then edit `$S/docker/Dockerfile.*` (or a pin in `$S/versions.env`) and run the steps above from the image you changed
onwards: each image is built on the previous one of the same architecture and suffix.

## Another architecture

`--arch` replaces the default (this machine's architecture): `xless setup --docker --xcode … --arch amd64` builds only the
amd64 chain, and `--arch arm64 --arch amd64` builds both. A chain for another architecture than the machine's runs
under emulation: 2 to 3 times slower under Rosetta, slower still under QEMU. Use a Docker that runs the other architecture through Rosetta (an Apple-silicon
Mac) or a native host when you can: under QEMU's user-mode emulation gcc and Swift have crashed at random. The `xless`
binary for the other architecture comes from the release tarball (checked against `SHA256SUMS`), or from
`XLESS_BIN_ARM64` / `XLESS_BIN_AMD64` when set.
