#!/usr/bin/env bash
# scripts/arch-compare.sh: two finished .app directories (built on hosts of different architectures) must be
# byte-identical outside _CodeSignature/ and the Mach-O code-signature blob. The `xless tauri report` step is replaced
# by a stub (XLESS) that lists the tree, so the test needs no build of xless.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
S="$repo/scripts/arch-compare.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# The stub: `xless tauri report <app> --json <out>` writes the sorted file list as JSON to <out> and nothing to stdout, like the
# real command; a "<app>.summary" file beside the app adds a field, so trees with identical bytes can have different summaries.
cat > "$T/xless" <<'S'
#!/bin/sh
[ "$1 $2" = "tauri report" ] || exit 64
{ printf '{"files": ['; (cd "$3" && find . -type f -not -path './_CodeSignature/*' | sort | sed 's/.*/"&"/' | paste -sd, -); printf '], "extra": "%s"}\n' "$(cat "$3.summary" 2>/dev/null)"; } > "$5"
S
chmod +x "$T/xless"
export XLESS="$T/xless"

mkfixture() {   # DIR
  mkdir -p "$1/_CodeSignature" "$1/Frameworks"
  printf 'plist' > "$1/Info.plist"
  printf 'bundle-js' > "$1/main.jsbundle"
  printf 'sig-a' > "$1/_CodeSignature/CodeResources"
  printf 'data' > "$1/Frameworks/data.bin"
}
# A minimal 64-bit Mach-O: header, one LC_SEGMENT_64 __LINKEDIT, one LC_CODE_SIGNATURE, payload, then the signature blob.
macho() {   # FILE SIGNATURE-BYTE
  python3 - "$1" "$2" <<'P'
import struct, sys
path, sigbyte = sys.argv[1], sys.argv[2].encode()
payload = b"code" * 8
seg = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 0, 0, 0, 0, 7, 3, 0, 0)
sig_off = 32 + 72 + 16 + len(payload)
sig = sigbyte * 64
lc = struct.pack("<IIII", 0x1d, 16, sig_off, len(sig))
hdr = struct.pack("<IiiIIIII", 0xfeedfacf, 0x0100000c, 0, 2, 2, 72 + 16, 0, 0)
open(path, "wb").write(hdr + seg + lc + payload + sig)
P
}

