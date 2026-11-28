#!/usr/bin/env bash
# Compares two trees of built products, file by file: one built in an image with an Xcode baked in (the baseline), one built
# with that Xcode's pack (the candidate). The pack moved three directories, and a product may record where they were:
#   the SDK      /opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle  ->  /xcodes/<pack>/config/swiftpm/swift-sdks/darwin.artifactbundle
#   Swift        /opt/xless/toolchains/swift-<version>                       ->  /xcodes/<pack>/toolchain
#                (or, where the baked image's Swift was its own, at /, the empty prefix of /usr/lib/swift[-<v>]/<platform>)
#   Swift Build  /opt/swift-build                                            ->  /xcodes/<pack>/swift-build
# (<pack> is <version>-<build>-<arch>, e.g. 27.0-27A266a-arm64). Every file is compared outside the bundles' _CodeSignature/
# directories and the Mach-O code-signature blob (scripts/code-signature-mask.py, as scripts/arch-compare.sh does); a fat
# file slice by slice. A file that still differs is "path only" when its differences are those paths and nothing else,
# proven by the first of these that applies:
#   same length    each old path in the baseline and each new one in the candidate is replaced by a placeholder of its
#                  length, and the two are then equal;
#   substituted    the lengths differ: the baseline with each old path replaced by the new one, in order, IS the candidate,
#                  byte for byte (so nothing moved around them);
#   Mach-O         every path is in a load command that holds a string (LC_RPATH, LC_LOAD_DYLIB, ...) or in LC_SYMTAB's
#                  string table, and the two images are equal once the paths are replaced in those strings, leaving out
#                  only what follows from their lengths (sizeofcmds, those commands' sizes, strsize, each symbol's offset
#                  into the string table) and LC_UUID, the linker's hash of the file, which is listed; the header's padding
#                  must be all zero and every section in place.
# Only a path as a whole is replaced (it ends where a name cannot go on), only where it occurs (the old in the baseline, the
# new in the candidate), and the n-th old path must be the same directory as the n-th new one, all in one pack. Anything
# else is not masked: it differs, and the output says so, whether its printable strings (runs of 4 or more) are the same
# once the paths are replaced and, in a Mach-O image, where its first section starts in each: evidence for a human
# (otool, nm, llvm-dwarfdump), not a pass.
# Every masked occurrence is listed: its offset in the baseline and in the candidate, in the bytes as compared (without the
# code signature) and where it is (a load command, the string table, or a section).
# Usage: scripts/pack-parity.sh <baseline dir> <candidate dir>
# Exit: 0 the same (identical, or path only), 1 any other difference or a file in one tree only, 2 usage or two trees
# with no file (nothing was compared).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -eq 2 ]] || { echo "usage: $0 <baseline dir> <candidate dir>" >&2; exit 2; }
for d in "$1" "$2"; do [[ -d "$d" ]] || { echo "pack-parity: $d is not a directory" >&2; exit 2; }; done
a="$(cd "$1" && pwd)"; b="$(cd "$2" && pwd)"
echo "==> baseline $a"
echo "==> candidate $b"
exec python3 -I - "$a" "$b" "$repo/scripts/code-signature-mask.py" <<'PY'
import importlib.util, os, re, struct, sys

spec = importlib.util.spec_from_file_location("code_signature_mask", sys.argv[3])
mask = importlib.util.module_from_spec(spec); spec.loader.exec_module(mask)

END = rb"(?![A-Za-z0-9_.+-])"            # the path ends here: a name cannot go on
PLATFORMS = rb"(?:iphoneos|iphonesimulator|macosx|appletvos|appletvsimulator|watchos|watchsimulator|xros|xrsimulator)"
PACK = rb"/xcodes/([0-9]+(?:\.[0-9]+)*-[0-9A-Za-z]+-(?:arm64|amd64))"
OLD = [("sdk", re.compile(rb"/opt/xless/config/swiftpm/swift-sdks/darwin\.artifactbundle" + END)),
       ("swift", re.compile(rb"/opt/xless/toolchains/swift-[0-9]+(?:\.[0-9]+)*" + END)),
       # the image's own Swift, at /, when it was the Xcode's: its root is the empty prefix of its per-platform
       # libraries (/usr/lib/swift[-<version>]/<platform>, which no Apple OS has), at the start of a path
       ("swift", re.compile(rb"(?<![A-Za-z0-9_.+/-])(?=/usr/lib/swift(?:-[0-9]+(?:\.[0-9]+)*)?/" + PLATFORMS + END + rb")")),
       ("swift-build", re.compile(rb"/opt/swift-build" + END))]
