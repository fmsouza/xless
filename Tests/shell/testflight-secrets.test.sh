#!/usr/bin/env bash
# xless run with the secret store (fmsouza/xless#102): a secret whose *_FILE variable is not set comes from
# the store. In docker, the host's xless writes them once (`xless secrets materialize`) into a fresh run directory, one
# set per container, each mounted read-only into its container only and removed when it ends; the rest goes when the
# run ends, fails, or is stopped by INT, TERM or HUP. Natively, xless reads the store itself (checked up front), and the
# build step cannot open it. A fake xless stands in for the store, a fake docker logs what each container gets.
set -euo pipefail
t=$(mktemp -d)
. "$(dirname "$0")/run-entry.sh"
bg=()
finally() { local p; for p in ${bg[@]+"${bg[@]}"}; do kill "$p" 2>/dev/null || true; done; rm -rf "$t"; }
trap finally EXIT
fail() { echo "FAIL: $*"; exit 1; }
waitfor() { local _; for _ in $(seq 100); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }   # RE FILE
mkdir -p "$t/proj" "$t/bin" "$t/home" "$t/run" "$t/ov/app" "$t/keys"
chmod 700 "$t/run"
printf 'teamID: ABCDE12345\n' > "$t/proj/xless.yml"
printf 'type: tauri\nsource: app\nbundleID: com.example.x\nteamID: ABCDE12345\n' > "$t/ov/app.yml"
RUN="$t/run/xless/0123456789abcdef0123456789abcdef"

# The fake xless: `secrets materialize` writes each SET=NAME,… as $RUN/SET/NAME, printing $RUN first (MAT_EXIT: fails
# instead; MAT_SLEEP: stops after printing, as when it waits for the passphrase; MAT_DIR: prints that path instead).
# `secrets named-by` prints NAMES (comma-separated) and logs to $XLOG.named; ABSENT: optional (?NAME) secrets the
# store does not have. `session` runs its command, with XLESS_SESSION set (unless NO_HOLD: where nothing can be held).
cat > "$t/bin/xless" <<'X'
#!/usr/bin/env bash
if [[ "$1 $2" == "secrets named-by" ]]; then echo "$*" >> "$XLOG.named"; [[ -z "${NAMES:-}" ]] || tr , '\n' <<<"$NAMES"; exit "${NAMED_EXIT:-0}"; fi
echo "$* | NOSTORE=${XLESS_NO_SECRET_STORE-unset}${XLESS_SESSION+ HELD}${MY_REVIEW_PW_FILE+ PWF=$MY_REVIEW_PW_FILE}${MY_REVIEW_PW+ PW=set}" >> "$XLOG"
if [[ "$1" == session ]]; then
  [[ -z "${SESSION_EXIT:-}" ]] || exit "$SESSION_EXIT"
  while [[ "$1" != -- ]]; do shift; done; shift
  [[ -n "${NO_HOLD:-}" ]] || export XLESS_SESSION=/held.sock
  "$@"; exit
fi
[[ "$1 $2" == "secrets materialize" ]] || { case "$*" in *next-build*) echo 1.0.0.2026112301 ;; esac; exit "${XLESS_EXIT:-0}"; }
[[ -z "${MAT_EXIT:-}" ]] || { echo "error: [config] the secret store has no XLESS_DIST_KEY" >&2; exit "$MAT_EXIT"; }
if [[ "$3" == --check ]]; then   # prints the optional (?NAME) secrets the store has
  for a in "$@"; do case "$a" in *=*) IFS=, read -r -a names <<<"${a#*=}"
    for n in "${names[@]}"; do [[ "$n" != \?* || ",${ABSENT:-}," == *",${n#\?},"* ]] || echo "${n#\?}"; done ;; esac; done
  exit "${CHECK_EXIT:-0}"
fi
d="${MAT_DIR:-$XDG_RUNTIME_DIR/xless/0123456789abcdef0123456789abcdef}"
mkdir -p "$d"; echo "$d"
[[ -z "${MAT_SLEEP:-}" ]] || { echo $$ > "$MPID"; exec sleep 30; }
for a in "$@"; do
  case "$a" in *=*) mkdir -p "$d/${a%%=*}"
    IFS=, read -r -a names <<<"${a#*=}"
    for n in "${names[@]}"; do
      if [[ "$n" == \?* ]]; then n="${n#\?}"; [[ ",${ABSENT:-}," != *",$n,"* ]] || continue; fi
      printf 'v' > "$d/${a%%=*}/$n"
    done ;; esac
