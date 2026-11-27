# shellcheck shell=bash disable=SC2154,SC2034   # xcode, arch and args are the sourcing script's, and so is pack
# Sourced by the scripts that build a sample in this checkout's image (test-cargo-linux.sh, test-tauri-linux.sh,
# test-rn-linux.sh, parity.sh): `pack_args <script name>` sets `pack` to the docker run options that give a container the
# Xcode's pack, read-only, as xless run gives it to every container (xless setup --docker prepares it): the newest build of
# $xcode for $arch in its volume (found by its name, xless-xcode-<version>-<build>-<arch>, as xless finds it: a volume made
# by hand has no label), or in the directory XLESS_XCODES names (that pack's directory alone). It reads $xcode,
# $arch and $args (the docker command, with its --context); without such a pack it says what prepares one and exits 2.
pack_args() {
  local name dir volumes
  if [[ -n "${XLESS_XCODES:-}" ]]; then
    dir="$(ls -d "$XLESS_XCODES/$xcode"-*-"$arch" 2>/dev/null | sort | tail -1 || true)"
    [[ -n "$dir" && -f "$dir/pack.json" ]] || { echo "$1: no pack of Xcode $xcode for $arch in $XLESS_XCODES; prepare it: xless setup --docker --xcode <Xcode $xcode .xip>" >&2; exit 2; }
    name="$(basename "$dir")"; pack=(--mount "type=bind,src=$dir,dst=/xcodes/$name,readonly" -e "XLESS_XCODE=/xcodes/$name")
  else
    volumes="$("${args[@]}" volume ls --format '{{.Name}}')" || { echo "$1: docker could not list the volumes (${args[*]} volume ls); check that it runs (docker ps)" >&2; exit 2; }
    name="$(grep -E "^xless-xcode-${xcode//./\\.}-[A-Za-z0-9]+-$arch\$" <<<"$volumes" | sort | tail -1 || true)"
    [[ -n "$name" ]] || { echo "$1: no pack volume of Xcode $xcode for $arch; prepare it: xless setup --docker --xcode <Xcode $xcode .xip>" >&2; exit 2; }
    pack=(--mount "type=volume,src=$name,dst=/xcodes,readonly" -e "XLESS_XCODE=/xcodes/${name#xless-xcode-}")
  fi
}
