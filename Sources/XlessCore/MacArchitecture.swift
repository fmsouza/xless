/// A macOS CPU architecture an app can be built for. `allCases` is the canonical order (the cargo runs' order) and the
/// default: both, merged into a universal executable.
public enum MacArchitecture: String, Sendable, CaseIterable, Codable {
    case arm64, x86_64

    /// The Rust (cargo) target triple.
    public var rustTarget: String { self == .arm64 ? "aarch64-apple-darwin" : "x86_64-apple-darwin" }
}
