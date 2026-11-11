include versions.env
export

.PHONY: test test-linux
test:
	swift test

test-linux:
	mkdir -p .build-linux
	docker run --rm -v "$(CURDIR)":/src -v "$(CURDIR)/.build-linux":/scratch -w /src $(SWIFT_IMAGE) \
	  bash -c 'apt-get update -qq && apt-get install -y -qq zip unzip rsync git >/dev/null && swift test --scratch-path /scratch'

XLESS_TAG = xcode$(XCODE_VERSION)-$(XCODE_BUILD)-v$(XLESS_VERSION)
BUILD_ARGS = --build-arg SWIFT_IMAGE=$(SWIFT_IMAGE) --build-arg XTOOL_VERSION=$(XTOOL_VERSION) --build-arg RCODESIGN_VERSION=$(RCODESIGN_VERSION) \
  --build-arg STATIC_SDK_URL=$(STATIC_SDK_URL) --build-arg STATIC_SDK_SHA256=$(STATIC_SDK_SHA256) \
  --build-arg XTOOL_SHA256_AARCH64=$(XTOOL_SHA256_AARCH64) --build-arg XTOOL_SHA256_X86_64=$(XTOOL_SHA256_X86_64) \
  --build-arg RCODESIGN_SHA256_AARCH64=$(RCODESIGN_SHA256_AARCH64) --build-arg RCODESIGN_SHA256_X86_64=$(RCODESIGN_SHA256_X86_64)
XCODE ?= /Applications/Xcode.app
# The local image targets build these architectures, tag their images local-<arch>$(IMAGE_SUFFIX), and take the SDK from
# $(SDK_DIR). `make images` sets the last two per Xcode (Ruling R8): IMAGE_SUFFIX=-xcode<version>-<build>, SDK_DIR=dist/sdk-xcode<version>;
# it then tags the images -xcode<version> too (scripts/build-images.sh).
ARCHS ?= arm64 amd64
IMAGE_SUFFIX ?=
SDK_DIR ?= dist/sdk

# Ruling R10: the Swift toolchain the image chain compiles app code with, for docker/Dockerfile.sdk. `make images` sets them
# from the Xcode (scripts/xcode-swift.sh and versions.env's XCODE_SWIFT_<build> map); empty: the image's own Swift.
APP_SWIFT_VERSION ?=
APP_SWIFT_URL_AARCH64 ?=
APP_SWIFT_SHA256_AARCH64 ?=
APP_SWIFT_URL_X86_64 ?=
APP_SWIFT_SHA256_X86_64 ?=
SDK_BUILD_ARGS = --build-arg APP_SWIFT_VERSION=$(APP_SWIFT_VERSION) \
  --build-arg APP_SWIFT_URL_AARCH64=$(APP_SWIFT_URL_AARCH64) --build-arg APP_SWIFT_SHA256_AARCH64=$(APP_SWIFT_SHA256_AARCH64) \
  --build-arg APP_SWIFT_URL_X86_64=$(APP_SWIFT_URL_X86_64) --build-arg APP_SWIFT_SHA256_X86_64=$(APP_SWIFT_SHA256_X86_64)

.PHONY: images
# make images [XCODE=<Xcode.app | Xcode_*.xip>] [ARCHS="arm64"]: the whole image chain (xless-base, xless, xless-tauri,
# xless-rn) from one Xcode's SDK and the Swift toolchain that Xcode ships (Ruling R10), tagged *:local-<arch>-xcode<version>
# (and the plain local-<arch> tags when it is versions.env's XCODE_VERSION/XCODE_BUILD). A project pins it with `xcode: "<version>"`; scripts/testflight.sh selects
# the images from the pin. Mac only (scripts/build-images.sh; a .xip is expanded with `xip --expand` first).
images:
	scripts/build-images.sh "$(XCODE)" $(ARCHS)

.PHONY: base-local sdk-export sdk-local base-push sdk-push
base-local:
	for a in $(ARCHS); do scripts/docker-images.sh base --arch $$a --suffix '$(IMAGE_SUFFIX)' || exit 1; done

sdk-export: base-local
	swift run xless sdk export --xcode "$(XCODE)" --out $(SDK_DIR) --base-image 'xless-base:local-{arch}$(IMAGE_SUFFIX)' --arch $(ARCHS)

sdk-local:
	for a in $(ARCHS); do scripts/docker-images.sh sdk --arch $$a --suffix '$(IMAGE_SUFFIX)' --sdk-dir '$(SDK_DIR)' --xcode-build '$(XCODE_BUILD)' || exit 1; done

base-push:
	R=$$(scripts/check-private-registry.sh) && docker buildx build --platform linux/arm64,linux/amd64 --push \
	  -t $$R/xless-base:v$(XLESS_VERSION) -f docker/Dockerfile.base $(BUILD_ARGS) .

sdk-push:
	R=$$(scripts/check-private-registry.sh) && docker buildx build --platform linux/arm64,linux/amd64 --push \
	  -t $$R/xless:$(XLESS_TAG) -f docker/Dockerfile.sdk --build-context sdk=dist/sdk --build-arg BASE=$$R/xless-base:v$(XLESS_VERSION) $(SDK_BUILD_ARGS) .

