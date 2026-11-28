#!/usr/bin/env bash
# scripts/package-release.sh, scripts/stamp-version.sh and scripts/third-party-licenses.sh: the tarball holds exactly the
# documented layout (built from a stub binary; stripping is replaced by `true`), stamped with the version, and the
# third-party licences cover every package in Package.resolved plus the Swift runtime and musl. The same for macOS, where the
# signing is replaced too. scripts/check-package.sh refuses anything else, scripts/check-macos-binary.sh a binary that is not
# a release's (with the real tools on macOS, with stand-ins for them elsewhere).
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
export XLESS_CHECKOUTS="$t/checkouts" XLESS_STRIP=true XLESS_CHECK_MAP=true XLESS_STUB=true   # a script in the place of the binary

bash "$repo/scripts/package-release.sh" 1.2.3 x86_64 "$t/xless" "$t/out" >/dev/null
tb="$t/out/xless-1.2.3-linux-x86_64.tar.gz"
[[ -f "$tb" ]] || fail "no $tb"
top=xless-1.2.3-linux-x86_64
tar -tzf "$tb" | sed 's#/$##' | sort > "$t/list"

# Nothing outside the documented layout.
bad=$(grep -vE "^$top(/(bin(/xless)?|LICENSE|share(/xless(/(VERSION|versions\.env|docker(/.*)?|scripts(/(docker-images|xcode-swift|testflight|fit-toolchain|pack-swift-build|pack-check)\.sh)?|credential-helpers(/xless-credential-(pass|secret-tool))?|samples(/HelloShip(/.*)?)?|licenses(/.*)?))?)?))?$" "$t/list" || true)
[[ -z "$bad" ]] || fail "unexpected entries: $bad"
for p in bin/xless LICENSE share/xless/VERSION share/xless/versions.env share/xless/docker/Dockerfile share/xless/docker/Dockerfile.dockerignore \
         share/xless/docker/tauri/Dockerfile share/xless/docker/react-native/Dockerfile \
         share/xless/docker/toolchain/target-os/17C52.txt share/xless/scripts/docker-images.sh \
         share/xless/scripts/xcode-swift.sh share/xless/scripts/testflight.sh share/xless/scripts/fit-toolchain.sh share/xless/scripts/pack-swift-build.sh share/xless/scripts/pack-check.sh share/xless/samples/HelloShip/Package.swift \
         share/xless/credential-helpers/xless-credential-pass share/xless/credential-helpers/xless-credential-secret-tool; do
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

# macOS: the same layout under its own name, without the notices of what is the system's there.
XLESS_CODESIGN=true XLESS_CHECK_BINARY=true bash "$repo/scripts/package-release.sh" --os macos 1.2.3 arm64 "$t/xless" "$t/out" >/dev/null 2>&1 || fail "no macOS package"
mac="$t/out/xless-1.2.3-macos-arm64.tar.gz" mactop=xless-1.2.3-macos-arm64
[[ "$(wc -l < "$t/out/SHA256SUMS" | tr -d ' ')" == 3 ]] || fail "SHA256SUMS should have three lines"
tar -tzf "$mac" > "$t/maclist"
diff <(tar -tzf "$tb" | sed "s#^$top##" | grep -v /licenses/ | sort) <(tar -tzf "$mac" | sed "s#^$mactop##" | grep -v /licenses/ | sort) || fail "the macOS package has another layout"
sed 's#/$##' "$t/maclist" | tr / '\001' | LC_ALL=C sort -c || fail "the names in the macOS package are not sorted"
grep -qE '(^|/)(\._[^/]*|\.DS_Store|__MACOSX|_CodeSignature)(/|$)' "$t/maclist" && fail "macOS metadata in the package"
for id in swift-LICENSE llvm-compiler-rt boringssl libyaml swift-crypto yams assetkit; do grep -q "/licenses/$id" "$t/maclist" || fail "no notice for $id on macOS"; done
for id in musl curl icu zlib libxml2 swift-corelibs; do grep -q "/licenses/$id" "$t/maclist" && fail "a notice for $id, which a macOS xless has not in it"; done
XLESS_CODESIGN=true XLESS_CHECK_BINARY=false bash "$repo/scripts/package-release.sh" --os macos 1.2.3 x86_64 "$t/xless" "$t/out" >/dev/null 2>&1 && fail "a binary that fails its check was packaged"
XLESS_CODESIGN=false XLESS_CHECK_BINARY=true bash "$repo/scripts/package-release.sh" --os macos 1.2.3 x86_64 "$t/xless" "$t/out" >/dev/null 2>&1 && fail "a binary that cannot be signed was packaged"
[[ ! -e "$t/out/xless-1.2.3-macos-x86_64.tar.gz" ]] || fail "a refused package is there"
bash "$repo/scripts/package-release.sh" --os windows 1.2.3 arm64 "$t/xless" "$t/out" >/dev/null 2>&1 && fail "windows accepted"

