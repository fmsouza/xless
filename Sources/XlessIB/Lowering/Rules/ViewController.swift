import Foundation
import XlessCore

/// The view controller nib `UIViewController-<vcID>.nib` (docs/research/nib-encoding.md, section 6 "View controller nib").
/// It depends only on the two IDs: every golden with VC `01J-lp-oVM` and view `Ze5-6b-2t3` has the same bytes;
/// `id-different-ids` and `id-long-ids` prove the IDs are used verbatim.
///
/// A `storyboardIdentifier` (Expo's `SplashScreenViewController`) names the nib and its `Info.plist` entries instead of
/// `UIViewController-<vcID>` and adds `UIStoryboardIdentifier` = @the identifier to the class swapper, after `UINibName`
/// (`vc-storyboard-identifier`, `-short`, `-punct`; `-shared`: "UIViewController" is one string object with
/// `UIClassName`).
enum ViewControllerRule {
    static let knownAttributes: Set<String> = ["id", "sceneMemberID", "storyboardIdentifier"]

    /// The view controller's `storyboardIdentifier`, nil without one. It becomes a file name and a string in two
    /// archives, so only what was compiled with ibtool is accepted (`vc-storyboard-identifier`, `-short`, `-punct`:
    /// letters, digits, space, ".", "_", "-" and "+"), at most `maxStoryboardIdentifierLength` characters. Refused too:
    /// a leading ".", leading or trailing spaces, and a name equal to the view nib's, ignoring case (the nibs share a
    /// directory, and macOS file systems ignore case).
    static func storyboardIdentifier(_ vc: IBViewController, doc: IBDocument) throws -> String? {
        guard let s = vc.attributes["storyboardIdentifier"] else { return nil }
        let line = doc.element(at: vc.rawPath)?.line
        guard !s.isEmpty, s.utf8.count <= maxStoryboardIdentifierLength, s.wholeMatch(of: /[A-Za-z0-9 ._+\-]+/) != nil, !s.hasPrefix("."),
              !s.hasPrefix(" "), !s.hasSuffix(" "),
              s.lowercased() != StoryboardcLayout.viewNibName(vcID: vc.id, viewID: vc.view.id).lowercased() else {
            throw LoweringError.unsupported("storyboardIdentifier \"\(s)\" (verified: 1–\(maxStoryboardIdentifierLength) of A-Z a-z 0-9 space . _ - +, no leading \".\" or surrounding spaces, not the view nib's name)", line: line)
        }
        return s
    }

    /// The longest `storyboardIdentifier` accepted: its length then has the one-byte form in both the nib (a varint
    /// below 128) and the binary Info.plist (an int marker with one byte), the forms the corpus measured (6 and 26
    /// characters; `-short` is below the plist's inline limit of 15).
    static let maxStoryboardIdentifierLength = 127

    static func nib(vcID: String, viewID: String, storyboardIdentifier: String? = nil) throws -> NIBArchive {
        let b = ArchiveBuilder()
        let owner = b.proxy("IBFilesOwner"), responder = b.proxy("IBFirstResponder"), storyboard = b.proxy("UIStoryboardPlaceholder")
        let swapper = b.object("UIClassSwapper")
        let table = b.object("NSDictionary")
        b.set(table, "NSInlinedValue", .bool(true))
        b.set(swapper, "UIExternalObjectsTableForViewLoading", table)
        b.set(swapper, "UINibName", b.string(StoryboardcLayout.viewNibName(vcID: vcID, viewID: viewID)))
        if let storyboardIdentifier { b.set(swapper, "UIStoryboardIdentifier", b.string(storyboardIdentifier)) }
        b.set(swapper, "UIClassName", b.string("UIViewController"))
        b.set(swapper, "UIOriginalClassName", b.string("UIViewController"))
        let objects = [owner, responder, storyboard, swapper]
        let root = b.nibRoot(topLevel: objects, objects: objects, connections: [
            b.outlet("storyboard", source: swapper, destination: storyboard),
            b.outlet("sceneViewController", source: owner, destination: swapper),
        ])
        return try b.finish(root: root)
    }
}

