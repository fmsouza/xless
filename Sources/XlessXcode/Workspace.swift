import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XlessCore

/// An Xcode workspace: its projects (in `contents.xcworkspacedata` order) and its shared schemes.
public struct Workspace: Sendable {
    public let name: String
    /// The `.xcworkspace` directory; for a bare project, `<project>.xcodeproj/project.xcworkspace` (as Xcode).
    public let path: URL
    public let projects: [XcodeProject]
    /// Shared schemes of the workspace and of every project (`xcshareddata/xcschemes/*.xcscheme`).
    public let schemes: [Scheme]

    public func project(at path: URL) -> XcodeProject? {
        let p = path.standardizedFileURL.path
        return projects.first { $0.path.path == p }
    }

    public func scheme(named name: String) throws -> Scheme {
        guard let s = schemes.first(where: { $0.name == name }) else {
            let known = schemes.map(\.name).sorted().joined(separator: ", ")
            throw XlessError(.prepare, "no shared scheme \(name) in \(path.lastPathComponent) (shared schemes: \(known.isEmpty ? "none" : known))",
                             fix: "name a shared scheme (xcshareddata/xcschemes); Expo prebuild shares the app's scheme")
        }
        return s
    }

    /// The scheme's build-action targets that are built for `action`, resolved to their projects.
    public func buildTargets(of scheme: Scheme, for action: SchemeAction = .running) throws -> [(project: XcodeProject, target: Target)] {
        var out: [(XcodeProject, Target)] = []
        for entry in scheme.entries where entry.builds(for: action) {
            guard let project = project(at: entry.container) else {
                throw XlessError(.prepare, "scheme \(scheme.name) builds \(entry.blueprintName) from \(entry.container.lastPathComponent), which is not in \(path.lastPathComponent)",
                                 fix: "add the project to the workspace or fix the scheme's ReferencedContainer")
            }
            guard let target = project.target(id: entry.blueprintIdentifier) ?? project.target(named: entry.blueprintName) else {
                throw XlessError(.prepare, "scheme \(scheme.name) builds \(entry.blueprintName) (\(entry.blueprintIdentifier)), which is not a target of \(project.name)",
                                 fix: "re-share the scheme in Xcode or regenerate the project (expo prebuild)")
            }
            out.append((project, target))
        }
        guard !out.isEmpty else {
            throw XlessError(.prepare, "scheme \(scheme.name) builds no target for \(action.rawValue)",
                             fix: "check the scheme's Build action entries")
        }
        return out
    }

    /// The project and target that `dependency` (declared in `project`) refers to, if they are in the workspace.
    public func resolve(_ dependency: TargetDependency, in project: XcodeProject) -> (project: XcodeProject, target: Target)? {
        switch dependency.location {
        case .local(let id):
            return project.target(id: id).map { (project, $0) }
        case .remote(let fileID, let id):
            guard let url = project.resolvedPath(of: fileID), let other = self.project(at: url),
                  let t = other.target(id: id) else { return nil }
            return (other, t)
        }
    }
}

public enum SchemeAction: String, Sendable {
    case running, archiving
}

public struct Scheme: Sendable, Equatable {
    public let name: String
    public let buildImplicitDependencies: Bool
    public let parallelizeBuildables: Bool
    public let entries: [BuildActionEntry]
    public let launchConfiguration: String?
    public let archiveConfiguration: String?
}

public struct BuildActionEntry: Sendable, Equatable {
    public let blueprintIdentifier: String
    public let blueprintName: String
    public let buildableName: String
    /// The `.xcodeproj` that `ReferencedContainer` names, resolved.
    public let container: URL
    public let buildForRunning: Bool
    public let buildForArchiving: Bool

    func builds(for action: SchemeAction) -> Bool {
        switch action {
        case .running: buildForRunning
        case .archiving: buildForArchiving
        }
    }
}

