# Uninstall xless and free its disk space

This is the same on Linux and macOS (on Windows: [native-install.md](native-install.md#windows)). After `xless setup` and a few builds, xless takes space in these places:

| What | Where | Size |
|---|---|---|
| The program and its support files | `~/.local/bin/xless`, `~/.local/share/xless` (the install's `--prefix` / `XLESS_PREFIX`) | about 100 MB |
| On a Mac, natively: rcodesign only (the builds use your Xcode) | `~/.local/share/xless-native` | under 50 MB |
| The native install: xtool, rcodesign, and the Xcode packs of its store (each the SDK and the Swift toolchain fitted to it; Swift Build only where the Xcode tool shims are, `XLESS_SHIM_DIR`, so not on a bare host) | `~/.local/share/xless-native`, the packs in its `xcodes/` (or `$XLESS_XCODES`) | about 6 to 7 GB per Xcode and architecture |
| The exported SDKs, Tauri work copies and downloads | `~/.cache/xless` (`$XDG_CACHE_HOME/xless` when that is set) | about 3.5 GB per Xcode and architecture, plus the work copies |
| With `--docker`: the image `xless:<version>-<arch>`, the kits on it, and the build cache that made them | Docker's data root (`/var/lib/docker` by default) | about 6.5 GB for the image and 0.3 GB for the `tauri` kit, per architecture, and Docker's build cache |
| With `--docker`: the Xcode packs, one volume each (`xless-xcode-<version>-<build>-<arch>`), or the directory `XLESS_XCODES` names | Docker's data root, or that directory | 6.7 to 7.3 GB (decimal) per Xcode and architecture |
| With `--docker`: Docker volumes of `xless run --docker` (Rust toolchains, React Native work copies and caches) | Docker's data root | a few GB per app |
| The secret store, if you made one (your keys); with a credential helper, only its writers' `lock` file | `~/.local/share/xless/vault` (`$XDG_DATA_HOME/xless/vault`) | a few KB |

Part of the Docker figure is Docker's build cache, which `xless clean` leaves alone ([below](#free-the-build-cache)).

## `xless clean`

`xless clean` removes what xless made, and nothing else. With no option it lists what it finds and removes nothing:

```sh
xless clean                 # list the native install, images, volumes, packs and cache
xless clean --all --dry-run # what --all would remove
xless clean --all           # remove all of them
```

| Option | Removes |
|---|---|
| `--images` | every local tag of xless's images: `xless:<version>-<arch>` and its kits, of every xless version, and those of the older layouts (`xless:local-…`, and `xless-base`, `xless-tauri` and `xless-rn` of xless 0.10 and older); then their older builds that a later `xless setup` left untagged (`docker image prune --filter label=org.xless.image=true`). An [image of your own](images.md#an-image-of-your-own) is yours to remove, and stays when its Dockerfile says `LABEL org.xless.image=own`. xless's versions are `X.Y.Z` (and `0.0.0-dev` from source): a tag whose version has another word in it (`1.0.0-rc.1-arm64`, `2.0.0-mine-arm64`) is taken for one of your own and stays too |
| `--old` | only what an upgrade leaves: the tags of the older layouts, the images and kits of another xless version than this one (never this one's), the untagged older builds, and an older native install (the SDK that an xless of before the packs installed, its `toolchain-meta.json`, its Swift toolchains). It lists them and asks (no is the default; `--yes` answers, and without a terminal nothing is removed unless it is given), and looks at each again right before it goes. Never a pack |
| `--volumes` | the volumes `xless run --docker` creates: `xless-rustup`, `xless-cargo`, `xless-corepack`, `xless-bundle`, `xless-cocoapods-home`, `xless-cocoapods-cache` and every `xless-rn-work-*`. Not the packs |
| `--packs` | the Xcode packs: the volumes `xless-xcode-<version>-<build>-<arch>`, and the packs of a store of your own (`XLESS_XCODES`). Preparing one again takes minutes and needs its SDK export or the Xcode, so it lists them and asks (`--yes` answers); a pack that a running container uses is left. In a store of your own it also removes what interrupted setups left beside the packs (`<name>.partial`, `<name>.old`, `<name>.lock`), but for those of a setup that is running |
| `--cache` | `~/.cache/xless` (or `$XDG_CACHE_HOME/xless`), with the SDK exports that the packs are prepared from: without the `.xip` they are your only copy; needs no Docker. A store of packs inside it (`XLESS_XCODES` there) is left unless `--packs` is given too |
| `--native` | the native install: `~/.local/share/xless-native` (or `$XLESS_NATIVE_HOME`) with the packs of its store, and an older install's SDK and `toolchain-meta.json`. Only a directory that holds nothing but what xless's setup puts there is removed, and it asks first (`--yes` answers); a home (or its `xcodes`) that is a symbolic link is removed as a link, and what it leads to is left; needs no Docker |
| `--all` | `--images`, `--volumes`, `--packs`, `--cache` and `--native` |

It leaves alone the xless install itself, SwiftPM's caches of the packages that your projects depend on (on a Mac
`~/Library/Caches/org.swift.swiftpm`, which Xcode uses too), the [secret store](secrets.md) and Docker's build cache, which other
projects share. A volume or image that a
container still uses is not removed: `docker ps -a` shows the container, `docker rm <container>` removes it. Tauri
work copies are built as root inside the container, so if `--cache` reports files it could not remove, run the
`sudo rm -rf` it prints.

## Free the build cache

Docker's build cache is not xless's alone. To see it and free it:

```sh
docker buildx du             # how much the build cache takes
docker builder prune         # remove the build cache that no image uses (asks first)
docker builder prune --all   # remove all of it: the next build of any project starts from scratch
```

## After an upgrade

A new xless has an image of its own, `xless:<new version>-<arch>`: the first `xless setup --docker` after the upgrade builds
it, and the kits follow when they are next needed. The Xcode packs stay and are used as they are, unless the new xless
prepares a part of them in another way; then a run prepares that part again from the SDK export, or `xless setup --docker`
does. The previous version's image and kits stay on disk. Remove them, and what older layouts left (the per-Xcode images
`xless:local-<arch>-xcode<version>`, the tools image `xless:local-<arch>-setup`, the four images of xless 0.10 and older,
an older native install), with:

```sh
xless clean --old
```

Images built by a release older than the one that added `xless clean` do not carry the `org.xless.image` label, so
`--old` does not see their untagged builds. `docker image prune` removes them, together with every other untagged image on the machine.

## Remove one Xcode

`xless clean --packs` lists every pack and asks before it removes them all. To drop one Xcode, for example 26.2 (17C52),
remove its pack and its SDK export:

```sh
docker volume rm xless-xcode-26.2-17C52-arm64            # with --docker; docker volume ls --filter name=xless-xcode- lists them
rm -rf ~/.local/share/xless-native/xcodes/26.2-17C52-arm64   # natively, or in your XLESS_XCODES
rm -rf ~/.cache/xless/sdk/xcode26.2-17C52
```

Docker refuses to remove a volume that a container uses. A project that pins that Xcode then stops at its build and says
how to prepare the pack again.

## Uninstall

To return the machine to its state before xless (with the default prefix, the second `rm` removes the secret store
too: read the paragraph below first):

```sh
xless clean --all
rm -f ~/.local/bin/xless
rm -rf ~/.local/share/xless       # with the default prefix this holds the secret store too (vault/): see below
```

Use your prefix in place of `~/.local` if you installed with `--prefix` or `XLESS_PREFIX`. With the default prefix,
`~/.local/share/xless/vault` is the [secret store](secrets.md): the only copy of the keys xless created for you.
Before removing it, revoke at Apple the keys and certificates you no longer use, or export the ones you keep
([security.md](security.md#wiping-everything)); to keep it, remove everything in `~/.local/share/xless` but `vault`.
Reinstalling or upgrading with the install line keeps it. Run `xless lock` before you remove `xless`, so nothing is held
any more (after an upgrade too: a new xless does not use the agent of the old one). The agent's directory of sockets
(`$XDG_RUNTIME_DIR/xless-agent`, `$TMPDIR/xless-agent` on macOS) is empty then, and the system removes it. On macOS xless
puts nothing into the Keychain, `~/Library` or `/Applications`. Then, if you want:

- free Docker's build cache ([above](#free-the-build-cache));
- remove `~/.cache/xless` by hand if `xless clean` was already gone (and `docker image rm` the images and
  `docker volume rm` the volumes listed in the table above);
- remove `~/.config/xless` (it may hold your `testflight.env`, and `config.yml` with the default team and where the secrets live);
- remove the line that adds `~/.local/bin` to `PATH` from your shell's startup file (`~/.zshrc` on macOS), if you added one;
- on macOS, take your terminal out of System Settings > Privacy & Security > Input Monitoring, if you put it there for a
  [security key](apple-account.md#signing-in-with-a-security-key);
- delete the Xcode `.xip` you downloaded.

The images of older xless releases (`xless:local-<arch>-xcode<version>`) contain Apple's SDK, so they belong on no registry
([maintainers.md](maintainers.md#images-on-other-machines)). If you ever pushed one to a private registry of yours, delete it
there too. The packs and the SDK exports hold it as well and never leave your machines; the image of this xless holds
nothing of Apple's.
