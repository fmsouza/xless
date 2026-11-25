#!/usr/bin/env bash
# SPIKE (m2b Task 4, "spike A"): build samples/HelloTauri for iOS on Linux by hand, without tauri-cli or Xcode.
# Kept as executable documentation of the Linux build sequence that TauriBuilder (Task 11) automates. It is not
# part of xless and is not run by CI. Findings: docs/research/tauri-ios-contract.md, "Linux build — spike A".
#
# Runs inside xless:<tag>-tauri with the repo mounted read-only. Everything is written under /cache/work:
#
#   docker --context colima-xless run --rm \
#     -v xless-rustup:/cache/rustup -v xless-cargo:/cache/cargo -v xless-spike:/cache/work \
#     -v "$PWD":/repo:ro xless:local-arm64-xcode27.0-tauri /repo/scripts/spikes/hellotauri-linux.sh
#
# Env: SPIKE_STEPS  space-separated subset of: sync rust frontend cargo swift symbols link app
#                   (default: all of them, in that order)
#      SPIKE_CLEAN  1 = also drop the cargo target dir kept from an earlier run (default 0: incremental)
#      SPIKE_REPO   repo root (default /repo)
#      SPIKE_WORK   work copy (default /cache/work/hellotauri)
#
# Outputs, in $SPIKE_WORK/.xless/spike: xcrun.log (every xcrun call as cwd<TAB>argv), required-symbols.txt,
# HelloTauri (the linked executable), HelloTauri.app (executable + minimal Info.plist), allow.txt (gap list for
# `xless tauri compare` so that only the executable section is compared) and, if the image's xless has the
# `tauri` command, report.json + the compare result.
set -euo pipefail

REPO="${SPIKE_REPO:-/repo}"
WORK="${SPIKE_WORK:-/cache/work/hellotauri}"
STEPS="${SPIKE_STEPS:-sync rust frontend cargo swift symbols link app}"
SAMPLE=samples/HelloTauri
OUT="$WORK/.xless/spike"
SWIFT_DIR="$WORK/.xless/swift"
TARGET=aarch64-apple-ios
MIN_IOS=16.0               # bundle.iOS.minimumSystemVersion (tauri's default; gen/apple/project.yml)
CRATE_PACKAGE=hello-tauri  # Cargo [package] name
CRATE_LIB=hello_tauri_lib  # Cargo [lib] name → lib<name>.a
PRODUCT=HelloTauri         # tauri.conf.json productName → executable name
# `sdk:` dependencies of the app target in gen/apple/project.yml, in that order.
SDK_FRAMEWORKS=(CoreGraphics Metal MetalKit QuartzCore Security UIKit WebKit)
# SwiftRs for the aggregate package. 1.0.9 is the release whose @_cdecl FFI (retain_object, release_object,
# string_from_bytes) is `public`; pinned through a generated Package.resolved + --force-resolved-versions.
SWIFTRS_URL=https://github.com/Brendonovich/swift-rs
SWIFTRS_VERSION=1.0.9
SWIFTRS_REVISION=207e4bfe5d36fdd0cc08f28d1849ff94ac7e24b8
# The Swift FFI the Rust side imports: tauri (ios.rs), swift-rs (SRObject/SRString) and one init per plugin.
FFI_PATTERN='^_(init_plugin_[A-Za-z0-9_]+|log_stdout|register_plugin|run_plugin_command|on_webview_created|retain_object|release_object|string_from_bytes)$'

[[ -d /opt/xless ]] || { echo "hellotauri-linux: run inside a tauri kit's image" >&2; exit 1; }
want() { [[ " $STEPS " == *" $1 "* ]]; }
step() { echo; echo "==> [$(date +%T)] $*"; }
SECONDS=0

export RUSTUP_HOME="${RUSTUP_HOME:-/cache/rustup}" CARGO_HOME="${CARGO_HOME:-/cache/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
SDKROOT_IOS="$(/opt/xless/shims/xcrun --sdk iphoneos --show-sdk-path)"
SDK_BUNDLE="${SDKROOT_IOS%%/Developer/Platforms/*}"
TOOLCHAIN="$SDK_BUNDLE/Developer/Toolchains/XcodeDefault.xctoolchain"
LD64="$SDK_BUNDLE/toolset/bin/ld64.lld"
CLANG_RT="$(realpath "$TOOLCHAIN"/usr/lib/clang/*/lib/darwin/libclang_rt.ios.a | sort -u)"   # clang/21.0.0 → 21
HOST_TRIPLE="$(uname -m | sed 's/^arm64$/aarch64/')-unknown-linux-gnu"
HOST_ENV="$(echo "$HOST_TRIPLE" | tr 'a-z-' 'A-Z_')"
CARGO_OUT="$WORK/src-tauri/target/$TARGET/release"

