# shellcheck shell=bash disable=SC2154,SC2034   # xcode, arch and args are the sourcing script's, and so is pack
# Sourced by the scripts that build a sample in this checkout's image (test-cargo-linux.sh, test-tauri-linux.sh,
# test-rn-linux.sh, parity.sh): `pack_args <script name>` sets `pack` to the docker run options that give a container the
# Xcode's pack, read-only, as xless run gives it to every container (xless setup --docker prepares it): the newest build of
# $xcode for $arch as xless chooses it (`newest_pack`) in its volume (found by its name, xless-xcode-<version>-<build>-<arch>, as xless finds it: a volume made
# by hand has no label), or in the directory XLESS_XCODES names (that pack's directory alone). It reads $xcode,
# $arch and $args (the docker command, with its --context); without such a pack it says what prepares one and exits 2.
pack_args_versions="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/versions.env"

# newest_pack PREFIX SUFFIX: of the names on stdin, each PREFIX<build>SUFFIX, the one xless chooses (XcodeResolver): the build
# that comes last in versions.env's XCODE_RELEASES, one it does not list before every one it does, and among those the
# greater build as text.
newest_pack() {
  local releases n b before rank
  releases=" $(sed -n 's/^XCODE_RELEASES="\(.*\)"$/\1/p' "$pack_args_versions") "
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    b="${n#"$1"}"; b="${b%"$2"}"; rank=0
    if [[ "$releases" == *" $b "* ]]; then before="${releases%%" $b "*}"; rank=$(( $(wc -w <<<"$before") + 1 )); fi
    printf '%06d\t%s\t%s\n' "$rank" "$b" "$n"
  done | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 | tail -1 | cut -f3
}

pack_args() {
  local name dir volumes src
  if [[ -n "${XLESS_XCODES:-}" ]]; then
    dir="$(ls -d "$XLESS_XCODES/$xcode"-*-"$arch" 2>/dev/null | newest_pack "$XLESS_XCODES/$xcode-" "-$arch" || true)"
    [[ -n "$dir" && -f "$dir/pack.json" ]] || { echo "$1: no pack of Xcode $xcode for $arch in $XLESS_XCODES; prepare it: xless setup --docker --xcode <Xcode $xcode .xip>" >&2; exit 2; }
    # docker reads --mount as CSV: a field with a comma, a quote or a line break is quoted, its quotes doubled (as xless does)
    src="src=$dir"
    [[ "$src" != *[,\"$'\n'$'\r']* ]] || src="\"${src//\"/\"\"}\""
    name="$(basename "$dir")"; pack=(--mount "type=bind,$src,dst=/xcodes/$name,readonly" -e "XLESS_XCODE=/xcodes/$name")
  else
    volumes="$("${args[@]}" volume ls --format '{{.Name}}')" || { echo "$1: docker could not list the volumes (${args[*]} volume ls); check that it runs (docker ps)" >&2; exit 2; }
    name="$(grep -E "^xless-xcode-${xcode//./\\.}-[A-Za-z0-9]+-$arch\$" <<<"$volumes" | newest_pack "xless-xcode-$xcode-" "-$arch" || true)"
    [[ -n "$name" ]] || { echo "$1: no pack volume of Xcode $xcode for $arch; prepare it: xless setup --docker --xcode <Xcode $xcode .xip>" >&2; exit 2; }
    pack=(--mount "type=volume,src=$name,dst=/xcodes,readonly" -e "XLESS_XCODE=/xcodes/${name#xless-xcode-}")
  fi
}