done
X
# The fake docker: each `run` logs its command and, for each /secrets/store mount, which files it can see, and what the
# run directory holds at that moment. DSLEEP: a run whose command has that word sleeps (to be stopped).
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
case "$1" in context|image|ps|rm) exit 0 ;; esac
[[ "$1" == run ]] || exit 0
{ echo "run $*"
  for a in "$@"; do
    case "$a" in *dst=/secrets/store*) s="${a#type=bind,src=}"; s="${s%%,dst=*}"; echo "  sees $(cd "$s" 2>/dev/null && ls | tr '\n' ' ')" ;; esac
  done
  echo "  sets: $(ls "$RUN" 2>/dev/null | tr '\n' ' ')"; } >> "$DLOG"
case "$*" in *next-build*) echo 1.0.0.2026112301 ;; esac
if [[ -n "${DSLEEP:-}" && "$*" == *"$DSLEEP"* ]]; then echo $$ > "$DPID"; exec sleep 30; fi
exit 0
D
chmod +x "$t/bin/xless" "$t/bin/docker"
docker=(env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=1
        XDG_RUNTIME_DIR="$t/run" RUN="$RUN" XLOG="$t/xlog" DLOG="$t/dlog" DPID="$t/dpid" MPID="$t/mpid")
reset() { : > "$t/xlog"; : > "$t/xlog.named"; : > "$t/dlog"; rm -rf "$t/run/xless" "$t/dpid" "$t/mpid"; }

# A project directory with nothing set: one materialisation (with the project's team), one container gets the set
reset
"${docker[@]}" "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "project dir from the store: $(cat "$t/err")"
[[ "$(head -1 "$t/xlog")" == "secrets materialize --team ABCDE12345 sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY | "* ]] || fail "materialise call: $(cat "$t/xlog")"
grep -q -- "--mount type=bind,src=$RUN/sign,dst=/secrets/store,readonly" "$t/dlog" || fail "the set is not mounted read-only: $(cat "$t/dlog")"
for n in ASC_KEY_P8 ASC_KEY_ID ASC_ISSUER_ID XLESS_DIST_KEY; do grep -q -- "-e ${n}_FILE=/secrets/store/$n " "$t/dlog" || fail "$n not passed as a file: $(cat "$t/dlog")"; done
grep -q "  sees ASC_ISSUER_ID ASC_KEY_ID ASC_KEY_P8 XLESS_DIST_KEY $" "$t/dlog" || fail "the container does not see the set: $(cat "$t/dlog")"
grep -q -- "-e ASC_KEY_ID \|dst=/secrets/asc.p8" "$t/dlog" && fail "variables passed besides the store: $(cat "$t/dlog")"
[[ ! -e "$RUN" ]] || fail "the run directory outlived the run: $(ls -R "$RUN")"
# --allow-disk-secrets is passed on; it is the script's option, not ship's
reset
"${docker[@]}" "$S" "$t/proj" --allow-disk-secrets >/dev/null 2>"$t/err" || fail "--allow-disk-secrets run: $(cat "$t/err")"
grep -q "^secrets materialize --team ABCDE12345 --allow-disk sign=" "$t/xlog" || fail "--allow-disk-secrets not passed on: $(cat "$t/xlog")"
grep -q "allow-disk" "$t/dlog" && fail "--allow-disk-secrets reached xless ship: $(cat "$t/dlog")"
# the env file (or the environment) wins: a set *_FILE is mounted as before, and only the rest comes from the store
printf 'x' > "$t/keys/key.p8"; printf 'ISSUER' > "$t/keys/issuer"
printf 'ASC_KEY_ID=KEYID\nASC_ISSUER_ID_FILE=%s\nASC_KEY_P8_FILE=%s\n' "$t/keys/issuer" "$t/keys/key.p8" > "$t/tf.env"
reset
"${docker[@]}" XLESS_TESTFLIGHT_ENV="$t/tf.env" "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "env file + store: $(cat "$t/err")"
grep -q "^secrets materialize --team ABCDE12345 sign=XLESS_DIST_KEY | " "$t/xlog" || fail "only the dist key should come from the store: $(cat "$t/xlog")"
grep -q -- "dst=/secrets/asc.p8,readonly" "$t/dlog" && grep -q "  sees XLESS_DIST_KEY $" "$t/dlog" || fail "env file and store mounts: $(cat "$t/dlog")"
printf 'x' > "$t/keys/dist.pem"
reset
"${docker[@]}" XLESS_TESTFLIGHT_ENV="$t/tf.env" XLESS_DIST_KEY_FILE="$t/keys/dist.pem" "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "all from the env file"
grep -q "materialize" "$t/xlog" && fail "the store is read though every *_FILE is set: $(cat "$t/xlog")"

