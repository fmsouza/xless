import Foundation
import XlessCore

/// One `.xcodeproj`, reduced to what the PIF needs. Built by `XcodeProject.load(_:)` from `project.pbxproj`; any
/// object or key outside the supported subset (what React Native, Expo, CocoaPods and XcodeGen write) is refused.
public struct XcodeProject: Sendable {
    /// The project name (the `.xcodeproj` name without extension).
    public let name: String
    /// Absolute path of the `.xcodeproj` directory.
    public let path: URL
    /// The project directory (`SRCROOT`): the directory holding the `.xcodeproj`, plus `projectDirPath`.
    public let directory: URL
    /// The pbxproj object ID of the `PBXProject`.
    public let rootID: String
    public let mainGroup: Group
    public let configurations: [BuildConfiguration]
    public let defaultConfigurationName: String
    public let developmentRegion: String?
    public let knownRegions: [String]
    public let targets: [Target]
    public let packageReferences: [PackageReference]
    /// Every `PBXFileReference` by object ID, including product references and references outside the group tree.
    public let fileReferences: [String: FileReference]
    /// Every `PBXReferenceProxy` (a product of a target in another project) by object ID.
    public let referenceProxies: [String: ReferenceProxy]
    /// `TargetAttributes` of the `PBXProject`, by target ID (only `ProvisioningStyle` is used).
    let provisioningStyles: [String: String]
    /// `projectReferences` (`ProjectRef`): file references of other `.xcodeproj`s whose products this project uses.
    public let projectReferenceIDs: [String]
    /// File references that build files or configurations use but no group contains (some Expo config plugins
    /// add files that way). Xcode shows them in a "Recovered References" group at the end of the main group, with
    /// paths relative to the project directory; the PIF does the same. Sorted by object ID.
    public let recoveredReferenceIDs: [String]

    public func target(named name: String) -> Target? { targets.first { $0.name == name } }
    public func target(id: String) -> Target? { targets.first { $0.id == id } }

    /// The target whose product reference is `fileRefID`, if any.
    public func producingTarget(ofProduct fileRefID: String) -> Target? {
        targets.first { $0.productReferenceID == fileRefID }
    }
}

public struct Group: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let path: String?
    public let sourceTree: String
    public let children: [GroupItem]
    /// A `PBXVariantGroup` (localized resource); its children are the per-region files.
    public let isVariantGroup: Bool
}

public indirect enum GroupItem: Sendable, Equatable {
    case group(Group)
    case file(FileReference)

    public var id: String {
        switch self {
        case .group(let g): g.id
        case .file(let f): f.id
        }
    }
}

public struct FileReference: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let path: String
    public let sourceTree: String
    /// The Xcode file type identifier: `explicitFileType`, else `lastKnownFileType`, else inferred from the extension
    /// (also when the project says `undefined`/`unknown`, which the `xcode` npm package writes).
    public let fileType: String
    /// `fileEncoding` as a PIF text encoding name (only UTF-8 and UTF-16 are mapped).
    public let textEncoding: String?
}

public struct ReferenceProxy: Sendable, Equatable {
    public let id: String
    public let path: String
    public let fileType: String
    /// The remote target's product: the project file reference (`containerPortal`) and the product's object ID in
    /// that project (`remoteGlobalIDString`).
    public let containerPortalID: String
    public let remoteProductID: String
}

public struct BuildConfiguration: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Build settings as PIF strings: array values are joined with single spaces, as Xcode does when it writes a PIF.
    public let settings: [String: String]
    /// The `baseConfigurationReference` file reference (an `.xcconfig`), if any.
    public let baseConfigurationID: String?
}

public struct Target: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case native(productType: String)
        case aggregate
    }
    public let id: String
    public let name: String
    public let kind: Kind
    public let configurations: [BuildConfiguration]
    public let defaultConfigurationName: String
    public let phases: [BuildPhase]
    public let dependencies: [TargetDependency]
    /// The product `PBXFileReference` (native targets).
    public let productReferenceID: String?
    public let packageProducts: [PackageProductDependency]

    public var productType: String? { if case .native(let t) = kind { t } else { nil } }
}

