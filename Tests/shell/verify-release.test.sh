#!/usr/bin/env bash
# scripts/release-assets.sh and scripts/verify-release.sh: the release workflow's check that the stamped tarballs install
# and report their version before anything is published. Tarballs are built with scripts/package-release.sh from stubs.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export XLESS_CHECKOUTS="$t/checkouts" XLESS_STRIP=true XLESS_CODESIGN=true XLESS_CHECK_BINARY=true XLESS_CHECK_MAP=true XLESS_STUB=true XLESS_UNAME_S=Linux XLESS_UNAME_M=x86_64
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do
  mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"
done

# dist <dir> <version> <what the stub prints>: the four tarballs and the zip of <version>, their binaries printing <what>.
dist() {
  local a o
  mkdir -p "$1"
  for o in linux macos; do for a in x86_64 arm64; do
    printf '#!/bin/sh\necho "%s"\n' "$3" > "$t/xless"; chmod +x "$t/xless"
    bash "$repo/scripts/package-release.sh" --os "$o" "$2" "$a" "$t/xless" "$1" >/dev/null
  done; done
  bash "$repo/scripts/package-release.sh" --os windows "$2" x86_64 "$t/xless" "$1" >/dev/null
  rm -f "$1/SHA256SUMS"   # package-release.sh's per-leg file; release-assets.sh writes the release's
}