# --config, three steps: one materialisation for the run; step 1 sees its set, step 2 none, step 3 its own (step 1's gone)
reset
"${docker[@]}" "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "overlay from the store: $(cat "$t/err")"
[[ $(grep -c "materialize" "$t/xlog") -eq 1 ]] || fail "want one materialisation: $(cat "$t/xlog")"
grep -q "^secrets materialize --team ABCDE12345 next=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY | " "$t/xlog" \
  || fail "overlay sets: $(cat "$t/xlog")"
s1=$(grep -A3 "^run .*next-build" "$t/dlog"); s2=$(grep -A1 "^run .*--to finalize" "$t/dlog"); s3=$(grep -A3 "^run .*--from sign" "$t/dlog")
[[ "$s1" == *"src=$RUN/next,dst=/secrets/store,readonly"* && "$s1" == *"sees ASC_ISSUER_ID ASC_KEY_ID ASC_KEY_P8 "* && "$s1" != *"XLESS_DIST_KEY"* ]] || fail "step 1: $s1"
[[ "$s2" != *"/secrets"* && "$s2" != *"_FILE"* && "$s2" == *"sets: sign "* ]] || fail "step 2 (no secret; step 1's set already gone): $s2"
[[ "$s3" == *"src=$RUN/sign,dst=/secrets/store,readonly"* && "$s3" == *"sees ASC_ISSUER_ID ASC_KEY_ID ASC_KEY_P8 XLESS_DIST_KEY "* ]] || fail "step 3: $s3"
[[ ! -e "$RUN" ]] || fail "the run directory outlived the overlay run"
# a failing step removes them too
reset; code=0
"${docker[@]}" DSLEEP=nothing "$S" --config "$t/ov/app.yml" --to finalize >/dev/null 2>&1 || code=$?
[[ ! -e "$RUN" ]] || fail "run directory left after --to finalize"

# refusals: the store cannot give a secret (xless's exit code, nothing runs, nothing left)
reset; code=0
"${docker[@]}" MAT_EXIT=10 "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 10 ]] && grep -q "has no XLESS_DIST_KEY" "$t/err" || fail "a store without the key: exit $code $(cat "$t/err")"
[[ ! -s "$t/dlog" ]] || fail "containers ran without their secrets: $(cat "$t/dlog")"
# ... prints something that is not a run directory
reset; code=0
"${docker[@]}" MAT_DIR="$t/elsewhere" "$S" "$t/proj" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "not a run directory" "$t/err" || fail "odd run directory: exit $code $(cat "$t/err")"
[[ -d "$t/elsewhere" && ! -s "$t/dlog" ]] || fail "an unexpected path was removed, or a container ran"
# ... would put them inside a folder mounted into the build container
mkdir -p "$t/ov/app/rt"; chmod 700 "$t/ov/app/rt"; reset; code=0
"${docker[@]}" XDG_RUNTIME_DIR="$t/ov/app/rt" MAT_DIR="$t/ov/app/rt/xless/0123456789abcdef0123456789abcdef" "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "mounted into the build container" "$t/err" || fail "secrets inside the source: exit $code $(cat "$t/err")"
[[ ! -e "$t/ov/app/rt/xless/0123456789abcdef0123456789abcdef" && ! -s "$t/dlog" ]] || fail "secrets inside the source were left, or a container ran"
# ... the API key's IDs without the key file (one source for the three)
reset; code=0
"${docker[@]}" ASC_KEY_ID=KEYID "$S" "$t/proj" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "ASC_KEY_P8_FILE" "$t/err" || fail "IDs without the key: exit $code $(cat "$t/err")"
# ... no xless on this host to read the store
reset; code=0
env -i HOME="$t/home" PATH="/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=1 "$S" "$t/proj" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "is not on PATH" "$t/err" || fail "no host xless: exit $code $(cat "$t/err")"