public struct BuildPhase: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sources, frameworks, resources, headers
        /// `destinationSubfolder`/`destinationSubpath` already mapped from `dstSubfolderSpec`/`dstPath`.
        case copyFiles(destinationSubfolder: String, destinationSubpath: String)
        case shellScript(ShellScript)
    }
    public let id: String
    public let kind: Kind
    public let name: String?
    public let files: [BuildFile]
    public let runOnlyForDeploymentPostprocessing: Bool
}

public struct ShellScript: Sendable, Equatable {
    public let shellPath: String
    public let script: String
    public let inputPaths: [String]
    public let outputPaths: [String]
    public let inputFileListPaths: [String]
    public let outputFileListPaths: [String]
    public let alwaysOutOfDate: Bool
    public let showEnvVarsInLog: Bool
}

public struct BuildFile: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        /// A `PBXFileReference`, `PBXVariantGroup` or `PBXReferenceProxy`.
        case reference(String)
        /// An `XCSwiftPackageProductDependency`.
        case packageProduct(String)
    }
    public let id: String
    public let item: Item
    /// `settings.ATTRIBUTES` (CodeSignOnCopy, RemoveHeadersOnCopy, Weak, Public, Private, Project).
    public let attributes: [String]
    /// `settings.COMPILER_FLAGS`.
    public let compilerFlags: String?
}

public struct TargetDependency: Sendable, Equatable {
    public enum Location: Sendable, Equatable {
        /// A target of the same project.
        case local(targetID: String)
        /// A target of another project, through a project file reference (`containerPortal`).
        case remote(projectFileID: String, targetID: String)
    }
    public let id: String
    public let name: String?
    public let location: Location
}

public struct PackageReference: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case remote(url: String, requirement: [String: String])
        case local(path: String)
    }
    public let id: String
    public let kind: Kind

    /// SwiftPM's package identity: the last path component of the URL or path, lowercased, without `.git`.
    public var identity: String {
        let s: String
        switch kind {
        case .remote(let url, _): s = url
        case .local(let path): s = path
        }
        var last = s.split(separator: "/").last.map(String.init) ?? s
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.lowercased()
    }
}

public struct PackageProductDependency: Sendable, Equatable {
    public let id: String
    public let productName: String
    /// The `XCRemoteSwiftPackageReference`/`XCLocalSwiftPackageReference` object ID.
    public let packageID: String?
}

// MARK: - Loading

extension XcodeProject {
    /// Reads `<path>/project.pbxproj`. `path` is the `.xcodeproj` directory.
    public static func load(_ path: URL) throws -> XcodeProject {
        let path = path.standardizedFileURL
        let file = path.appendingPathComponent("project.pbxproj")
        let data: Data
        do { data = try PlainFile.read(file, followsLinks: true) } catch {
            throw XlessError(.prepare, "cannot read \(file.path): it \(error.reason)",
                             fix: "check that the workspace's projects exist (run expo prebuild and pod install first)")
        }
        let root = try OpenStepPlist.parse(data, file: file.path)
        return try Loader(root: root, path: path, file: file.path).load()
    }
}

/// Builds the typed model from the raw pbxproj objects, refusing anything outside the supported subset.
private struct Loader {
    typealias Object = [String: PlistValue]
    let objects: [String: Object]
    let rootID: String
    let path: URL
    let file: String

    init(root: PlistValue, path: URL, file: String) throws {
        self.path = path
        self.file = file
        guard let top = root.dict, let objects = top["objects"]?.dict, let rootID = top["rootObject"]?.string else {
            throw XlessError(.prepare, "\(file) has no objects/rootObject", fix: "the file must be an Xcode project file")
        }
        var objs: [String: Object] = [:]
        for (id, v) in objects {
            guard let o = v.dict else {
                throw XlessError(.prepare, "unsupported pbxproj value at \(id) in \(file)", fix: Self.fix)
            }
            objs[id] = o
        }
        self.objects = objs
        self.rootID = rootID
    }