/// Scene-level checks: one scene, its view controller is the initial one, only the first-responder placeholder.
enum SceneRule {
    static let placeholderAttributes: Set<String> = ["placeholderIdentifier", "id", "userLabel", "sceneMemberID", "customClass"]

    static func line(_ doc: IBDocument, _ path: [Int]) -> Int? { doc.element(at: path)?.line }

    static func initialScene(_ doc: IBDocument) throws -> IBScene {
        guard doc.scenes.count == 1, let scene = doc.scenes.first else {
            throw LoweringError.unsupported("storyboard with \(doc.scenes.count) scenes (launch screens have one)", line: doc.scenes.count > 1 ? line(doc, doc.scenes[1].rawPath) : nil)
        }
        let vc = scene.viewController
        guard vc.id == doc.initialViewController else {
            throw LoweringError.unsupported("initialViewController \"\(doc.initialViewController)\" (the scene's view controller is \"\(vc.id)\")", line: doc.raw.line)
        }
        try LoweringError.checkAttributes(vc.attributes, known: ViewControllerRule.knownAttributes, element: "viewController", line: line(doc, vc.rawPath))
        if let raw = doc.element(at: vc.rawPath) {
            if let extra = raw.children.first(where: { $0.name != "view" && $0.name != "layoutGuides" }) {
                throw StoryboardParser.unsupported(extra.name, line: extra.line)   // e.g. <connections>
            }
            // Only the root view (`key="view"`) is in a golden; another view (e.g. `key="inputAccessoryView"`) is refused.
            if let extra = raw.children.filter({ $0.name == "view" }).dropFirst().first {
                throw StoryboardParser.unsupported(extra.name, line: extra.line)
            }
            // Legacy top/bottom guides change nothing without safe areas (`core-legacy-layoutguides`); with them, untested.
            if let guides = raw.children.first(where: { $0.name == "layoutGuides" }) {
                if doc.useSafeAreas || vc.view.safeArea != nil {
                    throw LoweringError.unsupported("<layoutGuides> with safe area layout guides", line: guides.line)
                }
                for g in guides.children {
                    try LoweringError.checkAttributes(g.attributes, known: ["type", "id"], element: g.name, line: g.line)
                    guard ["top", "bottom"].contains(g.attributes["type"] ?? "") else {
                        throw LoweringError.unsupported("<\(g.name) type=\"\(g.attributes["type"] ?? "")\">", line: g.line)
                    }
                }
            }
        }
        for p in scene.placeholders {
            let l = line(doc, p.rawPath)
            try LoweringError.checkAttributes(p.attributes, known: placeholderAttributes, element: "placeholder", line: l)
            guard p.attributes["placeholderIdentifier"] == "IBFirstResponder" else {
                throw LoweringError.unsupported("placeholder \"\(p.attributes["placeholderIdentifier"] ?? "")\"", line: l)
            }
            if let c = p.attributes["customClass"], c != "UIResponder" {
                throw LoweringError.unsupported("first responder customClass \"\(c)\"", line: l)
            }
            if let raw = doc.element(at: p.rawPath), let child = raw.children.first {
                throw StoryboardParser.unsupported(child.name, line: child.line)
            }
        }
        guard vc.view.key == "view" else {
            throw LoweringError.unsupported("root view key \"\(vc.view.key ?? "")\"", line: vc.view.line)
        }
        return scene
    }

    /// IDs become file names and plist strings; only printable ASCII without `/` was verified.
    static func checkIdentifier(_ id: String, doc: IBDocument, path: [Int]) throws {
        guard !id.isEmpty, id.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != 0x2F }) else {
            throw LoweringError.unsupported("id \"\(id)\" (IDs must be printable ASCII without \"/\")", line: line(doc, path))
        }
    }
}

