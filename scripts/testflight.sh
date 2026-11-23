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
#   `xless run` sets it: 0, or 1 with --docker (`xless docker`: 1). Natively the steps run $XLESS_SELF (else xless on PATH).
#
# Configuration comes from the environment, and from a local file that is sourced first when it exists:
#   $XLESS_TESTFLIGHT_ENV, default ~/.config/xless/testflight.env   (keep it out of git; it holds paths and IDs only)
# The secret store (`xless secrets`, docs/secrets.md#xless-run-and-docker-builds): a secret whose *_FILE is not set
#   comes from it (the API key and its IDs together: set ASC_KEY_P8_FILE, ASC_KEY_ID and the issuer, or none of them).
#   Natively xless reads it (the script checks first, by name, that it holds them all; step 2 gets
#   XLESS_NO_SECRET_STORE=1). In docker the host's xless (`xless secrets materialize`, $XLESS_SELF else PATH) writes
#   them once, before step 1, to a fresh $XDG_RUNTIME_DIR/xless/<random>/ (a tmpfs; with --allow-disk-secrets, any
#   file system, else ~/.cache/xless/secrets/), one directory per container: next (step 1), sign (step 3, or the
#   project's container, or the DMG ship), appstore (the mac App-Store ship). Each is mounted read-only at
#   /secrets/store into its container only and removed when it ends; cleanup removes the rest. The store prefers the
#   entries of the project's or overlay's top-level teamID:. The TestFlight demo account's password (testflight.external
#   .review.demoAccount; its secret's name, passwordSecret, read by the host's xless: `xless secrets named-by`) goes to
#   the container that uploads only (sign, or appstore on macos), when the store has it: it is sent only when the demo
#   account is new, renamed or newly required, so a store without it stops nothing up front.
# Variables (see docs/signing-and-testflight.md):
#   ASC_KEY_ID               App Store Connect API key ID                      (required, unless the store has the key)
#   ASC_ISSUER_ID_FILE       file holding the issuer ID   (or ASC_ISSUER_ID)   (required, unless the store has the key)
#   ASC_KEY_P8_FILE          the API key .p8 file                              (required, unless the store has it)
#   XLESS_DIST_KEY_FILE      the Apple Distribution private key (PEM)          (required on ios; on macos when --to upload runs the App-Store lane: the app's signature)
#   XLESS_DEVID_KEY_FILE     the Developer ID Application private key (PEM)    (required with --platform macos)
#   XLESS_INSTALLER_KEY_FILE the Mac Installer Distribution private key (PEM)  (macos, only when --to upload runs the App-Store lane)
#   XLESS_DEMO_PASSWORD_FILE the TestFlight demo account's password (<passwordSecret>_FILE for a name of your own)
#                            (only for a run that uploads with testflight.external.review.demoAccount; else the store's)
#     (the signing keys too: each *_FILE is needed unless the store has the key;
#      "required" means: when a step that uses it runs. A project directory needs none of them for a run that stops
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
#   images made from that Xcode by `xless setup --docker --xcode <Xcode.app | .xip>`: <image>:local-<arch>-xcode<version>, e.g.
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

