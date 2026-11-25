#!/usr/bin/env bash
# The Windows package (scripts/windows-package.py, package-release.sh --os windows, check-package.sh windows): made from stand-ins
# for PE files, it holds what it must; anything more, less or of another kind is refused, and so is a program or library that needs
# what is neither packed nor Windows' own.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export LC_ALL=C

cat > "$t/pe.py" <<'P'
"""pe.py <out> [key=value...]: a PE file that loads nothing, with what windows-package.py reads.
needs=A.dll:f,g;B.dll:#  delay=...  machine=8664  flags=160  dll=0|1  subsystem=3  codeview=0|1  magic=20b  sum=<the checksum>  signed=0|1
load=<load flags>|none: the load configuration, of config=<size> bytes that says it is of inner=<size>; a library has one with a checksum"""
import struct, sys
out, opts = sys.argv[1], dict(a.split("=", 1) for a in sys.argv[2:])
BASE = 0x1000  # the one section, at 0x400 in the file
body = bytearray()
def add(data):
    while len(body) % 8: body.append(0)
    at = BASE + len(body); body.extend(data); return at
def string(s): return add(s.encode() + b"\0")
def thunks(functions):
    values = [(1 << 63 | 1) if f == "#" else add(b"\0\0" + f.encode() + b"\0") for f in functions]
    return add(struct.pack("<%dQ" % (len(values) + 1), *values, 0))
def table(text):
    return [(string(d), thunks([f for f in fs.split(",") if f])) for d, _, fs in (p.partition(":") for p in text.split(";") if p)]
directories = [(0, 0)] * 16
needs = table(opts.get("needs", "KERNEL32.dll:ExitProcess"))
rows = b"".join(struct.pack("<IIIII", t, 0, 0, n, t) for n, t in needs) + bytes(20)
directories[1] = (add(rows), len(rows))
delay = table(opts.get("delay", ""))
if delay:
    rows = b"".join(struct.pack("<IIIIIIII", 1, n, 0, t, t, 0, 0, 0) for n, t in delay) + bytes(32)
    directories[13] = (add(rows), len(rows))
dll = opts.get("dll", "0") == "1"
load = opts.get("load", "0")
if load != "none":
    size = int(opts.get("config", "320"))
    directories[10] = (add(struct.pack("<I", int(opts.get("inner", "320"))) + bytes(74) + struct.pack("<H", int(load, 16)) + bytes(240)), size)
if opts.get("signed") == "1": directories[4] = (0x400, 8)
if opts.get("codeview") == "1": directories[6] = (add(struct.pack("<IIHHIIII", 0, 0, 0, 0, 2, 0, 0, 0)), 28)
characteristics = 0x22 | (0x2000 if dll else 0)
optional = struct.pack("<H", int(opts.get("magic", "20b"), 16)) + bytes(62) + struct.pack("<I", int(opts.get("sum", "0"), 16))
optional += struct.pack("<HH", int(opts.get("subsystem", "3")), int(opts.get("flags", "160"), 16)) + bytes(36) + struct.pack("<I", 16)
optional += b"".join(struct.pack("<II", *d) for d in directories)
head = b"MZ" + bytes(58) + struct.pack("<I", 64) + b"PE\0\0" + struct.pack("<HHIIIHH", int(opts.get("machine", "8664"), 16), 1, 0, 0, 0, len(optional), characteristics)
head += optional + struct.pack("<8sIIIIIIHHI", b".rdata", len(body), BASE, len(body), 0x400, 0, 0, 0, 0, 0x40000040)
open(out, "wb").write(head.ljust(0x400, b"\0") + bytes(body))
P
pe() { python3 -I "$t/pe.py" "$@"; }
export XLESS_CHECKOUTS="$t/checkouts"
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"; done

