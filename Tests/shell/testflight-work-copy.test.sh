#!/usr/bin/env bash
# One run per work copy (fmsouza/xless#57): scripts/testflight.sh holds a lock on the work copy while it runs. A run
# refuses to start while a live run holds it, and stops what a run killed with SIGKILL left behind (its containers,
# natively its xless) before it starts. A fake docker logs what it is asked; no daemon, no network, no secrets.
set -euo pipefail
S="$(cd "$(dirname "$0")/../.." && pwd)/scripts/testflight.sh"
t=$(mktemp -d)
bg=()   # background processes to stop on the way out
finally() { local p; for p in ${bg[@]+"${bg[@]}"}; do kill "$p" 2>/dev/null || true; done; rm -rf "$t"; }
trap finally EXIT
fail() { echo "FAIL: $*"; exit 1; }
# a zombie counts as stopped (the test's own children stay zombies until it waits for them)
alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
started() { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" | sed 's/^ *//; s/ *$//'; }   # as the script records it
waitfor() { local _; for _ in $(seq 300); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }   # RE FILE
mkdir -p "$t/proj" "$t/proj2" "$t/bin" "$t/nbin" "$t/home"
touch "$t/proj/xless.yml" "$t/proj2/xless.yml"
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
echo "$*" >> "$KLOG"
case "$1" in
  run) [[ -z "${RUN_SLEEP:-}" ]] || sleep "$RUN_SLEEP" ;;
  rm) [[ -z "${RM_FAIL:-}" ]] || exit 1 ;;
  ps) [[ "$*" != *"label=xless.work="* || -z "${WORK_IDS:-}" ]] || echo "$WORK_IDS" ;;
