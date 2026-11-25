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

    /// The image references to remove, from `docker image ls --format '{{.Repository}}:{{.Tag}}'`: every local tag of xless's
    /// images, those of older ones too. (A pushed `<registry>/xless:…`, or a tag of another form, is not xless's.) Untagged
    /// (`<none>`) entries are left to the label prune.
    public static func images(fromListing listing: String) -> [String] {
        references(listing) { $0 == ImageName.repository || ImageName.oldRepositories.contains($0) }
    }

    /// Those that nothing uses any more, as an upgrade leaves them: the images of xless up to 0.10, and what an interrupted setup
    /// left. `labelled`: the listing of the images that have the label of the SDK they hold, which this xless's all do.
    public static func old(fromListing listing: String, labelled: String) -> [String] {
        let current = Set(references(labelled) { $0 == ImageName.repository })
        return references(listing) { $0 == ImageName.repository || ImageName.oldRepositories.contains($0) }.filter { !current.contains($0) }
    }

    /// `reference`, which was an old image with this ID when it was listed, is one now.
    public static func isStillOld(_ reference: String, id: String, now: LocalImage?) -> Bool {
        guard let now, now.id == id, images(fromListing: reference) == [reference] else { return false }
        return now.sdk == nil || !reference.hasPrefix("\(ImageName.repository):")
    }

    private static func references(_ listing: String, of isOurs: (String) -> Bool) -> [String] {
        var refs: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let ref = line.trimmingCharacters(in: .whitespaces)
            guard let colon = ref.lastIndex(of: ":") else { continue }
            let repo = String(ref[..<colon]), tag = ref[ref.index(after: colon)...]
            guard isOurs(repo), tag.wholeMatch(of: /local(-[A-Za-z0-9_.-]+)?/) != nil, !refs.contains(ref) else { continue }
            refs.append(ref)
        }
        return refs
    }

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
