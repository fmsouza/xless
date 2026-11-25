# The xless image: one per Xcode and architecture (xless:local-<arch>-xcode<version>; docs/images.md). It holds xless's job and
# no app's toolchain: Swift and the Swift toolchain the Xcode ships, xless, xtool, rcodesign, that Xcode's Darwin SDK, Swift
# Build, stand-ins for Xcode's command-line tools, LLVM's binutils and the DMG tools. Node, Rust, Ruby and the like are added on
# top of it: docker/tauri and docker/react-native, or a Dockerfile of the project's own.
#
# scripts/docker-images.sh builds it, on this machine only: it holds Apple's SDK, so it is never pushed. What changes most often
# comes last, so a new xless rebuilds the last layers alone. The target `tools` has no SDK: `xless setup` exports one with it.
# SWIFT_IMAGE: versions.env's swift:<SWIFT_VERSION>-jammy@sha256:… (pinned by digest)
ARG SWIFT_IMAGE
# XLESS_FROM=prebuilt takes the xless binary from the build context xlessbin (a directory holding a file named xless;
# scripts/docker-images.sh base --xless-bin) instead of compiling it: no source checkout needed.
ARG XLESS_FROM=source
# Runs natively on the build host and cross-compiles with the Static Linux SDK
# (swift build under Rosetta/QEMU emulation crashes intermittently).
FROM --platform=$BUILDPLATFORM ${SWIFT_IMAGE} AS build
ARG TARGETARCH
ARG STATIC_SDK_URL
ARG STATIC_SDK_SHA256
WORKDIR /src
RUN swift sdk install "$STATIC_SDK_URL" --checksum "$STATIC_SDK_SHA256"
COPY Package.swift Package.resolved ./
COPY ThirdParty ThirdParty
# GitHub rate-limits git over HTTP/2 from this git version (401)
RUN git config --global http.version HTTP/1.1
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN set -eux; \
    case "$TARGETARCH" in arm64) A=aarch64 ;; amd64) A=x86_64 ;; *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
    swift build -c release --product xless --swift-sdk "${A}-swift-linux-musl"; \
    install -m755 "$(swift build -c release --swift-sdk "${A}-swift-linux-musl" --show-bin-path)/xless" /usr/local/bin/xless

FROM scratch AS xless-source
COPY --from=build /usr/local/bin/xless /xless

FROM scratch AS xless-prebuilt
COPY --from=xlessbin /xless /xless

FROM xless-${XLESS_FROM} AS xless-bin

# libdmg-hfsplus (GPL-3): only its `dmg` and `hfsplus` executables are copied into the image and run as external
# tools; nothing of it is linked into xless.
FROM ${SWIFT_IMAGE} AS libdmg
ARG LIBDMG_HFSPLUS_COMMIT
ARG LIBDMG_HFSPLUS_SHA256
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates cmake make gcc libc6-dev zlib1g-dev libbz2-dev liblzma-dev \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    curl -fsSL -o /tmp/libdmg.tar.gz "https://github.com/mozilla/libdmg-hfsplus/archive/${LIBDMG_HFSPLUS_COMMIT}.tar.gz"; \
    echo "${LIBDMG_HFSPLUS_SHA256}  /tmp/libdmg.tar.gz" | sha256sum -c -; \
    mkdir -p /src/libdmg; tar -xzf /tmp/libdmg.tar.gz -C /src/libdmg --strip-components=1; \
    cmake -S /src/libdmg -B /build -DCMAKE_BUILD_TYPE=Release -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON; \
    make -C /build -j"$(nproc)" dmg-bin hfsplus; \
    mkdir -p /out; install -m755 /build/dmg/dmg /build/hfs/hfsplus /out/; cp /src/libdmg/LICENSE /out/LICENSE

# The Swift toolchain's own llvm-objcopy (LLVM 21, the LLVM of ld64.lld; it is llvm-strip when called by that name): the
# strip shim's tool, whose output is closest to Xcode's strip. The LLVM 14 package of `tools` replaces /usr/bin/llvm-objcopy.
FROM ${SWIFT_IMAGE} AS swifttools

