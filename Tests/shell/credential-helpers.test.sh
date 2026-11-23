#!/usr/bin/env bash
# The reference credential helpers (scripts/credential-helpers/), against stubs of `pass` and `secret-tool` that keep
# their entries as plain files: store / get / erase / list in xless's protocol, values byte for byte (quotes,
# backslashes, control characters, UTF-8, trailing newlines, empty), one keyring item per name, names refused, junk
# refused, and nothing printed but the answers. python3 builds the requests and checks the answers' JSON.
#   Tests/shell/credential-helpers.test.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/bin" "$t/home"

# pass: entries are $PASSWORD_STORE_DIR/<path>.gpg in clear; prints what the real one prints on stdout.
cat > "$t/bin/pass" <<'P'
#!/bin/sh
set -eu
d=$PASSWORD_STORE_DIR
case "$1" in
  insert)
    [ "$2" = --multiline ] && [ "$3" = --force ] || { echo "stub pass: unexpected $*" >&2; exit 9; }
    mkdir -p "$(dirname "$d/$4")"
    echo "Enter contents of $4 and press Ctrl+D when finished:"
    cat > "$d/$4.gpg" ;;
  show)
    [ -f "$d/$2.gpg" ] || { echo "Error: $2 is not in the password store." >&2; exit 1; }
    cat "$d/$2.gpg" ;;
  rm)
    [ "$2" = --recursive ] && [ "$3" = --force ] || exit 9
    rm -rf "${d:?}/$4"; echo "removed '$d/$4'" ;;
  *) exit 9 ;;
esac
P
# secret-tool, as libsecret's behaves: items are $SECRETS/<n>/{label,attrs,secret} ("key<TAB>value" lines); store
# replaces the item with exactly the same attributes, and keeps only the first 8191 bytes of a longer value ("password
# is too long" on stderr, exit 0); search prints paths, labels and values on stdout but the attributes on stderr.
cat > "$t/bin/secret-tool" <<'S'
#!/bin/sh
set -eu
d=$SECRETS
mkdir -p "$d"
verb=$1; shift
[ "$verb" != search ] || { [ "$1" = --all ] && shift; }
label=
if [ "$verb" = store ]; then label=${1#--label=}; shift; fi
want=$(while [ $# -gt 0 ]; do printf '%s\t%s\n' "$1" "$2"; shift 2; done)
matches() { printf '%s\n' "$want" | while IFS= read -r line; do grep -Fxq -- "$line" "$1/attrs" || exit 1; done; }
same() { [ "$(sort "$1/attrs")" = "$(printf '%s\n' "$want" | sort)" ]; }
case "$verb" in
  store)
    i=
    for j in "$d"/item*; do [ -d "$j" ] && same "$j" && i=$j; done
    if [ -z "$i" ]; then n=$(cat "$d/.next" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/.next"; i="$d/item$n"; mkdir "$i"; fi
    printf '%s' "$label" > "$i/label"; printf '%s\n' "$want" > "$i/attrs"
    head -c 8191 > "$i/secret"
    if [ -n "$(head -c 1)" ]; then echo "secret-tool: password is too long" >&2; fi ;;
  lookup)
    for i in "$d"/item*; do [ -d "$i" ] && matches "$i" && { cat "$i/secret"; exit 0; }; done; exit 1 ;;
  search)
    for i in "$d"/item*; do
      [ -d "$i" ] && matches "$i" || continue
      printf '[/org/freedesktop/secrets/collection/login/%s]\nlabel = %s\nsecret = ' "${i##*item}" "$(cat "$i/label")"
      cat "$i/secret"; printf '\ncreated = 2026-11-23 10:00:00\nmodified = 2026-11-23 10:00:00\nschema = org.freedesktop.Secret.Generic\n'
      sed 's/^\([^\t]*\)\t/attribute.\1 = /' "$i/attrs" >&2
    done ;;
  clear)
    for i in "$d"/item*; do [ -d "$i" ] && matches "$i" && rm -rf "$i"; done; exit 0 ;;
esac
S
chmod +x "$t/bin/pass" "$t/bin/secret-tool"

