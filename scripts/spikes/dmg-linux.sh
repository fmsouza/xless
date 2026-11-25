#!/usr/bin/env bash
# SPIKE (m2c Task 3): build a Developer ID signed DMG of an existing macOS .app on Linux, without hdiutil.
# Kept as executable documentation of the sequence DmgBuilder automates. It is not part of xless and is not run by
# CI. Findings: docs/research/tauri-ios-contract.md, "macOS DMG — spike findings".
#
# Runs inside xless:<tag> (mkfs.hfsplus from hfsprogs, dmg + hfsplus from libdmg-hfsplus, rcodesign). Nothing
# is written into the repo: the input .app is mounted read-only and every output goes to $SPIKE_OUT.
#
#   docker --context colima-xless run --rm \
#     -v <dir holding the unsigned .app>:/in:ro -v <scratch out dir>:/out \
#     -v <Developer ID key PEM>:/secrets/devid-key.pem:ro -v <Developer ID cert PEM>:/secrets/devid-cert.pem:ro \
#     -v "$PWD/scripts/spikes":/spike:ro xless:local-arm64-xcode27.0 /spike/dmg-linux.sh
#
# The key is mounted only into this container, which runs nothing but this script, rcodesign and the DMG tools on
# our own sample app (no third-party build code). Notarization is NOT done here; see the contract doc.
#
# Env: SPIKE_STEPS   space-separated subset of: stage sign dmg signdmg (default: all, in that order)
#      SPIKE_APP     input .app (default: the only *.app in /in)
#      SPIKE_OUT     output dir (default /out)
#      SPIKE_TMP     container-local work dir for the staged .app and the raw volume (default /tmp/dmg-linux); kept
#                    off the host mount because Colima's macOS file sharing reports 0700/0600 modes in the container
#      SPIKE_VOLUME  volume name (default: the .app's name without .app)
#      SPIKE_DMG     output file name (default <volume>_1.0.0_universal.dmg, Tauri's <productName>_<version>_universal)
#      SPIKE_KEY / SPIKE_CERT   Developer ID Application key and certificate PEMs (default /secrets/devid-{key,cert}.pem)
#
# Outputs in $SPIKE_OUT: <dmg> (signed UDZO DMG), addall.log and dmg-build.log (tool output), dmg-linux.log (every
# command and its output). Steps after `stage` expect $SPIKE_TMP from the same container run.
set -euo pipefail

STEPS="${SPIKE_STEPS:-stage sign dmg signdmg}"
OUT="${SPIKE_OUT:-/out}"
APP_IN="${SPIKE_APP:-$(find /in -maxdepth 1 -type d -name '*.app' | head -1)}"
[[ -n "$APP_IN" && -d "$APP_IN" ]] || { echo "dmg-linux: no input .app (set SPIKE_APP or mount a dir with one at /in)" >&2; exit 2; }
APP_NAME="$(basename "$APP_IN")"
VOLUME="${SPIKE_VOLUME:-${APP_NAME%.app}}"
DMG="$OUT/${SPIKE_DMG:-${VOLUME}_1.0.0_universal.dmg}"
KEY="${SPIKE_KEY:-/secrets/devid-key.pem}"
CERT="${SPIKE_CERT:-/secrets/devid-cert.pem}"
TMPW="${SPIKE_TMP:-/tmp/dmg-linux}"
STAGE="$TMPW/stage"
IMG="$TMPW/img.hfs"
mkdir -p "$OUT" "$TMPW"
exec > >(tee -a "$OUT/dmg-linux.log") 2>&1
run() { echo "+ $*"; "$@"; }
has() { [[ " $STEPS " == *" $1 "* ]]; }

if has stage; then
  echo "==> stage: copy $APP_IN"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  run cp -R "$APP_IN" "$STAGE/"
  # Normalise modes the way create-dmg ends up (dirs and executables 755, other files 644); hfsplus addall copies
  # each file's st_mode into the volume as is.
  run chmod -R u=rwX,go=rX "$STAGE"
fi

if has sign; then
  # Same flags as xless's Developer ID path (RCodesign.signArguments, distribution developerID), minus the
  # entitlements file: this sample has no entitlements and no provisioning profile.
  echo "==> sign: Developer ID + hardened runtime"
  run rcodesign sign --pem-file "$KEY" --pem-file "$CERT" --code-signature-flags runtime --for-notarization \
    "$STAGE/$APP_NAME"
  run rcodesign verify "$STAGE/$APP_NAME/Contents/MacOS/$(ls "$STAGE/$APP_NAME/Contents/MacOS" | head -1)" || true
fi

if has dmg; then
  echo "==> dmg: HFS+ volume '$VOLUME' → $DMG"
  rm -f "$IMG" "$DMG"
  # Content size + 30 % + 4 MiB for the catalog/extents B-trees and the journal-less volume headers.
  SIZE=$(( $(du -sk "$STAGE" | cut -f1) * 13 / 10 + 4096 ))
  run dd if=/dev/zero of="$IMG" bs=1k count="$SIZE" status=none
  run mkfs.hfsplus -v "$VOLUME" "$IMG"
  # clone_link keeps symlinks inside the .app (frameworks) as symlinks; special-modes off stops hfsplus from
  # applying its iOS-restore chmod rules. Modes come from the staged files.
  run hfsplus --symlinks clone_link --special-modes no "$IMG" addall "$STAGE" > "$OUT/addall.log"
  echo "    addall: $(wc -l < "$OUT/addall.log") lines (addall.log)"
  run hfsplus "$IMG" symlink /Applications /Applications
  run hfsplus "$IMG" ls /
  run dmg -c zlib build "$IMG" "$DMG" > "$OUT/dmg-build.log"
  ls -l "$DMG"
fi

if has signdmg; then
  echo "==> signdmg: Developer ID signature on the DMG"
  run rcodesign sign --pem-file "$KEY" --pem-file "$CERT" "$DMG"
  sha256sum "$DMG"
fi
echo "==> done"
