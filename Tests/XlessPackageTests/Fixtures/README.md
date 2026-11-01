#!/bin/sh
# The deterministic reference tree (Contents/) has three files — MacOS/LightCraft
# ("hello-lightcraft\n"), Resources/data.bin (bytes 0..255 x16) and Resources/sub/readme.txt
# ("readme\n") — with every mtime set to 2026-01-01 00:00 UTC (touch -t 202601010000.00).
#
# reference.bom: the path-only `mkbom -s . reference.bom` output of a directory holding this
#   Contents/ plus the output of an earlier run (hence the ./reference.bom entry).
# reference-full.bom: the metadata-bearing `mkbom $(mktemp -d; cp -R reference-tree/Contents …)` —
#   regenerate with: mkbom reference-tree/Contents reference-full.bom
