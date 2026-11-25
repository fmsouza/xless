public enum Stage: String, Sendable, CaseIterable, Comparable {
    case config, sdk, prepare, build, assets, finalize, sign, package, upload, ib
    /// The Apple account commands (`xless api`, and the resource commands of M7): not a pipeline stage.
    case account
    /// Input was needed, and `--no-input` (XLESS_NO_INPUT=1) is set: not a pipeline stage either.
    case input

    public var exitCode: Int32 {
        switch self {
        case .config: 10
        case .sdk: 11
        case .prepare: 19
        case .build: 12
        case .assets: 13
        case .finalize: 14
        case .sign: 15
        case .package: 16
        case .upload: 17
        case .ib: 18
        case .account: 20
        case .input: 23
        }
    }

    public static func < (a: Stage, b: Stage) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public struct XlessError: Error, CustomStringConvertible, Equatable, Sendable {
    public let stage: Stage
    public let cause: String
    public let fix: String
    /// The process's exit code when it is not the stage's own.
    public let code: Int32?

    /// `sign` needs changes on the account that it may not make (`--no-provisioning-updates`).
    public static let provisioningNeeded: Int32 = 24

    public init(_ stage: Stage, _ cause: String, fix: String, code: Int32? = nil) {
        self.stage = stage
        self.cause = cause
        self.fix = fix
        self.code = code
    }

    public var exitCode: Int32 { code ?? stage.exitCode }

    public var description: String { "[\(stage.rawValue)] \(cause) — \(fix)" }
}