    static let fix = "xless builds the project subset that React Native, Expo and CocoaPods generate; remove or replace this " +
        "construct, or build this project on a Mac"

    func unsupported(_ what: String, at id: String) -> XlessError {
        XlessError(.prepare, "unsupported pbxproj \(what) at \(id) in \(file)", fix: Self.fix)
    }

    /// Keys accepted per isa: those that matter are read below; the rest are editor-only state.
    static let allowedKeys: [String: Set<String>] = [
        "PBXProject": ["isa", "attributes", "buildConfigurationList", "compatibilityVersion", "developmentRegion",
                       "hasScannedForEncodings", "knownRegions", "mainGroup", "minimizedProjectReferenceProxies",
                       "packageReferences", "preferredProjectObjectVersion", "productRefGroup", "projectDirPath",
                       "projectReferences", "projectRoot", "targets"],
        "PBXNativeTarget": ["isa", "buildConfigurationList", "buildPhases", "buildRules", "dependencies", "name",
                            "packageProductDependencies", "productName", "productReference", "productType",
                            "productInstallPath"],
        "PBXAggregateTarget": ["isa", "buildConfigurationList", "buildPhases", "dependencies", "name",
                               "packageProductDependencies", "productName"],
        "XCConfigurationList": ["isa", "buildConfigurations", "defaultConfigurationIsVisible", "defaultConfigurationName"],
        "XCBuildConfiguration": ["isa", "baseConfigurationReference", "buildSettings", "name"],
        "PBXGroup": ["isa", "children", "name", "path", "sourceTree", "indentWidth", "tabWidth", "usesTabs",
                     "wrapsLines", "comments"],
        "PBXVariantGroup": ["isa", "children", "name", "path", "sourceTree", "indentWidth", "tabWidth", "usesTabs"],
        "PBXFileReference": ["isa", "explicitFileType", "fileEncoding", "includeInIndex", "indentWidth",
                             "lastKnownFileType", "lineEnding", "name", "path", "sourceTree", "tabWidth", "usesTabs",
                             "wrapsLines", "xcLanguageSpecificationIdentifier", "plistStructureDefinitionIdentifier",
                             "comments"],
        "PBXReferenceProxy": ["isa", "fileType", "name", "path", "remoteRef", "sourceTree"],
        "PBXBuildFile": ["isa", "fileRef", "productRef", "settings"],
        "PBXSourcesBuildPhase": ["isa", "buildActionMask", "files", "runOnlyForDeploymentPostprocessing", "name"],
        "PBXFrameworksBuildPhase": ["isa", "buildActionMask", "files", "runOnlyForDeploymentPostprocessing", "name"],
        "PBXResourcesBuildPhase": ["isa", "buildActionMask", "files", "runOnlyForDeploymentPostprocessing", "name"],
        "PBXHeadersBuildPhase": ["isa", "buildActionMask", "files", "runOnlyForDeploymentPostprocessing", "name"],
        "PBXCopyFilesBuildPhase": ["isa", "buildActionMask", "dstPath", "dstSubfolderSpec", "files", "name",
                                   "runOnlyForDeploymentPostprocessing"],
        "PBXShellScriptBuildPhase": ["isa", "alwaysOutOfDate", "buildActionMask", "files", "inputFileListPaths",
                                     "inputPaths", "name", "outputFileListPaths", "outputPaths",
                                     "runOnlyForDeploymentPostprocessing", "shellPath", "shellScript",
                                     "showEnvVarsInLog"],
        "PBXTargetDependency": ["isa", "name", "target", "targetProxy"],
        "PBXContainerItemProxy": ["isa", "containerPortal", "proxyType", "remoteGlobalIDString", "remoteInfo"],
        "XCRemoteSwiftPackageReference": ["isa", "repositoryURL", "requirement"],
        "XCLocalSwiftPackageReference": ["isa", "relativePath"],
        "XCSwiftPackageProductDependency": ["isa", "package", "productName"],
    ]

