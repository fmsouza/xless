# What scripts/arch-compare.sh and scripts/pack-parity.sh compare of a built app: every file outside the bundles'
# _CodeSignature/ directories, and of a Mach-O image its bytes without the code signature. Loaded by those scripts
# (importlib, from this directory); not run by itself.
import os
import struct


def files(root):
    """{relative path: path} of every file and symbolic link under root, outside any _CodeSignature/ directory."""
    out = {}
    for d, dirs, names in os.walk(root):
        dirs[:] = [n for n in dirs if n != "_CodeSignature" or os.path.islink(os.path.join(d, n))]
        for n in dirs + names:
            p = os.path.join(d, n)
            if n in names or os.path.islink(p):
                out[os.path.relpath(p, root)] = p
    return out


def masked_thin(data):
    """A thin 64-bit little-endian Mach-O without its LC_CODE_SIGNATURE data, that command's offset and size, and
    __LINKEDIT's file and VM size, which the signature's length moves. Anything else is returned as it is."""
    data = bytearray(data)
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xfeedfacf:
        return bytes(data)
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, sig = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x1d:                                   # LC_CODE_SIGNATURE: dataoff, datasize
            sig = struct.unpack_from("<II", data, off + 8)
            struct.pack_into("<II", data, off + 8, 0, 0)
        elif cmd == 0x19 and data[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            struct.pack_into("<Q", data, off + 32, 0)     # vmsize
            struct.pack_into("<Q", data, off + 48, 0)     # filesize
        off += size
    if sig:
        del data[sig[0]:sig[0] + sig[1]]
    return bytes(data)


def fat_slices(data):
    """[(cputype, offset, size)] of a fat (universal) Mach-O file, or None when data is not one."""
    if len(data) < 8 or struct.unpack_from(">I", data, 0)[0] != 0xcafebabe:
        return None
    count = struct.unpack_from(">I", data, 4)[0]
    if not 0 < count < 20 or len(data) < 8 + 20 * count:       # (a Java class file starts with the same magic)
        return None
    out = []
    for i in range(count):
        cputype, _, offset, size, _ = struct.unpack_from(">iiIII", data, 8 + 20 * i)
        if offset + size > len(data):
            return None
        out.append((cputype, offset, size))
    return out


def masked(path):
    """The file's bytes; a symbolic link as its target; a Mach-O image without its code signature (a fat file slice by
    slice: its header with each slice's offset and size zeroed, then each slice without its signature, in order)."""
    if os.path.islink(path):
        return b"link:" + os.readlink(path).encode()
    data = open(path, "rb").read()
    slices = fat_slices(data)
    if slices is None:
        return masked_thin(data)
    head = bytearray(data[:8 + 20 * len(slices)])
    for i in range(len(slices)):
        struct.pack_into(">II", head, 8 + 20 * i + 8, 0, 0)
    return bytes(head) + b"".join(masked_thin(data[o:o + n]) for _, o, n in slices)