# ---------------------------------------------------------------------------------------------------------------
if want sync; then
  step "sync: tracked files of $SAMPLE → $WORK"
  # A fresh work tree each run; the cargo target dir survives unless SPIKE_CLEAN=1 (incremental cargo).
  KEEP="$WORK.target.keep"; rm -rf "$KEEP"
  if [[ "${SPIKE_CLEAN:-0}" != 1 && -d "$WORK/src-tauri/target" ]]; then mv "$WORK/src-tauri/target" "$KEEP"; fi
  rm -rf "$WORK"; mkdir -p "$WORK"
  git config --global --add safe.directory "$REPO"
  git -C "$REPO" ls-files -z -- "$SAMPLE" | sed -z "s#^$SAMPLE/##" \
    | rsync -a --from0 --files-from=- "$REPO/$SAMPLE/" "$WORK/"
  if [[ -d "$KEEP" ]]; then mv "$KEEP" "$WORK/src-tauri/target"; fi
fi
cd "$WORK"

# xcrun logging wrapper in front of the xless shim: which xcrun calls does a Linux build make (open question 6)?
mkdir -p "$OUT/bin"
cat > "$OUT/bin/xcrun" <<EOF
#!/bin/sh
printf '%s\t%s\n' "\$PWD" "\$*" >> "$OUT/xcrun.log"
exec /opt/xless/shims/xcrun "\$@"
EOF
chmod +x "$OUT/bin/xcrun"
export PATH="$OUT/bin:$PATH"

# ---------------------------------------------------------------------------------------------------------------
if want rust; then
  step "rust: rustup bootstrap; toolchain, targets and components from rust-toolchain.toml"
  command -v rustup >/dev/null || rustup-init -y --no-modify-path --default-toolchain none
  rustup toolchain install   # no argument: installs what rust-toolchain.toml selects (1.97.0 + aarch64-apple-ios)
  rustup show active-toolchain
fi
# The image's llvm-nm is LLVM 14 and fails (exit 1, "Opaque pointers are only supported in -opaque-pointers mode")
# on the LLVM 22 bitcode in Rust 1.97's compiler_builtins members of the staticlib; rustup's llvm-tools nm (the
# `llvm-tools` component in rust-toolchain.toml) reads both those and the Swift objects.
NM="$(rustc --print sysroot)/lib/rustlib/$HOST_TRIPLE/bin/llvm-nm"

# ---------------------------------------------------------------------------------------------------------------
if want frontend; then
  step "frontend: pnpm install + beforeBuildCommand"
  COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm install --frozen-lockfile
  # The hook env tauri-cli sets (contract: "beforeBuildCommand hook"). PLATFORM_VERSION: the SDK version on Linux.
  TAURI_ENV_PLATFORM=ios TAURI_ENV_ARCH=aarch64 TAURI_ENV_TARGET_TRIPLE=$TARGET TAURI_ENV_FAMILY=unix \
  TAURI_ENV_PLATFORM_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)" \
    node scripts/build.mjs
fi

