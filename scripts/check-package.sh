#!/usr/bin/env bash
# A release tarball holds what it must, and nothing else: no file of Apple's, of the Xcode or of the build among them.
#   scripts/check-package.sh <linux|macos|windows> <version> <x86_64|arm64> <tarball or zip>
# Every entry is a regular file or a directory of root's below xless-<version>-<os>-<arch>/, with the mode it must have and no
# extended attributes. The files are those of this checkout, byte for byte (docker/ and samples/HelloShip: the tracked ones;
# versions.env but for XLESS_VERSION, which a release build stamps), the licences by name (third-party-licenses.sh --list), the
# vendored ones by their sha256 and a package's own as text, share/xless/VERSION, and bin/xless, the only executable code: a
# program for that system and architecture. What is in that program is for check-link-map.sh and check-macos-binary.sh. Prints the list.
# A Windows package is a zip with another layout: scripts/windows-package.py says which, and what its programs may need.
# XLESS_STUB=true: bin/xless may be anything (tests, which put a script there).
set -euo pipefail
os="${1:-}" version="${2:-}" arch="${3:-}" tarball="${4:-}"
die() { echo "check-package: $*" >&2; exit 1; }
[[ -n "$os" && -n "$version" && -n "$arch" && -n "$tarball" ]] || { echo "usage: check-package.sh <linux|macos|windows> <version> <x86_64|arm64> <tarball or zip>" >&2; exit 2; }
[[ -f "$tarball" ]] || die "no $tarball"
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$os" == windows ]]; then
  python=python3; command -v python3 >/dev/null 2>&1 || python=python
  "$root/scripts/third-party-licenses.sh" --os windows --list | "$python" -I "$root/scripts/windows-package.py" check "$version" "$arch" "$tarball" "$root" \
    || die "$tarball is not what is released"
  exit 0
fi
top="xless-$version-$os-$arch"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
export LC_ALL=C

# Regular files and directories only, with no permission for others to write, nor to run as another user; root's.
tar --numeric-owner -tvzf "$tarball" > "$t/long" || die "$tarball cannot be read"
odd="$(grep -vE '^(-rw.r-.r-.|drw.r-.r-.)' "$t/long" || true)"
[[ -z "$odd" ]] || die "$tarball holds something else than files and directories, or one that others may write: $odd"
odd="$(cut -c1-10 "$t/long" | grep '[sStT]' || true)"
[[ -z "$odd" ]] || die "$tarball holds a set-user-ID, set-group-ID or sticky entry"
# GNU tar: "-rw-r--r-- 0/0 …"; bsdtar: "-rw-r--r--  0 0      0  …" (the links first).
odd="$(grep -vE '^[^ ]+ +(0/0|0 +0 +0) ' "$t/long" || true)"
[[ -z "$odd" ]] || die "$tarball holds entries of another owner than root: $odd"
# (grep reads to the end: it must not end gzip)
odd="$(gzip -dc "$tarball" | grep -acE '[0-9]+ (SCHILY|LIBARCHIVE|RHT)\.(xattr|acl|fflags|security)' || true)"
[[ "$odd" == 0 ]] || die "$tarball holds extended attributes, access lists or flags"