# A program, and a runtime of which it needs a part.
runtime="$t/runtime"; export XLESS_RUNTIME="$runtime"
mkdir -p "$runtime"
xless() { pe "$t/xless.exe" load=a00 "needs=${1:-swiftCore.dll:a,b;KERNEL32.dll:ExitProcess;api-ms-win-crt-runtime-l1-1-0.dll:exit;VCRUNTIME140.dll:memcpy;VCRUNTIME140_1.dll:__CxxFrameHandler4}" "${@:2}"; }
xless
pe "$runtime/swiftCore.dll" dll=1 subsystem=2 sum=1234 "needs=swiftCRT.dll:#;KERNEL32.dll:VirtualAlloc" "delay=dbghelp.dll:SymInitialize"
pe "$runtime/swiftCRT.dll" dll=1 subsystem=2 "needs=msvcp140.dll:x;ucrtless.dll:y" # refused below, then made good
pe "$runtime/Foundation.dll" dll=1
package() { bash "$repo/scripts/package-release.sh" --os windows 1.2.3 x86_64 "$t/xless.exe" "$t/out" 2>&1; }
rm -rf "$t/out"; mkdir "$t/out"
out=$(package) && fail "packaged what needs a library of nobody's"
grep -qF "swiftCRT.dll needs ucrtless.dll, which is neither Windows' nor the Swift runtime's" <<< "$out" || fail "wrong message: $out"
pe "$runtime/swiftCRT.dll" dll=1 subsystem=2 "needs=msvcp140.dll:x;dispatch.dll:y"
out=$(package) && fail "packaged without a library of the runtime"
grep -qF "swiftCRT.dll needs dispatch.dll, which is not in" <<< "$out" || fail "wrong message: $out"
[[ -z "$(ls "$t/out")" ]] || fail "a refused package is there"
pe "$runtime/swiftCRT.dll" dll=1 subsystem=2 "needs=msvcp140.dll:x"
out=$(package) || fail "no package: $out"
zip="$t/out/xless-1.2.3-windows-x86_64.zip" top=xless-1.2.3-windows-x86_64
[[ "$out" == "$zip" ]] || fail "it says: $out"
grep -qE '^[0-9a-f]{64}  xless-1\.2\.3-windows-x86_64\.zip$' "$t/out/SHA256SUMS" || fail "SHA256SUMS: $(cat "$t/out/SHA256SUMS")"
check() { bash "$repo/scripts/check-package.sh" windows 1.2.3 x86_64 "$1" 2>"$t/err"; }
check "$zip" > "$t/files" || fail "a good package is refused: $(cat "$t/err")"
sed "s#^$top/##" "$t/files" | grep -v /licenses/ > "$t/some"
diff - "$t/some" <<< $'LICENSE\nbin/swiftCRT.dll\nbin/swiftCore.dll\nbin/xless.exe\nshare/xless/VERSION' || fail "the files"
# Each library has the load flags of xless.exe, and is the runtime's otherwise.
(cd "$t" && unzip -q -o "$zip" "$top/bin/*" -d un)
python3 -I - "$runtime" "$t/un/$top/bin" <<'P' || fail "another change than the load flags"
import struct, sys
for name, checksum in (("swiftCore.dll", True), ("swiftCRT.dll", False)):
    was, now = (bytearray(open(f"{d}/{name}", "rb").read()) for d in sys.argv[1:])
    pe, = struct.unpack_from("<I", was, 0x3C)
    rva, = struct.unpack_from("<I", was, pe + 24 + 112 + 80)
    at = rva - 0x1000 + 0x400 + 78
    assert now[at:at + 2] == b"\x00\x0a" and was[at:at + 2] == b"\0\0"
    was[at:at + 2] = now[at:at + 2]
    total = 0  # as imagehlp's CheckSumMappedFile, word by word
    for i in range(0, len(was), 2):
        word = 0 if i in (pe + 88, pe + 90) else int.from_bytes(was[i:i + 2], "little")
        total += word
        total = (total & 0xFFFF) + (total >> 16)
    got, = struct.unpack_from("<I", now, pe + 88)
    assert got == (total + len(was) if checksum else 0), (name, hex(got))
    was[pe + 88:pe + 92] = now[pe + 88:pe + 92]
    assert was == now, name