# ---------------------------------------------------------------------------------------------------------------
if want cargo; then
  step "cargo: staticlib only (cargo rustc --crate-type staticlib)"
  # iOS target: what xcode-script sets on the Mac (SDKROOT, IPHONEOS_DEPLOYMENT_TARGET, CFLAGS_<target>), plus the
  # compilers Apple's clang would have provided: the image's clang/llvm-ar, told the target explicitly.
  # Host (build scripts, proc macros): rustc and cc default to `cc`, which the image does not have → clang.
  # No cdylib/rlib for the app crate: the cdylib link needs the Swift symbols (unresolved on Linux, where tauri
  # skips Swift) and an iOS linker setup; nothing uses it on iOS (open question 3).
  env SDKROOT="$SDKROOT_IOS" IPHONEOS_DEPLOYMENT_TARGET=$MIN_IOS \
      TAURI_IOS_APP_NAME=$CRATE_PACKAGE TAURI_IOS_PROJECT_PATH="$WORK/src-tauri/gen/apple" \
      CC_aarch64_apple_ios=clang CXX_aarch64_apple_ios=clang++ AR_aarch64_apple_ios=llvm-ar \
      CFLAGS_aarch64_apple_ios="--target=arm64-apple-ios$MIN_IOS -isysroot $SDKROOT_IOS" \
      CXXFLAGS_aarch64_apple_ios="--target=arm64-apple-ios$MIN_IOS -isysroot $SDKROOT_IOS" \
      "CARGO_TARGET_${HOST_ENV}_LINKER=clang" "CC_${HOST_TRIPLE//-/_}=clang" "CXX_${HOST_TRIPLE//-/_}=clang++" \
    cargo rustc --package $CRATE_PACKAGE --manifest-path src-tauri/Cargo.toml --target $TARGET \
      --features "tauri/custom-protocol tauri/custom-protocol" --lib --release --crate-type staticlib
  ls -l "$CARGO_OUT/lib$CRATE_LIB.a"
  # A Linux-built libapp.a must hold no Swift objects (spec §11 change 2).
  if llvm-objdump --section-headers "$CARGO_OUT/lib$CRATE_LIB.a" 2>/dev/null | grep -q __swift5_; then
    echo "hellotauri-linux: lib$CRATE_LIB.a contains Swift objects" >&2; exit 1
  fi
  "$NM" -u "$CARGO_OUT/lib$CRATE_LIB.a" 2>/dev/null | awk "{print \$NF}" | grep -E "$FFI_PATTERN" | sort -u > "$OUT/required-symbols.txt"
  echo "Swift FFI imported by lib$CRATE_LIB.a:"; sed 's/^/  /' "$OUT/required-symbols.txt"
fi

# ---------------------------------------------------------------------------------------------------------------
if want swift; then
  step "swift: stage packages, generate the aggregate, swift build"
  META="$OUT/cargo-metadata.json"
  cargo metadata --format-version 1 --filter-platform $TARGET --manifest-path src-tauri/Cargo.toml > "$META"
  # tauri's mobile/ios-api, and every package with a build-dependency on tauri-plugin and an ios/Package.swift.
  mapfile -t PKGS < <(python3 - "$META" <<'EOF'
import json, os, sys
m = json.load(open(sys.argv[1]))
for p in m["packages"]:
    d = os.path.dirname(p["manifest_path"])
    if p["name"] == "tauri":
        print(f"api\t{p['name']}\t{d}/mobile/ios-api")
for p in sorted(m["packages"], key=lambda p: p["name"]):
    d = os.path.dirname(p["manifest_path"])
    if any(x["name"] == "tauri-plugin" and x["kind"] == "build" for x in p["dependencies"]) \
       and os.path.isfile(f"{d}/ios/Package.swift"):
        print(f"plugin\t{p['name']}\t{d}/ios")
EOF
  )
  printf '  %s\n' "${PKGS[@]}"

  # Layout: every plugin package is a sibling under plugins/, named after its crate (SwiftPM's identity of a path
  # package is its directory name, so N copies of ios/ would collide), and ONE tauri-api under plugins/.tauri, so
  # each plugin's `path: "../.tauri/tauri-api"` resolves to the same directory (no duplicate-identity warning, one
  # copy of the Tauri module). Nothing is written outside .xless/swift; the cargo registry stays untouched.
  rm -rf "$SWIFT_DIR"; mkdir -p "$SWIFT_DIR/plugins/.tauri" "$SWIFT_DIR/Aggregate/Sources/XlessTauriSwift"
  EXCL=(--exclude=.build --exclude=Package.resolved --exclude=Tests)
  DEPS=""; PRODS=""
  for line in "${PKGS[@]}"; do
    IFS=$'\t' read -r kind name dir <<<"$line"
    if [[ $kind == api ]]; then
      rsync -a "${EXCL[@]}" "$dir/" "$SWIFT_DIR/plugins/.tauri/tauri-api/"
      DEPS+="    .package(name: \"Tauri\", path: \"../plugins/.tauri/tauri-api\"),"$'\n'
      PRODS+="      .product(name: \"Tauri\", package: \"Tauri\"),"$'\n'
    else
      rsync -a "${EXCL[@]}" "$dir/" "$SWIFT_DIR/plugins/$name/"
      product="$(swift package dump-package --package-path "$SWIFT_DIR/plugins/$name" 2>/dev/null \
        | python3 -c 'import json,sys; print(*[p["name"] for p in json.load(sys.stdin)["products"] if "library" in p["type"]])')"
      [[ -n "$product" && "$product" != *" "* ]] || { echo "hellotauri-linux: $name: need exactly one library product, got '$product'" >&2; exit 1; }
      DEPS+="    .package(name: \"$product\", path: \"../plugins/$name\"),"$'\n'
      PRODS+="      .product(name: \"$product\", package: \"$product\"),"$'\n'
    fi
  done
  cat > "$SWIFT_DIR/Aggregate/Package.swift" <<EOF