public enum XcodeWorkspace {
    /// Loads a `.xcworkspace` (every project it lists) or a single `.xcodeproj`, with their shared schemes.
    public static func load(_ url: URL) throws -> Workspace {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw XlessError(.prepare, "no Xcode workspace or project at \(url.path)",
                             fix: "run expo prebuild and pod install first, or point at the .xcworkspace")
        }
        switch url.pathExtension {
        case "xcodeproj":
            let (projects, schemes) = try loadProjects([url])
            return Workspace(name: projects[0].name, path: url.appendingPathComponent("project.xcworkspace"),
                             projects: projects, schemes: schemes)
        case "xcworkspace":
            let contents = url.appendingPathComponent("contents.xcworkspacedata")
            let root = try XMLTree.parse(file: contents)
            guard root.name == "Workspace" else {
                throw XlessError(.prepare, "\(contents.path) is not a workspace", fix: "regenerate it (pod install)")
            }
            let container = url.deletingLastPathComponent()
            var projectURLs: [URL] = []
            try collectProjects(root, groupDir: container, container: container, file: contents.path, into: &projectURLs)
            let (projects, schemes) = try loadProjects(projectURLs)
            let own = try loadSchemes(in: url.appendingPathComponent("xcshareddata/xcschemes"), base: container)
            return Workspace(name: url.deletingPathExtension().lastPathComponent, path: url, projects: projects,
                             schemes: own + schemes)
        default:
            throw XlessError(.prepare, "\(url.lastPathComponent) is neither an .xcworkspace nor an .xcodeproj",
                             fix: "point at the app's .xcworkspace (Expo/CocoaPods) or .xcodeproj")
        }
    }

    /// Loads `urls` and, like Xcode's PIF (which lists nested projects flat), the projects they reference through
    /// `projectReferences`; with each project's shared schemes.
    static func loadProjects(_ urls: [URL]) throws -> ([XcodeProject], [Scheme]) {
        var projects: [XcodeProject] = []
        var schemes: [Scheme] = []
        var queue = urls
        while !queue.isEmpty {
            let p = queue.removeFirst()
            guard !projects.contains(where: { $0.path == p }) else { continue }
            let project = try XcodeProject.load(p)
            projects.append(project)
            schemes += try loadSchemes(in: p.appendingPathComponent("xcshareddata/xcschemes"), base: p.deletingLastPathComponent())
            queue += project.projectReferenceIDs.compactMap { project.resolvedPath(of: $0) }
        }
        return (projects, schemes)
    }

    /// Resolves a workspace `location` (`group:`, `container:`, `absolute:`).
    static func resolve(location: String, groupDir: URL, container: URL, file: String) throws -> URL {
        guard let colon = location.firstIndex(of: ":") else {
            throw XlessError(.prepare, "unsupported workspace location \(location) in \(file)", fix: "use group: or container: locations")
        }
        let kind = location[..<colon]
        let rest = String(location[location.index(after: colon)...])
        switch kind {
        case "group": return (rest.isEmpty ? groupDir : groupDir.appendingPathComponent(rest)).standardizedFileURL
        case "container": return (rest.isEmpty ? container : container.appendingPathComponent(rest)).standardizedFileURL
        case "absolute": return URL(fileURLWithPath: rest).standardizedFileURL
        default:
            throw XlessError(.prepare, "unsupported workspace location \(location) in \(file)", fix: "use group: or container: locations")
        }
    }

    static func collectProjects(_ node: XMLTree, groupDir: URL, container: URL, file: String, into out: inout [URL]) throws {
        for child in node.children {
            switch child.name {
            case "FileRef":
                guard let loc = child.attributes["location"] else { continue }
                let u = try resolve(location: loc, groupDir: groupDir, container: container, file: file)
                if u.pathExtension == "xcodeproj" { out.append(u) }
            case "Group":
                let dir = try child.attributes["location"].map {
                    try resolve(location: $0, groupDir: groupDir, container: container, file: file)
                } ?? groupDir
                try collectProjects(child, groupDir: dir, container: container, file: file, into: &out)
            default:
                throw XlessError(.prepare, "unsupported workspace element <\(child.name)> in \(file)",
                                 fix: "the workspace may list projects (FileRef) and groups only")
            }
        }
    }

    static func loadSchemes(in dir: URL, base: URL) throws -> [Scheme] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return try names.filter { $0.hasSuffix(".xcscheme") }.sorted().map {
            try parseScheme(dir.appendingPathComponent($0), base: base)
        }
    }

    /// Parses an `.xcscheme`. `ReferencedContainer` paths (`container:X.xcodeproj`) are relative to `base`, the
    /// directory holding the `.xcodeproj`/`.xcworkspace` that stores the scheme.
    public static func parseScheme(_ url: URL, base: URL) throws -> Scheme {
        let root = try XMLTree.parse(file: url)
        let name = url.deletingPathExtension().lastPathComponent
        func yes(_ v: String?, default d: Bool) -> Bool { v.map { $0 == "YES" } ?? d }
        let build = root.child("BuildAction")
        var entries: [BuildActionEntry] = []
        for e in build?.child("BuildActionEntries")?.children ?? [] where e.name == "BuildActionEntry" {
            guard let ref = e.child("BuildableReference"),
                  let id = ref.attributes["BlueprintIdentifier"], let container = ref.attributes["ReferencedContainer"] else {
                throw XlessError(.prepare, "scheme \(url.path) has a build entry without a BuildableReference",
                                 fix: "re-share the scheme in Xcode")
            }
            entries.append(BuildActionEntry(
                blueprintIdentifier: id, blueprintName: ref.attributes["BlueprintName"] ?? "",
                buildableName: ref.attributes["BuildableName"] ?? "",
                container: try resolve(location: container, groupDir: base, container: base, file: url.path),
                buildForRunning: yes(e.attributes["buildForRunning"], default: true),
                buildForArchiving: yes(e.attributes["buildForArchiving"], default: true)))
        }
        return Scheme(name: name,
                      buildImplicitDependencies: yes(build?.attributes["buildImplicitDependencies"], default: true),
                      parallelizeBuildables: yes(build?.attributes["parallelizeBuildables"], default: true),
                      entries: entries,
                      launchConfiguration: root.child("LaunchAction")?.attributes["buildConfiguration"],
                      archiveConfiguration: root.child("ArchiveAction")?.attributes["buildConfiguration"])
    }
}

