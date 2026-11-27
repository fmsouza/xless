import Foundation
import XlessImages

/// What `xless clean` removes: the local tags of xless's images, the Docker volumes `xless run --docker` creates, and the cache
/// directory. Pure: it reads `docker` listings handed to it and returns what to remove, so it is testable without Docker.
public enum CleanPlan {
    /// The label of xless's images. An image setup replaced (its tag moved to a newer build) keeps it once untagged, so
    /// `docker image prune --filter label=…` removes those. An image of a person's own inherits it; one that gives it another value
    /// is never removed.
    public static let imageLabel = "\(ImageLabel.image)=true"

    /// The Docker volumes `xless run --docker` creates: Rust toolchains for Tauri, and the React Native
    /// caches. React Native work copies are one volume per overlay, `xless-rn-work-<overlay>-<hash>`.
    public static let volumes = ["xless-rustup", "xless-cargo", "xless-corepack", "xless-bundle",
                                 "xless-cocoapods-home", "xless-cocoapods-cache"]
    public static let volumePrefix = "xless-rn-work-"

    /// The two forms of an xless image's tag besides the legacy one: `<tag>-<arch>` and `<tag>-<arch>-<kit>`, where `<tag>` is a
    /// release (`X.Y.Z`: what scripts/next-version.sh makes; `0.0.0-dev`, a source build's) or a checkout's commit (`ImageName.checkoutTag`: 12 hex,
    /// and `-dirty`). A tag with another word in it (`2.0.0-mine`, `0.14.0-xcode26.2`) is a person's.
    /// Anything else in the `xless` repository (`xless:mine`, `xless:1`) is a person's own.
    static var tagVersion: Regex<(Substring, Substring?)> { /[0-9]+\.[0-9]+\.[0-9]+|0\.0\.0-dev|[0-9a-f]{12}(-dirty)?/ }

    /// The `<tag>` of an image of this layout's tag (`0.14.0` of `0.14.0-arm64-tauri`), or nil for any other tag.
    public static func version(ofTag tag: String) -> String? {
        var rest = Substring(tag)
        for kit in Kit.allCases where rest.hasSuffix("-\(kit.rawValue)") { rest = rest.dropLast(kit.rawValue.count + 1); break }
        for arch in ["arm64", "amd64"] where rest.hasSuffix("-\(arch)") {
            let version = rest.dropLast(arch.count + 1)
            return version.wholeMatch(of: tagVersion) != nil ? String(version) : nil
        }
        return nil
    }

    private static func split(_ reference: String) -> (repository: String, tag: String)? {
        guard let colon = reference.lastIndex(of: ":") else { return nil }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }

    /// `reference` is an image xless made: of the `xless` repository, with a tag of this layout (`version(ofTag:)`) or a legacy one; or of
    /// one of the old repositories, with a legacy tag. Nothing else: not a person's own tag in `xless`, not one with a registry or a
    /// namespace in front, not `<none>`.
    public static func isXlessImage(_ reference: String) -> Bool {
        guard let (repository, tag) = split(reference) else { return false }
        let legacy = tag.wholeMatch(of: ImageName.legacyTag) != nil
        if ImageName.oldRepositories.contains(repository) { return legacy }
        return repository == ImageName.repository && (legacy || version(ofTag: tag) != nil)
    }

    /// `reference` is an image of an older xless (a legacy tag), which nothing uses any more.
    public static func isLegacyImage(_ reference: String) -> Bool { isXlessImage(reference) && split(reference).map { $0.tag.wholeMatch(of: ImageName.legacyTag) != nil } == true }

    /// A checkout's tag without its `-dirty`: the commit. The image of this commit is this xless's, clean or not.
    private static func core(_ version: String) -> String {
        guard version.hasSuffix("-dirty") else { return version }
        let commit = String(version.dropLast("-dirty".count))
        return commit.wholeMatch(of: /[0-9a-f]{12}/) != nil ? commit : version
    }

    /// `reference` is an image of this layout made by another xless than the one whose tag is `version`.
    public static func isOtherVersion(_ reference: String, than version: String) -> Bool {
        guard isXlessImage(reference), let tag = split(reference)?.tag, let found = Self.version(ofTag: tag) else { return false }
        return core(found) != core(version)
    }

    /// The image references to remove, from `docker image ls --format '{{.Repository}}:{{.Tag}}'`: every local tag of xless's
    /// images (`isXlessImage`): of every xless version, and the legacy ones. Untagged (`<none>`) entries are left to the label prune.
    public static func images(fromListing listing: String) -> [String] { references(listing, where: isXlessImage) }

    /// The legacy ones alone.
    public static func legacy(fromListing listing: String) -> [String] { references(listing, where: isLegacyImage) }

    /// What nothing uses any more: the legacy tags, and the images and kits of another xless than the one whose tag is `version`
    /// (`ImageName.cachedTag`). Never the image of that one, nor its kits (of a checkout's commit: clean or `-dirty`), nor a pack.
    public static func old(fromListing listing: String, version: String) -> [String] {
        references(listing) { isLegacyImage($0) || isOtherVersion($0, than: version) }
    }

    /// `reference`, which was an old image with this ID when it was listed, is one now. `version`: the tag of this xless (nil when it
    /// is not known: then only the legacy ones are old).
    public static func isStillOld(_ reference: String, id: String, now: LocalImage?, version: String?) -> Bool {
        guard let now, now.id == id, images(fromListing: reference) == [reference] else { return false }
        return isLegacyImage(reference) || version.map { isOtherVersion(reference, than: $0) } == true
    }

    private static func references(_ listing: String, where isOurs: (String) -> Bool) -> [String] {
        var refs: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let ref = line.trimmingCharacters(in: .whitespaces)
            guard isOurs(ref), !refs.contains(ref) else { continue }
            refs.append(ref)
        }
        return refs
    }

    /// An Xcode pack's volume: `PackVolumes.prefix`, then `<version>-<build>-<arch>` in the shape xless creates.
    public struct PackVolume: Equatable, Sendable {
        public let name: String
        public let xcode: String, build: String, arch: String

        /// "Xcode 26.2 (17C52, arm64)".
        public var summary: String { "Xcode \(xcode) (\(build), \(arch))" }
    }

    /// The pack volumes of a `docker volume ls --format '{{.Name}}'` listing, each once. A name that only starts like one
    /// (`xless-xcode-backup`, `xless-xcode-26.2-17C52-arm64-old`) is not.
    public static func packs(fromListing listing: String) -> [PackVolume] {
        var found: [PackVolume] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(PackVolumes.prefix),
                  let m = String(name.dropFirst(PackVolumes.prefix.count)).wholeMatch(of: /([0-9]+(?:\.[0-9]+)*)-([A-Za-z0-9]+)-(arm64|amd64)/),
                  !found.contains(where: { $0.name == name }) else { continue }
            found.append(PackVolume(name: name, xcode: String(m.1), build: String(m.2), arch: String(m.3)))
        }
        return found
    }

    /// The names of those.
    public static func packVolumes(fromListing listing: String) -> [String] { packs(fromListing: listing).map(\.name) }

    /// The volumes to remove, from `docker volume ls --format '{{.Name}}'`.
    public static func volumes(fromListing listing: String) -> [String] {
        var names: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard volumes.contains(name) || (name.hasPrefix(volumePrefix) && name.count > volumePrefix.count),
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }
}