NEW = [("sdk", re.compile(PACK + rb"/config/swiftpm/swift-sdks/darwin\.artifactbundle" + END)),
       ("swift", re.compile(PACK + rb"/toolchain" + END)),
       ("swift-build", re.compile(PACK + rb"/swift-build" + END))]
NEW_TEXT = {"sdk": b"/xcodes/%s/config/swiftpm/swift-sdks/darwin.artifactbundle", "swift": b"/xcodes/%s/toolchain",
            "swift-build": b"/xcodes/%s/swift-build"}
TAIL = re.compile(rb"[^\0\s\"'<>|;:,]*")  # the rest of a path, for the listing

def occurrences(data, table):
    """[(offset, kind, text, pack)] of every path of the table in data, in order."""
    out = []
    for kind, rx in table:
        for m in rx.finditer(data):
            out.append((m.start(), kind, m.group(0), m.group(1) if rx.groups else None))
    out.sort()
    return out

def replaced(data, occ, by):
    """data with each occurrence replaced by by(i, occurrence)."""
    parts, at = [], 0
    for i, (off, _, text, _) in enumerate(occ):
        parts += [data[at:off], by(i, (off, text))]
        at = off + len(text)
    parts.append(data[at:])
    return b"".join(parts)

def strings(data):
    return re.findall(rb"[\x20-\x7e]{4,}", data)

# Load commands that carry a path (an lc_str: its offset at +8, the string up to cmdsize, NUL-padded).
LC_STR = {0xc: "LC_LOAD_DYLIB", 0xd: "LC_ID_DYLIB", 0xe: "LC_LOAD_DYLINKER", 0x20: "LC_LAZY_LOAD_DYLIB",
          0x80000018: "LC_LOAD_WEAK_DYLIB", 0x8000001c: "LC_RPATH", 0x8000001f: "LC_REEXPORT_DYLIB",
          0x80000023: "LC_LOAD_UPWARD_DYLIB"}
LC_NAME = {**LC_STR, 0x19: "LC_SEGMENT_64", 0x2: "LC_SYMTAB", 0xb: "LC_DYSYMTAB", 0x1d: "LC_CODE_SIGNATURE",
           0x32: "LC_BUILD_VERSION", 0x80000028: "LC_MAIN", 0x1b: "LC_UUID"}

def is_macho(data):
    return len(data) >= 32 and struct.unpack_from("<I", data, 0)[0] == 0xfeedfacf

def commands(data):
    """[(offset, cmd, size)] of a thin 64-bit Mach-O's load commands."""
    out, off = [], 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        cmd, size = struct.unpack_from("<II", data, off)
        out.append((off, cmd, size)); off += size
    return out

def regions(data):
    """[(start, end, name)] of a thin 64-bit Mach-O: its load commands, sections and segments, by offset."""
    out = []
    for off, cmd, size in commands(data):
        out.append((off, off + size, f"load command {LC_NAME.get(cmd, hex(cmd))}"))
        if cmd == 0x19:
            seg = data[off + 8:off + 24].rstrip(b"\0").decode(errors="replace")
            fileoff, filesize = struct.unpack_from("<QQ", data, off + 40)
            for k in range(struct.unpack_from("<I", data, off + 64)[0]):
                s = off + 72 + 80 * k
                size_, = struct.unpack_from("<Q", data, s + 40)
                foff, = struct.unpack_from("<I", data, s + 48)
                sect = data[s:s + 16].rstrip(b"\0").decode(errors="replace")
                if foff:
                    out.append((foff, foff + size_, f"{seg},{sect}"))
            out.append((fileoff, fileoff + filesize, seg))
    return out

def where(data, offset):
    if not is_macho(data):
        return ""
    st = symtab(data)
    if st and st[2] <= offset < st[2] + st[3]:
        return " [string table]"
    found = [(e - s, name) for s, e, name in regions(data) if s <= offset < e]
    return f" [{min(found)[1]}]" if found else ""

def symtab(data):
    """(symoff, nsyms, stroff, strsize, offset of the command) of a thin Mach-O's LC_SYMTAB, or None."""
    for off, cmd, size in commands(data):
        if cmd == 0x2:
            return struct.unpack_from("<IIII", data, off + 8) + (off,)
    return None

