#!/usr/bin/env bash
# scripts/package-sums.sh, and how the release workflow uses it: what is verified and published is what the build jobs' outputs say, not
# what an artifact of that name holds by then.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export LC_ALL=C
sums() { bash "$repo/scripts/package-sums.sh" "$@" 2>"$t/err"; }
refused() {  # what it says, then the arguments
  local say="$1"; shift
  sums "$@" >"$t/out" && fail "accepted: $*"
  grep -qF -- "$say" "$t/err" || fail "refused for something else than '$say': $(cat "$t/err")"
  [[ ! -s "$t/out" ]] || fail "refused, it says: $(cat "$t/out")"
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -c1-64; }

# A build job says its own package's sum.
names=(linux-x86_64 linux-arm64 macos-x86_64 macos-arm64 windows-x86_64)
pairs=()
mkdir "$t/dist"
for n in "${names[@]}"; do
  mkdir "$t/$n"; e=tar.gz; [[ $n != windows-* ]] || e=zip
  echo "the package $n" > "$t/$n/xless-1.4.0-$n.$e"; echo other > "$t/$n/SHA256SUMS"
  got=$(sums one "$n" "$t/$n") || fail "one $n: $(cat "$t/err")"
  [[ "$got" == "$n=$(sha "$t/$n/xless-1.4.0-$n.$e")" ]] || fail "one $n: $got"
  pairs+=("$got"); cp "$t/$n/xless-1.4.0-$n.$e" "$t/dist/"
done
refused "does not hold the one package linux-arm64" one linux-arm64 "$t/linux-x86_64"
refused "does not hold the one package linux-x86_64" one linux-x86_64 "$t/dist"
refused "there is no package 'windows-arm64'" one windows-arm64 "$t/windows-x86_64"
refused "does not hold the one" one linux-x86_64 "$repo/scripts"