# The modes in a package are the same whatever the umask and the modes of what is copied.
for u in 000 077; do
  mkdir -p "$t/out$u"; (umask $u; bash "$repo/scripts/package-release.sh" 1.2.3 arm64 "$t/xless" "$t/out$u" >/dev/null) || fail "no package with umask $u"
  tar -tvzf "$t/out$u/xless-1.2.3-linux-arm64.tar.gz" | cut -c1-10 | sort -u > "$t/modes$u"
done
[[ "$(tr '\n' ' ' < "$t/modes000")" == "-rw-r--r-- -rwxr-xr-x drwxr-xr-x " ]] && cmp -s "$t/modes000" "$t/modes077" || fail "modes: $(cat "$t/modes000" "$t/modes077")"

# scripts/check-package.sh: anything more, less or of another kind is refused.
check() { bash "$repo/scripts/check-package.sh" linux 1.2.3 x86_64 "$1" 2>"$t/err"; }
# pack <dir>: as root's, whoever runs this
pack() {
  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then tar -czf "$2" --owner="${3:-0}" --group="${3:-0}" --numeric-owner -C "$1" "$top"
  else COPYFILE_DISABLE=1 tar -czf "$2" --uid "${3:-0}" --gid "${3:-0}" --numeric-owner --no-mac-metadata --no-xattrs --no-acls --no-fflags -C "$1" "$top"; fi
}
check "$tb" > "$t/files" || fail "a good package is refused: $(cat "$t/err")"
grep -qx "$top/bin/xless" "$t/files" || fail "check-package's list"
bad() {  # what it says, then a command that changes the unpacked package $b/$top
  local want="$1"; shift
  b="$t/bad"; rm -rf "$b"; mkdir -p "$b"; tar -xzf "$tb" -C "$b"
  (cd "$b/$top" && "$@")
  pack "$b" "$t/bad.tar.gz"
  check "$t/bad.tar.gz" >/dev/null && fail "accepted: $want ($*)"
  grep -qF "$want" "$t/err" || fail "refused for something else than '$want': $(cat "$t/err")"
}
cd / # the paths below are the package's
umask 022 # and so are the modes
bad "too much" touch bin/libswiftCore.dylib
bad "too much" touch share/xless/docker/.DS_Store
bad "too much" sh -c 'mkdir -p share/xless/SDKs && echo x > share/xless/SDKs/x.tbd'
bad "too much" touch share/xless/licenses/x.h
bad "empty directory" mkdir share/xless/empty
bad "missing" rm bin/xless
bad "missing" rm share/xless/docker/Dockerfile
bad "missing" rm share/xless/licenses/swift-LICENSE.txt
bad "too much" sh -c 'echo text > share/xless/licenses/other.txt'
bad "too much" sh -c 'echo text > share/xless/licenses/other.NOTICE.txt'
bad "is not the one of SOURCES.tsv" sh -c 'echo more >> share/xless/licenses/musl-COPYRIGHT.txt'
bad "differs from the checkout" sh -c 'echo more >> share/xless/licenses/assetkit.txt'
for f in docker/Dockerfile scripts/testflight.sh credential-helpers/xless-credential-pass samples/HelloShip/Package.swift; do
  bad "differs from the checkout" sh -c 'echo more >> "$0"' "share/xless/$f"
done
bad "differs from the checkout" sh -c 'echo MORE=1 >> share/xless/versions.env'
bad "differs from the checkout" sh -c 'echo more >> LICENSE'
for text in '\0' '\001\002' '\037\213\010\000gzip' 'BC\300\336' 'x\317\372\355\376' '\342\234\250\001\000'; do
  bad "is no text" sh -c 'printf "$0" > share/xless/licenses/swift-png.txt' "$text"
