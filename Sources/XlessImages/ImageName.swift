import Foundation
import XlessCore

/// The names of the Docker images of xless: one image per xless and architecture, `xless:<version>-<arch>`, with no Xcode in it
/// (the Xcode is a pack, mounted in a container of it). The images of the kits (`Kit`) are named after the one they are built on.
public enum ImageName {
    public static let repository = "xless"

    /// The images of xless up to 0.10: one Xcode's SDK, Tauri's and React Native's toolchains, each an image of its own.
    public static let oldRepositories = ["xless-base", "xless-tauri", "xless-rn"]

    /// Every tag of the old layouts (`xless:local-arm64-xcode26.6`, `xless:local-arm64-setup`, …): an older xless's.
    public static var legacyTag: Regex<(Substring, Substring?)> { /local(-[A-Za-z0-9_.-]+)?/ }

    /// `tag` names this xless: its release version, or a checkout's commit (`tag(ofShare:)`).
    public static func base(version tag: String, arch: String) -> String { "\(repository):\(tag)-\(arch)" }

    /// `name` is an image that an older xless made: it is not used, and `xless clean --old` removes it.
    public static func isLegacy(_ name: String) -> Bool {
        guard let colon = name.lastIndex(of: ":") else { return false }
        let repository = String(name[..<colon]), tag = String(name[name.index(after: colon)...])
        return oldRepositories.contains(repository) || repository == Self.repository && tag.wholeMatch(of: legacyTag) != nil
    }

    /// `text` can be the name of an image. It starts with a letter or a digit, so docker never takes it for an option.
    public static func isReference(_ text: String) -> Bool { text.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._\/:@+\-]*/) != nil }

    // MARK: - The tag of this xless

    /// Runs git in `directory`: its exit code, and what it printed.
    public typealias Git = (_ arguments: [String], _ directory: URL) -> (code: Int32, output: String)

    /// A checkout's tag: its commit (12 hex), and `-dirty` when what is tracked has changes.
    public static func checkoutTag(commit: String, dirty: Bool) -> String { dirty ? "\(commit)-dirty" : commit }

    /// The part of the tag that names the xless of `share` (its share directory), as scripts/docker-images.sh decides it: the
    /// commit of the checkout that `share` is the top of, else the release (its VERSION file's, else versions.env's).
    public static func tag(ofShare share: URL, git: Git = ImageName.runGit) throws -> String {
        let root = share.resolvingSymlinksInPath()
        let top = git(["rev-parse", "--show-toplevel"], root)
        if top.code == 0,
           URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path == root.path {
            let commit = git(["rev-parse", "--short=12", "HEAD"], root)
            let id = commit.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if commit.code == 0, !id.isEmpty { return checkoutTag(commit: id, dirty: git(["diff", "--quiet", "HEAD"], root).code != 0) }
        }
        guard let release = XlessShare.release(of: share) else {
            throw ImageProblem("xless's share directory \(share.path) records no release (no VERSION file, no XLESS_VERSION in versions.env), so the image of this xless has no name",
                               fix: "install xless again, or set XLESS_SHARE to its share directory")
        }
        return release
    }

    /// Thin: git, as the person has it, started as every tool is. Where it is not there, or fails, the share is no checkout.
    public static func runGit(_ arguments: [String], in directory: URL) -> (code: Int32, output: String) {
        do { return (0, try Shell.run("git", ["-C", directory.path] + arguments, stage: .sdk).stdout) } catch { return (1, "") }
    }
}

/// The labels of the images, which docker/Dockerfile writes. An image built on one of them inherits them, and anybody can write
/// a label: they say what an image is for, and are no reason to trust it.
public enum ImageLabel {
    /// On every image of xless and those built on one: `xless clean` finds the untagged ones by it.
    public static let image = "org.xless.image"
    public static let arch = "dev.xless.arch"
    /// The release of the xless in it.
    public static let version = "dev.xless.version"
    /// Which xless built it: `v<version>-<12 hex>` of a release, `<commit>[-dirty]-<12 hex>` of a checkout (the hex: its pins).
    public static let id = "dev.xless.image"

    /// A kit's image: which kit, the ID of the image it was built on, and the SHA-256 of what it was built from.
    public static let kit = "dev.xless.kit"
    public static let kitBase = "dev.xless.kit.base"
    public static let kitRecipe = "dev.xless.kit.recipe"
}

/// Why an image is not used, and how to get one that is.
public struct ImageProblem: Error, Equatable, CustomStringConvertible {
    public let cause: String
    public let fix: String

    public init(_ cause: String, fix: String) { self.cause = cause; self.fix = fix }

    public var description: String { "\(cause); \(fix)" }
}