# All of them, in one list.
sums all 1.4.0 "${pairs[@]}" > "$t/sums" || fail "all: $(cat "$t/err")"
diff <(cut -c67- "$t/sums") - <<< $'xless-1.4.0-linux-arm64.tar.gz\nxless-1.4.0-linux-x86_64.tar.gz\nxless-1.4.0-macos-arm64.tar.gz\nxless-1.4.0-macos-x86_64.tar.gz\nxless-1.4.0-windows-x86_64.zip' || fail "all: the names"
(cd "$t/dist" && if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$t/sums"; else shasum -a 256 -c "$t/sums"; fi) >/dev/null || fail "all: the sums"
refused "4 packages, not five" all 1.4.0 "${pairs[@]:1}"
refused "linux-x86_64 is there twice" all 1.4.0 "${pairs[@]:0:4}" "${pairs[0]}"
refused "did not say its sum: ''" all 1.4.0 "${pairs[@]:1}" "linux-x86_64="
refused "did not say its sum" all 1.4.0 "${pairs[@]:1}" "linux-x86_64=$(printf 'A%.0s' {1..64})"
refused "did not say its sum" all 1.4.0 "${pairs[@]:1}" "${pairs[0]}"$'\n'"x"
refused "there is no package 'other'" all 1.4.0 "${pairs[@]:1}" "other=${pairs[0]#*=}"
refused "<version>" all '1.4.0 x' "${pairs[@]}"

# What is there by then is that.
sums check "$t/sums" "$t/dist" || fail "check: $(cat "$t/err")"
touch "$t/dist/install.sh"; sums check "$t/sums" "$t/dist" || fail "a file that is no package is nobody's matter"
for n in "${names[@]}"; do
  f=$(cd "$t/dist" && ls xless-1.4.0-"$n".*)
  cp "$t/dist/$f" "$t/kept"; echo more >> "$t/dist/$f"
  refused "$f is not the one that was built" check "$t/sums" "$t/dist"
  rm "$t/dist/$f"; refused "which are not the packages that were built" check "$t/sums" "$t/dist"
  cp "$t/kept" "$t/dist/$f"
done
for f in xless-1.4.0-linux-riscv.tar.gz xless-1.4.1-linux-arm64.tar.gz other.zip; do
  touch "$t/dist/$f"; refused "which are not the packages that were built" check "$t/sums" "$t/dist"; rm "$t/dist/$f"
done
: > "$t/none"; refused "<sums>" check "$t/none" "$t/dist"
echo > "$t/none"; refused "is no list of packages" check "$t/none" "$t/dist"
{ cat "$t/sums"; echo; } > "$t/none"; refused "is no list of packages" check "$t/none" "$t/dist"

# The workflow: each build job says the sum of what it uploads, before it does; one job that runs nothing of it makes the list; and
# verify and publish take no package but through the action that compares.
wf="$repo/.github/workflows/release.yml"
job() { awk -v j="  $1:" '$0 == j { on = 1; next } on && /^  [a-z#]/ { exit } on { print }' "$wf"; }
action="$repo/.github/actions/release-packages/action.yml"
built="$(job built)"
grep -qx '    needs: \[plan, build, build-macos, build-windows\]' <<< "$built" || fail "built does not need every build"
for j in build:linux build-macos:macos build-windows:windows; do
  os="${j#*:}" j="${j%%:*}" body="$(job "${j%%:*}")"
  [[ "$(grep -c 'id: sum$' <<< "$body")" == 1 && "$(grep -c 'upload-artifact@' <<< "$body")" == 1 ]] || fail "$j has not one sum and one package"
  [[ "$(grep -nE 'package-sums.sh one|upload-artifact@|Build and package' <<< "$body" | sed -E 's/.*(one|upload|Build).*/\1/' | tr '\n' ' ')" == "Build one upload " ]] || fail "$j: the order"
  for a in x86_64 arm64; do
    [[ $os-$a != windows-arm64 ]] || continue
    grep -qxF "      $os-$a: \${{ steps.sum.outputs.$os-$a }}" <<< "$body" || fail "$j does not say the sum of $os-$a"
    grep -qF "\${{ needs.$j.outputs.$os-$a }}" <<< "$built" || fail "built does not ask for $os-$a"
  done
done
for j in verify verify-windows publish; do
  body="$(job $j)"
  grep -qE '^    needs: \[plan, built(, verify, verify-windows)?\]$' <<< "$body" || fail "$j needs: $(grep needs: <<< "$body")"
  [[ "$(grep -c 'uses: ./.github/actions/release-packages$' <<< "$body")" == 1 ]] || fail "$j takes packages elsewhere"
  grep -qxF '          sums: ${{ needs.built.outputs.sums }}' <<< "$body" || fail "$j compares with something else"
done
grep -q 'download-artifact' "$wf" && fail "release.yml takes an artifact without comparing it"
grep -qE 'pattern:|merge-multiple' "$action" && fail "artifacts are taken by a pattern"
[[ "$(grep -oE 'name: tarball-[a-z0-9_-]+' "$action" | sort | tr '\n' ' ')" == "name: tarball-arm64 name: tarball-macos-arm64 name: tarball-macos-x86_64 name: tarball-windows-x86_64 name: tarball-x86_64 " ]] || fail "not the five artifacts"
grep -qE 'continue-on-error|if:' "$action" && fail "the comparison may be gone without"

# The two steps as they are there.
step() { awk -v n="- name: $2" 'index($0, n) { on = 1 } on && /^ +run: \|/ { body = 1; match($0, /^ +/); ind = RLENGTH; next } body && $0 !~ "^ {" ind + 1 "}" && NF { exit } body { print substr($0, ind + 3) }' "$1"; }
step "$wf" "The packages' sums" > "$t/built.sh"; step "$action" "They are the packages that were built" > "$t/check.sh"
grep -q 'package-sums.sh all' "$t/built.sh" && grep -q 'package-sums.sh check' "$t/check.sh" || fail "no such steps: $(cat "$t/built.sh" "$t/check.sh")"
value() { local p; for p in "${pairs[@]}"; do [[ "${p%%=*}" != "$1" ]] || echo "${p#*=}"; done; }
built() { (cd "$repo" && GITHUB_OUTPUT="$t/github" VERSION=1.4.0 LINUX_ARM64="$(value linux-arm64)" LINUX_X86_64="$(value linux-x86_64)" MACOS_ARM64="$(value macos-arm64)" \
  MACOS_X86_64="$(value macos-x86_64)" WINDOWS_X86_64="${1-$(value windows-x86_64)}" bash -e "$t/built.sh" 2>"$t/err"); }
: > "$t/github"; built || fail "the list: $(cat "$t/err")"
diff "$t/github" <(echo 'sums<<END'; cat "$t/sums"; echo END) || fail "the list's output"
: > "$t/github"; built "" && fail "a list without Windows"
[[ ! -s "$t/github" ]] || fail "a list without Windows is an output"
mkdir "$t/work" "$t/tmp"; ln -s "$repo/scripts" "$t/work/scripts"; ln -s "$t/dist" "$t/work/dist"
check() { (cd "$t/work" && RUNNER_TEMP="$t/tmp" SUMS="$1" bash -e "$t/check.sh" 2>"$t/err"); }
check "$(cat "$t/sums")" || fail "the comparison: $(cat "$t/err")"
check "" && fail "compared with nothing"
echo more >> "$t/dist/xless-1.4.0-linux-arm64.tar.gz"; check "$(cat "$t/sums")" && fail "another package is taken"
echo "package-sums.test.sh: ok"
