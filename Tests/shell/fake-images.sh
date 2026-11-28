#!/usr/bin/env bash
# The images of a fake docker: `fake-images.sh image ls …` and `fake-images.sh image inspect … NAME`, from the file $FAKE_IMAGES.
# One image a line: NAME ID ARCH LAYER,LAYER,… [LABEL=VALUE …]. `fake-images.sh base ARCH XCODE BUILD [NAME]` prints the line of
# an image as `xless setup --docker` builds it, `fake-images.sh kit KIT SHARE ARCH XCODE BUILD` that of a kit's image on it, and
# `fake-images.sh tag [SHARE]` the part of the tag that names the xless of SHARE (the repository's when it is not given), as the script says it.
# An image holds no Xcode: XCODE and BUILD only make the fake's IDs and layers differ, and its name is xless:<tag>-<arch>.
# `fake-images.sh pack STORE ARCH [XCODE BUILD]` makes an Xcode pack in the directory store STORE (XLESS_XCODES), as a setup
# leaves it: its pack.json and the entries of both parts. By default of Xcode 99.0 (99Z99), which no versions.env lists: no
# recipe of this xless makes it stale, so a run that is not a dry run takes it as it is.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tag() { # [SHARE]: what scripts/docker-images.sh says (its `tag` mode), for the repository or for a copy of the script and versions.env in SHARE
  local share="${1:-$repo}"
  if [[ "$share" == "$repo" ]]; then "$repo/scripts/docker-images.sh" tag --arch arm64
  else mkdir -p "$share/scripts"; cp "$repo/scripts/docker-images.sh" "$share/scripts/" 2>/dev/null || true; "$share/scripts/docker-images.sh" tag --arch arm64
  fi
}
base() { # ARCH XCODE BUILD [NAME] [ID] [LAYERS]
  echo "${4:-xless:$(tag "${FAKE_SHARE:-}")-$1} ${5:-sha256:base$2} $1 ${6:-base$2,xless$2} org.xless.image=true dev.xless.arch=$1 dev.xless.version=0.0.0-dev dev.xless.image=$(tag "${FAKE_SHARE:-}")-0123456789ab"
}
recipe() { # SHARE KIT: as Sources/XlessImages/Kit.swift hashes the folder
  python3 -I - "$1/docker/$2" <<'P'
import hashlib, os, sys
root, files = sys.argv[1], []
for d, _, names in os.walk(root): files += [os.path.relpath(os.path.join(d, n), root) for n in names]
h = hashlib.sha256()
for f in sorted(files):
    data = open(os.path.join(root, f), "rb").read()
    h.update(f.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
print(h.hexdigest())
P
}
case "$1 ${2:-}" in
  "image ls")
    filter=""; for a in "$@"; do case "$a" in label=*) filter="${a#label=}" ;; esac; done
    while read -r name _ _ _ labels; do
      [[ -n "$name" ]] || continue
      [[ -z "$filter" || " $labels" == *" $filter="* ]] && echo "$name"
    done < "$FAKE_IMAGES"
    exit 0 ;;
  "image inspect")
    want="${*: -1}"
    while read -r name id arch layers labels; do
      [[ "$name" == "$want" ]] || continue
      l=""; for label in $labels; do l+="${l:+,}\"${label%%=*}\":\"${label#*=}\""; done
      [[ "$layers" != - ]] || layers=""
      printf '{"Id":"%s","Architecture":"%s","Config":{"Labels":{%s}},"RootFS":{"Type":"layers","Layers":[%s]}}\n' "$id" "$arch" "$l" "${layers:+\"${layers//,/\",\"}\"}"
      exit 0
    done < "$FAKE_IMAGES"
    echo "Error: No such image: $want" >&2; exit 1 ;;
  "tag "*|"tag ") shift; tag "$@" ;;
  "pack "*)
    shift; store="$1" arch="$2" xcode="${3:-99.0}" build="${4:-99Z99}"; p="$store/$xcode-$build-$arch"
    mkdir -p "$p"/{toolchain,config,toolchain-meta.json,swift-toolchain.json,include,swift-build}
    printf '{"format":1,"xcode":"%s","build":"%s","arch":"%s","swift":"6.4.0","mode":"own","parts":{"sdk":"s","swift-build":"b"}}\n' "$xcode" "$build" "$arch" > "$p/pack.json" ;;
  "base "*) shift; base "$@" ;;
  "kit "*)
    shift; kit="$1" share="$2" arch="$3" xcode="$4" build="$5"
    echo "$(FAKE_SHARE="$share" base "$arch" "$xcode" "$build" "xless:$(tag "$share")-$arch-$kit" "sha256:kit$kit" "base$xcode,xless$xcode,$kit")" \
         "dev.xless.kit=$kit dev.xless.kit.base=sha256:base$xcode dev.xless.kit.recipe=$(recipe "$share" "$kit")" ;;
  *) echo "fake-images: $*" >&2; exit 2 ;;
esac
