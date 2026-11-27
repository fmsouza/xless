#!/usr/bin/env bash
# scripts/pack-parity.sh: two trees of built products (one built in an image with the Xcode baked in, one with the Xcode's
# pack) must be the same file for file; a file may differ only where one of the paths the pack moved is written (the old
# one in the first tree, the new one in the second), and such a file is listed with every offset. Synthetic trees.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
S="$repo/scripts/pack-parity.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

OLD_SDK=/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle
NEW_SDK=/xcodes/27.0-27A266a-arm64/config/swiftpm/swift-sdks/darwin.artifactbundle
OLD_TC=/opt/xless/toolchains/swift-6.2.3        # 33 bytes
NEW_TC_SAME=/xcodes/26.2-17C5-arm64/toolchain   # 33 bytes: the same length
OLD_SWB=/opt/swift-build
NEW_SWB=/xcodes/27.0-27A266a-arm64/swift-build

mkfixture() {   # DIR
  mkdir -p "$1/App.app/_CodeSignature" "$1/App.app/Frameworks"
  printf 'plist' > "$1/App.app/Info.plist"
  printf 'bundle-js' > "$1/App.app/main.jsbundle"
  printf 'sig-a' > "$1/App.app/_CodeSignature/CodeResources"
  printf 'data' > "$1/App.app/Frameworks/data.bin"
}
# A minimal 64-bit Mach-O: header, one LC_SEGMENT_64 __LINKEDIT, one LC_CODE_SIGNATURE, payload, then the signature blob.
macho() {   # FILE SIGNATURE-BYTE [PAYLOAD]
  python3 - "$1" "$2" "${3:-}" <<'P'
import struct, sys
path, sigbyte, extra = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
payload = b"code" * 8 + extra
seg = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 0, 0, 0, 0, 7, 3, 0, 0)
sig_off = 32 + 72 + 16 + len(payload)
sig = sigbyte * 64
lc = struct.pack("<IIII", 0x1d, 16, sig_off, len(sig))
hdr = struct.pack("<IiiIIIII", 0xfeedfacf, 0x0100000c, 0, 2, 2, 72 + 16, 0, 0)
open(path, "wb").write(hdr + seg + lc + payload + sig)
P
}
# A fat file of two such slices (x86_64 and arm64), each with its own signature byte and payload.
fat() {   # FILE SIGNATURE-BYTE [PAYLOAD-X86_64] [PAYLOAD-ARM64]
  macho "$T/slice1" "$2" "${3:-}"; macho "$T/slice2" "$2" "${4:-}"
  python3 - "$1" "$T/slice1" "$T/slice2" <<'P'
import struct, sys
out, s1, s2 = sys.argv[1], open(sys.argv[2], "rb").read(), open(sys.argv[3], "rb").read()
o1 = 4096; o2 = o1 + 4096
hdr = struct.pack(">II", 0xcafebabe, 2) + struct.pack(">iiIII", 0x01000007, 3, o1, len(s1), 12) + struct.pack(">iiIII", 0x0100000c, 0, o2, len(s2), 12)
data = hdr + b"\0" * (o1 - len(hdr)) + s1 + b"\0" * (4096 - len(s1)) + s2
open(out, "wb").write(data)
P
}
# A 64-bit Mach-O as a linker lays it out: LC_SEGMENT_64 __TEXT with __text at file offset 0x400, LC_UUID, one LC_RPATH per
# path given (padded to 8 bytes), zeros up to 0x400 (the header padding), then the code. SECTION_AT moves __text.
rpaths() {   # FILE UUID-BYTE CODE PATH... (SECTION_AT=0x400)
  python3 - "$@" <<'P'
import os, struct, sys
path, uuid, code, rps = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode(), [p.encode() for p in sys.argv[4:]]
at = int(os.environ.get("SECTION_AT", "0x400"), 16)
sect = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x100000000 + at, len(code), at, 2, 0, 0, 0x80000400, 0, 0, 0)
seg = struct.pack("<II16sQQQQiiII", 0x19, 72 + 80, b"__TEXT", 0x100000000, 0x4000, 0, at + len(code), 5, 5, 1, 0) + sect
cmds = [seg, struct.pack("<II", 0x1b, 24) + uuid * 16]
for p in rps:
    n = (12 + len(p) + 1 + 7) // 8 * 8
    cmds.append(struct.pack("<III", 0x8000001c, n, 12) + p + b"\0" * (n - 12 - len(p)))
