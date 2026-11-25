# Uninstall xless and free its disk space

This is the same on Linux and macOS. After `xless setup` and a few builds, xless takes space in these places:

| What | Where | Size |
|---|---|---|
| The program and its support files | `~/.local/bin/xless`, `~/.local/share/xless` (the install's `--prefix` / `XLESS_PREFIX`) | about 100 MB |
| On a Mac, natively: rcodesign only (the builds use your Xcode) | `~/.local/share/xless-native` | under 50 MB |
| The native install: Swift toolchain, xtool, rcodesign; the installed SDK and its metadata | `~/.local/share/xless-native`; `~/.swiftpm/swift-sdks/darwin.artifactbundle` and `~/.config/xless/toolchain-meta.json` | about 8 GB |
| The exported SDKs, Tauri work copies and downloads | `~/.cache/xless` (`$XDG_CACHE_HOME/xless` when that is set) | about 3.5 GB per Xcode and architecture, plus the work copies |
| With `--docker`: the image `xless:local-<arch>-xcode<version>`, the kits on it, and the build cache that made them | Docker's data root (`/var/lib/docker` by default) | about 14 GB for the images and about 25 GB with the build cache, per Xcode and architecture |
| With `--docker`: Docker volumes of `xless run --docker` (Rust toolchains, React Native work copies and caches) | Docker's data root | a few GB per app |
| The secret store, if you made one (your keys); with a credential helper, only its writers' `lock` file | `~/.local/share/xless/vault` (`$XDG_DATA_HOME/xless/vault`) | a few KB |

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
| `--images` | every local tag of `xless` (and of `xless-base`, `xless-tauri` and `xless-rn`, the images of xless 0.10 and older), then their older builds (see `--old`). An [image of your own](images.md#an-image-of-your-own) is yours to remove, and stays when its Dockerfile says `LABEL org.xless.image=own` |
| `--old` | only what an upgrade leaves: the tags of xless 0.10 and older, which it lists and asks about (no is the default; `--yes` answers, and without a terminal nothing is removed unless it is given), each looked at again right before it goes; and the older builds that a later `xless setup` replaced, which are left untagged (`docker image prune --filter label=org.xless.image=true`) |
| `--volumes` | the volumes `xless run --docker` creates: `xless-rustup`, `xless-cargo`, `xless-corepack`, `xless-bundle`, `xless-cocoapods-home`, `xless-cocoapods-cache` and every `xless-rn-work-*` |
| `--cache` | `~/.cache/xless` (or `$XDG_CACHE_HOME/xless`); needs no Docker |
| `--native` | the native install: `~/.local/share/xless-native` (or `$XLESS_NATIVE_HOME`), the installed SDK and its `toolchain-meta.json`; needs no Docker |
| `--all` | `--images`, `--volumes`, `--cache` and `--native` |

It leaves alone the xless install itself, the [secret store](secrets.md) and Docker's build cache, which other
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

Each `xless setup --docker` after an upgrade builds the image again around the new `xless` and moves its tag to the new
build; the kits follow when they are next needed. The old builds stay on disk, untagged (`<none>` in `docker images`), and
the four images of xless 0.10 and older (`xless-base`, `xless`, `xless-tauri`, `xless-rn`) stay with their tags. Remove
them with:

```sh
xless clean --old
```

Images built by a release older than the one that added `xless clean` do not carry the `org.xless.image` label, so
`--old` does not see their untagged builds. `docker image prune` removes them, together with every other untagged image on the machine.

## Remove one Xcode's images

`xless clean --images` removes the images of every Xcode. To drop one Xcode, for example 26.2, remove its image, the kits
on it and its exported SDK:

```sh
docker image rm $(docker image ls --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^xless:local-(arm64|amd64)-xcode26\.2(-|$)')
rm -rf ~/.cache/xless/sdk/xcode26.2-17C52
```

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

The images contain Apple's SDK, so they belong on no registry ([maintainers.md](maintainers.md#images-on-other-machines)). If
you ever pushed one to a private registry of yours, delete it there too.
