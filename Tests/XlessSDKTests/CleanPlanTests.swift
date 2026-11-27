import Testing
import XlessImages
@testable import XlessSDK

private let listing = """
xless-base:local-arm64-xcode27.0-27A266a
xless-base:local
xless:local-arm64
xless:local-arm64-xcode26.2
xless:local-arm64-xcode27.0-tauri
xless:local-arm64-setup
xless:0.13.0-arm64
xless:0.13.0-arm64-react-native
xless:0.14.0-arm64
xless:0.14.0-arm64-tauri
xless:0.14.0-amd64-react-native
xless:0.15.0-rc.1-arm64
xless:0123456789ab-arm64
xless:0123456789ab-dirty-arm64-tauri
xless-tauri:local-amd64-xcode27.0
xless-rn:local-arm64
xless-rn:<none>
xless:<none>
xless:mine
xless:1
xless:0.14.0
xless:0.14.0-s390x
xless:0.14.0-arm64-other
xless:latest-arm64
xless-rn:locally-made
ghcr.io/x/xless:0.14.0-arm64
ghcr.io/x/xless:1
me/xless:local-arm64
localhost:5000/xless:0.13.0-arm64
registry.example.com/xless:local-arm64
xless-other:local
xless-lintest:183
swift:6.4.0-jammy
alpine:latest
xless:local-arm64

"""

private let legacyTags = [
    "xless-base:local-arm64-xcode27.0-27A266a", "xless-base:local", "xless:local-arm64", "xless:local-arm64-xcode26.2",
    "xless:local-arm64-xcode27.0-tauri", "xless:local-arm64-setup", "xless-tauri:local-amd64-xcode27.0", "xless-rn:local-arm64",
]
private let versioned = [
    "xless:0.13.0-arm64", "xless:0.13.0-arm64-react-native", "xless:0.14.0-arm64", "xless:0.14.0-arm64-tauri", "xless:0.14.0-amd64-react-native",
    "xless:0.15.0-rc.1-arm64", "xless:0123456789ab-arm64", "xless:0123456789ab-dirty-arm64-tauri",
]

@Test func imagesIncludeVersionedAndLegacyTags() {
    #expect(Set(CleanPlan.images(fromListing: listing)) == Set(legacyTags + versioned))
    #expect(CleanPlan.images(fromListing: listing).count == legacyTags.count + versioned.count, "each once")
    #expect(CleanPlan.images(fromListing: "") == [])
}

/// A person's own tag, one with a registry or a namespace, a tag that is no form of xless's, `<none>`: never listed (nor removed).
@Test func aPersonsOwnTagIsLeftAlone() {
    let theirs = ["xless:mine", "xless:1", "xless:0.14.0", "xless:0.14.0-s390x", "xless:0.14.0-arm64-other", "xless:latest-arm64", "xless:<none>", "xless-rn:<none>",
                  "xless-rn:locally-made", "ghcr.io/x/xless:0.14.0-arm64", "ghcr.io/x/xless:1", "me/xless:local-arm64", "localhost:5000/xless:0.13.0-arm64",
                  "registry.example.com/xless:local-arm64", "xless-other:local", "xless-lintest:183", "swift:6.4.0-jammy", "alpine:latest", "xless-base:mine",
                  "xless:0123456789a-arm64", "xless:0123456789abc-arm64", "xless:0123456789AB-arm64", "xless", ""]
    let mine = Set(CleanPlan.images(fromListing: listing))
    for t in theirs { #expect(!CleanPlan.isXlessImage(t), "\(t)"); #expect(!mine.contains(t), "\(t)") }
    for t in theirs { #expect(!CleanPlan.old(fromListing: t, version: "0.14.0").contains(t), "\(t) under --old") }
}

/// What an upgrade leaves: the legacy tags, and the images of another xless than this one's, with their kits; never this one's.
@Test func oldIsLegacyAndOtherVersions() {
    #expect(CleanPlan.old(fromListing: "xless:0.13.0-arm64\nxless:0.14.0-arm64\n", version: "0.14.0") == ["xless:0.13.0-arm64"])
    #expect(CleanPlan.old(fromListing: "xless:0.14.0-arm64-tauri\nxless:0.14.0-amd64-react-native\nxless:0.14.0-arm64\n", version: "0.14.0") == [])
    #expect(Set(CleanPlan.old(fromListing: listing, version: "0.14.0")) == Set(legacyTags + [
        "xless:0.13.0-arm64", "xless:0.13.0-arm64-react-native", "xless:0.15.0-rc.1-arm64", "xless:0123456789ab-arm64", "xless:0123456789ab-dirty-arm64-tauri",
    ]))
    #expect(CleanPlan.old(fromListing: "", version: "0.14.0") == [])
}

/// In a checkout the tag is a commit: every earlier commit is another version, the current one (clean or dirty) and its kits are kept.
@Test func theCurrentCommitAndItsKitsAreKeptAlsoWhenDirty() {
    let l = "xless:0123456789ab-arm64\nxless:0123456789ab-arm64-tauri\nxless:0123456789ab-dirty-arm64\nxless:0123456789ab-dirty-arm64-react-native\n"
        + "xless:fedcba987654-arm64\nxless:fedcba987654-dirty-arm64-tauri\n"
    #expect(CleanPlan.old(fromListing: l, version: "0123456789ab-dirty") == [
        "xless:0123456789ab-arm64", "xless:0123456789ab-arm64-tauri", "xless:fedcba987654-arm64", "xless:fedcba987654-dirty-arm64-tauri",
    ])
    #expect(CleanPlan.old(fromListing: l, version: "0123456789ab") == [
        "xless:0123456789ab-dirty-arm64", "xless:0123456789ab-dirty-arm64-react-native", "xless:fedcba987654-arm64", "xless:fedcba987654-dirty-arm64-tauri",
    ])
}

