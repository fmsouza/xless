# Ruling R10 (docker/Dockerfile.sdk): records the clang flags a Swift toolchain needs for Darwin targets.
#   python3 record-flags.py <version> <root> <SDK bundle> <flag …>
# - the record (/opt/xless/swift-toolchain.json, or $XLESS_SWIFT_TOOLCHAIN_RECORD: a native install's) gets them as clangFlags (XlessCore SwiftToolchain: Swift Build's build settings);
# - each of the SDK bundle's toolsets gets them as -Xcc options of its swiftCompiler (Swift compiles of SwiftPM builds),
#   ahead of the options it has; a toolset without a swiftCompiler gets one (one per toolset: a second would shadow the
#   first, e.g. toolset.json's -use-ld=lld).
import json, os, sys

version, root, bundle, flags = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
assert flags, "no flags"
with open(os.environ.get("XLESS_SWIFT_TOOLCHAIN_RECORD") or "/opt/xless/swift-toolchain.json", "w") as f:
    json.dump({"version": version, "root": root, "clangFlags": flags}, f)
for name in ("toolset.json", "toolset-swb.json"):
    path = f"{bundle}/{name}"
    with open(path) as f:
        toolset = json.load(f)
    options = toolset.setdefault("swiftCompiler", {}).setdefault("extraCLIOptions", [])
    options[:0] = [w for flag in flags for w in ("-Xcc", flag)]
    with open(path, "w") as f:
        json.dump(toolset, f, indent=2)
    with open(path) as f:
        check = json.load(f)["swiftCompiler"]["extraCLIOptions"]
    assert check[:2 * len(flags)] == [w for flag in flags for w in ("-Xcc", flag)], (path, check)
    print(f"{name}: swiftCompiler.extraCLIOptions {check}")