done
bad "is a text stub" sh -c 'printf -- "--- !tapi-tbd\ntbd-version: 4\n" > share/xless/licenses/swift-png.txt'
bad "is a text stub" sh -c 'printf "{\n \"tapi_tbd_version\": 5\n}\n" > share/xless/licenses/swift-png.txt'
bad "is empty" sh -c ': > share/xless/licenses/swift-png.txt'
bad "has the mode" chmod 644 bin/xless
bad "has the mode" chmod 755 LICENSE
bad "has the mode" chmod 644 share/xless/scripts/testflight.sh
bad "something else than files" ln -s xless bin/x
bad "something else than files" chmod 666 LICENSE
bad "executable code" sh -c 'printf "\317\372\355\376more" > share/xless/licenses/swift-png.txt'
bad "executable code" sh -c 'printf "\177ELF" > share/xless/licenses/swift-png.txt'
bad "executable code" sh -c 'printf "!<arch>\n" > share/xless/licenses/swift-png.txt'
bad "VERSION is not" sh -c 'echo 1.2.4 > share/xless/VERSION'
bash "$repo/scripts/check-package.sh" macos 1.2.3 x86_64 "$tb" >/dev/null 2>&1 && fail "a Linux package is taken for a macOS one"
bash "$repo/scripts/check-package.sh" linux 1.2.3 arm64 "$tb" >/dev/null 2>&1 && fail "an x86_64 package is taken for an arm64 one"
# Somebody else's files, and what tar can keep beside a file's contents.
rm -rf "$b"; mkdir "$b"; tar -xzf "$tb" -C "$b"
pack "$b" "$t/bad.tar.gz"; check "$t/bad.tar.gz" >/dev/null || fail "repacked, it is refused: $(cat "$t/err")"
pack "$b" "$t/bad.tar.gz" 501; check "$t/bad.tar.gz" >/dev/null && fail "accepted another owner"
grep -qF "another owner than root" "$t/err" || fail "owner: $(cat "$t/err")"
for key in SCHILY.xattr.com.apple.quarantine LIBARCHIVE.xattr.user.x SCHILY.acl.access SCHILY.fflags; do
  python3 -I - "$t/bad.tar.gz" "$b" "$top" "$key" <<'P'
import sys, tarfile
out, root, top, key = sys.argv[1:]
def own(i): i.uid = i.gid = 0; i.uname = i.gname = ""; i.pax_headers = {key: "v"} if i.name.endswith("/LICENSE") else {}; return i
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT) as f: f.add(root + "/" + top, top, filter=own)
P
  check "$t/bad.tar.gz" >/dev/null && fail "accepted $key"
  grep -qF "extended attributes" "$t/err" || fail "$key: $(cat "$t/err")"
done
# A real package's binary is a program of its system and architecture (no stub).
for head in '\177ELF\002\001\001\0\0\0\0\0\0\0\0\0\002\0\076\0' '\177ELF\002\001\001\0\0\0\0\0\0\0\0\0\003\0\076\0'; do
  printf "$head" > "$b/$top/bin/xless"; pack "$b" "$t/bad.tar.gz"; XLESS_STUB='' check "$t/bad.tar.gz" >/dev/null || fail "an x86_64 ELF is refused: $(cat "$t/err")"
done
for head in '#!/bin/sh' '\177ELF\002\001\001\0\0\0\0\0\0\0\0\0\002\0\267\0' '\317\372\355\376\007\0\0\001' '\312\376\272\276\0\0\0\002'; do
  printf "$head" > "$b/$top/bin/xless"; pack "$b" "$t/bad.tar.gz"; XLESS_STUB='' check "$t/bad.tar.gz" >/dev/null && fail "accepted as an x86_64 Linux program: $head"
  grep -qF "bin/xless is no program for linux x86_64" "$t/err" || fail "$head: $(cat "$t/err")"
done
echo no > "$t/bad.tar.gz"; check "$t/bad.tar.gz" >/dev/null && fail "accepted what is no tarball"
cd "$repo"

