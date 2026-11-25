import Foundation
import XlessCore

/// Builds the `.app` of a Cargo app from its executable, with no Xcode: the Info.plist (from the app's template, or
/// from nothing), the resources the overlay lists and, per platform, the privacy manifest (iOS) or icon (macOS). The
/// asset catalog and launch screen are compiled later by the `assets` stage; DT* keys and the SDK version by `finalize`.
public enum CargoBundler {
    /// `vars` are the built-in placeholder values (`SHORT_VERSION`, `VERSION`, `GIT_SHA`…). The overlay's `plistVars`
    /// (`resolved.plistVars`) are expanded once against them and win on a name clash. `inputs` maps an input name to its
    /// absolute directory (for `input:<name>/…` paths).
    public static func infoPlist(resolved: ResolvedCargo, platform: Platform, work: URL, inputs: [String: URL], vars: [String: String]) throws -> [String: Any] {
        let block = resolved.platform, config = resolved.config
        guard isFileName(block.product) else {
            throw XlessError(.build, "product '\(block.product)' is not a single file name", fix: "use a plain name for \(platform.rawValue).product, e.g. Hello")
        }
        var info: [String: Any] = [:]
        if let path = block.infoPlist {
            info = try Plist.read(try resolve(path, key: "\(platform.rawValue).infoPlist", work: work, inputs: inputs), stage: .build)
        }

        var all = vars
        for (name, value) in resolved.plistVars.sorted(by: { $0.key < $1.key }) {
            var missing = Set<String>()
            let expanded = PlistTemplate.expand(value, vars: vars, missing: &missing)
            // One pass: a token still there (a plistVars name, or an unknown one) is not resolved.
            var leftover = Set<String>()
            _ = PlistTemplate.expand(expanded, vars: [:], missing: &leftover)
            if !missing.isEmpty || !leftover.isEmpty {
                throw XlessError(.build, "plistVars \(name) refers to \(missing.union(leftover).sorted().map { "@\($0)@" }.joined(separator: ", ")), which is not a built-in value",
                                 fix: "plistVars may use only the built-ins (\(vars.keys.sorted().joined(separator: ", "))), not each other")
            }
            all[name] = expanded
        }
        info = try PlistTemplate.expand(info, vars: all)

        info["CFBundleIdentifier"] = config.bundleID(for: platform)
        info["CFBundleExecutable"] = block.product
        if info["CFBundleName"] == nil { info["CFBundleName"] = block.product }
        info["CFBundlePackageType"] = "APPL"
        info["CFBundleShortVersionString"] = config.version
        info["CFBundleVersion"] = config.build
        info["CFBundleInfoDictionaryVersion"] = "6.0"
        switch platform {
        case .ios:
            info["MinimumOSVersion"] = block.minimumOS
            info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
            if info["UIDeviceFamily"] == nil { info["UIDeviceFamily"] = [1, 2] }
        case .macos:
            info["LSMinimumSystemVersion"] = block.minimumOS
            if block.icon != nil { info["CFBundleIconFile"] = block.product }
        }
        return info
    }