FROM ${SWIFT_IMAGE} AS tools
ARG TARGETARCH
ARG XTOOL_VERSION
ARG RCODESIGN_VERSION
ARG XTOOL_SHA256_AARCH64
ARG XTOOL_SHA256_X86_64
ARG RCODESIGN_SHA256_AARCH64
ARG RCODESIGN_SHA256_X86_64
# Every image built on this one inherits it; `xless clean` finds the untagged older builds by it.
LABEL org.xless.image=true
# SWIFT_DETERMINISTIC_HASHING: Swift seeds every Dictionary and Set from the process, so the binary property lists that
# Foundation writes (Info.plist of a bundle, Expo.plist) list their keys in a different order on every run, and a build is
# not byte-for-byte reproducible, on one host or between an arm64 and an amd64 host (scripts/arch-compare.sh).
ENV APPIMAGE_EXTRACT_AND_RUN=1 \
    XDG_CONFIG_HOME=/opt/xless/config \
    XLESS_TOOLCHAIN_META=/opt/xless/toolchain-meta.json \
    SWIFT_DETERMINISTIC_HASHING=1
# What xless runs itself, and the libraries of the DMG tools (zlib, bz2, lzma) and of Swift Build (sqlite, ncurses).
# mkfs.hfsplus (hfsprogs, jammy universe) makes a DMG's empty HFS+ volume.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates zip unzip librsvg2-bin squashfs-tools cpio \
      rsync git python3 llvm hfsprogs zlib1g libbz2-1.0 liblzma5 libsqlite3-0 libncurses6 \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "$TARGETARCH" in arm64) A=aarch64; XSUM="$XTOOL_SHA256_AARCH64"; RSUM="$RCODESIGN_SHA256_AARCH64" ;; amd64) A=x86_64; XSUM="$XTOOL_SHA256_X86_64"; RSUM="$RCODESIGN_SHA256_X86_64" ;; *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
    curl -fsSL -o /tmp/xtool.AppImage "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VERSION}/xtool-${A}.AppImage"; \
    echo "${XSUM}  /tmp/xtool.AppImage" | sha256sum -c -; \
    # squashfs-tools 4.4 (jammy) dies on xtool 1.21.0's AppImage ("Data queue size is too large");
    # the AppImage runtime ships its own unsquashfs, so extract with it. --appimage-extract lands
    # in "squashfs-root" under the RUN's cwd, which is / .
    chmod +x /tmp/xtool.AppImage; /tmp/xtool.AppImage --appimage-extract >/dev/null; mv /squashfs-root /opt/xtool; ln -s /opt/xtool/AppRun /usr/local/bin/xtool; rm -f /tmp/xtool.AppImage; \
    # Its runtime makes the directories readable by root alone, and the SDK is exported as the calling user.
    chmod -R a+rX /opt/xtool; \
    RC="apple-codesign-${RCODESIGN_VERSION}-${A}-unknown-linux-musl"; \
    curl -fsSL -o "/tmp/${RC}.tar.gz" "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F${RCODESIGN_VERSION}/${RC}.tar.gz"; \
    echo "${RSUM}  /tmp/${RC}.tar.gz" | sha256sum -c -; \
    tar -xzf "/tmp/${RC}.tar.gz" -C /tmp; install -m755 "$(find /tmp/${RC} -name rcodesign -type f | head -1)" /usr/local/bin/rcodesign; \
    rm -rf /tmp/${RC}*
RUN mkdir -p /opt/xless/config && chmod -R a+rwX /opt/xless && xtool --help >/dev/null && rcodesign --version
WORKDIR /work

