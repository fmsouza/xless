#!/usr/bin/env bash
# Builds, signs and uploads an iOS project and delivers it to TestFlight (`xless ship --platform ios`).
# Usage: scripts/testflight.sh <project-dir> [extra xless ship args...]     (or: make testflight PROJECT=<dir>)
#        scripts/testflight.sh --config <overlay.yml> [extra xless ship args...]   (or: make testflight CONFIG=<overlay.yml> [ARGS="…"])
#
# --config: an app described by an overlay file instead of an xless.yml project: a Tauri v2 app (`type: tauri`,
#   docs/tauri.md), a plain Cargo app (`type: cargo`, docs/cargo.md) or a React Native / Expo app (`type: react-native`,
#   docs/react-native.md). The script reads the
#   overlay's top-level `type:` line to choose the images and caches below.
#   The app source is the overlay's `source:` (`~` expanded, relative to the overlay file's directory), or $XLESS_SOURCE
#   when set, which wins. `source:` and `type:` must be plain top-level `key: value` lines (optionally quoted, with a
#   trailing comment); anything fancier (flow style, anchors, multi-line) is not read by this script: set XLESS_SOURCE
#   instead. The overlay path may start with `~/`. The source is never written to.
#   The app's build runs third-party code (npm scripts, build.rs, proc-macros, CocoaPods, Xcode build phases), so it
#   never runs next to a secret. Three steps, each its own container (or process, natively):
#     1. xless next-build            with the App Store Connect key only: the next dated build number (read-only).
#                                    (`xless tauri next-build` for a Tauri overlay.) Skipped when XLESS_BUILD_NUMBER or
#                                    --build-number is given, or when resuming after build.
#     2. xless ship --to finalize    WITHOUT any secret mount or variable: prepare, build, assets, finalize, with
#                                    XLESS_BUILD_NUMBER from step 1.
#     3. xless ship --from sign      with the secrets: sign, package, upload (no build code runs here).
#   --from/--to among the extra args select which steps run (`--to prepare` alone starts at prepare); the secrets each
#   step needs are required only when that step runs (`--build-number <n> --to finalize` needs none, and neither does
#   step 1 for a fixed `build:`). In docker (bind mounts as --mount, so any path works):
#     the source           mounted read-only at /source           and passed as --source /source
#       (a source inside a git checkout, not at its top, mounts the checkout's top and passes --source /source/<path>:
#        xless reads the source's tracked files with git)
#     the overlay's folder mounted read-only at /config           and passed as --config /config/<file>
#       (the whole folder, so a relative `privacyManifest:` or `assets:` in the overlay resolves; `source:` would
#        resolve inside /config too, which is why --source overrides it). Keep the overlay in its own directory: the
#        script refuses an overlay directory, or a mounted source directory, that holds the env file or a secret file
#        (compared by inode), and either one that is /, your home directory or a directory above it.
#   Tauri and cargo (image xless-tauri:local-<arch>, or XLESS_IMAGE, for all three steps):
#     ~/.cache/xless/work (steps 2 and 3) and ~/.cache/xless/downloads (step 2) at /cache/work and /cache/downloads
#     volumes xless-rustup and xless-cargo at /cache/rustup and /cache/cargo (step 2; Rust toolchains survive between runs)
#   Cargo only (step 1 is `xless next-build`, as for React Native):
#     ~/.cache/xless/inputs (step 2) at /cache/inputs: the checkouts of the overlay's git inputs.
#     The overlay's path inputs (`xless cargo inputs`, asked of $XLESS_SELF, else xless on PATH) are mounted read-only at
#       /inputs/<name> on step 2 only, with XLESS_INPUTS_MOUNTED=1. Each gets the checks of the source and the overlay's
#       folder: not /, your home directory or a directory above it, and holding no secret file. Natively nothing is
#       mounted (xless reads the paths itself).
#   React Native (step 2: xless-rn:local-<arch>, or XLESS_IMAGE; steps 1 and 3: xless-base:local-<arch>, or
#   XLESS_SIGN_IMAGE, which holds xless and rcodesign and no build tool; the script stops when the two images hold
#   different xless binaries):
#     volume xless-rn-work-<overlay name>-<hash of the overlay path> (or XLESS_RN_WORK_VOLUME) at /cache/work (steps 2
#       and 3): the work copy, its derived data and the pnpm store. A docker volume, not a host folder: the build needs a case-sensitive file system (a macOS
#       folder shared into the VM is case-insensitive, and the build's lowercase framework links would collide).
#     volumes xless-corepack, xless-bundle, xless-cocoapods-home, xless-cocoapods-cache (step 2): corepack's package
#       managers, the app's gems, CocoaPods' specs repo and pod downloads. Docker creates every volume on first use.
#     XLESS_RN_CLEAN=1 is passed to step 2 (prepare regenerates ios/ and the pods).
#   XLESS_BUILD_NUMBER is not defaulted: the overlay's `build:` decides (`dated` asks App Store Connect for the next
#   number in step 1). When set it is passed to steps 2 and 3.
#
# Where it runs
#   Docker (the xless images), unless a native SDK is installed on this host: $XLESS_TOOLCHAIN_META, else ~/.config/xless/toolchain-meta.json.
#   XLESS_USE_DOCKER=1 forces docker; XLESS_USE_DOCKER=0 forces native; unset: docker unless a native SDK (toolchain-meta.json) is installed.
#
# Configuration comes from the environment, and from a local file that is sourced first when it exists:
#   $XLESS_TESTFLIGHT_ENV, default ~/.config/xless/testflight.env   (keep it out of git; it holds paths and IDs only)
# Variables (see docs/signing-and-testflight.md):
#   ASC_KEY_ID               App Store Connect API key ID                      (required)
#   ASC_ISSUER_ID_FILE       file holding the issuer ID   (or ASC_ISSUER_ID)   (required)
#   ASC_KEY_P8_FILE          the API key .p8 file                              (required)
#   XLESS_DIST_KEY_FILE      the Apple Distribution private key (PEM)          (required on ios; on macos when --to upload runs the App-Store lane)
#   XLESS_DEVID_KEY_FILE     the Developer ID Application private key (PEM)    (required with --platform macos)
#     ("required" means: when a step that uses it runs. A project directory needs none of them for a run that stops
#      before sign (--to prepare|build|assets|finalize); with --config, see the three steps above)
#   XLESS_IMAGE              docker image; default xless:local-<arch> (with --config: see above)
#   XLESS_SIGN_IMAGE         React Native only: the image of steps 1 and 3; default xless-base:local-<arch>
#   DOCKER_CONTEXT           docker context; default colima-xless if it exists, else the current one
#   XLESS_BUILD_NUMBER       build number; default minutes since 1970 (monotonic across machines); not defaulted with --config
#   XLESS_TESTFLIGHT_DRY_RUN=1 (or --dry-run)   print what would run (no secret values are ever printed) and exit
# With docker, secret files and the project must live under a directory the docker VM can see (on macOS typically somewhere under
# $HOME; Colima shares $HOME, Docker Desktop shares the directories listed in its file-sharing settings).
#
# --platform macos (default ios; only with a Tauri or cargo --config): a notarized, stapled DMG of the macOS app (`make dmg`).
#   Step 1 (next-build) is skipped: macOS builds have no App Store Connect build number, `dated` uses the clock when the run
#   starts (XLESS_BUILD_NUMBER, if set, still wins and is passed on). Step 2 is unchanged (no secrets). Step 3 runs
#   `xless ship --platform macos --from sign --to package` with XLESS_DEVID_KEY_FILE and the App Store Connect key (the
#   read-only certificate lookup and notarization); it prints the DMG path last. `--from package` reuses the signed app.
# xcode: "<version>" (a top-level line of the overlay, or of xless.yml; Ruling R8): with docker, every step runs in the
#   images made from that Xcode by `xless setup --xcode <Xcode.app | .xip>`: <image>:local-<arch>-xcode<version>, e.g.
#   xless-rn:local-arm64-xcode26.2 and xless-base:local-arm64-xcode26.2. For versions.env's XCODE_VERSION the plain
#   local-<arch> images serve when the suffixed ones do not exist. A missing image stops the script (exit 2) with the
#   `xless setup` command that builds it. XLESS_IMAGE / XLESS_SIGN_IMAGE still win. Prepare (exit 19; the build stage
#   for xless.yml) checks the SDK inside the image against the pin either way (natively too).
# --destination simulator (only with a React Native --config): an ad-hoc signed app for the iOS Simulator (`make simulator`).
#   Step 2 only, with no secret and no App Store Connect query (a dated build number comes from the clock):
#   `xless ship --destination simulator --to build`, into the work volume's .xless/build/ios-simulator/app, with its own
#   derived data (the device build's outputs are left alone). It prints the app as `volume:<work volume>:<path>`, the
#   argument scripts/sim-launch.sh takes to install and launch it on this Mac's simulator. --from/--to may only name
#   prepare and build; nothing is signed with a distribution identity or uploaded.
# The exit code is xless's (2 for a usage or configuration error in this script).
set -euo pipefail