tar -tzf "$tarball" > "$t/names"
[[ "$(sort "$t/names" | uniq -d)" == "" ]] || die "$tarball holds an entry twice"
grep -v '/$' "$t/names" | sort > "$t/files"
"$root/scripts/third-party-licenses.sh" --os "$os" --list > "$t/licences"
{
  printf '%s\n' LICENSE bin/xless share/xless/VERSION share/xless/versions.env
  for s in docker-images xcode-swift testflight native-toolchain fit-toolchain; do echo "share/xless/scripts/$s.sh"; done
  for h in pass secret-tool; do echo "share/xless/credential-helpers/xless-credential-$h"; done
  git -c "safe.directory=$root" -C "$root" ls-files docker samples/HelloShip | sed 's#^#share/xless/#'
  while IFS=' ' read -r name kind; do
    if [[ "$kind" != 'text?' ]] || grep -qxF "$top/share/xless/licenses/$name" "$t/files"; then echo "share/xless/licenses/$name"; fi
  done < "$t/licences"
} | sed "s#^#$top/#" | sort > "$t/want"
diff "$t/want" "$t/files" > "$t/diff" || die "$tarball does not hold what a package holds (<: missing, >: too much):
$(cat "$t/diff")"
# The directories are the files' own.
{ echo "$top/"; sed 's#/[^/]*$##' "$t/files" | while IFS= read -r d; do while [[ "$d" == */* ]]; do echo "$d/"; d="${d%/*}"; done; done; } | sort -u > "$t/wantdirs"
grep '/$' "$t/names" | sort > "$t/dirs" || true
odd="$(comm -13 "$t/wantdirs" "$t/dirs")"
[[ -z "$odd" ]] || die "$tarball holds an empty directory: $odd"

# The modes: what runs may be run, and nothing else.
{
  echo bin/xless
  grep -E '^share/xless/(scripts|credential-helpers)/' <(sed "s#^$top/##" "$t/files")
  git -c "safe.directory=$root" -C "$root" ls-files -s docker samples/HelloShip | sed -n 's#^100755 [^	]*	#share/xless/#p'
} | sed "s#^#$top/#" | sort > "$t/run"
paste -d ' ' <(cut -c1-10 "$t/long") "$t/names" > "$t/modes"
while IFS=' ' read -r mode name; do
  want=-rw-r--r--
  if [[ "$name" == */ ]]; then want=drwxr-xr-x; elif grep -qxF "$name" "$t/run"; then want=-rwxr-xr-x; fi
  [[ "$mode" == "$want" ]] || die "$tarball: $name has the mode $mode, not $want"
done < "$t/modes"

# No executable code but xless: nothing with the magic number of ELF, Mach-O (also universal) or an archive.
mkdir "$t/x"
tar -xzf "$tarball" -C "$t/x" || die "$tarball cannot be unpacked"
hex() { head -c "$2" "$1" | od -An -v -tx1 | tr -d ' \n'; }
while IFS= read -r f; do
  [[ "$f" != "$top/bin/xless" ]] || continue
  case "$(hex "$t/x/$f" 4)" in
    7f454c46|feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|cafebabf|213c6172) die "$tarball: $f is executable code" ;;
  esac
done < "$t/files"
if [[ "${XLESS_STUB:-}" != true ]]; then
  head="$(hex "$t/x/$top/bin/xless" 20)"
  case "$os-$arch" in   # ELF: 64 bits, little-endian, e_machine; Mach-O: 64 bits, cputype
    linux-x86_64) [[ "$head" == 7f454c460201* && "${head:36:4}" == 3e00 ]] ;;
    linux-arm64) [[ "$head" == 7f454c460201* && "${head:36:4}" == b700 ]] ;;
    macos-x86_64) [[ "$head" == cffaedfe07000001* ]] ;;
    macos-arm64) [[ "$head" == cffaedfe0c000001* ]] ;;
    *) false ;;
  esac || die "$tarball: bin/xless is no program for $os $arch"
fi
[[ "$(cat "$t/x/$top/share/xless/VERSION")" == "$version" ]] || die "$tarball: share/xless/VERSION is not $version"

# The contents: this checkout's.
share="$t/x/$top/share/xless"
same() { cmp -s "$1" "$2" || die "$tarball: ${1#"$t/x/$top/"} differs from the checkout's"; }
same "$t/x/$top/LICENSE" "$root/LICENSE"
[[ "$(sed -n '/^XLESS_VERSION=/p' "$share/versions.env" | wc -l)" -eq 1 ]] || die "$tarball: share/xless/versions.env has not one XLESS_VERSION"
cmp -s <(grep -v '^XLESS_VERSION=' "$share/versions.env") <(grep -v '^XLESS_VERSION=' "$root/versions.env") \
  || die "$tarball: share/xless/versions.env differs from the checkout's"
for f in "$share"/scripts/*; do same "$f" "$root/scripts/${f##*/}"; done
for f in "$share"/credential-helpers/*; do same "$f" "$root/scripts/credential-helpers/${f##*/}"; done
git -c "safe.directory=$root" -C "$root" ls-files docker samples/HelloShip > "$t/tracked"
while IFS= read -r f; do same "$share/$f" "$root/$f"; done < "$t/tracked"
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
while IFS=' ' read -r name kind; do
  f="$share/licenses/$name"
  case "$kind" in
    text|text\?)
      [[ -e "$f" ]] || continue   # a NOTICE: what must be there is in the list above
      [[ -s "$f" ]] || die "$tarball: licenses/$name is empty"
      [[ "$(tr -d '\000-\010\013\016-\037\177' < "$f" | wc -c)" -eq "$(wc -c < "$f")" ]] || die "$tarball: licenses/$name is no text"
      iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1 || die "$tarball: licenses/$name is no text"
      ! grep -qE '^--- *!tapi-tbd|"?tapi_tbd_version"?' "$f" || die "$tarball: licenses/$name is a text stub of a library" ;;
    */*) same "$f" "$root/$kind" ;;
    *) [[ "$(sha256 "$f")" == "$kind" ]] || die "$tarball: licenses/$name is not the one of SOURCES.tsv" ;;
  esac
done < "$t/licences"
cat "$t/files"