    func object(_ id: String, isa expected: Set<String>) throws -> (isa: String, fields: Object) {
        guard let o = objects[id] else {
            throw XlessError(.prepare, "\(file) refers to a missing object \(id)",
                             fix: "the project file is damaged; regenerate it (expo prebuild, pod install)")
        }
        guard let isa = o["isa"]?.string else { throw unsupported("object without isa", at: id) }
        guard let allowed = Self.allowedKeys[isa], expected.contains(isa) else { throw unsupported(isa, at: id) }
        for key in o.keys.sorted() where !allowed.contains(key) {
            throw unsupported("\(isa) key \(key)", at: id)
        }
        return (isa, o)
    }

    func string(_ o: Object, _ key: String, at id: String) throws -> String? {
        guard let v = o[key] else { return nil }
        guard let s = v.string else { throw unsupported("value of \(key)", at: id) }
        return s
    }

    func strings(_ o: Object, _ key: String, at id: String) throws -> [String] {
        guard let v = o[key] else { return [] }
        guard let a = v.array else { throw unsupported("value of \(key)", at: id) }
        return try a.map { item in
            guard let s = item.string else { throw unsupported("value of \(key)", at: id) }
            return s
        }
    }

    func flag(_ o: Object, _ key: String, at id: String, default value: Bool) throws -> Bool {
        guard let s = try string(o, key, at: id) else { return value }
        switch s {
        case "1", "YES", "true": return true
        case "0", "NO", "false": return false
        default: throw unsupported("value \(key) = \(s)", at: id)
        }
    }

    func load() throws -> XcodeProject {
        let (_, p) = try object(rootID, isa: ["PBXProject"])
        if let root = try string(p, "projectRoot", at: rootID), !root.isEmpty {
            throw unsupported("PBXProject key projectRoot = \(root)", at: rootID)
        }
        let dirPath = try string(p, "projectDirPath", at: rootID) ?? ""
        let base = path.deletingLastPathComponent()
        let directory = dirPath.isEmpty ? base
            : (dirPath.hasPrefix("/") ? URL(fileURLWithPath: dirPath) : base.appendingPathComponent(dirPath)).standardizedFileURL

        guard let mainGroupID = try string(p, "mainGroup", at: rootID) else { throw unsupported("PBXProject without mainGroup", at: rootID) }
        let (configs, defaultConfig) = try configurationList(try string(p, "buildConfigurationList", at: rootID), owner: rootID)

        var fileRefs: [String: FileReference] = [:]
        var proxies: [String: ReferenceProxy] = [:]
        let mainGroup = try group(mainGroupID, fileRefs: &fileRefs, proxies: &proxies)

        // Products of project references (PBXReferenceProxy) live in `projectReferences` product groups, outside the
        // main group tree.
        var projectRefs: [String] = []
        if let refs = p["projectReferences"] {
            guard let list = refs.array else { throw unsupported("value of projectReferences", at: rootID) }
            for entry in list {
                guard let d = entry.dict, let productGroup = d["ProductGroup"]?.string, let ref = d["ProjectRef"]?.string else {
                    throw unsupported("projectReferences entry", at: rootID)
                }
                _ = try group(productGroup, fileRefs: &fileRefs, proxies: &proxies)
                projectRefs.append(ref)
            }
        }

        var packages: [PackageReference] = []
        for id in try strings(p, "packageReferences", at: rootID) {
            packages.append(try packageReference(id))
        }

        var styles: [String: String] = [:]
        if let attrs = p["attributes"]?.dict, let ta = attrs["TargetAttributes"]?.dict {
            for (tid, v) in ta {
                if let s = v.dict?["ProvisioningStyle"]?.string { styles[tid] = s }
            }
        }

        var targets: [Target] = []
        for id in try strings(p, "targets", at: rootID) {
            targets.append(try target(id, fileRefs: &fileRefs, proxies: &proxies))
        }
        // Orphan file references (see `recoveredReferenceIDs`).
        var used: [String] = []
        for c in configs { if let b = c.baseConfigurationID { used.append(b) } }
        for target in targets {
            for c in target.configurations { if let b = c.baseConfigurationID { used.append(b) } }
            for phase in target.phases {
                for f in phase.files { if case .reference(let id) = f.item { used.append(id) } }
            }
        }
        var inTree = Set<String>()
        func collect(_ g: Group) {
            inTree.insert(g.id)
            for c in g.children { if case .group(let sub) = c { collect(sub) } else { inTree.insert(c.id) } }
        }
        collect(mainGroup)
        var recovered: [String] = []
        for id in Set(used).sorted() where fileRefs[id] == nil && proxies[id] == nil && !inTree.contains(id) {
            guard objects[id]?["isa"]?.string == "PBXFileReference" else {
                _ = try object(id, isa: ["PBXFileReference"])  // throws the unsupported/missing-object error
                continue
            }
            fileRefs[id] = try fileReference(id)
            recovered.append(id)
        }
        let name = path.deletingPathExtension().lastPathComponent
        return XcodeProject(
            name: name, path: path, directory: directory, rootID: rootID, mainGroup: mainGroup,
            configurations: configs, defaultConfigurationName: defaultConfig,
            developmentRegion: try string(p, "developmentRegion", at: rootID),
            knownRegions: try strings(p, "knownRegions", at: rootID),
            targets: targets, packageReferences: packages, fileReferences: fileRefs, referenceProxies: proxies,
            provisioningStyles: styles, projectReferenceIDs: projectRefs, recoveredReferenceIDs: recovered)
    }

