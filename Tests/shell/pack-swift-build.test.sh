#!/usr/bin/env bash
# scripts/pack-swift-build.sh <pack> <arch> own|separate with fake curl, swift and strip: the eight source archives are
# fetched from their tags and each is checked against its pin (a wrong one stops it before anything is compiled, and
# nothing is in <pack>/swift-build), both products are built with the pack's toolchain first on PATH, local dependencies
# and a relative rpath to the pack's Swift runtime, `--strip-debug` is passed for `separate` only, and <pack>/swift-build
# gets the executables, the resource bundles, LICENSE.txt and SOURCE, with no absolute path of the pack in them.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
case "$(uname -m)" in aarch64|arm64) arch=arm64 other=amd64 ;; *) arch=amd64 other=arm64 ;; esac
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
command -v sha256sum >/dev/null || { echo "SKIP: needs sha256sum"; exit 0; }

# The archives, as GitHub serves them: one top directory. swift-build's has its LICENSE.txt.
mkdir -p "$t/archives" "$t/fakes"
for repo_name in swift-build swift-driver swift-llbuild swift-tools-support-core swift-tools-protocols swift-argument-parser \
                 swift-system swift-toolchain-sqlite; do
  mkdir -p "$t/src/$repo_name-x"
  echo "$repo_name" > "$t/src/$repo_name-x/README"
  [[ $repo_name != swift-build ]] || echo "Apache License" > "$t/src/$repo_name-x/LICENSE.txt"
  tar -czf "$t/archives/$repo_name.tar.gz" -C "$t/src" "$repo_name-x"
done
pins() {
  export SWB_TAG=swift-6.4.0-RELEASE SWB_ARGUMENT_PARSER_VERSION=1.6.1 SWB_SYSTEM_VERSION=1.5.0 SWB_SQLITE_VERSION=1.0.9
  SWB_SHA256=$(sum "$t/archives/swift-build.tar.gz"); SWB_DRIVER_SHA256=$(sum "$t/archives/swift-driver.tar.gz")
  SWB_LLBUILD_SHA256=$(sum "$t/archives/swift-llbuild.tar.gz"); SWB_TSC_SHA256=$(sum "$t/archives/swift-tools-support-core.tar.gz")
  SWB_TOOLS_PROTOCOLS_SHA256=$(sum "$t/archives/swift-tools-protocols.tar.gz")
  SWB_ARGUMENT_PARSER_SHA256=$(sum "$t/archives/swift-argument-parser.tar.gz"); SWB_SYSTEM_SHA256=$(sum "$t/archives/swift-system.tar.gz")
  SWB_SQLITE_SHA256=$(sum "$t/archives/swift-toolchain-sqlite.tar.gz")
  export SWB_SHA256 SWB_DRIVER_SHA256 SWB_LLBUILD_SHA256 SWB_TSC_SHA256 SWB_TOOLS_PROTOCOLS_SHA256 SWB_ARGUMENT_PARSER_SHA256 SWB_SYSTEM_SHA256 SWB_SQLITE_SHA256
}

# curl -fsSL -o <file> https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz: that repo's archive.
cat > "$t/fakes/curl" <<'EOF'
#!/bin/sh
out=; while [ $# -gt 1 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
echo "curl $1" >> "$FAKE_LOG"
cp "$FAKE_ARCHIVES/$(echo "$1" | cut -d/ -f5).tar.gz" "$out"
EOF
# strip [--strip-debug] -o <out> <in>
cat > "$t/fakes/strip" <<'EOF'
#!/bin/sh
echo "strip $*" >> "$FAKE_LOG"
if [ -n "${FAKE_SLEEP:-}" ]; then touch "$FAKE_SLEEP"; sleep 2; fi
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; -*) ;; *) in=$1 ;; esac; shift; done
cp "$in" "$out"
EOF
chmod +x "$t/fakes/curl" "$t/fakes/strip"

