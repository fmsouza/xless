#!/usr/bin/env bash
# scripts/package-release.sh, scripts/stamp-version.sh and scripts/third-party-licenses.sh: the tarball holds exactly the
# documented layout (built from a stub binary; stripping is replaced by `true`), stamped with the version, and the
# third-party licences cover every package in Package.resolved plus the Swift runtime and musl.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

printf '#!/bin/sh\necho stub\n' > "$t/xless"; chmod +x "$t/xless"
mkdir -p "$t/out"
# A checkouts directory with a LICENSE for every package, so the test does not depend on a prior `swift build`.
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do
  mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"
done
mv "$t/checkouts/yams" "$t/checkouts/Yams"   # SwiftPM keeps the manifest's case for some checkouts
export XLESS_CHECKOUTS="$t/checkouts" XLESS_STRIP=true

bash "$repo/scripts/package-release.sh" 1.2.3 x86_64 "$t/xless" "$t/out" >/dev/null
tb="$t/out/xless-1.2.3-linux-x86_64.tar.gz"
[[ -f "$tb" ]] || fail "no $tb"
top=xless-1.2.3-linux-x86_64
tar -tzf "$tb" | sed 's#/$##' | sort > "$t/list"

# Nothing outside the documented layout.
bad=$(grep -vE "^$top(/(bin(/xless)?|LICENSE|share(/xless(/(VERSION|versions\.env|docker(/.*)?|scripts(/(docker-images|xcode-swift|testflight|native-toolchain)\.sh)?|samples(/HelloShip(/.*)?)?|licenses(/.*)?))?)?))?$" "$t/list" || true)
[[ -z "$bad" ]] || fail "unexpected entries: $bad"
for p in bin/xless LICENSE share/xless/VERSION share/xless/versions.env share/xless/docker/Dockerfile.base \
         share/xless/docker/toolchain/target-os/17C52.txt share/xless/scripts/docker-images.sh \
         share/xless/scripts/xcode-swift.sh share/xless/scripts/testflight.sh share/xless/scripts/native-toolchain.sh share/xless/samples/HelloShip/Package.swift; do
  grep -qx "$top/$p" "$t/list" || fail "missing $p"
done

# Tracked files only: the sample's ignored build output never ships.
grep -qE '/(\.xless|xtool|\.build|\.bsp)(/|$)' "$t/list" && fail "ignored files in the tarball"
git -c "safe.directory=$repo" -C "$repo" ls-files docker | while IFS= read -r f; do
  grep -qx "$top/share/xless/$f" "$t/list" || { echo "FAIL: docker file $f missing"; exit 1; }
done
untracked=$(git -c "safe.directory=$repo" -C "$repo" ls-files --others --ignored --exclude-standard samples/HelloShip | sed -n 1p)
[[ -z "$untracked" ]] || ! grep -qx "$top/share/xless/$untracked" "$t/list" || fail "ignored $untracked shipped"

x="$t/x"; mkdir -p "$x"; tar -xzf "$tb" -C "$x"
[[ "$(cat "$x/$top/share/xless/VERSION")" == "1.2.3" ]] || fail "VERSION is not 1.2.3"
[[ -x "$x/$top/bin/xless" ]] || fail "bin/xless is not executable"
diff -q "$repo/LICENSE" "$x/$top/LICENSE" >/dev/null || fail "LICENSE differs"
diff -q "$repo/versions.env" "$x/$top/share/xless/versions.env" >/dev/null || fail "versions.env differs"
for id in swift-crypto yams swift-argument-parser swift-asn1 swift-certificates swift-png h; do
  ls "$x/$top/share/xless/licenses/" | grep -q "^$id" || fail "no licence file for $id"
done
for id in swift-LICENSE musl-COPYRIGHT curl-COPYING libxml2 zlib icu-LICENSE boringssl swift-foundation-icu assetkit lzfse; do ls "$x/$top/share/xless/licenses/" | grep -q "^$id" || fail "no notice for $id"; done

# SHA256SUMS lists the tarball in sha256sum's format, and a second arch adds a line instead of replacing it.
bash "$repo/scripts/package-release.sh" 1.2.3 arm64 "$t/xless" "$t/out" >/dev/null
[[ "$(wc -l < "$t/out/SHA256SUMS" | tr -d ' ')" == 2 ]] || fail "SHA256SUMS should have two lines"
grep -qE '^[0-9a-f]{64}  xless-1\.2\.3-linux-arm64\.tar\.gz$' "$t/out/SHA256SUMS" || fail "SHA256SUMS format"
(cd "$t/out" && if command -v sha256sum >/dev/null; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi) >/dev/null || fail "SHA256SUMS does not verify"

# Bad arguments.
bash "$repo/scripts/package-release.sh" 1.2.3 riscv64 "$t/xless" "$t/out" >/dev/null 2>&1 && fail "riscv64 accepted"
bash "$repo/scripts/package-release.sh" 1.2 x86_64 "$t/xless" "$t/out" >/dev/null 2>&1 && fail "1.2 accepted"

# stamp-version.sh rewrites a copy of the two files and rejects anything but x.y.z.
s="$t/stamp"; mkdir -p "$s/Sources/XlessCore" "$s/scripts"
cp "$repo/scripts/stamp-version.sh" "$s/scripts/"; cp "$repo/versions.env" "$s/"; cp "$repo/Sources/XlessCore/Version.swift" "$s/Sources/XlessCore/"
bash "$s/scripts/stamp-version.sh" 0.1.0 >/dev/null
grep -q 'current = "0.1.0"' "$s/Sources/XlessCore/Version.swift" || fail "Version.swift not stamped"
grep -q 'development = "0.0.0-dev"' "$s/Sources/XlessCore/Version.swift" || fail "the stamp changed XlessVersion.development"
grep -q '^XLESS_VERSION=0.1.0$' "$s/versions.env" || fail "versions.env not stamped"
for v in 1.2 v1.2.3 1.2.3-rc1 "" abc; do
  bash "$s/scripts/stamp-version.sh" "$v" >/dev/null 2>&1 && fail "stamp accepted '$v'"
done
grep -q 'current = "0.1.0"' "$s/Sources/XlessCore/Version.swift" || fail "a rejected stamp changed Version.swift"
echo "package-release.test.sh: OK"
