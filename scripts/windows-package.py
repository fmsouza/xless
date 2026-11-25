#!/usr/bin/env python3
"""The Windows release package: a zip of xless.exe, of the Swift runtime's DLLs that it needs, and of their licences.

  windows-package.py closure <xless.exe> <runtime-dir>     the DLLs of <runtime-dir> that go beside xless.exe, one per line
  windows-package.py harden <library>...                   has Windows take what these need from beside xless.exe and System32
  windows-package.py pack <stage> <zip>                    <stage>/<name>/ as <name>/... in <zip>
  windows-package.py check <version> <arch> <zip> <root>   refuses a package that holds too much, too little or something else;
                                                           third-party-licenses.sh --os windows --list comes on stdin

A program or library of the package needs nothing but the package's other files and libraries that every Windows has in
System32; the Visual C++ runtime (VC_RUNTIME) is the one thing a person may have to install (docs/native-install.md#windows).
Nothing of Microsoft's is packed. XLESS_STUB=true: the programs may be anything (tests). Standard library only.
"""
import array
import hashlib
import os
import re
import stat
import struct
import sys
import zipfile

ARCHES = {"x86_64": 0x8664}

# What may be packed beside xless.exe, and no more: the Swift runtime's own.
RUNTIME = {name.lower() for name in (
    "swiftCore.dll", "swiftCRT.dll", "swiftDispatch.dll", "swiftSynchronization.dll",
    "swiftWinSDK.dll", "swift_Concurrency.dll", "swift_RegexParser.dll", "swift_StringProcessing.dll", "swiftObservation.dll",
    "Foundation.dll", "FoundationEssentials.dll", "FoundationInternationalization.dll", "FoundationNetworking.dll", "_FoundationICU.dll",
    "dispatch.dll", "BlocksRuntime.dll")}

# Windows' own, in System32 of every Windows that xless runs on.
SYSTEM = {
    "advapi32.dll", "bcrypt.dll", "crypt32.dll", "dbghelp.dll", "iphlpapi.dll", "kernel32.dll", "normaliz.dll", "ole32.dll", "secur32.dll",
    "shell32.dll", "shlwapi.dll", "user32.dll", "userenv.dll", "winhttp.dll", "winmm.dll", "ws2_32.dll"}
API_SET = re.compile(r"api-ms-win-(core|crt)-[a-z0-9-]+\.dll")

# Microsoft's Visual C++ runtime: not Windows' own, and not ours to give away.
VC_RUNTIME = {"vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"}

# What Microsoft's own need of each other, without load flags: where a part of it is missing, msvcp140.dll would bring in another's of that name.
# xless.exe needs them itself, whose load flags are asked first.
VC_RUNTIME_FIRST = {"vcruntime140.dll", "vcruntime140_1.dll"}

# What would start a program: xless on Windows starts none (docs/security.md).
STARTS_PROGRAMS = re.compile(r"CreateProcess|ShellExecute|WinExec|(Nt|Zw|Rtl)Create(User)?Process|\$s10Foundation7Process|_?w?(system|popen|exec[lv]p?e?|spawn[lv]p?e?)$")
BY_NUMBER = {"ws2_32.dll"}  # the only library whose functions a program names by their numbers, which says nothing of what they are

# LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32. They are those of the program or library that has them, and not of
# what that one needs in turn: each has its own.
LOAD_FLAGS = 0xA00


class Refused(Exception):
    pass


def refuse(message):
    raise Refused(message)