P
harden() { python3 -I "$repo/scripts/windows-package.py" harden "$t/lib.dll" 2>&1; }
unhardened() {  # what it says, then pe.py's words
  local say="$1"; shift
  pe "$t/lib.dll" dll=1 "$@"; cp "$t/lib.dll" "$t/lib.was"
  out=$(harden) && fail "hardened: $say"
  grep -qF "$say" <<< "$out" || fail "refused for something else than '$say': $out"
  cmp -s "$t/lib.dll" "$t/lib.was" || fail "changed what it refused: $say"
}
unhardened "has no room for load flags" load=none
unhardened "has no room for load flags" config=79
unhardened "has no room for load flags" inner=79
unhardened "has load flags of its own (0x800)" load=800
unhardened "is signed" signed=1
pe "$t/lib.dll" dll=1 load=a00; cp "$t/lib.dll" "$t/lib.was"; harden || fail "what is hardened is not hardened again"
cmp -s "$t/lib.dll" "$t/lib.was" || fail "hardened twice, it is another"
for id in swift-LICENSE swift-corelibs-foundation swift-foundation-LICENSE swift-corelibs-libdispatch swift-foundation-icu icu curl zlib boringssl libyaml llvm-compiler-rt swift-crypto yams; do
  grep -q "/licenses/$id" "$t/files" || fail "no notice for $id"
done
for id in musl assetkit lzfse llvm-libcxx; do grep -q "/licenses/$id" "$t/files" && fail "a notice for $id, which a Windows xless has not in it"; done
cp "$zip" "$t/first.zip"; package >/dev/null || fail "no second package"
cmp -s "$zip" "$t/first.zip" || fail "the same files, another zip"
bash "$repo/scripts/package-release.sh" --os windows 1.2.3 arm64 "$t/xless.exe" "$t/out" >/dev/null 2>&1 && fail "a package for arm64"
XLESS_RUNTIME='' package >/dev/null && fail "a package without a runtime"
bash "$repo/scripts/check-package.sh" windows 1.2.4 x86_64 "$zip" >/dev/null 2>&1 && fail "another version's package"
bash "$repo/scripts/check-package.sh" windows 1.2.3 arm64 "$zip" >/dev/null 2>&1 && fail "another architecture's package"

# What is refused: the zip rewritten.
cat > "$t/rezip.py" <<'P'
import stat, sys, zipfile
source, target, code = sys.argv[1:]
files = []
with zipfile.ZipFile(source) as z:
    for i in z.infolist(): files.append((i, z.read(i)))
top = "xless-1.2.3-windows-x86_64/"
def info(name, mode=stat.S_IFREG | 0o644):
    i = zipfile.ZipInfo(top + name, (1980, 1, 1, 0, 0, 0)); i.create_system = 3; i.external_attr = mode << 16; i.compress_type = zipfile.ZIP_DEFLATED; return i
def add(name, data=b"x", **k): files.append((info(name, **k), data))
def drop(name): files[:] = [f for f in files if f[0].filename != top + name]
def put(name, data): drop(name); add(name, data)
def read(name): return next(d for i, d in files if i.filename == top + name)
def each(f):
    for i, _ in files: f(i)
comment = b""
exec(code)
import warnings; warnings.simplefilter("ignore")
with zipfile.ZipFile(target, "w") as z:
    for i, data in files:
        n = i.filename; z.writestr(i, data)
    z.comment = comment