    func configurationList(_ id: String?, owner: String) throws -> ([BuildConfiguration], String) {
        guard let id else { throw unsupported("missing buildConfigurationList", at: owner) }
        let (_, list) = try object(id, isa: ["XCConfigurationList"])
        var configs: [BuildConfiguration] = []
        for cid in try strings(list, "buildConfigurations", at: id) {
            let (_, c) = try object(cid, isa: ["XCBuildConfiguration"])
            guard let name = try string(c, "name", at: cid) else { throw unsupported("XCBuildConfiguration without name", at: cid) }
            var settings: [String: String] = [:]
            if let bs = c["buildSettings"] {
                guard let d = bs.dict else { throw unsupported("value of buildSettings", at: cid) }
                for (k, v) in d {
                    switch v {
                    case .string(let s): settings[k] = s
                    case .array(let items):
                        settings[k] = try items.map { item -> String in
                            guard let s = item.string else { throw unsupported("build setting \(k) value", at: cid) }
                            return s
                        }.joined(separator: " ")
                    case .dict: throw unsupported("build setting \(k) value", at: cid)
                    }
                }
            }
            let base = try string(c, "baseConfigurationReference", at: cid)
            configs.append(BuildConfiguration(id: cid, name: name, settings: settings, baseConfigurationID: base))
        }
        guard !configs.isEmpty else { throw unsupported("empty XCConfigurationList", at: id) }
        let def = try string(list, "defaultConfigurationName", at: id) ?? configs[0].name
        return (configs, def)
    }

    func group(_ id: String, fileRefs: inout [String: FileReference], proxies: inout [String: ReferenceProxy]) throws -> Group {
        let (isa, g) = try object(id, isa: ["PBXGroup", "PBXVariantGroup"])
        var children: [GroupItem] = []
        for cid in try strings(g, "children", at: id) {
            guard let child = objects[cid] else {
                throw XlessError(.prepare, "\(file) refers to a missing object \(cid)",
                                 fix: "the project file is damaged; regenerate it (expo prebuild, pod install)")
            }
            switch child["isa"]?.string {
            case "PBXGroup", "PBXVariantGroup":
                children.append(.group(try group(cid, fileRefs: &fileRefs, proxies: &proxies)))
            case "PBXFileReference":
                let f = try fileReference(cid)
                fileRefs[cid] = f
                children.append(.file(f))
            case "PBXReferenceProxy":
                proxies[cid] = try referenceProxy(cid)
            case let other:
                throw unsupported(other ?? "object without isa", at: cid)
            }
        }
        return Group(id: id, name: try string(g, "name", at: id), path: try string(g, "path", at: id),
                     sourceTree: try sourceTree(g, at: id), children: children, isVariantGroup: isa == "PBXVariantGroup")
    }