# On exit, and when stopped (INT, TERM, HUP), remove this run's containers (labelled with $run_label; `--rm` acts only
# once a container exits on its own), release its work copy ($wc_lock, below) and remove its temporary files.
run_label=""; tmpfiles=(); job=""; wc_lock=""; wc_takeover=""; in_job=""; secrets_dir=""; secrets_out=""
# PID: TERM PID and every process under it, deepest first. A job of a non-interactive bash ignores INT (and xless sets
# no handler), so Ctrl-C alone would leave a native build running after the script exits.
stop_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do stop_tree "$c"; done
  kill -TERM "$1" 2>/dev/null || true
}
cleanup() {
  if [[ -n "$job" ]]; then   # and wait (5 s at most) for it, before another run may take the work copy
    stop_tree "$job"
    for _ in $(seq 50); do running "$job" || break; sleep 0.1; done
  fi
  if [[ -n "$run_label" && "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]]; then
    local ids
    ids="$("${docker_cli[@]}" ps -aq --filter "label=$run_label" 2>/dev/null)" || ids=""
    # shellcheck disable=SC2086 # container IDs: hex words
    if [[ -n "$ids" ]] && ! "${docker_cli[@]}" rm -f $ids >/dev/null; then
      echo "testflight: could not remove this run's containers; remove them with: ${docker_cli[*]} rm -f ${ids//$'\n'/ }" >&2
    fi
  fi
  if [[ -n "$wc_lock" ]] && grep -qx "pid=$$" "$wc_lock" 2>/dev/null; then rm -f "$wc_lock"; fi
  [[ -z "$wc_takeover" ]] || rmdir "$wc_takeover" 2>/dev/null || true
  drop_secrets
  rm -f ${tmpfiles[@]+"${tmpfiles[@]}"}
}
# The secrets `xless secrets materialize` wrote for this run (below): its run directory, which it prints first, even
# when it was stopped half-way. Only a path of the shape it creates is removed.
is_secrets_dir() { [[ "$1" =~ ^/([^/]+/)*xless(/secrets)?/[0-9a-f]{32}$ && "$1" != */../* && "$1" != */./* ]]; }
drop_secrets() {   # [SET]: that set's directory, or the whole run directory
  local d="$secrets_dir"
  [[ -n "$d" || -z "$secrets_out" ]] || d="$(head -1 "$secrets_out" 2>/dev/null || true)"
  is_secrets_dir "$d" || return 0
  if [[ -n "${1:-}" ]]; then rm -rf -- "${d:?}/$1"; else rm -rf -- "$d"; fi
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

# One run per work copy (fmsouza/xless#57). A run holds a lock on its work copy, ~/.cache/xless/locks/<hash>.lock: its
# PID, the start time of that process (so a reused PID is not taken for it), its host (for the messages) and, while a
# step runs, the step's job. A run on a work copy that a live run holds is refused. A SIGKILL leaves no chance to clean
# up, so the next run on that work copy takes the lock over and stops what the killed run left: the job it recorded,
# and every container labelled xless.work=<hash> (every run that labels a container so holds the lock while it runs).
wc_owner=""
running() { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }   # PID: alive, not a zombie
# PID: its start time, the same text whatever the caller's time zone and locale; empty when unknown
started_of() { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }
is_proc() {   # PID STARTED: PID is running, and is the process that started at STARTED (not a reused PID)
  [[ -n "$2" && "$(started_of "$1")" == "$2" ]] && running "$1"
}
holds() {   # PID STARTED: the run that wrote a lock is alive. When in doubt, it is: a start time that ps cannot give, or
  # one that moved (a clock stepped under a long build), still counts for a PID that runs this script.
  running "$1" || return 1
  is_proc "$1" "$2" || [[ -z "$2" || -z "$(started_of "$1")" ]] || [[ "$(ps -o command= -p "$1" 2>/dev/null)" == *testflight.sh* ]]
}
sha_hex() { if command -v sha256sum >/dev/null; then printf '%s' "$1" | sha256sum; else printf '%s' "$1" | shasum -a 256; fi | cut -c1-64; }   # TEXT
lock_field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }   # NAME TEXT: the lock's NAME= line
hold_work_copy() {   # KEY: take the lock of the work copy KEY names (a path, or a docker volume), or stop
  # (no local named job: cleanup, which a die here runs, reads the global one)
  local key="$1" dir="$HOME/.cache/xless/locks" hash lock tmp old pid started host step held=0 ids
  hash="$(sha_hex "$key" | cut -c1-12)"
  [[ $use_docker == 0 ]] || docker_run+=(--label "xless.work=$hash")
  [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]] || return 0
  lock="$dir/$hash.lock"; tmp="$dir/$hash.$$"; tmpfiles+=("$tmp" "$tmp.new" "$lock.$$")
  mkdir -p "$dir" || die "cannot create $dir, for the lock of the work copy $key"
  wc_owner="$(printf 'pid=%s\nstarted=%s\nhost=%s\nwork=%s' "$$" "$(started_of $$)" "$(uname -n)" "$key")"
  printf '%s\n' "$wc_owner" > "$tmp"
  ! ln "$tmp" "$lock" 2>/dev/null || held=1   # a hard link: created whole, and only when no lock is there
  if [[ $held == 0 ]]; then
    old="$(cat "$lock" 2>/dev/null)" || die "cannot take the lock $lock of the work copy $key"
    pid="$(lock_field pid "$old")"; started="$(lock_field started "$old")"; host="$(lock_field host "$old")"; step="$(lock_field job "$old")"
    if holds "$pid" "$started"; then
      die "the work copy $key is in use by another run (pid $pid on $host, started $started); wait for it to end, or stop it: kill $pid"
    fi
    # That run is gone: take the lock over, one taker at a time (the .takeover directory). The lock is replaced by a
    # rename, so it never disappears and no new run can take it in between.
    if mkdir "$lock.takeover" 2>/dev/null; then
      wc_takeover="$lock.takeover"
      if [[ "$(cat "$lock" 2>/dev/null)" == "$old" ]]; then cp "$tmp" "$tmp.new" && mv -f "$tmp.new" "$lock" && held=1; fi
      rmdir "$wc_takeover"; wc_takeover=""
    fi
    [[ $held == 1 ]] || die "another run is taking over the work copy $key; run again (if none is, remove $lock.takeover)"
    wc_lock="$lock"
    echo "==> work copy $key: the run that held it (pid $pid) is gone without cleaning up; stopping what it left" >&2
    if is_proc "${step%% *}" "${step#* }"; then
      echo "==> stopping its step (pid ${step%% *})" >&2
      stop_tree "${step%% *}"
      for _ in $(seq 50); do is_proc "${step%% *}" "${step#* }" || break; sleep 0.1; done
      ! is_proc "${step%% *}" "${step#* }" || die "the step of the run that held the work copy $key (pid ${step%% *}) does not stop; stop it: kill -9 ${step%% *}"
    fi
    # the secrets it wrote from the store: their run directory is the first line of the file it recorded
    old_out="$(lock_field secrets_out "$old")"
    if [[ -n "$old_out" && -f "$old_out" ]]; then
      old_dir="$(head -1 "$old_out" 2>/dev/null || true)"
      if is_secrets_dir "$old_dir" && [[ -d "$old_dir" ]]; then
        echo "==> removing the secrets it left in $old_dir" >&2
        rm -rf -- "$old_dir"
      fi
    fi
  fi
  wc_lock="$lock"
  if [[ $use_docker == 1 ]]; then
    ids="$("${docker_cli[@]}" ps -aq --filter "label=xless.work=$hash" 2>/dev/null)" || ids=""
    if [[ -n "$ids" ]]; then
      echo "==> work copy $key: removing the containers a gone run left on it: ${ids//$'\n'/ }" >&2
      # shellcheck disable=SC2086 # container IDs: hex words
      "${docker_cli[@]}" rm -f $ids >/dev/null \
        || die "could not remove the containers a gone run left on the work copy $key; remove them with: ${docker_cli[*]} rm -f ${ids//$'\n'/ }"
    fi
  fi
}
note_job() {   # records the running step ($job) in the lock, for the run that takes over if this one is killed
  # only from the script's own shell ($in_job is set in a job's subshell), and only while the lock is still this run's
  [[ -n "$wc_lock" && -z "$in_job" ]] && grep -qx "pid=$$" "$wc_lock" 2>/dev/null || return 0
  # best effort: a lock without its job still guards the work copy (written aside, then renamed: never read half-written)
  { printf '%s\njob=%s %s\n' "$wc_owner" "$job" "$(started_of "$job")" > "$wc_lock.$$" && mv -f "$wc_lock.$$" "$wc_lock"; } 2>/dev/null || true
}

usage="usage: $0 <project-dir> [extra xless ship args...]   or   $0 --config <overlay.yml> [--platform ios|macos] [--destination device|simulator] [--dry-run] [--allow-disk-secrets] [extra args...]"
[[ $# -ge 1 ]] || die "$usage"
PLATFORM=ios
DESTINATION=device
ALLOW_DISK=0
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) [[ $# -ge 2 ]] || die "--platform needs ios or macos"; PLATFORM="$2"; shift 2 ;;
    --platform=*) PLATFORM="${1#--platform=}"; shift ;;
    --destination) [[ $# -ge 2 ]] || die "--destination needs device or simulator"; DESTINATION="$2"; shift 2 ;;
    --destination=*) DESTINATION="${1#--destination=}"; shift ;;
    --dry-run) XLESS_TESTFLIGHT_DRY_RUN=1; shift ;;
    --allow-disk-secrets) ALLOW_DISK=1; shift ;;
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

use_docker=0
# Natively, the xless that started this script (`xless run` sets XLESS_SELF), else the one on PATH.
xself="${XLESS_SELF:-xless}"
case "${XLESS_USE_DOCKER:-auto}" in
  1) use_docker=1 ;;
  0) use_docker=0 ;;
  # auto: the images, unless an SDK is installed natively (xless sdk install writes toolchain-meta.json)
  auto) if [[ ! -e "${XLESS_TOOLCHAIN_META:-${XDG_CONFIG_HOME:-$HOME/.config}/xless/toolchain-meta.json}" ]] || ! command -v "$xself" >/dev/null 2>&1; then use_docker=1; fi ;;
  *) die "XLESS_USE_DOCKER must be 0, 1 or unset" ;;
esac

# The secrets of the steps that run (for a project directory: all of them, or none before sign).
need_asc=0; need_key=0
[[ $step1 == 0 && $step3 == 0 ]] || need_asc=1
[[ $step3 == 0 ]] || need_key=1
# The signing keys: the first ship's (Apple Distribution on iOS, Developer ID for the DMG), and those of the mac
# App-Store lane (--to upload): the app is signed with the Apple Distribution key and the flat pkg with the Mac
# Installer Distribution key (the Developer ID one stays for the DMG). Only an upload-reaching run needs them in reach.
sign_keys=(); lane_keys=(); mac_lane=0
if [[ $need_key == 1 ]]; then
  if [[ "$PLATFORM" == macos ]]; then sign_keys=(XLESS_DEVID_KEY); else sign_keys=(XLESS_DIST_KEY); fi
  if [[ "$PLATFORM" == macos && $(index "$to") -ge 6 ]]; then mac_lane=1; lane_keys=(XLESS_DIST_KEY XLESS_INSTALLER_KEY); fi
fi
# Secret file paths are made absolute (docker -v needs absolute host paths) and must be readable.
abs_file() {   # NAME: resolve $NAME to an absolute path in place
  local v="$1" p="${!1}"
  [[ -r "$p" ]] || die "$v points to a file that does not exist or is unreadable"
  [[ "$p" == /* ]] || p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  printf -v "$v" '%s' "$p"
}
# Where each secret comes from: NAME_FILE (set in the environment or the env file) wins, as does NAME itself natively;
# else the encrypted secret store (`xless secrets`): natively xless reads it itself, and in docker the host's xless
# writes what each container needs to a tmpfs first (below). The App Store Connect key and its IDs come from one place.
asc_store=0
if [[ $need_asc == 1 ]]; then
  if [[ -n "${ASC_KEY_P8_FILE:-}" || ( $use_docker == 0 && -n "${ASC_KEY_P8:-}" ) ]]; then
    [[ -n "${ASC_KEY_ID:-}" ]] || die "set ASC_KEY_ID in the environment or $ENV_FILE"
    [[ -n "${ASC_ISSUER_ID_FILE:-}${ASC_ISSUER_ID:-}" ]] || die "set ASC_ISSUER_ID_FILE (or ASC_ISSUER_ID) in the environment or $ENV_FILE"
    [[ -z "${ASC_KEY_P8_FILE:-}" ]] || abs_file ASC_KEY_P8_FILE
    [[ -z "${ASC_ISSUER_ID_FILE:-}" ]] || abs_file ASC_ISSUER_ID_FILE
  elif [[ -n "${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}${ASC_ISSUER_ID_FILE:-}" ]]; then
    die "ASC_KEY_ID or ASC_ISSUER_ID is set, but not ASC_KEY_P8_FILE: set ASC_KEY_P8_FILE in the environment or $ENV_FILE, or unset the IDs to use the App Store Connect key of the secret store (xless secrets), which carries its IDs"
  else
    asc_store=1
  fi
fi
store_keys=()
for v in ${sign_keys[@]+"${sign_keys[@]}"} ${lane_keys[@]+"${lane_keys[@]}"}; do
  f="${v}_FILE"
  if [[ -n "${!f:-}" ]]; then abs_file "$f"
  elif [[ $use_docker == 1 || -z "${!v:-}" ]]; then store_keys+=("$v"); fi
done
# In docker a secret's value itself (NAME, not NAME_FILE) is never passed into a container: the store's is used.
for v in ASC_KEY_P8 ${store_keys[@]+"${store_keys[@]}"}; do
  [[ $use_docker == 0 || -z "${!v:-}" ]] || [[ $v == ASC_KEY_P8 && $asc_store == 0 ]] \
    || echo "==> note: $v is set, but docker builds take only ${v}_FILE (a file to mount); using the secret store's $v" >&2
done
# The TestFlight demo account's password (xless.yml's or the overlay's testflight.external.review.demoAccount): only
# the upload reads it, so only the container that uploads gets it (step 3, the project's container, or the mac
# App-Store ship), never step 2. Its name may be the user's own (passwordSecret): the host's xless reads the
# configuration (`xless secrets named-by`, nothing when the account never needs its password sent). From NAME_FILE when
# set, else, in docker, from the store as an optional secret: Apple never gives the password back, so it is sent only
# when the demo account is new, renamed or newly required, and a store without it stops nothing up front. Natively
# xless reads it itself; the build step (2) runs without NAME and NAME_FILE.
demo_names=(); demo_store=(); demo_files=()
upload=0
if [[ -n "$OVERLAY" ]]; then [[ $SIM == 1 || $ti -lt 6 ]] || upload=1; else [[ $pti -lt 6 ]] || upload=1; fi
if [[ $upload == 1 ]]; then
  if command -v "$xself" >/dev/null 2>&1; then
    if [[ -n "$OVERLAY" ]]; then named=(--config "$OVERLAY" --platform "$PLATFORM"); else named=(--project "$PROJECT"); fi
    # (an answer that is not names, as from an xless too old to know the command, counts as none)
    if names_out="$("$xself" secrets named-by "${named[@]}" 2>/dev/null)" \
       && [[ "$names_out" =~ ^([A-Za-z_][A-Za-z0-9_]*(@[A-Z0-9]{10})?($'\n'|$))*$ ]]; then
      while IFS= read -r n; do [[ -z "$n" ]] || demo_names+=("$n"); done <<<"$names_out"
    else
      if [[ $use_docker == 1 ]]; then what="it is given to no container"; else what="xless reads it itself when it uploads"; fi
      echo "==> note: \"$xself\" secrets named-by could not tell which secret holds the TestFlight demo account's password: $what (xless says what is wrong when it reads the configuration)" >&2
    fi
  elif [[ -n "${XLESS_DEMO_PASSWORD_FILE:-}" ]]; then
    demo_names=(XLESS_DEMO_PASSWORD)   # no xless here to read the configuration: the default name, set as a file
  fi
fi
# (NAME and NAME_FILE are read from the environment only for upper-case names other than ENV: never one of this
# script's own variables, such as ENV_FILE, the env file)
own() { [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ && "$1" != ENV ]]; }
for n in ${demo_names[@]+"${demo_names[@]}"}; do
  f="${n}_FILE"
  if own "$n" && [[ -n "${!f:-}" ]]; then
    abs_file "$f"; demo_files+=("$n")
  elif [[ $use_docker == 1 ]]; then
    ! own "$n" || [[ -z "${!n:-}" ]] || echo "==> note: $n is set, but docker builds take only ${n}_FILE (a file to mount); using the secret store's $n" >&2
    demo_store+=("?$n")
  fi
done
# What the store gives, per container: `next` (step 1), `sign` (step 3, the project's one container, or the DMG ship)
# and `appstore` (the mac App-Store ship). The store prefers the project's team (its top-level teamID:).
has() { local n x="$1"; shift; for n in "$@"; do [[ "$n" != "$x" ]] || return 0; done; return 1; }   # WORD LIST…
store_sets=()
add_set() {   # NAME KEYS…: NAME=<the store's App Store Connect key and IDs, those of KEYS from the store, and ?OPTIONAL ones>
  local name="$1" k list=(); shift
  [[ $asc_store == 0 ]] || list=(ASC_KEY_P8 ASC_KEY_ID ASC_ISSUER_ID)
  for k in "$@"; do [[ "$k" != \?* ]] && ! has "$k" ${store_keys[@]+"${store_keys[@]}"} || list+=("$k"); done
  [[ ${#list[@]} -gt 0 ]] || return 0
  local IFS=,; store_sets+=("$name=${list[*]}")
}
[[ $step1 == 0 ]] || add_set next
if [[ "$PLATFORM" == macos ]]; then   # the demo password goes to the container that uploads
  [[ $step3 == 0 ]] || add_set sign ${sign_keys[@]+"${sign_keys[@]}"}
  [[ $mac_lane == 0 ]] || add_set appstore "${lane_keys[@]}" ${demo_store[@]+"${demo_store[@]}"}
else
  [[ $step3 == 0 ]] || add_set sign ${sign_keys[@]+"${sign_keys[@]}"} ${demo_store[@]+"${demo_store[@]}"}
fi
TEAM="$(yaml_top "$pin_file" teamID)"; [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || TEAM=""
team_arg=(); [[ -z "$TEAM" ]] || team_arg=(--team "$TEAM")
if [[ ${#store_sets[@]} -gt 0 ]]; then
  command -v "$xself" >/dev/null 2>&1 || [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]] \
    || die "the secrets not set in the environment or $ENV_FILE come from the secret store, which xless on this host reads, and \"$xself\" is not on PATH: install xless (or set XLESS_SELF), or set the *_FILE variables (${store_sets[*]})"
fi

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
secret_vars=(ENV_FILE ASC_KEY_P8_FILE XLESS_DIST_KEY_FILE XLESS_DEVID_KEY_FILE XLESS_INSTALLER_KEY_FILE ASC_ISSUER_ID_FILE)
for n in ${demo_files[@]+"${demo_files[@]}"}; do secret_vars+=("${n}_FILE"); done
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
  waited "$@"
}
# CMD...: as a job the script waits for. bash runs a trap only once the foreground command has ended, so a stopped
# script would otherwise wait for the whole build before cleanup could remove its container.
# The job's PID is in $job while it runs, for cleanup to stop it (and in the work copy's lock, note_job).
waited() { local rc=0; "$@" & job=$!; note_job; wait "$job" || rc=$?; job=""; return "$rc"; }
# LOG CMD...: waited, with CMD's output also written to LOG; returns CMD's status.
waited_tee() {
  local log="$1" rc=0; shift
  { in_job=1; "$@" | tee "$log"; exit "${PIPESTATUS[0]}"; } & job=$!; note_job; wait "$job" || rc=$?; job=""; return "$rc"
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
  # --init: an init process forwards the stop signal docker run proxies to xless (which, as PID 1, would ignore it).
  # The label lets cleanup find this run's containers.
  run_label="xless.run=$$.$(date +%s)"
  docker_run+=(--init --label "$run_label")
  # Secrets by path or by name: values never appear on a command line.
  if [[ $need_asc == 1 && $asc_store == 0 ]]; then
    asc_secrets=(--mount "$(bind "$ASC_KEY_P8_FILE" /secrets/asc.p8 ro)" -e ASC_KEY_ID -e ASC_KEY_P8_FILE=/secrets/asc.p8)
    if [[ -n "${ASC_ISSUER_ID_FILE:-}" ]]; then
      asc_secrets+=(--mount "$(bind "$ASC_ISSUER_ID_FILE" /secrets/asc-issuer-id ro)" -e ASC_ISSUER_ID_FILE=/secrets/asc-issuer-id)
    else
      asc_secrets+=(-e ASC_ISSUER_ID)   # by name: the value never appears in the process list
    fi
  fi
  key_file() {   # VAR DST: add to words the mount of the file $VAR names at DST, when it is set (else the store gives it)
    [[ -z "${!1:-}" ]] || words+=(--mount "$(bind "${!1}" "$2" ro)" -e "$1=$2")
  }
  words=()
  if [[ $need_key == 1 && "$PLATFORM" == macos ]]; then
    key_file XLESS_DEVID_KEY_FILE /secrets/devid-key.pem; dist_secret=(${words[@]+"${words[@]}"}); words=()
    # The App-Store lane's keys, in the same shape: their own mounts, only the second ship takes them (and only a run that
    # reaches it has them: the variables may be unset otherwise).
    if [[ $mac_lane == 1 ]]; then
      key_file XLESS_DIST_KEY_FILE /secrets/dist-key.pem; key_file XLESS_INSTALLER_KEY_FILE /secrets/installer-key.pem
      appstore_secret=(${words[@]+"${words[@]}"}); words=()
    fi
  elif [[ $need_key == 1 ]]; then
    key_file XLESS_DIST_KEY_FILE /secrets/dist-key.pem; dist_secret=(${words[@]+"${words[@]}"}); words=()
  fi
  # the demo password's file, into the container that uploads only
  for n in ${demo_files[@]+"${demo_files[@]}"}; do key_file "${n}_FILE" "/secrets/passwords/$n"; done
  if [[ "$PLATFORM" == macos ]]; then appstore_secret+=(${words[@]+"${words[@]}"}); else dist_secret+=(${words[@]+"${words[@]}"}); fi
  words=()
fi

# Docker: the store's secrets, written once for the whole run (one passphrase) by the host's xless into a fresh
# $XDG_RUNTIME_DIR/xless/<random>/ (a tmpfs; anywhere else only with --allow-disk-secrets), one directory per container
# (next, sign, appstore: see store_sets), each mounted read-only at /secrets/store into its container only and removed
# when that container ends; whatever is left goes when the run ends, on an error and when it is stopped (cleanup).
if [[ ${#store_sets[@]} -gt 0 && $use_docker == 0 ]]; then
  # Natively each step's xless reads the store itself (the run's one process asks the passphrase once; with --config,
  # steps 1 and 3 are two). Check now, without the passphrase, that it holds them all, not after the build.
  run "$xself" secrets materialize --check ${team_arg[@]+"${team_arg[@]}"} "${store_sets[@]}" || exit $?
fi
next_store=(); sign_store=(); appstore_store=()
store_words() {   # SET: words=(the set's read-only mount, and NAME_FILE=/secrets/store/NAME for each of its secrets)
  local s n
  words=()
  for s in ${store_sets[@]+"${store_sets[@]}"}; do
    [[ "${s%%=*}" == "$1" ]] || continue
    words=(--mount "$(bind "$secrets_dir/$1" /secrets/store ro)")
    local IFS=,
    for n in ${s#*=}; do
      if [[ "$n" == \?* ]]; then   # optional: passed only when the store had it
        n="${n#\?}"
        if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 && ! -f "$secrets_dir/$1/$n" ]]; then
          echo "==> note: the secret store has no $n: a run that must send the TestFlight demo account's password stops at upload (store it with: xless secrets import $n --file <file> --kind password, or set ${n}_FILE)" >&2
          continue
        fi
      fi
      words+=(-e "${n}_FILE=/secrets/store/$n")
    done
  done
}
build_mounts=()   # the host folders the build container (step 2) mounts: no secret may be inside one
materialise() {   # docker: write the store's sets (one passphrase), after every check that could still stop the run
  [[ $use_docker == 1 && ${#store_sets[@]} -gt 0 ]] || return 0
  [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]] || prune_optional || return 0
  local mat=("$xself" secrets materialize ${team_arg[@]+"${team_arg[@]}"}) base d code=0
  [[ $ALLOW_DISK == 0 ]] || mat+=(--allow-disk)
  mat+=("${store_sets[@]}")
  if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then
    run "${mat[@]}"; secrets_dir="\$XDG_RUNTIME_DIR/xless/<run>"
  else
    # where xless will put them (SecretRunBase): refused before anything is written when a build mount holds it
    if [[ "${XDG_RUNTIME_DIR:-}" == /* && -d "$XDG_RUNTIME_DIR" ]]; then base="$XDG_RUNTIME_DIR/xless"
    elif [[ "${XDG_CACHE_HOME:-}" == /* ]]; then base="$XDG_CACHE_HOME/xless/secrets"
    else base="$HOME/.cache/xless/secrets"; fi
    not_in_build_mounts "$base"
    echo "==> secrets from the secret store: ${store_sets[*]}" >&2
    secrets_out="$(mktemp)"; tmpfiles+=("$secrets_out")
    # recorded in the work copy's lock first: a run that takes the lock over after a SIGKILL removes what this wrote
    [[ -z "$wc_lock" ]] || { wc_owner+=$'\n'"secrets_out=$secrets_out"; note_job; }
    waited "${mat[@]}" >"$secrets_out" || code=$?
    secrets_dir="$(head -1 "$secrets_out")"
    [[ $code -eq 0 ]] || { echo "==> xless exited with code $code (the secret store)" >&2; exit "$code"; }
    is_secrets_dir "$secrets_dir" && [[ -d "$secrets_dir" ]] || die "\"$xself\" secrets materialize printed '$secrets_dir', not a run directory"
    not_in_build_mounts "$secrets_dir"
  fi
  store_words next; next_store=(${words[@]+"${words[@]}"})
  store_words sign; sign_store=(${words[@]+"${words[@]}"})
  store_words appstore; appstore_store=(${words[@]+"${words[@]}"})
}
# Docker: the optional secrets (?NAME, the demo password) the store does not have leave store_sets, asked by name first
# (`materialize --check` prints those it has; no passphrase). A run whose other secrets are all files then opens the
# store, and needs a tmpfs, only when the store has the password. False when no secret is left to write.
prune_optional() {
  [[ "${store_sets[*]}" == *\?* ]] || return 0
  local s n out code=0 required=0 list names kept=()
  for s in "${store_sets[@]}"; do
    IFS=, read -r -a names <<<"${s#*=}"
    for n in "${names[@]}"; do [[ "$n" == \?* ]] || required=1; done
  done
  out="$("$xself" secrets materialize --check ${team_arg[@]+"${team_arg[@]}"} "${store_sets[@]}")" || code=$?
  if [[ $code -ne 0 ]]; then
    [[ $required == 0 ]] || { echo "==> xless exited with code $code (the secret store)" >&2; exit "$code"; }
    out=""   # only optional secrets: a store that cannot be read gives none of them
  fi
  for s in "${store_sets[@]}"; do
    list=()
    IFS=, read -r -a names <<<"${s#*=}"
    for n in "${names[@]}"; do
      if [[ "$n" == \?* ]] && ! grep -qxF -- "${n#\?}" <<<"$out"; then
        echo "==> note: the secret store has no ${n#\?}: a run that must send the TestFlight demo account's password stops at upload (store it with: xless secrets import ${n#\?} --file <file> --kind password, or set ${n#\?}_FILE)" >&2
        continue
      fi
      list+=("$n")
    done
    [[ ${#list[@]} -eq 0 ]] || kept+=("${s%%=*}=$(IFS=,; echo "${list[*]}")")
  done
  store_sets=(${kept[@]+"${kept[@]}"})
  [[ ${#store_sets[@]} -gt 0 ]]
}
not_in_build_mounts() {   # DIR: neither DIR (or, while it does not exist, its nearest parent) nor a parent of it is mounted into the build
  local p="$1" d
  while [[ ! -e "$p" && "$p" != / ]]; do p="$(dirname "$p")"; done
  for d in ${build_mounts[@]+"${build_mounts[@]}"}; do
    [[ -e "$d" ]] || continue
    if inside "$p/." "$d"; then
      die "the secret store's files ($1) would be inside $d, which is mounted into the build container; point XDG_RUNTIME_DIR elsewhere"
    fi
  done
}

# xcode: pin (docker only; XLESS_IMAGE / XLESS_SIGN_IMAGE win): IMAGE-xcode<pin>, made by `xless setup --docker --xcode <Xcode.xip>`. The plain
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
    image_exists "$i" || die "the image $i is not built on this machine (xless images are never pulled from a registry); build it with: xless setup --docker --xcode <Xcode.xip> --arch $arch"
  done
}
check_pin() {   # after apply_pin: refuse missing images with the command that builds them
  [[ -n "$XCODE_PIN" && $use_docker == 1 ]] || return 0
  [[ ${#pin_missing[@]} -eq 0 ]] || die "$pin_file pins xcode: \"$XCODE_PIN\", but these images are missing: ${pin_missing[*]}; build them from Xcode $XCODE_TAG: xless setup --docker --xcode <path to Xcode $XCODE_TAG's .app or .xip> --arch $arch"
  echo "==> xcode: \"$XCODE_PIN\" (pinned): $*" >&2
}

if [[ -z "$OVERLAY" ]]; then
  # A project directory: one `xless ship`. Secrets are mounted, and xless scrubs them from the environment of the tools
  # it runs, but the files stay readable to package code (SwiftPM plugins and macros) built in the same container.
  hold_work_copy "$(cd -P "$PROJECT" && pwd -P)"   # the project is its own work copy
  if [[ $given_build == 1 ]]; then echo "==> TestFlight: build number from --build-number" >&2
  else echo "==> TestFlight: build number $XLESS_BUILD_NUMBER" >&2; fi
  set +e
  if [[ $use_docker == 1 ]]; then
    image="${XLESS_IMAGE:-xless:local-$arch}"
    [[ -n "${XLESS_IMAGE:-}" ]] || apply_pin image
    check_pin "$image"
    need_images "$image"
    materialise
    run "${docker_run[@]}" --mount "$(bind "$PROJECT" /work)" -w /work ${asc_secrets[@]+"${asc_secrets[@]}"} ${dist_secret[@]+"${dist_secret[@]}"} \
      ${sign_store[@]+"${sign_store[@]}"} -e XLESS_BUILD_NUMBER \
      "$image" xless ship --platform ios "$@"
  else
    cd "$PROJECT"
    run "$xself" ship --platform ios "$@"
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
    ov_hash="$(sha_hex "$OVERLAY" | cut -c1-8)"
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
  # (the list is xless's SecretEnvironment.entries; a test keeps them equal), and with the secret store closed to it
  scrub=(env); for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 XLESS_DIST_KEY XLESS_DEVID_KEY XLESS_INSTALLER_KEY XLESS_DEMO_PASSWORD; do scrub+=(-u "$v" -u "${v}_FILE"); done
  for v in ${demo_names[@]+"${demo_names[@]}"}; do scrub+=(-u "$v" -u "${v}_FILE"); done   # a passwordSecret of the user's own
  scrub+=(XLESS_NO_SECRET_STORE=1)
fi
bn=(); [[ -z "${XLESS_BUILD_NUMBER:-}" ]] || bn=(-e XLESS_BUILD_NUMBER)
if [[ $use_docker == 1 ]]; then
  [[ -n "${XLESS_IMAGE:-}" ]] || apply_pin image
  # A simulator build runs step 2 only: the App Store Connect image is never used, so it is neither selected nor required.
  if [[ $RN == 1 && $SIM == 0 ]]; then [[ -n "${XLESS_SIGN_IMAGE:-}" ]] || apply_pin key_image; elif [[ $RN == 0 ]]; then key_image="$image"; fi
  if [[ $RN == 1 && $SIM == 0 ]]; then check_pin "build $image, App Store Connect steps $key_image"; else check_pin "$image"; fi
  if [[ $RN == 1 && $SIM == 0 ]]; then need_images "$image" "$key_image"; else need_images "$image"; fi
fi

# The work copy all three steps share: the overlay's name under xless's work root (the cache's, in docker), or the
# React Native build's work volume.
work_dir() {   # ROOT NAME: ROOT/NAME, ROOT with its symlinks resolved (and created, as xless would: one spelling only)
  [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]] || mkdir -p "$1" || die "cannot create the work root $1"
  if [[ -d "$1" ]]; then printf '%s/%s' "$(cd -P "$1" && pwd -P)" "$2"; else printf '%s/%s' "$1" "$2"; fi
}
wc_name="$(basename "$OVERLAY")"; wc_name="${wc_name%.*}"
if [[ $use_docker == 0 ]]; then
  wc_root="${XLESS_WORK_ROOT:-$HOME/.cache/xless/work}"
  case "$wc_root" in "~") wc_root="$HOME" ;; "~/"*) wc_root="$HOME/${wc_root#\~/}" ;; esac
  wc_key="$(work_dir "$wc_root" "$wc_name")"
elif [[ $RN == 1 ]]; then wc_key="docker volume $rn_work"
else wc_key="$(work_dir "$cache/work" "$wc_name")"; fi
hold_work_copy "$wc_key"

# React Native: step 2 (xless-rn) and steps 1 and 3 (xless-base) must run the same xless, or step 3 could misread what
# step 2 wrote. The images are compared by the digest of their xless binary (not for a simulator build: step 2 only).
if [[ $use_docker == 1 && $RN == 1 && $SIM == 0 && "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]]; then
  digest() { "${docker_run[@]}" --entrypoint sha256sum "$1" /usr/local/bin/xless 2>/dev/null | cut -c1-64; }
  d2="$(digest "$image")" || true; d13="$(digest "$key_image")" || true
  [[ -n "$d2" ]] || die "cannot read xless from $image (is the image built? xless setup --docker --xcode <Xcode.xip>)"
  [[ -n "$d13" ]] || die "cannot read xless from $key_image (is the image built? xless setup --docker --xcode <Xcode.xip>)"
  [[ "$d2" == "$d13" ]] || die "$image and $key_image hold different xless builds (${d2:0:12} vs ${d13:0:12}); rebuild both from the same commit (xless setup --docker --xcode <Xcode.xip>), or set XLESS_IMAGE / XLESS_SIGN_IMAGE to matching images"
fi

# The store's secrets for steps 1 and 3, now that nothing else can stop the run before step 1 (docker only).
if [[ $use_docker == 1 ]]; then
  build_mounts=("$overlay_dir" "$source_dir" ${input_paths[@]+"${input_paths[@]}"})
  [[ $RN == 1 ]] || build_mounts+=("$cache/work" "$cache/downloads" "$cache/inputs")
fi
materialise

# Step 1: the build number, only for a run that starts (later stages read the one recorded in the work copy).
if [[ $step1 == 1 ]]; then
  echo "==> TestFlight: step 1/3, next build number (App Store Connect, read-only)" >&2
  if [[ $use_docker == 1 ]]; then cmd=("${docker_run[@]}" "${app[@]}" ${asc_secrets[@]+"${asc_secrets[@]}"} ${next_store[@]+"${next_store[@]}"} "$key_image" "${next_build[@]}" "${xl[@]}")
  else cmd=("$xself" "${next_build[@]:1}" "${xl[@]}"); fi
  if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then
    run "${cmd[@]}"; XLESS_BUILD_NUMBER="<next-build>"
  else
    # waited, not "$(…)": a command substitution would hold a stop until the step ends, as a foreground command does
    outf="$(mktemp)"; tmpfiles+=("$outf")
    set +e; waited "${cmd[@]}" >"$outf"; code=$?; set -e
    drop_secrets next   # step 1's copy of the key: done with
    out="$(cat "$outf")"
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
  if [[ $SIM == 1 && "${XLESS_TESTFLIGHT_DRY_RUN:-0}" != 1 ]]; then log2="$(mktemp)"; tmpfiles+=("$log2"); fi
  step2() {
    if [[ $use_docker == 1 ]]; then
      run "${docker_run[@]}" "${app[@]}" "${build_caches[@]}" -e "XLESS_SOURCE_ORIGIN=$SOURCE" ${bn[@]+"${bn[@]}"} \
        "$image" xless ship --platform "$PLATFORM" "${xl[@]}" ${dest[@]+"${dest[@]}"} --from "$from" --to "$bto" ${extra[@]+"${extra[@]}"}
    else
      run "${scrub[@]}" "$xself" ship --platform "$PLATFORM" "${xl[@]}" ${dest[@]+"${dest[@]}"} --from "$from" --to "$bto" ${extra[@]+"${extra[@]}"}
    fi
  }
  set +e
  if [[ $SIM == 1 ]]; then waited_tee "$log2" step2; code=$?; else step2; code=$?; fi
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
    # flat package (installer-signed) that App Store Connect receives and TestFlight delivers.
    # A failure in either channel stops the run with that channel's code; the DMG's work does
    # not depend on the second ship.
    mac_tf_to="package"; [[ "$(index "$to")" -ge 6 ]] || mac_tf_to="$to"
    if [[ $use_docker == 1 ]]; then
      if [[ "${XLESS_TESTFLIGHT_DRY_RUN:-0}" == 1 ]]; then
        run "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" ${asc_secrets[@]+"${asc_secrets[@]}"} ${dist_secret[@]+"${dist_secret[@]}"} ${sign_store[@]+"${sign_store[@]}"} ${bn[@]+"${bn[@]}"} \
          "$key_image" xless ship --platform macos "${xl[@]}" --from "$sfrom" --to "$mac_tf_to" ${extra[@]+"${extra[@]}"}
        if [[ "$(index "$to")" -ge 6 ]]; then
          run "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" ${asc_secrets[@]+"${asc_secrets[@]}"} ${appstore_secret[@]+"${appstore_secret[@]}"} ${appstore_store[@]+"${appstore_store[@]}"} ${bn[@]+"${bn[@]}"} \
            "$key_image" xless ship --platform macos "${xl[@]}" --distribution app-store --from sign --to upload ${extra[@]+"${extra[@]}"}
        fi
        echo "==> TestFlight: stopped after $to (--to), nothing delivered" >&2
        exit 0
      fi
      log="$(mktemp)"; tmpfiles+=("$log")
      set +e
      waited_tee "$log" "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" ${asc_secrets[@]+"${asc_secrets[@]}"} ${dist_secret[@]+"${dist_secret[@]}"} ${sign_store[@]+"${sign_store[@]}"} ${bn[@]+"${bn[@]}"} \
        "$key_image" xless ship --platform macos "${xl[@]}" --from "$sfrom" --to "$mac_tf_to" ${extra[@]+"${extra[@]}"}
      code=$?
      [[ $code -eq 0 ]] || { set -e; echo "==> xless exited with code $code" >&2; exit "$code"; }
      drop_secrets sign
      dmg="$(grep '\.dmg$' "$log" | tail -1 || true)"
      [[ $use_docker == 0 ]] || dmg="${dmg/#\/cache\/work/$cache/work}"
      echo "==> DMG: $dmg" >&2
      if [[ "$(index "$to")" -ge 6 ]]; then
        waited_tee "$log" "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" ${asc_secrets[@]+"${asc_secrets[@]}"} ${appstore_secret[@]+"${appstore_secret[@]}"} ${appstore_store[@]+"${appstore_store[@]}"} ${bn[@]+"${bn[@]}"} \
          "$key_image" xless ship --platform macos "${xl[@]}" --distribution app-store --from sign --to upload ${extra[@]+"${extra[@]}"}
        code=$?
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
    shiplog="$(mktemp)"; shipout="$(mktemp)"; tmpfiles+=("$shiplog" "$shipout")
    waited "$xself" ship --platform macos "${xl[@]}" --from "$sfrom" --to "$mac_tf_to" ${extra[@]+"${extra[@]}"} >"$shipout" 2>"$shiplog"
    code=$?
    [[ $code -eq 0 ]] || { set -e; cat "$shiplog" >&2; echo "==> xless exited with code $code" >&2; exit "$code"; }
    dmg="$(grep '\.dmg$' "$shipout" | tail -1 || true)"
    echo "==> DMG: $dmg" >&2
    echo "==> DMG build finished" >&2
    if [[ "$(index "$to")" -ge 6 ]]; then
      : > "$shiplog"
      waited "$xself" ship --platform macos "${xl[@]}" --distribution app-store --from sign --to upload ${extra[@]+"${extra[@]}"} >"$shipout" 2>"$shiplog"
      code=$?
      [[ $code -eq 0 ]] || { set -e; cat "$shiplog" >&2; echo "==> xless exited with code $code (the TestFlight upload)" >&2; exit "$code"; }
      pkg="$(grep '\.pkg$' "$shipout" | tail -1 || true)"
      echo "==> PKG: $pkg" >&2
    fi
    set -e
    exit 0
  fi
  set +e
  if [[ $use_docker == 1 ]]; then
    run "${docker_run[@]}" "${app[@]}" "${sign_caches[@]}" ${asc_secrets[@]+"${asc_secrets[@]}"} ${dist_secret[@]+"${dist_secret[@]}"} ${sign_store[@]+"${sign_store[@]}"} ${bn[@]+"${bn[@]}"} \
      "$key_image" xless ship --platform "$PLATFORM" "${xl[@]}" --from "$sfrom" --to "$to" ${extra[@]+"${extra[@]}"}
  else
    run "$xself" ship --platform "$PLATFORM" "${xl[@]}" --from "$sfrom" --to "$to" ${extra[@]+"${extra[@]}"}
  fi
  code=$?
  set -e
  finish $code
fi
echo "==> TestFlight: stopped after $to (--to), nothing delivered" >&2
exit 0