test_identical_trees_pass() {
  mkfixture "$T/a1"; mkfixture "$T/b1"
  "$S" "$T/a1" "$T/b1" >"$T/out" 2>&1 || fail "identical trees exit $?: $(cat "$T/out")"
}
test_one_byte_change_fails_naming_the_file() {
  mkfixture "$T/a2"; mkfixture "$T/b2"
  printf 'bundle-jz' > "$T/b2/main.jsbundle"
  local rc=0; "$S" "$T/a2" "$T/b2" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "changed file exits $rc, want 1"
  grep -q '^  main.jsbundle: bytes differ' "$T/out" || fail "output does not name main.jsbundle: $(cat "$T/out")"
  ! grep -q '^  Info.plist' "$T/out" || fail "output names an unchanged file"
}
test_codesignature_directory_change_passes() {
  mkfixture "$T/a3"; mkfixture "$T/b3"
  printf 'sig-b' > "$T/b3/_CodeSignature/CodeResources"
  "$S" "$T/a3" "$T/b3" >"$T/out" 2>&1 || fail "_CodeSignature change exits $?: $(cat "$T/out")"
}
test_added_file_fails() {
  mkfixture "$T/a4"; mkfixture "$T/b4"; printf x > "$T/b4/extra.txt"
  local rc=0; "$S" "$T/a4" "$T/b4" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "extra file exits $rc, want 1"
  grep -q 'extra.txt' "$T/out" || fail "output does not name extra.txt"
}
test_macho_signature_blob_change_passes() {
  mkfixture "$T/a5"; mkfixture "$T/b5"; macho "$T/a5/App" A; macho "$T/b5/App" B
  "$S" "$T/a5" "$T/b5" >"$T/out" 2>&1 || fail "Mach-O signature blob change exits $?: $(cat "$T/out")"
}
test_macho_code_change_fails() {
  mkfixture "$T/a6"; mkfixture "$T/b6"; macho "$T/a6/App" A; macho "$T/b6/App" A
  python3 - "$T/b6/App" <<'P'
import sys
b = bytearray(open(sys.argv[1], "rb").read()); b[32 + 72 + 16 + 3] ^= 1; open(sys.argv[1], "wb").write(b)
P
  local rc=0; "$S" "$T/a6" "$T/b6" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "Mach-O code change exits $rc, want 1"
  grep -q 'App' "$T/out" || fail "output does not name App"
}
test_summary_difference_fails() {
  mkfixture "$T/a7"; mkfixture "$T/b7"
  cp -R "$T/a7/Frameworks/data.bin" "$T/a7/same.bin"; cp "$T/a7/same.bin" "$T/b7/same.bin"
  rm "$T/b7/Frameworks/data.bin"
  local rc=0; "$S" "$T/a7" "$T/b7" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "differing summaries exit $rc, want 1"
}
test_summaries_are_printed() {
  mkfixture "$T/a8"; mkfixture "$T/b8"
  "$S" "$T/a8" "$T/b8" >"$T/out" 2>&1 || fail "identical trees exit $?"
  grep -q 'main.jsbundle' "$T/out" || fail "summary content missing from output: $(cat "$T/out")"
  [[ $(grep -c '"files"' "$T/out") == 2 ]] || fail "want one summary per app: $(cat "$T/out")"
}
test_summary_diff_alone_fails() {
  mkfixture "$T/a9"; mkfixture "$T/b9"; echo one > "$T/a9.summary"; echo two > "$T/b9.summary"
  local rc=0; "$S" "$T/a9" "$T/b9" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "differing summaries (identical bytes) exit $rc, want 1"
  grep -q 'one' "$T/out" && grep -q 'two' "$T/out" || fail "summary diff not shown"
}
# The wider masking (scripts/code-signature-mask.py): a nested bundle's _CodeSignature/ at any depth, and a universal file
# slice by slice, each without its signature (the fat header's offsets and sizes left out); a code change in a slice fails.
fat() {   # FILE SIGNATURE-BYTE [FLIP]: two slices of macho(), the second's code byte FLIP changed
  macho "$1.a" "$2"; macho "$1.b" "$2"
  python3 - "$1" "${3:-}" <<'P2'
import struct, sys
path, flip = sys.argv[1], sys.argv[2]
a, b = open(path + ".a", "rb").read(), bytearray(open(path + ".b", "rb").read())
if flip: b[32 + 72 + 16 + int(flip)] ^= 1
off_a = 4096; off_b = off_a + ((len(a) + 4095) // 4096) * 4096
hdr = struct.pack(">II", 0xcafebabe, 2) + struct.pack(">iiIII", 0x0100000c, 0, off_a, len(a), 12) + struct.pack(">iiIII", 0x01000007, 3, off_b, len(b), 12)
out = bytearray(hdr) + bytearray(off_a - len(hdr)) + a + bytearray(off_b - off_a - len(a)) + b
open(path, "wb").write(out)
P2
  rm "$1.a" "$1.b"
}
test_nested_codesignature_and_fat_signatures_pass() {
  mkfixture "$T/a10"; mkfixture "$T/b10"
  mkdir -p "$T/a10/Frameworks/X.framework/_CodeSignature" "$T/b10/Frameworks/X.framework/_CodeSignature"
  printf 'sig-a' > "$T/a10/Frameworks/X.framework/_CodeSignature/CodeResources"
  printf 'sig-b' > "$T/b10/Frameworks/X.framework/_CodeSignature/CodeResources"
  fat "$T/a10/Universal" A; fat "$T/b10/Universal" B
  "$S" "$T/a10" "$T/b10" >"$T/out" 2>&1 || fail "nested _CodeSignature or fat signatures exit $?: $(cat "$T/out")"
}
test_fat_slice_code_change_fails() {
  mkfixture "$T/a11"; mkfixture "$T/b11"; fat "$T/a11/Universal" A; fat "$T/b11/Universal" A 5
  local rc=0; "$S" "$T/a11" "$T/b11" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail "a fat slice's code change exits $rc, want 1"
  grep -q 'Universal' "$T/out" || fail "output does not name Universal: $(cat "$T/out")"
}
test_usage() {
  local rc=0; "$S" "$T/a1" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "one argument exits $rc, want 2"
  rc=0; "$S" "$T/a1" "$T/missing" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "missing directory exits $rc, want 2"
}

test_identical_trees_pass
test_one_byte_change_fails_naming_the_file
test_codesignature_directory_change_passes
test_added_file_fails
test_macho_signature_blob_change_passes
test_macho_code_change_fails
test_summary_difference_fails
test_summaries_are_printed
test_summary_diff_alone_fails
test_nested_codesignature_and_fat_signatures_pass
test_fat_slice_code_change_fails
test_usage
echo PASS