# stopped (INT, TERM, HUP): while a container runs, and while xless writes them (or waits for the passphrase), the run
# directory goes at once. INT: the script is started with INT at its default (a background job of this test starts with
# INT ignored, which bash cannot trap).
dfl() { exec python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
for sig in INT TERM HUP; do
  case $sig in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
  for where in container materialise; do
    reset
    if [[ $where == container ]]; then extra=(DSLEEP="--from sign"); pidf="$t/dpid"; else extra=(MAT_SLEEP=1); pidf="$t/mpid"; fi
    dfl "${docker[@]}" "${extra[@]}" "$S" --config "$t/ov/app.yml" >/dev/null 2>&1 & pid=$!; bg+=("$pid")
    for _ in $(seq 100); do [[ -s "$pidf" ]] && break; sleep 0.1; done
    [[ -s "$pidf" && -d "$RUN" ]] || fail "$sig/$where: never reached the point to stop: $(cat "$t/dlog" "$t/xlog")"
    start=$SECONDS; kill -"$sig" "$pid"; code=0; wait "$pid" || code=$?
    [[ $code -eq $want && $((SECONDS - start)) -lt 10 ]] || fail "$sig/$where: exit $code after $((SECONDS - start)) s, want $want at once"
    [[ ! -e "$RUN" ]] || fail "$sig/$where: the run directory outlived the stopped run: $(ls -R "$RUN")"
    kill "$(cat "$pidf")" 2>/dev/null || true
  done
done

# a SIGKILL leaves no chance to clean up: the next run on the work copy, which takes its lock over, removes them
reset; K="$t/run/xless/ffffffffffffffffffffffffffffffff"
"${docker[@]}" DSLEEP="--from sign" MAT_DIR="$K" "$S" --config "$t/ov/app.yml" >/dev/null 2>&1 & pid=$!; bg+=("$pid")
for _ in $(seq 100); do [[ -s "$t/dpid" ]] && break; sleep 0.1; done
[[ -s "$t/dpid" && -d "$K/sign" ]] || fail "SIGKILL: step 3 never started: $(cat "$t/dlog")"
kill -KILL "$pid"; wait "$pid" 2>/dev/null || true
[[ -d "$K" ]] || fail "SIGKILL: nothing left to test"
"${docker[@]}" "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "the run after a SIGKILL: $(cat "$t/err")"
grep -q "removing the secrets it left in $K" "$t/err" && [[ ! -e "$K" ]] || fail "a killed run's secrets were left: $(cat "$t/err")"
kill "$(cat "$t/dpid")" 2>/dev/null || true
# the run directory's place must not be inside a cache folder the build container mounts read-write either
mkdir -p "$t/home/.cache/xless/work/rt"; chmod 700 "$t/home/.cache/xless/work/rt"; reset; code=0
"${docker[@]}" XDG_RUNTIME_DIR="$t/home/.cache/xless/work/rt" "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "mounted into the build container" "$t/err" || fail "secrets inside the work cache: exit $code $(cat "$t/err")"
grep -q materialize "$t/xlog" && fail "materialised before the refusal: $(cat "$t/xlog")"
# in docker a value (not a file) is not passed into a container: the run says it uses the store's
reset
"${docker[@]}" XLESS_DIST_KEY=pem "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "a dist key value in docker: $(cat "$t/err")"
grep -q "XLESS_DIST_KEY is set, but docker builds take only XLESS_DIST_KEY_FILE" "$t/err" || fail "no note for a value in docker: $(cat "$t/err")"
grep -q -- "-e XLESS_DIST_KEY " "$t/dlog" && fail "a secret value reached a container: $(cat "$t/dlog")"

# natively nothing is written: xless reads the store itself; the script checks it holds them first (no passphrase),
# and the build step (2) cannot open it
# a program the run itself starts (ps): it logs whether it is told of the session
mkdir -p "$t/own"
printf '#!/bin/sh\necho "ps${XLESS_SESSION+ HELD}" >> "%s/own.log"\nexec %s "$@"\n' "$t" "$(command -v ps)" > "$t/own/ps"; chmod +x "$t/own/ps"
native=(env -i HOME="$t/home" PATH="$t/bin:$t/own:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=0 XDG_RUNTIME_DIR="$t/run" XLOG="$t/xlog")
reset
"${native[@]}" "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "native overlay from the store: $(cat "$t/err")"
check="secrets materialize --check --team ABCDE12345 next=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY | NOSTORE=unset"
[[ "$(sed -n 1p "$t/xlog")" == "$check" ]] || fail "native check: $(cat "$t/xlog")"
grep -q -- "--to finalize | NOSTORE=1$" "$t/xlog" || fail "native step 2 can open the store: $(cat "$t/xlog")"
grep -q -- "--from sign --to upload | NOSTORE=unset HELD$" "$t/xlog" || fail "native step 3 cannot open the store: $(cat "$t/xlog")"
[[ ! -e "$t/run/xless" ]] || fail "a native run wrote secrets"
# and it asks for the passphrase once, before the first step, for all of them (`xless session`): the steps run inside it,
# the build without it
[[ "$(sed -n 2p "$t/xlog")" == "session --if-possible --purpose xless run --reason reading ASC_KEY_P8, ASC_KEY_ID, ASC_ISSUER_ID, XLESS_DIST_KEY -- $XLESS_RUN run --config $t/ov/app.yml | NOSTORE=unset" ]] \
  || fail "native session: $(cat "$t/xlog")"
[[ $(grep -c "^session" "$t/xlog") -eq 1 ]] || fail "one session: $(cat "$t/xlog")"
grep -q "^ps$" "$t/own.log" && ! grep -q HELD "$t/own.log" || fail "the programs of the run's own are told of the session: $(cat "$t/own.log")"
grep -q "next-build.* HELD$" "$t/xlog" || fail "step 1 is not in the session: $(cat "$t/xlog")"
reset
"${native[@]}" "$S" "$t/proj" --verbose >/dev/null 2>"$t/err" || fail "native project from the store: $(cat "$t/err")"
[[ "$(sed -n 2p "$t/xlog")" == "session "*" -- $XLESS_RUN run $t/proj --verbose | "* && "$(grep -c "^session" "$t/xlog")" -eq 1 ]] && grep -q "^ship .* HELD$" "$t/xlog" \
  || fail "a project directory's run asks up front too: $(cat "$t/xlog")"
reset
"${native[@]}" NO_HOLD=1 "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "native, with nothing held: $(cat "$t/err")"
[[ $(grep -c "^session" "$t/xlog") -eq 1 ]] && grep -q -- "--from sign --to upload | NOSTORE=unset$" "$t/xlog" || fail "where nothing can be held the run goes on without: $(cat "$t/xlog")"
reset
"${native[@]}" XLESS_SESSION=/mine.sock "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "native, in a session: $(cat "$t/err")"
grep -q "^session" "$t/xlog" && fail "a run in a session of the user's own starts another: $(cat "$t/xlog")"
grep -q -- "--to finalize | NOSTORE=1$" "$t/xlog" || fail "the build is told of the user's session: $(cat "$t/xlog")"
reset; code=0
"${native[@]}" SESSION_EXIT=23 "$S" --config "$t/ov/app.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 23 && $(wc -l < "$t/xlog") -eq 2 ]] || fail "a store that is not unlocked must stop the run before it builds: exit $code $(cat "$t/xlog")"
reset; code=0
"${native[@]}" CHECK_EXIT=10 "$S" "$t/proj" >/dev/null 2>&1 || code=$?
[[ $code -eq 10 && $(wc -l < "$t/xlog") -eq 1 ]] || fail "a failed native check must stop the run before it builds: exit $code $(cat "$t/xlog")"
reset
"${native[@]}" XLESS_TESTFLIGHT_DRY_RUN=1 "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "native dry run: $(cat "$t/err")"
[[ ! -s "$t/xlog" ]] || fail "a dry run unlocks: $(cat "$t/xlog")"
# natively a NAME set in the environment serves as well (xless reads it), so the store is not checked for it
reset
"${native[@]}" XLESS_DIST_KEY=pem ASC_KEY_P8=p8 ASC_KEY_ID=K ASC_ISSUER_ID=I "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "native values: $(cat "$t/err")"
grep -q "materialize" "$t/xlog" && fail "native values still checked in the store: $(cat "$t/xlog")"

mkdir -p "$t/pw"; printf 'pw' > "$t/pw/review"
# The TestFlight demo account's password (fmsouza/xless#140): the host's xless names its secret (`secrets named-by`);
# only the container that uploads gets it, as an optional secret of its set (or from its _FILE), never step 1 or 2.
reset
"${docker[@]}" NAMES=XLESS_DEMO_PASSWORD "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "project dir with a demo password: $(cat "$t/err")"
[[ "$(cat "$t/xlog.named")" == "secrets named-by --project $t/proj" ]] || fail "named-by call: $(cat "$t/xlog.named")"
grep -q "^secrets materialize --team ABCDE12345 sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY,?XLESS_DEMO_PASSWORD | " "$t/xlog" \
  || fail "the demo password is not an optional secret of the set: $(cat "$t/xlog")"
grep -q -- "-e XLESS_DEMO_PASSWORD_FILE=/secrets/store/XLESS_DEMO_PASSWORD " "$t/dlog" && grep -q "  sees ASC_ISSUER_ID ASC_KEY_ID ASC_KEY_P8 XLESS_DEMO_PASSWORD XLESS_DIST_KEY $" "$t/dlog" \
  || fail "the container does not get the demo password: $(cat "$t/dlog")"
[[ ! -e "$RUN" ]] || fail "the demo password outlived the run"
# an overlay, under a name of the user's own: step 3 only, removed when it ends
reset
"${docker[@]}" NAMES=MY_REVIEW_PW "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "overlay with a demo password: $(cat "$t/err")"
[[ "$(cat "$t/xlog.named")" == "secrets named-by --config $t/ov/app.yml --platform ios" ]] || fail "overlay named-by call: $(cat "$t/xlog.named")"
grep -q "^secrets materialize --team ABCDE12345 next=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY,?MY_REVIEW_PW | " "$t/xlog" \
  || fail "overlay sets with the demo password: $(cat "$t/xlog")"
s1=$(grep -A3 "^run .*next-build" "$t/dlog"); s2=$(grep -A1 "^run .*--to finalize" "$t/dlog"); s3=$(grep -A3 "^run .*--from sign" "$t/dlog")
[[ "$s1" != *MY_REVIEW_PW* && "$s2" != *MY_REVIEW_PW* && "$s2" != *"/secrets"* ]] || fail "the demo password reached step 1 or 2: $s1 / $s2"
[[ "$s3" == *"-e MY_REVIEW_PW_FILE=/secrets/store/MY_REVIEW_PW "* && "$s3" == *"sees ASC_ISSUER_ID ASC_KEY_ID ASC_KEY_P8 MY_REVIEW_PW XLESS_DIST_KEY "* ]] || fail "step 3 lacks the demo password: $s3"
[[ ! -e "$RUN" ]] || fail "the demo password outlived the overlay run"
# ... a team's entry (NAME@TEAMID) keeps its name, which xless asks for
reset
"${docker[@]}" NAMES=MY_REVIEW_PW@ABCDE12345 "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "a team's demo password: $(cat "$t/err")"
grep -q -- "-e MY_REVIEW_PW@ABCDE12345_FILE=/secrets/store/MY_REVIEW_PW@ABCDE12345 " "$t/dlog" || fail "a team's demo password: $(cat "$t/dlog")"
# the store does not have it: nothing stops (it is sent only when the demo account changes), the run says so
reset
"${docker[@]}" NAMES=MY_REVIEW_PW ABSENT=MY_REVIEW_PW "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "a store without the demo password: $(cat "$t/err")"
grep -q "the secret store has no MY_REVIEW_PW" "$t/err" || fail "no note for a missing demo password: $(cat "$t/err")"
grep -q "MY_REVIEW_PW_FILE" "$t/dlog" && fail "a missing demo password passed as a file: $(cat "$t/dlog")"
grep -q "^secrets materialize --check --team ABCDE12345 next=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY,?MY_REVIEW_PW | " "$t/xlog" \
  && grep -q "^secrets materialize --team ABCDE12345 next=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY | " "$t/xlog" \
  || fail "the store is asked first, and the missing demo password left out: $(cat "$t/xlog")"
# every other secret a file: a store without the password is never opened (nor a tmpfs needed); one with it is
printf 'x' > "$t/keys/key.p8"; printf 'x' > "$t/keys/dist.pem"
allfiles=(XLESS_TESTFLIGHT_ENV="$t/tf.env" XLESS_DIST_KEY_FILE="$t/keys/dist.pem" NAMES=XLESS_DEMO_PASSWORD)
reset
"${docker[@]}" "${allfiles[@]}" ABSENT=XLESS_DEMO_PASSWORD XDG_RUNTIME_DIR= "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "all files, no password in the store: $(cat "$t/err")"
grep -q "^secrets materialize --check --team ABCDE12345 sign=?XLESS_DEMO_PASSWORD | " "$t/xlog" && ! grep -q "^secrets materialize --team" "$t/xlog" \
  || fail "the store was opened for a password it does not have: $(cat "$t/xlog")"
grep -q "dst=/secrets/store" "$t/dlog" && fail "an empty set was mounted: $(cat "$t/dlog")"
reset
"${docker[@]}" "${allfiles[@]}" "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "all files, the password in the store: $(cat "$t/err")"
grep -q "^secrets materialize --team ABCDE12345 sign=?XLESS_DEMO_PASSWORD | " "$t/xlog" && grep -q "  sees XLESS_DEMO_PASSWORD $" "$t/dlog" \
  && grep -q -- "-e XLESS_DEMO_PASSWORD_FILE=/secrets/store/XLESS_DEMO_PASSWORD " "$t/dlog" || fail "all files, the password from the store: $(cat "$t/xlog" "$t/dlog")"
# ... and a store that cannot be read at all gives no optional secret, and stops nothing
reset
"${docker[@]}" "${allfiles[@]}" CHECK_EXIT=10 "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "all files, an unreadable store: $(cat "$t/err")"
grep -q "the secret store has no XLESS_DEMO_PASSWORD" "$t/err" && ! grep -q "^secrets materialize --team" "$t/xlog" || fail "an unreadable store: $(cat "$t/err" "$t/xlog")"
# ... while a needed secret it cannot check stops the run, as before
reset; code=0
"${docker[@]}" NAMES=XLESS_DEMO_PASSWORD CHECK_EXIT=10 "$S" "$t/proj" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 10 && ! -s "$t/dlog" ]] || fail "a failed check of needed secrets: exit $code $(cat "$t/err")"
# a project directory's one container takes the password's file (the env file's NAME_FILE too)
reset
"${docker[@]}" NAMES=MY_REVIEW_PW MY_REVIEW_PW_FILE="$t/pw/review" "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "project dir, a password file: $(cat "$t/err")"
grep -q -- "--mount type=bind,src=$t/pw/review,dst=/secrets/passwords/MY_REVIEW_PW,readonly -e MY_REVIEW_PW_FILE=/secrets/passwords/MY_REVIEW_PW " "$t/dlog" || fail "project dir password file: $(cat "$t/dlog")"
# a name that is one of the script's own variables (ENV: ENV_FILE is the env file) never reads it
reset
"${docker[@]}" NAMES=ENV "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "a password named ENV: $(cat "$t/err")"
grep -q "dst=/secrets/passwords" "$t/dlog" && fail "the env file was taken for a password: $(cat "$t/dlog")"
# its _FILE wins: mounted into step 3 only, and not asked of the store
reset
"${docker[@]}" NAMES=MY_REVIEW_PW MY_REVIEW_PW_FILE="$t/pw/review" "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "a demo password file: $(cat "$t/err")"
grep -q "MY_REVIEW_PW" "$t/xlog" && fail "the store was asked for a demo password given as a file: $(cat "$t/xlog")"
s1=$(grep "^run .*next-build" "$t/dlog"); s2=$(grep "^run .*--to finalize" "$t/dlog"); s3=$(grep "^run .*--from sign" "$t/dlog")
[[ "$s3" == *"--mount type=bind,src=$t/pw/review,dst=/secrets/passwords/MY_REVIEW_PW,readonly -e MY_REVIEW_PW_FILE=/secrets/passwords/MY_REVIEW_PW "* ]] || fail "step 3 lacks the demo password file: $s3"
[[ "$s1" != *MY_REVIEW_PW* && "$s2" != *MY_REVIEW_PW* ]] || fail "the demo password file reached step 1 or 2: $s1 / $s2"
# ... but not from inside the folder mounted into the build
printf 'pw' > "$t/ov/review-pw"; reset; code=0
"${docker[@]}" NAMES=MY_REVIEW_PW MY_REVIEW_PW_FILE="$t/ov/review-pw" "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "MY_REVIEW_PW_FILE .* is inside the overlay's directory" "$t/err" || fail "a demo password in the overlay's folder: exit $code $(cat "$t/err")"
rm -f "$t/ov/review-pw"
# a value (not a file) is not passed in: the store's is used
reset
"${docker[@]}" NAMES=MY_REVIEW_PW MY_REVIEW_PW=pw "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "a demo password value in docker: $(cat "$t/err")"
grep -q "MY_REVIEW_PW is set, but docker builds take only MY_REVIEW_PW_FILE" "$t/err" && ! grep -q -- "-e MY_REVIEW_PW " "$t/dlog" || fail "a demo password value: $(cat "$t/err") $(cat "$t/dlog")"
# a run that does not upload does not ask, and gives it to nobody
reset
"${docker[@]}" NAMES=MY_REVIEW_PW "$S" --config "$t/ov/app.yml" --to package >/dev/null 2>"$t/err" || fail "a run to package: $(cat "$t/err")"
[[ ! -s "$t/xlog.named" ]] && ! grep -q MY_REVIEW_PW "$t/xlog" "$t/dlog" || fail "a run that never uploads got the demo password: $(cat "$t/xlog.named" "$t/xlog")"
# the configuration cannot be read: a note, and the run goes on (xless reports what is wrong with it)
reset
"${docker[@]}" NAMED_EXIT=10 "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "named-by failing: $(cat "$t/err")"
grep -q "secrets named-by could not tell which secret" "$t/err" || fail "no note when named-by fails: $(cat "$t/err")"
# ... or answers something that is not names: none is used
reset
"${docker[@]}" NAMES='MY_REVIEW_PW,A=B' "$S" "$t/proj" >/dev/null 2>"$t/err" || fail "an odd answer from named-by: $(cat "$t/err")"
grep -q "secrets named-by could not tell which secret" "$t/err" && ! grep -q "MY_REVIEW_PW" "$t/xlog" "$t/dlog" || fail "an odd answer from named-by: $(cat "$t/err" "$t/xlog")"
# the mac App-Store lane: the pkg ship uploads, so it gets it; the DMG ship does not
reset
"${docker[@]}" NAMES=MY_REVIEW_PW "$S" --config "$t/ov/app.yml" --platform macos --to upload >/dev/null 2>"$t/err" || fail "mac lane with a demo password: $(cat "$t/err")"
[[ "$(cat "$t/xlog.named")" == "secrets named-by --config $t/ov/app.yml --platform macos" ]] || fail "mac named-by call: $(cat "$t/xlog.named")"
grep -q "^secrets materialize --team ABCDE12345 sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DEVID_KEY appstore=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY,XLESS_INSTALLER_KEY,?MY_REVIEW_PW | " "$t/xlog" \
  || fail "mac lane sets: $(cat "$t/xlog")"
