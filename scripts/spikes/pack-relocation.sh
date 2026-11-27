#!/usr/bin/env bash
# SPIKE (xcode packs, Task 1): can an installed Darwin SDK be moved to another directory and used from a read-only mount?
# Kept as executable documentation of the measurement. It is not part of xless and is not run by CI. Findings:
# docs/research/xcode-pack-relocation.md.
#
#   scripts/spikes/pack-relocation.sh <export dir, holding <arch>/darwin.xtoolsdk> <arch: arm64|amd64>
#
# On the host it re-runs itself in a privileged container of the setup image (xless:local-<arch>-setup, from
# `scripts/docker-images.sh tools --arch <arch>`); inside, as root:
#   (a) installs the export with `xtool sdk install` under XDG_CONFIG_HOME=/tmp/p1/config and lists every file and every
#       symlink that holds the absolute path /tmp/p1;
#   (b) moves the tree to /tmp/p2, remounts it read-only (mount --bind -o ro), and builds a Swift-only sample for iOS twice:
#       run X with XDG_CONFIG_HOME=/tmp/p2/config, run S with --swift-sdks-path /tmp/p2/config/swiftpm/swift-sdks and the
#       user's own (empty, writable) XDG_CONFIG_HOME;
#   (c) prints what each run tried to write under /tmp/p2 (strace -f of openat/mkdir/... with write flags, and the result).
# Env: SPIKE_SAMPLE  the sample directory under the repo's samples/ (default HelloShip, a plain Swift package)
#      SPIKE_OUT     where the raw logs go on the host (default: a new temp directory; printed)
set -euo pipefail

