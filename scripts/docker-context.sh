# shellcheck shell=bash
# The docker context of xless's scripts, chosen as xless chooses it (Sources/XlessCore/DockerContext.swift; docs/maintainers.md):
# DOCKER_CONTEXT when set (that of xless run's file of settings, XLESS_TESTFLIGHT_ENV else ~/.config/xless/testflight.env, winning
# over the environment's, as in xless); else, when DOCKER_HOST is set, docker's current one, DOCKER_HOST left in place; else
# colima-xless when docker has that context; else docker's current one. Docker's current one is printed as nothing: no --context.
# A DOCKER_CONTEXT that docker does not have stops the script, exit 2, with where it was set and the contexts there are.
#   . scripts/docker-context.sh
#   ctx="$(docker_context <script name>)" || exit 2
#   [[ -z "$ctx" ]] || unset DOCKER_HOST   # a chosen context is the docker (docker ranks DOCKER_HOST above DOCKER_CONTEXT)
docker_context() {
  local names name="" source="the environment" file line n=0 value
  # xless run's file, read as data: a DOCKER_CONTEXT line here is a plain name (bare, or in quotes), else the script stops
  # rather than guess what xless would make of it; the last one wins.
  file="${XLESS_TESTFLIGHT_ENV:-${HOME:-}/.config/xless/testflight.env}"
  if [[ -r "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?DOCKER_CONTEXT= ]] || continue
      value="${line#*DOCKER_CONTEXT=}"
      if [[ "$value" =~ ^([A-Za-z0-9._+-]*)([[:space:]]+(#.*)?)?$ || "$value" =~ ^\'([A-Za-z0-9._+-]*)\'([[:space:]]+(#.*)?)?$ \
            || "$value" =~ ^\"([A-Za-z0-9._+-]*)\"([[:space:]]+(#.*)?)?$ ]]; then
        name="${BASH_REMATCH[1]}" source="$file"
      else
        echo "${1:-xless}: DOCKER_CONTEXT in $file (line $n) is not a plain context name; write it there as one (e.g. DOCKER_CONTEXT=colima)" >&2
        return 2
      fi
    done < "$file"
  fi
  if [[ "$source" == "the environment" ]]; then name="${DOCKER_CONTEXT:-}"; fi
  # without the variable: docker lists the context it names as one of its own, even one it does not have; docker 23.0.0 and
  # 23.0.1 marked the current one with " *" even with --format
  names="$(env -u DOCKER_CONTEXT docker context ls --format '{{.Name}}' 2>/dev/null | sed 's/[[:space:]]*\*$//' || true)"
  if [[ -n "$name" ]]; then
    if [[ -n "$names" ]] && ! grep -qxF -- "$name" <<<"$names"; then
      echo "${1:-xless}: DOCKER_CONTEXT is $name (set in $source), but docker has no context of that name; its contexts: $(paste -sd, - <<<"$names" | sed 's/,/, /g');" \
        "set DOCKER_CONTEXT to one of them in $source, or remove it there: xless then uses colima-xless when that context exists and DOCKER_HOST is not set, else docker's current one" >&2
      return 2
    fi
    printf '%s\n' "$name"
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    return 0
  elif grep -qx colima-xless <<<"$names"; then
    echo colima-xless
  fi
}