/// `<document>` attributes, limited to the values the corpus was compiled with (every case has the first seven;
/// `real-tauri-app` lacks `launchScreen`, `core-no-traitcollections` lacks `useTraitCollections`, and the
/// legacy cases lack `useSafeAreas`). `toolsVersion` (23727, 17150 in `real-tauri-app`, 13122.16 in
/// `xcode-template`) does not change the output.
enum DocumentRule {
    static let required: [String: String] = [
        "type": "com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB", "version": "3.0", "targetRuntime": "iOS.CocoaTouch",
        "propertyAccessControl": "none", "useAutolayout": "YES", "colorMatched": "YES",
    ]
    /// Optional attributes: absent, or this value.
    static let optional: [String: String] = ["launchScreen": "YES", "useTraitCollections": "YES", "useSafeAreas": "YES"]

    /// The newest `toolsVersion` xless accepts, whatever the image's Xcode: the one Xcode 27.0 (ibtool bundle-version
    /// 25098) writes (docs/research/ib-invocation.md). A guard against document formats the rules have never seen, not
    /// an ibtool limit: ibtool itself does not check `toolsVersion` (docs/research/xcode-tools-by-version.md).
    static let maxToolsVersion = "25098"

    static func check(_ doc: IBDocument, profile: XcodeToolsProfile) throws {
        try checkCapabilities(doc, profile: profile)
        let a = doc.attributes, line = doc.raw.line
        let known = Set(required.keys).union(optional.keys).union(["toolsVersion", "initialViewController"])
        try LoweringError.checkAttributes(a, known: known, element: "document", line: line)
        for (key, value) in required.sorted(by: { $0.key < $1.key }) {
            guard let v = a[key] else { throw LoweringError.unsupported("<document> without \(key)", line: line) }
            guard v == value else { throw LoweringError.unsupported("<document> \(key)=\"\(v)\" (verified: \(value))", line: line) }
        }
        for (key, value) in optional.sorted(by: { $0.key < $1.key }) {
            if let v = a[key], v != value { throw LoweringError.unsupported("<document> \(key)=\"\(v)\" (verified: \(value) or absent)", line: line) }
        }
        let tools = a["toolsVersion"] ?? ""
        guard !tools.isEmpty, tools.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            throw LoweringError.unsupported("<document> toolsVersion=\"\(tools)\"", line: line)
        }
        guard let v = DottedVersion(tools) else { throw LoweringError.unsupported("<document> toolsVersion=\"\(tools)\"", line: line) }
        if v > DottedVersion(maxToolsVersion)! {
            throw XlessError(.ib, "storyboard was saved by a newer Xcode (toolsVersion \(tools)) than xless supports (\(maxToolsVersion))",
                             fix: "re-save the storyboard with Xcode 27.0 or older, or update xless")
        }
    }

    /// ibtool refuses a document with a capability newer than itself: `<capability … minToolsVersion="X"/>` with X above
    /// its `short-bundle-version` gives "This document requires at least Xcode X." and exit 1 (27.0 and 26.2 measured,
    /// docs/research/xcode-tools-by-version.md). The image's profile is that limit.
    static func checkCapabilities(_ doc: IBDocument, profile: XcodeToolsProfile) throws {
        let limit = DottedVersion(profile.ibtoolShortVersion)!
        for deps in doc.raw.children where deps.name == "dependencies" {
            for c in deps.children where c.name == "capability" {
                guard let s = c.attributes["minToolsVersion"] else { continue }
                guard s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                      let v = DottedVersion(s) else {
                    throw LoweringError.unsupported("<capability> minToolsVersion=\"\(s)\"", line: c.line)
                }
                if v > limit {
                    throw XlessError(.ib, "This document requires at least Xcode \(s). The ibtool \(profile.ibtoolShortVersion) of the Xcode this build uses (Xcode \(profile.xcodeVersion), \(profile.xcodeBuild)) accepts documents up to Xcode \(profile.ibtoolShortVersion).",
                                     fix: "re-save the storyboard without features newer than Xcode \(profile.ibtoolShortVersion), or pin a newer Xcode (`xcode:`) and prepare its pack (xless setup --xcode <Xcode.xip>; --docker for xless run --docker)")
                }
            }
        }
    }
}