if [ -z "${SPIKE_INSIDE:-}" ]; then
  [ $# -eq 2 ] || { echo "usage: $0 <export dir> <arch: arm64|amd64>" >&2; exit 2; }
  EXPORT=$(cd "$1" && pwd); ARCH=$2
  [ -f "$EXPORT/$ARCH/darwin.xtoolsdk/toolset-swb.json" ] || [ -d "$EXPORT/$ARCH/darwin.xtoolsdk" ] || { echo "no $EXPORT/$ARCH/darwin.xtoolsdk" >&2; exit 2; }
  REPO=$(cd "$(dirname "$0")/../.." && pwd)
  OUT=${SPIKE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/pack-relocation.XXXXXX")}; mkdir -p "$OUT"
  echo "raw logs: $OUT"
  exec docker run --rm --privileged --pull=never --platform "linux/$ARCH" -e SPIKE_INSIDE=1 -e ARCH="$ARCH" \
    -e SPIKE_SAMPLE="${SPIKE_SAMPLE:-HelloShip}" \
    -v "$EXPORT/$ARCH":/export:ro -v "$REPO/samples":/samples:ro -v "$REPO/scripts/spikes/pack-relocation.sh":/spike.sh:ro \
    -v "$OUT":/out "xless:local-$ARCH-setup" bash /spike.sh
fi

# ---- inside the container ----
export HOME=/root
command -v strace >/dev/null || { apt-get update -qq >/dev/null && apt-get install -y -qq strace >/dev/null; }
WRITE='O_WRONLY|O_RDWR|O_CREAT|O_TRUNC'
ROOT=/tmp/p2
filter_writes() { # strace log -> the calls that write under $ROOT
  grep -E "$ROOT" "$1" | grep -E "($WRITE)|mkdir|rename|unlink|symlink|chmod|utimens|truncate" || true; }
sec() { printf '\n==== %s ====\n' "$*"; }

sec "install under XDG_CONFIG_HOME=/tmp/p1/config"
mkdir -p /tmp/p1/config
ls -la /export
XDG_CONFIG_HOME=/tmp/p1/config strace -f -o /out/install.strace -e trace=openat,mkdir,mkdirat,rename,symlink,symlinkat,unlink,unlinkat \
  xtool sdk install /export/darwin.xtoolsdk 2>&1 | tail -5
echo "xtool wrote outside /tmp/p1 (write-flag opens, mkdirs):"
grep -E "($WRITE)|mkdir" /out/install.strace | grep -vE '"/(tmp/p1|proc|dev)|ENOENT|EEXIST' | grep -E '"/' | sed -E 's/^[0-9]+ +//' | sort -u | head -20 || true
du -sh /tmp/p1; ( cd /tmp/p1/config && find . -maxdepth 4 -type d | sort | head -30 )

sec "(a) files holding /tmp/p1, symlinks whose target is absolute"
echo "-- grep -rIl /tmp/p1 /tmp/p1/config"
grep -rIl /tmp/p1 /tmp/p1/config || echo "(none)"
echo "-- binary files holding it (grep -rl, not -I)"
{ grep -rl /tmp/p1 /tmp/p1/config || true; } | sort > /tmp/all.txt; { grep -rIl /tmp/p1 /tmp/p1/config || true; } | sort > /tmp/txt.txt
comm -23 /tmp/all.txt /tmp/txt.txt | grep . || echo "(none)"
echo "-- find -type l -lname '/*'"
find /tmp/p1/config -type l -lname '/*' -printf '%p -> %l\n' > /tmp/abslinks.txt; head -40 /tmp/abslinks.txt
echo "absolute symlinks: $(wc -l </tmp/abslinks.txt); of them into /tmp/p1: $(grep -c -- '-> /tmp/p1' /tmp/abslinks.txt || true)"
echo "-- every line holding /tmp/p1, per file"
{ grep -rIn /tmp/p1 /tmp/p1/config || true; } | cut -c1-240 | head -40
echo "-- any absolute path in the JSON metadata of the bundle (not /tmp/p1)"
grep -rIhoE '"(/[A-Za-z0-9_./-]+)"' /tmp/p1/config --include='*.json' | sort | uniq -c | sort -rn | head -10 || true

# The command line xless itself uses (Sources/XlessBuild/MacBuilder.swift, Sources/XlessXcode/SwiftBuildEnvironment.swift): Swift Build,
# the SDK's toolset-swb.json, and XCODE_EXTRA_PLATFORM_FOLDERS naming the bundle's Developer/Platforms (without it: "unable to find
# platform for 'iphoneos'").
build() { # name, env XDG, extra args
  local name=$1 xdg=$2; shift 2
  TOOLSET=$ROOT_SDKS/swift-sdks/darwin.artifactbundle/toolset-swb.json
  rm -rf /tmp/w-$name; mkdir -p /tmp/w-$name; cp -R "/samples/$SPIKE_SAMPLE/." /tmp/w-$name/
  sec "(b) build $name: XDG_CONFIG_HOME=$xdg $*"
  # cache and scratch are given a writable home of their own, so that what lands under /tmp/p2 is the SDK's doing
  ( cd /tmp/w-$name && env -u SDKROOT XCODE_EXTRA_PLATFORM_FOLDERS="$ROOT_SDKS/swift-sdks/darwin.artifactbundle/Developer/Platforms" XDG_CONFIG_HOME=$xdg XDG_CACHE_HOME=/tmp/cache-$name HOME=/tmp/home-$name \
      strace -f -o /out/build-$name.strace -e trace=openat,mkdir,mkdirat,rename,renameat,renameat2,symlink,symlinkat,unlink,unlinkat,chmod,fchmodat,utimensat,truncate \
      swift build --swift-sdk "$SDKID" --build-system swiftbuild --toolset "$TOOLSET" --scratch-path /tmp/w-$name/.build "$@" ) > /out/build-$name.log 2>&1 && echo "RESULT $name: BUILD OK" || echo "RESULT $name: BUILD FAILED (exit $?)"
  tail -25 /out/build-$name.log
  sec "(c) writes under $ROOT attempted by run $name"
  filter_writes /out/build-$name.strace | sed -E 's/^[0-9]+ +//' | cut -c1-220 | sort | uniq -c | sort -rn | head -30
  echo "(count of such calls: $(filter_writes /out/build-$name.strace | wc -l); of them failing with EROFS: $(filter_writes /out/build-$name.strace | grep -c EROFS || true))"
  echo "reads of /tmp/p1 attempted (the old location): $(grep -c '/tmp/p1' /out/build-$name.strace || true)"
  grep '/tmp/p1' /out/build-$name.strace | sed -E 's/^[0-9]+ +//' | cut -c1-200 | sort -u | head -10
  echo "other writes outside /tmp/w-$name, /tmp/cache-$name, /tmp/home-$name (name of the tool, path):"
  grep -E "($WRITE)|mkdir" /out/build-$name.strace | grep -vE "\"/(tmp/(w-$name|cache-$name|home-$name)|proc|dev)" | grep -vE 'ENOENT|EEXIST' | grep -E '"/' | sed -E 's/^[0-9]+ +//' | cut -c1-200 | sort -u | head -15
}
SDKID=arm64-apple-ios   # the target triple; `swift sdk list` names the bundle "darwin", which has several triples
sec "control: the same build where it was installed (/tmp/p1, writable, not moved)"
ROOT=/tmp/p1; ROOT_SDKS=/tmp/p1/config/swiftpm
build C /tmp/p1/config || true
ROOT=/tmp/p2; ROOT_SDKS=/tmp/p2/config/swiftpm

sec "move to /tmp/p2, remount read-only"
mv /tmp/p1 /tmp/p2
mount --bind /tmp/p2 /tmp/p2 && mount -o remount,bind,ro /tmp/p2
touch /tmp/p2/probe 2>&1 | head -1 || true
grep ' /tmp/p2 ' /proc/mounts
echo "after the move, files still holding /tmp/p1: $(grep -rIl /tmp/p1 /tmp/p2/config | wc -l); dangling absolute symlinks: $(find /tmp/p2/config -xtype l | wc -l)"
find /tmp/p2/config -xtype l -printf 'dangling: %p -> %l\n' | head -10

SDKS=/tmp/p2/config/swiftpm/swift-sdks
echo "-- swift sdk list (XDG_CONFIG_HOME=/tmp/p2/config)"
XDG_CONFIG_HOME=/tmp/p2/config swift sdk list 2>&1 | head
echo "-- swift sdk list (--swift-sdks-path)"
mkdir -p /tmp/userxdg; XDG_CONFIG_HOME=/tmp/userxdg swift sdk list --swift-sdks-path "$SDKS" 2>&1 | head
touch /tmp/marker

build X /tmp/p2/config || true
build S /tmp/userxdg --swift-sdks-path "$SDKS" || true

sec "tree under /tmp/p2 unchanged?"
echo "(entries in /tmp/p2 modified since the mount: $(find /tmp/p2 -newer /tmp/marker | wc -l))"
umount /tmp/p2
