# Uninstall xless and free its disk space

After `xless setup` and a few builds, xless takes space in these places:

| What | Where | Size |
|---|---|---|
| The program and its support files | `~/.local/bin/xless`, `~/.local/share/xless` (the install's `--prefix` / `XLESS_PREFIX`) | about 100 MB |
| The native install: Swift toolchain, xtool, rcodesign; the installed SDK and its metadata | `~/.local/share/xless-native`; `~/.swiftpm/swift-sdks/darwin.artifactbundle` and `~/.config/xless/toolchain-meta.json` | about 8 GB |
| The exported SDKs, Tauri work copies and downloads | `~/.cache/xless` (`$XDG_CACHE_HOME/xless` when that is set) | about 3.5 GB per Xcode and architecture, plus the work copies |
| With `--docker`: the images `xless-base`, `xless`, `xless-tauri`, `xless-rn`, and the build cache that made them | Docker's data root (`/var/lib/docker` by default) | about 21 to 31 GB per Xcode and architecture ([measured](acceptance-m5.md#runs-in-the-vm)) |
| With `--docker`: Docker volumes of `xless run --docker` (Rust toolchains, React Native work copies and caches) | Docker's data root | a few GB per app |

Part of the Docker figure is Docker's build cache, which `xless clean` leaves alone ([below](#free-the-build-cache)).

## `xless clean`

`xless clean` removes what xless made, and nothing else. With no option it lists what it finds and removes nothing:

```sh
xless clean                 # list the native install, images, volumes and cache
xless clean --all --dry-run # what --all would remove
xless clean --all           # remove all of them
```

| Option | Removes |
|---|---|
| `--images` | every local tag of `xless-base`, `xless`, `xless-tauri` and `xless-rn`, then their older builds (see `--old`) |
| `--old` | only the older builds of the images that a later `xless setup` replaced, which are left untagged (`docker image prune --filter label=org.xless.image`) |
| `--volumes` | the volumes `xless run --docker` creates: `xless-rustup`, `xless-cargo`, `xless-corepack`, `xless-bundle`, `xless-cocoapods-home`, `xless-cocoapods-cache` and every `xless-rn-work-*` |
| `--cache` | `~/.cache/xless` (or `$XDG_CACHE_HOME/xless`); needs no Docker |
| `--native` | the native install: `~/.local/share/xless-native` (or `$XLESS_NATIVE_HOME`), the installed SDK and its `toolchain-meta.json`; needs no Docker |
| `--all` | `--images`, `--volumes`, `--cache` and `--native` |

It leaves alone the xless install itself and Docker's build cache, which other projects share. A volume or image that a
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

Each `xless setup --docker` after an upgrade builds the images again around the new `xless` and moves their tags to the new
builds. The old builds stay on disk, untagged (`<none>` in `docker images`). Remove them with:

```sh
xless clean --old
```

Images built by a release older than the one that added `xless clean` do not carry the `org.xless.image` label, so
`--old` does not see them. `docker image prune` removes them, together with every other untagged image on the machine.

## Remove one Xcode's images

`xless clean --images` removes the images of every Xcode. To drop one Xcode, for example 26.2, remove its tags and its
exported SDK:

```sh
docker image rm $(docker image ls --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^xless(-base|-tauri|-rn)?:local-(arm64|amd64)-xcode26\.2(-|$)')
rm -rf ~/.cache/xless/sdk/xcode26.2-17C52
```

Docker removes an image when its last tag goes. The plain `:local-<arch>` tags belong to the default Xcode (27.0); for
27.0 also remove `xless-base:local-<arch>`, `xless:local-<arch>`, `xless-tauri:local-<arch>` and
`xless-rn:local-<arch>`.

## Uninstall

To return the machine to its state before xless:

```sh
xless clean --all
rm -f ~/.local/bin/xless
rm -rf ~/.local/share/xless
```

Use your prefix in place of `~/.local` if you installed with `--prefix` or `XLESS_PREFIX`. Then, if you want:

- free Docker's build cache ([above](#free-the-build-cache));
- remove `~/.cache/xless` by hand if `xless clean` was already gone (and `docker image rm` the images and
  `docker volume rm` the volumes listed in the table above);
- remove `~/.config/xless` (it may hold your `testflight.env`);
- remove the line that adds `~/.local/bin` to `PATH` from your shell's startup file, if you added one;
- delete the Xcode `.xip` you downloaded.

The images contain Apple's SDK. If you ever pushed them to a private registry
([maintainers.md](maintainers.md#private-registries)), delete them there too.
