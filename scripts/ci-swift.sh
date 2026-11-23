#!/bin/sh
# CI's `swift <args>` (pr.yml's swift test steps): run again, once, when swift itself was killed by a signal.
#   scripts/ci-swift.sh test [--package-path ThirdParty/AssetKit]
# Swift 6.4's swift-build crashes now and then while it plans the build, before a test runs: SIGSEGV in libdispatch's
# event loop (_dispatch_event_loop_drain on its manager thread), a toolchain bug outside this repository, seen in CI on
# 2026-11-12 (arm64) and 2026-11-23 (x86_64) and on other projects' Linux builds too. The shell then sees 128 + the
# signal. A failing or crashing test is not that: swift test reports it and exits 1, which is returned as is, never
# retried; so is a second crash. Env: CI_SWIFT (default swift) is the command, for the test.
set -u
swift=${CI_SWIFT:-swift}
rc=0
"$swift" "$@" || rc=$?
[ "$rc" -gt 128 ] || exit "$rc"
echo "::warning::$swift $* was killed by signal $((rc - 128)) (a crash of the toolchain itself, not a test failure): running it again once"
rc=0
"$swift" "$@" || rc=$?
exit "$rc"