// swift-tools-version:5.9
// Generated by xless: links every Tauri Swift package of this app into one static library.
import PackageDescription

let package = Package(
  name: "XlessTauriSwift",
  platforms: [.iOS("$MIN_IOS")],
  products: [.library(name: "XlessTauriSwift", type: .static, targets: ["XlessTauriSwift"])],
  dependencies: [
$DEPS  ],
  targets: [
    .target(name: "XlessTauriSwift", dependencies: [
$PRODS    ], path: "Sources"),
  ]
)
EOF
  echo "// Intentionally empty: the product carries its dependencies." \
    > "$SWIFT_DIR/Aggregate/Sources/XlessTauriSwift/XlessTauriSwift.swift"
  cat > "$SWIFT_DIR/Aggregate/Package.resolved" <<EOF
{
  "pins" : [
    {
      "identity" : "swift-rs",
      "kind" : "remoteSourceControl",
      "location" : "$SWIFTRS_URL",
      "state" : {
        "revision" : "$SWIFTRS_REVISION",
        "version" : "$SWIFTRS_VERSION"
      }
    }
  ],
  "version" : 2
}
EOF
  cat "$SWIFT_DIR/Aggregate/Package.swift"

  # Same invocation shape as MacBuilder: Swift Build, a versioned triple (so every module, dependencies included,
  # gets minos $MIN_IOS like swift-rs's `--triple arm64-apple-ios16.0` on the Mac), the SDK bundle's swb toolset,
  # its platforms via XCODE_EXTRA_PLATFORM_FOLDERS (else "unable to find platform for 'iphoneos'") and no SDKROOT.
  env -u SDKROOT XCODE_EXTRA_PLATFORM_FOLDERS="$SDK_BUNDLE/Developer/Platforms" PATH="$SDK_BUNDLE/toolset/bin:$PATH" \
    swift build -c release --package-path "$SWIFT_DIR/Aggregate" --build-system swiftbuild \
      --triple arm64-apple-ios$MIN_IOS --toolset "$SDK_BUNDLE/toolset-swb.json" --force-resolved-versions
  AGG="$SWIFT_DIR/Aggregate/.build/out/Products/Release-iphoneos/libXlessTauriSwift.a"
  ls -l "$AGG"
  echo "members: $(llvm-ar t "$AGG" | tr '\n' ' ')"
  grep -E '"(version|revision)"' "$SWIFT_DIR/Aggregate/Package.resolved"
fi
AGG="$SWIFT_DIR/Aggregate/.build/out/Products/Release-iphoneos/libXlessTauriSwift.a"

# ---------------------------------------------------------------------------------------------------------------
if want symbols; then
  step "symbols: every Swift FFI symbol lib$CRATE_LIB.a imports must be global in the aggregate"
  # `nm -g` lists N_EXT symbols, with or without N_PEXT: the @_cdecl functions come out "private external"
  # (hidden) unless declared public (SwiftRs 1.0.9's three are "external"). Both resolve in the static link of
  # the executable; only a local (`t`) symbol would not.
  "$NM" -g --defined-only "$AGG" 2>/dev/null | awk '$2 ~ /^[TSD]$/ {print $3}' | sort -u > "$OUT/aggregate-globals.txt"
  missing="$(comm -23 "$OUT/required-symbols.txt" "$OUT/aggregate-globals.txt")"
  if [[ -n "$missing" ]]; then
    echo "hellotauri-linux: not global in the aggregate:" $missing >&2
    "$NM" "$AGG" 2>/dev/null | grep -wE "$(echo $missing | tr ' ' '|')" >&2 || true
    exit 1
  fi
  "$NM" -g --defined-only "$AGG" 2>/dev/null | grep -wFf "$OUT/required-symbols.txt" | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------------------------------------------
