# shellcheck shell=bash
# The docker context of xless's scripts, chosen as xless chooses it (Sources/XlessCore/DockerContext.swift; docs/maintainers.md):
# DOCKER_CONTEXT when set, else colima-xless when docker has that context, else docker's current one (printed as nothing: no
# --context). A DOCKER_CONTEXT that docker does not have stops the script, exit 2, with the contexts there are.
#   . scripts/docker-context.sh
#   ctx="$(docker_context <script name>)" || exit 2
docker_context() {
  local names
  # without the variable: docker lists the context it names as one of its own, even one it does not have
  names="$(env -u DOCKER_CONTEXT docker context ls --format '{{.Name}}' 2>/dev/null || true)"
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    if [[ -n "$names" ]] && ! grep -qxF -- "$DOCKER_CONTEXT" <<<"$names"; then
      echo "${1:-xless}: DOCKER_CONTEXT is $DOCKER_CONTEXT (set in the environment), but docker has no context of that name; its contexts: $(paste -sd, - <<<"$names" | sed 's/,/, /g');" \
        "set DOCKER_CONTEXT to one of them in the environment, or remove it there: xless then uses colima-xless when that context exists, else docker's current one" >&2
      return 2
    fi
    printf '%s\n' "$DOCKER_CONTEXT"
  elif grep -qx colima-xless <<<"$names"; then
    echo colima-xless
  fi
}