.PHONY: testflight
# make testflight PROJECT=<dir> | CONFIG=<overlay.yml> [ARGS="…"]: build, sign, upload and deliver an iOS project (or an app
# described by an overlay: Tauri, docs/tauri.md; React Native, docs/react-native.md; plain Cargo, docs/cargo.md) to TestFlight
# (see scripts/testflight.sh). A cargo overlay's path inputs are listed with the host's `xless` (XLESS_SELF, else PATH).
# ARGS go to the script, e.g. ARGS="--build-number 1.0.0.2026101601 --to finalize" (offline, no secrets) or "--from upload".
testflight:
	@test -n "$(PROJECT)$(CONFIG)" || { echo "usage: make testflight PROJECT=<dir>  or  make testflight CONFIG=<overlay.yml> [ARGS=…]" >&2; exit 2; }
	@test -z "$(PROJECT)" -o -z "$(CONFIG)" || { echo "give PROJECT or CONFIG, not both" >&2; exit 2; }
	@if test -n "$(CONFIG)"; then scripts/testflight.sh --config "$(CONFIG)" $(ARGS); else scripts/testflight.sh "$(PROJECT)" $(ARGS); fi

.PHONY: simulator sim-launch
# make simulator CONFIG=<overlay.yml> [ARGS=…]: a React Native app built for the iOS Simulator on Linux (docker), ad-hoc
# signed, no secrets (scripts/testflight.sh --destination simulator); it prints the sim-launch command for the app.
simulator:
	@test -n "$(CONFIG)" || { echo "usage: make simulator CONFIG=<overlay.yml> [ARGS=…]" >&2; exit 2; }
	scripts/testflight.sh --config "$(CONFIG)" --destination simulator $(ARGS)

# make sim-launch APP=<App.app | volume:<volume>:<path>> [ARGS="--seconds 20"]: install and launch it on this Mac's
# simulator, check it is still running, and save its console, log, screenshot and crash reports (scripts/sim-launch.sh).
sim-launch:
	@test -n "$(APP)" || { echo "usage: make sim-launch APP=<App.app | volume:<volume>:<path>> [ARGS=…]" >&2; exit 2; }
	scripts/sim-launch.sh $(ARGS) "$(APP)"

.PHONY: dmg
# make dmg CONFIG=<overlay.yml>: build, sign (Developer ID), notarize and staple a Tauri or cargo macOS app's DMG, universal
# unless a cargo overlay's macos.architectures picks one (scripts/testflight.sh --platform macos; docs/tauri.md#macos). Like testflight, a cargo overlay needs `xless` on PATH.
dmg:
	@test -n "$(CONFIG)" || { echo "usage: make dmg CONFIG=<overlay.yml>" >&2; exit 2; }
	scripts/testflight.sh --config "$(CONFIG)" --platform macos

.PHONY: test-tauri-linux
# Build samples/HelloTauri on Linux (docker) and compare it with the Mac reference (scripts/test-tauri-linux.sh).
test-tauri-linux:
	scripts/test-tauri-linux.sh

.PHONY: test-cargo-linux
# Build samples/HelloCargo for iOS and macOS on Linux (docker) and check the finalized apps (scripts/test-cargo-linux.sh).
test-cargo-linux:
	scripts/test-cargo-linux.sh

.PHONY: test-rn-linux
# Build samples/HelloRN on Linux (docker, xless-rn) from a fresh prepare and compare it with the Mac reference
# (scripts/test-rn-linux.sh).
test-rn-linux:
	scripts/test-rn-linux.sh

.PHONY: parity ib-parity
parity:
	scripts/parity.sh

ib-parity:
	scripts/ib-parity.sh

.PHONY: tauri-local
tauri-local:
	for a in $(ARCHS); do scripts/docker-images.sh tauri --arch $$a --suffix '$(IMAGE_SUFFIX)' || exit 1; done

.PHONY: tauri-reference
# make tauri-reference APP=<tauri app root> OUT=<dir> [PLATFORM=ios|macos] [TAURI_FEATURES=…]: Mac-only black-box
# reference build of a Tauri app with the real Tauri CLI and Xcode (see scripts/tauri-ios-reference.sh); PLATFORM
# defaults to ios, macos builds the universal .app and .dmg. The docker recipes live in scripts/docker-images.sh.
tauri-reference:
	@test -n "$(APP)" -a -n "$(OUT)" || { echo "usage: make tauri-reference APP=<tauri app root> OUT=<dir> [PLATFORM=ios|macos]" >&2; exit 2; }
	scripts/tauri-ios-reference.sh --platform "$(or $(PLATFORM),ios)" "$(APP)" "$(OUT)"

.PHONY: rn-reference
# make rn-reference [APP=samples/HelloRN] [OUT=<APP>/reference]: Mac-only reference build of an Expo app (pnpm install,
# expo prebuild, pod install, unsigned xcodebuild Release iphoneos; see scripts/rn-reference.sh).
rn-reference:
	scripts/rn-reference.sh "$(or $(APP),samples/HelloRN)" "$(or $(OUT),$(or $(APP),samples/HelloRN)/reference)"

.PHONY: rn-local
# make rn-local [ARCHS="arm64"]: the xless-rn image (Ruby/Bundler, Swift Build's swbuild, hermesc) on xless-tauri.
# Swift Build is compiled in the image, so an amd64 build on an arm64 host runs swift under emulation (slow, best-effort).
rn-local:
	for a in $(ARCHS); do scripts/docker-images.sh rn --arch $$a --suffix '$(IMAGE_SUFFIX)' || exit 1; done