# The Swift that compiles app code (Ruling R10).
FROM tools AS toolchain
ARG TARGETARCH
# APP_SWIFT_VERSION: the open-source release versions.env maps the Xcode to (scripts/xcode-swift.sh, run by
# scripts/docker-images.sh); empty when it is the image's own Swift (SWIFT_VERSION), which then compiles app code as well. Otherwise the
# release is installed under /opt/xless/toolchains/swift-<version>, without what no build uses (LLDB, SourceKit-LSP,
# clangd, DocC, swift-format, the Embedded Swift and static Linux standard libraries). xless itself stays built with the
# image's own Swift, as does Swift Build (below). /opt/xless/swift-toolchain.json records the toolchain
# (XlessCore SwiftToolchain); prepare and the build stage check it against the Xcode's Swift in toolchain-meta.json.
# A release x.y.0 names itself without the patch (`Swift version 6.2 (swift-6.2-RELEASE)`), which the install checks for.
ARG APP_SWIFT_VERSION=
ARG APP_SWIFT_URL_AARCH64=
ARG APP_SWIFT_SHA256_AARCH64=
ARG APP_SWIFT_URL_X86_64=
ARG APP_SWIFT_SHA256_X86_64=
ENV XLESS_SWIFT_TOOLCHAIN=/opt/xless/swift-toolchain.json
RUN set -eux; \
    if [ -n "$APP_SWIFT_VERSION" ]; then \
      case "$TARGETARCH" in arm64) U="$APP_SWIFT_URL_AARCH64"; H="$APP_SWIFT_SHA256_AARCH64" ;; amd64) U="$APP_SWIFT_URL_X86_64"; H="$APP_SWIFT_SHA256_X86_64" ;; *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
      [ -n "$U" ] || { echo "no Swift toolchain URL for $TARGETARCH (APP_SWIFT_URL_*)"; exit 1; }; \
      [ -n "$H" ] || { echo "no Swift toolchain sha256 for $TARGETARCH (APP_SWIFT_SHA256_*)"; exit 1; }; \
      root="/opt/xless/toolchains/swift-$APP_SWIFT_VERSION"; \
      curl -fsSL -o /tmp/swift.tar.gz "$U"; \
      echo "$H  /tmp/swift.tar.gz" | sha256sum -c -; \
      mkdir -p "$root"; tar -xzf /tmp/swift.tar.gz -C "$root" --strip-components=1; rm /tmp/swift.tar.gz; \
      cd "$root/usr"; \
      rm -rf bin/lldb* lib/liblldb* lib/python3* bin/sourcekit-lsp lib/libsourcekitdInProc.so lib/libSwiftSourceKit*.so \
             bin/clangd bin/docc share/docc bin/swift-format bin/wasmkit bin/swift-build-sdk-interfaces lib/swift/embedded \
             lib/swift_static local; \
      sv="${APP_SWIFT_VERSION%.0}"; \
      "$root/usr/bin/swiftc" --version | grep -qF "Swift version $sv (swift-$sv-RELEASE)"; \
      v="$APP_SWIFT_VERSION"; \
    else \
      root=/; v="$(swiftc --version | sed -nE 's/.*Swift version ([0-9.]+) .*/\1/p' | head -1)"; [ -n "$v" ]; \
    fi; \
    printf '{"version":"%s","root":"%s"}\n' "$v" "$root" > /opt/xless/swift-toolchain.json; \
    test -x "${root%/}/usr/bin/clang" && test -x "${root%/}/usr/bin/swift-frontend"

# Swift Build (swiftlang/swift-build): `swbuild` is its CLI; it launches `SWBBuildServiceBundle` from its own directory,
# and both read the resource bundles (`SwiftBuild_*.bundle`, the xcspecs) next to the executable. Dependencies are
# sibling source checkouts (SWIFTCI_USE_LOCAL_DEPS=1), so nothing is resolved from a branch at build time.
FROM toolchain AS swb
ARG SWB_TAG
ARG SWB_SHA256
ARG SWB_DRIVER_SHA256
ARG SWB_LLBUILD_SHA256
ARG SWB_TSC_SHA256
ARG SWB_TOOLS_PROTOCOLS_SHA256
ARG SWB_ARGUMENT_PARSER_VERSION
ARG SWB_ARGUMENT_PARSER_SHA256
ARG SWB_SYSTEM_VERSION
ARG SWB_SYSTEM_SHA256
ARG SWB_SQLITE_VERSION
ARG SWB_SQLITE_SHA256
RUN apt-get update \
 && apt-get install -y --no-install-recommends libncurses-dev libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    fetch() { curl -fsSL -o "/tmp/$1.tar.gz" "https://github.com/$2/archive/refs/tags/$3.tar.gz"; \
              echo "$4  /tmp/$1.tar.gz" | sha256sum -c -; \
              mkdir -p "/src/$1"; tar -xzf "/tmp/$1.tar.gz" -C "/src/$1" --strip-components=1; rm "/tmp/$1.tar.gz"; }; \
    fetch swift-build swiftlang/swift-build "$SWB_TAG" "$SWB_SHA256"; \
    fetch swift-driver swiftlang/swift-driver "$SWB_TAG" "$SWB_DRIVER_SHA256"; \
    fetch llbuild swiftlang/swift-llbuild "$SWB_TAG" "$SWB_LLBUILD_SHA256"; \
    fetch swift-tools-support-core swiftlang/swift-tools-support-core "$SWB_TAG" "$SWB_TSC_SHA256"; \
    fetch swift-tools-protocols swiftlang/swift-tools-protocols "$SWB_TAG" "$SWB_TOOLS_PROTOCOLS_SHA256"; \
    fetch swift-argument-parser apple/swift-argument-parser "$SWB_ARGUMENT_PARSER_VERSION" "$SWB_ARGUMENT_PARSER_SHA256"; \
    fetch swift-system apple/swift-system "$SWB_SYSTEM_VERSION" "$SWB_SYSTEM_SHA256"; \
    fetch swift-toolchain-sqlite swiftlang/swift-toolchain-sqlite "$SWB_SQLITE_VERSION" "$SWB_SQLITE_SHA256"
