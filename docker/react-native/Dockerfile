# check=skip=InvalidDefaultArgInFrom
# What React Native and Expo apps need besides the xless image: Node with corepack (pnpm and yarn), Ruby and Bundler (CocoaPods
# comes from each app's Gemfile.lock at prepare time), and hermesc for the machine it runs on.
#
# `xless run --docker` builds it when it is needed, and `xless setup --docker --with react-native` ahead of that. It is an
# ordinary Dockerfile, and a start for one of your own (docs/images.md):
#   docker build --pull=false --build-arg XLESS_IMAGE=xless:local-arm64-xcode27.0 -t my-image <this folder>
# Everything downloaded is pinned by its SHA-256. The image holds Apple's SDK, as the one it is built on: never push it.
ARG XLESS_IMAGE
# Where Ruby and hermesc are compiled: the system the xless image is built on (versions.env's SWIFT_IMAGE), not that image, so a
# new xless image compiles neither again.
ARG BUILD_IMAGE=swift:6.4.0-jammy@sha256:11bb836ebbc05dbe59b28ffa6cb6ca6b452375d7a65b322c5b6c83f44d52f8c0
# Ruby from source: Bundler 2.7 needs Ruby >= 3.2 and jammy ships 3.0; 3.4.8 matches the acceptance app's .tool-versions. sha256
# from ruby-lang.org's published release list.
ARG RN_RUBY_VERSION=3.4.8
ARG RN_RUBY_SHA256=53c4ddad41fbb6189f1f5ee0db57a51d54bd1f87f8755b3d68604156a35b045b
# Bundler gem from rubygems.org; sha256 as published by the rubygems.org versions API.
ARG RN_BUNDLER_VERSION=2.7.2
ARG RN_BUNDLER_SHA256=1decaf9e2e1acb91b6586a2925c8f3f6da2334a82731a62ff2ded1b83c283871
# hermesc built from facebook/hermes for the host arch (React Native ships an x86_64-only Linux hermesc).
# Version mapping: react-native 0.86.2 -> sdks/.hermesv1version = hermes-v250829098.0.16 (Hermes V1, the default:
# hermes-utils.rb enables it unless RCT_HERMES_V1_ENABLED=0) = npm hermes-compiler 250829098.0.16 (gitHead
# 90f23852efcd361315688e2904d2446707fa274c, the tag's commit). The legacy engine (sdks/.hermesversion) is hermes-v0.17.0.
# sha256 of https://github.com/facebook/hermes/archive/refs/tags/<tag>.tar.gz computed locally (trust-on-first-use).
ARG HERMES_TAG=hermes-v250829098.0.16
ARG HERMES_SHA256=25c4180de4fb7b2a7809fa288be9288c187cbc161c5cdf2bf4ab2ec1e8afaa99

FROM ${BUILD_IMAGE} AS ruby
ARG RN_RUBY_VERSION
ARG RN_RUBY_SHA256
ARG RN_BUNDLER_VERSION
ARG RN_BUNDLER_SHA256
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates build-essential libssl-dev libyaml-dev zlib1g-dev libffi-dev \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    curl -fsSL -o /tmp/ruby.tar.gz "https://cache.ruby-lang.org/pub/ruby/${RN_RUBY_VERSION%.*}/ruby-${RN_RUBY_VERSION}.tar.gz"; \
    echo "${RN_RUBY_SHA256}  /tmp/ruby.tar.gz" | sha256sum -c -; \
    mkdir -p /src/ruby; tar -xzf /tmp/ruby.tar.gz -C /src/ruby --strip-components=1; cd /src/ruby; \
    CC=gcc ./configure --prefix=/opt/ruby --disable-install-doc; make -j"$(nproc)"; make install; \
    curl -fsSL -o "/tmp/bundler-${RN_BUNDLER_VERSION}.gem" "https://rubygems.org/downloads/bundler-${RN_BUNDLER_VERSION}.gem"; \
    echo "${RN_BUNDLER_SHA256}  /tmp/bundler-${RN_BUNDLER_VERSION}.gem" | sha256sum -c -; \
    /opt/ruby/bin/gem install --local --no-document "/tmp/bundler-${RN_BUNDLER_VERSION}.gem"; \
    /opt/ruby/bin/bundle -v | grep -qF "${RN_BUNDLER_VERSION}"

# hermesc for the host arch, the upstream Linux recipe (.github/workflows/build-hermesc-linux.yml): static, Release,
# only the hermesc target; the release version is set as upstream's Apple build does, so `-version` names the tag.
FROM ${BUILD_IMAGE} AS hermes
ARG HERMES_TAG
ARG HERMES_SHA256
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates build-essential cmake ninja-build libicu-dev \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    curl -fsSL -o /tmp/hermes.tar.gz "https://github.com/facebook/hermes/archive/refs/tags/${HERMES_TAG}.tar.gz"; \
    echo "${HERMES_SHA256}  /tmp/hermes.tar.gz" | sha256sum -c -; \
    mkdir -p /src/hermes; tar -xzf /tmp/hermes.tar.gz -C /src/hermes --strip-components=1; rm /tmp/hermes.tar.gz; \
    CC=gcc CXX=g++ cmake -S /src/hermes -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release -DHERMES_STATIC_LINK=ON \
      -DHERMES_ENABLE_TEST_SUITE=OFF -DHERMES_RELEASE_VERSION="${HERMES_TAG#hermes-v}"; \
    cmake --build /build --target hermesc -j"$(nproc)"; \
    mkdir -p /out; strip -o /out/hermesc /build/bin/hermesc; cp /src/hermes/LICENSE /out/LICENSE; \
    echo "https://github.com/facebook/hermes/tree/${HERMES_TAG}" > /out/SOURCE

