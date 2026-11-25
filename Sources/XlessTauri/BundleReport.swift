import Foundation
import XlessCore
import XlessMachO

public struct SliceReport: Codable, Equatable, Sendable {
    public var platform: UInt32
    public var minos: String
    public var linkedLibraries: [String]
    public var rpaths: [String]

    public init(platform: UInt32, minos: String, linkedLibraries: [String], rpaths: [String]) {
        self.platform = platform; self.minos = minos; self.linkedLibraries = linkedLibraries; self.rpaths = rpaths
    }
}

public struct ExecutableReport: Codable, Equatable, Sendable {
    public var platform: UInt32
    public var minos: String
    public var linkedLibraries: [String]
    public var rpaths: [String]
    /// Per-architecture view; present only for fat binaries. The fields above are those of the first slice in arch-name order.
    public var slices: [String: SliceReport]?

    public init(platform: UInt32, minos: String, linkedLibraries: [String], rpaths: [String], slices: [String: SliceReport]? = nil) {
        self.platform = platform; self.minos = minos; self.linkedLibraries = linkedLibraries; self.rpaths = rpaths
        self.slices = slices
    }

    static func read(_ url: URL) throws -> ExecutableReport {
        let data = try Data(contentsOf: url)
        let archs = try MachO.sliceArchitectures(in: data).sorted { $0.name < $1.name }
        var reports: [String: SliceReport] = [:]
        for a in archs {
            let bv = try MachO.buildVersion(in: data, slice: a.range)
            reports[a.name] = SliceReport(platform: bv?.platform ?? 0, minos: bv.map { MachO.decodeVersion($0.minos) } ?? "",
                                          linkedLibraries: try MachO.linkedLibraries(in: data, slice: a.range),
                                          rpaths: try MachO.rpaths(in: data, slice: a.range))
        }
        guard let first = archs.first.flatMap({ reports[$0.name] }) else { throw MachOError.notMachO }
        return ExecutableReport(platform: first.platform, minos: first.minos, linkedLibraries: first.linkedLibraries,
                                rpaths: first.rpaths, slices: MachO.isFat(data) ? reports : nil)
    }
}

/// Platform-independent description of a built .app, used to compare an xless build against an Xcode-built reference.
public struct BundleReport: Codable, Equatable, Sendable {
    public var files: [String]
    public var infoPlist: [String: String]
    public var executable: ExecutableReport
    public var frameworks: [String: ExecutableReport]
    /// `AssetCatalogReport` lines of each `.car` in the bundle, by bundle-relative path. Recorded only where `xcrun
    /// assetutil` exists (macOS); absent from reports made elsewhere, and then not compared.
    public var assetCatalogs: [String: [String]]? = nil

    static let volatilePlistKeys: Set<String> = ["BuildMachineOSBuild", "DTCompiler", "DTPlatformBuild", "DTSDKBuild",
                                                 "DTXcode", "DTXcodeBuild", "CFBundleVersion"]