def canonical(data, subst, uuid):
    """A thin Mach-O (its code signature masked) with the paths it records put through subst, and nothing that their
    lengths move:
    - in the load commands: no sizeofcmds, no cmdsize or padding of a command with a path (LC_RPATH, LC_LOAD_DYLIB, ...),
      and the header padding (from the end of the load commands to the first section) only as 'all zero' when it is;
    - in the symbol table: each entry's name in place of its offset in the string table (n_strx), no strsize, and the
      string table as its text, without the zeros that pad it; the string table must be the last thing in the file;
    - LC_UUID's value is left out and appended to uuid: ld64.lld computes it as a hash of the file's own bytes, so it
      changes with any byte, the path among them.
    Every other byte is kept as it is, in place. None when the file is not laid out like that."""
    st = symtab(data)
    first = min([s for s, e, n in regions(data) if "," in n and e > s] or [len(data)])
    parts = [data[:20], data[24:32]]
    for off, cmd, size in commands(data):
        if cmd in LC_STR:
            at, = struct.unpack_from("<I", data, off + 8)
            text, _, pad = data[off + at:off + size].partition(b"\0")
            if not 12 <= at <= size or any(pad):
                return None
            parts += [struct.pack("<II", cmd, at), data[off + 12:off + at], b"<", subst(text), b">"]
        elif cmd == 0x1b:                                   # LC_UUID
            uuid.append(data[off + 8:off + 24]); parts.append(data[off:off + 8])
        elif cmd == 0x2:                                    # LC_SYMTAB without strsize
            parts.append(data[off:off + 20])
        else:
            parts.append(data[off:off + size])
    end = 32 + struct.unpack_from("<I", data, 20)[0]
    pad = data[end:first]
    parts.append(b"[padding all zero]" if not any(pad) else b"[padding]" + pad)
    if st is None:
        return b"".join(parts + [data[first:]])
    symoff, nsyms, stroff, strsize, _ = st
    if not (first <= symoff and symoff + 16 * nsyms <= stroff and stroff + strsize <= len(data)) or any(data[stroff + strsize:]):
        return None
    strings_ = data[stroff:stroff + strsize]
    parts.append(data[first:symoff])
    for i in range(nsyms):                                  # nlist_64: n_strx, n_type, n_sect, n_desc, n_value
        e = symoff + 16 * i
        strx, = struct.unpack_from("<I", data, e)
        parts += [data[e + 4:e + 16], b"<", subst(strings_[strx:strings_.index(b"\0", strx)] if strx < strsize else b"?"), b">"]
    parts += [data[symoff + 16 * nsyms:stroff], b"[strings]", subst(strings_.rstrip(b"\0"))]
    return b"".join(parts)

def macho_paths(a, b, oa, ob, pack, label):
    """The baseline and the candidate are the same Mach-O once the moved paths it records are replaced: every occurrence
    is in a load command with a path or in the symbol table's string table, and canonical() of both is equal. None when
    they are not; else (where the paths are, the listing of the UUIDs that differ)."""
    if not (is_macho(a) and is_macho(b)):
        return None
    def place(data, o):
        st = symtab(data)
        if st and st[2] <= o < st[2] + st[3]:
            return "strings"
        for s, e, n in regions(data):
            if s <= o < e and n.startswith("load command ") and n[13:] in LC_STR.values():
                return "load commands"
        return None
    places = {place(a, o) for o, *_ in oa} | {place(b, o) for o, *_ in ob}
    if None in places:
        return None
    sub = lambda text: replaced(text, occurrences(text, OLD), lambda i, o: NEW_TEXT[occurrences(text, OLD)[i][1]] % pack)
    ua, ub = [], []
    ca, cb = canonical(a, sub, ua), canonical(b, lambda text: text, ub)
    if ca is None or ca != cb:
        return None
    where_ = " and ".join(sorted("the symbol table's strings" if p == "strings" else p for p in places))
    return where_, [f"    {label}LC_UUID {x.hex()} -> {y.hex()} (the linker's hash of the file)" for x, y in zip(ua, ub) if x != y]

def show(data, off, text):
    return (text + TAIL.match(data, off + len(text)).group(0)).decode(errors="replace")

