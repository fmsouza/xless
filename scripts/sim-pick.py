#!/usr/bin/env python3
"""Picks the iOS simulator for scripts/sim-launch.sh: a device on a runtime that matches the Xcode's SDK.

  sim-pick.py --devices <json> --runtimes <json> --match <json> --sdk-version <v> --device <name|udid> [--runtime <spec>]

--devices, --runtimes and --match are the outputs of `xcrun simctl list devices available -j`,
`xcrun simctl list runtimes available -j` and `xcrun simctl runtime match list -j` (an empty object when the Xcode's
simctl has no `runtime match`), all under the Xcode in question (DEVELOPER_DIR). --sdk-version is that Xcode's
iphonesimulator SDK version.

The runtime: --runtime (an identifier, a build, a version such as 26.3.1, or the runtime's short version such as 26.3)
when given, else the one Xcode itself pairs with its iphoneos SDK (`runtime match list`'s chosenRuntimeBuild), else the
newest one whose major.minor is the SDK's. The device: --device by UDID or by name on that runtime; a name with no device
on it is created there (iPhone 17 when the runtime supports it, else its last listed iPhone).

Prints one tab-separated line: `use <udid> <runtime id> <runtime name>` or
`create <device type id> <runtime id> <runtime name>`. Exit 2, with the reason on stderr, when there is no such runtime
or the device named by UDID is on another runtime.
"""
import argparse
import json
import sys


def die(msg):
    print(f"sim-launch: {msg}", file=sys.stderr)
    sys.exit(2)


def vkey(v):
    return [int(x) if x.isdigit() else 0 for x in v.split(".")]


def short(r):  # "iOS 26.3" -> "26.3" (the version field may be 26.3.1)
    name = r.get("name", "")
    return name[4:] if name.startswith("iOS ") else r.get("version", "")


def describe(r):
    return f"{r.get('name', r['identifier'])} ({r.get('version', '?')} - {r.get('buildversion', '?')})"


def main():
    ap = argparse.ArgumentParser()
    for a in ("--devices", "--runtimes", "--match", "--sdk-version", "--device"):
        ap.add_argument(a, required=True)
    ap.add_argument("--runtime", default="")
    args = ap.parse_args()

    load = lambda p: json.load(open(p)) if p else {}
    runtimes = [r for r in load(args.runtimes).get("runtimes", [])
                if r.get("platform") == "iOS" and r.get("isAvailable", True)]
    runtimes.sort(key=lambda r: vkey(r.get("version", "0")))
    devices = load(args.devices).get("devices", {})
    match = load(args.match)
    installed = ", ".join(describe(r) for r in runtimes) or "none"

    if args.runtime:
        s = args.runtime
        cands = [r for r in runtimes if s in (r["identifier"], r.get("buildversion"), r.get("version"), short(r))]
        if not cands:
            die(f"no available iOS simulator runtime '{s}' (installed: {installed})")
        runtime = cands[-1]
    else:
        sdk = args.sdk_version
        chosen = next((m.get("chosenRuntimeBuild") for m in match.values()
                       if isinstance(m, dict) and m.get("platform") == "com.apple.platform.iphoneos"), None)
        exact = [r for r in runtimes if chosen and r.get("buildversion") == chosen]
        same = [r for r in runtimes if vkey(r.get("version", "0"))[:2] == vkey(sdk)[:2]]
        if not (exact or same):
            want = f"iOS {sdk}" + (f" (build {chosen}, Xcode's choice for its SDK)" if chosen else "")
            die(f"no simulator runtime matches this Xcode's iphonesimulator{sdk} SDK: it needs {want}; installed: "
                f"{installed}. Install it with `xcodebuild -downloadPlatform iOS` under this DEVELOPER_DIR, or pass "
                f"--runtime <version> to launch on another runtime deliberately.")
        runtime = (exact or same)[-1]
    rid, rname = runtime["identifier"], runtime.get("name", runtime["identifier"])

    want = args.device
    for r_id, devs in devices.items():
        for d in devs:
            if d.get("udid") == want:
                if r_id != rid:
                    why = "the --runtime given" if args.runtime else "the runtime that matches this Xcode's SDK"
                    die(f"device {want} ({d.get('name')}) is on {r_id}, not {rid} ({rname}), {why}; "
                        f"pass --runtime {r_id} to use it anyway")
                print("\t".join(["use", want, rid, rname]))
                return
    on_rt = [d for d in devices.get(rid, []) if d.get("name") == want]
    if on_rt:
        on_rt.sort(key=lambda d: d.get("state") != "Booted")
        print("\t".join(["use", on_rt[0]["udid"], rid, rname]))
        return
    elsewhere = sorted(r_id for r_id, devs in devices.items()
                       if ".iOS-" in r_id and any(d.get("name") == want for d in devs))
    if elsewhere:
        print(f"sim-launch: note: {want} exists on {', '.join(elsewhere)} only; creating one on {rname}", file=sys.stderr)
    types = [t["identifier"] for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
    iphone17 = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
    dtype = iphone17 if (iphone17 in types or not types) else types[-1]
    print("\t".join(["create", dtype, rid, rname]))


if __name__ == "__main__":
    main()
