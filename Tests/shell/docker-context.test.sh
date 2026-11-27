#!/usr/bin/env bash
# scripts/docker-context.sh's docker_context, as the scripts source it (set -euo pipefail): the context xless itself chooses
# (Sources/XlessCore/DockerContext.swift): DOCKER_CONTEXT when set, else colima-xless when docker has it, else none (docker's
# current one); a DOCKER_CONTEXT that docker does not have stops with exit 2 and the message xless prints, after docker is asked
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
printf '%s\n' $CONTEXTS ${DOCKER_CONTEXT:-}
EOF
chmod +x "$t/bin/docker"

# run CONTEXTS [DOCKER_CONTEXT]: docker_context in a shell of its own; its output, then its exit code, in $out and $code.
run() {
  : > "$t/log"; code=0
  out="$(PATH="$t/bin:/usr/bin:/bin" LOG="$t/log" CONTEXTS="$1" DOCKER_CONTEXT="${2:-}" bash -c '
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
want="some-script: DOCKER_CONTEXT is colima-xless (set in the environment), but docker has no context of that name; its contexts: colima, default; set DOCKER_CONTEXT to one of them in the environment, or remove it there: xless then uses colima-xless when that context exists, else docker's current one"
[[ "$out" == "$want" ]] || fail "the message: $out"
[[ "$(cat "$t/log")" == "-" ]] || fail "docker was asked with DOCKER_CONTEXT set: $(cat "$t/log")"
# a docker that cannot list its contexts: a set one goes to docker as it is (docker says the rest)
DOWN=1 run "" mine
[[ $code == 0 && "$out" == "[mine]" ]] || fail "a docker that does not answer: $code $out"
echo "PASS docker-context"