    static let sourceTrees: Set<String> = ["<group>", "<absolute>", "SOURCE_ROOT", "BUILT_PRODUCTS_DIR", "SDKROOT",
                                           "DEVELOPER_DIR", "PLATFORM_DIR"]

    func sourceTree(_ o: Object, at id: String) throws -> String {
        let tree = try string(o, "sourceTree", at: id) ?? "<group>"
        guard Self.sourceTrees.contains(tree) else { throw unsupported("sourceTree \(tree)", at: id) }
        return tree
    }

    func fileReference(_ id: String) throws -> FileReference {
        let (_, f) = try object(id, isa: ["PBXFileReference"])
        let name = try string(f, "name", at: id)
        guard let path = try string(f, "path", at: id) ?? name else { throw unsupported("PBXFileReference without path", at: id) }
        let explicit = try string(f, "explicitFileType", at: id)
        let lastKnown = try string(f, "lastKnownFileType", at: id)
        let type = [explicit, lastKnown].compactMap { $0 }.first(where: FileTypes.isKnown)
            ?? FileTypes.infer(path: path)
        var encoding: String?
        switch try string(f, "fileEncoding", at: id) {
        case "4": encoding = "utf-8"
        case "10": encoding = "utf-16"
        default: encoding = nil
        }
        return FileReference(id: id, name: name, path: path, sourceTree: try sourceTree(f, at: id), fileType: type,
                             textEncoding: encoding)
    }

    func referenceProxy(_ id: String) throws -> ReferenceProxy {
        let (_, r) = try object(id, isa: ["PBXReferenceProxy"])
        guard let path = try string(r, "path", at: id), let remote = try string(r, "remoteRef", at: id) else {
            throw unsupported("PBXReferenceProxy without path/remoteRef", at: id)
        }
        let (portal, remoteID) = try containerProxy(remote, expectedType: "2")
        return ReferenceProxy(id: id, path: path, fileType: try string(r, "fileType", at: id) ?? FileTypes.infer(path: path),
                              containerPortalID: portal, remoteProductID: remoteID)
    }

    /// `(containerPortal, remoteGlobalIDString)` of a `PBXContainerItemProxy`.
    func containerProxy(_ id: String, expectedType: String) throws -> (String, String) {
        let (_, c) = try object(id, isa: ["PBXContainerItemProxy"])
        guard let portal = try string(c, "containerPortal", at: id), let remote = try string(c, "remoteGlobalIDString", at: id) else {
            throw unsupported("PBXContainerItemProxy without containerPortal/remoteGlobalIDString", at: id)
        }
        let type = try string(c, "proxyType", at: id) ?? expectedType
        guard type == expectedType else { throw unsupported("PBXContainerItemProxy proxyType \(type)", at: id) }
        return (portal, remote)
    }

    func packageReference(_ id: String) throws -> PackageReference {
        let (isa, o) = try object(id, isa: ["XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference"])
        if isa == "XCLocalSwiftPackageReference" {
            guard let rel = try string(o, "relativePath", at: id) else { throw unsupported("\(isa) without relativePath", at: id) }
            return PackageReference(id: id, kind: .local(path: rel))
        }
        guard let url = try string(o, "repositoryURL", at: id) else { throw unsupported("\(isa) without repositoryURL", at: id) }
        var requirement: [String: String] = [:]
        if let r = o["requirement"] {
            guard let d = r.dict else { throw unsupported("value of requirement", at: id) }
            for (k, v) in d {
                guard let s = v.string else { throw unsupported("requirement \(k)", at: id) }
                requirement[k] = s
            }
        }
        return PackageReference(id: id, kind: .remote(url: url, requirement: requirement))
    }

