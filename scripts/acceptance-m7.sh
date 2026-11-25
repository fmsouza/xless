#!/usr/bin/env bash
# The M7 acceptance kit (#105): takes samples/m7-acceptance from zero to the App Store on a real Apple account, from a
# Linux terminal, and records every command and its output, redacted, into docs/acceptance-m7.md.
#
# usage: scripts/acceptance-m7.sh                 walk #105's checklist: step 0 (live contract check), then 1 to 9
#        scripts/acceptance-m7.sh --contract      only the read-only live contract check (run it first, before any write)
#        scripts/acceptance-m7.sh --status        what is done, what is left
#        scripts/acceptance-m7.sh --dry-run       print every step's commands; run nothing
#        scripts/acceptance-m7.sh --cleanup       remove what the run created: testers, devices, profiles, certificates,
#                                                 auth keys and the API key (the app record cannot be deleted)
#        scripts/acceptance-m7.sh --wait          like the default, but step 6 polls App Review instead of stopping
#
# Resumable: a step that finished is skipped when the script runs again; a step that failed or stopped runs again from
# its start. App Review takes days: step 6 stops with exit code 75 while the version is in review; run the script again
# later. It pauses only where a person must act: the store's passphrase and the Apple ID sign-in (asked by xless itself,
# on the terminal, once: `xless unlock` and `xless auth login --keep` hold both for the steps that follow, and neither is
# asked again while it lasts), installing the TestFlight build on a device, and the closing question of step 9.
#
# Environment (read once and kept in the state file; the state wins afterwards):
#   XLESS_M7_TEAM            the Apple team ID (10 characters)                                       required
#   XLESS_M7_TESTER          the TestFlight tester's email (step 5; one of the team's users)          required
#   XLESS_M7_CONTACT_FIRST, XLESS_M7_CONTACT_LAST, XLESS_M7_CONTACT_PHONE, XLESS_M7_CONTACT_EMAIL
#                            App Review's contact (app.yml review.contact)                           required
#   XLESS_M7_BUNDLE_ID       a bundle ID never registered (default: dev.xless.m7.<random>)
#   XLESS_M7_APP_NAME        the App Store name, unique on the store (default: "xless M7 <random>")
#   XLESS_M7_SKU             default: from the bundle ID
#   XLESS_M7_COMPANY         the seller name, when this is the team's first app (provision --company-name)
#   XLESS_M7_DEVICE_UDID, XLESS_M7_DEVICE_NAME   optional: a device to register (and disable in --cleanup)
#   XLESS_M7_DIR             the state and the app's copy (default: ${XDG_STATE_HOME:-~/.local/state}/xless-m7)
#   XLESS_M7_RECORD          the record (default: docs/acceptance-m7.md of this checkout)
#   XLESS                    the xless to run (default: xless on PATH: the release candidate)
#   XLESS_M7_POLL            seconds between App Review checks with --wait (default 1800)
#   XLESS_M7_HUMAN=auto      answer every pause by itself (only for Tests/shell/acceptance-m7.test.sh)
set -euo pipefail
export LC_ALL=C

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XLESS="${XLESS:-xless}"
DIR="${XLESS_M7_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/xless-m7}"
STATE="$DIR/state"
RECORD="${XLESS_M7_RECORD:-$ROOT/docs/acceptance-m7.md}"
APP="$DIR/app"
HUMAN="${XLESS_M7_HUMAN:-ask}"
POLL="${XLESS_M7_POLL:-1800}"
BEGIN_MARK='<!-- acceptance-m7:record:begin -->'
END_MARK='<!-- acceptance-m7:record:end -->'
GROUP="M7 Acceptance"
# Exit codes: 0 done, 1 a check failed, 2 usage or setup, 75 come back later (App Review), 76 Apple rejected it.
EX_LATER=75; EX_REJECTED=76

mode=run; WAIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) mode=contract ;;
    --status) mode=status ;;
    --dry-run) mode=dry ;;
    --cleanup) mode=cleanup ;;
    --wait) WAIT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*" >&2; }
die() { printf 'acceptance-m7: %s\n' "$*" >&2; exit 2; }

