# Ruling R10 (docker/Dockerfile): records the clang flags a Swift toolchain needs for Darwin targets.
#   python3 record-flags.py [--record <file>] [--root <recorded root>] <version> [<root>] <SDK bundle> <flag …>
# --record names the record file (default: $XLESS_SWIFT_TOOLCHAIN_RECORD, else /opt/xless/swift-toolchain.json). --root
# is the root to record, taken as is (scripts/fit-toolchain.sh records a relative one: the pack holds no absolute path);
# without it the positional <root> is recorded, and with it that positional is not given.
# - the record (/opt/xless/swift-toolchain.json, or $XLESS_SWIFT_TOOLCHAIN_RECORD: a native install's) gets them as clangFlags (XlessCore SwiftToolchain: Swift Build's build settings);
# - each of the SDK bundle's toolsets gets them as -Xcc options of its swiftCompiler (Swift compiles of SwiftPM builds),
#   ahead of the options it has; a toolset without a swiftCompiler gets one (one per toolset: a second would shadow the
#   first, e.g. toolset.json's -use-ld=lld).
import json, os, sys

argv, record, recorded_root = sys.argv[1:], os.environ.get("XLESS_SWIFT_TOOLCHAIN_RECORD") or "/opt/xless/swift-toolchain.json", None
while argv and argv[0] in ("--record", "--root"):
    option, value, argv = argv[0], argv[1], argv[2:]
    if option == "--record":
        record = value
    else:
        recorded_root = value
version, argv = argv[0], argv[1:]
root, argv = (recorded_root, argv) if recorded_root is not None else (argv[0], argv[1:])
bundle, flags = argv[0], argv[1:]
assert flags, "no flags"
with open(record, "w") as f:
    json.dump({"version": version, "root": root, "clangFlags": flags}, f)
for name in ("toolset.json", "toolset-swb.json"):
    path = f"{bundle}/{name}"
    with open(path) as f:
        toolset = json.load(f)
    options = toolset.setdefault("swiftCompiler", {}).setdefault("extraCLIOptions", [])
    added = [w for flag in flags for w in ("-Xcc", flag)]
    if options[:len(added)] != added:  # a second fit of the same SDK adds nothing
        options[:0] = added
    with open(path, "w") as f:
        json.dump(toolset, f, indent=2)
    with open(path) as f:
        check = json.load(f)["swiftCompiler"]["extraCLIOptions"]
    assert check[:2 * len(flags)] == [w for flag in flags for w in ("-Xcc", flag)], (path, check)
    print(f"{name}: swiftCompiler.extraCLIOptions {check}")