# request KIND NAME SECRET-FILE → the store request xless sends for it.
request() {
  python3 -I -c 'import json,sys
print(json.dumps({"ServerURL":"xless:"+sys.argv[1],"Username":json.dumps({"kind":sys.argv[2],"teamID":"ABCDE12345"},separators=(",",":")),
                  "Secret":open(sys.argv[3],"rb").read().decode()},ensure_ascii=False,separators=(",",":")),end="")' "$2" "$1" "$3"
}
# check_get ANSWER NAME SECRET-FILE KIND: the get answer is JSON with the name, the username and the exact secret.
check_get() {
  python3 -I -c 'import json,sys
a=json.loads(open(sys.argv[1]).read())
assert a["ServerURL"]=="xless:"+sys.argv[2], a
assert json.loads(a["Username"])["kind"]==sys.argv[4], a
assert a["Secret"].encode()==open(sys.argv[3],"rb").read(), (a["Secret"], open(sys.argv[3],"rb").read())' "$1" "$2" "$3" "$4"
}
# list_names ANSWER → the names it lists, sorted, one per line.
list_names() { python3 -I -c 'import json,sys
for k in sorted(json.loads(open(sys.argv[1]).read())): print(k)' "$1"; }

printf -- '-----BEGIN PRIVATE KEY-----\nMIGT"quo\\te/\tTAB\r\001\037\177 é 😀\n-----END PRIVATE KEY-----\n\n' > "$t/pem"
printf 'p4ss w0rd' > "$t/password"
: > "$t/empty"

for helper in pass secret-tool; do
  h="$repo/scripts/credential-helpers/xless-credential-$helper"
  rm -rf "$t/store" "$t/secrets"; mkdir -p "$t/store"
  run() { # VERB < stdin: answer → $t/out, messages → $t/err, exit code → $code
    code=0
    env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" PASSWORD_STORE_DIR="$t/store" SECRETS="$t/secrets" "$h" "$1" >"$t/out" 2>"$t/err" || code=$?
  }
  run list < /dev/null
  [[ $code == 0 && "$(cat "$t/out")" == "{}" ]] || fail "$helper: empty list: $code $(cat "$t/out" "$t/err")"

  for case in "ASC_KEY_P8@ABCDE12345 asc-api-key pem" "XLESS_DEMO_PASSWORD password password" "EMPTY generic empty"; do
    read -r name kind file <<<"$case"
    request "$kind" "$name" "$t/$file" > "$t/req"
    run store < "$t/req"
    [[ $code == 0 && ! -s "$t/out" ]] || fail "$helper: store $name: $code out=$(cat "$t/out") err=$(cat "$t/err")"
    printf 'xless:%s' "$name" > "$t/url"
    run get < "$t/url"
    [[ $code == 0 ]] || fail "$helper: get $name: $code $(cat "$t/err")"
    check_get "$t/out" "$name" "$t/$file" "$kind" || fail "$helper: get $name answered $(cat "$t/out")"
  done
  run list < /dev/null
  [[ $code == 0 ]] || fail "$helper: list: $(cat "$t/err")"
  [[ "$(list_names "$t/out")" == $'xless:ASC_KEY_P8@ABCDE12345\nxless:EMPTY\nxless:XLESS_DEMO_PASSWORD' ]] || fail "$helper: list: $(cat "$t/out")"
  python3 -I -c 'import json,sys
assert json.loads(json.loads(open(sys.argv[1]).read())["xless:ASC_KEY_P8@ABCDE12345"])=={"kind":"asc-api-key","teamID":"ABCDE12345"}' "$t/out" \
    || fail "$helper: list usernames: $(cat "$t/out")"

  # Storing a name again replaces it (one item, the new username).
  request generic XLESS_DEMO_PASSWORD "$t/pem" > "$t/req"
  run store < "$t/req"; [[ $code == 0 ]] || fail "$helper: restore: $(cat "$t/err")"
  printf 'xless:XLESS_DEMO_PASSWORD' | { run get; }
  check_get "$t/out" XLESS_DEMO_PASSWORD "$t/pem" generic || fail "$helper: replaced value: $(cat "$t/out")"
  run list < /dev/null
  [[ "$(list_names "$t/out" | grep -c DEMO)" == 1 ]] || fail "$helper: two items for one name: $(cat "$t/out")"

  # Erase, then it is not found.
  printf 'xless:EMPTY' > "$t/url"
  run erase < "$t/url"; [[ $code == 0 && ! -s "$t/out" ]] || fail "$helper: erase: $code $(cat "$t/out" "$t/err")"
  run get < "$t/url"
  [[ $code == 1 && "$(cat "$t/out")" == "credentials not found in native keychain" ]] || fail "$helper: erased get: $code $(cat "$t/out")"
  run erase < "$t/url"; [[ $code == 1 ]] || fail "$helper: erasing nothing succeeded"

  # Refusals: another credential, a bad name, junk, an unknown verb.
  printf 'https://index.docker.io/v1/' > "$t/url"; run get < "$t/url"; [[ $code != 0 ]] || fail "$helper: a foreign URL was read"
  printf 'xless:../x' > "$t/url"; run get < "$t/url"; [[ $code != 0 ]] || fail "$helper: a bad name was read"
  printf '{"ServerURL":"xless:A","Username":"{}"}' > "$t/req"; run store < "$t/req"; [[ $code != 0 ]] || fail "$helper: a store without Secret"
  printf 'not json' > "$t/req"; run store < "$t/req"; [[ $code != 0 ]] || fail "$helper: junk stored"
  printf '{"ServerURL":"xless:A","Username":"{}","Secret":"\\u00e9"}' > "$t/req"; run store < "$t/req"
  [[ $code != 0 ]] || fail "$helper: a \\u escape past ASCII was stored"
  grep -q 'UTF-8' "$t/err" || fail "$helper: a \\u escape past ASCII: $(cat "$t/err")"
  run frobnicate < /dev/null; [[ $code == 2 ]] || fail "$helper: unknown verb: $code"

  # 9000 bytes: pass keeps them all; secret-tool would cut them, so its helper refuses.
  head -c 9000 /dev/zero | tr '\0' 'k' > "$t/long"
  request generic LONG "$t/long" > "$t/req"
  run store < "$t/req"
  if [[ $helper == pass ]]; then
    [[ $code == 0 ]] || fail "pass: a 9000-byte value: $(cat "$t/err")"
    printf 'xless:LONG' > "$t/url"; run get < "$t/url"; check_get "$t/out" LONG "$t/long" generic || fail "pass: the long value came back different"
  else
    [[ $code != 0 ]] || fail "secret-tool: a 9000-byte value was stored (and cut)"
    grep -q "less than 8 KiB" "$t/err" || fail "secret-tool: $(cat "$t/err")"
  fi
done

# A keyring that cannot be searched is an error, never an empty list.
cat > "$t/bin/secret-tool" <<'S'
#!/bin/sh
echo "Cannot autolaunch D-Bus without X11 \$DISPLAY" >&2
exit 1
S
code=0; env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" "$repo/scripts/credential-helpers/xless-credential-secret-tool" list >"$t/out" 2>"$t/err" </dev/null || code=$?
[[ $code != 0 ]] || fail "an unreachable keyring listed as: $(cat "$t/out")"
grep -q 'D-Bus' "$t/err" || fail "the keyring's error was not shown: $(cat "$t/err")"
echo "credential-helpers: ok"
