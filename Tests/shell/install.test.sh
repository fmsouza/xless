#!/usr/bin/env bash
# scripts/install.sh, run under dash (the shell `curl … | sh` is on Debian/Ubuntu; plain sh when dash is missing) against a
# file:// release built with scripts/package-release.sh from a stub binary.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
sh_bin=$(command -v dash || command -v sh)
echo "install.sh runs under $sh_bin"
export XLESS_CHECKOUTS="$t/checkouts" XLESS_STRIP=true XLESS_CODESIGN=true XLESS_CHECK_BINARY=true
mkdir -p "$t/checkouts"
for id in $(sed -n 's/.*"identity" : "\(.*\)",/\1/p' "$repo/Package.resolved"); do
  mkdir -p "$t/checkouts/$id"; echo "licence of $id" > "$t/checkouts/$id/LICENSE"
done

# release <version>: a release directory with both arches of both systems at <rel>/download/v<version>/ (and /latest/download/ when asked).
rel="$t/rel"
release() {  # version [latest]
  local v=$1 d="$rel/download/v$1" a
  mkdir -p "$d"
  for a in x86_64 arm64; do
    printf '#!/bin/sh\necho "xless %s %s"\n' "$v" "$a" > "$t/stub-$a"; chmod +x "$t/stub-$a"
    bash "$repo/scripts/package-release.sh" "$v" "$a" "$t/stub-$a" "$d" >/dev/null
    printf '#!/bin/sh\necho "xless %s macos %s"\n' "$v" "$a" > "$t/stub-$a"
    bash "$repo/scripts/package-release.sh" --os macos "$v" "$a" "$t/stub-$a" "$d" >/dev/null
  done
  if [[ "${2:-}" == latest ]]; then rm -rf "$rel/latest"; mkdir -p "$rel/latest"; cp -R "$d" "$rel/latest/download"; fi
}
# A PATH with the tools the installer needs, a docker that works, and nothing else.
mkdir -p "$t/tools" "$t/tools-nodocker"
for c in curl tar gzip mktemp mv cp rm mkdir chmod cat awk sed grep uname dirname basename sha256sum shasum od tr head ls find sort wc cut date ln; do
  p=$(command -v "$c" 2>/dev/null || true)
  if [[ -n "$p" && "$p" == /* ]]; then ln -sf "$p" "$t/tools/$c"; ln -sf "$p" "$t/tools-nodocker/$c"; fi
done
printf '#!/bin/sh\nexit 0\n' > "$t/tools/docker"; chmod +x "$t/tools/docker"

run() {  # env... -- runs install.sh with the given extra env; sets $out and $rc
  rc=0; out=$(env "$@" "$sh_bin" "$repo/scripts/install.sh" 2>&1) || rc=$?
}
base=(XLESS_RELEASE_BASE="file://$rel" XLESS_UNAME_S=Linux XLESS_UNAME_M=x86_64 HOME="$t/home")
mkdir -p "$t/home"

release 1.2.3 latest

# Fresh install, latest, into a temp prefix on PATH.
p="$t/p1"
run "${base[@]}" XLESS_PREFIX="$p" PATH="$p/bin:$t/tools"
[[ $rc == 0 ]] || fail "fresh install exited $rc: $out"
[[ -x "$p/bin/xless" ]] || fail "no bin/xless"
[[ "$(cat "$p/share/xless/VERSION")" == 1.2.3 ]] || fail "VERSION"
[[ "$("$p/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "wrong binary installed"
echo "$out" | grep -qF "xless 1.2.3 installed to $p/bin/xless" || fail "no installed line: $out"
echo "$out" | grep -qF "next: xless setup --xcode ~/Downloads/Xcode_27.xip" || fail "no next line: $out"
echo "$out" | grep -q "export PATH=" && fail "PATH hint printed though prefix is on PATH"
echo "$out" | grep -qi "docker" && fail "docker mentioned: $out"
[[ -z "$(ls -A "$p/share" | grep -v '^xless$')" ]] || fail "temp files left in share: $(ls -A "$p/share")"

# --prefix works, and a newer pinned version replaces both.
release 1.3.0
rc=0; out=$(env "${base[@]}" XLESS_VERSION=v1.3.0 PATH="$p/bin:$t/tools" "$sh_bin" "$repo/scripts/install.sh" --prefix "$p" 2>&1) || rc=$?
[[ $rc == 0 ]] || fail "upgrade exited $rc: $out"
[[ "$(cat "$p/share/xless/VERSION")" == 1.3.0 ]] || fail "share not replaced"
[[ "$("$p/bin/xless")" == "xless 1.3.0 x86_64" ]] || fail "binary not replaced"

# The secret store lives in share/xless/vault when the prefix is ~/.local ($XDG_DATA_HOME/xless/vault): an upgrade keeps
# it, with its permissions, and a rollback puts it back.
mkdir -m 700 "$p/share/xless/vault"; (umask 077; echo sealed > "$p/share/xless/vault/secrets.vault"; : > "$p/share/xless/vault/lock")
rc=0; out=$(env "${base[@]}" XLESS_VERSION=v1.2.3 PATH="$p/bin:$t/tools" "$sh_bin" "$repo/scripts/install.sh" --prefix "$p" 2>&1) || rc=$?
[[ $rc == 0 && "$(cat "$p/share/xless/VERSION")" == 1.2.3 ]] || fail "downgrade with a store exited $rc: $out"
[[ "$(cat "$p/share/xless/vault/secrets.vault" 2>/dev/null)" == sealed && -e "$p/share/xless/vault/lock" ]] || fail "the upgrade lost the secret store"
[[ "$(ls -ld "$p/share/xless/vault" | cut -c1-10)" == drwx------ && "$(ls -l "$p/share/xless/vault/secrets.vault" | cut -c1-10)" == -rw------- ]] || fail "the store's permissions changed"
rc=0; out=$(env "${base[@]}" XLESS_VERSION=v1.3.0 PATH="$p/bin:$t/tools" "$sh_bin" "$repo/scripts/install.sh" --prefix "$p" 2>&1) || rc=$?
[[ $rc == 0 && "$(cat "$p/share/xless/vault/secrets.vault" 2>/dev/null)" == sealed ]] || fail "the second upgrade lost the secret store: $out"

# A pinned version uses /download/v<version>/ and nothing else.
rm -rf "$rel/latest"
run "${base[@]}" XLESS_PREFIX="$t/p2" XLESS_VERSION=v1.2.3 PATH="$t/p2/bin:$t/tools"
[[ $rc == 0 ]] || fail "pinned install without /latest exited $rc: $out"
[[ "$(cat "$t/p2/share/xless/VERSION")" == 1.2.3 ]] || fail "pinned VERSION"
run "${base[@]}" XLESS_PREFIX="$t/p2b" XLESS_VERSION=9.9.9 PATH="$t/p2b/bin:$t/tools"
[[ $rc == 1 ]] || fail "an unreleased version should exit 1, got $rc"
release 1.2.3 latest

# A tampered tarball: exit 1, nothing replaced.
p="$t/p3"
run "${base[@]}" XLESS_PREFIX="$p" XLESS_VERSION=1.2.3 PATH="$p/bin:$t/tools" >/dev/null
printf 'x' >> "$rel/download/v1.3.0/xless-1.3.0-linux-x86_64.tar.gz"
run "${base[@]}" XLESS_PREFIX="$p" XLESS_VERSION=1.3.0 PATH="$p/bin:$t/tools"
[[ $rc == 1 ]] || fail "tampered tarball exited $rc, want 1: $out"
echo "$out" | grep -qi "sha256\|checksum\|verif" || fail "no checksum message: $out"
[[ "$(cat "$p/share/xless/VERSION")" == 1.2.3 ]] || fail "share replaced by a tampered tarball"
[[ "$("$p/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "binary replaced by a tampered tarball"
release 1.3.0

# An https base: every fetch is https-only with TLS 1.2+, and `latest` is resolved to a version whose files are then fetched from
# download/v<version>/ (not latest/download/), so a release published in between cannot mix files.
mkdir -p "$t/tools-log"; cp -P "$t/tools"/* "$t/tools-log/"; rm -f "$t/tools-log/curl"
real_curl=$(command -v curl)
cat > "$t/tools-log/curl" <<C
#!/bin/sh
echo "\$*" >> "$t/curl.log"
args=""; skip=0
for a; do
  case "\$a" in
    --proto) skip=1 ;;
    '=https'|--tlsv1.2) ;;
    https://rel.test/*) set -- "\$@"; args="\$args file://$rel/\${a#https://rel.test/}" ;;
    *) args="\$args \$a" ;;
  esac
done
exec $real_curl \$args
C
chmod +x "$t/tools-log/curl"
: > "$t/curl.log"
run "${base[@]}" XLESS_RELEASE_BASE=https://rel.test XLESS_PREFIX="$t/ph" PATH="$t/ph/bin:$t/tools-log"
[[ $rc == 0 && "$("$t/ph/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "https latest install: rc=$rc $out"
[[ $(grep -c -e "--proto =https --tlsv1.2" "$t/curl.log") -eq $(wc -l < "$t/curl.log") ]] || fail "a fetch lacks --proto =https --tlsv1.2: $(cat "$t/curl.log")"
grep -q "https://rel.test/latest/download/SHA256SUMS" "$t/curl.log" || fail "latest not resolved through latest/download/SHA256SUMS: $(cat "$t/curl.log")"
grep -q "latest/download/xless-" "$t/curl.log" && fail "the tarball came from latest/download/: $(cat "$t/curl.log")"
grep -q "https://rel.test/download/v1.2.3/xless-1.2.3-linux-x86_64.tar.gz" "$t/curl.log" || fail "the tarball is not from download/v1.2.3/: $(cat "$t/curl.log")"
grep -q "https://rel.test/download/v1.2.3/SHA256SUMS" "$t/curl.log" || fail "SHA256SUMS not re-fetched from download/v1.2.3/: $(cat "$t/curl.log")"
# Truncated `curl | sh`: the script runs nothing until its last line, so a download cut anywhere installs nothing.
sed '$d' "$repo/scripts/install.sh" > "$t/cut.sh"
rc=0; out=$(env "${base[@]}" XLESS_PREFIX="$t/pt" PATH="$t/tools" "$sh_bin" "$t/cut.sh" 2>&1) || rc=$?
[[ $rc == 0 && ! -e "$t/pt" ]] || fail "a script cut before main ran something: rc=$rc $out"
tail -n 1 "$repo/scripts/install.sh" | grep -qx 'main "$@"' || fail "install.sh does not end with main \"\$@\""

# Architectures.
run "${base[@]}" XLESS_UNAME_M=aarch64 XLESS_PREFIX="$t/pa" PATH="$t/pa/bin:$t/tools"
[[ $rc == 0 && "$("$t/pa/bin/xless")" == "xless 1.2.3 arm64" ]] || fail "aarch64 should install arm64: $out"
run "${base[@]}" XLESS_UNAME_M=x86_64 XLESS_PREFIX="$t/px" PATH="$t/px/bin:$t/tools"
[[ $rc == 0 && "$("$t/px/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "x86_64 should install x86_64: $out"
run "${base[@]}" XLESS_UNAME_M=riscv64 XLESS_PREFIX="$t/pr" PATH="$t/pr/bin:$t/tools"
[[ $rc == 1 ]] || fail "riscv64 exited $rc"
echo "$out" | grep -qi "unsupported" || fail "riscv64: no 'unsupported': $out"
[[ ! -e "$t/pr/bin/xless" ]] || fail "riscv64 installed something"

# macOS: the macOS tarballs, from 14 on; a shell that Rosetta translates gets the Mac's own architecture.
mkdir -p "$t/tools-mac"; cp -P "$t/tools"/* "$t/tools-mac/"
fake() { printf '#!/bin/sh\n%s\n' "$2" > "$t/tools-mac/$1"; chmod +x "$t/tools-mac/$1"; }   # tool, what it does
mac=("${base[@]}" XLESS_UNAME_S=Darwin)
fake sw_vers '[ "$*" = -productVersion ] && echo 15.6.1'
fake sysctl '[ "$*" = "-n hw.optional.arm64" ] || exit 1; echo 1'
run "${mac[@]}" XLESS_UNAME_M=arm64 XLESS_PREFIX="$t/m1" PATH="$t/m1/bin:$t/tools-mac"
[[ $rc == 0 && "$("$t/m1/bin/xless")" == "xless 1.2.3 macos arm64" && "$(cat "$t/m1/share/xless/VERSION")" == 1.2.3 ]] || fail "an Apple silicon Mac: rc=$rc $out"
[[ "$out" == *"next: the account commands work now"*"xless setup --docker --xcode ~/Downloads/Xcode_27.xip"* ]] || fail "no next lines on macOS: $out"
run "${mac[@]}" XLESS_UNAME_M=x86_64 XLESS_VERSION=1.3.0 XLESS_PREFIX="$t/m1" PATH="$t/m1/bin:$t/tools-mac"
[[ $rc == 0 && "$("$t/m1/bin/xless")" == "xless 1.3.0 macos arm64" ]] || fail "a Rosetta shell: rc=$rc $out"
fake sysctl 'exit 1'
run "${mac[@]}" XLESS_UNAME_M=x86_64 XLESS_PREFIX="$t/m2" PATH="$t/m2/bin:$t/tools-mac"
[[ $rc == 0 && "$("$t/m2/bin/xless")" == "xless 1.2.3 macos x86_64" ]] || fail "an Intel Mac: rc=$rc $out"
for v in 13.7.8 12 10.15.7; do
  fake sw_vers "echo $v"
  run "${mac[@]}" XLESS_UNAME_M=arm64 XLESS_PREFIX="$t/m3" PATH="$t/m3/bin:$t/tools-mac"
  [[ $rc == 1 && "$out" == *"xless needs macOS 14 or later (this is macOS $v)"* && ! -e "$t/m3" ]] || fail "macOS $v: rc=$rc $out"
done
for v in 14.0 26.1 27.2.1; do
  fake sw_vers "echo $v"
  run "${mac[@]}" XLESS_UNAME_M=arm64 XLESS_PREFIX="$t/m4" PATH="$t/m4/bin:$t/tools-mac"
  [[ $rc == 0 ]] || fail "macOS $v: rc=$rc $out"
done
rm "$t/tools-mac/sw_vers" # not told: left to the program
run "${mac[@]}" XLESS_UNAME_M=arm64 XLESS_PREFIX="$t/m5" PATH="$t/m5/bin:$t/tools-mac"
[[ $rc == 0 ]] || fail "a macOS that tells no version: rc=$rc $out"
# A tampered macOS tarball installs nothing, nor does a release without one.
printf x >> "$rel/download/v1.3.0/xless-1.3.0-macos-arm64.tar.gz"
run "${mac[@]}" XLESS_UNAME_M=arm64 XLESS_VERSION=1.3.0 XLESS_PREFIX="$t/m5" PATH="$t/m5/bin:$t/tools-mac"
[[ $rc == 1 && "$out" == *"sha256 mismatch"* && "$("$t/m5/bin/xless")" == "xless 1.2.3 macos arm64" ]] || fail "a tampered macOS tarball: rc=$rc $out"
release 1.3.0
cp "$rel/latest/download/SHA256SUMS" "$t/sums"; grep -v macos "$t/sums" > "$rel/latest/download/SHA256SUMS"
run "${mac[@]}" XLESS_UNAME_M=arm64 XLESS_PREFIX="$t/m6" PATH="$t/m6/bin:$t/tools-mac"
[[ $rc == 1 && "$out" == *"the latest release lists no macos arm64 tarball"* && ! -e "$t/m6" ]] || fail "a release without macOS: rc=$rc $out"
cp "$t/sums" "$rel/latest/download/SHA256SUMS"
# Off PATH on macOS: nothing puts ~/.local/bin on PATH there, and the startup file is the one a login shell reads.
for s in /bin/zsh:.zshrc /bin/bash:.bash_profile /opt/fish:.profile; do
  run "${mac[@]}" XLESS_UNAME_M=arm64 SHELL="${s%%:*}" PATH="$t/tools-mac"
  [[ $rc == 0 && "$out" == *"$t/home/.local/bin is not on PATH in this shell. Run:"*"add that line to $t/home/${s##*:}."* && "$out" != *"new terminal"* ]] || fail "the PATH hint on macOS ($s): $out"
done
rm -rf "$t/home/.local"
run "${base[@]}" XLESS_UNAME_S=FreeBSD XLESS_PREFIX="$t/m7" PATH="$t/m7/bin:$t/tools"
[[ $rc == 1 && "$out" == *"unsupported OS FreeBSD: xless releases are for Linux and macOS 14 or later (x86_64 and arm64)"* ]] || fail "FreeBSD: rc=$rc $out"

# A prefix that is not on PATH gets the export line.
run "${base[@]}" XLESS_PREFIX="$t/pn" PATH="$t/tools"
[[ $rc == 0 ]] || fail "off-PATH install exited $rc"
echo "$out" | grep -qF "export PATH=\"$t/pn/bin:\$PATH\"" || fail "no export PATH line: $out"
echo "$out" | grep -qF "$t/pn/bin is not on PATH in this shell. Run:" || fail "the PATH hint does not say 'in this shell': $out"
echo "$out" | grep -qF "add that line to " || fail "the PATH hint does not name a startup file: $out"
echo "$out" | grep -q "new terminal" && fail "a custom prefix got the new-terminal hint (only ~/.local/bin is added at login): $out"
# The default prefix (~/.local) off PATH: a new terminal may already have it, as Ubuntu's ~/.profile adds ~/.local/bin.
run "${base[@]}" PATH="$t/tools"
[[ $rc == 0 ]] || fail "default-prefix install exited $rc: $out"
echo "$out" | grep -qF "$t/home/.local/bin is not on PATH in this shell. Open a new terminal" || fail "no new-terminal hint for ~/.local: $out"
echo "$out" | grep -qF "export PATH=\"$t/home/.local/bin:\$PATH\"" || fail "no export line for ~/.local: $out"

# No docker (it is only needed for --docker): exit 0, and no word of Docker.
run "${base[@]}" XLESS_PREFIX="$t/pd" PATH="$t/pd/bin:$t/tools-nodocker"
[[ $rc == 0 ]] || fail "no-docker install exited $rc: $out"
echo "$out" | grep -qi "docker" && fail "docker mentioned though setup installs natively: $out"
echo "$out" | grep -qF "next: xless setup --xcode" || fail "no next line without docker: $out"

# A failure after the share swap (the binary cannot be renamed into place) rolls everything back.
p="$t/p4"
run "${base[@]}" XLESS_PREFIX="$p" XLESS_VERSION=1.2.3 PATH="$p/bin:$t/tools" >/dev/null
mkdir -p "$t/tools-badmv"; cp -P "$t/tools"/* "$t/tools-badmv/"; rm "$t/tools-badmv/mv"
real_mv=$(command -v mv)
printf '#!/bin/sh\nfor a; do last=$a; done\ncase "$last" in */bin/xless) exit 1 ;; esac\nexec %s "$@"\n' "$real_mv" > "$t/tools-badmv/mv"; chmod +x "$t/tools-badmv/mv"
run "${base[@]}" XLESS_PREFIX="$p" XLESS_VERSION=1.3.0 PATH="$p/bin:$t/tools-badmv"
[[ $rc == 1 ]] || fail "failed binary rename exited $rc: $out"
[[ "$(cat "$p/share/xless/VERSION")" == 1.2.3 ]] || fail "share/ not rolled back"
[[ "$("$p/bin/xless")" == "xless 1.2.3 x86_64" ]] || fail "old binary lost"
[[ -z "$(ls -A "$p/share" | grep -v '^xless$')" ]] || fail "temp files left in share: $(ls -A "$p/share")"
[[ -z "$(ls -A "$p/bin" | grep -v '^xless$')" ]] || fail "temp binary left in bin: $(ls -A "$p/bin")"
# ... the secret store included.
mkdir -m 700 "$p/share/xless/vault"; echo sealed > "$p/share/xless/vault/secrets.vault"
run "${base[@]}" XLESS_PREFIX="$p" XLESS_VERSION=1.3.0 PATH="$p/bin:$t/tools-badmv"
[[ $rc == 1 && "$(cat "$p/share/xless/VERSION")" == 1.2.3 ]] || fail "failed upgrade with a store: rc=$rc $out"
[[ "$(cat "$p/share/xless/vault/secrets.vault" 2>/dev/null)" == sealed ]] || fail "the rollback lost the secret store"
# The same on a fresh prefix leaves no share/xless behind.
run "${base[@]}" XLESS_PREFIX="$t/p5" XLESS_VERSION=1.3.0 PATH="$t/p5/bin:$t/tools-badmv"
[[ $rc == 1 && ! -e "$t/p5/share/xless" && ! -e "$t/p5/bin/xless" ]] || fail "fresh failed install left files"

# A trailing slash on the prefix still counts as on PATH; HOME unset without a prefix is an error, not a crash.
run "${base[@]}" XLESS_PREFIX="$t/p6/" PATH="$t/p6/bin:$t/tools"
[[ $rc == 0 ]] || fail "trailing slash prefix exited $rc"
echo "$out" | grep -q "export PATH=" && fail "export PATH printed for an on-PATH prefix with a trailing slash"
rc=0; out=$(env -u HOME -u XLESS_PREFIX XLESS_RELEASE_BASE="file://$rel" XLESS_UNAME_S=Linux PATH="$t/tools" "$sh_bin" "$repo/scripts/install.sh" 2>&1) || rc=$?
[[ $rc == 1 ]] && echo "$out" | grep -q "HOME is unset" || fail "unset HOME: rc=$rc $out"

echo "install.test.sh: OK"
