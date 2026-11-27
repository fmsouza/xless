# The Docker image and the Xcode packs

`xless setup --docker --xcode <Xcode.xip>` builds the image that `xless run --docker` builds and signs apps in, and
prepares the Xcode pack that the image builds with (without `--docker`, `xless setup` installs natively instead:
[native-install.md](native-install.md)). The image holds nothing of Apple's; everything of an Xcode is in its pack, which
every container of a run gets read-only. Everything is built on your machine: xless never pulls an image of its own from
a registry, and never pushes one. (`docker build` fetches what its Dockerfiles start `FROM` when that is not on the
machine: Swift's image from Docker Hub for the xless image. The kits start from the local xless
image.)

## What there is

**One image per xless and architecture**, `xless:<version>-<arch>` (for example `xless:1.4.0-arm64`; built from a source
checkout, `xless:<commit>-<arch>`, with `-dirty` after the commit when the checkout has changes). It holds what xless does,
for any app and any Xcode: Swift, `xless`, xtool, rcodesign, stand-ins for Xcode's command-line tools (`docker/shims`),
LLVM's binutils, the DMG tools, and what prepares an Xcode pack. It holds **no Apple file**: no SDK, no Xcode metadata, no
label or build argument that names an Xcode (`make test-image` checks every layer, label and build argument of it). So Apple's
terms no longer keep it off a registry. It does hold other projects' software under their own licences (among them Swift,
LLVM, xtool, rcodesign, libdmg-hfsplus under the GPL 3 and hfsprogs under the APSL, as programs), and those have not been
reviewed for publishing the image: keep it on your machines and registries of your own until they are. For arm64 it takes about 6.5 GB, and building it takes a few minutes.

**A kit for the apps that need other toolchains**, a small image on top of that one, Xcode-independent too:

| Kit | Image | For | What it adds |
|---|---|---|---|
| `tauri` | `xless:<version>-<arch>-tauri` | Tauri and Cargo apps | Node, pnpm (corepack) and Rust's installer |
| `react-native` | `xless:<version>-<arch>-react-native` | React Native and Expo apps | Node, pnpm (corepack), Ruby, Bundler and `hermesc` |

You never have to know about the kits: `xless run --docker` builds the one an app needs when it is missing or older than
xless's Dockerfile or image, says so, and uses it from then on. To build them ahead of that, for example on a machine
that will be offline:

```sh
xless setup --docker --with tauri,react-native                       # on the image; it needs no Xcode
xless setup --docker --xcode ~/Downloads/Xcode_27.xip --with tauri    # with the image and that Xcode's pack
```

`cargo` and `expo` are other names of the two. The `tauri` kit takes about 0.3 GB on top of the image; building it took 18
to 33 seconds on an arm64 Mac. The `react-native` kit takes about 0.8 GB; building it took 2 min 30 s there, in the one
build measured (it compiles Ruby and `hermesc`).

**One Xcode pack per Xcode build and architecture.** Everything that depends on an Xcode:

| In the pack | Whose |
|---|---|
| The Darwin SDK exported from the Xcode, installed for xtool and SwiftPM (`config/`), and its `toolchain-meta.json` | Apple's |
| The open-source Swift toolchain of that Xcode's Swift ([which one](xcode-versions.md#the-versions)), fitted to the SDK (`toolchain/`, `include/`, the record `swift-toolchain.json`) | swift.org's |
| Swift Build, compiled with that toolchain (`swift-build/`) | open source |
| `pack.json`: the Xcode version and build, the architecture, and the recipe hash of each part | xless's |

