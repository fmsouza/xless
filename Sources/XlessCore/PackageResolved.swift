import Foundation

/// SwiftPM keeps to the root package's Package.resolved only. Where xless builds an app's package as the dependency of a root package
/// that it generates, the app's own file is put there.
public enum PackageResolved {
    static let name = "Package.resolved"

    /// Puts the file of `directory` (a project, or a workspace's `xcshareddata/swiftpm`) into the generated package `wrapper`.
    /// False when there is none.
    @discardableResult
    public static func copy(from directory: URL, to wrapper: URL) throws -> Bool {
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        do { try Data(contentsOf: file).write(to: wrapper.appendingPathComponent(name), options: .atomic) } catch {
            throw XlessError(.build, "cannot read \(file.path): \(error.localizedDescription)", fix: "make it readable: it says which versions of its packages the app is built with")
        }
        return true
    }

    /// The packages that were built in a version that the project's file does not name, for the build's log.
    public static func unpinnedNote(project: URL, wrapper: URL) -> String? {
        func pins(_ directory: URL) -> [String: [String: String]]? {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                  let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pins = file["pins"] as? [[String: Any]] else { return nil }
            return Dictionary(pins.compactMap { pin in (pin["identity"] as? String).map { ($0, pin["state"] as? [String: String] ?? [:]) } }) { first, _ in first }
        }
        let own = pins(project)
        let others = (pins(wrapper) ?? [:]).filter { own?[$0.key] != $0.value }
            .map { "\($0.key) \($0.value["version"] ?? $0.value["branch"] ?? $0.value["revision"] ?? "?")" }.sorted()
        guard !others.isEmpty else { return nil }
        return (own == nil ? "the project has no Package.resolved, which would hold these packages to a version: " : "Package.resolved does not name these, which were built: ")
            + others.joined(separator: ", ") + " (`swift package resolve` writes it: keep it with the project)"
    }
}
