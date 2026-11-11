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

    /// Where the dSYM of one executable is, or why there is none.
    public enum Source: Equatable, Sendable {
        case found(URL)
        case missing(String)
    }

    /// The dSYM of `app`, from the `<executable>.dSYM` next to each of `executables` (one thin executable per
    /// architecture): `keep(_:app:into:)`.
    public static func keep(executables: [URL], app: URL, into dir: URL) throws -> Outcome {
        try keep(executables.map { (executable: $0, dSYM: Source.found(companion(of: $0))) }, app: app, into: dir)
    }

    /// The dSYM of `app`, from one dSYM per thin executable (one executable per architecture; the slices follow their
    /// order): written to `dir` as `<App>.app.dSYM`, with one DWARF file named after the app's `CFBundleExecutable`,
    /// universal when there is more than one executable. The rest of the bundle (Info.plist) is the first dSYM's. `dir`
    /// is replaced; it is removed when there is no dSYM to keep: an executable has none (`.missing`, or a dSYM without
    /// its DWARF file: its build had no debug info), or a dSYM's UUIDs are not its executable's (a dSYM left by an
    /// earlier build).
    public static func keep(_ slices: [(executable: URL, dSYM: Source)], app: URL, into dir: URL) throws -> Outcome {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        var dwarfs: [Data] = [], bundles: [URL] = []
        for (exe, source) in slices {
            let dSYM: URL
            switch source {
            case .missing(let reason): return .none(reason)
            case .found(let url): dSYM = url
            }
            let files = (try? fm.contentsOfDirectory(at: dSYM.appendingPathComponent(dwarfDir), includingPropertiesForKeys: nil)) ?? []
            guard files.count <= 1 else { return .none("\(dSYM.path) holds \(files.count) DWARF files, not one") }
            guard let file = files.first, let dwarf = try? Data(contentsOf: file) else {
                return .none(dSYM == companion(of: exe) ? "no \(dSYM.lastPathComponent) next to \(exe.path)" : "no DWARF file in \(dSYM.path)")
            }
            let want = (try? MachO.uuids(in: Data(contentsOf: exe))) ?? [], have = (try? MachO.uuids(in: dwarf)) ?? []
            guard !want.isEmpty else { return .none("\(exe.path) has no LC_UUID") }
            guard have == want else {
                return .none("the UUID of \(dSYM.path) (\(have.joined(separator: ", "))) is not its executable's "
                             + "(\(want.joined(separator: ", "))): it is from another build")
            }
            dwarfs.append(dwarf)
            bundles.append(dSYM)
        }
        guard let first = bundles.first else { return .none("no executable") }
        let name = app.lastPathComponent + ".dSYM"
        let partial = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            let bundle = partial.appendingPathComponent(name, isDirectory: true)
            // The dSYM may be a symbolic link (cargo's `<bin>.dSYM` names rustc's `deps/<crate>-<hash>.dSYM`): copy
            // what it names.
            try fm.copyItem(at: first.resolvingSymlinksInPath(), to: bundle)
            let dwarfDir = bundle.appendingPathComponent(Self.dwarfDir, isDirectory: true)
            try fm.removeItem(at: dwarfDir)
            try fm.createDirectory(at: dwarfDir, withIntermediateDirectories: true)
            try (dwarfs.count == 1 ? dwarfs[0] : MachO.makeFat(dwarfs)).write(to: dwarfDir.appendingPathComponent(executableName(of: app)))
            try fm.moveItem(at: partial, to: dir)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return .kept(dir.appendingPathComponent(name, isDirectory: true))
    }

    /// The dSYM of `shipped`, a Rust executable cargo linked through xless's linker wrapper with `-Wl,-x`, from the
    /// wrapper's debug link in `dir` (`RustApple.DebugLink`). `ld64.lld -x` drops the debug map of local and hidden
    /// functions, nearly all of a Rust program, so when the crate's objects carry debug info the wrapper links the same
    /// objects again without `-x` into `dir/<name>` and runs dsymutil on that (`dir/<name>.dSYM`). Of the unstripped
    /// links in `dir`, the one with the shipped code (`MachO.sameCode`: only the symbol table and the UUID differ) is
    /// the one; its dSYM's UUID is set to the shipped executable's, which crash reporters match on. The other links
    /// (other binaries of the package, older builds) are then removed; this one stays for a build cargo does not relink.
    /// Without a link, the wrapper's records say why: `<name>.nodebug` (the objects had no DWARF) or `<name>.failed`
    /// (the second link or dsymutil failed). Never throws: whatever goes wrong is the reason there is no dSYM.
    public static func debugLinkDSYM(of shipped: URL, in dir: URL) -> Source {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        let links = entries.filter { !["dSYM", "nodebug", "failed"].contains($0.pathExtension) }
        guard !links.isEmpty else {
            if entries.contains(where: { $0.pathExtension == "failed" }) {
                return .missing("the link of \(shipped.lastPathComponent) without -x, or dsymutil on it, failed (the cargo output says why)")
            }
            if entries.contains(where: { $0.pathExtension == "nodebug" }) {
                return .missing("\(shipped.lastPathComponent) was compiled without debug info: set `debug` in the release profile for a dSYM")
            }
            return .missing("no debug link in \(dir.path): xless's linker wrapper did not link \(shipped.lastPathComponent)")
        }
        do {
            let code = try Data(contentsOf: shipped)
            guard let want = try MachO.uuids(in: code).first else { return .missing("\(shipped.path) has no LC_UUID") }
            guard let unstripped = links.first(where: { (try? MachO.sameCode(code, Data(contentsOf: $0))) == true }) else {
                return .missing("no unstripped link in \(dir.path) has the code of \(shipped.path)")
            }
            let bundle = companion(of: unstripped)
            let files = (try? fm.contentsOfDirectory(at: bundle.appendingPathComponent(dwarfDir), includingPropertiesForKeys: nil)) ?? []
            guard files.count == 1, var dwarf = try? Data(contentsOf: files[0]) else {
                return .missing("dsymutil left no dSYM of \(unstripped.path) (the cargo output says why)")
            }
            try MachO.setUUID(in: &dwarf, to: want)
            try dwarf.write(to: files[0])
            for other in links where other != unstripped {
                try? fm.removeItem(at: other)
                try? fm.removeItem(at: companion(of: other))
            }
            return .found(bundle)
        } catch {
            return .missing("cannot match \(shipped.path) with its debug link: \(error)")
        }
    }

    /// The app's `CFBundleExecutable` (macOS: `Contents/Info.plist`; iOS: `Info.plist`), else its name without `.app`.
    public static func executableName(of app: URL) -> String {
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
