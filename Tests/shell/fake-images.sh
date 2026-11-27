#!/usr/bin/env bash
# The images of a fake docker: `fake-images.sh image ls …` and `fake-images.sh image inspect … NAME`, from the file $FAKE_IMAGES.
# One image a line: NAME ID ARCH LAYER,LAYER,… [LABEL=VALUE …]. `fake-images.sh base ARCH XCODE BUILD [NAME]` prints the line of
# an image as `xless setup --docker` builds it, `fake-images.sh kit KIT SHARE ARCH XCODE BUILD` that of a kit's image on it, and
# `fake-images.sh tag [SHARE]` the part of the tag that names the xless of SHARE (the repository's when it is not given).
# ADAPTER(packs): removed in the setup/run tasks. An image holds no Xcode any more: XCODE and BUILD only make the fake's IDs and layers
# differ, and its name is xless:<tag>-<arch>.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tag() { # [SHARE]: as scripts/docker-images.sh decides it
  local share="${1:-$repo}" top version
  share="$(cd "$share" && pwd -P)"
  top="$(git -C "$share" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$share" ]]; then
    local id; id="$(git -C "$share" rev-parse --short=12 HEAD)"
    git -C "$share" diff --quiet HEAD 2>/dev/null || id+="-dirty"
    echo "$id"; return
  fi
  version="$(sed -n 's/^XLESS_VERSION=//p' "$share/versions.env")"
  [[ ! -s "$share/VERSION" ]] || version="$(tr -d '[:space:]' < "$share/VERSION")"
  echo "$version"
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
  "base "*) shift; base "$@" ;;
  "kit "*)
    shift; kit="$1" share="$2" arch="$3" xcode="$4" build="$5"
    echo "$(FAKE_SHARE="$share" base "$arch" "$xcode" "$build" "xless:$(tag "$share")-$arch-$kit" "sha256:kit$kit" "base$xcode,xless$xcode,$kit")" \
         "dev.xless.kit=$kit dev.xless.kit.base=sha256:base$xcode dev.xless.kit.recipe=$(recipe "$share" "$kit")" ;;
  *) echo "fake-images: $*" >&2; exit 2 ;;
esac