pack="$t/xcodes/26.2-17C52-$arch.partial"
mkpack() {   # a pack whose toolchain has a fake swift: it builds where the dependencies are siblings and local
  rm -rf "$t/xcodes"; mkdir -p "$pack/toolchain/usr/bin"
  cat > "$pack/toolchain/usr/bin/swift" <<'EOF'
#!/bin/sh
echo "swift $*" >> "$FAKE_LOG"
[ "$1" = --version ] && { echo "Swift version 6.2.3 (swift-6.2.3-RELEASE)"; exit 0; }
[ "${SWIFTCI_USE_LOCAL_DEPS:-}" = 1 ] || { echo "not with local dependencies" >&2; exit 1; }
for d in swift-driver llbuild swift-tools-support-core swift-tools-protocols swift-argument-parser swift-system swift-toolchain-sqlite; do
  [ -f "../$d/README" ] || { echo "no ../$d" >&2; exit 1; }
done
bin="$PWD/.build/release"
case " $* " in *" --show-bin-path "*) echo "$bin"; exit 0 ;; esac
product=; while [ $# -gt 0 ]; do [ "$1" = --product ] && product=$2; shift; done
mkdir -p "$bin/SwiftBuild_SWBCore.resources" "$bin/SwiftBuild_SWBUniversalPlatform.resources"
echo "spec" > "$bin/SwiftBuild_SWBCore.resources/Core.xcspec"
echo "binary $product ${FAKE_EMBED:-}" > "$bin/$product"
EOF
  chmod +x "$pack/toolchain/usr/bin/swift"
}
run() {   # $1: mode; the rest: env assignments
  local mode=$1; shift
  : > "$t/log"
  env "$@" PATH="$t/fakes:$PATH" FAKE_LOG="$t/log" FAKE_ARCHIVES="$t/archives" \
    sh "$repo/scripts/pack-swift-build.sh" "$pack" "$arch" "$mode" > "$t/out" 2>&1
}

# separate: --strip-debug, the products and the bundles, LICENSE.txt and SOURCE.
pins; mkpack
run separate || fail "separate: $(cat "$t/out")"
s="$pack/swift-build"
for f in swbuild SWBBuildServiceBundle SwiftBuild_SWBCore.resources/Core.xcspec LICENSE.txt SOURCE; do [[ -f "$s/$f" ]] || fail "no swift-build/$f: $(ls -R "$s")"; done
[[ -d "$s/SwiftBuild_SWBUniversalPlatform.resources" ]] || fail "a resource bundle is missing"
[[ "$(cat "$s/swbuild")" == "binary swbuild " ]] || fail "swbuild: $(cat "$s/swbuild")"
[[ "$(cat "$s/LICENSE.txt")" == "Apache License" ]] || fail "LICENSE.txt"
[[ "$(cat "$s/SOURCE")" == "https://github.com/swiftlang/swift-build/tree/swift-6.4.0-RELEASE" ]] || fail "SOURCE: $(cat "$s/SOURCE")"
[[ "$(grep -c '^strip --strip-debug -o ' "$t/log")" == 2 ]] || fail "separate is not stripped of debug information only: $(grep strip "$t/log")"
# The eight archives, from their tags.
for u in swiftlang/swift-build/archive/refs/tags/swift-6.4.0-RELEASE swiftlang/swift-driver/archive/refs/tags/swift-6.4.0-RELEASE \
         swiftlang/swift-llbuild/archive/refs/tags/swift-6.4.0-RELEASE swiftlang/swift-tools-support-core/archive/refs/tags/swift-6.4.0-RELEASE \
         swiftlang/swift-tools-protocols/archive/refs/tags/swift-6.4.0-RELEASE apple/swift-argument-parser/archive/refs/tags/1.6.1 \
         apple/swift-system/archive/refs/tags/1.5.0 swiftlang/swift-toolchain-sqlite/archive/refs/tags/1.0.9; do
  grep -qxF "curl https://github.com/$u.tar.gz" "$t/log" || fail "not fetched: $u"
done
# Both products, with the pack's toolchain (its fake swift ran) and the Swift runtime found from the executable's place.
for p in SWBBuildServiceBundle swbuild; do
  grep -qxF "swift build -c release --product $p -Xswiftc -no-toolchain-stdlib-rpath -Xlinker -rpath -Xlinker \$ORIGIN/../toolchain/usr/lib/swift/linux" "$t/log" \
    || fail "$p not built as expected: $(grep '^swift build' "$t/log")"
done
[[ -z "$(grep -rlF "$t" "$s" || true)" ]] || fail "swift-build names a place: $(grep -rlF "$t" "$s")"
[[ ! -e "$pack/swift-build.partial" ]] || fail "swift-build.partial left"

# own: a full strip; a second run replaces the part.
run own || fail "own: $(cat "$t/out")"
[[ "$(grep -c '^strip -o ' "$t/log")" == 2 && "$(grep -c -- '--strip-debug' "$t/log")" == 0 ]] || fail "own is not stripped fully: $(grep strip "$t/log")"
[[ -f "$pack/swift-build/swbuild" ]] || fail "own: no swbuild"

