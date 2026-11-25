#!/usr/bin/env bash
# One run per work copy (fmsouza/xless#57): xless run holds a lock on the work copy while it runs. A run
# refuses to start while a live run holds it, and stops what a run killed with SIGKILL left behind (its containers,
# natively its xless) before it starts. A fake docker logs what it is asked; no daemon, no network, no secrets.
set -euo pipefail
t=$(mktemp -d)
. "$(dirname "$0")/run-entry.sh"
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
case "$(uname -m)" in arm64|aarch64) A=arm64 ;; *) A=amd64 ;; esac
fake="$repo/Tests/shell/fake-images.sh"
{ "$fake" base "$A" 27.0 27A266a; for kit in tauri react-native; do "$fake" kit "$kit" "$repo" "$A" 27.0 27A266a; done; } > "$t/images"
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
echo "$*" >> "$KLOG"
case "$1" in
  image) exec "$FAKE" "$@" ;;
  run) [[ -z "${RUN_SLEEP:-}" ]] || sleep "$RUN_SLEEP" ;;
  rm) [[ -z "${RM_FAIL:-}" ]] || exit 1 ;;
  ps) [[ "$*" != *"label=xless.work="* || -z "${WORK_IDS:-}" ]] || echo "$WORK_IDS" ;;
esac
exit 0
D
chmod +x "$t/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$t/nbin/xless"; chmod +x "$t/nbin/xless"
docker=(env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" KLOG="$t/klog" FAKE="$fake" FAKE_IMAGES="$t/images" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=1)
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
# however it was started, and whatever the clock did since: no single value says that it is gone
kill -TERM "$a"; code=0; wait "$a" || code=$?
[[ $code -eq 143 ]] || fail "the first run: exit $code after TERM, want 143"
ln -s "$XLESS_RUN" "$t/ci-run"
for how in marks nomarks link; do
  first=("$XLESS_RUN"); [[ $how != link ]] || first=("$t/ci-run")
  : > "$t/klog"
  "${docker[@]}" RUN_SLEEP=120 XLESS_SHARE="$repo" XLESS_SELF=xless WORK_IDS=live0 "${first[@]}" --no-input run "$t/proj" "${args[@]}" >/dev/null 2>"$t/errA" & a=$!; bg+=("$a")
  waitfor '^run ' "$t/klog" && waitfor '^job=' "$lock" || fail "$how: the first run never started: $(cat "$t/errA")"
  aj=$(sed -n 's/^job=\([0-9]*\).*/\1/p' "$lock")
  sed -i.bak 's/^started=.*/started=Thu Jan  1 00:00:00 1970/' "$lock"
  [[ $how = marks ]] || sed -i.bak '/^mark=/d' "$lock"
  rm -f "$lock.bak"
  code=0; "${docker[@]}" KLOG="$t/klogE" WORK_IDS=live0 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/errB" || code=$?
  [[ $code -eq 2 ]] || fail "$how: a second run on a busy work copy: exit $code, want 2: $(cat "$t/errB")"
  if [[ $how = marks ]]; then grep -qF "wait for it to end, or stop it: kill $a" "$t/errB" || fail "$how: $(cat "$t/errB")"
  else grep -qF "when no run works there any more, stop its step, if it still runs (kill $aj), then remove $lock and run again" "$t/errB" || fail "$how: the refusal does not say how to go on: $(cat "$t/errB")"; fi
  grep -q '^run \|^rm ' "$t/klogE" 2>/dev/null && fail "$how: the refused run ran or removed containers: $(cat "$t/klogE")"
  alive "$a" && alive "$aj" || fail "$how: the refused run stopped the live run"
  kill -TERM "$a"; wait "$a" || true
done
[[ ! -e "$lock" ]] || fail "the lock outlived a stopped run"
# a run on a machine with another name (a home two machines share) cannot be seen from here: refused, with how to go on
printf 'pid=1\nstarted=x\nhost=%s-not\nwork=%s\n' "$(uname -n)" "$t/proj" > "$lock"
code=0; "${docker[@]}" "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -qF "remove $lock and run again" "$t/err" || fail "a lock of another machine: exit $code: $(cat "$t/err")"
rm "$lock"
"${docker[@]}" "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || fail "after removing it: $(cat "$t/err")"

# a run killed with SIGKILL, then the machine has another name (a Mac's follows the network): its secrets, its step and its
# containers go all the same. On another machine nothing can be told: refused, and the message says what to remove there.
# (The machine is known by a hash: its own ID is not in the lock.)
left="$(cd -P "$t" && pwd -P)/home/run/xless/0123456789abcdef0123456789abcdef"
for where in renamed other; do
  : > "$t/klog"; mkdir -p "$left/sign"; chmod 700 "$left"; echo v > "$left/sign/XLESS_DIST_KEY"; echo "$left" > "$t/out"
  "${docker[@]}" RUN_SLEEP=120 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/errA" & a=$!; bg+=("$a")
  waitfor '^run ' "$t/klog" && waitfor '^job=' "$lock" || fail "$where: the first run never started: $(cat "$t/errA")"
  aj=$(sed -n 's/^job=\([0-9]*\).*/\1/p' "$lock"); bg+=("$aj")
  kill -KILL "$a"; wait "$a" 2>/dev/null || true
  alive "$aj" || fail "$where: the step ended with its run, so nothing is shown"
  grep -Eq '^machine=[0-9a-f]{32}$' "$lock" || fail "the lock does not say the machine: $(cat "$lock")"
  for id in "$(cat /etc/machine-id 2>/dev/null || true)" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d - || true)" \
            "$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID" = "\(.*\)"/\1/p' | tr -d - | tr A-F a-f || true)"; do
    [[ -z "$id" ]] || ! sed -n 's/^machine=//p' "$lock" | grep -qiF "$id" || fail "the machine's own ID is in the lock"
  done
  sed -i.bak "s/^host=.*/host=elsewhere.example/" "$lock"; echo "secrets_out=$t/out" >> "$lock"
  [[ $where = renamed ]] || { sed -i.bak "s/^machine=.*/machine=00000000000000000000000000000000/" "$lock"; echo "secrets=$left" >> "$lock"; }
  rm -f "$lock.bak"; : > "$t/klog"
  code=0; "${docker[@]}" WORK_IDS=dead2 "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || code=$?
  if [[ $where = renamed ]]; then
    [[ $code -eq 0 ]] || fail "a killed run on this machine, by another name: exit $code: $(cat "$t/err")"
    [[ ! -e "$left" ]] || fail "the killed run's secrets are still there"
    alive "$aj" && fail "the killed run's step still runs"
    grep -qx 'rm -f dead2' "$t/klog" || fail "the killed run's container was not removed: $(cat "$t/klog")"
    [[ ! -e "$lock" ]] || fail "the lock outlived the run that took it over"
  else
    [[ $code -eq 2 && -e "$left" && -e "$lock" ]] && alive "$aj" || fail "another machine's run: exit $code: $(cat "$t/err")"
    grep -qF "stop its step, if it still runs (on elsewhere.example: kill $aj, the process that started $(sed -n 's/^job=[0-9]* //p' "$lock")), then remove the secrets that it may have left (on elsewhere.example: rm -rf $left), then remove $lock and run again" "$t/err" \
      || fail "the refusal does not say what may be left: $(cat "$t/err")"
    grep -q '^run \|^rm ' "$t/klog" && fail "the refused run ran or removed containers: $(cat "$t/klog")"
    kill "$aj" || true; rm -rf "$left" "$lock"
  fi
