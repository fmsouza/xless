# Records the clang flags an Xcode pack's Swift toolchain needs for Darwin targets (scripts/fit-toolchain.sh runs it).
#   python3 record-flags.py --record <file> [--root <recorded root>] <version> [<root>] <SDK bundle> <flag …>
# --record names the record file (the pack's swift-toolchain.json; it has no default). --root is the root to record,
# taken as is (scripts/fit-toolchain.sh records a relative one: the pack holds no absolute path); without it the
# positional <root> is recorded, and with it that positional is not given.
# - the record gets them as clangFlags (XlessCore SwiftToolchain: Swift Build's build settings);
# - each of the SDK bundle's toolsets gets them as -Xcc options of its swiftCompiler (Swift compiles of SwiftPM builds),
#   ahead of the options it has; a toolset without a swiftCompiler gets one (one per toolset: a second would shadow the
#   first, e.g. toolset.json's -use-ld=lld). A flag the toolset passes already (an earlier fit of the same SDK), wherever
#   it is among its options, is moved ahead rather than passed twice.
import json, sys

argv, record, recorded_root = sys.argv[1:], None, None
while argv and argv[0] in ("--record", "--root"):
    option, value, argv = argv[0], argv[1], argv[2:]
    if option == "--record":
        record = value
    else:
        recorded_root = value
if record is None:
    sys.exit("record-flags.py: --record <file> is required")
version, argv = argv[0], argv[1:]
root, argv = (recorded_root, argv) if recorded_root is not None else (argv[0], argv[1:])
bundle, flags = argv[0], argv[1:]
assert flags, "no flags"
with open(record, "w") as f:
    json.dump({"version": version, "root": root, "clangFlags": flags}, f)
added = [w for flag in flags for w in ("-Xcc", flag)]
for name in ("toolset.json", "toolset-swb.json"):
    path = f"{bundle}/{name}"
    with open(path) as f:
        toolset = json.load(f)
    options = toolset.setdefault("swiftCompiler", {}).setdefault("extraCLIOptions", [])
    kept, i = [], 0
    while i < len(options):
        if options[i] == "-Xcc" and i + 1 < len(options) and options[i + 1] in flags:
            i += 2
        else:
            kept.append(options[i])
            i += 1
    options[:] = added + kept
    with open(path, "w") as f:
        json.dump(toolset, f, indent=2)
    with open(path) as f:
        check = json.load(f)["swiftCompiler"]["extraCLIOptions"]
    assert check[:len(added)] == added, (path, check)
    print(f"{name}: swiftCompiler.extraCLIOptions {check}")
