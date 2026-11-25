import Foundation

/// What `xless clean` removes: the image chain's local tags, the Docker volumes `xless docker` creates, and the cache
/// directory. Pure: it reads `docker` listings handed to it and returns what to remove, so it is testable without Docker.
public enum CleanPlan {
    /// The label docker/Dockerfile.base puts on xless-base, which xless, xless-tauri and xless-rn inherit. An image setup
    /// replaced (its tags moved to a newer build) keeps it once untagged, so `docker image prune --filter label=…` removes
    /// those, and only those.
    public static let imageLabel = "org.xless.image"

    /// The Docker volumes `xless run --docker` creates: Rust toolchains for Tauri, and the React Native
    /// caches. React Native work copies are one volume per overlay, `xless-rn-work-<overlay>-<hash>`.
    public static let volumes = ["xless-rustup", "xless-cargo", "xless-corepack", "xless-bundle",
                                 "xless-cocoapods-home", "xless-cocoapods-cache"]
    public static let volumePrefix = "xless-rn-work-"

    /// The image references to remove, from `docker image ls --format '{{.Repository}}:{{.Tag}}'`: every tag of the four
    /// local images (a pushed `<registry>/xless:…` is not local and is left alone). Untagged (`<none>`) entries are left
    /// to the label prune.
    public static func images(fromListing listing: String) -> [String] {
        var refs: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let ref = line.trimmingCharacters(in: .whitespaces)
            guard let colon = ref.lastIndex(of: ":") else { continue }
            let repo = String(ref[..<colon]), tag = String(ref[ref.index(after: colon)...])
            guard SetupPlan.images.contains(repo), tag != "<none>", !tag.isEmpty, !refs.contains(ref) else { continue }
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
