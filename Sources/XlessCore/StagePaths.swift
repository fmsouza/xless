import Foundation

public struct StagePaths: Sendable {
    public let root: URL

    public init(project: URL, platform: Platform) {
        root = project.appendingPathComponent(".xless/build/\(platform.rawValue)", isDirectory: true)
    }

    /// React Native simulator builds: `.xless/build/ios-simulator`, next to (never inside) the device build's `ios`.
    public static func iosSimulator(project: URL) -> StagePaths {
        StagePaths(root: project.appendingPathComponent(".xless/build/ios-simulator", isDirectory: true))
    }

    private init(root: URL) { self.root = root }

    public var app: URL { root.appendingPathComponent("app", isDirectory: true) }
    public var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public var final: URL { root.appendingPathComponent("final", isDirectory: true) }
    public var signed: URL { root.appendingPathComponent("signed", isDirectory: true) }
    public var out: URL { root.appendingPathComponent("out", isDirectory: true) }
    /// The build's debug symbols, which `package` zips next to its package: for React Native device builds every `.dSYM`
    /// Swift Build wrote, at its path under the products directory; for every other app, `<App>.app.dSYM` (`DSYM.keep`),
    /// when its build had debug info (docs/pipeline.md#dsyms). Removed at the start of every `build`.
    public var dSYMs: URL { root.appendingPathComponent("dSYMs", isDirectory: true) }
    public var uploadRecord: URL { root.appendingPathComponent("upload.json") }
}
