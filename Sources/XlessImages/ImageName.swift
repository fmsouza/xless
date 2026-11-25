import Foundation

/// The names of the Docker images `xless setup --docker` builds on this machine. One image per Xcode and architecture,
/// `xless:local-<arch>-xcode<version>`; the images of the kits (`Kit`) are named after the one they are built on.
public enum ImageName {
    public static let repository = "xless"

    /// The images of xless up to 0.10: one Xcode's SDK, Tauri's and React Native's toolchains, each an image of its own.
    public static let oldRepositories = ["xless-base", "xless-tauri", "xless-rn"]

    public static func base(arch: String, xcode: String) -> String { "\(repository):local-\(arch)-xcode\(xcode)" }

    /// The base image of one build of an Xcode: the tag that `XLESS_XCODE_RETAG=1` keeps when another build of that version comes.
    public static func base(arch: String, xcode: String, build: String) -> String { "\(base(arch: arch, xcode: xcode))-\(build)" }

    /// Swift, xtool and rcodesign without an SDK: what `xless setup --docker` exports the SDK with, and removes again.
    public static func tools(arch: String) -> String { "\(repository):local-\(arch)-setup" }

    /// The tag without an Xcode, as xless made it up to 0.10.
    public static func plain(arch: String) -> String { "\(repository):local-\(arch)" }

    /// The Xcode version of a base image's name; nil: it is another image's.
    public static func xcode(ofBase name: String, arch: String) -> String? {
        let start = "\(repository):local-\(arch)-xcode"
        guard name.hasPrefix(start) else { return nil }
        let version = name.dropFirst(start.count)
        return version.wholeMatch(of: /[0-9]+\.[0-9]+(\.[0-9]+)?/) == nil ? nil : String(version)
    }

    /// `text` can be the name of an image. It starts with a letter or a digit, so docker never takes it for an option.
    public static func isReference(_ text: String) -> Bool { text.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._\/:@+\-]*/) != nil }

    /// `a` is an older Xcode version than `b`.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let a = a.split(separator: ".").map { Int($0) ?? 0 }, b = b.split(separator: ".").map { Int($0) ?? 0 }
        return a.lexicographicallyPrecedes(b)
    }
}

/// The labels of the images, which docker/Dockerfile writes. An image built on one of them inherits them, and anybody can write
/// a label: they say what an image is for, and are no reason to trust it.
public enum ImageLabel {
    /// On every image of xless and those built on one: `xless clean` finds the untagged ones by it.
    public static let image = "org.xless.image"
    /// The Xcode build whose SDK it holds, e.g. 17F113.
    public static let sdk = "dev.xless.sdk"
    /// That Xcode's version, e.g. 26.6.
    public static let xcode = "dev.xless.xcode"
    public static let arch = "dev.xless.arch"
    /// The release of the xless in it.
    public static let version = "dev.xless.version"

    /// A kit's image: which kit, the ID of the image it was built on, and the SHA-256 of what it was built from.
    public static let kit = "dev.xless.kit"
    public static let kitBase = "dev.xless.kit.base"
    public static let kitRecipe = "dev.xless.kit.recipe"

    /// The oldest xless that this one works with in an image.
    public static let minimumVersion = "0.10.0"
}

/// Why an image is not used, and how to get one that is.
public struct ImageProblem: Error, Equatable, CustomStringConvertible {
    public let cause: String
    public let fix: String

    public init(_ cause: String, fix: String) { self.cause = cause; self.fix = fix }

    public var description: String { "\(cause); \(fix)" }
}