die() { echo "testflight: $*" >&2; exit 2; }

usage="usage: $0 <project-dir> [extra xless ship args...]   or   $0 --config <overlay.yml> [--platform ios|macos] [--destination device|simulator] [--dry-run] [extra args...]"
[[ $# -ge 1 ]] || die "$usage"
PLATFORM=ios
DESTINATION=device
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) [[ $# -ge 2 ]] || die "--platform needs ios or macos"; PLATFORM="$2"; shift 2 ;;
    --platform=*) PLATFORM="${1#--platform=}"; shift ;;
    --destination) [[ $# -ge 2 ]] || die "--destination needs device or simulator"; DESTINATION="$2"; shift 2 ;;
    --destination=*) DESTINATION="${1#--destination=}"; shift ;;
    --dry-run) XLESS_TESTFLIGHT_DRY_RUN=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ "$PLATFORM" == ios || "$PLATFORM" == macos ]] || die "--platform must be ios or macos"
[[ "$DESTINATION" == device || "$DESTINATION" == simulator ]] || die "--destination must be device or simulator"
SIM=0; [[ "$DESTINATION" == device ]] || SIM=1
set -- ${args[@]+"${args[@]}"}
[[ $# -ge 1 ]] || die "$usage"
OVERLAY=""
PROJECT=""
if [[ "$1" == --config ]]; then
  [[ $# -ge 2 ]] || die "$usage"
  OVERLAY="$2"; shift 2
  [[ $# -eq 0 || "$1" == -* ]] || die "--config replaces <project-dir>; give one or the other"
  case "$OVERLAY" in "~/"*) OVERLAY="$HOME/${OVERLAY#\~/}" ;; esac   # e.g. `make testflight CONFIG=~/…` under zsh
  [[ -f "$OVERLAY" ]] || die "overlay $OVERLAY not found"
  OVERLAY="$(cd "$(dirname "$OVERLAY")" && pwd)/$(basename "$OVERLAY")"
else
  PROJECT="$1"; shift
  for a in "$@"; do [[ "$a" != --config && "$a" != --config=* ]] || die "--config replaces <project-dir>; give one or the other"; done
  [[ $SIM == 0 ]] || die "--destination simulator needs --config <overlay.yml> (a React Native app)"
  [[ "$PLATFORM" == ios ]] || die "--platform macos needs --config <overlay.yml> (a Tauri or cargo app)"
  [[ -f "$PROJECT/xless.yml" ]] || die "$PROJECT/xless.yml not found (is '$PROJECT' an xless project?)"
  PROJECT="$(cd "$PROJECT" && pwd)"
fi

ENV_FILE="${XLESS_TESTFLIGHT_ENV:-$HOME/.config/xless/testflight.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a   # export what the file defines, so `docker run -e NAME` can see it
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

yaml_top() {   # FILE KEY: FILE's top-level `KEY: value` line, without a trailing comment and surrounding quotes
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed -E "s/[[:space:]]+#.*$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}
top_value() { yaml_top "$OVERLAY" "$1"; }   # KEY: the overlay's
# Ruling R8: the Xcode whose SDK builds the app (its images are selected below; prepare and the build stage check the SDK).
pin_file="$OVERLAY"; [[ -n "$pin_file" ]] || pin_file="$PROJECT/xless.yml"
XCODE_PIN="$(yaml_top "$pin_file" xcode)"
[[ -z "$XCODE_PIN" || "$XCODE_PIN" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "xcode: '$XCODE_PIN' in $pin_file is not an Xcode version (e.g. xcode: \"26.2\")"
# The pin as image tags spell the Xcode version (scripts/build-images.sh): major.minor, plus the patch when it is not 0
# ("26" and "26.0.0" → 26.0, "26.2.0" → 26.2, "26.0.1" stays). xless compares versions the same way (27 = 27.0 = 27.0.0).
canonical_xcode() { local IFS=.; local p=($1); local v="$((10#${p[0]})).$((10#${p[1]:-0}))"
  [[ -z "${p[2]:-}" ]] || [[ $((10#${p[2]})) -eq 0 ]] || v+=".$((10#${p[2]}))"; echo "$v"; }
XCODE_TAG=""; [[ -z "$XCODE_PIN" ]] || XCODE_TAG="$(canonical_xcode "$XCODE_PIN")"
SOURCE=""
RN=0; CARGO=0
if [[ -n "$OVERLAY" ]]; then
  overlay_type="$(top_value type)"
  [[ "$overlay_type" != react-native ]] || RN=1
  [[ "$overlay_type" != cargo ]] || CARGO=1
  [[ $RN == 0 || "$PLATFORM" == ios ]] || die "React Native overlays build iOS apps only (drop --platform macos)"
  [[ $SIM == 0 || $RN == 1 ]] || die "--destination simulator builds React Native overlays only"
  SOURCE="${XLESS_SOURCE:-}"
  if [[ -z "$SOURCE" ]]; then
    SOURCE="$(top_value source)"
    [[ -n "$SOURCE" ]] || die "$OVERLAY has no source: (set it, or set XLESS_SOURCE)"
  fi
  case "$SOURCE" in "~") SOURCE="$HOME" ;; "~/"*) SOURCE="$HOME/${SOURCE#\~/}" ;; esac
  [[ "$SOURCE" == /* ]] || SOURCE="$(dirname "$OVERLAY")/$SOURCE"
  [[ -d "$SOURCE" ]] || die "the app source $SOURCE does not exist"
  SOURCE="$(cd "$SOURCE" && pwd)"
fi
# What docker mounts at /source: the source, or the top of the git checkout it is inside of (xless lists the tracked
# files with git, which needs the checkout's .git); --source then names the source below /source.
SOURCE_MOUNT="$SOURCE"; SOURCE_SUB=""
if [[ -n "$SOURCE" ]] && top="$(git -C "$SOURCE" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]]; then
  sp="$(cd "$SOURCE" && pwd -P)"; tp="$(cd "$top" && pwd -P)"
  if [[ "$sp" == "$tp"/* ]]; then SOURCE_MOUNT="$tp"; SOURCE_SUB="${sp#"$tp"}"; fi
fi

# --config: the three steps of the header. --from/--to are placed by this script; other extra args go to both ship steps.
from=build; to=upload; extra=(); [[ "$PLATFORM" != macos ]] || to=package; [[ $SIM == 0 ]] || to=build; given_build=0; given_from=0
stages=(prepare build assets finalize sign package upload)
index() { local i; for i in "${!stages[@]}"; do [[ "${stages[$i]}" != "$1" ]] || { echo "$i"; return 0; }; done
  die "unknown stage '$1' (use one of: ${stages[*]})"; }
step1=0; step3=1
if [[ -n "$OVERLAY" ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|--to) [[ $# -ge 2 ]] || die "$1 needs a stage"; if [[ "$1" == --from ]]; then from="$2"; given_from=1; else to="$2"; fi; shift 2 ;;
      --from=*) from="${1#--from=}"; given_from=1; shift ;;
      --to=*) to="${1#--to=}"; shift ;;
      --build-number|--build-number=*) given_build=1; extra+=("$1"); shift ;;
      *) extra+=("$1"); shift ;;
    esac
  done
  fi_="$(index "$from")"; ti="$(index "$to")"
  # `--to prepare` alone: the run starts at prepare (the default --from is build, which includes prepare)
  if [[ $given_from == 0 && $ti -lt $fi_ ]]; then from=prepare; fi_=0; fi
  [[ $fi_ -le $ti ]] || die "--to $to comes before --from $from"
  [[ $SIM == 0 || $ti -le 1 ]] || die "--destination simulator builds stop at build (--to $to)"
  # Step 1 (the build number) only for a run that starts with `build: dated` (the default): later stages read the one
  # recorded in the work copy, and a fixed build needs no App Store Connect query.
  build_kind="$(top_value build)"
  [[ "$PLATFORM" != ios || $SIM == 1 || -n "${XLESS_BUILD_NUMBER:-}" || $given_build == 1 || $fi_ -gt 1 || ( -n "$build_kind" && "$build_kind" != dated ) ]] || step1=1
  [[ $ti -ge 4 ]] || step3=0
else
  # A project directory is one container: it gets the secrets unless the run stops before sign (`--to finalize`).
  pto=upload; prev=""
  for a in "$@"; do
    [[ "$prev" != --to ]] || pto="$a"
    case "$a" in --to=*) pto="${a#--to=}" ;; --build-number|--build-number=*) given_build=1 ;; esac
    prev="$a"
  done
  pti="$(index "$pto")"
  [[ $pti -ge 4 ]] || step3=0
fi

# The secrets of the steps that run (for a project directory: all of them, or none before sign).
need_asc=0; need_key=0
[[ $step1 == 0 && $step3 == 0 ]] || need_asc=1
[[ $step3 == 0 ]] || need_key=1
if [[ $need_asc == 1 ]]; then
  [[ -n "${ASC_KEY_ID:-}" ]] || die "set ASC_KEY_ID in the environment or $ENV_FILE"
  [[ -n "${ASC_ISSUER_ID_FILE:-}${ASC_ISSUER_ID:-}" ]] || die "set ASC_ISSUER_ID_FILE (or ASC_ISSUER_ID) in the environment or $ENV_FILE"
fi
# Secret file paths are made absolute (docker -v needs absolute host paths) and must be readable.
abs_file() {   # NAME: resolve $NAME to an absolute path in place
  local v="$1" p="${!1}"
  [[ -r "$p" ]] || die "$v points to a file that does not exist or is unreadable"
  [[ "$p" == /* ]] || p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  printf -v "$v" '%s' "$p"
}
secret_files=()
[[ $need_asc == 0 ]] || secret_files+=(ASC_KEY_P8_FILE)
if [[ $need_key == 1 ]]; then
  if [[ "$PLATFORM" == macos ]]; then secret_files+=(XLESS_DEVID_KEY_FILE); else secret_files+=(XLESS_DIST_KEY_FILE); fi
fi
# The mac App-Store lane (--to upload): the flat pkg is signed with the Apple Distribution key
# (the Developer ID one stays for the DMG). Only an upload-reaching run needs it in reach.
if [[ $need_key == 1 && "$PLATFORM" == macos && $(index "$to") -ge 6 ]]; then
  secret_files+=(XLESS_DIST_KEY_FILE)
fi
for v in ${secret_files[@]+"${secret_files[@]}"}; do
  [[ -n "${!v:-}" ]] || die "set $v in the environment or $ENV_FILE"
  abs_file "$v"
done
if [[ $need_asc == 1 && -n "${ASC_ISSUER_ID_FILE:-}" ]]; then abs_file ASC_ISSUER_ID_FILE; fi

use_docker=0
case "${XLESS_USE_DOCKER:-auto}" in
  1) use_docker=1 ;;
  0) use_docker=0 ;;
  # auto: the images, unless an SDK is installed natively (xless sdk install writes toolchain-meta.json)
  auto) if [[ ! -e "${XLESS_TOOLCHAIN_META:-${XDG_CONFIG_HOME:-$HOME/.config}/xless/toolchain-meta.json}" ]] || ! command -v xless >/dev/null 2>&1; then use_docker=1; fi ;;
  *) die "XLESS_USE_DOCKER must be 0, 1 or unset" ;;
esac

# With docker, the overlay's directory and the source are mounted into the container that runs the app's build code:
# no secret may live below them. (Natively nothing is mounted: the build runs on the host, without the secret variables.)
physical() {   # PATH: absolute path with every symlink (the file's own and its directories') resolved
  local p="$1" t n=0
  while [[ -L "$p" && $n -lt 40 ]]; do t="$(readlink "$p")"; [[ "$t" == /* ]] || t="$(dirname "$p")/$t"; p="$t"; n=$((n + 1)); done
  printf '%s/%s' "$(cd -P "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
}
inside() {   # FILE DIR: FILE (symlinks resolved) is somewhere below DIR, compared by inode (-ef), so neither a symlink
  # nor another spelling of the path (case on macOS file systems) hides it
  local d; d="$(dirname "$(physical "$1")")"
  while :; do
    [[ ! "$d" -ef "$2" ]] || return 0
    [[ "$d" != / ]] || return 1
    d="$(dirname "$d")"
  done
}
broad_dir() { [[ "$1" -ef / || "$1" -ef "$HOME" ]] || inside "$HOME/." "$1"; }   # DIR: is / , the home directory or a directory above it
secret_vars=(ENV_FILE ASC_KEY_P8_FILE XLESS_DIST_KEY_FILE XLESS_DEVID_KEY_FILE ASC_ISSUER_ID_FILE)
input_names=(); input_paths=()   # cargo path inputs mounted at /inputs/<name> (step 2, docker)
if [[ -n "$OVERLAY" && $use_docker == 1 ]]; then
  overlay_dir="$(cd -P "$(dirname "$OVERLAY")" && pwd -P)"
  source_dir="$(cd -P "$SOURCE_MOUNT" && pwd -P)"
  # Both are mounted whole: never the file system root, the home directory or a directory above it.
  for d in "$overlay_dir" "$source_dir"; do
    if broad_dir "$d"; then
      die "$d would be mounted into the build container, and it is / or holds your home directory; keep the overlay in its own directory and point source: at the app's checkout"
    fi
  done
  for v in "${secret_vars[@]}"; do
    f="${!v:-}"
    [[ -n "$f" && -e "$f" ]] || continue
    ! inside "$f" "$overlay_dir" || die "$v (${!v}) is inside the overlay's directory $overlay_dir, which is mounted into the build container; keep the overlay in its own directory, away from secrets"
    ! inside "$f" "$source_dir" || die "$v (${!v}) is inside the app source $source_dir, which is mounted into the build container; keep secrets out of the source"
  done
  # A cargo overlay's path inputs are mounted into step 2, the container that runs the app's build code: the same rules.
  # (Only when step 2 runs; the host xless lists them.)
  if [[ $CARGO == 1 && $fi_ -le 3 ]]; then
    inputs_out="$("${XLESS_SELF:-xless}" cargo inputs --config "$OVERLAY" --source "$SOURCE")" \
      || die "cannot list the path inputs of $OVERLAY (\"${XLESS_SELF:-xless}\" cargo inputs failed)"
    while IFS=$'\t' read -r in_name in_path; do
      [[ -n "$in_name" ]] || continue
      [[ "$in_name" =~ ^[A-Za-z0-9._-]+$ && "$in_name" != . && "$in_name" != .. ]] || die "the path input '$in_name' has a name that cannot be a mount point"
      [[ "$in_path" == /* && -e "$in_path" ]] || die "the path input '$in_name' ($in_path) does not exist"
      if broad_dir "$in_path"; then
        die "the path input '$in_name' ($in_path) would be mounted into the build container, and it is / or holds your home directory; point it at the folder the build needs"
      fi
      for v in "${secret_vars[@]}"; do
        f="${!v:-}"
        [[ -n "$f" && -e "$f" ]] || continue
        if [[ "$f" -ef "$in_path" ]] || inside "$f" "$in_path"; then
          die "$v (${!v}) is inside the path input '$in_name' ($in_path), which is mounted into the build container; keep secrets out of the path inputs"
        fi
      done
      input_names+=("$in_name"); input_paths+=("$in_path")
    done <<<"$inputs_out"
  fi
fi

# With --config the overlay's `build:` decides (dated by default); an explicit XLESS_BUILD_NUMBER still wins.
if [[ -z "$OVERLAY" ]]; then export XLESS_BUILD_NUMBER="${XLESS_BUILD_NUMBER:-$(( $(date +%s) / 60 ))}"; fi

shq() {   # WORD: WORD quoted for a shell when it needs it (single quotes), as the dry run prints commands
  if [[ "$1" =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then printf '%s' "$1"; else printf "'%s'" "${1//\'/\'\\\'\'}"; fi
}
run() {
  if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then for w in "$@"; do shq "$w"; printf ' '; done; echo; return 0; fi
  "$@"
}

finish() {   # CODE: report and exit with xless's exit code
  if [[ $1 -eq 0 ]]; then echo "==> TestFlight delivery finished" >&2
  else echo "==> xless exited with code $1" >&2; fi
  exit "$1"
}

bind() {   # SRC DST [ro]: a `docker run --mount` bind spec; a path with ',' or '"' is CSV-quoted, so any path works
  local src="src=$1"
  case "$1" in *,*|*\"*) src="\"src=${1//\"/\"\"}\"" ;; esac
  printf 'type=bind,%s,dst=%s%s' "$src" "$2" "${3:+,readonly}"
}

asc_secrets=(); dist_secret=(); appstore_secret=()
if [[ $use_docker == 1 ]]; then
  command -v docker >/dev/null 2>&1 || die "docker is not installed (and no native xless is on PATH)"
  ctx="${DOCKER_CONTEXT:-}"
  if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  docker_cli=(docker)
  [[ -z "$ctx" ]] || docker_cli+=(--context "$ctx")
  docker_run=("${docker_cli[@]}" run --rm --pull=never)   # never pull: a missing local image is need_images's message, not a Docker Hub "pull access denied"
  # Secrets by path or by name: values never appear on a command line.
  if [[ $need_asc == 1 ]]; then
    asc_secrets=(--mount "$(bind "$ASC_KEY_P8_FILE" /secrets/asc.p8 ro)" -e ASC_KEY_ID -e ASC_KEY_P8_FILE=/secrets/asc.p8)
    if [[ -n "${ASC_ISSUER_ID_FILE:-}" ]]; then
      asc_secrets+=(--mount "$(bind "$ASC_ISSUER_ID_FILE" /secrets/asc-issuer-id ro)" -e ASC_ISSUER_ID_FILE=/secrets/asc-issuer-id)
    else
      asc_secrets+=(-e ASC_ISSUER_ID)   # by name: the value never appears in the process list
    fi
  fi
  if [[ $need_key == 1 && "$PLATFORM" == macos ]]; then
    dist_secret=(--mount "$(bind "$XLESS_DEVID_KEY_FILE" /secrets/devid-key.pem ro)" -e XLESS_DEVID_KEY_FILE=/secrets/devid-key.pem)
    # The App-Store lane's key, in the same shape: its own mount, only the second ship takes it.
    appstore_secret=(--mount "$(bind "$XLESS_DIST_KEY_FILE" /secrets/dist-key.pem ro)" -e XLESS_DIST_KEY_FILE=/secrets/dist-key.pem)
  elif [[ $need_key == 1 ]]; then
    dist_secret=(--mount "$(bind "$XLESS_DIST_KEY_FILE" /secrets/dist-key.pem ro)" -e XLESS_DIST_KEY_FILE=/secrets/dist-key.pem)
  fi
fi

# xcode: pin (docker only; XLESS_IMAGE / XLESS_SIGN_IMAGE win): IMAGE-xcode<pin>, made by `xless setup --xcode <Xcode.xip>`. The plain
# default images are versions.env's Xcode's, so they serve that pin when no suffixed image exists.
default_xcode="$(sed -n 's/^XCODE_VERSION=//p' "$(dirname "$0")/../versions.env" 2>/dev/null || true)"
image_exists() { "${docker_cli[@]}" image inspect "$1" >/dev/null 2>&1; }
pin_missing=()
apply_pin() {   # VAR: the image named by $VAR, for the pinned Xcode
  local v="$1" name="${!1}" want
  [[ -n "$XCODE_PIN" ]] || return 0
  want="$name-xcode$XCODE_TAG"
  if image_exists "$want"; then printf -v "$v" '%s' "$want"; return 0; fi
  if [[ -n "$default_xcode" && "$XCODE_TAG" == "$(canonical_xcode "$default_xcode")" ]] && image_exists "$name"; then return 0; fi
  pin_missing+=("$want")
}
need_images() {   # IMAGE...: a real run needs the images built here (docker run never pulls them)
  [[ $use_docker == 1 && "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]] || return 0
  local i
  for i in "$@"; do
    image_exists "$i" || die "the image $i is not built on this machine (xless images are never pulled from a registry); build it with: xless setup --xcode <Xcode.xip> --arch $arch"
  done
}
check_pin() {   # after apply_pin: refuse missing images with the command that builds them
  [[ -n "$XCODE_PIN" && $use_docker == 1 ]] || return 0
  [[ ${#pin_missing[@]} -eq 0 ]] || die "$pin_file pins xcode: \"$XCODE_PIN\", but these images are missing: ${pin_missing[*]}; build them from Xcode $XCODE_TAG: xless setup --xcode <path to Xcode $XCODE_TAG's .app or .xip> --arch $arch"
  echo "==> xcode: \"$XCODE_PIN\" (pinned): $*" >&2
}

if [[ -z "$OVERLAY" ]]; then
  # A project directory: one `xless ship`. Secrets are mounted, and xless scrubs them from the environment of the tools
  # it runs, but the files stay readable to package code (SwiftPM plugins and macros) built in the same container.
  if [[ $given_build == 1 ]]; then echo "==> TestFlight: build number from --build-number" >&2
  else echo "==> TestFlight: build number $XLESS_BUILD_NUMBER" >&2; fi
  set +e
  if [[ $use_docker == 1 ]]; then
    image="${XLESS_IMAGE:-xless:local-$arch}"
    [[ -n "${XLESS_IMAGE:-}" ]] || apply_pin image
    check_pin "$image"
    need_images "$image"
    run "${docker_run[@]}" --mount "$(bind "$PROJECT" /work)" -w /work ${asc_secrets[@]+"${asc_secrets[@]}"} ${dist_secret[@]+"${dist_secret[@]}"} -e XLESS_BUILD_NUMBER \
      "$image" xless ship --platform ios "$@"
  else
    cd "$PROJECT"
    run xless ship --platform ios "$@"
  fi
  code=$?
  set -e
  if [[ $code -eq 0 && $step3 == 0 ]]; then echo "==> TestFlight: stopped after $pto (--to), nothing delivered" >&2; exit 0; fi
  finish $code
fi

# --config: the three steps. Images, caches and the step 1 command per overlay type.
if [[ $RN == 1 || $CARGO == 1 ]]; then next_build=(xless next-build); else next_build=(xless tauri next-build); fi
if [[ $use_docker == 1 ]]; then
  app=(--mount "$(bind "$SOURCE_MOUNT" /source ro)" --mount "$(bind "$(dirname "$OVERLAY")" /config ro)")
  xl=(--config "/config/$(basename "$OVERLAY")" --source "/source$SOURCE_SUB")
  if [[ $RN == 1 ]]; then
    image="${XLESS_IMAGE:-xless-rn:local-$arch}"
    key_image="${XLESS_SIGN_IMAGE:-xless-base:local-$arch}"
    # One work volume per overlay file: its name, and a hash of its path (two overlays never share a work copy).
    ov_name="$(basename "$OVERLAY")"; ov_name="${ov_name%.*}"; ov_name="$(printf '%s' "$ov_name" | tr -c 'A-Za-z0-9_.-' '-')"
    ov_hash="$( { command -v sha256sum >/dev/null && printf '%s' "$OVERLAY" | sha256sum || printf '%s' "$OVERLAY" | shasum -a 256; } | cut -c1-8)"
    rn_work="${XLESS_RN_WORK_VOLUME:-xless-rn-work-$ov_name-$ov_hash}"
    build_caches=(-v "$rn_work:/cache/work" -v xless-corepack:/cache/corepack -v xless-bundle:/cache/bundle
                  -v xless-cocoapods-home:/root/.cocoapods -v xless-cocoapods-cache:/root/Library/Caches/CocoaPods
                  -e "XLESS_WORK_VOLUME=$rn_work")
    [[ -z "${XLESS_RN_CLEAN:-}" ]] || build_caches+=(-e XLESS_RN_CLEAN)
    # the base image sets no work root: the work copy is where step 2 left it
    sign_caches=(-v "$rn_work:/cache/work" -e XLESS_WORK_ROOT=/cache/work -e "XLESS_WORK_VOLUME=$rn_work")
    echo "==> React Native: work volume $rn_work" >&2
  else
    image="${XLESS_IMAGE:-xless-tauri:local-$arch}"
    key_image="$image"
    cache="$HOME/.cache/xless"
    [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]] || mkdir -p "$cache/work" "$cache/downloads"
    build_caches=(--mount "$(bind "$cache/work" /cache/work)" --mount "$(bind "$cache/downloads" /cache/downloads)" -e XLESS_CACHE=/cache
                  -v xless-rustup:/cache/rustup -v xless-cargo:/cache/cargo)
    if [[ $CARGO == 1 ]]; then   # the checkouts of git inputs; the overlay's path inputs are mounted below
      [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]] || mkdir -p "$cache/inputs"
      build_caches+=(--mount "$(bind "$cache/inputs" /cache/inputs)")
      for ((k = 0; k < ${#input_names[@]}; k++)); do
        build_caches+=(--mount "$(bind "${input_paths[$k]}" "/inputs/${input_names[$k]}" ro)")
      done
      build_caches+=(-e XLESS_INPUTS_MOUNTED=1)
    fi
    sign_caches=(--mount "$(bind "$cache/work" /cache/work)")
  fi
else
  # native: --source only when XLESS_SOURCE overrides the overlay's own `source:`
  xl=(--config "$OVERLAY"); [[ -z "${XLESS_SOURCE:-}" ]] || xl+=(--source "$SOURCE")
  # step 2 runs without the secret variables (xless also scrubs them from its tools); the files stay on disk
  scrub=(env); for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 XLESS_DIST_KEY XLESS_DEVID_KEY; do scrub+=(-u "$v" -u "${v}_FILE"); done
fi
bn=(); [[ -z "${XLESS_BUILD_NUMBER:-}" ]] || bn=(-e XLESS_BUILD_NUMBER)
if [[ $use_docker == 1 ]]; then
  [[ -n "${XLESS_IMAGE:-}" ]] || apply_pin image
  # A simulator build runs step 2 only: the App Store Connect image is never used, so it is neither selected nor required.
  if [[ $RN == 1 && $SIM == 0 ]]; then [[ -n "${XLESS_SIGN_IMAGE:-}" ]] || apply_pin key_image; elif [[ $RN == 0 ]]; then key_image="$image"; fi
  if [[ $RN == 1 && $SIM == 0 ]]; then check_pin "build $image, App Store Connect steps $key_image"; else check_pin "$image"; fi
  if [[ $RN == 1 && $SIM == 0 ]]; then need_images "$image" "$key_image"; else need_images "$image"; fi
fi

# React Native: step 2 (xless-rn) and steps 1 and 3 (xless-base) must run the same xless, or step 3 could misread what
# step 2 wrote. The images are compared by the digest of their xless binary (not for a simulator build: step 2 only).
if [[ $use_docker == 1 && $RN == 1 && $SIM == 0 && "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]]; then
  digest() { "${docker_run[@]}" --entrypoint sha256sum "$1" /usr/local/bin/xless 2>/dev/null | cut -c1-64; }
  d2="$(digest "$image")" || true; d13="$(digest "$key_image")" || true
  [[ -n "$d2" ]] || die "cannot read xless from $image (is the image built? xless setup --xcode <Xcode.xip>)"
  [[ -n "$d13" ]] || die "cannot read xless from $key_image (is the image built? xless setup --xcode <Xcode.xip>)"
  [[ "$d2" == "$d13" ]] || die "$image and $key_image hold different xless builds (${d2:0:12} vs ${d13:0:12}); rebuild both from the same commit (xless setup --xcode <Xcode.xip>), or set XLESS_IMAGE / XLESS_SIGN_IMAGE to matching images"
fi

# Step 1: the build number, only for a run that starts (later stages read the one recorded in the work copy).
if [[ $step1 == 1 ]]; then
  echo "==> TestFlight: step 1/3, next build number (App Store Connect, read-only)" >&2
  if [[ $use_docker == 1 ]]; then cmd=("${docker_run[@]}" "${app[@]}" "${asc_secrets[@]}" "$key_image" "${next_build[@]}" "${xl[@]}")
  else cmd=("${next_build[@]}" "${xl[@]}"); fi
  if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then
    run "${cmd[@]}"; XLESS_BUILD_NUMBER="<next-build>"
  else
    set +e; out="$("${cmd[@]}")"; code=$?; set -e
    [[ $code -eq 0 ]] || finish $code
    XLESS_BUILD_NUMBER="$(printf '%s\n' "$out" | tail -1)"
    [[ "$XLESS_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "${next_build[*]} printed '$XLESS_BUILD_NUMBER', not a build number"
  fi
  export XLESS_BUILD_NUMBER
  bn=(-e XLESS_BUILD_NUMBER)
fi
if [[ -n "${XLESS_BUILD_NUMBER:-}" ]]; then echo "==> TestFlight: build number $XLESS_BUILD_NUMBER" >&2
elif [[ $given_build == 1 ]]; then echo "==> TestFlight: build number from --build-number" >&2
elif [[ "$PLATFORM" == macos ]]; then echo "==> DMG: build number chosen from the clock when the run starts" >&2
elif [[ $SIM == 1 ]]; then echo "==> Simulator: build number chosen from the clock when the run starts" >&2
else echo "==> TestFlight: build number recorded in the work copy" >&2; fi

# Step 2: the build, with no secret in reach.
if [[ $fi_ -le 3 ]]; then
  bto="$to"; [[ $ti -le 3 ]] || bto=finalize
  dest=(); [[ $SIM == 0 ]] || dest=(--destination simulator)
  if [[ $SIM == 1 ]]; then echo "==> Simulator: $from to $bto (no secrets)" >&2; else echo "==> TestFlight: step 2/3, $from to $bto (no secrets)" >&2; fi
  log2=/dev/null
  if [[ $SIM == 1 && "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]]; then log2="$(mktemp)"; trap 'rm -f "$log2"' EXIT; fi
  step2() {
    if [[ $use_docker == 1 ]]; then
      run "${docker_run[@]}" "${app[@]}" "${build_caches[@]}" -e "XLESS_SOURCE_ORIGIN=$SOURCE" ${bn[@]+"${bn[@]}"} \
        "$image" xless ship --platform "$PLATFORM" "${xl[@]}" ${dest[@]+"${dest[@]}"} --from "$from" --to "$bto" ${extra[@]+"${extra[@]}"}
    else
      run "${scrub[@]}" xless ship --platform "$PLATFORM" "${xl[@]}" ${dest[@]+"${dest[@]}"} --from "$from" --to "$bto" ${extra[@]+"${extra[@]}"}
    fi
  }
  set +e
  if [[ $SIM == 1 ]]; then step2 | tee "$log2"; code=${PIPESTATUS[0]}; else step2; code=$?; fi
  set -e
  if [[ $SIM == 1 ]]; then
    [[ $code -eq 0 ]] || finish $code
    if [[ $to == build && "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]]; then
      built="$(grep '\.app$' "$log2" | tail -1 || true)"
      if [[ $use_docker == 1 ]]; then built="volume:$rn_work:$built"; fi
      echo "==> Simulator app: $built" >&2
      if [[ "$(uname -s)" == Darwin ]]; then echo "==> launch it on this Mac: scripts/sim-launch.sh $built" >&2; fi
    fi
    echo "==> Simulator build finished (nothing signed for distribution or uploaded)" >&2
    exit 0
  fi
  [[ $code -eq 0 ]] || finish $code
fi

# Step 3: sign, package, upload with the secrets; no build code runs here.
if [[ $step3 == 1 ]]; then
  sfrom="$from"; [[ $fi_ -ge 4 ]] || sfrom=sign
  echo "==> TestFlight: step 3/3, $sfrom to $to" >&2
  if [[ "$PLATFORM" == macos ]]; then
    # Macs ship two channels in one run, each signing its own copy of the signed-app build:
    # sign→package is the Developer-ID DMG; sign→upload under --distribution app-store is the
    # Apple-Distribution flat package that App Store Connect receives and TestFlight delivers.
    # A failure in either channel stops the run with that channel's code; the DMG's work does
    # not depend on the second ship.
    mac_tf_to="package"; [[ "$(index "$to")" -ge 6 ]] || mac_tf_to="$to"
    if [[ $use_docker == 1 ]]; then
      if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then
        run "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" "${asc_secrets[@]}" "${dist_secret[@]}" ${bn[@]+"${bn[@]}"} \
          "$key_image" xless ship --platform macos "${xl[@]}" --from "$sfrom" --to "$mac_tf_to" ${extra[@]+"${extra[@]}"}
        if [[ "$(index "$to")" -ge 6 ]]; then
          run "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" "${asc_secrets[@]}" ${appstore_secret[@]+"${appstore_secret[@]}"} ${bn[@]+"${bn[@]}"} \
            "$key_image" xless ship --platform macos "${xl[@]}" --distribution app-store --from sign --to upload ${extra[@]+"${extra[@]}"}
        fi
        echo "==> TestFlight: stopped after $to (--to), nothing delivered" >&2
        exit 0
      fi
      log="$(mktemp)"; trap 'rm -f "$log"' EXIT
      set +e
      "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" "${asc_secrets[@]}" "${dist_secret[@]}" ${bn[@]+"${bn[@]}"} \
        "$key_image" xless ship --platform macos "${xl[@]}" --from "$sfrom" --to "$mac_tf_to" ${extra[@]+"${extra[@]}"} | tee "$log"
      code=${PIPESTATUS[0]}
      [[ $code -eq 0 ]] || { set -e; echo "==> xless exited with code $code" >&2; exit "$code"; }
      dmg="$(grep '\.dmg$' "$log" | tail -1 || true)"
      [[ $use_docker == 0 ]] || dmg="${dmg/#\/cache\/work/$cache/work}"
      echo "==> DMG: $dmg" >&2
      if [[ "$(index "$to")" -ge 6 ]]; then
        "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" "${asc_secrets[@]}" ${appstore_secret[@]+"${appstore_secret[@]}"} ${bn[@]+"${bn[@]}"} \
          "$key_image" xless ship --platform macos "${xl[@]}" --distribution app-store --from sign --to upload ${extra[@]+"${extra[@]}"} | tee "$log"
        code=${PIPESTATUS[0]}
        [[ $code -eq 0 ]] || { set -e; echo "==> xless exited with code $code (the TestFlight upload)" >&2; exit "$code"; }
        pkg="$(grep '\.pkg$' "$log" | tail -1 || true)"
        [[ $use_docker == 0 ]] || pkg="${pkg/#\/cache\/work/$cache/work}"
        echo "==> PKG: $pkg" >&2
      fi
      set -e
      echo "==> DMG build finished" >&2
      exit 0
    fi
    # native (a macOS host run): the same two channels, xless straight from the env.
    set +e
    shiplog="$(mktemp)"; trap 'rm -f "$shiplog"' EXIT
    dmg_out="$(xless ship --platform macos "${xl[@]}" --from "$sfrom" --to "$mac_tf_to" ${extra[@]+"${extra[@]}"} 2>"$shiplog")"
    code=$?
    [[ $code -eq 0 ]] || { set -e; cat "$shiplog" >&2; echo "==> xless exited with code $code" >&2; exit "$code"; }
    dmg="$(grep '\.dmg$' <<<"$dmg_out" | tail -1 || true)"
    echo "==> DMG: $dmg" >&2
    echo "==> DMG build finished" >&2
    if [[ "$(index "$to")" -ge 6 ]]; then
      : > "$shiplog"
      pkg_out="$(xless ship --platform macos "${xl[@]}" --distribution app-store --from sign --to upload ${extra[@]+"${extra[@]}"} 2>"$shiplog")"
      code=$?
      [[ $code -eq 0 ]] || { set -e; cat "$shiplog" >&2; echo "==> xless exited with code $code (the TestFlight upload)" >&2; exit "$code"; }
      pkg="$(grep '\.pkg$' <<<"$pkg_out" | tail -1 || true)"
      echo "==> PKG: $pkg" >&2
    fi
    set -e
    exit 0
  fi
  set +e
  if [[ $use_docker == 1 ]]; then
    run "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" "${asc_secrets[@]}" "${dist_secret[@]}" ${bn[@]+"${bn[@]}"} \
      "$key_image" xless ship --platform "$PLATFORM" "${xl[@]}" --from "$sfrom" --to "$to" ${extra[@]+"${extra[@]}"}
  else
    run xless ship --platform "$PLATFORM" "${xl[@]}" --from "$sfrom" --to "$to" ${extra[@]+"${extra[@]}"}
  fi
  code=$?
  set -e
  finish $code
fi
echo "==> TestFlight: stopped after $to (--to), nothing delivered" >&2
exit 0