# Each archive is checked: a wrong sha256 stops it before anything is built, and nothing is in <pack>/swift-build.
for v in SWB_SHA256 SWB_SQLITE_SHA256; do
  mkpack
  run separate "$v=0000000000000000000000000000000000000000000000000000000000000000" && fail "a wrong $v was accepted"
  [[ ! -e "$pack/swift-build" && ! -e "$pack/swift-build.partial" ]] || fail "$v wrong: swift-build was written"
  grep -q '^swift build' "$t/log" && fail "$v wrong: swift built"
  grep -q 'sha256' "$t/out" || fail "$v wrong: the message does not say why: $(cat "$t/out")"
done

# A pin missing from the environment is named.
mkpack
run separate SWB_TSC_SHA256= && fail "a missing pin was accepted"
grep -q 'SWB_TSC_SHA256' "$t/out" || fail "the missing pin is not named: $(cat "$t/out")"
[[ ! -e "$pack/swift-build" ]] || fail "missing pin: swift-build was written"

# A product that names where the pack is prepared (an absolute rpath) is refused: the pack must be relocatable.
mkpack
run separate FAKE_EMBED="$pack/toolchain/usr/lib/swift/linux" && fail "an absolute path of the pack was accepted"
grep -q 'relocatable\|names' "$t/out" || fail "the message does not say why: $(cat "$t/out")"
[[ ! -e "$pack/swift-build" ]] || fail "absolute path: swift-build was written"

# grep failing (status 2: it could not read what it searched) is no clean answer: refused, nothing written.
mkpack
real_grep=$(command -v grep)
mkdir -p "$t/fake-grep"
printf '#!/bin/sh\necho "grep: cannot read" >&2\nexit 2\n' > "$t/fake-grep/grep"; chmod +x "$t/fake-grep/grep"
: > "$t/log"
env PATH="$t/fake-grep:$t/fakes:$PATH" FAKE_LOG="$t/log" FAKE_ARCHIVES="$t/archives" \
  sh "$repo/scripts/pack-swift-build.sh" "$pack" "$arch" separate > "$t/out" 2>&1 && fail "a failing grep was taken for a clean search"
"$real_grep" -q 'relocatable\|grep' "$t/out" || fail "the grep failure is not named: $(cat "$t/out")"
[[ ! -e "$pack/swift-build" ]] || fail "failing grep: swift-build was written"

# Stopped (TERM, INT) while it works: its temporary directory and <pack>/swift-build.partial are removed. Job control on,
# so the background run is a process group of its own and does not start with INT ignored (as a non-interactive shell's
# background jobs do); the signal goes to that group, as a terminal's ^C goes to the command and what it runs.
set -m
for sig in TERM INT; do
  mkpack
  rm -rf "$t/tmpdir" "$t/sleeping"; mkdir -p "$t/tmpdir"
  : > "$t/log"
  env PATH="$t/fakes:$PATH" FAKE_LOG="$t/log" FAKE_ARCHIVES="$t/archives" FAKE_SLEEP="$t/sleeping" TMPDIR="$t/tmpdir" \
    sh "$repo/scripts/pack-swift-build.sh" "$pack" "$arch" separate > "$t/out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [[ -e "$t/sleeping" ]] && break; sleep 0.1; done
  [[ -e "$t/sleeping" ]] || fail "$sig: the fake strip never ran: $(cat "$t/out")"
  kill -"$sig" -- -"$pid"
  wait "$pid" && fail "$sig: the script finished as if nothing happened"
  sleep 3   # an orphaned strip, had the script died without cleaning up, has written by now
  [[ ! -e "$pack/swift-build.partial" ]] || fail "$sig: swift-build.partial left: $(ls -R "$pack/swift-build.partial")"
  [[ -z "$(ls -A "$t/tmpdir")" ]] || fail "$sig: its temporary directory left: $(ls -A "$t/tmpdir")"
  [[ ! -e "$pack/swift-build" ]] || fail "$sig: swift-build was written"
done
set +m

# Swift Build is compiled on the architecture it is for; the mode is own or separate.
mkpack
: > "$t/log"
PATH="$t/fakes:$PATH" FAKE_LOG="$t/log" sh "$repo/scripts/pack-swift-build.sh" "$pack" "$other" separate > "$t/out" 2>&1 && fail "another arch was accepted"
grep -q "$other" "$t/out" || fail "arch message: $(cat "$t/out")"
run whatever && fail "a mode other than own or separate was accepted"
[[ ! -s "$t/log" ]] || fail "it started before its arguments were checked: $(cat "$t/log")"
echo "PASS pack-swift-build"