lc = b"".join(cmds)
hdr = struct.pack("<IiiIIIII", 0xfeedfacf, 0x0100000c, 0, 2, len(cmds), len(lc), 0, 0)
data = hdr + lc
open(path, "wb").write(data + b"\0" * (at - len(data)) + code)
P
}
# A 64-bit Mach-O with a symbol table, as ld64.lld writes a debug map: LC_SEGMENT_64 __TEXT (__text at 0x400), LC_UUID,
# LC_SYMTAB; the code, then one nlist_64 per name (n_value: VALUE+its index), then the string table, padded to 8 bytes.
symbols() {   # FILE UUID-BYTE VALUE NAME...
  python3 - "$@" <<'P'
import struct, sys
path, uuid, value, names = sys.argv[1], sys.argv[2].encode(), int(sys.argv[3]), [n.encode() for n in sys.argv[4:]]
code = b"code" * 4
sect = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x100000400, len(code), 0x400, 2, 0, 0, 0x80000400, 0, 0, 0)
seg = struct.pack("<II16sQQQQiiII", 0x19, 152, b"__TEXT", 0x100000000, 0x4000, 0, 0x410, 5, 5, 1, 0) + sect
strtab, strx = b" \0", []
for n in names:
    strx.append(len(strtab)); strtab += n + b"\0"
strtab += b"\0" * (-len(strtab) % 8)
symoff = 0x400 + len(code); stroff = symoff + 16 * len(names)
lc = seg + struct.pack("<II", 0x1b, 24) + uuid * 16 + struct.pack("<IIIIII", 0x2, 24, symoff, len(names), stroff, len(strtab))
hdr = struct.pack("<IiiIIIII", 0xfeedfacf, 0x0100000c, 0, 2, 3, len(lc), 0, 0)
nl = b"".join(struct.pack("<IBBHQ", x, 0x66, 0, 1, value + i) for i, x in enumerate(strx))
data = hdr + lc
open(path, "wb").write(data + b"\0" * (0x400 - len(data)) + code + nl + strtab)
P
}
code() { local rc=0; "$S" "$@" >"$T/out" 2>&1 || rc=$?; echo "$rc"; }

