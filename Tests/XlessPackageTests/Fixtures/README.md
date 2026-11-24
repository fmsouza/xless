#!/bin/sh
# The deterministic reference tree (Contents/) has three files — MacOS/LightCraft
# ("hello-lightcraft\n"), Resources/data.bin (bytes 0..255 x16) and Resources/sub/readme.txt
# ("readme\n") — with every mtime set to 2026-01-01 00:00 UTC (touch -t 202601010000.00).
#
# reference.bom: the path-only `mkbom -s . reference.bom` output of a directory holding this
#   Contents/ plus the output of an earlier run (hence the ./reference.bom entry).
# reference-full.bom: the metadata-bearing `mkbom $(mktemp -d; cp -R reference-tree/Contents …)` —
#   regenerate with: mkbom reference-tree/Contents reference-full.bom
#
# dmg/early.hfs.gz, dmg/late.hfs.gz: the HFS+ volume DmgBuilder makes (before `dmg build`), by hfsprogs' mkfs.hfsplus
#   (jammy) and libdmg-hfsplus's `hfsplus` (versions.env LIBDMG_HFSPLUS_COMMIT), on x86_64. The same tree twice, two
#   seconds apart, the second under umask 002, so they differ only in the tools' dates and mkfs's random volume UUID.
#   4153 KiB, like DmgBuilder.sizeKB, is not a whole number of 4 KiB blocks: mkfs writes the alternate volume header at
#   the end of the file and libdmg another at the end of the last block. Regenerate in a container with those tools
#   (HFSPlusDatesTests' source dates are its own, not the tree's):
#     image() { s=$w/$1/stage; a="$s/Hello Tauri.app"
#       mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources" "$a/Contents/Frameworks/F.framework/Versions/A"
#       printf bin > "$a/Contents/MacOS/x"; chmod 700 "$a/Contents/MacOS/x"
#       printf fw > "$a/Contents/Frameworks/F.framework/Versions/A/F"; printf cv > "$a/Contents/Resources/Résumé.txt"
#       ln -s A "$a/Contents/Frameworks/F.framework/Versions/Current"
#       ln -s Versions/Current/F "$a/Contents/Frameworks/F.framework/F"; chmod -R u=rwX,go=rX "$s"
#       dd if=/dev/zero of=$w/$1/img.hfs bs=1k count=4153 status=none; mkfs.hfsplus -v "Hello Tauri é" $w/$1/img.hfs
#       hfsplus --symlinks clone_link --special-modes no $w/$1/img.hfs addall "$s"
#       hfsplus $w/$1/img.hfs symlink /Applications /Applications; gzip -9n < $w/$1/img.hfs > dmg/$1.hfs.gz; }
#     w=$(mktemp -d); umask 022; image early; sleep 2; umask 002; image late
