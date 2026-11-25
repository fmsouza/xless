#!/usr/bin/env bash
# Which packages a release publishes: those whose sums the jobs that built them said. A job's output is the job's alone, while an artifact
# is the whole run's: any job may replace it.
#   scripts/package-sums.sh one <name> <dist>      "<name>=<sha256>" of the one package in <dist>, for a build job's $GITHUB_OUTPUT
#   scripts/package-sums.sh all <version> <name>=<sha256>...   the sums of all five packages, sha256sum's format, sorted by name
#   scripts/package-sums.sh check <sums> <dist>    refuses a package in <dist> that is not one of <sums>, a file of what `all` printed,
#                                                  and one of <sums> that is not in <dist>
# <name>: <linux|macos>-<x86_64|arm64> or windows-x86_64.
set -euo pipefail
export LC_ALL=C
die() { echo "package-sums: $*" >&2; exit 1; }
usage() { sed -n 's/^#   //p' "$0" >&2; exit 2; }
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -c1-64; }
packages() { (cd "$1" && find . -maxdepth 1 \( -name '*.tar.gz' -o -name '*.zip' \) | sed 's#^\./##' | sort); }
file() {  # version, name
  case "$2" in
    linux-arm64|linux-x86_64|macos-arm64|macos-x86_64) echo "xless-$1-$2.tar.gz" ;;
    windows-x86_64) echo "xless-$1-$2.zip" ;;
    *) die "there is no package '$2'" ;;
  esac
}
case "${1:-}" in
  one)
    [[ $# == 3 && -d "$3" ]] || usage
    file 0.0.0 "$2" >/dev/null
    found=$(packages "$3")
    [[ "$found" =~ ^xless-[0-9A-Za-z.-]+-"$2"\.(tar\.gz|zip)$ ]] || die "$3 does not hold the one package $2: [$found]"
    echo "$2=$(sum "$3/$found")" ;;
  all)
    [[ $# -ge 2 && "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || usage
    version="$2"; shift 2
    lines=""
    for pair in "$@"; do
      name="${pair%%=*}" value="${pair#*=}"
      f=$(file "$version" "$name")
      [[ "$value" =~ ^[0-9a-f]{64}$ ]] || die "the job that built $name did not say its sum: '$value'"
      [[ "$lines" != *"  $f"$'\n'* ]] || die "$name is there twice"
      lines+="$value  $f"$'\n'
    done
    [[ $# == 5 ]] || die "$# packages, not five"
    printf '%s' "$lines" | sort -k2 ;;
  check)
    [[ $# == 3 && -s "$2" && -d "$3" ]] || usage
    ! grep -qvE '^[0-9a-f]{64}  xless-[0-9A-Za-z.-]+-[a-z]+-(x86_64|arm64)\.(tar\.gz|zip)$' "$2" || die "$2 is no list of packages"
    [[ "$(cut -c67- "$2")" == "$(packages "$3")" ]] || die "$3 holds [$(packages "$3" | tr '\n' ' ')], which are not the packages that were built"
    while read -r want name; do
      got=$(sum "$3/$name")
      [[ "$got" == "$want" ]] || die "$name is not the one that was built ($got, not $want)"
    done < "$2" ;;
  *) usage ;;
esac
