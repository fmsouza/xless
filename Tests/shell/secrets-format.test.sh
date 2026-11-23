#!/usr/bin/env bash
# `xless secrets …` on a store a newer xless wrote (store format 3, minimumReaderVersion 3), run against the built xless:
# list and status still read it, and every command that would change it (import, rm, passwd) refuses with an "upgrade
# xless" error before asking anything, leaving the file byte for byte as it was.
#   Tests/shell/secrets-format.test.sh     (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

vault="$t/home/.local/share/xless/vault"
mkdir -p "$vault"
chmod 700 "$t/home/.local/share/xless" "$vault"
# Nothing here is a real key: the commands under test must refuse before they unwrap anything.
cat > "$vault/secrets.vault" <<'JSON'
{
  "entries" : [
    {
      "kind" : "signing-key",
      "metadata" : { "teamID" : "ABCDE12345", "certificateType" : "DISTRIBUTION", "hue" : "from a newer xless" },
      "name" : "XLESS_DIST_KEY@ABCDE12345",
      "sealed" : "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      "version" : 3
    }
  ],
  "format" : "xless-vault",
  "future" : { "kept" : true },
  "id" : "00000000-0000-4000-8000-000000000000",
  "kdf" : { "algorithm" : "scrypt", "blockSize" : 8, "parallelism" : 1, "rounds" : 1024, "salt" : "AAAAAAAAAAAAAAAAAAAAAA==" },
  "keyCheck" : "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  "minimumReaderVersion" : 3,
  "version" : 3,
  "wrappedKey" : "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}
JSON
chmod 600 "$vault/secrets.vault"
cp "$vault/secrets.vault" "$t/before"
printf 'not a key\n' > "$t/note"

run() { # ARGS…: stdout → $t/out, stderr → $t/err, exit code → $code
  code=0
  env -i HOME="$t/home" PATH="/usr/bin:/bin" "$x" secrets "$@" >"$t/out" 2>"$t/err" </dev/null || code=$?
}
unchanged() { cmp -s "$t/before" "$vault/secrets.vault" || fail "$1 changed the store"; }
refused() { # NAME: exit 10 ([config]), the upgrade message, nothing asked, the store as it was
  [[ $code == 10 ]] || fail "$1: exit $code: $(cat "$t/err")"
  grep -q "written by a newer xless" "$t/err" || fail "$1: $(cat "$t/err")"
  grep -q "upgrade xless" "$t/err" || fail "$1: no upgrade fix: $(cat "$t/err")"
  if grep -qi "passphrase\|terminal" "$t/err"; then fail "$1 asked something first: $(cat "$t/err")"; fi
  unchanged "$1"
}

run list
[[ $code == 0 ]] || fail "list: exit $code: $(cat "$t/err")"
grep -q "^XLESS_DIST_KEY@ABCDE12345 *signing-key *ABCDE12345 .*DISTRIBUTION" "$t/out" || fail "list: $(cat "$t/out")"
run status
[[ $code == 0 ]] || fail "status: exit $code: $(cat "$t/err")"
grep -q "version 3 (written by a newer xless" "$t/out" || fail "status: $(cat "$t/out")"

run import NOTE --file "$t/note"; refused import
[[ -f "$t/note" ]] || fail "import deleted the file it did not import"
run rm XLESS_DIST_KEY@ABCDE12345 --yes; refused rm
run passwd; refused passwd
unchanged "the commands"
echo "secrets-format: ok"