# ---- state ---------------------------------------------------------------------------------------------------------
# key=value lines, one value per key, never a secret (IDs, names, the steps done).
state_get() { [[ -f "$STATE" ]] || return 0; awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' "$STATE"; }
state_set() {
  local tmp="$STATE.tmp.$$"
  { [[ ! -f "$STATE" ]] || awk -v k="$1" 'index($0, k "=") != 1' "$STATE"; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
  mv "$tmp" "$STATE"
}
done_step() { [[ "$(state_get "step.$1")" == "done" ]]; }

# A setting: the state's, else the environment's (kept from then on).
setting() {   # KEY ENVVAR [DEFAULT]
  local have env="${!2:-}"
  have="$(state_get "cfg.$1")"
  if [[ -n "$have" ]]; then
    [[ -z "$env" || "$env" == "$have" ]] || say "note: $2 is '$env' but this run started with '$have' (kept; remove $DIR to start over)"
    printf '%s' "$have"; return
  fi
  local value="${env:-${3:-}}"
  [[ -z "$value" ]] || state_set "cfg.$1" "$value"
  printf '%s' "$value"
}
need() { [[ -n "$2" ]] || die "set $1 first (see --help)"; }

# ---- redaction ----------------------------------------------------------------------------------------------------
# Everything recorded goes through `xless secrets redact` (the --verbose trace rules), plus the account's personal
# values: the Apple ID, the team, the tester, the review contact, the device. Without that command (an older xless),
# a fallback hides PEM blocks, JWTs and the same values.
HIDE_VARS=()
hide() {   # VALUE: never shown in the record (values under 3 characters would mangle the text: left alone)
  [[ ${#1} -ge 3 ]] || return 0
  local n
  for n in ${HIDE_VARS[@]+"${HIDE_VARS[@]}"}; do [[ "${!n}" != "$1" ]] || return 0; done
  local name="M7_HIDE_${#HIDE_VARS[@]}"
  export "$name=$1"; HIDE_VARS+=("$name")
}
# The values learnt from Apple along the way (state: appleid, issuer, teamname.N, provider.N): hidden from then on, and
# every part of the record is redacted again when it is rendered, so they are hidden in what came before they were known
# too.
hide_learnt() {
  local key
  [[ -f "$STATE" ]] || return 0
  while IFS= read -r key; do hide "$(state_get "$key")"; done < <(awk -F= '$1 == "appleid" || $1 == "issuer" || $1 ~ /^(teamname|provider)\./ { print $1 }' "$STATE")
}
have_redact=""
redact() { redact_secrets | tidy_paths; }
# This kit's directory and $HOME are shown as <kit> and ~ (the record is public; paths name the user).
tidy_paths() {
  awk -v a="$DIR" -v c="$HOME" '
    function swap(s, from, to,   i) { if (length(from) < 2) return s
      while ((i = index(s, from)) > 0) s = substr(s, 1, i - 1) to substr(s, i + length(from)); return s }
    { print swap(swap($0, a, "<kit>"), c, "~") }'
}
redact_secrets() {
  if [[ -z "$have_redact" ]]; then
    if "$XLESS" secrets redact </dev/null >/dev/null 2>&1; then have_redact=1; else have_redact=0; fi
  fi
  if [[ $have_redact == 1 ]]; then
    local args=() n
    for n in ${HIDE_VARS[@]+"${HIDE_VARS[@]}"}; do args+=(--hide-env "$n"); done
    "$XLESS" secrets redact ${args[@]+"${args[@]}"}
  else
    python3 -I -c '
import os, re, sys
text = sys.stdin.read()
text = re.sub(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", "<redacted>", text, flags=re.S)
text = re.sub(r"eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*", "<redacted>", text)
text = re.sub(r"(?im)^([<>] )?(cookie|set-cookie|authorization|scnt|x-apple-[a-z-]*(session|token)[a-z-]*): .*$", r"\1\2: <redacted>", text)
for k, v in sorted(((k, v) for k, v in os.environ.items() if k.startswith("M7_HIDE_") and v), key=lambda kv: -len(kv[1])):
    text = text.replace(v, "<redacted>")
sys.stdout.write(text)'
  fi
}

# ---- the record ---------------------------------------------------------------------------------------------------
# Each step's part is $DIR/record/<step>.md (redacted as it is written); render() puts the header, the results table
# and the parts between the markers of $RECORD, leaving the rest of the file (how to run the kit) alone.
STEP=0
frag() { printf '%s/record/%02d.md' "$DIR" "$STEP"; }
note() { printf '%s\n' "$*" | redact >> "$(frag)"; printf '%s\n' "$*" >&2; }

# Runs a command with its output on the terminal, and appends `$ command`, the output and the exit code, redacted, to
# the step's part. A secret never reaches the disk unredacted (personal values learnt later, such as the Apple ID of a
# first sign-in, are hidden when the record is rendered). Returns the command's exit code.
record() {
  local shown rc=0
  shown="$(printf '%q ' "$@")"; shown="${shown% }"
  [[ "$1" != "$XLESS" ]] || shown="xless${shown#"$(printf '%q' "$XLESS")"}"
  say "$shown"
  { printf '\n```console\n$ '; printf '%s\n' "$shown"; } | redact >> "$(frag)"
  # tee -a: appending, so a standard error that is a file is not truncated
  "$@" 2>&1 | tee -a /dev/stderr | redact >> "$(frag)" || rc=${PIPESTATUS[0]}
  printf '(exit %s)\n```\n' "$rc" >> "$(frag)"
  return "$rc"
}
xl() { record "$XLESS" "$@"; }

# Like xl, and keeps the command's standard output (JSON of IDs and states, no secret) in the file $1.
xl_keep() {
  local out="$1"; shift
  local shown rc=0
  shown="xless $(printf '%q ' "$@")"; shown="${shown% }"
  say "$shown"
  { printf '\n```console\n$ '; printf '%s\n' "$shown"; } | redact >> "$(frag)"
  { "$XLESS" "$@" 2>&1 1>&3 | tee -a /dev/stderr | redact >> "$(frag)" || rc=${PIPESTATUS[0]}; } 3> "$out"
  redact < "$out" >> "$(frag)"; cat "$out" >&2
  printf '(exit %s)\n```\n' "$rc" >> "$(frag)"
  return "$rc"
}

result() {   # STEP PASS|FAIL|PENDING|SKIPPED NOTE
  state_set "result.$1" "$2|$3"
  note "**Result: $2** — $3"
  render
}

step_titles=(
  "Live contract check: the list and get endpoints xless reads, decoded (read-only)"
  "Fresh Linux machine, xless from the release candidate, no ~/.config/xless, no key files"
  "xless auth login; xless auth api-key create (key in the store)"
  "A new sample app: never-registered bundle ID, push entitlement, appstore/ with two locales and screenshots"
  "xless provision plan, then apply; a second apply is a no-op"
  "xless auth logout; xless run ships to TestFlight using only the store; a tester gets the build"
  "xless release submit --release manual; status to Pending Developer Release; xless release publish"
  "Security: no secret under \$HOME but the vault, vault strings, process environments, core dumps, keyring, --verbose"
  "Docker: xless run --docker with the store; the build container never sees a secret"
  "Neither developer.apple.com nor appstoreconnect.apple.com was opened in a browser"
)

render() {
  local body="$DIR/rendered.$$" i r status text
  {
    printf '%s\n' "$BEGIN_MARK"
    printf '## Record\n\n'
    printf -- '- Started: %s; last updated: %s\n' "$(state_get started)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- Machine: %s\n' "$(state_get machine)"
    printf -- '- xless: %s\n' "$(state_get xless_version)"
    printf -- '- App: bundle ID %s, name "%s"\n\n' "\`$(state_get cfg.bundle)\`" "$(state_get cfg.name)"
    printf '| # | Criterion | Result |\n|---|---|---|\n'
    for i in "${!step_titles[@]}"; do
      r="$(state_get "result.$i")"; status="${r%%|*}"; text="${r#*|}"
      [[ -n "$r" ]] || { status="not run"; text=""; }
      printf '| %s | %s | **%s**%s |\n' "$i" "${step_titles[$i]}" "$status" "${text:+ — $text}"
    done
    for i in "${!step_titles[@]}"; do
      [[ -f "$(printf '%s/record/%02d.md' "$DIR" "$i")" ]] || continue
      printf '\n### %s. %s\n' "$i" "${step_titles[$i]}"
      cat "$(printf '%s/record/%02d.md' "$DIR" "$i")"
    done
    [[ ! -f "$DIR/record/cleanup.md" ]] || { printf '\n### Cleanup\n'; cat "$DIR/record/cleanup.md"; }
    printf '%s\n' "$END_MARK"
  } | redact > "$body"
  if [[ ! -f "$RECORD" ]] || ! grep -qF "$BEGIN_MARK" "$RECORD"; then
    { [[ ! -f "$RECORD" ]] || cat "$RECORD"; printf '\n'; cat "$body"; } > "$RECORD.tmp.$$"
  else
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v f="$body" '
      $0 == b { while ((getline line < f) > 0) print line; skip = 1; next }
      $0 == e { skip = 0; next }
      !skip' "$RECORD" > "$RECORD.tmp.$$"
  fi
  mv "$RECORD.tmp.$$" "$RECORD"; rm -f "$body"
}

# ---- people ---------------------------------------------------------------------------------------------------------
tty_ok() { [[ -r /dev/tty && -w /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }
# What was typed before a question is shown is no answer to it.
fresh_tty() { python3 -I -c 'import termios; termios.tcflush(0, termios.TCIFLUSH)' < /dev/tty 2>/dev/null || true; }
# Waits for a person: Enter goes on, "no" (or n) records that it did not happen. Returns 1 for no.
pause() {   # MESSAGE
  local answer
  if [[ "$HUMAN" == auto ]]; then note "(human step answered by the test harness: $1)"; return 0; fi
  tty_ok || die "a person is needed here and there is no terminal: $1"
  fresh_tty
  printf '\n*** %s\n*** Press Enter when done, or type no: ' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=no
  case "$answer" in n|N|no|NO|No) note "Person: \"$1\" — answered no."; return 1 ;; esac
  note "Person: \"$1\" — done ($(date -u +%Y-%m-%dT%H:%MZ))."
}
ask_yes() {   # QUESTION: yes → 0
  local answer
  if [[ "$HUMAN" == auto ]]; then note "(question answered no by the test harness: $1)"; return 1; fi
  tty_ok || die "a person is needed here and there is no terminal: $1"
  fresh_tty
  printf '\n*** %s [y/N] ' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=n
  case "$answer" in y|Y|yes|YES|Yes) note "Person: \"$1\" — yes."; return 0 ;; esac
  note "Person: \"$1\" — no."; return 1
}

# ---- helpers --------------------------------------------------------------------------------------------------------
json() {   # FILE EXPR: a Python expression over `d` (the parsed file); prints the result, one item per line for a list
  python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
try:
    r = eval(sys.argv[2], {"d": d})
except Exception:
    sys.exit(0)
if isinstance(r, list):
    print("\n".join(str(x) for x in r))
elif r is not None:
    print(r)' "$1" "$2"
}
ids() { json "$1" '[x.get("id") for x in (d.get("data", []) if isinstance(d, dict) else d) if isinstance(x, dict) and x.get("id")]'; }

session_kept() {
  local out="$DIR/tmp.status.json"
  "$XLESS" auth status --json > "$out" 2>/dev/null || true
  [[ "$(json "$out" 'd["session"]["state"]')" == kept ]] && { remember_apple_id "$out"; rm -f "$out"; return 0; }
  rm -f "$out"; return 1
}
# STATUS: what `xless auth status` says of the session or the store (kept, saved, none…; unlocked, locked, missing…)
held() { local out="$DIR/tmp.held.json"; "$XLESS" auth status --json > "$out" 2>/dev/null || true; json "$out" "d['$1']['state']"; rm -f "$out"; }
# One passphrase for the steps that follow, up front: nothing is asked while the store is unlocked, or when there is none.
unlock_store() {
  [[ "$(held store)" == locked ]] || return 0
  say "Unlocking the secret store for this terminal: xless asks its passphrase once for the next hour (xless lock ends it)"
  xl unlock --for 1h || note "The store could not be kept unlocked: each command that needs it asks its passphrase."
}
# STATUS-JSON: the Apple ID, the names of its teams (an individual's team is their name) and their App Store Connect
# provider IDs (live-check prints the current one).
remember_apple_id() {
  local id i=0 name out="$DIR/tmp.teams.json"
  id="$(json "$1" 'd["session"].get("appleID")')"
  [[ -z "$id" ]] || { state_set appleid "$id"; hide "$id"; }
  [[ -z "$(state_get teamname.0)" || -z "$(state_get provider.0)" ]] || return 0
  "$XLESS" team list --json > "$out" 2>/dev/null || true
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    state_set "teamname.$i" "$name"; hide "$name"; i=$((i + 1))
  done < <(json "$out" '[t.get("name") for t in d if isinstance(t, dict) and t.get("name")]')
  i=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    state_set "provider.$i" "$name"; hide "$name"; i=$((i + 1))
  done < <(json "$out" '[str(t["providerId"]) for t in d if isinstance(t, dict) and t.get("providerId")]')
  rm -f "$out"
}
sign_in() {   # only when no usable session is kept: keeps one for the steps that use the web session, its trace scanned
  session_kept && return 0
  if [[ "$(held session)" == saved ]]; then unlock_store; if session_kept; then return 0; fi; fi
  say "Signing in to Apple: xless asks the Apple ID, the password and the two-factor code on this terminal, once for the next 30 minutes"
  traced auth login --keep 30m --verbose
  state_set trace.login 1
  session_kept || true
}

# A traced command (a sign-in, the web session, the API): its trace is scanned for anything secret that came through
# unredacted, in memory; the record keeps the count of lines and the findings. Returns the command's exit code.
TRACE_RE='(^[<>] (Cookie|Set-Cookie|Authorization|scnt|X-Apple-ID-Session-Id|X-Apple-Session-Token|X-Apple-TwoSV-Trust-Token|X-Apple-HC|csrf|csrf_ts): (?!<redacted>))|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.|PRIVATE KEY|"(password|a|b|c|m1|m2|key|securityCode)": ?"(?!<redacted>)|[Bb]earer (?!<redacted>)'
traced() {
  local trace rc=0 counts n f
  say "xless $* (its trace is scanned, not recorded)"
  trace="$("$XLESS" "$@" 2>&1 >/dev/null)" || rc=$?
  counts="$(printf '%s\n' "$trace" | python3 -I -c '
import re, sys
pattern = re.compile(sys.argv[1], re.M)
n = f = 0
for line in sys.stdin:
    if not line.strip():
        continue
    n += 1
    if pattern.search(line):
        f += 1
        print("FINDING line %d: %s" % (n, pattern.search(line).group(0)[:40]), file=sys.stderr)
print(n, f)' "$TRACE_RE" 2> >(redact >> "$(frag)"))" || true
  n="${counts% *}"; f="${counts#* }"
  note "\`xless $*\`: ${n:-0} trace line(s), ${f:-0} finding(s)."
  state_set trace.lines $(( $(state_get trace.lines) + ${n:-0} ))
  state_set trace.findings $(( $(state_get trace.findings) + ${f:-0} ))
  [[ $rc == 0 ]] || { printf '%s\n' "$trace" | grep -v -E '^[<>] ' | tail -n 5 | redact | tee -a /dev/stderr >> "$(frag)" || true; note "(exit $rc)"; }
  return "$rc"
}
# The commands traced besides the sign-in, once: step 2 does it, while the session it needs is kept.
trace_commands() {
  [[ -z "$(state_get trace.commands)" ]] || return 0
  traced team list --verbose || true
  traced keys list --team "$TEAM" --verbose || true
  traced apps list --team "$TEAM" --verbose || true
  state_set trace.commands 1
}

ARCH="$(uname -m)"; case "$ARCH" in arm64|aarch64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac

# The names of secrets a process may not carry: xless's own, and anything named like a key, a password or a token.
SECRET_NAME_RE='(^|_)(KEY|P8|PEM|PASSWORD|PASSPHRASE|TOKEN|SECRET)(_|$)'
# Watches the environments and command lines of this script's descendants (xless, testflight.sh, docker, the build
# tools) until $DIR/watch.stop appears, or this script is gone, and writes what it finds to $1: variable names and
# process names, never a value. Variables already in this shell before the run (yours) are listed once and not counted.
# It prints nothing (start_watch): a person may be typing a passphrase meanwhile.
watch_processes() {   # OUT
  local out="$1" root="$$" seen=" " p env name comm line
  set +e   # a process that ends while it is read is no reason to stop
  : > "$out"
  while [[ ! -e "$DIR/watch.stop" ]] && kill -0 "$root"; do
    for p in $(descendants "$root"); do
      comm="$(proc_name "$p" | tr ' ' '_')"   # with the name: a process may exec another program
      [[ "$seen" != *" $p:$comm "* ]] || continue
      if ! env="$(proc_env "$p")"; then
        [[ "$seen" == *" u$p "* ]] || { seen+="u$p "; echo "unreadable $p $comm" >> "$out"; }
        continue
      fi
      seen+="$p:$comm "
      echo "scanned $p ${comm:-?}" >> "$out"
      while IFS= read -r line; do
        name="${line%%=*}"; [[ -n "$name" && "$line" == *=* ]] || continue
        [[ -n "${line#*=}" ]] || continue
        [[ "$name" != *_FILE && "$name" != XLESS_NO_SECRET_STORE ]] || continue
        [[ " $BASELINE_SECRETS " != *" $name "* ]] || continue
        if [[ "$name" =~ $SECRET_NAME_RE ]]; then echo "FOUND ${comm:-?}($p): environment variable $name" >> "$out"; fi
        case "${line#*=}" in *"PRIVATE KEY"*|eyJ*.*.*) echo "FOUND ${comm:-?}($p): $name holds key material or a token" >> "$out" ;; esac
      done <<< "$env"
      case "$(proc_args "$p")" in
        *"PRIVATE KEY"*|*eyJ*.*.*) echo "FOUND ${comm:-?}($p): key material or a token on its command line" >> "$out" ;;
      esac
    done
    sleep 0.5
  done
}
# A process's name, command line and environment (NAME=VALUE lines): from /proc, else (macOS) from ps, which shows no
# environment of the system's own programs.
if [[ -r /proc/self/environ ]]; then
  proc_name() { cat "/proc/$1/comm"; }
  proc_env() { [[ -r "/proc/$1/environ" ]] && tr '\0' '\n' < "/proc/$1/environ"; }
  proc_args() { tr '\0' ' ' < "/proc/$1/cmdline"; }
  proc_parents() {   # "pid ppid" lines (no ps needed)
    local f line pid rest
    for f in /proc/[0-9]*/stat; do
      IFS= read -r line < "$f" || continue
      pid="${f#/proc/}"; rest="${line##*) }"; rest="${rest#* }"
      echo "${pid%/stat} ${rest%% *}"
    done
  }
else
  proc_name() { local name; name="$(ps -o comm= -p "$1")"; printf '%s' "${name##*/}"; }
  proc_env() { local all; all="$(ps -Eww -o command= -p "$1")" && printf '%s\n' "${all#"$(proc_args "$1")"}" | tr ' ' '\n'; }
  proc_args() { ps -ww -o command= -p "$1"; }
  proc_parents() { ps -axo pid=,ppid=; }
fi
descendants() {   # PID: every process below it
  proc_parents | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      below[root] = 1
      do {
        changed = 0
        for (p in parent) if (!(p in below) && (parent[p] in below)) { below[p] = 1; changed = 1 }
      } while (changed)
      for (p in below) if (p != root) print p
    }'
}
WATCHERS=()
start_watch() { rm -f "$DIR/watch.stop"; watch_processes "$1" </dev/null >/dev/null 2>&1 & WATCHERS+=("$!"); }
start_container_watch() { watch_containers "$1" </dev/null >/dev/null 2>&1 & WATCHERS+=("$!"); }
stop_watch() { touch "$DIR/watch.stop"; wait ${WATCHERS[@]+"${WATCHERS[@]}"} 2>/dev/null || true; WATCHERS=(); rm -f "$DIR/watch.stop"; }
watch_summary() {   # FILE: one line, and FOUND lines in the record
  local scanned unreadable found
  scanned=$(grep -c '^scanned ' "$1" || true); unreadable=$(grep -c '^unreadable ' "$1" || true); found=$(grep -c '^FOUND ' "$1" || true)
  note "Processes watched during the run: $scanned read, $unreadable unreadable (gone before they were read, or non-dumpable: xless makes itself so while it holds a secret), $found finding(s)."
  grep '^FOUND ' "$1" | sort -u | redact >> "$(frag)" || true
  [[ "$found" == 0 ]]
}

# Docker: every container the run starts (label xless.run), sampled while it lives: its image, mounts and environment
# variable names (never their values).
watch_containers() {   # OUT
  local out="$1" seen=" " c
  set +e
  : > "$out"
  while [[ ! -e "$DIR/watch.stop" ]] && kill -0 "$$"; do
    for c in $(docker ps -q --filter label=xless.run 2>/dev/null || true); do
      [[ "$seen" != *" $c "* ]] || continue
      seen+="$c "
      docker inspect "$c" 2>/dev/null | python3 -I -c '
import json, re, sys
try:
    c = json.load(sys.stdin)[0]
except Exception:
    sys.exit(0)
env = c.get("Config", {}).get("Env") or []
names = sorted(e.split("=", 1)[0] for e in env)
# not a secret: the swift base image names the public key its tarballs are verified with (a fingerprint, nothing else)
env = [e for e in env if not re.fullmatch(r"SWIFT_SIGNING_KEY=[0-9A-F]{40}", e)]
secret = [e.split("=", 1)[0] for e in env if re.search(sys.argv[1], e.split("=", 1)[0]) and not e.split("=", 1)[0].endswith("_FILE")]
material = [e.split("=", 1)[0] for e in env if "PRIVATE KEY" in e or re.search(r"eyJ[\w-]*\.[\w-]+\.", e)]
mounts = sorted(m.get("Destination", "") for m in c.get("Mounts") or [])
args = " ".join(c.get("Args") or [])
print("container %s image=%s args=[%s] mounts=%s env=%s secrets=%s material=%s" % (
    c.get("Id", "")[:12], c.get("Config", {}).get("Image", "?"), args, ",".join(mounts), ",".join(names),
    ",".join(secret) or "-", ",".join(material) or "-"))' "$SECRET_NAME_RE" >> "$out" || true
    done
    sleep 1
  done
}

# Files under $HOME that hold an Apple private key (PKCS#8, EC or RSA PEM) or are named like one (.p8, .p12, AuthKey_*),
# outside the store, ~/.ssh and ~/.gnupg (not Apple's), this checkout and the kit's own directory.
secret_files() {
  local vault="${XDG_DATA_HOME:-$HOME/.local/share}/xless/vault"
  local prune=( \( -path "$ROOT" -o -path "$DIR" -o -path "$vault" -o -path "$HOME/.ssh" -o -path "$HOME/.gnupg" -o -name .git
                 -o -name node_modules -o -path "$HOME/.cache/xless/work" -o -path "$HOME/.cache/xless/downloads"
                 -o -path "$HOME/.cache/xless/inputs" -o -path "$HOME/.local/share/xless/sdk" -o -path "$HOME/.local/share/docker" \) -prune )
  {
    find "$HOME" -xdev "${prune[@]}" -o -type f \( -name '*.p8' -o -name '*.p12' -o -name '*.pfx' -o -name 'AuthKey_*' \) -print 2>/dev/null || true
    find "$HOME" -xdev "${prune[@]}" -o -type f -size -64k -exec grep -lIsE -- '-----BEGIN (EC |RSA |ENCRYPTED )?PRIVATE KEY-----' {} + 2>/dev/null || true
  } | sort -u
}

vault_file() { printf '%s/xless/vault/secrets.vault' "${XDG_DATA_HOME:-$HOME/.local/share}"; }

# ---- the steps ------------------------------------------------------------------------------------------------------
step0() {   # [NOTE] [sign-in]: the read-only live contract check (signs in first only when asked)
  local app_arg=() rc
  [[ "${2:-}" != sign-in ]] || sign_in
  [[ -z "$(state_get app_ready)" ]] || app_arg=(--app "$BUNDLE")
  set +e; XLESS_LIVE_APPLE=1 xl live-check --team "$TEAM" ${app_arg[@]+"${app_arg[@]}"}; rc=$?; set -e
  if [[ $rc == 0 ]]; then result 0 PASS "no endpoint failed${1:+ ($1)}"; return 0; fi
  result 0 FAIL "an endpoint answered in a way xless cannot read${1:+ ($1)}: fix xless before anything is written (docs/research/m7-live-checklist.md)"
  return 1
}

step1() {
  local version found ok=1
  version="$("$XLESS" --version 2>/dev/null || echo unknown)"
  state_set xless_version "$version"
  xl --version || true
  record uname -srm || true
  if [[ "$version" == 0.0.0-dev* || "$version" == unknown ]]; then note "xless $version is not a release: install the release candidate (README.md#install)."; ok=0; fi
  # `xless setup` leaves toolchain-meta.json there: only the account's files count (the saved team, the secrets file).
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/xless" f
  for f in config.yml testflight.env; do
    if [[ -e "$config/$f" ]]; then note "$config/$f exists."; ok=0; fi
  done
  if [[ -d "$config" ]]; then note "$config holds: $(find "$config" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | sort | tr '\n' ' ')"; else note "No $config."; fi
  if [[ -e "$(vault_file)" ]]; then note "A secret store already exists: $(vault_file)."; ok=0; else note "No secret store."; fi
  found="$(secret_files)"
  if [[ -n "$found" ]]; then note "Key files under \$HOME:"; printf '%s\n' "$found" | redact >> "$(frag)"; ok=0; else note "No key file under \$HOME."; fi
  if [[ $ok == 1 ]]; then result 1 PASS "fresh: $version, no configuration, no store, no key file"; return 0; fi
  if ask_yes "This machine is not fresh (see above). Go on anyway?"; then result 1 FAIL "not a fresh machine (the run went on)"; return 0; fi
  result 1 FAIL "not a fresh machine"; return 1
}

step2() {
  local out="$DIR/tmp.key.json" key
  if [[ ! -e "$(vault_file)" ]]; then xl secrets init || { result 2 FAIL "xless secrets init failed"; return 1; }; fi
  unlock_store
  sign_in
  xl auth status || true
  xl team use "$TEAM" || { result 2 FAIL "xless team use failed"; return 1; }
  key="$(state_get api_key_id)"
  if [[ -z "$key" ]]; then
    if ! xl_keep "$out" auth api-key create --name "xless M7 acceptance" --role ADMIN --team "$TEAM" --json; then
      rm -f "$out"; result 2 FAIL "xless auth api-key create failed"; return 1
    fi
    key="$(json "$out" 'd["keyID"]')"
    state_set issuer "$(json "$out" 'd.get("issuerID")')"; hide_learnt; rm -f "$out"
    [[ -n "$key" ]] || { result 2 FAIL "no key ID in the answer of xless auth api-key create"; return 1; }
    state_set api_key_id "$key"
  fi
  xl secrets list || true
  xl auth status --team "$TEAM" || true
  trace_commands
  result 2 PASS "API key $key created and kept in the store"
}

step3() {
  local out="$DIR/tmp.list.json"
  rm -rf "$APP"; mkdir -p "$APP"
  cp -R "$ROOT/samples/m7-acceptance/." "$APP/"
  rm -f "$APP/make-images.py"
  # The placeholders (samples/m7-acceptance/README.md).
  local f
  for f in "$APP/xless.yml" "$APP/appstore/app.yml"; do
    sed -e "s/com\.example\.xless\.m7/$BUNDLE/g" -e "s/ABCDE12345/$TEAM/g" -e "s/XLESSM7SKU/$SKU/g" "$f" > "$f.new"
    cat "$f.new" > "$f"; rm -f "$f.new"
  done
  python3 -I - "$APP/appstore/app.yml" <<'PY'
import os, sys
p = sys.argv[1]
s = open(p).read()
contact = '{ firstName: "%s", lastName: "%s", phone: "%s", email: "%s" }' % tuple(
    os.environ[k].replace('"', "'") for k in ("M7_FIRST", "M7_LAST", "M7_PHONE", "M7_EMAIL"))
s = s.replace('{ firstName: Contact, lastName: Placeholder, phone: "+1 555 0100", email: review@example.com }', contact)
open(p, "w").write(s)
PY
  for f in "$APP"/appstore/*/name.txt; do printf '%s\n' "$NAME" > "$f"; done
  if command -v git >/dev/null 2>&1; then
    { git -C "$APP" init -q && git -C "$APP" add -A && git -C "$APP" -c user.name=xless -c user.email=xless@localhost commit -qm "M7 acceptance app"; } || true
  fi
  note "The app's files:"
  { printf '```text\n'; (cd "$APP" && find . -path ./.git -prune -o -type f -print | sort); printf '```\n'; } | redact >> "$(frag)"
  record cat "$APP/xless.yml" "$APP/ios.entitlements" || true
  # Never registered: neither a bundle ID nor an app has it yet (skipped once step 4 made them).
  if [[ -z "$(state_get step.4.started)" ]]; then
    # (not recorded: the listing names every app of the team)
    "$XLESS" bundle-ids list --team "$TEAM" --json > "$out" 2>/dev/null || { rm -f "$out"; result 3 FAIL "xless bundle-ids list failed"; return 1; }
    if [[ -n "$(json "$out" "[x for x in d.get('data', []) if x.get('attributes', {}).get('identifier') == '$BUNDLE']")" ]]; then
      rm -f "$out"; result 3 FAIL "$BUNDLE is already registered: set another XLESS_M7_BUNDLE_ID and remove $DIR"; return 1
    fi
    rm -f "$out"
    note "\`xless bundle-ids list --json\` (not recorded: it names every app of the team): $BUNDLE is not registered."
  fi
  xl store validate --dir "$APP/appstore" || { result 3 FAIL "xless store validate refused the manifest"; return 1; }
  result 3 PASS "$BUNDLE, push entitlement, en-US and pt-BR, iPhone 6.9\" and iPad 13\" screenshots, free, every territory but China mainland"
}

# What exists before provisioning, so --cleanup removes only what this run made. A listing that fails is marked, and
# nothing of that kind is ever counted as made (so --cleanup never touches what was there before).
snapshot() {   # NAME
  local kind
  for kind in certs profiles keys; do
    rm -f "$DIR/$1.$kind.failed"
    if "$XLESS" "$kind" list --team "$TEAM" --json > "$DIR/tmp.$kind.json" 2>/dev/null; then
      ids "$DIR/tmp.$kind.json" | sort > "$DIR/$1.$kind"
    else
      : > "$DIR/$1.$kind"; touch "$DIR/$1.$kind.failed"
    fi
    rm -f "$DIR/tmp.$kind.json"
  done
}
made() {   # KIND: what appeared between the two snapshots
  if [[ -e "$DIR/before.$1.failed" || -e "$DIR/after.$1.failed" ]]; then
    : > "$DIR/made.$1"; note "The $1 could not be listed before or after: --cleanup leaves them alone."
  else
    comm -13 "$DIR/before.$1" "$DIR/after.$1" > "$DIR/made.$1"
  fi
}

step4() {
  local out="$DIR/tmp.plan.json" company=() steps dev
  state_set step.4.started 1
  sign_in
  [[ -f "$DIR/before.certs" ]] || snapshot before
  if [[ -n "$UDID" && -z "$(state_get device_id)" ]]; then
    if xl_keep "$out" devices register "${DEVICE_NAME:-xless M7 device}" "$UDID" --team "$TEAM" --json; then
      dev="$(json "$out" '(d.get("registered") or [{}])[0].get("id")')"   # never one that was there before
      [[ -z "$dev" ]] || state_set device_id "$dev"
    fi
    rm -f "$out"
  fi
  [[ -z "$COMPANY" ]] || company=(--company-name "$COMPANY")
  xl provision plan --project "$APP" || true
  if ! xl provision apply --project "$APP" --yes ${company[@]+"${company[@]}"}; then
    result 4 FAIL "xless provision apply stopped (re-run the script to continue from there)"; return 1
  fi
  state_set app_ready 1
  snapshot after
  local kind
  for kind in certs profiles keys; do made "$kind"; done
  note "Made by this run: $(grep -c . "$DIR/made.certs") certificate(s), $(grep -c . "$DIR/made.profiles") profile(s), $(grep -c . "$DIR/made.keys") auth key(s)."
  xl provision apply --project "$APP" --yes || { result 4 FAIL "the second xless provision apply failed"; return 1; }
  xl_keep "$out" provision plan --project "$APP" --json || true
  steps="$(json "$out" 'len(d["steps"])')"; rm -f "$out"
  [[ "$steps" == 0 ]] || { result 4 FAIL "after two applies the plan still has ${steps:-unknown} step(s)"; return 1; }
  xl store push --dir "$APP/appstore" --dry-run || true
  result 4 PASS "provisioned; a second apply had nothing to do (plan: 0 steps)"
}

# A build number never used by this run before: minutes since 1970 (as scripts/testflight.sh counts), at least one more
# than the last one taken.
next_build() {
  local n last
  n=$(( $(date +%s) / 60 )); last="$(state_get build.last)"
  [[ -z "$last" || $n -gt $last ]] || n=$(( last + 1 ))
  state_set build.last "$n"; printf '%s' "$n"
}

secret_env_names() { env | awk -F= -v re="$SECRET_NAME_RE" '$1 ~ re && $1 !~ /_FILE$/ && $1 != "XLESS_NO_SECRET_STORE" && $2 != "" { print $1 }' | sort; }

step5() {
  local rc watch="$DIR/watch.5" bad
  bad="$(env | awk -F= '$1 ~ /^(ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_P8|XLESS_DIST_KEY|XLESS_DEVID_KEY|XLESS_INSTALLER_KEY|XLESS_DEMO_PASSWORD)(_FILE)?$/ { print $1 }')"
  [[ -z "$bad" ]] || { result 5 FAIL "the environment sets $(echo "$bad" | tr '\n' ' ')— only the store may provide them"; return 1; }
  [[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/xless/testflight.env" ]] || { result 5 FAIL "${XDG_CONFIG_HOME:-$HOME/.config}/xless/testflight.env exists: only the store may provide the secrets"; return 1; }
  [[ -n "$(state_get build.5)" ]] || state_set build.5 "$(next_build)"
  if [[ -z "$(state_get shipped.5)" ]]; then
    xl auth logout || true
    if session_kept; then result 5 FAIL "a session is still kept after xless auth logout"; return 1; fi
    start_watch "$watch"
    set +e; XLESS_BUILD_NUMBER="$(state_get build.5)" xl run "$APP"; rc=$?; set -e
    stop_watch
    state_set watch.5 "$(grep -c '^FOUND ' "$watch" || true)"
    watch_summary "$watch" || true
    # a failed run takes a new build number next time (Apple refuses one it has, if the upload got through)
    [[ $rc == 0 ]] || { state_set build.5 ""; result 5 FAIL "xless run exited with $rc (run the script again: step 5 starts again)"; return 1; }
    state_set shipped.5 1
  fi
  if [[ -z "$(state_get tester_added)" ]]; then
    xl testflight testers add "$TESTER" --group "$GROUP" --app "$BUNDLE" --team "$TEAM" --yes || { result 5 FAIL "xless testflight testers add failed"; return 1; }
    state_set tester_added 1
  fi
  xl builds list --app "$BUNDLE" --team "$TEAM" || true
  if ! pause "Install build 1.0.0 ($(state_get build.5)) of \"$NAME\" from TestFlight (invitation sent to the tester) on a device and open it"; then
    result 5 FAIL "the build did not reach the tester's device"; return 1
  fi
  result 5 PASS "build $(state_get build.5) shipped with the store only, tester added to \"$GROUP\", installed on a device"
}

release_state() {   # prints the version state, or nothing (not recorded: the caller notes the state)
  local out="$DIR/tmp.release.json"
  "$XLESS" release status --dir "$APP/appstore" --team "$TEAM" --json > "$out" 2>/dev/null || true
  json "$out" '(lambda v: v.get("appVersionState") or v.get("appStoreState"))(d["version"]["attributes"])'
  rm -f "$out"
}

step6() {
  local rc st
  if [[ -z "$(state_get submitted)" ]]; then
    # step 5's build (the version's build number from xless.yml, the build number the run used)
    local version build
    version="$(awk -F': *' '$1 == "version" { v = $2; sub(/[[:space:]]*#.*$/, "", v); gsub(/["\047[:space:]]/, "", v); print v }' "$APP/xless.yml")"
    build="$version+$(state_get build.5)"
    xl release submit --dir "$APP/appstore" --team "$TEAM" --build "$build" --release manual --dry-run || true
    set +e; xl release submit --dir "$APP/appstore" --team "$TEAM" --build "$build" --release manual; rc=$?; set -e
    case "$rc" in
      0|22) state_set submitted "$(date -u +%Y-%m-%dT%H:%MZ)" ;;
      21) result 6 FAIL "the pre-flight refused the submission (nothing was sent): fix what it lists, then re-run"; return 1 ;;
      *) result 6 FAIL "xless release submit exited with $rc"; return 1 ;;
    esac
  fi
  while :; do
    st="$(release_state)"
    note "App Review: ${st:-unknown} ($(date -u +%Y-%m-%dT%H:%MZ))."
    case "$st" in
      PENDING_DEVELOPER_RELEASE) break ;;
      READY_FOR_SALE|READY_FOR_DISTRIBUTION|PROCESSING_FOR_DISTRIBUTION) state_set published 1; break ;;
      PREPARE_FOR_SUBMISSION|READY_FOR_REVIEW)
        state_set submitted ""
        result 6 FAIL "the version is not in review (${st:-no state read}): run the script again to submit it"
        return 1 ;;
      REJECTED|METADATA_REJECTED|INVALID_BINARY|DEVELOPER_REJECTED|UNRESOLVED_ISSUES)
        state_set submitted ""
        result 6 PENDING "Apple rejected it ($st): record the reason Apple sent (email) and the fix here, fix it, then re-run (it resubmits)"
        return $EX_REJECTED ;;
      *)
        if [[ $WAIT == 1 ]]; then sleep "$POLL"; continue; fi
        result 6 PENDING "in App Review (${st:-state not read this time}): run the script again later (or with --wait)"
        return $EX_LATER ;;
    esac
  done
  if [[ -z "$(state_get published)" ]]; then
    xl release publish --dir "$APP/appstore" --team "$TEAM" || { result 6 FAIL "xless release publish failed"; return 1; }
    state_set published 1
  fi
  xl release status --dir "$APP/appstore" --team "$TEAM" || true
  result 6 PASS "submitted, approved (Pending Developer Release) and published"
}

step7() {
  local ok=1 found vault keyring scan
  vault="$(vault_file)"
  # 1. secret files under $HOME
  found="$(secret_files)"
  if [[ -n "$found" ]]; then note "Key files under \$HOME (outside the store):"; printf '%s\n' "$found" | redact >> "$(frag)"; ok=0; else note "No key file under \$HOME but the store ($vault)."; fi
  # 2. no key material in the vault's strings
  if [[ -f "$vault" ]]; then
    scan="$( { if command -v strings >/dev/null 2>&1; then strings -n 8 "$vault"; else grep -a -o -E '[[:print:]]{8,}' "$vault"; fi; } |
      grep -c -E 'PRIVATE KEY|MIGHAgEAMBMGByqGSM49|MHcCAQEE|MIIEvQIBADANBgkqhkiG9w0BAQEF|MIIEpAIBAAKCAQEA|eyJ[A-Za-z0-9_-]+\.' || true)"
    note "strings on the store: $scan line(s) with key material or a token."
    [[ "$scan" == 0 ]] || ok=0
  else note "No store at $vault."; ok=0; fi
  # 3. process environments during the runs of steps 5 and 8
  note "Processes during xless run (step 5): $(state_get watch.5 || echo '?') finding(s); during xless run --docker (step 8): $(state_get watch.8 || echo 'not run yet') finding(s)."
  [[ "$(state_get watch.5)" == 0 ]] || ok=0
  # 4. core dumps since the run started
  if command -v coredumpctl >/dev/null 2>&1; then
    found="$(coredumpctl list --no-pager --since "$(state_get started_local)" 2>&1 | grep -v -i -E 'no coredumps found|^$' || true)"
    if [[ -n "$found" ]]; then record coredumpctl list --no-pager --since "$(state_get started_local)" || true; ok=0; else note "coredumpctl: no core dump since the run started."; fi
  else
    note "coredumpctl is not installed; kernel.core_pattern is $(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo '?')."
  fi
  # 5. --verbose traces: nothing secret. The sign-in's was scanned when it was made, the others' in step 2; what was not
  # (a session kept before the run, a run started by an older kit) is scanned now.
  if [[ -z "$(state_get trace.login)" ]]; then
    xl auth logout || true
    traced auth login --keep 10m --verbose || { result 7 FAIL "the traced sign-in failed"; return 1; }
    state_set trace.login 1
  fi
  if [[ -z "$(state_get trace.commands)" ]]; then sign_in; trace_commands; fi
  note "--verbose traces scanned: $(state_get trace.lines) line(s), $(state_get trace.findings) finding(s)."
  [[ "$(state_get trace.lines)" != 0 ]] || note "warning: the traces were empty."
  if [[ "$(state_get trace.findings)" != 0 ]]; then
    ok=0
    for found in login commands lines findings; do state_set "trace.$found" ""; done   # scanned again by the next run
  fi
  # 6. nothing is held after xless lock: the agent, and the kernel keyring
  xl lock || true
  if session_kept; then note "A session is still kept after xless lock."; ok=0; fi
  if [[ "$(held store)" == unlocked ]]; then note "The store is still unlocked after xless lock."; ok=0; fi
  keyring="$( { grep -i xless /proc/keys 2>/dev/null || true; if command -v keyctl >/dev/null 2>&1; then keyctl show @s 2>/dev/null; keyctl show @u 2>/dev/null; fi; } | grep -i xless || true)"
  if [[ -n "$keyring" ]]; then note "The kernel keyring still holds:"; printf '%s\n' "$keyring" | redact >> "$(frag)"; ok=0; else note "The kernel keyring holds no xless key after xless lock."; fi
  if [[ $ok == 1 ]]; then result 7 PASS "no secret file, store opaque, no secret in processes, no core dump, clean traces and keyring"; return 0; fi
  result 7 FAIL "see the findings above"; return 1
}

step8() {
  local rc watch="$DIR/watch.8" containers="$DIR/containers.8" ok=1 image="xless:local-$ARCH"
  command -v docker >/dev/null 2>&1 || { result 8 FAIL "docker is not installed"; return 1; }
  while ! docker image inspect "$image" >/dev/null 2>&1; do
    note "The image $image is missing."
    pause "Build the images once: xless setup --docker --xcode <Xcode.xip> (README.md#build-in-docker-instead)" || { result 8 FAIL "no xless images"; return 1; }
  done
  [[ -n "$(state_get build.8)" ]] || state_set build.8 "$(next_build)"
  local build; build="$(state_get build.8)"
  # An xless.yml project runs in one container that gets the secrets when it signs (scripts/testflight.sh); split it,
  # so the container that runs the app's build has none: build to finalize, then sign, package and upload.
  for half in build sign; do
    [[ -z "$(state_get "shipped.8.$half")" ]] || continue
    local args=(--to finalize); [[ $half == build ]] || args=(--from sign)
    start_watch "$watch.$half"; start_container_watch "$containers.$half"
    set +e; XLESS_BUILD_NUMBER="$build" xl run --docker "$APP" "${args[@]}"; rc=$?; set -e
    stop_watch
    note "Containers of the $half half:"; redact < "$containers.$half" >> "$(frag)"
    watch_summary "$watch.$half" || ok=0
    if [[ $rc != 0 ]]; then
      # again from the build, with a new build number (Apple refuses one it has)
      state_set shipped.8.build ""; state_set build.8 ""
      result 8 FAIL "xless run --docker ${args[*]} exited with $rc (run the script again: step 8 starts again)"; return 1
    fi
    state_set "shipped.8.$half" 1
  done
  state_set watch.8 "$(cat "$watch.build" "$watch.sign" 2>/dev/null | grep -c '^FOUND ' || true)"
  if [[ ! -s "$containers.build" ]]; then note "No build container was seen (sampled every second)."; ok=0; fi
  if grep -q -E 'mounts=[^ ]*/secrets|secrets=[^-]|material=[^-]' "$containers.build"; then note "A build container had a secret mount or variable."; ok=0; fi
  if [[ $ok == 1 ]]; then result 8 PASS "build $build: the build container had no secret mount or variable; only the signing container read the store"
  else
    # again from the build: what these containers showed would fail it every time
    state_set shipped.8.build ""; state_set shipped.8.sign ""; state_set build.8 ""
    result 8 FAIL "see the containers above (run the script again: step 8 starts again)"; return 1
  fi
}

step9() {
  if ask_yes "At any step, did you open developer.apple.com or appstoreconnect.apple.com in a browser?"; then
    result 9 FAIL "a portal was opened in a browser"; return 1
  fi
  result 9 PASS "no portal opened in a browser (the maintainer's word; Apple's emails were read)"
}

# ---- cleanup --------------------------------------------------------------------------------------------------------
cleanup() {
  local id kind
  STEP=cleanup
  frag() { printf '%s/record/cleanup.md' "$DIR"; }
  note "Cleanup of $(date -u +%Y-%m-%dT%H:%MZ):"
  unlock_store
  sign_in
  if [[ -n "$(state_get tester_added)" ]]; then
    if xl testflight testers remove "$TESTER" --app "$BUNDLE" --team "$TEAM" --yes; then state_set tester_added ""; fi
  fi
  id="$(state_get device_id)"
  if [[ -n "$id" ]] && xl devices disable "$id" --team "$TEAM" --yes; then state_set device_id ""; fi
  # A provision that stopped half-way never compared its snapshots: compare them now.
  if [[ -f "$DIR/before.certs" && ! -f "$DIR/made.certs" ]]; then
    snapshot after
    for kind in certs profiles keys; do made "$kind"; done
  fi
  for kind in profiles certs keys; do
    [[ -f "$DIR/made.$kind" ]] || continue
    : > "$DIR/left.$kind"
    while IFS= read -r -u 3 id; do
      [[ -n "$id" ]] || continue
      case "$kind" in
        profiles) xl profiles delete "$id" --team "$TEAM" --yes ;;
        certs) xl certs revoke "$id" --team "$TEAM" --yes ;;
        keys) xl keys revoke "$id" --team "$TEAM" --yes ;;
      esac || echo "$id" >> "$DIR/left.$kind"   # kept for the next --cleanup
    done 3< "$DIR/made.$kind"
    mv "$DIR/left.$kind" "$DIR/made.$kind"
  done
  id="$(state_get api_key_id)"
  if [[ -n "$id" ]] && xl auth api-key revoke "$id" --team "$TEAM" --yes; then state_set api_key_id ""; fi
  xl secrets list || true
  xl lock || true
  note "Left in place (Apple has no delete for them): the app record of $BUNDLE and its bundle ID, the TestFlight group, the uploaded builds (they expire after 90 days)."
  render
}

