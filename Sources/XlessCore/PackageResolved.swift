import Foundation

/// SwiftPM keeps to the root package's Package.resolved only. Where xless builds an app's package as the dependency of a root package
/// that it generates, the app's own file is put there.
public enum PackageResolved {
    static let name = "Package.resolved"
    /// (Nobody's is near it.)
    static let limit = 16 << 20

    /// Puts the file of `directory` (a project, or a workspace's `xcshareddata/swiftpm`) into the generated package `wrapper`.
    /// False when there is none. One that is there and is no Package.resolved (a link to nothing, say) is never taken for none: the
    /// app would be built with other versions than it says.
    @discardableResult
    public static func copy(from directory: URL, to wrapper: URL) throws -> Bool {
        let file = directory.appendingPathComponent(name)
        let there: [FileAttributeKey: Any]
        do { there = try FileManager.default.attributesOfItem(atPath: file.path) } catch CocoaError.fileReadNoSuchFile { return false } catch { throw refused(file, error.localizedDescription) }
        var about = there
        if there[.type] as? FileAttributeType == .typeSymbolicLink {
            guard FileManager.default.fileExists(atPath: file.path) else { throw refused(file, "it is a link to a file that is not there") }
            do { about = try FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path) } catch { throw refused(file, error.localizedDescription) }
        }
        guard about[.type] as? FileAttributeType == .typeRegular else { throw refused(file, "it is not a file") }
        guard (about[.size] as? NSNumber)?.int64Value ?? .max <= Int64(limit) else { throw refused(file, "it is larger than \(limit >> 20) MB") }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw refused(file, error.localizedDescription) }
        guard pins(data) != nil else { throw refused(file, "it has no pins (`swift package resolve` writes it)") }
        do { try data.write(to: wrapper.appendingPathComponent(name), options: .atomic) } catch {
            throw XlessError(.build, "cannot write \(wrapper.appendingPathComponent(name).path): \(error.localizedDescription)", fix: "check disk space and permissions")
        }
        return true
    }

    private static func refused(_ file: URL, _ why: String) -> XlessError {
        XlessError(.build, "cannot read \(file.path): \(why)", fix: "repair it: it says which versions of its packages the app is built with")
    }

    /// Each package's state (revision, version, branch) by its identity; nil: not a Package.resolved. Version 1 has them in `object`,
    /// and URLs in place of identities, which are their last component.
    static func pins(_ data: Data) -> [String: [String: String]]? {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = file["pins"] as? [[String: Any]] ?? (file["object"] as? [String: Any])?["pins"] as? [[String: Any]] else { return nil }
        return Dictionary(pins.compactMap { pin in
            let state = (pin["state"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return (pin["identity"] as? String ?? (pin["repositoryURL"] as? String).map(identity(ofURL:))).map { ($0, state) }
        }) { first, _ in first }
    }

    /// The identity of the package at `url`.
    public static func identity(ofURL url: String) -> String {
        let name = url.split(separator: "/").last.map { $0.lowercased() } ?? ""
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    /// The packages that were built in a version that the project's file does not name, for the build's log.
    public static func unpinnedNote(project: URL, wrapper: URL) -> String? {
        func pins(_ directory: URL) -> [String: [String: String]]? {
            FileManager.default.contents(atPath: directory.appendingPathComponent(name).path).flatMap { Self.pins($0) }
        }
        let own = pins(project)
        let others = (pins(wrapper) ?? [:]).filter { own?[$0.key] != $0.value }
            .map { "\($0.key) \($0.value["version"] ?? $0.value["branch"] ?? $0.value["revision"] ?? "?")" }.sorted()
        guard !others.isEmpty else { return nil }
        return (own == nil ? "the project has no Package.resolved, which would hold these packages to a version: " : "Package.resolved does not name these, which were built: ")
            + others.joined(separator: ", ") + " (`swift package resolve` writes it: keep it with the project)"
    }
}
