include versions.env
export

.PHONY: test test-linux
test:
	swift test

test-linux:
	mkdir -p .build-linux
	docker run --rm -v "$(CURDIR)":/src -v "$(CURDIR)/.build-linux":/scratch -w /src $(SWIFT_IMAGE) \
	  bash -c 'apt-get update -qq && apt-get install -y -qq zip unzip rsync git >/dev/null && swift test --scratch-path /scratch'

XCODE ?= /Applications/Xcode.app
# The image targets build these architectures. `make sdk-export` exports the SDK to $(SDK_DIR).
ARCHS ?= arm64 amd64
SDK_DIR ?= dist/sdk

.PHONY: images
# make images [ARCHS="arm64"]: the xless image of this checkout, xless:<short commit>[-dirty]-<arch> (scripts/build-images.sh).
# It holds no Xcode: an Xcode is an Xcode pack, which `xless setup` prepares. Nothing here pushes an image.
images:
	scripts/build-images.sh $(ARCHS)

.PHONY: test-image
# make test-image [ARCHS="arm64"]: what the xless image of this checkout holds (Tests/shell/image-contents.test.sh), for each
# architecture whose image is here.
test-image:
	for a in $(ARCHS); do XLESS_IMAGE_ARCH=$$a bash Tests/shell/image-contents.test.sh || exit 1; done

.PHONY: sdk-export
sdk-export:
	swift run xless sdk export --xcode "$(XCODE)" --out $(SDK_DIR) --arch $(ARCHS)

# This checkout's xless (XLESS_SELF, else the one `swift run` builds), with this checkout's Dockerfiles.
XLESS_HERE = XLESS_SHARE="$(CURDIR)" $(or $(XLESS_SELF),swift run xless)

.PHONY: kits
# make kits [KITS=tauri,react-native] [ARCHS="arm64"]: what Tauri, Cargo, React Native and Expo apps need, on the newest Xcode's
# image (docker/tauri, docker/react-native). `xless run` builds the one it needs by itself.
KITS ?= tauri,react-native
kits:
	$(XLESS_HERE) setup --docker --with $(KITS) --arch $(ARCHS)

# `xless run` of this machine's xless (XLESS_SELF, else PATH), as scripts/testflight.sh has it: in the images, unless an SDK is
# installed natively (XLESS_USE_DOCKER=1 or 0 decides).
XLESS_RUN = XLESS_RUN_AS_SCRIPT=1 "$${XLESS_SELF:-xless}" run

.PHONY: testflight
# make testflight PROJECT=<dir> | CONFIG=<overlay.yml> [ARGS="…"]: build, sign, upload and deliver an iOS project (or an app
# described by an overlay: Tauri, docs/tauri.md; React Native, docs/react-native.md; plain Cargo, docs/cargo.md) to TestFlight
# (docs/signing-and-testflight.md). ARGS go to xless run, e.g. ARGS="--build-number 1.0.0.2026101601 --to finalize" (offline, no secrets) or "--from upload".
testflight:
	@test -n "$(PROJECT)$(CONFIG)" || { echo "usage: make testflight PROJECT=<dir>  or  make testflight CONFIG=<overlay.yml> [ARGS=…]" >&2; exit 2; }
	@test -z "$(PROJECT)" -o -z "$(CONFIG)" || { echo "give PROJECT or CONFIG, not both" >&2; exit 2; }
	@if test -n "$(CONFIG)"; then $(XLESS_RUN) --config "$(CONFIG)" $(ARGS); else $(XLESS_RUN) "$(PROJECT)" $(ARGS); fi

.PHONY: simulator sim-launch
# make simulator CONFIG=<overlay.yml> [ARGS=…]: a React Native app built for the iOS Simulator in Docker, ad-hoc
# signed, no secrets (xless run --destination simulator); it prints the sim-launch command for the app.
simulator:
	@test -n "$(CONFIG)" || { echo "usage: make simulator CONFIG=<overlay.yml> [ARGS=…]" >&2; exit 2; }
	$(XLESS_RUN) --config "$(CONFIG)" --destination simulator $(ARGS)

# make sim-launch APP=<App.app | volume:<volume>:<path>> [ARGS="--seconds 20"]: install and launch it on this Mac's
# simulator, check it is still running, and save its console, log, screenshot and crash reports (scripts/sim-launch.sh).
sim-launch:
	@test -n "$(APP)" || { echo "usage: make sim-launch APP=<App.app | volume:<volume>:<path>> [ARGS=…]" >&2; exit 2; }
	scripts/sim-launch.sh $(ARGS) "$(APP)"

.PHONY: dmg
# make dmg CONFIG=<overlay.yml>: build, sign (Developer ID), notarize and staple a Tauri or cargo macOS app's DMG, universal
# unless a cargo overlay's macos.architectures picks one (xless run --platform macos; docs/tauri.md#macos).
dmg:
	@test -n "$(CONFIG)" || { echo "usage: make dmg CONFIG=<overlay.yml>" >&2; exit 2; }
	$(XLESS_RUN) --config "$(CONFIG)" --platform macos

.PHONY: test-tauri-linux
# Build samples/HelloTauri on Linux (docker) and compare it with the Mac reference (scripts/test-tauri-linux.sh).
test-tauri-linux:
	scripts/test-tauri-linux.sh

.PHONY: test-cargo-linux
# Build samples/HelloCargo for iOS and macOS on Linux (docker) and check the finalized apps (scripts/test-cargo-linux.sh).
test-cargo-linux:
	scripts/test-cargo-linux.sh

.PHONY: test-rn-linux
# Build samples/HelloRN on Linux (docker) from a fresh prepare and compare it with the Mac reference
# (scripts/test-rn-linux.sh).
test-rn-linux:
	scripts/test-rn-linux.sh

.PHONY: parity ib-parity
parity:
	scripts/parity.sh

ib-parity:
	scripts/ib-parity.sh

.PHONY: tauri-reference
# make tauri-reference APP=<tauri app root> OUT=<dir> [PLATFORM=ios|macos] [TAURI_FEATURES=…]: Mac-only black-box
# reference build of a Tauri app with the real Tauri CLI and Xcode (see scripts/tauri-ios-reference.sh); PLATFORM
# defaults to ios, macos builds the universal .app and .dmg.
tauri-reference:
	@test -n "$(APP)" -a -n "$(OUT)" || { echo "usage: make tauri-reference APP=<tauri app root> OUT=<dir> [PLATFORM=ios|macos]" >&2; exit 2; }
	scripts/tauri-ios-reference.sh --platform "$(or $(PLATFORM),ios)" "$(APP)" "$(OUT)"

.PHONY: rn-reference
# make rn-reference [APP=samples/HelloRN] [OUT=<APP>/reference]: Mac-only reference build of an Expo app (pnpm install,
# expo prebuild, pod install, unsigned xcodebuild Release iphoneos; see scripts/rn-reference.sh).
rn-reference:
	scripts/rn-reference.sh "$(or $(APP),samples/HelloRN)" "$(or $(OUT),$(or $(APP),samples/HelloRN)/reference)"