    static let supportedProductTypes: Set<String> = [
        "com.apple.product-type.application", "com.apple.product-type.app-extension",
        "com.apple.product-type.framework", "com.apple.product-type.library.static",
        "com.apple.product-type.library.dynamic", "com.apple.product-type.bundle",
    ]

    func target(_ id: String, fileRefs: inout [String: FileReference], proxies: inout [String: ReferenceProxy]) throws -> Target {
        let (isa, t) = try object(id, isa: ["PBXNativeTarget", "PBXAggregateTarget"])
        guard let name = try string(t, "name", at: id) else { throw unsupported("\(isa) without name", at: id) }
        let kind: Target.Kind
        var productRef: String?
        if isa == "PBXNativeTarget" {
            guard let type = try string(t, "productType", at: id) else { throw unsupported("PBXNativeTarget without productType", at: id) }
            guard Self.supportedProductTypes.contains(type) else { throw unsupported("productType \(type)", at: id) }
            kind = .native(productType: type)
            if !(try strings(t, "buildRules", at: id)).isEmpty { throw unsupported("PBXNativeTarget buildRules (PBXBuildRule)", at: id) }
            productRef = try string(t, "productReference", at: id)
            if let pr = productRef, fileRefs[pr] == nil {
                fileRefs[pr] = try fileReference(pr)  // product references may sit outside the main group
            }
        } else {
            kind = .aggregate
        }
        let (configs, def) = try configurationList(try string(t, "buildConfigurationList", at: id), owner: id)
        var phases: [BuildPhase] = []
        for pid in try strings(t, "buildPhases", at: id) {
            phases.append(try buildPhase(pid))
        }
        var deps: [TargetDependency] = []
        for did in try strings(t, "dependencies", at: id) {
            deps.append(try dependency(did))
        }
        var products: [PackageProductDependency] = []
        for pid in try strings(t, "packageProductDependencies", at: id) {
            products.append(try packageProduct(pid))
        }
        return Target(id: id, name: name, kind: kind, configurations: configs, defaultConfigurationName: def,
                      phases: phases, dependencies: deps, productReferenceID: productRef, packageProducts: products)
    }

    func packageProduct(_ id: String) throws -> PackageProductDependency {
        let (_, o) = try object(id, isa: ["XCSwiftPackageProductDependency"])
        guard let product = try string(o, "productName", at: id) else { throw unsupported("XCSwiftPackageProductDependency without productName", at: id) }
        return PackageProductDependency(id: id, productName: product, packageID: try string(o, "package", at: id))
    }

    func dependency(_ id: String) throws -> TargetDependency {
        let (_, d) = try object(id, isa: ["PBXTargetDependency"])
        let name = try string(d, "name", at: id)
        if let proxy = try string(d, "targetProxy", at: id) {
            let (portal, remote) = try containerProxy(proxy, expectedType: "1")
            if portal == rootID { return TargetDependency(id: id, name: name, location: .local(targetID: remote)) }
            return TargetDependency(id: id, name: name, location: .remote(projectFileID: portal, targetID: remote))
        }
        if let target = try string(d, "target", at: id) {
            return TargetDependency(id: id, name: name, location: .local(targetID: target))
        }
        throw unsupported("PBXTargetDependency without target/targetProxy", at: id)
    }

    /// `dstSubfolderSpec` → PIF `destinationSubfolder`, as `xcodebuild -dumpPIF` maps them (0 = absolute: the
    /// subfolder is empty and `dstPath` is the absolute subpath).
    static let copyDestinations: [String: String] = [
        "0": "", "1": "$(WRAPPER_NAME)", "6": "$(EXECUTABLE_FOLDER_PATH)", "7": "$(UNLOCALIZED_RESOURCES_FOLDER_PATH)",
        "10": "$(FRAMEWORKS_FOLDER_PATH)", "11": "$(SHARED_FRAMEWORKS_FOLDER_PATH)",
        "12": "$(SHARED_SUPPORT_FOLDER_PATH)", "13": "$(PLUGINS_FOLDER_PATH)", "15": "$(JAVA_FOLDER_PATH)",
        "16": "<builtProductsDir>",
    ]

