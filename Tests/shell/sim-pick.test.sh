#!/usr/bin/env bash
# scripts/sim-pick.py (scripts/sim-launch.sh's device choice): with several iOS runtimes installed, the device is on the
# runtime that matches the Xcode's SDK, never on whichever one a same-named device happens to be on.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
P="$root/scripts/sim-pick.py"
RT=com.apple.CoreSimulator.SimRuntime
DT=com.apple.CoreSimulator.SimDeviceType

types() { local out="" ty; for ty; do out+="${out:+,}{\"identifier\":\"$DT.$ty\",\"productFamily\":\"iPhone\"}"; done; echo "[$out]"; }
cat > "$t/runtimes.json" <<JSON
{"runtimes": [
 {"identifier": "$RT.iOS-27-0", "name": "iOS 27.0", "version": "27.0", "buildversion": "24A434", "platform": "iOS", "isAvailable": true, "supportedDeviceTypes": $(types iPhone-17 iPhone-18-Pro)},
 {"identifier": "$RT.iOS-18-5", "name": "iOS 18.5", "version": "18.5", "buildversion": "22F77", "platform": "iOS", "isAvailable": true, "supportedDeviceTypes": $(types iPhone-16 iPhone-16-Pro)},
 {"identifier": "$RT.iOS-26-3", "name": "iOS 26.3", "version": "26.3.1", "buildversion": "23D8133", "platform": "iOS", "isAvailable": true, "supportedDeviceTypes": $(types iPhone-17)},
 {"identifier": "$RT.iOS-26-1", "name": "iOS 26.1", "version": "26.1", "buildversion": "23B86", "platform": "iOS", "isAvailable": true, "supportedDeviceTypes": $(types iPhone-17)},
 {"identifier": "$RT.watchOS-26-1", "name": "watchOS 26.1", "version": "26.1", "buildversion": "23S1", "platform": "watchOS", "isAvailable": true}
]}
JSON
# xless-sim exists on 27.0 (listed first) and on 26.1; BBBB is on 26.3.
cat > "$t/devices.json" <<JSON
{"devices": {
 "$RT.iOS-27-0": [{"name": "xless-sim", "udid": "AAAA", "state": "Shutdown"}],
 "$RT.iOS-26-3": [{"name": "Other", "udid": "BBBB", "state": "Shutdown"}],
 "$RT.iOS-26-1": [{"name": "xless-sim", "udid": "CCCC", "state": "Shutdown"}, {"name": "xless-sim", "udid": "DDDD", "state": "Booted"}],
 "$RT.watchOS-26-1": [{"name": "xless-sim", "udid": "WWWW", "state": "Shutdown"}]
}}
JSON
match() {   # match <sdk version> <chosen runtime build>
  printf '{"iphoneos%s": {"platform": "com.apple.platform.iphoneos", "sdkVersion": "%s", "chosenRuntimeBuild": "%s"},
"watchos%s": {"platform": "com.apple.platform.watchos", "chosenRuntimeBuild": "23S1"}}\n' "$1" "$1" "$2" "$1" > "$t/match.json"
}
pick() {   # pick <sdk version> <device> [<runtime>]
  python3 "$P" --devices "$t/devices.json" --runtimes "$t/runtimes.json" --match "$t/match.json" \
    --sdk-version "$1" --device "$2" --runtime "${3:-}"
}
want() { local got; got=$(pick "${@:2}" 2>"$t/err") || fail "pick ${*:2} failed: $(cat "$t/err")"; [[ "$got" == "$1" ]] || fail "pick ${*:2}: $got, want $1"; }
refused() { local rc=0; pick "${@:2}" >/dev/null 2>"$t/err" || rc=$?; [[ $rc == 2 ]] || fail "pick ${*:2} exits $rc, want 2"; grep -q -- "$1" "$t/err" || fail "pick ${*:2}: no '$1' in: $(cat "$t/err")"; }
T=$'\t'

# Xcode's own pairing (chosenRuntimeBuild) wins; the booted one of two same-named devices is used.
match 26.1 23B86
want "use${T}DDDD${T}$RT.iOS-26-1${T}iOS 26.1" 26.1 xless-sim
# A device of that name only on another runtime is not used: one is created on the matching runtime.
match 26.3 23D8133
want "create${T}$DT.iPhone-17${T}$RT.iOS-26-3${T}iOS 26.3" 26.3 xless-sim
grep -q "exists on .*iOS-26-1, .*iOS-27-0 only" "$t/err" || fail "no note about the other runtimes: $(cat "$t/err")"
# Without Xcode's choice installed (or listed), the SDK's major.minor decides: SDK 26.3 → runtime version 26.3.1.
match 26.3 23D9999
want "create${T}$DT.iPhone-17${T}$RT.iOS-26-3${T}iOS 26.3" 26.3 xless-sim
echo '{}' > "$t/match.json"
want "use${T}BBBB${T}$RT.iOS-26-3${T}iOS 26.3" 26.3 BBBB
# No runtime for the SDK: refused, naming the SDK, Xcode's choice and the remedies; never the newest instead.
match 27.2 24B8118
refused "iphonesimulator27.2 SDK" 27.2 xless-sim
for s in 24B8118 "downloadPlatform iOS" "--runtime" "iOS 27.0 (27.0 - 24A434)"; do grep -q -- "$s" "$t/err" || fail "refusal lacks '$s'"; done
match 26.2 23C53
refused "iphonesimulator26.2 SDK" 26.2 xless-sim
# --runtime picks one deliberately, by version, short version, build or identifier.
want "use${T}AAAA${T}$RT.iOS-27-0${T}iOS 27.0" 27.2 xless-sim 27.0
want "use${T}BBBB${T}$RT.iOS-26-3${T}iOS 26.3" 27.2 BBBB 26.3
want "use${T}BBBB${T}$RT.iOS-26-3${T}iOS 26.3" 27.2 BBBB 26.3.1
want "use${T}BBBB${T}$RT.iOS-26-3${T}iOS 26.3" 27.2 BBBB 23D8133
want "use${T}BBBB${T}$RT.iOS-26-3${T}iOS 26.3" 27.2 BBBB "$RT.iOS-26-3"
refused "no available iOS simulator runtime '26.2'" 27.2 xless-sim 26.2
refused "no available iOS simulator runtime '$RT.watchOS-26-1'" 27.2 xless-sim "$RT.watchOS-26-1"
# A device given by UDID on another runtime is refused (with how to use it anyway), not silently used.
match 26.1 23B86
refused "pass --runtime $RT.iOS-26-3" 26.1 BBBB
# A runtime without iPhone 17 gets its last listed iPhone.
want "create${T}$DT.iPhone-16-Pro${T}$RT.iOS-18-5${T}iOS 18.5" 26.1 xless-sim 18.5
# sim-launch.sh uses it.
grep -q 'sim-pick.py' "$root/scripts/sim-launch.sh" || fail "sim-launch.sh does not call sim-pick.py"
echo PASS
