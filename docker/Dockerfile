# The xless image: one per xless version and architecture (xless:<version>-<arch>; docs/images.md). It holds xless's job
# and nothing of an Xcode: Swift, xless, xtool, rcodesign, stand-ins for Xcode's command-line tools, LLVM's binutils, the
# DMG tools, and what prepares an Xcode pack. No Apple file is in any layer, label or build argument, so it may be
# published. The Xcode's parts (its Darwin SDK, the Swift toolchain it maps to, Swift Build) are an Xcode pack, which
# `xless setup` prepares in a container of this image (it is a Linux host with everything installed: XLESS_XCODES=/xcodes,
# the share in /usr/local/share/xless) and which every build mounts read-only. Node, Rust, Ruby and the like are added on
# top of it: docker/tauri and docker/react-native, or a Dockerfile of the project's own.
#
# scripts/docker-images.sh builds it. What changes most often comes last, so a new xless rebuilds the last layers alone.
# SWIFT_IMAGE: versions.env's swift:<SWIFT_VERSION>-jammy@sha256:… (pinned by digest)
ARG SWIFT_IMAGE
# XLESS_FROM=prebuilt takes the xless binary from the build context xlessbin (a directory holding a file named xless;
# scripts/docker-images.sh image --xless-bin) instead of compiling it: no source checkout needed.
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
    SWIFT_DETERMINISTIC_HASHING=1
# What xless runs itself, and the libraries of the DMG tools (zlib, bz2, lzma) and of Swift Build (sqlite, ncurses), with
# the headers a pack's Swift Build is compiled against (libsqlite3-dev, libncurses-dev: scripts/pack-swift-build.sh).
# mkfs.hfsplus (hfsprogs, jammy universe) makes a DMG's empty HFS+ volume.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates zip unzip librsvg2-bin squashfs-tools cpio \
      rsync git python3 llvm hfsprogs zlib1g libbz2-1.0 liblzma5 libsqlite3-0 libncurses6 libsqlite3-dev libncurses-dev \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "$TARGETARCH" in arm64) A=aarch64; XSUM="$XTOOL_SHA256_AARCH64"; RSUM="$RCODESIGN_SHA256_AARCH64" ;; amd64) A=x86_64; XSUM="$XTOOL_SHA256_X86_64"; RSUM="$RCODESIGN_SHA256_X86_64" ;; *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
    curl -fsSL -o /tmp/xtool.AppImage "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VERSION}/xtool-${A}.AppImage"; \
    echo "${XSUM}  /tmp/xtool.AppImage" | sha256sum -c -; \
    # squashfs-tools 4.4 (jammy) dies on xtool 1.21.0's AppImage ("Data queue size is too large");
    # the AppImage runtime ships its own unsquashfs, so extract with it. --appimage-extract lands
    # in "squashfs-root" under the RUN's cwd, which is / .
    chmod +x /tmp/xtool.AppImage; /tmp/xtool.AppImage --appimage-extract >/dev/null; mv /squashfs-root /opt/xtool; ln -s /opt/xtool/AppRun /usr/local/bin/xtool; rm -f /tmp/xtool.AppImage; \
    # Its runtime makes the directories readable by root alone, and a setup runs it as the calling user.
    chmod -R a+rX /opt/xtool; \
    RC="apple-codesign-${RCODESIGN_VERSION}-${A}-unknown-linux-musl"; \
    curl -fsSL -o "/tmp/${RC}.tar.gz" "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F${RCODESIGN_VERSION}/${RC}.tar.gz"; \
    echo "${RSUM}  /tmp/${RC}.tar.gz" | sha256sum -c -; \
    tar -xzf "/tmp/${RC}.tar.gz" -C /tmp; install -m755 "$(find /tmp/${RC} -name rcodesign -type f | head -1)" /usr/local/bin/rcodesign; \
    rm -rf /tmp/${RC}*
RUN xtool --help >/dev/null && xtool --version | grep -qx "xtool ${XTOOL_VERSION}" \
 && rcodesign --version | grep -qx "apple-codesign ${RCODESIGN_VERSION}"
WORKDIR /work

FROM tools
ARG LIBDMG_HFSPLUS_COMMIT
# XLESS_NATIVE_HOME: where a native setup would install xtool and rcodesign; it installs neither here (both are on PATH in
# the pinned versions) and writes nothing there. XLESS_XCODES: the store of Xcode packs, where a pack volume is mounted (a
# volume holds one pack, /xcodes/<version>-<build>-<arch>, and, while a setup prepares it, its .partial, .old and .lock
# siblings); any user may write there, as a setup container runs as the calling user.
ENV XLESS_SHIM_DIR=/opt/xless/shims XLESS_WORK_ROOT=/cache/work PATH=/opt/xless/shims:$PATH \
    XLESS_NATIVE_HOME=/opt/xless/native XLESS_XCODES=/xcodes