extension XcodeProject {
    /// The absolute path of a file reference in this project, when it resolves to the file system (`<group>`,
    /// `SOURCE_ROOT` or absolute source trees); nil for build-setting-relative references.
    public func resolvedPath(of fileRefID: String) -> URL? {
        func walk(_ g: Group, dir: URL?) -> URL? {
            for child in g.children {
                switch child {
                case .file(let f) where f.id == fileRefID:
                    return Self.resolve(f.path, tree: f.sourceTree, parent: dir, project: directory)
                case .group(let sub):
                    if let found = walk(sub, dir: Self.resolve(sub.path ?? "", tree: sub.sourceTree, parent: dir, project: directory)) {
                        return found
                    }
                default: continue
                }
            }
            return nil
        }
        if recoveredReferenceIDs.contains(fileRefID), let f = fileReferences[fileRefID] {
            return Self.resolve(f.path, tree: f.sourceTree, parent: directory, project: directory)
        }
        return walk(mainGroup, dir: Self.resolve(mainGroup.path ?? "", tree: mainGroup.sourceTree, parent: directory, project: directory))
    }

    static func resolve(_ path: String, tree: String, parent: URL?, project: URL) -> URL? {
        switch tree {
        case "<group>": return parent.map { (path.isEmpty ? $0 : $0.appendingPathComponent(path)).standardizedFileURL }
        case "SOURCE_ROOT": return (path.isEmpty ? project : project.appendingPathComponent(path)).standardizedFileURL
        case "<absolute>": return URL(fileURLWithPath: path).standardizedFileURL
        default: return nil
        }
    }
}

/// A minimal element tree over `XMLParser`, for workspace and scheme files.
struct XMLTree {
    var name: String
    var attributes: [String: String]
    var children: [XMLTree] = []

    func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }

    static func parse(file: URL) throws -> XMLTree {
        let data: Data
        do { data = try PlainFile.read(file, followsLinks: true) } catch {
            throw XlessError(.prepare, "cannot read \(file.path): it \(error.reason)", fix: "check the path")
        }
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = collector.stack.first?.children.first else {
            let msg = parser.parserError?.localizedDescription ?? "no root element"
            throw XlessError(.prepare, "invalid XML in \(file.path) at line \(parser.lineNumber): \(msg)",
                             fix: "re-save it in Xcode or regenerate it (expo prebuild, pod install)")
        }
        return root
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var stack: [XMLTree] = [XMLTree(name: "", attributes: [:])]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(XMLTree(name: elementName, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let done = stack.removeLast()
            stack[stack.count - 1].children.append(done)
        }
    }
}
