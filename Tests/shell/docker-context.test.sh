#!/usr/bin/env bash
# scripts/docker-context.sh's docker_context, as the scripts source it (set -euo pipefail): the context xless itself chooses
# (Sources/XlessCore/DockerContext.swift): DOCKER_CONTEXT when set (xless run's testflight.env's winning), else none when DOCKER_HOST
# is set, else colima-xless when docker has it, else none (docker's current one); a DOCKER_CONTEXT that docker does not have stops with exit 2 and the message xless prints, after docker is asked
# for its contexts without the variable (it lists the one the variable names as its own).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A fake docker whose contexts are $CONTEXTS (and DOCKER_CONTEXT's, as docker lists it); it records the variable it was given.
mkdir -p "$t/bin"
cat > "$t/bin/docker" <<'EOF'
#!/bin/sh
echo "${DOCKER_CONTEXT:--}" >> "$LOG"
[ "$*" = "context ls --format {{.Name}}" ] || exit 1
[ "${DOWN:-0}" != 1 ] || exit 1
[ -z "${RAW:-}" ] || { printf '%b' "$RAW"; exit 0; }   # a listing as it is, " *" marks and all
printf '%s\n' $CONTEXTS ${DOCKER_CONTEXT:-}
EOF
chmod +x "$t/bin/docker"

# run CONTEXTS [DOCKER_CONTEXT]: docker_context in a shell of its own (a home of its own, DOCKER_HOST and XLESS_TESTFLIGHT_ENV as
# $host and $envfile say); its output, then its exit code, in $out and $code.
host="" envfile=""
mkdir -p "$t/home"
run() {
  : > "$t/log"; code=0
  out="$(PATH="$t/bin:/usr/bin:/bin" HOME="$t/home" LOG="$t/log" CONTEXTS="$1" DOCKER_CONTEXT="${2:-}" DOCKER_HOST="$host" \
    XLESS_TESTFLIGHT_ENV="$envfile" bash -c '
    set -euo pipefail
    . "$1/scripts/docker-context.sh"
    ctx="$(docker_context some-script)" || exit $?
    printf "[%s]" "$ctx"' sh "$repo" 2>&1)" || code=$?
}

run "default colima-xless"
[[ $code == 0 && "$out" == "[colima-xless]" ]] || fail "colima-xless is not preferred: $code $out"
run "default colima"
[[ $code == 0 && "$out" == "[]" ]] || fail "docker's current one is not left to docker: $code $out"
run "default colima-xless mine" mine
[[ $code == 0 && "$out" == "[mine]" ]] || fail "a set context docker has is not used: $code $out"
run "colima default" colima-xless
[[ $code == 2 ]] || fail "a context docker does not have: exit $code: $out"
want="some-script: DOCKER_CONTEXT is colima-xless (set in the environment), but docker has no context of that name; its contexts: colima, default; set DOCKER_CONTEXT to one of them in the environment, or remove it there: xless then uses colima-xless when that context exists and DOCKER_HOST is not set, else docker's current one"
[[ "$out" == "$want" ]] || fail "the message: $out"
[[ "$(cat "$t/log")" == "-" ]] || fail "docker was asked with DOCKER_CONTEXT set: $(cat "$t/log")"
# a docker that cannot list its contexts: a set one goes to docker as it is (docker says the rest)
DOWN=1 run "" mine
[[ $code == 0 && "$out" == "[mine]" ]] || fail "a docker that does not answer: $code $out"
# a DOCKER_HOST that is set is kept when no DOCKER_CONTEXT is: docker's current one; a DOCKER_CONTEXT that is set wins
host=tcp://build:2376 run "default colima-xless"
[[ $code == 0 && "$out" == "[]" ]] || fail "a DOCKER_HOST that is set is not kept: $code $out"
host=tcp://build:2376 run "default colima-xless mine" mine
[[ $code == 0 && "$out" == "[mine]" ]] || fail "a DOCKER_CONTEXT does not win over DOCKER_HOST: $code $out"
# docker 23.0.0 and 23.0.1 marked the current context with " *" even with --format
RAW='default *\ncolima-xless\n' run ""
[[ $code == 0 && "$out" == "[colima-xless]" ]] || fail "a marked listing: $code $out"
RAW='colima-xless *\ndefault\n' run "" colima-xless
[[ $code == 0 && "$out" == "[colima-xless]" ]] || fail "a marked current context is not one docker has: $code $out"
# xless run's file of settings, as xless reads it: XLESS_TESTFLIGHT_ENV, else ~/.config/xless/testflight.env; its DOCKER_CONTEXT
# (the last) wins over the environment's, and a refusal names it
mkdir -p "$t/home/.config/xless"
printf '# settings\nA=1\nDOCKER_CONTEXT=gone\nexport DOCKER_CONTEXT="mine" # the one\n' > "$t/home/.config/xless/testflight.env"
run "default mine" other
[[ $code == 0 && "$out" == "[mine]" ]] || fail "the file's DOCKER_CONTEXT is not used: $code $out"
printf "DOCKER_CONTEXT='gone'\n" > "$t/other.env"
envfile="$t/other.env" run "default mine"
[[ $code == 2 && "$out" == "some-script: DOCKER_CONTEXT is gone (set in $t/other.env), but docker has no context of that name; its contexts: default, mine;"* ]] \
  || fail "XLESS_TESTFLIGHT_ENV's file: $code $out"
# the script reads a plain name alone; anything else there it does not guess at
# shellcheck disable=SC2016 # (written as it is)
printf 'DOCKER_CONTEXT=$(nope)\n' > "$t/other.env"
envfile="$t/other.env" run "default mine"
[[ $code == 2 && "$out" == "some-script: DOCKER_CONTEXT in $t/other.env (line 1) is not a plain context name; write it there as one (e.g. DOCKER_CONTEXT=colima)" ]] \
  || fail "an unreadable DOCKER_CONTEXT line: $code $out"
# shellcheck disable=SC2016 # (written as it is)
printf 'B=$(not read here)\n' > "$t/other.env"
envfile="$t/other.env" run "default colima-xless"
[[ $code == 0 && "$out" == "[colima-xless]" ]] || fail "another variable's line is read: $code $out"
echo "PASS docker-context"
