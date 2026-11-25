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
needs=A.dll:f,g;B.dll:#  delay=...  machine=8664  flags=160  dll=0|1  subsystem=3  load=a00  codeview=0|1  magic=20b"""
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
load = int(opts.get("load", "0"), 16)
if load: directories[10] = (add(struct.pack("<I", 0x140) + bytes(74) + struct.pack("<H", load) + bytes(0x140 - 80)), 0x140)
if opts.get("codeview") == "1": directories[6] = (add(struct.pack("<IIHHIIII", 0, 0, 0, 0, 2, 0, 0, 0)), 28)
characteristics = 0x22 | (0x2000 if opts.get("dll", "0") == "1" else 0)
optional = struct.pack("<H", int(opts.get("magic", "20b"), 16)) + bytes(66)
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
xless() { pe "$t/xless.exe" load=a00 "needs=${1:-swiftCore.dll:a,b;KERNEL32.dll:ExitProcess;api-ms-win-crt-runtime-l1-1-0.dll:exit;VCRUNTIME140.dll:memcpy}" "${@:2}"; }
xless
pe "$runtime/swiftCore.dll" dll=1 subsystem=2 "needs=swiftCRT.dll:#;KERNEL32.dll:VirtualAlloc" "delay=dbghelp.dll:SymInitialize"
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
bad "missing" 'drop("share/xless/licenses/curl-COPYING.txt")'
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
bad "is not the one of SOURCES.tsv" 'put("share/xless/licenses/curl-COPYING.txt", b"more")'
bad "is empty" 'put("share/xless/licenses/swift-png.txt", b"")'
bad "is no text" 'put("share/xless/licenses/swift-png.txt", b"\0")'
bad "is no text" 'put("share/xless/licenses/swift-png.txt", b"\xff\xfe")'
bad "is a text stub" 'put("share/xless/licenses/swift-png.txt", b"--- !tapi-tbd\n")'
bad "executable code" 'put("share/xless/licenses/swift-png.txt", b"MZ text")'
bad "executable code" 'put("share/xless/licenses/swift-png.txt", b"!<arch>\n")'
bad "VERSION is not" 'put("share/xless/VERSION", b"1.2.4\n")'
echo no > "$t/bad.zip"; check "$t/bad.zip" >/dev/null && fail "accepted what is no zip"

# ... and its programs.
image() {  # what it says, the file, then pe.py's words
  local say="$1" file="$2"; shift 2
  pe "$t/image" "$@"
  bad "$say" "put('bin/$file', open('$t/image', 'rb').read())"
}
good=(load=a00 "needs=swiftCore.dll:a")
image "is not for x86_64" xless.exe "${good[@]}" machine=aa64
image "is not of 64 bits" xless.exe "${good[@]}" magic=10b
image "is no program" xless.exe "${good[@]}" dll=1
image "is no library" swiftCRT.dll
image "is without HIGH_ENTROPY_VA" xless.exe "${good[@]}" flags=140
image "is without DYNAMIC_BASE" xless.exe "${good[@]}" flags=120
image "is without NX_COMPAT" swiftCRT.dll dll=1 flags=60
image "needs evil.dll" xless.exe load=a00 "needs=swiftCore.dll:a;evil.dll:b"
image "needs evil.dll" xless.exe load=a00 "needs=swiftCore.dll:a" "delay=evil.dll:b"
image "needs dispatch.dll" swiftCRT.dll dll=1 "needs=dispatch.dll:b"
image "nothing needs swiftcore.dll swiftcrt.dll" xless.exe load=a00
image "no program of a console" xless.exe "${good[@]}" subsystem=2
image "takes its libraries from elsewhere" xless.exe "needs=swiftCore.dll:a"
image "takes its libraries from elsewhere" xless.exe "needs=swiftCore.dll:a" load=800
image "names a file of debug information" xless.exe "${good[@]}" codeview=1
for f in CreateProcessW CreateProcessAsUserA ShellExecuteExW WinExec _wsystem system _popen _wspawnl _execvp; do
  image "can start programs: $f" xless.exe load=a00 "needs=swiftCore.dll:a;KERNEL32.dll:ExitProcess,$f"
done
bad "is no program or library of Windows" 'put("bin/xless.exe", b"#!/bin/sh")'
bad "is no program or library of Windows" 'put("bin/xless.exe", read("bin/xless.exe")[:300])'
bad "is no program or library of Windows" 'put("bin/swiftCore.dll", b"MZ")'
echo "windows-package.test.sh: ok"