class PE:
    """As much of a 64-bit PE file as is asked about."""

    def __init__(self, data, name):
        self.data, self.name = data, name
        try:
            self._read()
        except (struct.error, IndexError, UnicodeDecodeError):
            refuse(f"{name} is no program or library of Windows")

    def _at(self, layout, offset):
        return struct.unpack_from("<" + layout, self.data, offset)

    def _read(self):
        data = self.data
        if data[:2] != b"MZ":
            refuse(f"{self.name} is no program or library of Windows")
        pe, = self._at("I", 0x3C)
        if data[pe:pe + 4] != b"PE\0\0":
            refuse(f"{self.name} is no program or library of Windows")
        self.machine, sections, _, _, _, optional_size, self.characteristics = self._at("HHIIIHH", pe + 4)
        optional = pe + 24
        magic, = self._at("H", optional)
        if magic != 0x20B:
            refuse(f"{self.name} is not of 64 bits")
        self.subsystem, self.dll_characteristics = self._at("HH", optional + 68)
        count, = self._at("I", optional + 108)
        self.directories = [self._at("II", optional + 112 + 8 * i) for i in range(min(count, 16))]
        self.sections = []
        for i in range(sections):
            size, address, raw_size, raw = self._at("IIII", optional + optional_size + 40 * i + 8)
            self.sections.append((address, max(size, raw_size), raw))
        self.imports, self.by_number = {}, set()
        self._descriptors(1, 20, name_at=12, thunks_at=(0, 16))
        self._descriptors(13, 32, name_at=4, thunks_at=(16,))  # what is loaded when it is first called

    def _offset(self, rva):
        for address, size, raw in self.sections:
            if address <= rva < address + size:
                return rva - address + raw
        raise IndexError(rva)

    def _string(self, rva):
        start = self._offset(rva)
        end = self.data.index(b"\0", start) if b"\0" in self.data[start:start + 4096] else None
        if end is None:
            raise IndexError(rva)
        return self.data[start:end].decode("ascii")

    def directory(self, index):
        return self.directories[index] if index < len(self.directories) else (0, 0)

    def _descriptors(self, index, size, name_at, thunks_at):
        rva, _ = self.directory(index)
        if not rva:
            return
        at = self._offset(rva)
        while True:
            name, = self._at("I", at + name_at)
            if not name:
                return
            library = self._string(name).lower()
            functions = self.imports.setdefault(library, set())
            thunks = next((t for t in (self._at("I", at + offset)[0] for offset in thunks_at) if t), 0)
            if thunks:
                entry = self._offset(thunks)
                while True:
                    value, = self._at("Q", entry)
                    if not value:
                        break
                    if value >> 63:
                        self.by_number.add(library)
                    else:
                        functions.add(self._string((value & 0x7FFFFFFF) + 2))
                    entry += 8
            at += size

    def load_flags_at(self):
        """Where the load flags are in the file; None: it has no room for them."""
        rva, size = self.directory(10)
        if not rva or size < 80:
            return None
        at = self._offset(rva)
        return at + 78 if self._at("I", at)[0] >= 80 else None

    def load_flags(self):
        at = self.load_flags_at()
        return 0 if at is None else self._at("H", at)[0]

    def has_codeview(self):
        rva, size = self.directory(6)
        if not rva:
            return False
        at = self._offset(rva)
        return any(self._at("I", at + 28 * i + 12)[0] == 2 for i in range(size // 28))


def of_system(name):
    return name in SYSTEM or name in VC_RUNTIME or API_SET.fullmatch(name) is not None


def closure(program, directory):
    """The names of the libraries in the directory that the program needs, and that those need."""
    present = {name.lower(): name for name in os.listdir(directory)}
    found, waiting = {}, [PE(open(program, "rb").read(), os.path.basename(program))]
    while waiting:
        image = waiting.pop()
        for name in sorted(image.imports):
            if name in found or of_system(name):
                continue
            if name not in RUNTIME:
                refuse(f"{image.name} needs {name}, which is neither Windows' nor the Swift runtime's")
            if name not in present:
                refuse(f"{image.name} needs {name}, which is not in {directory}")
            found[name] = present[name]
            waiting.append(PE(open(os.path.join(directory, present[name]), "rb").read(), present[name]))
    return sorted(found.values())


def harden(path):
    """The library with LOAD_FLAGS, as the linker would have set them: Windows looks for what it needs where those say, and nowhere else."""
    with open(path, "rb") as file:
        data = bytearray(file.read())
    image = PE(bytes(data), os.path.basename(path))
    at = image.load_flags_at()
    if at is None:
        refuse(f"{image.name} has no room for load flags")
    if image.load_flags() not in (0, LOAD_FLAGS):
        refuse(f"{image.name} has load flags of its own ({image.load_flags():#x})")
    if image.directory(4) != (0, 0):
        refuse(f"{image.name} is signed, and would not be any more")
    struct.pack_into("<H", data, at, LOAD_FLAGS)
    pe, = struct.unpack_from("<I", data, 0x3C)
    if struct.unpack_from("<I", data, pe + 88)[0]:  # a checksum: of all words, with its own as 0
        struct.pack_into("<I", data, pe + 88, 0)
        words = array.array("H", bytes(data) + bytes(len(data) % 2))
        if sys.byteorder != "little":
            words.byteswap()
        total = sum(words)
        while total >> 16:
            total = (total & 0xFFFF) + (total >> 16)
        struct.pack_into("<I", data, pe + 88, total + len(data))
    with open(path, "wb") as file:
        file.write(data)


def pack(stage, target):
    names = []
    for base, directories, files in os.walk(stage):
        directories.sort()
        for name in files:
            path = os.path.join(base, name)
            if os.path.islink(path) or not os.path.isfile(path):
                refuse(f"{path} is no regular file")
            names.append((os.path.relpath(path, stage).replace(os.sep, "/"), path))
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as out:
        for name, path in sorted(names):
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as file:
                out.writestr(entry, file.read())


def text(name, data):
    if not data:
        refuse(f"{name} is empty")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        refuse(f"{name} is no text")
    if re.search(rb"[\x00-\x08\x0b\x0e-\x1f\x7f]", data):
        refuse(f"{name} is no text")
    if re.search(rb"(?m)^--- *!tapi-tbd|\"?tapi_tbd_version\"?", data):
        refuse(f"{name} is a text stub of a library")


def check(version, arch, path, root, licences):
    machine = ARCHES.get(arch) or refuse(f"no Windows package for {arch}")
    top = f"xless-{version}-windows-{arch}"
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile):
        refuse(f"{path} cannot be read")
    if archive.comment:
        refuse("the zip has a comment")
    files, seen = {}, set()
    for entry in archive.infolist():
        name = entry.filename
        if not re.fullmatch(r"[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*", entry.orig_filename) or any(p.strip(".") == "" or p.endswith(".") for p in name.split("/")):
            refuse(f"a name that no file of the package has: {entry.orig_filename!r}")
        if name.lower() in seen:
            refuse(f"{name} is there twice")
        seen.add(name.lower())
        if entry.create_system != 3 or entry.external_attr != (stat.S_IFREG | 0o644) << 16:
            refuse(f"{name} is something else than a file that everybody may read and its owner may write")
        if entry.flag_bits & ~0x2 or entry.extra or entry.comment or entry.compress_type != zipfile.ZIP_DEFLATED:
            refuse(f"{name} is not packed as the package's files are")
        if entry.file_size > 256 << 20:
            refuse(f"{name} is too large")
        try:
            files[name] = archive.read(entry)
        except (zipfile.BadZipFile, EOFError, OSError, ValueError) as error:
            refuse(f"{name} cannot be read: {error}")
    want = {f"{top}/{name}" for name in ("LICENSE", "bin/xless.exe", "share/xless/VERSION")}
    kinds = {}
    for line in licences.splitlines():
        name, kind = line.split(" ", 1)
        name = f"{top}/share/xless/licenses/{name}"
        kinds[name] = kind
        if kind != "text?" or name in files:
            want.add(name)
    libraries = {name for name in files if re.fullmatch(re.escape(top) + r"/bin/[^/]+", name) and name.rsplit("/", 1)[1].lower() in RUNTIME}
    if want - set(files):
        refuse("missing: " + " ".join(sorted(want - set(files))))
    if set(files) - want - libraries:
        refuse("too much: " + " ".join(sorted(set(files) - want - libraries)))

    if files[f"{top}/share/xless/VERSION"].decode("utf-8", "replace") != version + "\n":
        refuse(f"share/xless/VERSION is not {version}")
    def same(name, source):
        with open(os.path.join(root, source), "rb") as file:
            if file.read() != files[name]:
                refuse(f"{name} differs from the checkout's")
    same(f"{top}/LICENSE", "LICENSE")
    for name, kind in kinds.items():
        if name not in files:
            continue
        if kind in ("text", "text?"):
            text(name, files[name])
        elif "/" in kind:
            same(name, kind)
        elif hashlib.sha256(files[name]).hexdigest() != kind:
            refuse(f"{name} is not the one of SOURCES.tsv")
    magics = (b"MZ", b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"!<arch>")
    for name in set(files) - libraries - {f"{top}/bin/xless.exe"}:
        if files[name].startswith(magics):
            refuse(f"{name} is executable code")

    if os.environ.get("XLESS_STUB") != "true":
        images = {name.rsplit("/", 1)[1].lower(): PE(files[name], name.rsplit("/", 1)[1]) for name in libraries | {f"{top}/bin/xless.exe"}}
        for name, image in images.items():
            program = name == "xless.exe"
            if image.machine != machine:
                refuse(f"{image.name} is not for {arch}")
            if bool(image.characteristics & 0x2000) == program:
                refuse(f"{image.name} is no {'program' if program else 'library'}")
            for flag, what in ((0x20, "HIGH_ENTROPY_VA"), (0x40, "DYNAMIC_BASE"), (0x100, "NX_COMPAT")):
                if not image.dll_characteristics & flag:
                    refuse(f"{image.name} is without {what}")
            if image.load_flags() != LOAD_FLAGS:
                refuse(f"{image.name} takes its libraries from elsewhere than xless.exe's directory and System32 ({image.load_flags():#x})")
            for needed in image.imports:
                if needed not in images and not of_system(needed):
                    refuse(f"{image.name} needs {needed}, which is neither in the package nor Windows'")
        needed, waiting = {"xless.exe"}, ["xless.exe"]
        while waiting:
            for name in images[waiting.pop()].imports:
                if name in images and name not in needed:
                    needed.add(name)
                    waiting.append(name)
        if set(images) - needed:
            refuse("nothing needs " + " ".join(sorted(set(images) - needed)))
        xless = images["xless.exe"]
        if xless.subsystem != 3:
            refuse("xless.exe is no program of a console")
        if xless.has_codeview():
            refuse("xless.exe names a file of debug information")
        starts = sorted(f for functions in xless.imports.values() for f in functions if STARTS_PROGRAMS.match(f))
        if starts:
            refuse("xless.exe can start programs: " + " ".join(starts))
        if any(set(image.imports) & VC_RUNTIME for image in images.values()) and VC_RUNTIME_FIRST - set(xless.imports):
            refuse("xless.exe does not itself need " + " ".join(sorted(VC_RUNTIME_FIRST - set(xless.imports))))
        if xless.by_number - BY_NUMBER:
            refuse("xless.exe names functions by their numbers: " + " ".join(sorted(xless.by_number - BY_NUMBER)))
    for name in sorted(files):
        print(name)


def main(arguments):
    try:
        if len(arguments) == 3 and arguments[0] == "closure":
            print("\n".join(closure(*arguments[1:])))
        elif len(arguments) >= 2 and arguments[0] == "harden":
            for path in arguments[1:]:
                harden(path)
        elif len(arguments) == 3 and arguments[0] == "pack":
            pack(*arguments[1:])
        elif len(arguments) == 5 and arguments[0] == "check":
            check(*arguments[1:], sys.stdin.read())
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Refused as refused:
        print(f"windows-package: {refused}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(newline="\n")
    sys.exit(main(sys.argv[1:]))