# ---- the plan, for --dry-run ----------------------------------------------------------------------------------------
dry_run() {
  cat <<EOF
The M7 acceptance (#105), as this script would run it (nothing is run now):

 0. XLESS_LIVE_APPLE=1 xless live-check --team <team> [--app <bundle ID>]
    (after: xless auth login --keep 30m --verbose, its trace scanned; here and below only when no session is kept)
    again at the end of step 2 (with the new API key) and of step 4 (with the app); a FAIL stops the run
 1. xless --version; checks: no ~/.config/xless, no store, no key file under \$HOME          (a person decides if not fresh)
 2. xless secrets init; xless unlock --for 1h (here and before the steps below, only when the store is locked);
    xless auth login --keep 30m --verbose; xless team use <team>;
    xless auth api-key create --name "xless M7 acceptance" --role ADMIN --json; xless auth status;
    --verbose traces of team list, keys list, apps list scanned
 3. copy samples/m7-acceptance to $APP, fill the placeholders; xless bundle-ids list --json (not registered yet);
    xless store validate --dir $APP/appstore
 4. xless auth login --keep 30m --verbose; [xless devices register]; xless provision plan --project $APP;
    xless provision apply --project $APP --yes [--company-name ...]; again; xless provision plan --json (0 steps)
 5. xless auth logout; xless run $APP (processes watched); xless testflight testers add <tester> --group "$GROUP" --app <bundle ID>
    PAUSE: install the TestFlight build on a device
 6. xless release submit --release manual (--dry-run first); xless release status --json until Pending Developer Release
    (exit 75: in review, run again later; 76: rejected, fix and run again); xless release publish
 7. key files under \$HOME; strings on the store; process environments of steps 5 and 8; coredumpctl;
    what the --verbose traces above held; xless lock; what xless auth status and the keyring still hold
 8. xless run --docker $APP --to finalize, then --from sign (containers inspected: no secret in the build one)
 9. QUESTION: was a portal opened in a browser?
--cleanup: testers remove, devices disable, profiles delete, certs revoke, keys revoke (those this run made), api-key revoke.

The record goes to $RECORD, the state to $STATE.
EOF
}

status() {
  local i r
  [[ -f "$STATE" ]] || { echo "Nothing done yet ($STATE does not exist)."; return 0; }
  echo "State: $STATE; record: $RECORD"
  echo "App: $(state_get cfg.bundle) \"$(state_get cfg.name)\", team $(state_get cfg.team)"
  for i in "${!step_titles[@]}"; do
    r="$(state_get "result.$i")"; r="${r%%|*}"   # PASS|FAIL|PENDING|SKIPPED, without the note
    printf '%2s. %-8s %s\n' "$i" "${r:--}" "${step_titles[$i]}"
  done
}

# ---- main -----------------------------------------------------------------------------------------------------------
case "$mode" in
  dry) dry_run; exit 0 ;;
  status) status; exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 is needed (it reads xless's JSON answers)"
command -v "$XLESS" >/dev/null 2>&1 || die "no xless on PATH: install the release candidate (README.md#install), or set XLESS"
mkdir -p "$DIR/record"; chmod 700 "$DIR"
[[ -n "$(state_get started)" ]] || { state_set started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; state_set started_local "$(date '+%Y-%m-%d %H:%M:%S')"; }
machine() {
  local os; os="$(awk -F= '$1 == "PRETTY_NAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release 2>/dev/null || true)"
  printf '%s, %s, kernel %s' "${os:-$(uname -s)}" "$(uname -m)" "$(uname -r)"
}
[[ -n "$(state_get machine)" ]] || state_set machine "$(machine)"
[[ -n "$(state_get xless_version)" ]] || state_set xless_version "$("$XLESS" --version 2>/dev/null || echo unknown)"