    /// Writes `<product>.app` into `appDir` (an existing one is replaced) and returns it.
    public static func assemble(resolved: ResolvedCargo, platform: Platform, work: URL, inputs: [String: URL], vars: [String: String],
                                executable: URL, privacyManifest: URL?, into appDir: URL) throws -> URL {
        let fm = FileManager.default
        let block = resolved.platform, product = block.product
        let layout = BundleLayout(platform: platform)
        // Everything that can fail on the app's own files is checked before anything is written.
        let info = try infoPlist(resolved: resolved, platform: platform, work: work, inputs: inputs, vars: vars)
        guard fm.fileExists(atPath: executable.path) else {
            throw XlessError(.build, "the built executable \(executable.path) does not exist", fix: "check that cargo built the binary")
        }
        var icon: URL?
        if platform == .macos, let path = block.icon {
            let url = try resolve(path, key: "macos.icon", work: work, inputs: inputs)
            guard fm.fileExists(atPath: url.path) else {
                throw XlessError(.build, "macos.icon \(path) does not exist (\(url.path))", fix: "fix macos.icon in the overlay")
            }
            icon = url
        }
        if platform == .ios, let privacy = privacyManifest, !fm.fileExists(atPath: privacy.path) {
            throw XlessError(.build, "privacyManifest \(privacy.path) does not exist", fix: "fix privacyManifest in the overlay (a relative path resolves against the overlay file's directory)")
        }

        let app = appDir.appendingPathComponent("\(product).app", isDirectory: true)
        func at(_ relative: String) -> URL { relative.isEmpty ? app : app.appendingPathComponent(relative) }
        let executablePath = at(layout.executableDir).appendingPathComponent(product)
        let resourcesRoot = at(layout.resourcesDir)
        let reserved = Set([executablePath, at(layout.infoPlist), at(layout.pkgInfo), at("PrivacyInfo.xcprivacy"),
                            resourcesRoot.appendingPathComponent("\(product).icns")].map { $0.standardizedFileURL.path })

        do {
            try? fm.removeItem(at: app)
            for dir in [at(layout.executableDir), resourcesRoot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            try copyResources(block.resources, to: resourcesRoot, reserved: Set(reserved.map(fileKey)), work: work, inputs: inputs, platform: platform)
            try fm.copyItem(at: executable, to: executablePath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath.path)
            try Plist.write(info, to: at(layout.infoPlist), format: .xml, stage: .build)
            try Data("APPL????".utf8).write(to: at(layout.pkgInfo))
            if platform == .ios, let privacy = privacyManifest { try fm.copyItem(at: privacy, to: at("PrivacyInfo.xcprivacy")) }
            if let icon { try fm.copyItem(at: icon, to: resourcesRoot.appendingPathComponent("\(product).icns")) }
        } catch let e as XlessError {
            throw e
        } catch {
            throw XlessError(.build, "cannot assemble \(app.path): \(error)", fix: "check disk space and permissions")
        }
        return app
    }

    // MARK: paths

    private static func isFileName(_ s: String) -> Bool { !s.isEmpty && !s.contains("/") && s != "." && s != ".." && !s.contains("\0") }

    /// An overlay path: relative to `work`, or `input:<name>/<path>` into `inputs[name]`. Never outside its root.
    static func resolve(_ path: String, key: String, work: URL, inputs: [String: URL]) throws -> URL {
        var root = work, rest = Substring(path)
        if rest.hasPrefix("input:") {
            let after = rest.dropFirst("input:".count)
            let name = String(after.prefix(while: { $0 != "/" }))
            guard let dir = inputs[name] else {
                throw XlessError(.build, "\(key) '\(path)' names input '\(name)', which has no directory", fix: "declare the input under inputs: in the overlay")
            }
            root = dir
            rest = after.dropFirst(name.count + 1)
        }
        let base = root.standardizedFileURL
        let url = rest.isEmpty ? base : base.appendingPathComponent(String(rest)).standardizedFileURL
        guard !path.contains("\0"), url.path == base.path || url.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else {
            throw XlessError(.build, "\(key) '\(path)' leaves its root", fix: "use a path that stays inside the source root (or the input)")
        }
        return url
    }

    // MARK: resources

    /// Two paths with the same key name the same file: macOS file systems take no notice of case (nor of how a letter is composed,
    /// which Swift's strings do not tell apart either).
    private static func fileKey(_ path: String) -> String {
        #if os(macOS)
        path.lowercased()
        #else
        path
        #endif
    }

    private static func copyResources(_ resources: [CargoResource], to resourcesRoot: URL, reserved: Set<String>, work: URL, inputs: [String: URL],
                                      platform: Platform) throws {
        let fm = FileManager.default
        let root = resourcesRoot.standardizedFileURL.path
        for (i, resource) in resources.enumerated() {
            let key = "\(platform.rawValue).resources[\(i)]"
            let isGlob = resource.from.contains("*")
            let keepsName = resource.to.hasSuffix("/")
            if isGlob && !keepsName {
                throw XlessError(.build, "\(key).from '\(resource.from)' is a glob, so to '\(resource.to)' must end in '/'", fix: "name a directory: to: \"\(resource.to)/\"")
            }
            let sources: [(url: URL, name: String)]
            if isGlob {
                let found = try glob(resource.from, key: key, work: work, inputs: inputs)
                // Files of different directories keep their directory's name: fonts/<family>/OFL.txt → <family>-OFL.txt.
                sources = found.map { ($0, "\($0.deletingLastPathComponent().lastPathComponent)-\($0.lastPathComponent)") }
            } else {
                let url = try resolve(resource.from, key: "\(key).from", work: work, inputs: inputs)
                guard fm.fileExists(atPath: url.path) else {
                    throw XlessError(.build, "\(key).from '\(resource.from)' does not exist (\(url.path))", fix: "fix the path in the overlay's resources")
                }
                sources = [(url, url.lastPathComponent)]
            }
            if sources.isEmpty {
                throw XlessError(.build, "\(key).from '\(resource.from)' matches nothing", fix: "check the pattern, and that the input is the revision that has these files")
            }
            var seen = Set<String>()
            for (source, name) in sources {
                let dest = (keepsName ? resourcesRoot.appendingPathComponent(resource.to).appendingPathComponent(name) : resourcesRoot.appendingPathComponent(resource.to)).standardizedFileURL
                guard dest.path.hasPrefix(root + "/"), !reserved.contains(fileKey(dest.path)) else {
                    throw XlessError(.build, "\(key).to '\(resource.to)' would overwrite the bundle's own files or leave the bundle", fix: "name a location inside the bundle's resources, e.g. Licenses/")
                }
                guard seen.insert(fileKey(dest.path)).inserted else {
                    throw XlessError(.build, "\(key).from '\(resource.from)' has two matches that land on \(dest.lastPathComponent)", fix: "narrow the pattern")
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: source.resolvingSymlinksInPath(), to: dest)
            }
        }
    }

    /// The existing paths matching `pattern` (`*` stands for any run of characters inside one path component), sorted.
    private static func glob(_ pattern: String, key: String, work: URL, inputs: [String: URL]) throws -> [URL] {
        let fm = FileManager.default
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let firstWild = parts.firstIndex(where: { $0.contains("*") }), !parts.contains(".."), !(pattern.hasPrefix("input:") && firstWild == 0) else {
            throw XlessError(.build, "\(key).from '\(pattern)' is not a valid pattern", fix: "use `*` only inside the path after the input name, and no '..'")
        }
        // The part before the first wildcard is resolved as a path, so `input:` and the root check apply to it.
        let prefixEnd = firstWild
        let literal = parts[..<prefixEnd].joined(separator: "/")
        var current: [URL] = [try resolve(literal.isEmpty ? "." : literal, key: "\(key).from", work: work, inputs: inputs)]
        for component in parts[prefixEnd...] {
            var next: [URL] = []
            for dir in current {
                if component.contains("*") {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                          let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                    let pat = Array(component.unicodeScalars)
                    for name in names.sorted() where (!name.hasPrefix(".") || component.hasPrefix(".")) && wildcard(pat, Array(name.unicodeScalars)) {
                        next.append(dir.appendingPathComponent(name))
                    }
                } else {
                    next.append(dir.appendingPathComponent(component))
                }
            }
            current = next
        }
        return current.filter { fm.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
    }

    /// `*` matches any run (including none); every other scalar matches itself.
    static func wildcard(_ pattern: [Unicode.Scalar], _ text: [Unicode.Scalar]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1; t += 1
            } else if star >= 0 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