P
bad() {  # what it says, then Python that changes the zip
  python3 -I "$t/rezip.py" "$zip" "$t/bad.zip" "$2"
  check "$t/bad.zip" >/dev/null && fail "accepted: $1 ($2)"
  grep -qF "$1" "$t/err" || fail "refused for something else than '$1': $(cat "$t/err")"
}
python3 -I "$t/rezip.py" "$zip" "$t/bad.zip" ""; check "$t/bad.zip" >/dev/null || fail "rewritten, it is refused: $(cat "$t/err")"
bad "too much" 'add("bin/vcruntime140.dll")'
bad "too much" 'add("bin/msvcp140.dll")'
bad "too much" 'add("bin/ucrtbase.dll")'
bad "too much" 'add("bin/xless.pdb")'
bad "too much" 'add("bin/xless.lib")'
bad "too much" 'add("bin/more/swiftCore.dll")'
bad "too much" 'add("share/xless/licenses/other.txt")'
bad "missing" 'drop("bin/xless.exe")'
bad "missing" 'drop("LICENSE")'
bad "missing" 'drop("share/xless/licenses/curl-8.9.1-COPYING.txt")'
bad "is there twice" 'add("LICENSE")'
bad "is there twice" 'add("license")'
bad "a name that no file" 'add("../../evil")'
bad "a name that no file" 'add("bin/..")'
bad "a name that no file" 'add("bin/x:stream")'
bad "a name that no file" 'add("bin\\x")'
bad "a name that no file" 'add("bin/x.")'
bad "a name that no file" 'add("bin/")'
bad "a name that no file" 'i = info("x"); i.filename = "/absolute"; files.append((i, b""))'
bad "a name that no file" 'i = info("x"); i.filename = "C:/absolute"; files.append((i, b""))'
bad "something else than a file" 'add("bin/x", mode=stat.S_IFLNK | 0o777)'
bad "something else than a file" 'drop("LICENSE"); add("LICENSE", mode=stat.S_IFREG | 0o666)'
bad "something else than a file" 'each(lambda i: setattr(i, "create_system", 0))'
bad "not packed as" 'each(lambda i: setattr(i, "compress_type", zipfile.ZIP_STORED))'
bad "not packed as" 'each(lambda i: setattr(i, "extra", b"\x99\x99\x02\x00ab"))'
bad "not packed as" 'each(lambda i: setattr(i, "comment", b"x"))'
bad "the zip has a comment" 'comment = b"x"'
bad "differs from the checkout" 'put("LICENSE", read("LICENSE") + b"more")'
bad "is not the one of SOURCES.tsv" 'put("share/xless/licenses/curl-8.9.1-COPYING.txt", b"more")'
bad "is empty" 'put("share/xless/licenses/swift-png.txt", b"")'
bad "is no text" 'put("share/xless/licenses/swift-png.txt", b"\0")'
bad "is no text" 'put("share/xless/licenses/swift-png.txt", b"\xff\xfe")'
bad "is a text stub" 'put("share/xless/licenses/swift-png.txt", b"--- !tapi-tbd\n")'
bad "executable code" 'put("share/xless/licenses/swift-png.txt", b"MZ text")'
bad "executable code" 'put("share/xless/licenses/swift-png.txt", b"!<arch>\n")'
bad "VERSION is not" 'put("share/xless/VERSION", b"1.2.4\n")'
for i in swift-crypto swift-png; do bad "missing" "drop('share/xless/licenses/$i.txt')"; done
bad "differs from the checkout" 'put("share/xless/licenses/swift-runtime-CHANGES.txt", b"none\n")'
# What zipfile would not write: the zip's own words on an entry.
raw() {  # what it says, then Python that changes the first entry, LICENSE (at: in the list of entries; local: at its data)
  python3 -I - "$zip" "$t/bad.zip" "$2" <<'P'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
at = data.index(b"PK\1\2"); local, = struct.unpack_from("<I", data, at + 42)
assert data[at + 46:at + 46 + struct.unpack_from("<H", data, at + 28)[0]].endswith(b"/LICENSE")
def put(layout, offset, value): struct.pack_into("<" + layout, data, offset, value)
exec(sys.argv[3])
open(sys.argv[2], "wb").write(data)
P
  check "$t/bad.zip" >/dev/null && fail "accepted: $1 ($2)"
  grep -qF "$1" "$t/err" || fail "refused for something else than '$1': $(cat "$t/err")"
}
raw "LICENSE is not packed as" 'put("H", at + 8, 1); put("H", local + 6, 1)'
raw "LICENSE is not packed as" 'put("H", at + 8, 8); put("H", local + 6, 8)'
raw "LICENSE is too large" 'put("I", at + 24, (256 << 20) + 1); put("I", local + 22, (256 << 20) + 1)'
raw "a name that no file" 'n = data.index(b"/LICENSE", at); m = data.index(b"/LICENSE", local); data[n + 7] = data[m + 7] = 0'
# A link is not packed.
mkdir -p "$t/stage/a"; echo x > "$t/stage/a/file"
python3 -I "$repo/scripts/windows-package.py" pack "$t/stage" "$t/stage.zip" || fail "a stage of files is refused"
ln -s file "$t/stage/a/link"
out=$(python3 -I "$repo/scripts/windows-package.py" pack "$t/stage" "$t/stage.zip" 2>&1) && fail "a link is packed"
grep -qF "a/link is no regular file" <<< "$out" || fail "wrong message: $out"
echo no > "$t/bad.zip"; check "$t/bad.zip" >/dev/null && fail "accepted what is no zip"