    func buildPhase(_ id: String) throws -> BuildPhase {
        let (isa, o) = try object(id, isa: ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase",
                                            "PBXHeadersBuildPhase", "PBXCopyFilesBuildPhase", "PBXShellScriptBuildPhase"])
        let installOnly = try flag(o, "runOnlyForDeploymentPostprocessing", at: id, default: false)
        let kind: BuildPhase.Kind
        switch isa {
        case "PBXSourcesBuildPhase": kind = .sources
        case "PBXFrameworksBuildPhase": kind = .frameworks
        case "PBXResourcesBuildPhase": kind = .resources
        case "PBXHeadersBuildPhase": kind = .headers
        case "PBXCopyFilesBuildPhase":
            let spec = try string(o, "dstSubfolderSpec", at: id) ?? "16"
            guard let folder = Self.copyDestinations[spec] else { throw unsupported("dstSubfolderSpec \(spec)", at: id) }
            kind = .copyFiles(destinationSubfolder: folder, destinationSubpath: try string(o, "dstPath", at: id) ?? "")
        default:
            kind = .shellScript(ShellScript(
                shellPath: try string(o, "shellPath", at: id) ?? "/bin/sh",
                script: try string(o, "shellScript", at: id) ?? "",
                inputPaths: try strings(o, "inputPaths", at: id),
                outputPaths: try strings(o, "outputPaths", at: id),
                inputFileListPaths: try strings(o, "inputFileListPaths", at: id),
                outputFileListPaths: try strings(o, "outputFileListPaths", at: id),
                alwaysOutOfDate: try flag(o, "alwaysOutOfDate", at: id, default: false),
                showEnvVarsInLog: try flag(o, "showEnvVarsInLog", at: id, default: true)))
        }
        if installOnly {
            switch kind {
            case .copyFiles, .shellScript: break
            default: throw unsupported("\(isa) runOnlyForDeploymentPostprocessing = 1", at: id)
            }
        }
        var files: [BuildFile] = []
        for fid in try strings(o, "files", at: id) {
            files.append(try buildFile(fid))
        }
        if case .shellScript = kind, !files.isEmpty { throw unsupported("PBXShellScriptBuildPhase files", at: id) }
        return BuildPhase(id: id, kind: kind, name: try string(o, "name", at: id), files: files,
                          runOnlyForDeploymentPostprocessing: installOnly)
    }

    static let attributes: Set<String> = ["CodeSignOnCopy", "RemoveHeadersOnCopy", "Weak", "Public", "Private", "Project", "Required"]

    func buildFile(_ id: String) throws -> BuildFile {
        let (_, o) = try object(id, isa: ["PBXBuildFile"])
        let item: BuildFile.Item
        if let ref = try string(o, "fileRef", at: id) {
            item = .reference(ref)
        } else if let product = try string(o, "productRef", at: id) {
            item = .packageProduct(product)
        } else {
            throw unsupported("PBXBuildFile without fileRef/productRef", at: id)
        }
        var attributes: [String] = []
        var flags: String?
        if let s = o["settings"] {
            guard let d = s.dict else { throw unsupported("value of settings", at: id) }
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                switch k {
                case "ATTRIBUTES":
                    guard let a = v.array else { throw unsupported("value of settings.ATTRIBUTES", at: id) }
                    for x in a {
                        guard let s = x.string, Self.attributes.contains(s) else {
                            throw unsupported("PBXBuildFile attribute \(x.string ?? "?")", at: id)
                        }
                        attributes.append(s)
                    }
                case "COMPILER_FLAGS":
                    guard let s = v.string else { throw unsupported("value of settings.COMPILER_FLAGS", at: id) }
                    flags = s
                default:
                    throw unsupported("PBXBuildFile settings key \(k)", at: id)
                }
            }
        }
        return BuildFile(id: id, item: item, attributes: attributes, compilerFlags: flags)
    }
}
