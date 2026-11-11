import Foundation

/// Debug symbols: `.dSYM` bundles, matched to the binaries they describe by LC_UUID, as crash reporters (Crashlytics,
/// Sentry) match them. A dSYM whose UUIDs are not those of a shipped binary describes another build and is never kept.
public enum DSYM {
    public enum Outcome: Equatable, Sendable {
        /// The `.dSYM` bundle written.
        case kept(URL)
        /// Why there is none.
        case none(String)

        /// For the build's log: the bundle's name, or `none (<why>)`.
        public var summary: String {
            switch self {
            case .kept(let url): return url.lastPathComponent
            case .none(let reason): return "none (\(reason))"
            }
        }
    }

    static let dwarfDir = "Contents/Resources/DWARF"

    /// `<executable>.dSYM` next to `executable`: where dsymutil writes it by default and Swift Build puts it.
    public static func companion(of executable: URL) -> URL {
        URL(fileURLWithPath: executable.path + ".dSYM", isDirectory: true)
    }

    /// The UUIDs of a `.dSYM` bundle: those of every file in `Contents/Resources/DWARF`.
    public static func uuids(ofDSYM bundle: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: bundle.appendingPathComponent(dwarfDir), includingPropertiesForKeys: nil)) ?? []
        return Set(files.flatMap { url in (try? Data(contentsOf: url)).flatMap { try? MachO.uuids(in: $0) } ?? [] })
    }

    /// The UUIDs of every Mach-O image under `bundle` (the app's executable, its frameworks, extensions and dylibs).
    /// Only files that start with a Mach-O magic are read whole; symbolic links are not followed.
    public static func imageUUIDs(in bundle: URL) -> Set<String> {
        guard let walk = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var out: Set<String> = []
        for case let url as URL in walk {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true, let head = try? FileHandle(forReadingFrom: url) else { continue }
            let magic = (try? head.read(upToCount: 4)) ?? Data()
            try? head.close()
            guard MachO.isMachO(magic), let data = try? Data(contentsOf: url), let ids = try? MachO.uuids(in: data) else { continue }
            out.formUnion(ids)
        }
        return out
    }

    /// The dSYM of `app`, from the `<executable>.dSYM` next to each of `executables` (one thin executable per
    /// architecture; the slices follow their order): written to `dir` as `<App>.app.dSYM`, with one
    /// DWARF file named after the app's `CFBundleExecutable`, universal when there is more than one executable. The
    /// rest of the bundle (Info.plist) is the first dSYM's. `dir` is replaced; it is removed when there is no dSYM to
    /// keep: an executable has none (its build had no debug info), or a dSYM's UUIDs are not its executable's (a dSYM
    /// left by an earlier build).
    public static func keep(executables: [URL], app: URL, into dir: URL) throws -> Outcome {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        var slices: [Data] = []
        for exe in executables {
            let dSYM = companion(of: exe)
            let files = (try? fm.contentsOfDirectory(at: dSYM.appendingPathComponent(dwarfDir), includingPropertiesForKeys: nil)) ?? []
            guard files.count <= 1 else { return .none("\(dSYM.path) holds \(files.count) DWARF files, not one") }
            guard let file = files.first, let dwarf = try? Data(contentsOf: file) else {
                return .none("no \(dSYM.lastPathComponent) next to \(exe.path)")
            }
            let want = (try? MachO.uuids(in: Data(contentsOf: exe))) ?? [], have = (try? MachO.uuids(in: dwarf)) ?? []
            guard !want.isEmpty else { return .none("\(exe.path) has no LC_UUID") }
            guard have == want else {
                return .none("the UUID of \(dSYM.path) (\(have.joined(separator: ", "))) is not its executable's "
                             + "(\(want.joined(separator: ", "))): it is from another build")
            }
            slices.append(dwarf)
        }
        guard let first = executables.first else { return .none("no executable") }
        let name = app.lastPathComponent + ".dSYM"
        let partial = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            let bundle = partial.appendingPathComponent(name, isDirectory: true)
            // The companion may be a symbolic link (cargo's `<bin>.dSYM` names rustc's `deps/<crate>-<hash>.dSYM`): copy
            // what it names.
            try fm.copyItem(at: companion(of: first).resolvingSymlinksInPath(), to: bundle)
            let dwarfDir = bundle.appendingPathComponent(Self.dwarfDir, isDirectory: true)
            try fm.removeItem(at: dwarfDir)
            try fm.createDirectory(at: dwarfDir, withIntermediateDirectories: true)
            try (slices.count == 1 ? slices[0] : MachO.makeFat(slices)).write(to: dwarfDir.appendingPathComponent(executableName(of: app)))
            try fm.moveItem(at: partial, to: dir)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return .kept(dir.appendingPathComponent(name, isDirectory: true))
    }

    /// The app's `CFBundleExecutable` (macOS: `Contents/Info.plist`; iOS: `Info.plist`), else its name without `.app`.
    static func executableName(of app: URL) -> String {
        for plist in ["Contents/Info.plist", "Info.plist"] {
            if let data = FileManager.default.contents(atPath: app.appendingPathComponent(plist).path),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") {
                return name
            }
        }
        return app.deletingPathExtension().lastPathComponent
    }
}