RANDOM_PART="$(state_get random)"; [[ -n "$RANDOM_PART" ]] || { RANDOM_PART="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; state_set random "$RANDOM_PART"; }
TEAM="$(setting team XLESS_M7_TEAM)"
need XLESS_M7_TEAM "$TEAM"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "XLESS_M7_TEAM=$TEAM is not a 10-character team ID"
BUNDLE="$(setting bundle XLESS_M7_BUNDLE_ID "dev.xless.m7.a$RANDOM_PART")"
[[ "$BUNDLE" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "XLESS_M7_BUNDLE_ID=$BUNDLE is not a bundle ID (letters, digits, hyphens and dots)"
NAME="$(setting name XLESS_M7_APP_NAME "xless M7 $RANDOM_PART")"
SKU="$(setting sku XLESS_M7_SKU "XLESSM7$(printf '%s' "$RANDOM_PART" | tr '[:lower:]' '[:upper:]')")"
COMPANY="$(setting company XLESS_M7_COMPANY)"
TESTER="$(setting tester XLESS_M7_TESTER)"
UDID="$(setting udid XLESS_M7_DEVICE_UDID)"
DEVICE_NAME="$(setting device_name XLESS_M7_DEVICE_NAME)"
M7_FIRST="$(setting contact_first XLESS_M7_CONTACT_FIRST)"; M7_LAST="$(setting contact_last XLESS_M7_CONTACT_LAST)"
M7_PHONE="$(setting contact_phone XLESS_M7_CONTACT_PHONE)"; M7_EMAIL="$(setting contact_email XLESS_M7_CONTACT_EMAIL)"
export M7_FIRST M7_LAST M7_PHONE M7_EMAIL
for v in "$TEAM" "$TESTER" "$UDID" "$M7_FIRST" "$M7_LAST" "$M7_PHONE" "$M7_EMAIL" "$DEVICE_NAME" "$COMPANY"; do hide "$v"; done
hide_learnt
# Secret-like variables already in this shell are the user's, not the run's: listed once, not counted.
BASELINE_SECRETS="$(secret_env_names | tr '\n' ' ')"

if [[ "$mode" == cleanup ]]; then cleanup; exit 0; fi
if [[ "$mode" == contract ]]; then STEP=0; step0 "on its own" sign-in; exit $?; fi

need XLESS_M7_TESTER "$TESTER"
need XLESS_M7_CONTACT_FIRST "$M7_FIRST"; need XLESS_M7_CONTACT_LAST "$M7_LAST"
need XLESS_M7_CONTACT_PHONE "$M7_PHONE"; need XLESS_M7_CONTACT_EMAIL "$M7_EMAIL"
if [[ -n "$BASELINE_SECRETS" ]]; then say "note: this shell already has $BASELINE_SECRETS(yours: not counted by the checks)"; fi
render

# Step 8 (Docker) runs before step 6: once App Review approves the version, Apple takes no more builds of it. Step 7
# reads what the watchers of steps 5 and 8 found.
for STEP in 0 1 2 3 4 5 8 6 7 9; do
  if done_step "$STEP"; then say "step $STEP: done before, skipped"; continue; fi
  say "step $STEP: ${step_titles[$STEP]}"
  printf '\n_%s_\n' "$(date -u +%Y-%m-%dT%H:%MZ)" >> "$(frag)"
  # Asked here, before the step's own work; steps 0, 1 and 9 need no store, steps 2 and 7 see to it themselves.
  case "$STEP" in 3|4|5|6|8) unlock_store ;; esac
  set +e; ( set -e; if [[ $STEP == 0 ]]; then step0 "" sign-in; else "step$STEP"; fi ); rc=$?; set -e
  hide_learnt
  if [[ $rc != 0 ]]; then render; say "stopped at step $STEP (exit $rc): run the script again to continue from there"; exit "$rc"; fi
  # The contract check again once a key (after step 2) and the app (after step 4) exist, before more is written.
  if [[ $STEP == 2 || $STEP == 4 ]]; then
    s=$STEP; STEP=0
    set +e; ( set -e; step0 "again after step $s" ); rc=$?; set -e
    STEP=$s
    if [[ $rc != 0 ]]; then render; exit 1; fi
  fi
  state_set "step.$STEP" "done"
  render
done
say "every step is done: the record is $RECORD"