# A good release: assets made, installed pinned and as the latest, both report the version.
dist "$t/good" 1.4.0 1.4.0
bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/good" >/dev/null || fail "release-assets refused a good dist"
[[ "$(wc -l < "$t/good/SHA256SUMS" | tr -d ' ')" == 5 ]] || fail "SHA256SUMS: $(cat "$t/good/SHA256SUMS")"
head -n1 "$t/good/SHA256SUMS" | grep -q ' xless-1.4.0-linux-arm64.tar.gz$' || fail "SHA256SUMS not sorted by name"
tail -n1 "$t/good/SHA256SUMS" | grep -q ' xless-1.4.0-windows-x86_64.zip$' || fail "SHA256SUMS without the zip"
for i in install.sh install.ps1; do cmp -s "$repo/scripts/$i" "$t/good/$i" || fail "$i not copied"; done
out=$(bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/good" 2>&1) || fail "verify refused a good release: $out"
grep -q 'v1.4.0: xless 1.4.0 installed' <<<"$out" || fail "pinned install not checked: $out"
grep -q 'latest: xless 1.4.0 installed' <<<"$out" || fail "latest install not checked: $out"

# The same on a Mac (which xless' name for the machine's architecture and the system decide), and not on one that is too old.
mkdir -p "$t/mac"; printf '#!/bin/sh\necho 14.0\n' > "$t/mac/sw_vers"; printf '#!/bin/sh\nexit 1\n' > "$t/mac/sysctl"; chmod +x "$t/mac"/*
out=$(PATH="$t/mac:$PATH" XLESS_UNAME_S=Darwin XLESS_UNAME_M=arm64 bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/good" 2>&1) || fail "verify refused a good release on a Mac: $out"
[[ "$(grep -c 'downloading xless-1.4.0-macos-arm64.tar.gz' <<<"$out")" == 2 ]] || fail "not the macOS tarball: $out"
printf '#!/bin/sh\necho "checked $*" >> "%s/checked"\n' "$t" > "$t/checks"; chmod +x "$t/checks"
out=$(PATH="$t/mac:$PATH" XLESS_CHECK_BINARY="$t/checks" XLESS_UNAME_S=Darwin XLESS_UNAME_M=arm64 bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/good" 2>&1) || fail "verify with a check: $out"
[[ "$(grep -cE '^checked .*/(pinned|latest)/bin/xless arm64$' "$t/checked")" == 2 ]] || fail "the installed programs are not checked: $(cat "$t/checked")"
PATH="$t/mac:$PATH" XLESS_CHECK_BINARY=false XLESS_UNAME_S=Darwin XLESS_UNAME_M=arm64 bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/good" >/dev/null 2>&1 && fail "an installed program that fails its check is released"
rm "$t/checked"; XLESS_CHECK_BINARY="$t/checks" bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/good" >/dev/null 2>&1 || fail "verify on Linux"
[[ ! -e "$t/checked" ]] || fail "a Linux program is checked as a macOS one"
printf '#!/bin/sh\necho 13.7.1\n' > "$t/mac/sw_vers"
out=$(PATH="$t/mac:$PATH" XLESS_UNAME_S=Darwin XLESS_UNAME_M=arm64 bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/good" 2>&1) && fail "installed on macOS 13"
grep -q 'xless needs macOS 14 or later (this is macOS 13.7.1)' <<<"$out" || fail "wrong message: $out"

# A binary that reports another version (a stamp that didn't take) fails.
dist "$t/unstamped" 1.4.0 0.0.0-dev
bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/unstamped" >/dev/null
out=$(bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/unstamped" 2>&1) && fail "verify passed a 0.0.0-dev binary"
grep -q "printed '0.0.0-dev', expected '1.4.0'" <<<"$out" || fail "wrong message: $out"

# A wrong share/xless/VERSION fails.
dist "$t/badshare" 1.4.0 1.4.0
for a in linux-x86_64 linux-arm64; do
  n="xless-1.4.0-$a"; mkdir -p "$t/x"; tar -xzf "$t/badshare/$n.tar.gz" -C "$t/x"
  echo 0.0.0-dev > "$t/x/$n/share/xless/VERSION"; tar -czf "$t/badshare/$n.tar.gz" -C "$t/x" "$n"; rm -rf "$t/x"
done
out=$(bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/badshare" 2>&1) && fail "release-assets took a wrong share/xless/VERSION"
grep -q "the linux arm64 package is not as it must be" <<<"$out" || fail "wrong message: $out"
cp "$t/unstamped/install.sh" "$t/badshare/"; (cd "$t/badshare" && if command -v sha256sum >/dev/null; then sha256sum ./*.tar.gz; else shasum -a 256 ./*.tar.gz; fi) | sed 's# \./# #' > "$t/badshare/SHA256SUMS"
out=$(bash "$repo/scripts/verify-release.sh" 1.4.0 "$t/badshare" 2>&1) && fail "verify passed a wrong share/xless/VERSION"
grep -q "share/xless/VERSION is '0.0.0-dev'" <<<"$out" || fail "wrong message: $out"

# Tarballs named for another version (or one missing) are refused before any checksum is written.
dist "$t/misnamed" 1.3.9 1.4.0
out=$(bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/misnamed" 2>&1) && fail "release-assets took 1.3.9 tarballs for 1.4.0"
grep -q 'expected \[xless-1.4.0-linux-arm64.tar.gz xless-1.4.0-linux-x86_64.tar.gz xless-1.4.0-macos-arm64.tar.gz xless-1.4.0-macos-x86_64.tar.gz xless-1.4.0-windows-x86_64.zip\]' <<<"$out" || fail "wrong message: $out"
[[ ! -e "$t/misnamed/SHA256SUMS" ]] || fail "SHA256SUMS written for a refused dist"
for a in linux-arm64.tar.gz linux-x86_64.tar.gz macos-arm64.tar.gz macos-x86_64.tar.gz windows-x86_64.zip; do
  mv "$t/good/xless-1.4.0-$a" "$t/away"
  bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/good" >/dev/null 2>&1 && fail "release-assets took a dist without $a"
  mv "$t/away" "$t/good/xless-1.4.0-$a"
done
z="$t/good/xless-1.4.0-windows-x86_64.zip"; cp "$z" "$t/zip"
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "a").writestr("xless-1.4.0-windows-x86_64/bin/vcruntime140.dll", "x")' "$z"
out=$(bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/good" 2>&1) && fail "release-assets took a zip with more in it"
grep -q "the windows x86_64 package is not as it must be" <<<"$out" || fail "wrong message: $out"
cp "$t/zip" "$z"
# ... and one that holds what a package does not.
n=xless-1.4.0-macos-arm64; mkdir -p "$t/x"; tar -xzf "$t/good/$n.tar.gz" -C "$t/x"; echo x > "$t/x/$n/bin/libswift.dylib"
COPYFILE_DISABLE=1 tar -czf "$t/good/$n.tar.gz" -C "$t/x" "$n"
out=$(bash "$repo/scripts/release-assets.sh" 1.4.0 "$t/good" 2>&1) && fail "release-assets took a package with more in it"
grep -q "libswift.dylib" <<<"$out" || fail "wrong message: $out"

# The workflow: nothing is published unless every build and every install of it succeeded, and what pr.yml builds and installs is
# what release.yml does: the same action, with the same inputs but the version, on the same runners.
wf="$repo/.github/workflows"
job() { awk -v j="  $2:" '$0 == j { on = 1; next } on && /^  [a-z]/ { exit } on { print }' "$wf/$1"; }
grep -qx '    needs: \[plan, built, verify, verify-windows\]' <<<"$(job release.yml publish)" || fail "publish does not need every job"
grep -qx '    needs: \[plan, build, build-macos, build-windows\]' <<<"$(job release.yml built)" || fail "built does not need every build"
for j in verify verify-windows; do grep -qx '    needs: \[plan, built\]' <<<"$(job release.yml $j)" || fail "$j does not need every build"; done
for j in build build-macos build-windows built verify verify-windows publish; do
  [[ "$(job release.yml $j | grep -c "^    if: needs.plan.outputs.version != ''$")" == 1 ]] || fail "$j runs without a version, or after a failure"
  grep -qE 'continue-on-error|always\(\)|!cancelled|failure\(\)' <<<"$(job release.yml $j)" && fail "$j goes on after a failure"
done
runner() { job "$1" "$2" | sed -n 's/^    runs-on: \([^ ]*\).*/\1/p'; }
[[ -n "$(runner pr.yml package-macos)" && "$(runner pr.yml package-macos)" == "$(runner release.yml build-macos)" ]] || fail "macOS is built on other runners in pr.yml"
[[ -n "$(runner pr.yml package-windows)" && "$(runner pr.yml package-windows)" == "$(runner release.yml build-windows)" && "$(runner pr.yml package-windows)" == "$(runner pr.yml windows-tests)" ]] || fail "Windows is built on other runners in pr.yml"
[[ "$(job pr.yml install-windows | grep -oE 'windows-[0-9]+' | sort -u)" == "$(job release.yml verify-windows | grep -oE 'windows-[0-9]+' | sort -u)" ]] || fail "other Windows installs in pr.yml"
inputs() { job "$1" "$2" | awk '/uses: .\/.github\/actions\/build-package/ { on = 1 } on && /^ +(os|arch|triple): / { print } on && /^      - / { exit }'; }
diff <(inputs pr.yml package-macos) <(inputs release.yml build-macos) && diff <(inputs pr.yml package) <(inputs release.yml build) && diff <(inputs pr.yml package-windows) <(inputs release.yml build-windows) || fail "other inputs in pr.yml"
for r in macos-15 macos-15-intel; do
  grep -q "runner: $r }" <<<"$(job pr.yml install-macos)" && grep -q "runner: $r }" <<<"$(job release.yml verify)" || fail "$r installs not in both"
done
# How an agent and a command know each other is tested with the optimised program that is released, as installed, on both systems.
for j in package install-macos; do
  step=$(job pr.yml $j | awk '/^      - / { on = 0 } /- name: The installed xless .*agent/ { on = 1 } on { print }')
  grep -qxF '          export XLESS_BIN="$HOME/.local/bin/xless"' <<<"$step" && grep -qE '^          for t in agent session( [a-z-]+)*; do .* "Tests/shell/\$t\.test\.sh"; done$' <<<"$step" || fail "$j tests no agent: $step"
  grep -q 'continue-on-error' <<<"$(job pr.yml $j)" && fail "$j goes on after a failure"
done
# The plan step, with stand-ins: what it says last is why nothing is released.
job release.yml plan | awk '/- name: Next version/ { on = 1 } on && /^        run: \|/ { body = 1; next } body && /^ {0,9}[^ ]/ { exit } body { sub(/^          /, ""); print }' > "$t/plan.sh"
grep -q next-version.sh "$t/plan.sh" || fail "no plan step: $(cat "$t/plan.sh")"
pl="$t/plan"; mkdir -p "$pl/scripts"
git init -q "$pl"; git -C "$pl" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m x
printf '#!/bin/sh\nexit 0\n' > "$pl/scripts/release-tag-check.sh"
plan() {  # <the next version> <whether CI passed> <event>
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$pl/scripts/next-version.sh"; printf '#!/bin/sh\necho "the pr workflow is still queued"; exit %s\n' "$2" > "$pl/scripts/ci-passed.sh"
  chmod +x "$pl/scripts"/*; : > "$t/github"
  rc=0; out=$(cd "$pl" && GITHUB_OUTPUT="$t/github" EVENT="$3" FIRST_VERSION='' bash -e "$t/plan.sh" 2>&1) || rc=$?
}
plan 1.5.0 0 schedule; [[ $rc == 0 && "$out" == *"Releasing v1.5.0"* ]] && grep -qx version=1.5.0 "$t/github" || fail "plan: $rc $out"
plan "" 0 schedule; [[ $rc == 0 && "$out" == "No releasable change." ]] && grep -qx version= "$t/github" || fail "nothing to release: $rc $out"
plan 1.5.0 1 schedule; [[ $rc == 0 && "$out" == *"::warning::not releasing v1.5.0"*"still queued"* && "$out" != *"No releasable change"* ]] && grep -qx version= "$t/github" || fail "a blocked night: $rc $out"
[[ "$(tail -n1 <<< "$out")" == *"Not releasing v1.5.0"* ]] || fail "a blocked night ends with: $out"
plan 1.5.0 1 workflow_dispatch; [[ $rc != 0 ]] || fail "a blocked dispatch succeeds"
echo "verify-release.test.sh: ok"