test_identical_trees_pass() {
  mkfixture "$T/a1"; mkfixture "$T/b1"
  [[ $(code "$T/a1" "$T/b1") == 0 ]] || fail "identical trees: $(cat "$T/out")"
  grep -q 'identical' "$T/out" || fail "no verdict: $(cat "$T/out")"
}
test_byte_flipped_outside_a_path_fails() {
  mkfixture "$T/a2"; mkfixture "$T/b2"
  printf 'flags -I%s/usr/include x' "$OLD_SDK" > "$T/a2/App.app/flags.txt"
  printf 'flags -I%s/usr/include y' "$NEW_SDK" > "$T/b2/App.app/flags.txt"
  [[ $(code "$T/a2" "$T/b2") == 1 ]] || fail "a changed byte outside the path exits 0: $(cat "$T/out")"
  grep -q 'App.app/flags.txt: differs' "$T/out" || fail "does not name the file: $(cat "$T/out")"
  ! grep -q ': path only' "$T/out" || fail "calls it path only: $(cat "$T/out")"
}
test_same_length_path_swap_passes_and_is_listed() {
  mkfixture "$T/a3"; mkfixture "$T/b3"
  printf '\x01\x02%s/usr/lib/swift\x00tail' "$OLD_TC" > "$T/a3/App.app/Frameworks/data.bin"
  printf '\x01\x02%s/usr/lib/swift\x00tail' "$NEW_TC_SAME" > "$T/b3/App.app/Frameworks/data.bin"
  [[ $(code "$T/a3" "$T/b3") == 0 ]] || fail "same-length path swap: $(cat "$T/out")"
  grep -q 'App.app/Frameworks/data.bin: path only' "$T/out" || fail "not listed as path only: $(cat "$T/out")"
  grep -q "0x2 $OLD_TC" "$T/out" || fail "baseline offset not listed: $(cat "$T/out")"
  grep -q "0x2 $NEW_TC_SAME" "$T/out" || fail "candidate offset not listed: $(cat "$T/out")"
  grep -q 'same length' "$T/out" || fail "method not named: $(cat "$T/out")"
}
test_same_length_path_swap_with_another_change_fails() {
  mkfixture "$T/a17"; mkfixture "$T/b17"
  printf '\x01\x02%s/usr/lib/swift\x00tail' "$OLD_TC" > "$T/a17/App.app/Frameworks/data.bin"
  printf '\x01\x02%s/usr/lib/swift\x00tall' "$NEW_TC_SAME" > "$T/b17/App.app/Frameworks/data.bin"
  [[ $(code "$T/a17" "$T/b17") == 1 ]] || fail "a same-length swap and a changed byte pass: $(cat "$T/out")"
  grep -q 'App.app/Frameworks/data.bin: differs outside its 1 moved path(s) (same length)' "$T/out" || fail "verdict: $(cat "$T/out")"
  ! grep -q ': path only' "$T/out" || fail "calls it path only: $(cat "$T/out")"
}
test_fat_file_is_compared_slice_by_slice() {
  mkfixture "$T/a18"; mkfixture "$T/b18"
  # both slices path only (and signed differently)
  fat "$T/a18/App.app/Fat" A "$OLD_TC/lib" "$OLD_TC/lib"; fat "$T/b18/App.app/Fat" B "$NEW_TC_SAME/lib" "$NEW_TC_SAME/lib"
  [[ $(code "$T/a18" "$T/b18") == 0 ]] || fail "path-only slices: $(cat "$T/out")"
  grep -q 'App.app/Fat: path only (2 slices' "$T/out" || fail "not listed per slice: $(cat "$T/out")"
  # one slice differs besides its path
  fat "$T/b18/App.app/Fat" B "$NEW_TC_SAME/lib" "$NEW_TC_SAME/lix"
  [[ $(code "$T/a18" "$T/b18") == 1 ]] || fail "a differing slice passes: $(cat "$T/out")"
  grep -q 'App.app/Fat: differs' "$T/out" || fail "verdict: $(cat "$T/out")"
}
test_longer_path_in_text_passes_by_substitution() {
  mkfixture "$T/a4"; mkfixture "$T/b4"
  printf '{"swb": "%s/swbuild", "sdk": "%s"}\n' "$OLD_SWB" "$OLD_SDK" > "$T/a4/App.app/record.json"
  printf '{"swb": "%s/swbuild", "sdk": "%s"}\n' "$NEW_SWB" "$NEW_SDK" > "$T/b4/App.app/record.json"
  [[ $(code "$T/a4" "$T/b4") == 0 ]] || fail "longer path in text: $(cat "$T/out")"
  grep -q 'App.app/record.json: path only' "$T/out" || fail "not listed: $(cat "$T/out")"
  grep -q "0x9 $OLD_SWB/swbuild -> 0x9 $NEW_SWB/swbuild" "$T/out" || fail "offsets of the first occurrence: $(cat "$T/out")"
  grep -q 'substituted' "$T/out" || fail "method not named: $(cat "$T/out")"
}
test_longer_path_that_moves_other_bytes_is_refused() {
  # a length-prefixed record: the length byte changes with the path, so the substitution does not give the candidate
  mkfixture "$T/a5"; mkfixture "$T/b5"
  python3 - "$T/a5/App.app/rec.bin" "$OLD_SWB" <<'P'
import sys; p = sys.argv[2].encode(); open(sys.argv[1], "wb").write(bytes([len(p)]) + p + b"\0")
P
  python3 - "$T/b5/App.app/rec.bin" "$NEW_SWB" <<'P'
import sys; p = sys.argv[2].encode(); open(sys.argv[1], "wb").write(bytes([len(p)]) + p + b"\0")
P
  [[ $(code "$T/a5" "$T/b5") == 1 ]] || fail "a path whose length moved other bytes passes: $(cat "$T/out")"
  grep -q 'App.app/rec.bin: differs' "$T/out" || fail "not named: $(cat "$T/out")"
  grep -q 'lengths differ' "$T/out" || fail "does not say why: $(cat "$T/out")"
}
test_missing_file_fails() {
  mkfixture "$T/a6"; mkfixture "$T/b6"; rm "$T/b6/App.app/main.jsbundle"; printf x > "$T/b6/App.app/extra"
  [[ $(code "$T/a6" "$T/b6") == 1 ]] || fail "a missing file: $(cat "$T/out")"
  grep -q 'App.app/main.jsbundle: only in the baseline' "$T/out" || fail "missing file not named: $(cat "$T/out")"
  grep -q 'App.app/extra: only in the candidate' "$T/out" || fail "extra file not named: $(cat "$T/out")"
}
test_code_signature_is_masked() {
  mkfixture "$T/a7"; mkfixture "$T/b7"
  printf 'sig-b' > "$T/b7/App.app/_CodeSignature/CodeResources"
  macho "$T/a7/App.app/App" A; macho "$T/b7/App.app/App" B
  mkdir -p "$T/a7/App.app/PlugIns/X.appex/_CodeSignature" "$T/b7/App.app/PlugIns/X.appex/_CodeSignature"
  printf 'one' > "$T/a7/App.app/PlugIns/X.appex/_CodeSignature/CodeResources"
  printf 'two' > "$T/b7/App.app/PlugIns/X.appex/_CodeSignature/CodeResources"
  fat "$T/a7/App.app/Fat" A; fat "$T/b7/App.app/Fat" B
  [[ $(code "$T/a7" "$T/b7") == 0 ]] || fail "signature-only differences: $(cat "$T/out")"
}
test_path_in_macho_with_signature_change() {
  # a same-length path swap in the code, and therefore another signature: both masked, the file listed
  mkfixture "$T/a8"; mkfixture "$T/b8"
  macho "$T/a8/App.app/App" A "$OLD_TC"; macho "$T/b8/App.app/App" B "$NEW_TC_SAME"
  [[ $(code "$T/a8" "$T/b8") == 0 ]] || fail "path and signature: $(cat "$T/out")"
  grep -q 'App.app/App: path only' "$T/out" || fail "not listed: $(cat "$T/out")"
}
test_macho_code_change_fails() {
  mkfixture "$T/a9"; mkfixture "$T/b9"
  macho "$T/a9/App.app/App" A "$OLD_TC"; macho "$T/b9/App.app/App" A "$OLD_TC"
  python3 - "$T/b9/App.app/App" <<'P'
import sys
b = bytearray(open(sys.argv[1], "rb").read()); b[32 + 72 + 16 + 3] ^= 1; open(sys.argv[1], "wb").write(b)
P
  [[ $(code "$T/a9" "$T/b9") == 1 ]] || fail "a code change passes: $(cat "$T/out")"
}
test_paths_must_correspond() {
  # the old SDK path in the baseline, the new Swift Build path in the candidate: not the same path moved
  mkfixture "$T/a10"; mkfixture "$T/b10"
  printf 'x %s y' "$OLD_SDK" > "$T/a10/App.app/f"; printf 'x %s y' "$NEW_SWB" > "$T/b10/App.app/f"
  [[ $(code "$T/a10" "$T/b10") == 1 ]] || fail "different moved paths pass: $(cat "$T/out")"
  # a path that is not one of the moved ones
  printf 'x /opt/xless/other y' > "$T/a10/App.app/f"; printf 'x /xcodes/27.0-27A266a-arm64/other y' > "$T/b10/App.app/f"
  [[ $(code "$T/a10" "$T/b10") == 1 ]] || fail "a path that did not move passes: $(cat "$T/out")"
  # an old path in the candidate is not masked
  printf 'x %s y' "$OLD_SWB" > "$T/a10/App.app/f"; printf 'x %s/ y' "$OLD_SWB" > "$T/b10/App.app/f"
  [[ $(code "$T/a10" "$T/b10") == 1 ]] || fail "a changed byte after an old path passes: $(cat "$T/out")"
  # a longer name that only starts like a moved path
  printf 'x %s y' "$OLD_SWB" > "$T/a10/App.app/f"; printf 'x %sX y' "$NEW_SWB" > "$T/b10/App.app/f"
  [[ $(code "$T/a10" "$T/b10") == 1 ]] || fail "a longer name passes: $(cat "$T/out")"
}
test_symlinks_are_compared() {
  mkfixture "$T/a11"; mkfixture "$T/b11"
  ln -s Info.plist "$T/a11/App.app/link"; ln -s main.jsbundle "$T/b11/App.app/link"
  [[ $(code "$T/a11" "$T/b11") == 1 ]] || fail "a changed link passes: $(cat "$T/out")"
}
test_summary_counts() {
  mkfixture "$T/a12"; mkfixture "$T/b12"
  printf '%s' "$OLD_SWB" > "$T/a12/App.app/p"; printf '%s' "$NEW_SWB" > "$T/b12/App.app/p"
  [[ $(code "$T/a12" "$T/b12") == 0 ]] || fail "$(cat "$T/out")"
  grep -q '^==> 4 files: 3 identical, 1 path only, 0 differ' "$T/out" || fail "summary: $(cat "$T/out")"
}
test_moved_path_in_a_load_command_passes() {
  # the toolchain's rpath: longer in the candidate, so the load commands grow into the header padding; LC_UUID (the
  # linker's hash of the file) changes with it; the code is where it was
  mkfixture "$T/a14"; mkfixture "$T/b14"
  rpaths "$T/a14/App.app/App" A code /usr/lib/swift "$OLD_TC/usr/lib/swift-6.2/iphoneos" @executable_path/Frameworks
  rpaths "$T/b14/App.app/App" B code /usr/lib/swift "$NEW_TC_SAME-and-longer/usr/lib/swift-6.2/iphoneos" @executable_path/Frameworks
  [[ $(code "$T/a14" "$T/b14") == 1 ]] || fail "a name that only starts like the pack's toolchain passes: $(cat "$T/out")"
  rpaths "$T/b14/App.app/App" B code /usr/lib/swift "$NEW_SWB/../toolchain/usr/lib/swift-6.2/iphoneos" @executable_path/Frameworks
  [[ $(code "$T/a14" "$T/b14") == 1 ]] || fail "another moved path in the candidate passes: $(cat "$T/out")"
  rpaths "$T/b14/App.app/App" B code /usr/lib/swift "/xcodes/27.0-27A266a-arm64/toolchain/usr/lib/swift-6.2/iphoneos" @executable_path/Frameworks
  [[ $(code "$T/a14" "$T/b14") == 0 ]] || fail "a moved path in LC_RPATH: $(cat "$T/out")"
  grep -q 'App.app/App: path only (Mach-O: 1 occurrence(s) in load commands, and LC_UUID' "$T/out" || fail "not listed: $(cat "$T/out")"
  grep -q "$OLD_TC/usr/lib/swift-6.2/iphoneos -> .* /xcodes/27.0-27A266a-arm64/toolchain/usr/lib/swift-6.2/iphoneos \[load command LC_RPATH\]" "$T/out" \
    || fail "the occurrence is not listed with its load command: $(cat "$T/out")"
  grep -q 'LC_UUID 41414141414141414141414141414141 -> 42424242424242424242424242424242' "$T/out" || fail "UUIDs not listed: $(cat "$T/out")"
  # the image's own Swift (root /): its per-platform library directory, at the start of the path
  rpaths "$T/a14/App.app/App" A code /usr/lib/swift /usr/lib/swift-6.2/iphoneos @executable_path/Frameworks
  [[ $(code "$T/a14" "$T/b14") == 0 ]] || fail "the image's own Swift moved to the pack: $(cat "$T/out")"
  grep -q '0x[0-9a-f]* /usr/lib/swift-6.2/iphoneos -> ' "$T/out" || fail "not listed: $(cat "$T/out")"
}
test_load_command_proof_is_exact() {
  mkfixture "$T/a15"; mkfixture "$T/b15"
  local new=/xcodes/27.0-27A266a-arm64/toolchain/usr/lib/swift-6.2/iphoneos
  # a byte of code
  rpaths "$T/a15/App.app/App" A code /usr/lib/swift-6.2/iphoneos; rpaths "$T/b15/App.app/App" A cade "$new"
  [[ $(code "$T/a15" "$T/b15") == 1 ]] || fail "a code change next to a moved rpath passes: $(cat "$T/out")"
  # the code moved (the load commands did not fit in the header padding)
  rpaths "$T/a15/App.app/App" A code /usr/lib/swift-6.2/iphoneos; SECTION_AT=0x420 rpaths "$T/b15/App.app/App" A code "$new"
  [[ $(code "$T/a15" "$T/b15") == 1 ]] || fail "moved code passes: $(cat "$T/out")"
  grep -q 'first section is at 0x400 in the baseline and 0x420 in the candidate' "$T/out" || fail "does not say the code moved: $(cat "$T/out")"
  # a byte in the header padding
  rpaths "$T/a15/App.app/App" A code /usr/lib/swift-6.2/iphoneos; rpaths "$T/b15/App.app/App" A code "$new"
  python3 - "$T/b15/App.app/App" <<'P'
import sys
b = bytearray(open(sys.argv[1], "rb").read()); b[0x3f0] = 1; open(sys.argv[1], "wb").write(b)
P
  [[ $(code "$T/a15" "$T/b15") == 1 ]] || fail "a byte in the header padding passes: $(cat "$T/out")"
  # the system's Swift (/usr/lib/swift, no platform) is not the toolchain's
  rpaths "$T/a15/App.app/App" A code /usr/lib/swift; rpaths "$T/b15/App.app/App" A code /xcodes/27.0-27A266a-arm64/toolchain/usr/lib/swift
  [[ $(code "$T/a15" "$T/b15") == 1 ]] || fail "the system's /usr/lib/swift masked: $(cat "$T/out")"
  # another rpath changes too
  rpaths "$T/a15/App.app/App" A code /usr/lib/swift-6.2/iphoneos @loader_path
  # shellcheck disable=SC2016   # $ORIGIN is the rpath itself
  rpaths "$T/b15/App.app/App" A code "$new" '$ORIGIN'
  [[ $(code "$T/a15" "$T/b15") == 1 ]] || fail "a changed rpath that did not move passes: $(cat "$T/out")"
}
test_moved_path_in_the_symbol_table_passes() {
  # the debug map names the SDK's prebuilt modules: the string table grows, every later name's offset moves
  mkfixture "$T/a16"; mkfixture "$T/b16"
  symbols "$T/a16/App.app/App" A 7 /work/main.o "$OLD_SDK/usr/lib/swift/A.swiftmodule" "$OLD_SDK/usr/lib/swift/B.swiftmodule" _main
  symbols "$T/b16/App.app/App" B 7 /work/main.o "$NEW_SDK/usr/lib/swift/A.swiftmodule" "$NEW_SDK/usr/lib/swift/B.swiftmodule" _main
  [[ $(code "$T/a16" "$T/b16") == 0 ]] || fail "moved paths in the string table: $(cat "$T/out")"
  grep -q "App.app/App: path only (Mach-O: 2 occurrence(s) in the symbol table's strings, and LC_UUID" "$T/out" || fail "not listed: $(cat "$T/out")"
  grep -q "$OLD_SDK/usr/lib/swift/B.swiftmodule -> 0x[0-9a-f]* $NEW_SDK/usr/lib/swift/B.swiftmodule \\[string table\\]" "$T/out" \
    || fail "the second occurrence is not listed: $(cat "$T/out")"
  # a symbol's value
  symbols "$T/b16/App.app/App" B 8 /work/main.o "$NEW_SDK/usr/lib/swift/A.swiftmodule" "$NEW_SDK/usr/lib/swift/B.swiftmodule" _main
  [[ $(code "$T/a16" "$T/b16") == 1 ]] || fail "a changed symbol value passes: $(cat "$T/out")"
  # a name that is not a moved path
  symbols "$T/b16/App.app/App" B 7 /work/main.o "$NEW_SDK/usr/lib/swift/A.swiftmodule" "$NEW_SDK/usr/lib/swift/B.swiftmodule" _mainX
  [[ $(code "$T/a16" "$T/b16") == 1 ]] || fail "a changed name passes: $(cat "$T/out")"
  # a name that moved elsewhere than the pack's SDK
  symbols "$T/b16/App.app/App" B 7 /work/main.o "$NEW_SDK/usr/lib/swift/A.swiftmodule" "$NEW_SDK/usr/lib/swift/C.swiftmodule" _main
  [[ $(code "$T/a16" "$T/b16") == 1 ]] || fail "a changed module name passes: $(cat "$T/out")"
}
test_usage() {
  mkfixture "$T/a13"
  [[ $(code "$T/a13") == 2 ]] || fail "one argument"
  [[ $(code "$T/a13" "$T/missing") == 2 ]] || fail "a missing directory"
}

test_identical_trees_pass
test_byte_flipped_outside_a_path_fails
test_same_length_path_swap_passes_and_is_listed
test_same_length_path_swap_with_another_change_fails
test_fat_file_is_compared_slice_by_slice
test_longer_path_in_text_passes_by_substitution
test_longer_path_that_moves_other_bytes_is_refused
test_missing_file_fails
test_code_signature_is_masked
test_path_in_macho_with_signature_change
test_macho_code_change_fails
test_paths_must_correspond
test_symlinks_are_compared
test_summary_counts
test_moved_path_in_a_load_command_passes
test_load_command_proof_is_exact
test_moved_path_in_the_symbol_table_passes
test_usage
echo PASS
