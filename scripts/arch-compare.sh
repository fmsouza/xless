#!/usr/bin/env bash
# Compares two finished .app directories built from one project on hosts of different architectures (an arm64 and an
# amd64 build container): the output must not depend on the host.
# Usage: scripts/arch-compare.sh <app-a> <app-b>
#   1. prints `xless tauri report` (the summary reference.json is made of) of each app and diffs the two;
#   2. lists every file whose bytes differ outside the bundles' _CodeSignature/ directories and the Mach-O code-signature
#      blob (a file in only one app counts as different). A Mach-O image is compared without its LC_CODE_SIGNATURE data,
#      that command's offset and size, and __LINKEDIT's file and VM size, which the signature's length moves; a fat file
#      slice by slice (scripts/code-signature-mask.py, which scripts/pack-parity.sh uses too).
# Exit: 0 identical, 1 a summary or byte difference, 2 usage. XLESS: the xless binary (default: `xless` on PATH, else the
# host build `swift build --product xless`).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -eq 2 ]] || { echo "usage: $0 <app-a> <app-b>" >&2; exit 2; }
for d in "$1" "$2"; do [[ -d "$d" ]] || { echo "arch-compare: $d is not a directory" >&2; exit 2; }; done
a="$(cd "$1" && pwd)"; b="$(cd "$2" && pwd)"
x="${XLESS:-}"
if [[ -z "$x" ]]; then
  if command -v xless >/dev/null 2>&1; then x=xless
  else (cd "$repo" && swift build --product xless -q) && x="$(cd "$repo" && swift build --show-bin-path)/xless"; fi
fi
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
rc=0

"$x" tauri report "$a" --json "$t/a.json" >/dev/null
"$x" tauri report "$b" --json "$t/b.json" >/dev/null
echo "==> summary of $a"; cat "$t/a.json"; echo
echo "==> summary of $b"; cat "$t/b.json"; echo
if diff -u "$t/a.json" "$t/b.json" >"$t/summary.diff"; then
  echo "==> summaries are identical"
else
  echo "==> summaries differ:"; cat "$t/summary.diff"; rc=1
fi

echo "==> bytes outside _CodeSignature/ and the Mach-O code-signature blob"
if python3 -I - "$a" "$b" "$repo/scripts/code-signature-mask.py" <<'PY'
import importlib.util, os, sys

spec = importlib.util.spec_from_file_location("code_signature_mask", sys.argv[3])
mask = importlib.util.module_from_spec(spec); spec.loader.exec_module(mask)
files, masked = mask.files, mask.masked

fa, fb = files(sys.argv[1]), files(sys.argv[2])
bad = []
for rel in sorted(set(fa) | set(fb)):
    if rel not in fa:
        bad.append((rel, "only in the second app"))
    elif rel not in fb:
        bad.append((rel, "only in the first app"))
    elif masked(fa[rel]) != masked(fb[rel]):
        bad.append((rel, "bytes differ"))
for rel, why in bad:
    print(f"  {rel}: {why}")
print(f"  {len(bad)} difference(s) in {len(set(fa) | set(fb))} files")
sys.exit(1 if bad else 0)
PY
then :; else rc=1; fi
[[ $rc == 0 ]] && echo "==> identical" || echo "==> DIFFERENT" >&2
exit $rc