esac
exit 0
D
chmod +x "$t/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$t/nbin/xless"; chmod +x "$t/nbin/xless"
docker=(env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" KLOG="$t/klog" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=1)
native=(env -i HOME="$t/home" PATH="$t/nbin:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=0)
args=(--build-number 1 --to finalize)

# a run labels its containers with its work copy, and releases the work copy when it ends
: > "$t/klog"
"${docker[@]}" "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || fail "plain run: $(cat "$t/err")"
h=$(sed -n 's/^run .*--label xless\.work=\([0-9a-f]*\) .*/\1/p' "$t/klog" | head -1)
[[ -n "$h" ]] || fail "docker run without the work copy's label: $(cat "$t/klog")"
lock="$t/home/.cache/xless/locks/$h.lock"
[[ ! -e "$lock" ]] || fail "the lock outlived the run: $(cat "$lock")"

# a lock left by a run that is gone (its PID now another process, started at another time): the new run removes the
# containers labelled with this work copy before it builds, and says so
printf 'pid=%s\nstarted=%s\nhost=%s\nwork=%s\n' "$$" "Thu Jan  1 00:00:00 1970" "$(uname -n)" "$t/proj" > "$lock"
: > "$t/klog"
"${docker[@]}" WORK_IDS=dead0 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || fail "run after a killed one: $(cat "$t/err")"
ps_at=$(grep -nxF "ps -aq --filter label=xless.work=$h" "$t/klog" | head -1 | cut -d: -f1)
rm_at=$(grep -nx 'rm -f dead0' "$t/klog" | head -1 | cut -d: -f1)
run_at=$(grep -n '^run ' "$t/klog" | head -1 | cut -d: -f1)
[[ -n "$ps_at" && -n "$rm_at" && -n "$run_at" && $ps_at -lt $rm_at && $rm_at -lt $run_at ]] \
  || fail "the killed run's container was not removed before the build: $(cat "$t/klog")"
grep -qF "pid $$" "$t/err" || fail "the takeover does not name the gone run: $(cat "$t/err")"
[[ ! -e "$lock" ]] || fail "the lock outlived the run that took it over"

# a run that stops while it takes the work copy (here: the containers a gone run left cannot be removed) exits 2,
# naming the command to run, and leaves no lock behind
: > "$t/klog"
code=0; "${docker[@]}" WORK_IDS=dead1 RM_FAIL=1 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -qF "rm -f dead1" "$t/err" || fail "a failed removal: exit $code, want 2: $(cat "$t/err")"
grep -q '^run ' "$t/klog" && fail "it built next to the containers it could not remove: $(cat "$t/klog")"
[[ -z "$(ls -A "$t/home/.cache/xless/locks")" ]] || fail "it left files in the locks folder: $(ls -A "$t/home/.cache/xless/locks")"

# a live run holds the work copy: a second run on it is refused (exit 2) and touches none of its containers, nor its
# step, even from a shell in another time zone and with the step's start time unknown; a run on another work copy, and
# a dry run, go ahead
: > "$t/klog"
"${docker[@]}" TZ=UTC0 RUN_SLEEP=120 WORK_IDS=live0 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/errA" & a=$!; bg+=("$a")
waitfor '^run ' "$t/klog" || fail "the first run never started: $(cat "$t/errA")"
waitfor '^job=' "$lock" || fail "the lock does not record the live run's step: $(cat "$lock" 2>&1)"
grep -qx "pid=$a" "$lock" || fail "the lock does not name the live run $a: $(cat "$lock" 2>&1)"
aj=$(sed -n 's/^job=\([0-9]*\).*/\1/p' "$lock"); sed -i.bak "s/^job=.*/job=$aj /" "$lock"; rm -f "$lock.bak"
code=0; "${docker[@]}" TZ=EST5 KLOG="$t/klogB" WORK_IDS=live0 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/errB" || code=$?
[[ $code -eq 2 ]] || fail "a second run on a busy work copy: exit $code, want 2: $(cat "$t/errB")"
grep -qF "pid $a" "$t/errB" && grep -qF "in use" "$t/errB" || fail "the refusal does not name the live run: $(cat "$t/errB")"
grep -q '^run \|^rm ' "$t/klogB" 2>/dev/null && fail "the refused run ran or removed containers: $(cat "$t/klogB")"
grep -qx "pid=$a" "$lock" || fail "the refused run took the lock"
alive "$aj" || fail "the refused run stopped the live run's step"
"${docker[@]}" KLOG="$t/klogC" "$S" "$t/proj2" "${args[@]}" >/dev/null 2>"$t/errC" || fail "another work copy was refused: $(cat "$t/errC")"
"${docker[@]}" XLESS_TESTFLIGHT_DRY_RUN=1 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/errD" || fail "a dry run was refused: $(cat "$t/errD")"
kill -TERM "$a"; code=0; wait "$a" || code=$?
[[ $code -eq 143 ]] || fail "the first run: exit $code after TERM, want 143"
[[ ! -e "$lock" ]] || fail "the lock outlived a stopped run"

# overlays: the work copy is the overlay's name under the work root, so two overlay files of one name share it, in docker
# and natively; a React Native overlay's is its work volume
mkdir -p "$t/a/app" "$t/b/app"
printf 'type: tauri\nsource: app\n' | tee "$t/a/my.yml" > "$t/b/my.yml"
: > "$t/klog"
"${docker[@]}" RUN_SLEEP=120 "$S" --config "$t/a/my.yml" "${args[@]}" >/dev/null 2>"$t/errA" & a=$!; bg+=("$a")
waitfor '^run ' "$t/klog"; grep -q '^run .*--label xless\.work=' "$t/klog" || fail "overlay run without the work copy's label: $(cat "$t/klog" "$t/errA")"
code=0; "${native[@]}" "$S" --config "$t/b/my.yml" "${args[@]}" >/dev/null 2>"$t/errB" || code=$?
[[ $code -eq 2 ]] && grep -qF "$(cd -P "$t" && pwd -P)/home/.cache/xless/work/my is in use" "$t/errB" || fail "an overlay of the same name: exit $code: $(cat "$t/errB")"
printf 'type: react-native\nsource: app\n' > "$t/b/rn.yml"
"${docker[@]}" KLOG="$t/klogC" "$S" --config "$t/b/rn.yml" --destination simulator --to build >/dev/null 2>"$t/errC" || fail "a React Native overlay was refused: $(cat "$t/errC")"
grep -q '^run .*--label xless\.work=' "$t/klogC" || fail "React Native run without the work copy's label: $(cat "$t/klogC")"
kill -TERM "$a"; wait "$a" || true

# natively: the gone run's xless (the job recorded in the lock) is stopped, but only if it is still that process
sleep 300 & j1=$!; bg+=("$j1"); sleep 300 & j2=$!; bg+=("$j2")
own=(pid="$$" started="Thu Jan  1 00:00:00 1970" host="$(uname -n)" work="$t/proj")
printf '%s\n' "${own[@]}" "job=$j2 Thu Jan  1 00:00:00 1970" > "$lock"
"${native[@]}" "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || fail "native run after a killed one: $(cat "$t/err")"
alive "$j2" || fail "a process whose PID matches the recorded job, but not its start time, was stopped"
printf '%s\n' "${own[@]}" "job=$j1 $(started "$j1")" > "$lock"
"${native[@]}" "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || fail "native run after a killed one: $(cat "$t/err")"
for _ in $(seq 50); do alive "$j1" || break; sleep 0.1; done
alive "$j1" && fail "the killed run's xless is still running"
[[ ! -e "$lock" ]] || fail "the lock outlived the native run"
echo PASS