# Built with the image's app Swift toolchain (Ruling R10; /opt/xless/swift-toolchain.json): the same Swift Build release
# whatever the Xcode, but running on that toolchain's Swift runtime. Its build service loads the toolchain's dependency
# scanner (lib_InternalSwiftScan) in process for explicitly built modules, and that library's Swift code needs the runtime
# it was built against: Swift 6.2.3's scanner in a Swift 6.4 process crashes (swift_release in evaluatePoundIfCondition).
# With another toolchain than the image's own: `strip --strip-debug` (a full strip breaks Foundation's Bundle lookup in
# Swift 6.2.3's runtime), and resources in `<package>_<target>.resources` (Swift 6.4's SwiftPM writes `.bundle`).
RUN set -eux; cd /src/swift-build; export SWIFTCI_USE_LOCAL_DEPS=1; \
    root="$(sed -nE 's/.*"root" *: *"([^"]*)".*/\1/p' /opt/xless/swift-toolchain.json)"; export PATH="${root%/}/usr/bin:$PATH"; \
    swift --version; \
    swift build -c release --product SWBBuildServiceBundle; \
    swift build -c release --product swbuild
RUN set -eux; cd /src/swift-build; export SWIFTCI_USE_LOCAL_DEPS=1; \
    root="$(sed -nE 's/.*"root" *: *"([^"]*)".*/\1/p' /opt/xless/swift-toolchain.json)"; export PATH="${root%/}/usr/bin:$PATH"; \
    strip=strip; [ "$root" = / ] || strip="strip --strip-debug"; \
    B="$(swift build -c release --show-bin-path)"; mkdir -p /out/swift-build; \
    for x in swbuild SWBBuildServiceBundle; do $strip -o "/out/swift-build/$x" "$B/$x"; done; \
    for r in "$B"/SwiftBuild_*.bundle "$B"/SwiftBuild_*.resources; do [ ! -e "$r" ] || cp -R "$r" /out/swift-build/; done; \
    ls -d /out/swift-build/SwiftBuild_SWBCore.*; \
    cp /src/swift-build/LICENSE.txt /out/swift-build/LICENSE.txt; \
    echo "https://github.com/swiftlang/swift-build/tree/${SWB_TAG}" > /out/swift-build/SOURCE

# The SDK's export, one architecture of it: read from here, so that no layer of the image holds a second copy.
FROM scratch AS sdk-export
ARG TARGETARCH
COPY --from=sdk ${TARGETARCH}/darwin.xtoolsdk /darwin.xtoolsdk
COPY --from=sdk toolchain-meta.json /toolchain-meta.json

FROM toolchain
# From above and from toolchain: TARGETARCH and APP_SWIFT_VERSION are what they were there.
ARG TARGETARCH
ARG APP_SWIFT_VERSION=
ARG LIBDMG_HFSPLUS_COMMIT
ARG XLESS_XCODE_BUILD
ENV XLESS_SHIM_DIR=/opt/xless/shims XLESS_WORK_ROOT=/cache/work PATH=/opt/xless/shims:$PATH
RUN --mount=type=bind,from=sdk-export,target=/tmp/sdk \
    cp /tmp/sdk/toolchain-meta.json /opt/xless/toolchain-meta.json \
 && { grep -q "\"xcodeBuild\" *: *\"$XLESS_XCODE_BUILD\"" /opt/xless/toolchain-meta.json || { echo "the SDK export is not Xcode build $XLESS_XCODE_BUILD's"; exit 1; }; } \
 && xtool sdk install /tmp/sdk/darwin.xtoolsdk \
 && test -f /opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle/toolset-swb.json \
 && chmod -R a+rX /opt/xless
# The clang resource directory of an installed toolchain (Ruling R10). The SDK bundle's Swift resource directory (the
# Xcode toolchain's usr/lib/swift: Swift's shims, the C++ interop overlays, the back-deployment libraries) is the Xcode's,
# and Swift compiles pass its `clang` link as clang's -resource-dir. Apple's clang headers belong to Apple's clang build,
# though, not to the open-source clang of the same major version: Xcode 26.2's arm_vector_types.h uses `__mfp8`, which
# Swift 6.2.3's clang 17 does not know (`could not build module '_Builtin_intrinsics'`). So that link names the toolchain's
# own clang resource directory, which gets the Xcode's Darwin runtime libraries (lib/darwin: libclang_rt.*) beside its
# headers: the compiler's headers, the Xcode's runtimes. With the image's own Swift the Xcode's directory stays.
# Its ld64.lld (LLD 17) becomes the SDK's linker: SwiftPM's Swift Build 6.2 links with `clang -fuse-ld=lld`, which runs the
# ld64.lld next to clang rather than the toolset's, so every link goes through the same ld64.lld trampoline as before.
# An open-source clang driver can lack defaults of the Apple clang its Xcode ships, in both chains. Swift 6.2.3's (the
# 26.2 pin) drops -fno-cxx-modules (a C++ #include of a module-mapped header then fails: React Native's ReactCodegen) and
# predefines no TARGET_OS_* macros (Apple clang 17 does); with -fdefine-target-os-macros it still lacks four
# (TARGET_OS_ARROW, _BRIDGE, _IOSMAC, _XR). The image's own Swift (6.4, clang 21, the default chain, compiled at root /)
# predefines 19 of them with Apple's values and lacks five (ARROW, BRIDGE, IOSMAC, KERNELKIT, XR). Whatever the Xcode's
# clang predefines and the toolchain's lacks, docker/toolchain/target-os/derived.txt defines from the ones it has. Such a
# toolchain's `clang` and `clang++` become docker/toolchain/clang-driver, which adds them to what it runs for a Darwin
# target, and only then: a Linux compile (cargo build scripts, the cc crate's host builds, script phases) gets the
# open-source driver's own behaviour, on arm64 and amd64 alike.
# The predefine flags also become the record's clangFlags (Swift Build passes them as build settings, for its in-process
# dependency scanner and Swift's Clang importer) and -Xcc options of the SDK bundle's toolsets' swiftCompiler (Swift
# compiles of SwiftPM builds for Darwin).
# Checked against the Xcode's own clang (docker/toolchain/target-os/<Xcode build>.txt, measured black-box by
# scripts/target-os-macros.sh), with no allow-list: every Darwin triple xless compiles for gets every TARGET_OS_ macro with
# Apple's value, through the driver and through the record's flags, and a Linux triple (aarch64 and x86_64) gets none,
# exactly as the open-source driver predefines.
COPY docker/toolchain /tmp/toolchain
RUN set -eux; \
    xb="$(tr -d '\n ' < /opt/xless/toolchain-meta.json | sed -nE 's/.*"xcodeBuild":"([^"]*)".*/\1/p')"; \
    fixture="/tmp/toolchain/target-os/$xb.txt"; derived=/tmp/toolchain/target-os/derived.txt; chk="sh /tmp/toolchain/target-os-check"; \
    [ -f "$fixture" ] || { echo "no docker/toolchain/target-os/$xb.txt for Xcode build '$xb': on the Mac, scripts/target-os-macros.sh <its Xcode.app> > docker/toolchain/target-os/$xb.txt"; exit 1; }; \
    if [ -n "$APP_SWIFT_VERSION" ]; then \
      sv="$APP_SWIFT_VERSION"; root="/opt/xless/toolchains/swift-$sv"; \
    else \
      sv="$(tr -d '\n ' < /opt/xless/swift-toolchain.json | sed -nE 's/.*"version":"([^"]*)".*/\1/p')"; root=/; \
      [ -n "$sv" ] || { echo "no Swift version in /opt/xless/swift-toolchain.json"; exit 1; }; \
      [ "$(tr -d '\n ' < /opt/xless/swift-toolchain.json | sed -nE 's/.*"root":"([^"]*)".*/\1/p')" = / ] || { echo "the image's own Swift is not at root /"; exit 1; }; \
    fi; \
    bin="${root%/}/usr/bin"; \
    if [ -n "$APP_SWIFT_VERSION" ]; then \
      x=/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib; \
      own="$($bin/clang -print-resource-dir)"; \
      xcode="$(readlink -f "$x/swift/clang")"; \
      for d in "$xcode"/lib/*; do [ -e "$own/lib/$(basename "$d")" ] || ln -s "$d" "$own/lib/$(basename "$d")"; done; \
      for s in swift swift_static; do [ -L "$x/$s/clang" ] && rm "$x/$s/clang"; [ ! -e "$x/$s/clang" ]; ln -s "$own" "$x/$s/clang"; \
        [ "$(readlink -f "$x/$s/clang")" = "$(readlink -f "$own")" ]; done; \
      test -f "$x/swift/clang/lib/darwin/libclang_rt.ios.a" && test -f "$x/swift/clang/include/arm_neon.h"; \
      rm "$bin/ld64.lld"; printf '#!/bin/sh\nexec %s "$@"\n' /opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/ld64.lld > "$bin/ld64.lld"; \
      chmod 755 "$bin/ld64.lld"; \
    fi; \
    real="$(readlink "$bin/clang")"; [ -x "$bin/$real" ]; \
    set -f; \
    flags=; wrap=; \
    "$bin/clang" -target arm64-apple-ios17.0 -dM -E -x c /dev/null | grep -q TARGET_OS_IOS || { flags=-fdefine-target-os-macros; wrap=1; }; \
    missing="$($chk missing "$fixture" "$bin/clang" $flags)"; \
    if [ -n "$missing" ]; then flags="$flags $($chk derive "$derived" $missing | tr '\n' ' ')"; wrap=1; fi; \
    flags="$(echo $flags)"; \
    "$bin/clang++" -### -target arm64-apple-ios17.0 -x c++ -fmodules -fno-cxx-modules -c /dev/null -o /dev/null 2>&1 | grep -qF '"-fno-cxx-modules"' || wrap=1; \
    if [ -n "$wrap" ]; then \
      for d in clang clang++; do rm "$bin/$d"; \
        python3 -c 'import sys; t = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(t.replace("@DRIVER@", sys.argv[3]).replace("@FLAGS@", sys.argv[4]))' \
          /tmp/toolchain/clang-driver "$bin/$d" "$bin/$real" "$flags"; \
        chmod 755 "$bin/$d"; done; \
      printf '%s\n' '-target arm64-apple-ios17.0 -c -x c++ -fmodules -fno-cxx-modules' > /tmp/r.resp; \
      env -i "$bin/clang++" -### @/tmp/r.resp /dev/null 2>&1 | grep -qF '"-fno-cxx-modules"'; \
      printf '%s\n' '-target aarch64-unknown-linux-gnu -c -x c++ -fmodules -fno-cxx-modules' > /tmp/r.resp; \
      [ "$(env -i "$bin/clang++" -### @/tmp/r.resp /dev/null 2>&1 | grep -cF '"-fno-cxx-modules"')" = "$(env -i "$bin/$real" --driver-mode=g++ -### @/tmp/r.resp /dev/null 2>&1 | grep -cF '"-fno-cxx-modules"')" ]; \
      $chk same "$fixture" "$bin/clang" "$bin/$real"; \
    fi; \
    $chk check "$fixture" "$bin/clang"; \
    $chk darwin "$fixture" "$bin/$real" $flags; \
    if [ -n "$flags" ]; then \
      python3 /tmp/toolchain/record-flags.py "$sv" "$root" /opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle $flags; \
    fi; \
    rm -rf /tmp/toolchain /tmp/r.resp
# Headers Apple's clang finds in its toolchain's usr/include and the open-source one does not: Swift's C++ interop
# header <swift/bridging> as a module (SwiftBridging), from the Swift toolchain that compiles app code (Ruling R10,
# /opt/xless/swift-toolchain.json; identical to its Xcode's copy, e.g. 6.2.3's to Xcode 26.2's). xless adds the directory
# to every compile with -idirafter (SwiftBuildEnvironment).
ENV XLESS_TOOLCHAIN_INCLUDE=/opt/xless/toolchain/usr/include
RUN root="$(sed -nE 's/.*"root" *: *"([^"]*)".*/\1/p' /opt/xless/swift-toolchain.json)" && [ -n "$root" ] \
 && mkdir -p "$XLESS_TOOLCHAIN_INCLUDE/swift" \
 && cp "${root%/}/usr/include/swift/bridging" "${root%/}/usr/include/swift/bridging.modulemap" "$XLESS_TOOLCHAIN_INCLUDE/swift/" \
 && echo 'extern module SwiftBridging "swift/bridging.modulemap"' > "$XLESS_TOOLCHAIN_INCLUDE/module.modulemap"
# macOS resolves #include case-insensitively: the iOS SDK ships usr/include/Endian.h, and code includes <endian.h>. Each
# header in the SDKs' usr/include whose name has capitals gets an all-lowercase symbolic link when no file has that
# name already (only the spelling changes; it is the same file, so modules and include guards see one header).
RUN set -e; for inc in /opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/*/Developer/SDKs/*.sdk/usr/include; do \
      [ -L "$(dirname "$inc")" ] || [ -L "$(dirname "$(dirname "$inc")")" ] && continue; \
      find "$inc" -name '*.h' -type f | while read -r f; do b=$(basename "$f"); l=$(printf %s "$b" | tr A-Z a-z); \
        [ "$b" = "$l" ] || [ -e "$(dirname "$f")/$l" ] || ln -s "$b" "$(dirname "$f")/$l"; done; \
    done \
 && set -- /opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9]*.sdk \
 && [ "$#" -eq 1 ] && [ -d "$1" ] && test -L "$1/usr/include/endian.h"
COPY --from=swb /out/swift-build /opt/swift-build
COPY --from=libdmg /out/dmg /out/hfsplus /usr/local/bin/
COPY --from=libdmg /out/LICENSE /usr/local/share/doc/libdmg-hfsplus/LICENSE
COPY --from=swifttools /usr/bin/llvm-objcopy /opt/xless/llvm/bin/llvm-objcopy
# swbuild is a script, not a symbolic link: Swift 6.2.3's Foundation crashes looking up bundles from a symlinked executable.
# LLVM's tools come from jammy with a version suffix. /cache is where a run's work copies and caches are mounted.
RUN printf '#!/bin/sh\nexec /opt/swift-build/swbuild "$@"\n' > /usr/local/bin/swbuild && chmod 755 /usr/local/bin/swbuild && swbuild --help >/dev/null \
 && echo "https://github.com/mozilla/libdmg-hfsplus/tree/${LIBDMG_HFSPLUS_COMMIT}" > /usr/local/share/doc/libdmg-hfsplus/SOURCE \
 && command -v mkfs.hfsplus && hfsplus 2>&1 | grep -q symlink && { dmg 2>&1 || true; } | grep -q build \
 && ln -s llvm-objcopy /opt/xless/llvm/bin/llvm-strip && /opt/xless/llvm/bin/llvm-strip --version | grep -qF 'LLVM version 21' \
 && for t in lipo otool; do test -x "/usr/bin/llvm-$t-14" && ln -sf "/usr/bin/llvm-$t-14" "/usr/local/bin/llvm-$t" || exit 1; done \
 && llvm-nm --version >/dev/null \
 && { command -v llvm-libtool-darwin || ln -s "$(ls /usr/bin/llvm-libtool-darwin-* | head -1)" /usr/local/bin/llvm-libtool-darwin; } \
 && test -x /usr/local/bin/llvm-libtool-darwin -o -x /usr/bin/llvm-libtool-darwin \
 && mkdir -p /cache && chmod 1777 /cache
# Xcode tools Swift Build and the CocoaPods / React Native build phases run (and, in prepare/, the two tools `xless
# prepare` puts first on PATH while Expo prebuild and CocoaPods run: `command` as a program, and a clang that builds
# Expo's stub dylib for iOS) (docs/research/react-native-ios-contract.md,
# "Tool shims" and "Gate G3/G4"): actool, ibtool, copypng, xcodebuild, ditto, lipo and otool on PATH in XLESS_SHIM_DIR
# (lipo/otool through the xcrun shim's map to LLVM's, which jammy installs only with a version suffix; `xcrun --find
# actool` and `xcrun actool` reach the actool shim, for CocoaPods' Copy Pods Resources phase); PlistBuddy where
# the build phases call it; xless-ld64, the linker of xless's Swift Build toolset; and in swift-build/ the tools Swift
# Build must find before the Linux toolchain's (/usr/bin): strip (LLVM 21's llvm-strip) and embeddedBinaryValidationUtility.
# actool and ibtool answer as the image's Xcode's tools (XcodeToolsProfile, from toolchain-meta.json); an Xcode without a
# profile makes them exit 70, so the version checks below fail the image build.
COPY docker/shims/ /opt/xless/shims/
COPY --from=xless-bin --chmod=755 /xless /usr/local/bin/xless
# The release that is in the image, which its labels name: the one that its Dockerfile and shims are from.
ARG XLESS_VERSION
RUN mv /opt/xless/shims/PlistBuddy /usr/libexec/PlistBuddy && chmod a+rx /opt/xless/shims/* /opt/xless/shims/swift-build/* /opt/xless/shims/prepare/* /usr/libexec/PlistBuddy \
 && { [ "$(xless --version)" = "$XLESS_VERSION" ] || { echo "this is xless $(xless --version), and the Dockerfile is xless $XLESS_VERSION's"; exit 1; }; } \
 && xcrun --sdk iphoneos --show-sdk-path \
 && actool --version --output-format xml1 | grep -qE '<string>[0-9]+</string>' \
 && [ "$(xcrun --find actool)" = /opt/xless/shims/actool ] && xcrun actool --version --output-format xml1 | grep -qE '<string>[0-9]+</string>' \
 && ibtool --version --output-format xml1 | grep -qE '<string>[0-9]+</string>' \
 && xcodebuild -version | grep -qx 'Build version [0-9A-Za-z]*' \
 && lipo -version >/dev/null && otool --version >/dev/null \
 && /usr/libexec/PlistBuddy -c 'Add :K string v' /tmp/pb.plist >/dev/null && /usr/libexec/PlistBuddy -c 'Print :K' /tmp/pb.plist | grep -qx v \
 && mkdir -p /tmp/d/src && echo x > /tmp/d/src/f && ditto /tmp/d/src /tmp/d/dst && test -f /tmp/d/dst/f \
 && /opt/xless/shims/prepare/command -v sh >/dev/null \
 && echo 'int f(void){return 0;}' | PATH=/opt/xless/shims/prepare:$PATH clang -x c - -dynamiclib -o /tmp/d/stub -install_name @rpath/S.framework/S \
 && test -s /tmp/d/stub \
 && rm -r /tmp/pb.plist /tmp/d
# What the image is for (Sources/XlessImages). An image built on it inherits them; `xless run` refuses one whose labels or
# layers are not those of the local image of the project's Xcode.
ARG TARGETARCH
ARG XLESS_XCODE
LABEL dev.xless.sdk=${XLESS_XCODE_BUILD} dev.xless.xcode=${XLESS_XCODE} dev.xless.version=${XLESS_VERSION} dev.xless.arch=${TARGETARCH}
# The image's identity (the xless commit and versions.env, scripts/docker-images.sh), which `xless prepare` folds into its
# fingerprint so a new image regenerates a work copy's native project. Last, so a new value rebuilds only this layer.
ARG XLESS_IMAGE_ID=unknown
LABEL dev.xless.image=${XLESS_IMAGE_ID}
ENV XLESS_IMAGE_ID=${XLESS_IMAGE_ID}
WORKDIR /work
