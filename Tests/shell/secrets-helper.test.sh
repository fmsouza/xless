#!/usr/bin/env bash
# `xless secrets …` with `secrets: { backend: helper, helper: pass }` in config.yml, run against the built xless, the
# shipped xless-credential-pass and a stub `pass` that keeps entries in clear: import, list, status, export, rm,
# materialize and init work on the helper; unlock/lock say there is nothing to do; passwd is refused; a missing or
# unsafe helper and a broken setting are errors that say so; the vault is never created.
#   Tests/shell/secrets-helper.test.sh     (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
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

mkdir -p "$t/bin" "$t/tools" "$t/home/.config/xless" "$t/run"
chmod 700 "$t/run"
install -m 755 "$repo/scripts/credential-helpers/xless-credential-pass" "$t/bin/xless-credential-pass"
cat > "$t/tools/pass" <<'P'
#!/bin/sh
set -eu
d=$PASSWORD_STORE_DIR
case "$1" in
  insert) mkdir -p "$(dirname "$d/$4")"; echo "Enter contents of $4:"; cat > "$d/$4.gpg" ;;
  show) [ -f "$d/$2.gpg" ] || exit 1; cat "$d/$2.gpg" ;;
  rm) rm -rf "${d:?}/$4" ;;
esac
P
chmod 755 "$t/tools/pass"
config="$t/home/.config/xless/config.yml"
printf 'team: ABCDE12345\nsecrets:\n  backend: helper\n  helper: pass\n' > "$config"
ok() { [[ $code == 0 ]] || fail "$1: exit $code: $(cat "$t/err")"; }
refused() { [[ $code != 0 ]] || fail "$1: it succeeded"; grep -q -- "$2" "$t/err" || fail "$1: $(cat "$t/err")"; }
says() { grep -q -- "$2" "$t/${3:-out}" || fail "$1: $(cat "$t/${3:-out}")"; }
run() { # ARGS…: stdout → $t/out, stderr → $t/err, exit code → $code
  code=0
  env -i HOME="$t/home" PATH="$t/bin:$t/tools:/usr/bin:/bin" PASSWORD_STORE_DIR="$t/pw" XDG_RUNTIME_DIR="$t/run" \
    "$x" secrets "$@" >"$t/out" 2>"$t/err" </dev/null || code=$?
}

run list; ok "empty list"; says "empty list" "empty"
run init; ok init; says init "there is no store to create"

printf -- '-----BEGIN PRIVATE KEY-----\nnot a real key\n-----END PRIVATE KEY-----\n' > "$t/dist.pem"
printf 'hunter2 "quoted" \\ back\n' > "$t/password"
run import XLESS_DIST_KEY@ABCDE12345 --file "$t/dist.pem" --team-id ABCDE12345 --kind generic; ok "import key"
run import XLESS_DEMO_PASSWORD --file "$t/password" --remember 5m; ok "import password"
says "import --remember" "remember is for the encrypted vault" err
[[ -f "$t/pw/xless/XLESS_DIST_KEY@ABCDE12345/secret.gpg" ]] || fail "the key is not in pass"
cmp -s "$t/password" "$t/pw/xless/XLESS_DEMO_PASSWORD/secret.gpg" || fail "the password changed on its way to pass"
[[ ! -e "$t/home/.local/share/xless/vault" ]] || fail "a vault was created"
run import XLESS_DEMO_PASSWORD --file "$t/password"; refused "a second import" "already has an entry XLESS_DEMO_PASSWORD"

run list; ok list
says list "^XLESS_DIST_KEY@ABCDE12345 *generic *ABCDE12345"
says list "^XLESS_DEMO_PASSWORD *password"
if grep -q hunter2 "$t/out"; then fail "list printed a value"; fi
run status; ok status; says status "credential helper xless-credential-pass"; says status "Entries:  2"

run export XLESS_DEMO_PASSWORD --out "$t/exported"; ok export
cmp -s "$t/password" "$t/exported" || fail "the exported password differs"
run materialize --team ABCDE12345 --allow-disk sign=XLESS_DIST_KEY; ok materialize
cmp -s "$t/dist.pem" "$(head -1 "$t/out")/sign/XLESS_DIST_KEY" || fail "the materialized key differs"
run materialize --check sign=XLESS_INSTALLER_KEY; refused "materialize --check of a missing key" "credential helper"

run unlock --remember 5m; ok unlock; says unlock "nothing to do"
run lock; ok lock; says lock "nothing to do"
run passwd; refused passwd "is for the encrypted vault"

run rm XLESS_DEMO_PASSWORD --yes; ok rm
[[ ! -e "$t/pw/xless/XLESS_DEMO_PASSWORD" ]] || fail "rm left the entry in pass"

# An unsafe helper, a missing one, a broken setting: errors that say what to fix.
chmod 775 "$t/bin/xless-credential-pass"
run list; refused "a group-writable helper" "can be written by other users"
rm "$t/bin/xless-credential-pass"
run list; refused "a missing helper" "is not on PATH"
printf 'secrets:\n  backend: keychain\n' > "$config"
run list; refused "a broken setting" "neither vault nor helper"
echo "secrets-helper: ok"
