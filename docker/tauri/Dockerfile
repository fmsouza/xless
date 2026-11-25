# check=skip=InvalidDefaultArgInFrom
# What Tauri and Cargo apps need besides the xless image: Node with corepack (pnpm and yarn), and Rust's installer. The
# toolchain itself is the project's (its rust-toolchain.toml), installed at build time into the volume at /cache/rustup.
#
# `xless run --docker` builds it when it is needed, and `xless setup --docker --with tauri` ahead of that. It is an ordinary
# Dockerfile, and a start for one of your own (docs/images.md):
#   docker build --pull=false --build-arg XLESS_IMAGE=xless:local-arm64-xcode27.0 -t my-image <this folder>
# Everything downloaded is pinned by its SHA-256. The image holds Apple's SDK, as the one it is built on: never push it.
ARG XLESS_IMAGE
FROM ${XLESS_IMAGE}
ARG TARGETARCH
# Node 24 LTS; sha256s from nodejs.org's SHASUMS256.txt.
ARG NODE_VERSION=24.22.0
ARG NODE_SHA256_ARM64=fef00bb4d36e1c50104a9775a10359beee98f162b4104dd12472c75065c6a143
ARG NODE_SHA256_X64=cc2f601cee82d9a5a233302fe307abc600727035fd7d2c3a3571755989e95008
# rustup; sha256s from static.rust-lang.org's rustup-init.sha256.
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_SHA256_AARCH64=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c
ARG RUSTUP_SHA256_X86_64=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
ENV RUSTUP_HOME=/cache/rustup CARGO_HOME=/cache/cargo COREPACK_HOME=/cache/corepack \
    PATH=/opt/xless/shims:/cache/cargo/bin:/opt/node/bin:$PATH
RUN apt-get update \
 && apt-get install -y --no-install-recommends xz-utils pkg-config python3-pil \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "$TARGETARCH" in arm64) N=arm64; NS="$NODE_SHA256_ARM64" ;; amd64) N=x64; NS="$NODE_SHA256_X64" ;; *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
    curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${N}.tar.xz"; \
    echo "${NS}  /tmp/node.tar.xz" | sha256sum -c -; mkdir -p /opt/node; tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; rm /tmp/node.tar.xz; \
    /opt/node/bin/corepack enable --install-directory /opt/node/bin; \
    node --version && corepack --version
RUN set -eux; \
    case "$TARGETARCH" in arm64) R=aarch64-unknown-linux-gnu; RS="$RUSTUP_SHA256_AARCH64" ;; amd64) R=x86_64-unknown-linux-gnu; RS="$RUSTUP_SHA256_X86_64" ;; *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
    curl -fsSL -o /usr/local/bin/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${R}/rustup-init"; \
    echo "${RS}  /usr/local/bin/rustup-init" | sha256sum -c -; chmod +x /usr/local/bin/rustup-init; rustup-init --version
WORKDIR /work