FROM ${XLESS_IMAGE}
ARG TARGETARCH
ARG RN_RUBY_VERSION
ARG RN_BUNDLER_VERSION
ARG HERMES_TAG
# Node 24 LTS; sha256s from nodejs.org's SHASUMS256.txt.
ARG NODE_VERSION=24.22.0
ARG NODE_SHA256_ARM64=fef00bb4d36e1c50104a9775a10359beee98f162b4104dd12472c75065c6a143
ARG NODE_SHA256_X64=cc2f601cee82d9a5a233302fe307abc600727035fd7d2c3a3571755989e95008
# CocoaPods needs a UTF-8 locale and refuses root unless allowed (xless containers run as root). Gems (the app's
# CocoaPods and friends) install into the /cache/bundle volume.
ENV PATH=/opt/xless/shims:/opt/node/bin:$PATH:/opt/ruby/bin COREPACK_HOME=/cache/corepack LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    BUNDLE_PATH=/cache/bundle BUNDLE_SILENCE_ROOT_WARNING=1 COCOAPODS_ALLOW_ROOT=1
# The libraries Ruby was built against with their headers (native gem extensions such as ffi, json and bigdecimal link the same
# set), a C toolchain, and what CocoaPods shells out to (git, curl, unzip, xz; `file`, whose Mach-O descriptions its
# embed-frameworks script matches: "dynamically linked shared library", "dSYM companion").
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libssl-dev libyaml-dev zlib1g-dev libffi-dev \
      git curl unzip xz-utils pkg-config file \
 && rm -rf /var/lib/apt/lists/*
# /bin/sh is bash, as on macOS: Swift Build runs script phases with their shellPath /bin/sh, and React Native's phases (and the
# scripts they run with `/bin/sh -c`) use bash features such as `source`, which Ubuntu's dash lacks. This is Debian's supported
# switch (dash's debconf question), so package upgrades keep it.
RUN echo "dash dash/sh boolean false" | debconf-set-selections \
 && DEBIAN_FRONTEND=noninteractive dpkg-reconfigure dash \
 && test "$(readlink -f /bin/sh)" = /usr/bin/bash && /bin/sh -c 'source /dev/null'
RUN set -eux; \
    case "$TARGETARCH" in arm64) N=arm64; NS="$NODE_SHA256_ARM64" ;; amd64) N=x64; NS="$NODE_SHA256_X64" ;; *) echo "unsupported $TARGETARCH"; exit 1 ;; esac; \
    curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${N}.tar.xz"; \
    echo "${NS}  /tmp/node.tar.xz" | sha256sum -c -; mkdir -p /opt/node; tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; rm /tmp/node.tar.xz; \
    /opt/node/bin/corepack enable --install-directory /opt/node/bin; \
    node --version && corepack --version
COPY --from=ruby /opt/ruby /opt/ruby
COPY --from=hermes /out/hermesc /usr/local/bin/hermesc
COPY --from=hermes /out/LICENSE /out/SOURCE /usr/local/share/doc/hermes/
RUN ruby -v | grep -qF "ruby ${RN_RUBY_VERSION}" && bundle -v && hermesc -version | grep -qF "Hermes release version: ${HERMES_TAG#hermes-v}" \
 && (cd /tmp && ruby -rmkmf -e 'exit(try_link("int main(void) { return 0; }"))' && rm -f mkmf.log) \
 && echo 'print("ok")' > /tmp/smoke.js && hermesc -emit-binary -out /tmp/smoke.hbc /tmp/smoke.js && test -s /tmp/smoke.hbc \
 && rm /tmp/smoke.js /tmp/smoke.hbc \
 && echo 'int f(void){return 0;}' | PATH=/opt/xless/shims/prepare:$PATH clang -x c - -dynamiclib -o /tmp/stub -install_name @rpath/S.framework/S \
 && file /tmp/stub | grep -q 'Mach-O 64-bit.*dynamically linked shared library' && rm /tmp/stub
# `xless prepare` folds the image's identity into its fingerprint: these tools are part of it. (A Dockerfile of your own that
# changes what prepare runs does the same.)
ENV XLESS_IMAGE_ID=${XLESS_IMAGE_ID}-node${NODE_VERSION}-ruby${RN_RUBY_VERSION}-bundler${RN_BUNDLER_VERSION}-${HERMES_TAG}
WORKDIR /work
