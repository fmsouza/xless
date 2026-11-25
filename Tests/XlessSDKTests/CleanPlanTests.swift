import Testing
import XlessImages
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

/// The images of xless up to 0.10: by their names, or without the label that every image has now.
@Test func whatAnUpgradeLeavesIsKnown() {
    let labelled = "xless:local-arm64-xcode27.0\nxless:local-arm64-xcode27.0-tauri\nxless-rn:local-arm64\n"
    #expect(CleanPlan.old(fromListing: listing, labelled: labelled) == [
        "xless-base:local-arm64-xcode27.0-27A266a", "xless-base:local", "xless:local-arm64", "xless:local-arm64-xcode26.2", "xless:local-arm64-setup",
        "xless-tauri:local-amd64-xcode27.0", "xless-rn:local-arm64",
    ])
    #expect(CleanPlan.old(fromListing: labelled, labelled: labelled) == ["xless-rn:local-arm64"])
    #expect(CleanPlan.old(fromListing: "", labelled: "") == [])
}

/// Time passes between the listing and the removal.
@Test func anImageIsRemovedOnlyAsWhatItWasShown() {
    func image(_ id: String, sdk: String? = nil) -> LocalImage {
        LocalImage(name: "x", id: id, architecture: "arm64", labels: sdk.map { [ImageLabel.sdk: $0] } ?? [:], layers: [])
    }
    #expect(CleanPlan.isStillOld("xless:local-arm64", id: "sha256:1", now: image("sha256:1")))
    #expect(!CleanPlan.isStillOld("xless:local-arm64", id: "sha256:1", now: image("sha256:2")))
    #expect(!CleanPlan.isStillOld("xless:local-arm64", id: "sha256:1", now: image("sha256:1", sdk: "27A266a")))
    #expect(!CleanPlan.isStillOld("xless:local-arm64", id: "sha256:1", now: nil))
    #expect(CleanPlan.isStillOld("xless-rn:local-arm64", id: "sha256:1", now: image("sha256:1", sdk: "27A266a")), "no xless of now uses it")
    for other in ["postgres:16", "xless:mine", "registry.example.com/xless:local-arm64", "xless"] { #expect(!CleanPlan.isStillOld(other, id: "sha256:1", now: image("sha256:1")), "\(other)") }
}

/// An image of a person's own inherits the label, and says otherwise where it is not xless's to remove (docs/images.md).
@Test func theUntaggedOnesAreXlesssOwn() {
    #expect(CleanPlan.imageLabel == "\(ImageLabel.image)=true")
}

@Test func cleanTakesXlessVolumesOnly() {
    let listing = "xless-rustup\nxless-cargo\nxless-rn-work-overlay-1a2b3c4d\nxless-rn-work-\nxless-corepack\nxless-bundle\n"
        + "xless-cocoapods-home\nxless-cocoapods-cache\nmy-db\nxless-rustup-backup\n"
    #expect(CleanPlan.volumes(fromListing: listing) == [
        "xless-rustup", "xless-cargo", "xless-rn-work-overlay-1a2b3c4d", "xless-corepack", "xless-bundle",
        "xless-cocoapods-home", "xless-cocoapods-cache",
    ])
}