COPY --from=libdmg /out/dmg /out/hfsplus /usr/local/bin/
COPY --from=libdmg /out/LICENSE /usr/local/share/doc/libdmg-hfsplus/LICENSE
COPY --from=swifttools /usr/bin/llvm-objcopy /opt/xless/llvm/bin/llvm-objcopy
# LLVM's tools come from jammy with a version suffix. /cache is where a run's work copies and caches are mounted.
RUN echo "https://github.com/mozilla/libdmg-hfsplus/tree/${LIBDMG_HFSPLUS_COMMIT}" > /usr/local/share/doc/libdmg-hfsplus/SOURCE \
 && command -v mkfs.hfsplus && hfsplus 2>&1 | grep -q symlink && { dmg 2>&1 || true; } | grep -q build \
 && ln -s llvm-objcopy /opt/xless/llvm/bin/llvm-strip && /opt/xless/llvm/bin/llvm-strip --version | grep -qF 'LLVM version 21' \
 && for t in lipo otool; do test -x "/usr/bin/llvm-$t-14" && ln -sf "/usr/bin/llvm-$t-14" "/usr/local/bin/llvm-$t" || exit 1; done \
 && llvm-nm --version >/dev/null \
 && { command -v llvm-libtool-darwin || ln -s "$(ls /usr/bin/llvm-libtool-darwin-* | head -1)" /usr/local/bin/llvm-libtool-darwin; } \
 && test -x /usr/local/bin/llvm-libtool-darwin -o -x /usr/bin/llvm-libtool-darwin \
 && mkdir -p /cache /xcodes && chmod 1777 /cache /xcodes
# Stand-ins for Xcode's tools, which Swift Build and the CocoaPods / React Native build phases run (and, in prepare/, the
# two tools `xless prepare` puts first on PATH while Expo prebuild and CocoaPods run: `command` as a program, and a clang
# that builds Expo's stub dylib for iOS) (docs/research/react-native-ios-contract.md, "Tool shims" and "Gate G3/G4"):
# actool, ibtool, copypng, xcodebuild, ditto, lipo and otool on PATH in XLESS_SHIM_DIR (lipo/otool through the xcrun
# shim's map to LLVM's, which jammy installs only with a version suffix; `xcrun --find actool` and `xcrun actool` reach
# the actool shim, for CocoaPods' Copy Pods Resources phase); PlistBuddy where the build phases call it; xless-ld64, the
# linker of xless's Swift Build toolset; and in swift-build/ the tools Swift Build must find before the Linux toolchain's
# (/usr/bin): strip (LLVM 21's llvm-strip) and embeddedBinaryValidationUtility. The shims that answer for an Xcode read
# it from the pack a build mounts (actool and ibtool answer as its tools, XcodeToolsProfile): what needs a pack is checked
# when one is prepared (scripts/pack-check.sh), the rest here.
COPY docker/shims/ /opt/xless/shims/
# The share a setup in this image reads (XLESS_SHARE): versions.env and what prepares a pack, the very files whose bytes
# the pack's recipe hashes, so a pack prepared here is current for an xless of the same release on the host and the reverse.
ENV XLESS_SHARE=/usr/local/share/xless
COPY versions.env /usr/local/share/xless/versions.env
COPY docker/toolchain /usr/local/share/xless/docker/toolchain
COPY scripts/fit-toolchain.sh scripts/pack-swift-build.sh scripts/pack-check.sh /usr/local/share/xless/scripts/
COPY --from=xless-bin --chmod=755 /xless /usr/local/bin/xless
# The release that is in the image, which its labels name: the one that its Dockerfile, shims and share are from (the
# share's VERSION, as a release's share has it).
ARG XLESS_VERSION
RUN mv /opt/xless/shims/PlistBuddy /usr/libexec/PlistBuddy && chmod a+rx /opt/xless/shims/* /opt/xless/shims/swift-build/* /opt/xless/shims/prepare/* /usr/libexec/PlistBuddy \
 && chmod -R a+rX /usr/local/share/xless && chmod a+rx /usr/local/share/xless/scripts/*.sh \
 && { [ "$(xless --version)" = "$XLESS_VERSION" ] || { echo "this is xless $(xless --version), and the Dockerfile is xless $XLESS_VERSION's"; exit 1; }; } \
 && echo "$XLESS_VERSION" > /usr/local/share/xless/VERSION \
 && lipo -version >/dev/null && otool --version >/dev/null \
 && /usr/libexec/PlistBuddy -c 'Add :K string v' /tmp/pb.plist >/dev/null && /usr/libexec/PlistBuddy -c 'Print :K' /tmp/pb.plist | grep -qx v \
 && mkdir -p /tmp/d/src && echo x > /tmp/d/src/f && ditto /tmp/d/src /tmp/d/dst && test -f /tmp/d/dst/f \
 && /opt/xless/shims/prepare/command -v sh >/dev/null \
 && rm -r /tmp/pb.plist /tmp/d
# What the image is (Sources/XlessImages): an xless release for one architecture. An image built on it inherits them.
ARG TARGETARCH
LABEL dev.xless.version=${XLESS_VERSION} dev.xless.arch=${TARGETARCH}
# The image's identity (the xless commit and versions.env, scripts/docker-images.sh), which `xless prepare` folds into its
# fingerprint so a new image regenerates a work copy's native project. Last, so a new value rebuilds only this layer.
ARG XLESS_IMAGE_ID=unknown
LABEL dev.xless.image=${XLESS_IMAGE_ID}
ENV XLESS_IMAGE_ID=${XLESS_IMAGE_ID}
WORKDIR /work