dmg=$(grep "^run .*--to package" "$t/dlog"); pkg=$(grep "^run .*--distribution app-store" "$t/dlog")
[[ "$dmg" != *MY_REVIEW_PW* && "$pkg" == *"-e MY_REVIEW_PW_FILE=/secrets/store/MY_REVIEW_PW "* ]] || fail "mac lane: the demo password goes to the pkg ship only: $dmg / $pkg"
# natively the build step runs without it (a name of the user's own), and step 3 keeps it; nothing is written
reset
"${native[@]}" NAMES=MY_REVIEW_PW MY_REVIEW_PW_FILE="$t/pw/review" MY_REVIEW_PW=pw "$S" --config "$t/ov/app.yml" >/dev/null 2>"$t/err" || fail "native with a demo password: $(cat "$t/err")"
grep -q -- "--to finalize | NOSTORE=1$" "$t/xlog" || fail "native step 2 sees the demo password: $(cat "$t/xlog")"
grep -q -- "--from sign --to upload | NOSTORE=unset HELD PWF=$t/pw/review PW=set$" "$t/xlog" || fail "native step 3 lacks the demo password: $(cat "$t/xlog")"
grep -q "MY_REVIEW_PW" <(grep materialize "$t/xlog") && fail "natively the store is checked for an optional secret: $(cat "$t/xlog")"
[[ ! -e "$t/run/xless" ]] || fail "a native run wrote secrets"
echo PASS