done

# a PID that another process has by now is no run: an editor on xless.yml, a process of the same second
sleep 300 & other=$!; bg+=("$other")
tail -f "$t/proj/xless.yml" >/dev/null & editor=$!; bg+=("$editor")
printf 'pid=%s\nstarted=x\nhost=%s\nwork=%s\n' "$editor" "$(uname -n)" "$t/proj" > "$lock"
"${docker[@]}" "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || fail "a process with xless in an argument is taken for a run: $(cat "$t/err")"
printf 'pid=%s\nstarted=%s\nhost=%s\nmark=another 1\nwork=%s\n' "$other" "$(started "$other")" "$(uname -n)" "$t/proj" > "$lock"
"${docker[@]}" "$S" "$t/proj" "${args[@]}" >/dev/null 2>"$t/err" || fail "a process that started in the same second is taken for the run: $(cat "$t/err")"
alive "$other" && alive "$editor" || fail "a process that has a gone run's PID was stopped"

# overlays: the work copy is the overlay's name under the work root, so two overlay files of one name share it, in docker
# and natively; a React Native overlay's is its work volume
mkdir -p "$t/a/app" "$t/b/app"
printf 'type: tauri\nsource: app\n' | tee "$t/a/my.yml" > "$t/b/my.yml"
: > "$t/klog"
"${docker[@]}" RUN_SLEEP=120 "$S" --config "$t/a/my.yml" "${args[@]}" >/dev/null 2>"$t/errA" & a=$!; bg+=("$a")
waitfor '^run ' "$t/klog" || true; grep -q '^run .*--label xless\.work=' "$t/klog" || fail "overlay run without the work copy's label: $(cat "$t/klog" "$t/errA")"
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
