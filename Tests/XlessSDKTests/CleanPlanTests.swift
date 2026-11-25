import Testing
@testable import XlessSDK

private let listing = """
xless-base:local-arm64-xcode27.0-27A266a
xless-base:local
xless:local-arm64
xless:local-arm64-xcode26.2
xless:local-arm64-xcode27.0
xless:local-arm64-xcode27.0-tauri
xless:local-arm64-setup
xless-tauri:local-amd64-xcode27.0
xless-rn:local-arm64
xless-rn:<none>
xless:<none>
xless:mine
xless-rn:locally-made
registry.example.com/xless:local-arm64
registry.example.com/xless:xcode27.0-27A266a-v0.1.0
xless-other:local
xless-lintest:183
swift:6.4.0-jammy
alpine:latest
xless:local-arm64

"""

@Test func cleanTakesEveryLocalTagOfXlessAndNothingElse() {
    #expect(CleanPlan.images(fromListing: listing) == [
        "xless-base:local-arm64-xcode27.0-27A266a", "xless-base:local", "xless:local-arm64", "xless:local-arm64-xcode26.2", "xless:local-arm64-xcode27.0",
        "xless:local-arm64-xcode27.0-tauri", "xless:local-arm64-setup", "xless-tauri:local-amd64-xcode27.0", "xless-rn:local-arm64",
    ])
    #expect(CleanPlan.images(fromListing: "") == [])
}

/// The images of xless up to 0.9: by their names, or without the label that every image has now.
@Test func whatAnUpgradeLeavesIsKnown() {
    let labelled = "xless:local-arm64-xcode27.0\nxless:local-arm64-xcode27.0-tauri\nxless-rn:local-arm64\n"
    #expect(CleanPlan.old(fromListing: listing, labelled: labelled) == [
        "xless-base:local-arm64-xcode27.0-27A266a", "xless-base:local", "xless:local-arm64", "xless:local-arm64-xcode26.2", "xless:local-arm64-setup",
        "xless-tauri:local-amd64-xcode27.0", "xless-rn:local-arm64",
    ])
    #expect(CleanPlan.old(fromListing: labelled, labelled: labelled) == ["xless-rn:local-arm64"])
    #expect(CleanPlan.old(fromListing: "", labelled: "") == [])
}

@Test func cleanTakesXlessVolumesOnly() {
    let listing = "xless-rustup\nxless-cargo\nxless-rn-work-overlay-1a2b3c4d\nxless-rn-work-\nxless-corepack\nxless-bundle\n"
        + "xless-cocoapods-home\nxless-cocoapods-cache\nmy-db\nxless-rustup-backup\n"
    #expect(CleanPlan.volumes(fromListing: listing) == [
        "xless-rustup", "xless-cargo", "xless-rn-work-overlay-1a2b3c4d", "xless-corepack", "xless-bundle",
        "xless-cocoapods-home", "xless-cocoapods-cache",
    ])
}
