#!/usr/bin/env bash
# A release tarball holds what it must, and nothing else: no file of Apple's, of the Xcode or of the build among them.
#   scripts/check-package.sh <linux|macos> <version> <x86_64|arm64> <tarball>
# Every entry is a regular file or a directory below xless-<version>-<os>-<arch>/, of the list below (docker/ and
# samples/HelloShip: the files this checkout tracks), and the only executable code is bin/xless. Prints the list.
set -euo pipefail
os="${1:-}" version="${2:-}" arch="${3:-}" tarball="${4:-}"
die() { echo "check-package: $*" >&2; exit 1; }
[[ -n "$os" && -n "$version" && -n "$arch" && -n "$tarball" ]] || { echo "usage: check-package.sh <linux|macos> <version> <x86_64|arm64> <tarball>" >&2; exit 2; }
[[ -f "$tarball" ]] || die "no $tarball"
root="$(cd "$(dirname "$0")/.." && pwd)"
top="xless-$version-$os-$arch"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
export LC_ALL=C

# Regular files and directories only, with no permission for others to write, nor to run as another user.
tar -tvzf "$tarball" > "$t/long" || die "$tarball cannot be read"
odd="$(grep -vE '^(-rw.r-.r-.|drw.r-.r-.)' "$t/long" || true)"
[[ -z "$odd" ]] || die "$tarball holds something else than files and directories, or one that others may write: $odd"
odd="$(cut -c1-10 "$t/long" | grep '[sStT]' || true)"
[[ -z "$odd" ]] || die "$tarball holds a set-user-ID, set-group-ID or sticky entry"

tar -tzf "$tarball" > "$t/names"
[[ "$(sort "$t/names" | uniq -d)" == "" ]] || die "$tarball holds an entry twice"
grep -v '/$' "$t/names" | sort > "$t/files"
{
  printf '%s\n' LICENSE bin/xless share/xless/VERSION share/xless/versions.env
  for s in docker-images xcode-swift testflight native-toolchain; do echo "share/xless/scripts/$s.sh"; done
  for h in pass secret-tool; do echo "share/xless/credential-helpers/xless-credential-$h"; done
  git -c "safe.directory=$root" -C "$root" ls-files docker samples/HelloShip | sed 's#^#share/xless/#'
} | sed "s#^#$top/#" | sort > "$t/want"
grep -vE "^$top/share/xless/licenses/[A-Za-z0-9._-]+\.txt$" "$t/files" > "$t/got" || true
diff "$t/want" "$t/got" > "$t/diff" || die "$tarball does not hold what a package holds (<: missing, >: too much):
$(cat "$t/diff")"
grep -qE "/share/xless/licenses/swift-LICENSE\.txt$" "$t/files" || die "$tarball has no licences"
# The directories are the files' own.
{ echo "$top/"; sed 's#/[^/]*$##' "$t/files" | while IFS= read -r d; do while [[ "$d" == */* ]]; do echo "$d/"; d="${d%/*}"; done; done; } | sort -u > "$t/wantdirs"
grep '/$' "$t/names" | sort > "$t/dirs" || true
odd="$(comm -13 "$t/wantdirs" "$t/dirs")"
[[ -z "$odd" ]] || die "$tarball holds an empty directory: $odd"

# No executable code but xless: nothing with the magic number of ELF, Mach-O (also universal) or an archive.
mkdir "$t/x"
tar -xzf "$tarball" -C "$t/x" || die "$tarball cannot be unpacked"
while IFS= read -r f; do
  [[ "$f" != "$top/bin/xless" ]] || continue
  case "$(head -c 4 "$t/x/$f" | od -An -tx1 | tr -d ' \n')" in
    7f454c46|feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|cafebabf|213c6172) die "$tarball: $f is executable code" ;;
  esac
done < "$t/files"
[[ "$(cat "$t/x/$top/share/xless/VERSION")" == "$version" ]] || die "$tarball: share/xless/VERSION is not $version"
cat "$t/files"