# ... and its programs.
image() {  # what it says, the file, then pe.py's words
  local say="$1" file="$2"; shift 2
  pe "$t/image" "$@"
  bad "$say" "put('bin/$file', open('$t/image', 'rb').read())"
}
vc=";VCRUNTIME140.dll:memcpy;VCRUNTIME140_1.dll:__CxxFrameHandler4"
good=(load=a00 "needs=swiftCore.dll:a$vc")
lib=(dll=1 load=a00)
image "is not for x86_64" xless.exe "${good[@]}" machine=aa64
image "is not of 64 bits" xless.exe "${good[@]}" magic=10b
image "is no program" xless.exe "${good[@]}" dll=1
image "is no library" swiftCRT.dll
image "is without HIGH_ENTROPY_VA" xless.exe "${good[@]}" flags=140
image "is without DYNAMIC_BASE" xless.exe "${good[@]}" flags=120
image "is without NX_COMPAT" swiftCRT.dll "${lib[@]}" flags=60
image "needs evil.dll" xless.exe load=a00 "needs=swiftCore.dll:a$vc;evil.dll:b"
image "needs evil.dll" xless.exe load=a00 "needs=swiftCore.dll:a$vc" "delay=evil.dll:b"
image "needs dispatch.dll" swiftCRT.dll "${lib[@]}" "needs=dispatch.dll:b"
image "nothing needs swiftcore.dll swiftcrt.dll" xless.exe load=a00
image "no program of a console" xless.exe "${good[@]}" subsystem=2
image "takes its libraries from elsewhere" xless.exe "needs=swiftCore.dll:a$vc"
image "takes its libraries from elsewhere" xless.exe "needs=swiftCore.dll:a$vc" load=800
image "takes its libraries from elsewhere" xless.exe "${good[@]}" config=79
image "swiftCRT.dll takes its libraries from elsewhere" swiftCRT.dll dll=1
image "swiftCRT.dll takes its libraries from elsewhere" swiftCRT.dll dll=1 load=none
image "swiftCRT.dll takes its libraries from elsewhere" swiftCRT.dll dll=1 load=800
image "names a file of debug information" xless.exe "${good[@]}" codeview=1
for f in CreateProcessW CreateProcessAsUserA ShellExecuteExW WinExec _wsystem system _popen _wspawnl _execvp NtCreateUserProcess ZwCreateProcessEx RtlCreateUserProcess '$s10Foundation7ProcessCACycfC'; do
  image "can start programs: $f" xless.exe load=a00 "needs=swiftCore.dll:a$vc;KERNEL32.dll:ExitProcess,$f"
done
image "does not itself need vcruntime140.dll vcruntime140_1.dll" xless.exe load=a00 "needs=swiftCore.dll:a"
image "does not itself need vcruntime140_1.dll" xless.exe load=a00 "needs=swiftCore.dll:a;VCRUNTIME140.dll:memcpy"
image "names functions by their numbers: kernel32.dll" xless.exe load=a00 "needs=swiftCore.dll:a$vc;KERNEL32.dll:ExitProcess,#"
bad "is no program or library of Windows" 'put("bin/xless.exe", b"#!/bin/sh")'
bad "is no program or library of Windows" 'put("bin/xless.exe", read("bin/xless.exe")[:300])'
bad "is no program or library of Windows" 'put("bin/swiftCore.dll", b"MZ")'
echo "windows-package.test.sh: ok"