if want link; then
  step "link: compile main.mm, link with ld64.lld"
  # Xcode's CompileC flags for main.mm, minus header maps, -g/-gmodules and diagnostics plumbing.
  clang -x objective-c++ -target arm64-apple-ios$MIN_IOS -isysroot "$SDKROOT_IOS" -std=gnu++14 -stdlib=libc++ \
    -fobjc-arc -fobjc-weak -fmodules -fno-cxx-modules -fpascal-strings -Os -fno-common \
    -DNS_BLOCK_ASSERTIONS=1 -DOBJC_OLD_DISPATCH_PROTOTYPES=0 -fvisibility=hidden -fvisibility-inlines-hidden \
    -c src-tauri/gen/apple/Sources/$CRATE_PACKAGE/main.mm -o "$OUT/main.o"
  FW=(); for f in "${SDK_FRAMEWORKS[@]}"; do FW+=(-framework "$f"); done
  # Xcode's link line with these changes: ld64.lld via -fuse-ld; -mlinker-version so the driver emits
  # -platform_version (without it clang assumes an ancient ld64 and passes -iphoneos_version_min, which ld64.lld
  # rejects); the crate's staticlib and the aggregate instead of -lapp; the Swift library dirs as on the Mac;
  # libclang_rt.ios.a explicitly (Xcode's driver adds it from its resource dir; the Linux clang's resource dir has
  # no lib/darwin, so it silently adds nothing). ld64-only flags -reproducible, -no_warn_duplicate_libraries,
  # -object_path_lto, -final_output and -dependency_info are dropped.
  clang++ -target arm64-apple-ios$MIN_IOS -isysroot "$SDKROOT_IOS" -Os -fuse-ld="$LD64" -mlinker-version=907 \
    -L "$CARGO_OUT" -L "$SDKROOT_IOS/usr/lib/swift" -L "$TOOLCHAIN/usr/lib/swift/iphoneos" \
    "$OUT/main.o" -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -dead_strip \
    -stdlib=libc++ -fobjc-arc -fobjc-link-runtime -l$CRATE_LIB "$AGG" "$CLANG_RT" "${FW[@]}" \
    -o "$OUT/$PRODUCT" -v 2> "$OUT/link.log" || { grep -v '^ *>>>' "$OUT/link.log" | tail -40 >&2; exit 1; }
  grep -F "$LD64\"" "$OUT/link.log" | sed 's/^ */  ld: /'
  grep -c 'does not support linking for platform iOS' "$OUT/link.log" | sed 's/^/  lld "platform iOS" warnings: /'
  ls -l "$OUT/$PRODUCT"
  llvm-objdump --macho --private-headers "$OUT/$PRODUCT" | grep -A5 LC_BUILD_VERSION | grep -E 'platform|minos|sdk'
  llvm-objdump --macho --private-headers "$OUT/$PRODUCT" | grep -A2 LC_RPATH | grep path
  llvm-objdump --macho --dylibs-used "$OUT/$PRODUCT" | tail -n +2 | awk '{print $1}' | sort > "$OUT/linked-libraries.txt"
  echo "linked libraries: $(wc -l < "$OUT/linked-libraries.txt")"
fi

# ---------------------------------------------------------------------------------------------------------------
if want app; then
  step "app: minimal .app (executable + Info.plist) and the gap list for an executable-only compare"
  APPDIR="$OUT/$PRODUCT.app"; rm -rf "$APPDIR"; mkdir -p "$APPDIR"
  cp "$OUT/$PRODUCT" "$APPDIR/$PRODUCT"
  cat > "$APPDIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$PRODUCT</string>
</dict>
</plist>
EOF
  # Bundling is not part of this spike: allow every file/plist difference, so only lib:, rpath:, exe: count.
  python3 - "$WORK/reference/reference.json" > "$OUT/allow.txt" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
print("# spike A: bundle contents are out of scope; compare the executable section only")
for f in r["files"]:
    if f not in ("Info.plist",) and f != r["infoPlist"]["CFBundleExecutable"]:
        print(f"file:{f}")
for k in sorted(set(r["infoPlist"]) | {"CFBundleExecutable"}):
    if k != "CFBundleExecutable":
        print(f"plist:{k}")
EOF
  if xless tauri --help 2>/dev/null | grep -qw compare; then
    xless tauri report "$APPDIR" --json "$OUT/report.json"
    xless tauri compare "$WORK/reference/reference.json" "$APPDIR" --allow-file "$OUT/allow.txt" \
      && echo "compare: executable matches the reference"
  else
    echo "this image's xless has no 'tauri' command; copy $APPDIR out and run on the Mac:"
    echo "  swift run xless tauri compare $SAMPLE/reference/reference.json <app> --allow-file <allow.txt>"
  fi
fi

echo; echo "==> done in ${SECONDS}s"
