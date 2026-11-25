#!/usr/bin/env bash
# The vendored third-party notices (licenses/vendored/): every row of SOURCES.tsv has its file with the recorded sha256,
# every file is listed, the components that are statically linked into xless are all covered, and
# scripts/third-party-licenses.sh ships each of them byte for byte (and refuses a modified one).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
v="$repo/licenses/vendored"
tsv="$v/SOURCES.tsv"
[[ -f "$tsv" ]] || fail "no $tsv"

listed=""
while IFS=$'\t' read -r name component version url want; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -n "$component" && -n "$version" && "$url" == https://* && "$want" =~ ^[0-9a-f]{64}$ ]] || fail "malformed row for $name"
  [[ -s "$v/$name" ]] || fail "$name is missing or empty"
  [[ "$(sha "$v/$name")" == "$want" ]] || fail "$name does not match its recorded sha256"
  grep -q "$name" "$v/README.md" || fail "$name is not described in README.md"
  listed="$listed $name"
done < "$tsv"
for f in "$v"/*; do
  b=$(basename "$f")
  [[ "$b" == SOURCES.tsv || "$b" == README.md ]] && continue
  case " $listed " in *" $b "*) ;; *) fail "$b is not listed in SOURCES.tsv" ;; esac
done

# Every statically linked component has a notice (the list is the one recorded in README.md, from the link map).
for c in swift swift-corelibs-foundation swift-foundation swift-foundation-icu swift-corelibs-libdispatch icu musl musl-fts curl curl-windows brotli boringssl libxml2 zlib libcxx libcxxabi libunwind compiler-rt libyaml; do
  awk -F'\t' -v c="$c" '$2 == c { f = 1 } END { exit !f }' "$tsv" || fail "no notice for $c"
done

# The script ships them verbatim, and refuses a vendored file that no longer matches.
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do
  mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"
done
XLESS_CHECKOUTS="$t/checkouts" bash "$repo/scripts/third-party-licenses.sh" "$t/out" >/dev/null
for n in $listed; do
  [[ "$n" == brotli-* || "$n" == curl-8.9.1-* ]] || cmp -s "$v/$n" "$t/out/$n" || fail "$n was not shipped verbatim"
done
[[ ! -e "$t/out/brotli-LICENSE.txt" && ! -e "$t/out/curl-8.9.1-COPYING.txt" ]] || fail "brotli's notice is for Windows alone"

# Windows: the runtime's DLLs and what is in them, and what is in xless.exe.
XLESS_CHECKOUTS="$t/checkouts" bash "$repo/scripts/third-party-licenses.sh" --os windows "$t/windows" >/dev/null
for n in swift-LICENSE.txt swift-corelibs-foundation-LICENSE.txt swift-foundation-LICENSE.txt swift-foundation-icu-LICENSE.txt icu-LICENSE.txt \
         swift-corelibs-libdispatch-LICENSE.txt curl-8.9.1-COPYING.txt zlib-LICENSE.txt brotli-LICENSE.txt llvm-compiler-rt-LICENSE.txt \
         boringssl-LICENSE.txt libyaml-LICENSE.txt; do
  cmp -s "$v/$n" "$t/windows/$n" || fail "$n is not in the Windows package"
done
cmp -s "$repo/licenses/windows-swift-runtime-CHANGES.txt" "$t/windows/swift-runtime-CHANGES.txt" || fail "what is changed in the runtime is not said in the Windows package"
[[ ! -e "$t/out/swift-runtime-CHANGES.txt" ]] || fail "nothing is changed in the runtime of the other systems"
for n in curl-COPYING.txt musl-COPYRIGHT.txt musl-fts-COPYING.txt libxml2-Copyright.txt llvm-libcxx-LICENSE.txt assetkit.txt lzfse.txt; do
  [[ ! -e "$t/windows/$n" ]] || fail "$n is not for the Windows package"
done

mkdir -p "$t/fake/scripts" "$t/fake/licenses" "$t/fake/ThirdParty/AssetKit/Sources/CLZFSE"
cp "$repo/scripts/third-party-licenses.sh" "$t/fake/scripts/"; cp "$repo/Package.resolved" "$t/fake/"; cp -R "$v" "$t/fake/licenses/vendored"
cp "$repo/ThirdParty/AssetKit/LICENSE" "$t/fake/ThirdParty/AssetKit/"
cp "$repo/ThirdParty/AssetKit/Sources/CLZFSE/LICENSE" "$t/fake/ThirdParty/AssetKit/Sources/CLZFSE/"
# Control: the untampered fake root succeeds, so the failure below can only come from the sha check.
XLESS_CHECKOUTS="$t/checkouts" bash "$t/fake/scripts/third-party-licenses.sh" "$t/out1" >/dev/null 2>&1 || fail "the untampered fake root should succeed"
first=$(echo $listed | cut -d' ' -f1)
echo tampered >> "$t/fake/licenses/vendored/$first"
rc=0; err=$(XLESS_CHECKOUTS="$t/checkouts" bash "$t/fake/scripts/third-party-licenses.sh" "$t/out2" 2>&1 >/dev/null) || rc=$?
[[ $rc -ne 0 ]] || fail "a modified notice was shipped"
[[ "$err" == *"$first does not match SOURCES.tsv"* ]] || fail "wrong failure for a modified notice: $err"
echo "licenses.test.sh: OK"