def compare_bytes(a, b, label):
    """(verdict, listing) of two masked images or files."""
    if a == b:
        return "identical", []
    oa, ob = occurrences(a, OLD), occurrences(b, NEW)
    if not oa and not ob:
        return "differs: no moved path in it", []
    if [k for _, k, _, _ in oa] != [k for _, k, _, _ in ob]:
        return (f"differs: its moved paths do not correspond (baseline {[k for _, k, _, _ in oa]}, "
                f"candidate {[k for _, k, _, _ in ob]})"), []
    packs = sorted({p for *_, p in ob})
    if len(packs) != 1:
        return f"differs: the candidate names more than one pack ({', '.join(p.decode() for p in packs)})", []
    lines = [f"    {label}0x{x:x} {show(a, x, ta)} -> 0x{y:x} {show(b, y, tb)}{where(a, x) or where(b, y)}"
             for (x, _, ta, _), (y, _, tb, _) in zip(oa, ob)]
    if all(len(ta) == len(tb) for (_, _, ta, _), (_, _, tb, _) in zip(oa, ob)):
        hide = lambda i, o: b"\0" * len(o[1])
        if replaced(a, oa, hide) == replaced(b, ob, hide):
            return f"path only (same length, {len(oa)} occurrence(s))", lines
        return f"differs outside its {len(oa)} moved path(s) (same length)", []
    if replaced(a, oa, lambda i, o: ob[i][2]) == b:
        return f"path only (substituted, {len(oa)} occurrence(s))", lines
    found = macho_paths(a, b, oa, ob, packs[0], label)
    if found is not None:
        return (f"path only (Mach-O: {len(oa)} occurrence(s) in {found[0]}{', and LC_UUID' if found[1] else ''}; "
                f"every other byte identical)"), lines + found[1]
    same_strings = strings(replaced(a, oa, lambda i, o: ob[i][2])) == strings(b)
    moved = ""
    if is_macho(a) and is_macho(b):
        fa_, fb_ = (min([s for s, e, n in regions(d) if "," in n and e > s] or [0]) for d in (a, b))
        if fa_ != fb_:
            moved = f"; its first section is at 0x{fa_:x} in the baseline and 0x{fb_:x} in the candidate"
    return (f"differs: the baseline with its {len(oa)} moved path(s) replaced is not the candidate, and the lengths differ "
            f"(not masked; its printable strings are {'the same' if same_strings else 'not the same'} once they are{moved})"), lines

CPU = {0x01000007: "x86_64", 0x0100000c: "arm64"}

def compare(pa, pb):
    """(verdict, listing) of two files: a fat Mach-O slice by slice, anything else as a whole."""
    a, b = mask.masked(pa), mask.masked(pb)
    if a == b:
        return "identical", []
    ra, rb = (b"" if os.path.islink(p) else open(p, "rb").read() for p in (pa, pb))
    fa_, fb_ = mask.fat_slices(ra), mask.fat_slices(rb)
    if fa_ is None or fb_ is None:
        return compare_bytes(a, b, "")
    if [c for c, _, _ in fa_] != [c for c, _, _ in fb_] or a[:8 + 20 * len(fa_)] != b[:8 + 20 * len(fb_)]:
        return "differs: not the same slices (the fat header, its offsets and sizes left out)", []
    verdicts, lines = [], []
    for (cpu, oa_, na), (_, ob_, nb) in zip(fa_, fb_):
        v, l = compare_bytes(mask.masked_thin(ra[oa_:oa_ + na]), mask.masked_thin(rb[ob_:ob_ + nb]),
                             f"{CPU.get(cpu & 0xffffffff, hex(cpu))} slice ")
        verdicts.append(v); lines += l
    bad = [v for v in verdicts if not (v == "identical" or v.startswith("path only"))]
    if bad:
        return bad[0], lines
    if all(v == "identical" for v in verdicts):        # the slices are, so the difference is in the fat header
        return "differs: in the fat header", []
    return f"path only ({len(fa_)} slices: " + "; ".join(verdicts) + ")", lines

fa, fb = mask.files(sys.argv[1]), mask.files(sys.argv[2])
if not fa and not fb:
    print(f"pack-parity: no file to compare: {sys.argv[1]} and {sys.argv[2]} hold none", file=sys.stderr); sys.exit(2)
counts = {"identical": 0, "path only": 0, "differ": 0}
for rel in sorted(set(fa) | set(fb)):
    if rel not in fb:
        print(f"  {rel}: only in the baseline"); counts["differ"] += 1; continue
    if rel not in fa:
        print(f"  {rel}: only in the candidate"); counts["differ"] += 1; continue
    verdict, lines = compare(fa[rel], fb[rel])
    if verdict == "identical":
        counts["identical"] += 1; continue
    print(f"  {rel}: {verdict}")
    for line in lines:
        print(line)
    counts["path only" if verdict.startswith("path only") else "differ"] += 1
total = sum(counts.values())
plural = "" if total == 1 else "s"
print(f"==> {total} file{plural}: {counts['identical']} identical, {counts['path only']} path only, {counts['differ']} differ")
if counts["differ"]:
    sys.stdout.flush(); print("==> DIFFERENT", file=sys.stderr); sys.exit(1)
print("==> the same" + (" (path only where listed)" if counts["path only"] else ", file for file"))
PY
