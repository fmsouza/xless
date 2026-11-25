import Foundation

/// The tools of a build on a Mac that xless has a replacement of its own for: Xcode's are used where they are, xless's where not.
/// `XLESS_TOOLS` forces either, for all (`xcode`, `xless`) or for each (`actool=xless,ibtool=xcode`). It is a setting of the machine
/// and not of the project, which builds on Linux with xless's all the same. (The compiler and the linker are Xcode's: xless has none.)
public struct NativeTools: Sendable, Equatable {
    public enum Tool: String, Sendable, CaseIterable { case actool, ibtool }
    public enum Choice: String, Sendable { case xcode, xless }

    /// What is forced.
    public let forced: [Tool: Choice]

    public init(setting: String?) throws {
        var forced: [Tool: Choice] = [:]
        for word in (setting ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !word.isEmpty {
            let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let choice = Choice(rawValue: parts.last ?? ""), parts.count == 1 || Tool(rawValue: parts[0]) != nil else {
                throw XlessError(.config, "XLESS_TOOLS has '\(word)'", fix: "use xcode or xless, or one for each tool (\(Tool.allCases.map(\.rawValue).joined(separator: ", "))): actool=xless,ibtool=xcode")
            }
            for tool in parts.count == 1 ? Tool.allCases : Tool(rawValue: parts[0]).map({ [$0] }) ?? [] { forced[tool] = choice }
        }
        self.forced = forced
    }

    /// Xcode's `tool`; nil: xless's own does it.
    public func program(_ tool: Tool, of xcode: InstalledXcode, stage: Stage) throws -> URL? {
        switch forced[tool] {
        case .xless: return nil
        case .xcode: return try xcode.require(tool.rawValue, stage: stage)
        case nil: return xcode.tool(tool.rawValue)
        }
    }

    /// `actool and ibtool: Xcode's`, the line a build says it with.
    public func summary(of xcode: InstalledXcode) -> String {
        func names(_ ours: Bool) -> [String] {
            Tool.allCases.filter { (forced[$0] == .xless || forced[$0] == nil && xcode.tool($0.rawValue) == nil) == ours }.map(\.rawValue)
        }
        return [(names(false), "Xcode's"), (names(true), "xless's own")].filter { !$0.0.isEmpty }
            .map { "\($0.0.joined(separator: " and ")): \($0.1)" }.joined(separator: "; ")
    }
}