A pack has two parts, `sdk` (the SDK, its metadata and the fitted toolchain) and `swift-build`. Each has a **recipe hash**
in `pack.json`: a digest of what that part is made from (the Xcode build, the pinned toolchain, xtool's version, Swift
Build's pinned sources, and the scripts and files of xless that prepare it), and of nothing else, not xless's version. So
a pack is prepared once per machine and kept across xless releases: a new xless prepares nothing unless what a part is made
from has changed, and then only that part. A pack takes 6.7 to 7.3 GB (decimal; Xcode 26.2 and 27.0 on arm64). It holds
Apple's SDK: **never push or publish a pack.**

**The SDK export** is what a pack is prepared from: `~/.cache/xless/sdk/xcode<version>-<build>/` (`<arch>/darwin.xtoolsdk`
and `toolchain-meta.json`, about 3 GB), which `xless setup` writes once from the `.xip`. Once it is there the `.xip` is not
needed any more. It holds Apple's SDK too: it is what you back up and copy to another machine of yours, never to a
registry ([maintainers.md](maintainers.md#images-on-other-machines)).

## Which Docker

Every xless command that talks to Docker uses the same one: `xless setup --docker`, `xless run --docker`, `xless clean`,
`xless sdk export`, and a native setup when it asks whether a running build uses a pack. It is the context
`DOCKER_CONTEXT` names, else `colima-xless` when that context exists, else docker's current one. `DOCKER_CONTEXT` is read
from the environment, or from `testflight.env` (`XLESS_TESTFLIGHT_ENV`), whose value wins, as it does for `xless run`. A
pack volume is in the daemon that prepared it, so a run finds what setup prepared only in the same one. The repository's
scripts choose the same way (`scripts/docker-context.sh`; [maintainers.md](maintainers.md)).

A `DOCKER_CONTEXT` that docker does not have stops the command before it does anything, with exit 2 and the contexts
there are. `xless setup --docker` prints:

```
error: [config] DOCKER_CONTEXT is colima-xless (set in the environment), but docker has no context of that name; its contexts: colima, default — set DOCKER_CONTEXT to one of them in the environment, or remove it there: xless then uses colima-xless when that context exists, else docker's current one
```

(`xless run` prints the same after `testflight: `, with `;` before what to do.) Set `DOCKER_CONTEXT` to a context that
`docker context ls` lists, or remove it.

## Where the packs are

| | Where | Chosen by |
|---|---|---|
| `--docker`, by default | One Docker volume per pack, `xless-xcode-<version>-<build>-<arch>` (for example `xless-xcode-26.2-17C52-arm64`). Mounted at `/xcodes`, it holds the pack at `/xcodes/26.2-17C52-arm64` | nothing to set |
| `--docker`, in a directory | A directory of the host, one sub-directory per pack (`26.2-17C52-arm64/`) | `XLESS_XCODES=<directory>` |
| Natively, on Linux | `<native home>/xcodes/`, by default `~/.local/share/xless-native/xcodes/` | `XLESS_XCODES` too |

Several Xcodes live side by side in each: `xless setup` with another Xcode adds its pack beside the others. A project's
`xcode: "26.2"` chooses the pack of that version, and without a pin the newest Xcode there is a pack of is used. When two
builds of one version have a pack (a beta and the release), the one that comes later in `versions.env`'s Xcode table
(`XCODE_RELEASES`) is used, and the run says which.

A directory store is on the host's file system, and the SDK has headers whose names differ only in case (`Endian.h`,
`endian.h`): it must be on a case-sensitive file system, and `xless setup` refuses one that is not before it writes
anything. On a Mac, keep the default volumes: a Mac's disk is case-insensitive unless you made a volume that is not, and the
Docker volumes are on the virtual machine's own disk. A directory store is for a Linux host that wants the packs on a disk
of its own, or shares them between `--docker` and a native xless; then run a native `xless setup` only while no `xless run
--docker` builds, as a native setup does not see the containers that use a pack
([security.md](security.md#the-xcode-packs)). A directory store, and rootless Docker, are covered by xless's tests but
have not been tried on a real machine yet.

**Which pack a command uses.** Every command that needs the Xcode looks it up the same way, on a host and in a container:
`XLESS_XCODE=<pack directory>` names one pack and wins; else the store, `XLESS_XCODES`, by the pin or the newest. The
older variables still override single parts: `XLESS_TOOLCHAIN_META` (the SDK's metadata), `XLESS_SWIFT_TOOLCHAIN` (the
toolchain record), and an SDK installed under `XDG_CONFIG_HOME` (only together with `XLESS_TOOLCHAIN_META` when a pack is
found). With no pack, a command that needs one stops with the usage exit code (2) and the `xless setup` command that
prepares it; so does one whose pack was prepared by another recipe (it is stale). `xless build` of an iOS app runs
`xtool dev build` with `XDG_CONFIG_HOME` set to a directory of its own (`~/.cache/xless/xtool-config/<pack>`, which links to
the pack's SDK, so nothing writes into the pack): your own SwiftPM configuration (`$XDG_CONFIG_HOME/swiftpm`, else
`~/.swiftpm`), such as its mirrors or registries, is not read by that build.

## Preparing a pack

```sh
xless setup --docker --xcode ~/Downloads/Xcode_27.xip    # the image, the SDK export and the pack
xless setup --docker --sdk ~/.cache/xless/sdk/xcode26.2-17C52   # from an export: no .xip
xless setup --docker                                      # from the cache's one export, or the image alone
```

`xless setup --docker` builds the image of this xless when it is not there, then starts one container of it that prepares
the pack: the image's own `xless setup`, with the Xcode (or the export) mounted read-only, the export's directory in the
cache, and the store read-write; no project, no secret, and nothing else of the machine. It is the only container that
ever writes a pack. A pack that is current for this xless is left as it is (`nothing to prepare`); a part that is not is
prepared again by itself. With neither `--xcode` nor `--sdk` and no export in the cache, setup builds the image alone and
says that no pack was prepared. `--dry-run` prints each step and its command.

Measured on an arm64 Mac: preparing a whole pack from the export took 6 min 24 s (Xcode 26.2) and 6 min 55 s (27.0), of
which compiling Swift Build took 4 min 7 s and 4 min 16 s; preparing the `sdk` part of the 26.2 pack again alone took
1 min 33 s, and 2 min 43 s in an earlier run, most of it downloading and unpacking the Swift toolchain. Exporting the
SDK from the `.xip` first took 3 min 6 s more in the one export measured (setup's estimate is about two minutes), and up
to about 15 GB in the cache while the `.xip` is unpacked (about 3.5 GB stays). Setup prints its estimate with each step.

A pack that running containers use is not replaced under them: setup refuses, names the containers, and says to wait for
those runs or stop them. A native `xless setup` of a directory store that `--docker` runs mount (`XLESS_XCODES`) asks docker
too, before its first step and again right before it replaces the pack; it counts xless's own containers alone (a run's and
a pack setup's, by their labels `xless.run` and `xless.setup`), and goes on where docker does not answer
([security.md](security.md#the-xcode-packs)).

## What a run does

`xless run --docker`:

1. **The image** is this xless's, for this machine's architecture. A run never builds it: when it is missing the run stops
   (exit 2) with `xless setup --docker`, which needs no Xcode to build it. The kit an app needs is built when it is missing
   or stale ([above](#what-there-is)).
2. **The pack** of the pin, else the newest. A volume's `pack.json` is read with a short container of the image (no
   network, the volume read-only). A pack that is missing, or a part of it that is stale, is prepared first when the SDK
   export of that Xcode is in the cache: the run says so, which parts and how long each takes, and runs the same setup
   container as `xless setup --docker --sdk <export>`. Without the export it stops (exit 2) with the `xless setup --docker
   --xcode …` that prepares it.
3. **Every container of the run** gets that pack, and only that one, read-only, with `XLESS_XCODE` naming it (a run that
   starts after finalize, `--from sign` or later, reads no Xcode: it neither needs a pack nor prepares one). It is a
   mount, nothing is copied: from the command to the first line of the build step, three runs took 0.82, 0.44 and 0.44 s
   with a pack, and 0.48, 0.36 and 0.40 s with an image that had the Xcode in it (arm64 Mac). A run whose containers
   would mount a pack volume writable, or a directory that holds the store or is in it (`XLESS_XCODES` inside the
   project, for instance), is refused (exit 2) before anything runs: the build would be able to change what the steps
   after it read.

**Which step runs where:** an overlay app's build (and nothing else) runs in the kit's image, without any secret. The
steps that hold a secret (the next build number, signing, the upload) run in the xless image, where no toolchain of
another language is. A Swift-only project's `xless ship` is one container of the xless image, which builds and holds the
secrets, unless its build has an [image of its own](#an-image-of-your-own)
([security.md](security.md#a-build-that-means-harm)); the pack is read-only in each
([why](security.md#the-xcode-packs)).

## An image of your own

When an app needs something more (a system library, a code generator), write a Dockerfile on the local image, or on a
kit's, and build it:

```Dockerfile
ARG XLESS_IMAGE
FROM ${XLESS_IMAGE}
LABEL org.xless.image=own
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler && rm -rf /var/lib/apt/lists/*
```

The label says that it is not xless's own: `xless clean` then leaves its older builds alone
([uninstall.md](uninstall.md#xless-clean)).

```sh
docker build --pull=false --build-arg XLESS_IMAGE=xless:1.4.0-arm64-tauri -t my-app-image ./image
```

Then name it in xless.yml or the overlay, or with the environment variable, which wins over the file:

```yaml
image: my-app-image
```

```sh
XLESS_IMAGE=my-app-image xless run --docker --config app.yml
```

- It is used for the build step alone: the steps with the secrets run in the xless image. For a Swift-only project this
  makes the run two containers instead of one, and the one that builds has no secret, when the image is not the xless
  image itself. xless compares the two images' IDs: a tag of the xless image is the same image, and a Dockerfile that
  adds nothing to its `FROM` may be (the same ID). The run is then one container with the secrets, as without `image:`
  ([security.md](security.md#a-build-that-means-harm)). A run that builds and signs says which it is: its `==>` line that
  names the Xcode ends with `build my-app-image, signing and upload xless:1.4.0-arm64` when there are two, and with the
  xless image's name alone when there is one. The build's container gets the pack read-only, as every container of the
  run does. The project's directory is mounted whole into it, so it may not be your home directory or one above it.
- xless never builds it for you: your project's Dockerfile is code, and building it is your decision. It holds no Xcode,
  so another pin needs nothing of it; build it again after each new xless.
- It must be built on the image of this xless, as that image is now. xless checks the labels that it stamps on its images
  and a derived image inherits (`docker image inspect my-app-image`): `dev.xless.image` (which xless built the image it
  starts from) and `dev.xless.arch`, with the image's own architecture; that the image of this xless is on the machine;
  and that its layers are the first layers of yours. Another architecture, another xless, or labels without the layers
  are refused (exit 2) with the `docker build` that fixes it. Labels are a consistency check, not a proof of where an
  image comes from: anybody can write one.

`docker/tauri/Dockerfile` and `docker/react-native/Dockerfile` in `~/.local/share/xless` are ordinary Dockerfiles of the
same form: copy one to start from it, for example for a React Native release that needs another `hermesc`
(`HERMES_TAG`).

## Preparing by hand

This is what `xless setup --docker` runs, as plain commands, for when you want to see what each one does or change the
Dockerfile. Everything uses the files the release installed in `~/.local/share/xless`; no source checkout is needed. To
see the exact commands for your machine, with your paths, run it with `--dry-run`:

```sh
xless setup --docker --sdk ~/.cache/xless/sdk/xcode26.2-17C52 --dry-run
```

Every download in `docker/Dockerfile` is pinned by sha256 in `versions.env` (the kits' Dockerfiles hold their own pins).
`scripts/docker-images.sh` reads those pins, passes them as build arguments and runs `docker buildx build --load` with
`share/xless` as the build context.

Set the variables once. The values below are for Xcode 26.2 on an arm64 machine; on an x86_64 machine use `A=amd64`.

```sh
S=~/.local/share/xless                    # the installed share directory
A=arm64                                   # Docker architecture: arm64 or amd64
V=26.2 B=17C52                            # the Xcode's version and build
SDK=~/.cache/xless/sdk/xcode$V-$B         # the SDK export
IMAGE=xless:$("$S/scripts/docker-images.sh" tag --arch $A)-$A
VOLUME=xless-xcode-$V-$B-$A
```

**1. The image**, with the Linux `xless` of that architecture and of the share directory's release: on a Linux host of
that architecture the one you installed; else `bin/xless` from the release's `xless-<version>-linux-<aarch64|x86_64>.tar.gz`
(check it against the release's `SHA256SUMS`). The script takes a file named `xless` and uses its directory as a build
context, so copy it into an empty directory first:

```sh
BIN=$(mktemp -d) && cp ~/.local/bin/xless "$BIN/xless"    # on a Linux host; else the tarball's bin/xless
"$S/scripts/docker-images.sh" image --arch $A --xless-bin "$BIN/xless"
```

The script checks that the binary is a Linux one of that architecture.

**2. The volume**, of the name xless gives a pack volume (xless finds its pack volumes by that name; the label is the one
it gives the volumes it creates), and writable for you (a new volume takes the image's `/xcodes`, which anyone may write;
the second command changes nothing then):

```sh
docker volume create --label org.xless.pack=true $VOLUME
docker run --rm --pull=never --platform linux/$A --network none --mount type=volume,src=$VOLUME,dst=/xcodes $IMAGE \
  sh -c '[ "$(stat -c %u /xcodes)" = "$1" ] || [ $(( 0$(stat -c %a /xcodes) & 2 )) -ne 0 ] || chown "$1:$2" /xcodes' sh $(id -u) $(id -g)
```

**3. The pack**, by the image's own `xless setup`, from the export, read-only:

```sh
docker run --rm --pull=never --platform linux/$A --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --mount type=bind,src="$SDK",dst=/cache/xless/sdk/xcode$V-$B,readonly -e XDG_CACHE_HOME=/cache \
  --mount type=volume,src=$VOLUME,dst=/xcodes --label xless.setup=$V-$B-$A $IMAGE xless setup --sdk /cache/xless/sdk/xcode$V-$B
```

With rootless Docker leave out `--user …` (and step 2's second command). Without an export yet, the same container
exports it from the `.xip`: mount the `.xip` read-only at `/xcode/Xcode.xip` and `"$SDK"` (an empty directory you made)
writable at `/cache/xless/sdk/xcode$V-$B`, and run `xless setup --xcode /xcode/Xcode.xip`. The pack's recipe hashes are
computed from the image's copy of the share, which is the release's, so the pack is current for the xless on your machine.

**4. The kits**, when you need them: `xless setup --docker --with tauri,react-native`. To change one, make an
[image of your own](#an-image-of-your-own) from a copy of its Dockerfile.

## Changing the image

A new release of xless replaces `~/.local/share/xless`. To keep your changes, copy the share directory and build from
the copy:

```sh
cp -r ~/.local/share/xless ~/xless-share
S=~/xless-share
```

Then edit `$S/docker/Dockerfile` and run step 1 above; the kits on it are built again when they are needed next. Leave
`versions.env`, `docker/toolchain` and the scripts that prepare a pack as they are: they are what the packs' recipe hashes
are made of, the image prepares packs with its copy of them, and the xless on your machine computes the hashes from its
own share, so a pack prepared from changed ones is never current for it. The copy keeps the release's `VERSION` file: if
you point `XLESS_SHARE` at it, xless refuses it once you upgrade ([troubleshooting.md](troubleshooting.md#installing)), so
copy the new share and make your changes again. For something added on top, an [image of your own](#an-image-of-your-own)
is simpler.

## Using the image directly

A container of the image, started by hand or as a CI job's container, is a Linux host that has everything installed. In
it `XLESS_XCODES` is `/xcodes`, the share is `/usr/local/share/xless`, and `/cache` (where work copies go, and in the
`tauri` kit Rust's toolchains) may be written by anyone.

- **The account commands** need no pack: `docker run --rm -e ASC_KEY_ID -e ASC_ISSUER_ID -e ASC_KEY_P8 xless:1.4.0-arm64 xless apps list`.
- **`xless setup`** prepares a pack with the store mounted read-write, as in [step 3](#preparing-by-hand).
- **A build** needs a pack, mounted read-only. With a pack volume at `/xcodes` nothing else is set:

```sh
docker run --rm --pull=never --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --mount type=volume,src=xless-xcode-26.2-17C52-arm64,dst=/xcodes,readonly \
  -v "$PWD":/work -w /work xless:1.4.0-arm64 xless run . --build-number 1 --to finalize
```

A pack mounted elsewhere is named with `XLESS_XCODE=<where it is>`, and a directory store of the host can be mounted at
`/xcodes` read-only whole: the project's `xcode:` pin (or `XLESS_XCODE_PIN`) chooses among its packs, also for the build
that Expo's ExpoModulesJSI phase starts under `env -i` (the `xcodebuild` shim takes `XLESS_XCODES`, `XLESS_XCODE` and
`XLESS_XCODE_PIN` from the build phase's process). A Tauri or Cargo app builds the same way in the `tauri` kit's image, a React Native app in the
`react-native` kit's: the run builds an overlay wherever its tools are installed, and where they are not it names what is
missing and stops (exit 2). In the xless image itself an overlay lacks Node, Rust or Ruby.

**Keeping the build apart from the secrets is then your pipeline's job.** A whole run in one container is a native Linux
run: the build's tools get no secret variable and cannot open the store, but they run as the same user in the same
container as the steps that sign, so a secret *file* that the container has (a `_FILE` variable's) is readable to the
build's code ([security.md](security.md#the-image-used-directly)). Building in one container with no secret and signing
in another, as [ci.md](ci.md#in-the-image) does, keeps a build's mistake from the secrets, not code that means harm:
the build's container writes the project as your user, and what it leaves there is on the machine when the secrets come.
For that, sign in another job ([what keeps such a build from the secrets, and what does not](security.md#a-build-that-means-harm)).

## Another architecture

`--arch` replaces the default (this machine's architecture): `xless setup --docker --xcode … --arch amd64` builds only the
amd64 image and pack, and `--arch arm64 --arch amd64` both. An export holds the architectures it was made for: a pack for
another one needs an export of it, made from the `.xip` (`--xcode`). An image or a pack for another architecture than the
machine's is built under emulation, Swift Build's compile included: 2 to 3 times slower under Rosetta, slower still under
QEMU. Use a Docker that runs the other architecture through Rosetta (an Apple-silicon Mac) or a native host when you can:
under QEMU's user-mode emulation gcc and Swift have crashed at random. The `xless` binary for the other architecture comes
from the release tarball (checked against `SHA256SUMS`), or from `XLESS_BIN_ARM64` / `XLESS_BIN_AMD64` when set.

## From older layouts

Older releases built one image per Xcode and architecture (`xless:local-<arch>-xcode<version>`, about 13 GB, with Apple's
SDK in it), kits on each, a tools image (`xless:local-<arch>-setup`), and before that a chain of four images
(`xless-base`, `xless`, `xless-tauri`, `xless-rn`). None of them is used any more, and a run that finds only those says so.
The SDK export they were made from is still in the cache, so no `.xip` is needed:

```sh
xless setup --docker --sdk ~/.cache/xless/sdk/xcode26.2-17C52    # once per Xcode you used
xless clean --old                                                # the old images, when the new ones work
```

(With a single export in the cache, `xless setup --docker` alone takes it.)

- `xless clean --old` removes the images of the older layouts and those of other xless versions: it lists them and asks
  (`--yes` answers). It never removes a pack, a store or an SDK export ([uninstall.md](uninstall.md#xless-clean)).
- An image of your own is built again `FROM` the new image or kit ([above](#an-image-of-your-own)).
- `XLESS_XCODE_RETAG` is gone: two builds of one Xcode version each have a pack. `XLESS_SIGN_IMAGE` is read no more; a
  run that finds it set says that it changes nothing.
- `xless sdk install`, which copied the SDK out of an image or installed an export, installs nothing now: every form of it
  says to run `xless setup --sdk <export>`.
- A native install of an older xless (one Xcode's SDK under the configuration directory) is not used either: on Linux,
  `xless setup` with neither `--xcode` nor `--sdk` prepares the pack from the cache's export when one holds the
  architecture, and `xless clean --old` removes the old
  install ([native-install.md](native-install.md#several-xcodes)).