    public static func make(app: URL) throws -> BundleReport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: app.path, isDirectory: &isDir), isDir.boolValue else {
            throw XlessError(.build, "no bundle at \(app.path)", fix: "pass the path of a built .app directory")
        }
        let root = app.resolvingSymlinksInPath()
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw XlessError(.build, "cannot read bundle at \(app.path)", fix: "check the directory permissions")
        }
        var files: [String] = []
        for case let url as URL in en {
            let full = url.path.hasPrefix(root.path + "/") ? url.path : url.resolvingSymlinksInPath().path
            let rel = String(full.dropFirst(root.path.count + 1))
            if rel == "_CodeSignature" || rel.hasPrefix("_CodeSignature/") || rel.hasSuffix("/_CodeSignature")
                || rel.contains("/_CodeSignature/") || rel.hasSuffix("embedded.mobileprovision") { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(rel)
        }
        files.sort()

        // macOS bundles keep everything under Contents/ (Info.plist, MacOS/<exe>, Frameworks/); iOS bundles are flat.
        let contents = root.appendingPathComponent("Contents")
        let base = fm.fileExists(atPath: contents.appendingPathComponent("Info.plist").path) ? contents : root
        let exeDir = base == contents ? contents.appendingPathComponent("MacOS") : root
        let plistURL = base.appendingPathComponent("Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw XlessError(.build, "no readable Info.plist in \(app.path)", fix: "pass the path of a built .app directory")
        }
        var info: [String: String] = [:]
        for (k, v) in plist where !volatilePlistKeys.contains(k) { info[k] = canonical(v, top: true) }

        guard let exeName = plist["CFBundleExecutable"] as? String else {
            throw XlessError(.build, "Info.plist in \(app.path) has no CFBundleExecutable", fix: "pass the path of a built .app directory")
        }
        let exe: ExecutableReport
        do { exe = try ExecutableReport.read(exeDir.appendingPathComponent(exeName)) }
        catch { throw XlessError(.build, "cannot read executable \(exeName) in \(app.path): \(error)", fix: "pass the path of a built .app directory") }

        var fws: [String: ExecutableReport] = [:]
        let fwDir = base.appendingPathComponent("Frameworks")
        for name in ((try? fm.contentsOfDirectory(atPath: fwDir.path)) ?? []).sorted() where name.hasSuffix(".framework") {
            let bin = fwDir.appendingPathComponent(name).appendingPathComponent(String(name.dropLast(".framework".count)))
            guard let data = try? Data(contentsOf: bin) else { continue }
            let isImage: Bool
            do { isImage = try MachO.containsLoadableImage(data) }
            catch { throw XlessError(.build, "cannot read framework \(name) in \(app.path): \(error)", fix: "pass the path of a built .app directory") }
            guard isImage else { continue }   // static archives (also fat-wrapped) are not reported
            do { fws[name] = try ExecutableReport.read(bin) }
            catch { throw XlessError(.build, "cannot read framework \(name) in \(app.path): \(error)", fix: "pass the path of a built .app directory") }
        }
        // Bundles without a car (macOS apps with an .icns) report none, so their JSON keeps its shape.
        let hasCar = files.contains { $0.hasSuffix(".car") }
        let catalogs = AssetCatalogReport.isAvailable && hasCar ? try AssetCatalogReport.catalogs(in: root, files: files) : nil
        return BundleReport(files: files, infoPlist: info, executable: exe, frameworks: fws, assetCatalogs: catalogs)
    }

    /// Platform-independent rendering of a plist value: sorted dictionary keys, explicit scalar forms.
    /// A top-level string is verbatim; nested strings are quoted. Darwin and Linux Foundation decode
    /// bool/number/date differently, so every scalar is classified explicitly.
    static func canonical(_ v: Any, top: Bool = false) -> String {
        if let s = v as? String { return top ? s : quote(s) }
        if let d = v as? [String: Any] {
            return "{" + d.keys.sorted().map { "\(quote($0)):\(canonical(d[$0]!))" }.joined(separator: ",") + "}"
        }
        if let a = v as? [Any] { return "[" + a.map { canonical($0) }.joined(separator: ",") + "]" }
        if let dt = v as? Date {
            let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")!
            return "date(\(f.string(from: dt)))"
        }
        if let d = v as? Data { return "data(\(d.base64EncodedString()))" }
        if type(of: v) == Bool.self, let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber {
            switch String(cString: n.objCType) {
            case "c", "B": return n.boolValue ? "true" : "false"   // plist integers are 64-bit ("q"/"Q"), never "c"
            case "f", "d": return "\(n.doubleValue)"
            case "Q": return "\(n.uint64Value)"
            default: return "\(n.int64Value)"
            }
        }
        return String(describing: v)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacing(scalar: "\\", with: "\\\\").replacing(scalar: "\"", with: "\\\"") + "\""
    }

    /// Deterministic JSON (sorted keys, pretty printed).
    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// One line per difference, each starting with its key (`file:`, `plist:`, `lib:`, `rpath:`, `exe:`, `framework:`,
    /// `car:`). Asset catalogs are compared only when both reports carry them (both made on a Mac).
    public static func diff(reference: BundleReport, actual: BundleReport, allowed: Set<String>) -> [String] {
        var out: [String] = []
        func add(_ key: String, _ msg: String) { if !allowed.contains(key) { out.append("\(key) \(msg)") } }

        let rf = Set(reference.files), af = Set(actual.files)
        for f in rf.subtracting(af).sorted() { add("file:\(f)", "missing from actual") }
        for f in af.subtracting(rf).sorted() { add("file:\(f)", "not in reference") }

        for k in Set(reference.infoPlist.keys).union(actual.infoPlist.keys).sorted() {
            let r = reference.infoPlist[k], a = actual.infoPlist[k]
            if r != a { add("plist:\(k)", "reference=\(r ?? "<absent>") actual=\(a ?? "<absent>")") }
        }

        func libs(_ r: BundleReport) -> Set<String> {
            Set(r.executable.linkedLibraries).union(r.frameworks.values.flatMap(\.linkedLibraries))
        }
        let rl = libs(reference), al = libs(actual)
        for l in rl.subtracting(al).sorted() { add("lib:\(l)", "missing from actual") }
        for l in al.subtracting(rl).sorted() { add("lib:\(l)", "not in reference") }

        func rpaths(_ r: BundleReport) -> Set<String> {
            Set(r.executable.rpaths).union(r.frameworks.values.flatMap(\.rpaths))
        }
        let rr = rpaths(reference), ar = rpaths(actual)
        for p in rr.subtracting(ar).sorted() { add("rpath:\(p)", "missing from actual") }
        for p in ar.subtracting(rr).sorted() { add("rpath:\(p)", "not in reference") }

        if reference.executable.platform != actual.executable.platform {
            add("exe:platform", "reference=\(reference.executable.platform) actual=\(actual.executable.platform)")
        }
        if reference.executable.minos != actual.executable.minos {
            add("exe:minos", "reference=\(reference.executable.minos) actual=\(actual.executable.minos)")
        }
        let rs = reference.executable.slices ?? [:], as_ = actual.executable.slices ?? [:]
        for arch in Set(rs.keys).union(as_.keys).sorted() {
            guard let r = rs[arch] else { add("exe:slice:\(arch):extra", "not in reference"); continue }
            guard let a = as_[arch] else { add("exe:slice:\(arch):missing", "missing from actual"); continue }
            let rl = Set(r.linkedLibraries), al = Set(a.linkedLibraries)
            for l in rl.subtracting(al).sorted() { add("lib:\(arch):\(l)", "missing from actual") }
            for l in al.subtracting(rl).sorted() { add("lib:\(arch):\(l)", "not in reference") }
            if r.minos != a.minos { add("exe:\(arch):minos", "reference=\(r.minos) actual=\(a.minos)") }
        }
        for n in Set(reference.frameworks.keys).union(actual.frameworks.keys).sorted() {
            let r = reference.frameworks[n], a = actual.frameworks[n]
            if r == nil { add("framework:\(n)", "not in reference") }
            else if a == nil { add("framework:\(n)", "missing from actual") }
            else if r!.platform != a!.platform || r!.minos != a!.minos {
                add("framework:\(n)", "reference=\(r!.platform)/\(r!.minos) actual=\(a!.platform)/\(a!.minos)")
            }
        }
        if let rc = reference.assetCatalogs, let ac = actual.assetCatalogs {
            out += AssetCatalogReport.diff(reference: rc, actual: ac, allowed: allowed)
        }
        return out
    }

    /// Allow-file format: one key per line; blank lines and `#` comments are ignored.
    public static func parseAllow(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }
}