@Test func theVersionOfATag() {
    #expect(CleanPlan.version(ofTag: "0.14.0-arm64") == "0.14.0")
    #expect(CleanPlan.version(ofTag: "0.14.0-amd64-react-native") == "0.14.0")
    #expect(CleanPlan.version(ofTag: "0.0.0-dev-arm64-tauri") == "0.0.0-dev")
    #expect(CleanPlan.version(ofTag: "0123456789ab-dirty-arm64") == "0123456789ab-dirty")
    #expect(CleanPlan.version(ofTag: "local-arm64") == nil)
}

/// Time passes between the listing and the removal.
@Test func anImageIsRemovedOnlyAsWhatItWasShown() {
    func image(_ id: String) -> LocalImage { LocalImage(name: "x", id: id, architecture: "arm64", labels: [:], layers: []) }
    #expect(CleanPlan.isStillOld("xless:local-arm64", id: "sha256:1", now: image("sha256:1"), version: "0.14.0"))
    #expect(!CleanPlan.isStillOld("xless:local-arm64", id: "sha256:1", now: image("sha256:2"), version: "0.14.0"))
    #expect(!CleanPlan.isStillOld("xless:0.14.0-arm64", id: "sha256:1", now: image("sha256:1"), version: "0.14.0"), "an image of this xless")
    #expect(!CleanPlan.isStillOld("xless:0.14.0-arm64-tauri", id: "sha256:1", now: image("sha256:1"), version: "0.14.0"), "a kit of this xless")
    #expect(CleanPlan.isStillOld("xless:0.13.0-arm64", id: "sha256:1", now: image("sha256:1"), version: "0.14.0"))
    #expect(!CleanPlan.isStillOld("xless:0.13.0-arm64", id: "sha256:1", now: image("sha256:1"), version: nil), "this xless is not known: legacy only")
    #expect(!CleanPlan.isStillOld("xless:local-arm64", id: "sha256:1", now: nil, version: "0.14.0"))
    #expect(CleanPlan.isStillOld("xless-rn:local-arm64", id: "sha256:1", now: image("sha256:1"), version: "0.14.0"), "no xless of now uses it")
    for other in ["postgres:16", "xless:mine", "xless:1", "ghcr.io/x/xless:0.13.0-arm64", "registry.example.com/xless:local-arm64", "xless"] {
        #expect(!CleanPlan.isStillOld(other, id: "sha256:1", now: image("sha256:1"), version: "0.14.0"), "\(other)")
    }
}

private let volumeListing = """
xless-xcode-26.2-17C52-arm64
xless-xcode-27.0-27A266a-arm64
xless-xcode-26.2.1-17C53-amd64
xless-xcode-backup
xless-xcode-
xless-xcode-26.2-17C52
xless-xcode-26.2-17C52-s390x
xless-xcode-26.2-17C52-arm64-old
xless-xcode-26.2-17-C52-arm64
xless-xcode-x.y-17C52-arm64
xless-xcode-26.2--arm64
my-xless-xcode-26.2-17C52-arm64
xless-cargo
pgdata
xless-xcode-26.2-17C52-arm64

"""

@Test func packVolumesByPrefix() {
    #expect(CleanPlan.packVolumes(fromListing: volumeListing) == ["xless-xcode-26.2-17C52-arm64", "xless-xcode-27.0-27A266a-arm64", "xless-xcode-26.2.1-17C53-amd64"])
    let packs = CleanPlan.packs(fromListing: volumeListing)
    #expect(packs.first?.summary == "Xcode 26.2 (17C52, arm64)" && packs.count == 3)
    #expect(packs.map(\.name).allSatisfy { $0.hasPrefix(PackVolumes.prefix) })
    #expect(CleanPlan.packVolumes(fromListing: "") == [])
}

/// A volume with a similar name is not a pack's, and the work volumes are not packs.
@Test func similarVolumesAreNotPacks() {
    for name in ["xless-xcode-backup", "xless-xcode-", "xless-xcode-26.2-17C52", "xless-xcode-26.2-17C52-arm64-old", "xless-cargo", "xless-rn-work-ov-12345678"] {
        #expect(CleanPlan.packVolumes(fromListing: name) == [], "\(name)")
    }
    #expect(CleanPlan.volumes(fromListing: volumeListing) == ["xless-cargo"], "the work volumes do not include a pack, nor xless-xcode-backup")
}

/// Nothing --old names is a pack: no pack volume, whatever the listings hold, and nothing of the store.
@Test func oldNeverNamesAPack() {
    let all = volumeListing + listing
    #expect(CleanPlan.old(fromListing: all, version: "0.14.0").allSatisfy { CleanPlan.isXlessImage($0) && !$0.contains(PackVolumes.prefix) })
    #expect(CleanPlan.old(fromListing: volumeListing, version: "0.14.0") == [])
    #expect(CleanPlan.legacy(fromListing: volumeListing) == [])
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
