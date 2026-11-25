#!/usr/bin/env bash
# For tests on a Mac that get as far as signing and fetch nothing: a share directory like the checkout's whose versions.env pins a
# stand-in for rcodesign (a program that fails), and that stand-in where xless keeps what it fetched.
#   Tests/shell/fake-signer.sh <checkout> <new share directory> <native home>
set -euo pipefail
umask 077
repo="$1" share="$2" native="$3"
version="$(sed -n 's/^RCODESIGN_VERSION=//p' "$repo/versions.env")"
case "$(uname -m)" in arm64) arch=aarch64 ;; *) arch=x86_64 ;; esac
at="$native/tools/rcodesign-$version" archive="apple-codesign-$version-$arch-apple-darwin.tar.gz"
mkdir -p "$at" "$share"
printf '#!/bin/sh\nexit 1\n' > "$at/rcodesign"
chmod 700 "$at/rcodesign"
tar -czf "$at/$archive" -C "$at" rcodesign
for entry in "$repo"/*; do
  [[ ! -e "$entry" || "$entry" == */versions.env ]] || ln -s "$entry" "$share/"
done
sum="$(shasum -a 256 "$at/$archive" | cut -d' ' -f1)"
sed -E "s/^(RCODESIGN_SHA256_DARWIN_[A-Z0-9_]+)=.*/\\1=$sum/" "$repo/versions.env" > "$share/versions.env"