# scripts/check-macos-binary.sh, with stand-ins for otool, lipo and codesign that say what $t/mac holds.
mkdir -p "$t/mac" "$t/mactools"
printf '#!/bin/sh\ncat "%s/mac/archs"\n' "$t" > "$t/mactools/lipo"
printf '#!/bin/sh\ncase "$1" in -L) cat "%s/mac/libraries" ;; -l) cat "%s/mac/commands" ;; esac\n' "$t" "$t" > "$t/mactools/otool"
printf '#!/bin/sh\ncase "$*" in *--verify*) exit "$(cat "%s/mac/verify")" ;; *--entitlements*) cat "%s/mac/entitlements" ;; *) cat "%s/mac/signature" >&2 ;; esac\n' "$t" "$t" "$t" > "$t/mactools/codesign"
chmod +x "$t/mactools"/*
good() {
  echo arm64 > "$t/mac/archs"
  printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n\t/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit (compatibility version 1.0.0, current version 1.0.0)\n' "$t/xless" > "$t/mac/libraries"
  printf '          cmd LC_RPATH\n      cmdsize 32\n         path /usr/lib/swift (offset 12)\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform 1\n    minos 14.0\n      sdk 26.0\n' > "$t/mac/commands"
  printf 'CodeDirectory v=20500 size=1 flags=0x10802(adhoc,restrict,runtime) hashes=1+0 location=embedded\nSignature=adhoc\n' > "$t/mac/signature"
  echo 0 > "$t/mac/verify"; : > "$t/mac/entitlements"
}
macho() { PATH="$t/mactools:$PATH" bash "$repo/scripts/check-macos-binary.sh" "$t/xless" arm64 2>&1; }
good; macho >/dev/null || fail "a good binary is refused: $(macho)"
refused() { out=$(macho) && fail "accepted: $1"; grep -qF "$1" <<< "$out" || fail "refused for something else than '$1': $out"; good; }
echo x86_64 > "$t/mac/archs"; refused "is for [x86_64], not arm64"
echo "x86_64 arm64" > "$t/mac/archs"; refused "is for [x86_64 arm64], not arm64"
for lib in @rpath/libswiftCompatibilitySpan.dylib /opt/homebrew/lib/libx.dylib /Applications/Xcode.app/x.dylib /usr/lib/../../private/tmp/x.dylib /System/Library/./../x.dylib; do
  printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$lib" >> "$t/mac/libraries"; refused "needs what is not the system's: $lib"
done
: > "$t/mac/libraries"; refused "has no libraries"
for path in @loader_path /Applications/Xcode.app/Contents/Developer/usr/lib/swift; do
  printf '          cmd LC_RPATH\n      cmdsize 32\n         path %s (offset 12)\n' "$path" >> "$t/mac/commands"; refused "has a run path of its own: $path"
done
echo '          cmd LC_DYLD_ENVIRONMENT' >> "$t/mac/commands"; refused "sets variables of the dynamic linker"
sed -i.bak 's/minos 14.0/minos 26.0/' "$t/mac/commands"; refused "is for macOS 26.0 or later"
sed -i.bak 's/platform 1/platform 2/' "$t/mac/commands"; refused "is not for macOS"
printf '  sectname __swift56_hooks\n   segname __DATA\n' >> "$t/mac/commands"; refused "holds a compatibility library of Swift: __swift56_hooks"
echo 1 > "$t/mac/verify"; refused "does not verify"
sed -i.bak 's/Signature=adhoc/Authority=Someone/' "$t/mac/signature"; refused "is not signed ad hoc"
for flag in runtime restrict; do sed -i.bak "s/$flag//" "$t/mac/signature"; refused "not $flag"; done
echo '<plist/>' > "$t/mac/entitlements"; refused "has entitlements"

# The real thing: a program built here, as package-release.sh packages it.
if [[ "$(uname)" == Darwin ]] && cc=$(command -v clang); then
  printf 'int f(void){return 1;}\n' > "$t/f.c"; printf 'int f(void);int main(void){return f()-1;}\n' > "$t/m.c"
  host=$(uname -m); [[ "$host" == arm64 ]] && other=x86_64 || other=arm64
  "$cc" -arch "$host" -mmacosx-version-min=14.0 -Wl,-rpath,@loader_path -Wl,-rpath,"$t/some where" "$t/m.c" "$t/f.c" -o "$t/prog"
  XLESS_STRIP=strip bash "$repo/scripts/package-release.sh" --os macos 1.2.3 "$host" "$t/prog" "$t/out" >/dev/null 2>"$t/err" || fail "no package of a real binary: $(cat "$t/err")"
  rm -rf "$x"; mkdir "$x"; tar -xzf "$t/out/xless-1.2.3-macos-$host.tar.gz" -C "$x"
  p="$x/xless-1.2.3-macos-$host/bin/xless"
  "$p" || fail "the packaged binary does not run"
  [[ "$(otool -l "$p" | grep -c LC_RPATH)" == 0 ]] || fail "a run path is left"
  signature=$(codesign -dvv "$p" 2>&1)
  [[ "$signature" == *"flags=0x10802(adhoc,restrict,runtime)"* ]] || fail "signature: $signature"
  no() { XLESS_STRIP=strip bash "$repo/scripts/package-release.sh" --os macos 1.2.3 "$1" "$2" "$t/out2" >/dev/null 2>"$t/err" && fail "packaged: $3"; grep -qF "$3" "$t/err" || fail "refused for something else than '$3': $(cat "$t/err")"; }
  no "$other" "$t/prog" "not $other"
  "$cc" -arch "$host" -mmacosx-version-min=15.0 "$t/m.c" "$t/f.c" -o "$t/new"; no "$host" "$t/new" "is for macOS 15.0 or later"
  "$cc" -arch "$host" -mmacosx-version-min=14.0 -dynamiclib -install_name @rpath/libf.dylib "$t/f.c" -o "$t/libf.dylib"
  "$cc" -arch "$host" -mmacosx-version-min=14.0 "$t/m.c" "$t/libf.dylib" -o "$t/needs"; no "$host" "$t/needs" "needs what is not the system's: @rpath/libf.dylib"
  bash "$repo/scripts/check-macos-binary.sh" "$t/prog" "$host" >/dev/null 2>&1 && fail "a binary signed by the linker only is accepted"
  # What the linker leaves unsigned (for Intel, by itself, everything): no program of a package, and its package has a signature.
  "$cc" -arch x86_64 -mmacosx-version-min=14.0 -Wl,-no_adhoc_codesign "$t/m.c" "$t/f.c" -o "$t/unsigned"
  codesign --verify "$t/unsigned" 2>/dev/null && fail "the linker signed it all the same"
  bash "$repo/scripts/check-macos-binary.sh" "$t/unsigned" x86_64 >/dev/null 2>"$t/err" && fail "an unsigned binary is accepted"
  grep -qF "does not verify" "$t/err" || fail "unsigned: $(cat "$t/err")"
  XLESS_CODESIGN=true; export XLESS_CODESIGN; no x86_64 "$t/unsigned" "does not verify"; unset XLESS_CODESIGN
  XLESS_STRIP=strip bash "$repo/scripts/package-release.sh" --os macos 1.2.3 x86_64 "$t/unsigned" "$t/out" >/dev/null 2>"$t/err" || fail "no package of an unsigned binary: $(cat "$t/err")"
  rm -rf "$x"; mkdir "$x"; tar -xzf "$t/out/xless-1.2.3-macos-x86_64.tar.gz" -C "$x"
  signature=$(codesign -dvv "$x/xless-1.2.3-macos-x86_64/bin/xless" 2>&1)
  [[ "$signature" == *"flags=0x10802(adhoc,restrict,runtime)"* ]] || fail "x86_64 signature: $signature"
  # And what our own link flag (Package.swift) does for it: a build from source that its own agent can tell.
  grep -qF '"-Xlinker", "-adhoc_codesign"' "$repo/Package.swift" || fail "Package.swift leaves an Intel build unsigned"
  "$cc" -arch x86_64 -mmacosx-version-min=14.0 -Wl,-adhoc_codesign "$t/m.c" "$t/f.c" -o "$t/signed"
  codesign --verify --strict "$t/signed" || fail "-adhoc_codesign signs nothing"
fi

# A run path that cannot be taken out says why.
printf '#!/bin/sh\necho "install_name_tool: no room" >&2; exit 1\n' > "$t/mactools/install_name_tool"; chmod +x "$t/mactools/install_name_tool"
good; printf '          cmd LC_RPATH\n      cmdsize 32\n         path @loader_path (offset 12)\n' >> "$t/mac/commands"
PATH="$t/mactools:$PATH" XLESS_CHECK_BINARY=true bash "$repo/scripts/package-release.sh" --os macos 1.2.3 arm64 "$t/xless" "$t/out3" >/dev/null 2>"$t/err" && fail "packaged with a run path"
grep -qF "no room" "$t/err" || fail "nothing said of the run path: $(cat "$t/err")"

# scripts/check-link-map.sh: every object that was linked was made by this build.
m="$t/m/out"; mkdir -p "$m/Products/Release" "$m/Intermediates.noindex/p.build/Release/xless-p.build/Objects-normal/arm64" "$m/Intermediates.noindex/y.build/Release/Y-t.build/Objects-normal/arm64"
echo prog > "$m/Products/Release/xless"
objects="$m/Intermediates.noindex/p.build/Release/xless-p.build/Objects-normal/arm64" parts="$m/Intermediates.noindex/y.build/Release/Y-t.build/Objects-normal/arm64"
printf '%s\n' "$parts/A.o" "$parts/B.o" > "$parts/Y.LinkFileList"
printf '#!/bin/sh\nfor f; do :; done\ncat "$f.syms"\n' > "$t/mactools/nm"; chmod +x "$t/mactools/nm"
echo _a > "$parts/A.o.syms"; echo _b > "$parts/B.o.syms"; printf '_a\n_b\n' > "$m/Products/Release/Y.o.syms"
touch "$parts/A.o" "$parts/B.o" "$m/Products/Release/Y.o" "$objects/main.o"
xcode=/Applications/Xcode_27.app/Contents/Developer sdk=/Applications/Xcode_27.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk
goodmap() {
  printf '# Path: %s\n# Arch: arm64\n# Object files:\n[  0] linker synthesized\n[  1] %s\n[  2] %s\n[  3] %s\n[  4] %s\n%s# Sections:\n# Address\tSize    \tSegment\tSection\n0x1 0x2 __TEXT __text\n[  1] /elsewhere.a(x.o)\n' \
    "$m/Products/Release/xless" "$objects/main.o" "$m/Products/Release/Y.o" "$sdk/usr/lib/libSystem.tbd" "$sdk/System/Library/Frameworks/IOKit.framework/IOKit.tbd" "${1:+[  5] $1
}" > "$t/map"
}
linked() { PATH="$t/mactools:$PATH" bash "$repo/scripts/check-link-map.sh" "$t/map" "${1:-$m/Products/Release/xless}" "${2:-arm64}" 2>&1; }
goodmap; linked >/dev/null || fail "a good map is refused: $(linked)"
notlinked() { local out; out=$(linked "${2:-}" "${3:-}") && fail "a link is accepted: $1"; grep -qF -- "$1" <<< "$out" || fail "a link is refused for something else than '$1': $out"; }
swiftlib="$xcode/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
for object in "$swiftlib/libswiftCompatibilityPacks.a[2](Packs.o)" "$swiftlib/libswiftCompatibility50.a(x.o)" "$xcode/x/libclang_rt.osx.a[9](y.o)" "$sdk/usr/lib/x.o" "$sdk/usr/lib/x.dylib" \
              "$t/m/artifacts/x.framework/x" "$t/m/checkouts/x/x.o" "$m/Products/Release/libx.a(x.o)" "$m/Products/Release/../../../x.o" "$m/Intermediates.noindex/../x.o" /tmp/x.tbd "$sdk/../x.tbd" "/usr/lib/libx.dylib"; do
  goodmap "$object"; notlinked "$object"
done
goodmap; echo _c >> "$m/Products/Release/Y.o.syms"; notlinked "Y.o defines what its own objects do not: _c"; printf '_a\n_b\n' > "$m/Products/Release/Y.o.syms"
goodmap; echo "$swiftlib/libswiftCompatibilityPacks.a" >> "$parts/Y.LinkFileList"; notlinked "libswiftCompatibilityPacks.a"; printf '%s\n' "$parts/A.o" "$parts/B.o" > "$parts/Y.LinkFileList"
goodmap; mv "$parts/Y.LinkFileList" "$t/list.away"; notlinked "no list of the objects of Y.o"; mv "$t/list.away" "$parts/Y.LinkFileList"
goodmap; notlinked "is the map of" "$t/xless"
goodmap; notlinked "not x86_64" "" x86_64
goodmap; sed -i.bak '/Object files/,/Sections/d' "$t/map"; notlinked "lists no objects"
: > "$t/map"; notlinked "no link map"
rm "$t/map"; notlinked "no link map"
# A package is not made without one.
XLESS_CHECK_MAP='' XLESS_CODESIGN=true XLESS_CHECK_BINARY=true bash "$repo/scripts/package-release.sh" --os macos 1.2.3 x86_64 "$t/xless" "$t/out4" >/dev/null 2>"$t/err" && fail "packaged without a link map"
grep -qF "XLESS_LINK_MAP" "$t/err" || fail "no link map: $(cat "$t/err")"

# With the real linker, and an archive of the toolchain's that the section check does not know.
if [[ "$(uname)" == Darwin ]] && lib="$(dirname "$(dirname "$(xcrun --find swiftc 2>/dev/null)")")/lib/swift/macosx" && [[ -f "$lib/libswiftCompatibilityPacks.a" ]]; then
  r="$t/real/out"; o="$r/Intermediates.noindex/p.build/Release/xless-p.build/Objects-normal/$host"; mkdir -p "$o" "$r/Products/Release"
  echo 'print(1)' > "$o/main.swift"
  xcrun swiftc -target "$host-apple-macosx14.0" -runtime-compatibility-version none -c "$o/main.swift" -o "$o/main.o" 2>"$t/err" || fail "swiftc: $(cat "$t/err")"
  link() { xcrun swiftc -target "$host-apple-macosx14.0" -runtime-compatibility-version none "$o/main.o" -o "$r/Products/Release/xless" -Xlinker -map -Xlinker "$t/real.map" "$@" 2>"$t/err" || fail "link: $(cat "$t/err")"; }
  link; bash "$repo/scripts/check-link-map.sh" "$t/real.map" "$r/Products/Release/xless" "$host" >"$t/err" 2>&1 || fail "the real linker's map is refused: $(cat "$t/err")"
  # A target's objects in one, as the build makes it (ld -r renames what has no name of its own), and then with an archive in it.
  p="$r/Intermediates.noindex/y.build/Release/Y-t.build/Objects-normal/$host"; mkdir -p "$p"
  printf 'static int twice(int x) { return 2 * x; }\nint y(int x) { static const char *s[] = { "a", "b" }; return s[x & 1][0] + twice(x); }\n' > "$p/A.c"
  printf 'int z(void) { static double d[] = { 1.5, 2.5 }; return (int)d[0] + "cd"[1]; }\n' > "$p/B.c"
  for c in A B; do "$cc" -arch "$host" -mmacosx-version-min=14.0 -O0 -c "$p/$c.c" -o "$p/$c.o"; done
  printf '%s\n' "$p/A.o" "$p/B.o" > "$p/Y.LinkFileList"
  merge() { "$cc" -arch "$host" -mmacosx-version-min=14.0 -r -nostdlib "$p/A.o" "$p/B.o" "$@" -o "$r/Products/Release/Y.o" 2>"$t/err" || fail "ld -r: $(cat "$t/err")"; }
  merge; link "$r/Products/Release/Y.o"
  bash "$repo/scripts/check-link-map.sh" "$t/real.map" "$r/Products/Release/xless" "$host" >"$t/err" 2>&1 || fail "a target's objects in one are refused: $(cat "$t/err")"
  merge -Wl,-force_load,"$lib/libswiftCompatibilityPacks.a"
  bash "$repo/scripts/check-link-map.sh" "$t/real.map" "$r/Products/Release/xless" "$host" >"$t/err" 2>&1 && fail "accepted an archive inside a target's objects"
  grep -qF "Y.o defines what its own objects do not" "$t/err" || fail "merged: $(cat "$t/err")"
  for a in Packs Concurrency DynamicReplacements; do
    link -Xlinker -force_load -Xlinker "$lib/libswiftCompatibility$a.a"
    bash "$repo/scripts/check-link-map.sh" "$t/real.map" "$r/Products/Release/xless" "$host" >"$t/err" 2>&1 && fail "accepted libswiftCompatibility$a.a"
    grep -qF "libswiftCompatibility$a.a" "$t/err" || fail "$a: $(cat "$t/err")"
  done
fi

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
