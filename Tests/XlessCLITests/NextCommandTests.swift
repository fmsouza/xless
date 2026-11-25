import Foundation
import Testing
import XlessASC
import XlessCore
import XlessStore
@testable import xless

// `next: …`, printed after an upload, is the whole command: run from any directory, it finds the same project, its listing
// and its team.

private let record = UploadRecord(buildUploadID: "U1", buildID: "B1", state: "COMPLETE", processingState: "VALID", messages: [],
                                  bundleID: "com.example.app", version: "1.1", build: "42", platform: .ios)

private let xlessYML = """
bundleID: com.example.app
teamID: ABCDE12345
version: "1.1"
build: 42
platforms:
  ios: { minimumOS: "17.0", product: App }

"""
private let overlayYML = """
type: react-native
source: app
scheme: App
bundleIDs: { App: com.example.app }
teamID: ABCDE12345
version: "1.1"
build: 42

"""

/// A directory whose name a shell would read as more than a word, holding `files`, every one of them in it.
private struct Place {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless next \(UUID().uuidString)/it's $(touch x); \"a\"")
    init(_ files: [String: String]) throws {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    func context(_ arguments: [String], env: [String: String] = [:]) async throws -> Context {
        try await Context.load(try ProjectOptions.parse(arguments + ["--platform", "ios"]),
                               env: ["PATH": "/usr/bin:/bin", "XLESS_WORK_ROOT": root.appendingPathComponent("work").path].merging(env) { _, b in b })
    }
}

/// The words a shell makes of `command`.
private func words(_ command: String) throws -> [String] {
    let out = try Shell.run("sh", ["-c", "for w in \(command); do printf '%s\\0' \"$w\"; done"], stage: .build).stdout
    return out.split(separator: "\0").map(String.init)
}

/// `xless release submit`, as the printed command runs it.
private func submit(_ command: String) throws -> ReleaseSubmitCommand {
    let all = try words(command)
    #expect(Array(all.prefix(3)) == ["xless", "release", "submit"])
    return try ReleaseSubmitCommand.parse(Array(all.dropFirst(3)))
}

@Test func theNextCommandFindsAProjectGivenByPath() async throws {
    let place = try Place(["xless.yml": xlessYML, "appstore/app.yml": "bundleID: com.example.app\nprimaryLocale: en-US\nversion: \"1.1\"\n"])
    defer { place.cleanup() }
    let context = try await place.context(["--project", place.root.path])
    let command = try #require(context.submitCommand(for: record, env: [:]))
    #expect(command.hasPrefix("xless release submit --dir '/") && command.hasSuffix("' --app com.example.app --platform ios --app-version 1.1 --build B1"))
    let parsed = try submit(command)
    #expect(parsed.target.directory.url.path == place.root.appendingPathComponent("appstore").path && parsed.target.directory.url.path.hasPrefix("/"))
    #expect(parsed.target.manifest?.bundleID == "com.example.app")
    #expect(try parsed.target.wanted() == ReleaseWanted(app: "com.example.app", platform: "IOS", version: "1.1", team: "ABCDE12345"))
    #expect(parsed.build == "B1")
}

@Test func theNextCommandFindsTheListingAndTheTeamOfAnOverlay() async throws {
    let place = try Place(["ov/app.yml": overlayYML, "ov/appstore/app.yml": "primaryLocale: en-US\nversion: \"1.1\"\n", "ov/app/package.json": "{}"])
    defer { place.cleanup() }
    let overlay = place.root.appendingPathComponent("ov/app.yml")
    let context = try await place.context(["--config", overlay.path])
    let command = try #require(context.submitCommand(for: record, env: [:]))
    #expect(command.hasPrefix("xless release submit --config '/") && !command.contains("--dir"))
    let parsed = try submit(command)
    #expect(parsed.target.directory.configURL?.path == overlay.path)
    #expect(parsed.target.directory.url.path == place.root.appendingPathComponent("ov/appstore").path)
    #expect(parsed.target.manifest != nil)
    #expect(try parsed.target.wanted() == ReleaseWanted(app: "com.example.app", platform: "IOS", version: "1.1", team: "ABCDE12345"))
}

/// In a container the paths are the mounts'; `xless run` names the host's, which is where the command is pasted.
@Test func inAContainerTheNextCommandNamesTheHostsPaths() async throws {
    let place = try Place(["xless.yml": xlessYML, "ov/app.yml": overlayYML, "ov/app/package.json": "{}"])
    defer { place.cleanup() }
    let project = try await place.context(["--project", place.root.path]), overlay = try await place.context(["--config", place.root.appendingPathComponent("ov/app.yml").path])
    #expect(project.submitCommand(for: record, env: ["XLESS_PROJECT_ORIGIN": "/home/me/my app"])
        == "xless release submit --dir '/home/me/my app/appstore' --app com.example.app --platform ios --app-version 1.1 --build B1")
    #expect(overlay.submitCommand(for: record, env: ["XLESS_PROJECT_ORIGIN": "/home/me/o.yml"])
        == "xless release submit --config /home/me/o.yml --app com.example.app --platform ios --app-version 1.1 --build B1")
    // What is no absolute path is not one of the host's.
    for odd in ["", "relative/o.yml"] {
        #expect(overlay.submitCommand(for: record, env: ["XLESS_PROJECT_ORIGIN": odd]) == overlay.submitCommand(for: record, env: [:]))
    }
    // A path that a terminal would read as more than text is not printed, and neither is a command without it.
    for hostile in ["/home/\u{1B}[2J/o.yml", "/home/a\nb/o.yml", "/home/\u{202E}/o.yml"] {
        #expect(overlay.submitCommand(for: record, env: ["XLESS_PROJECT_ORIGIN": hostile]) == nil)
        #expect(project.submitCommand(for: record, env: ["XLESS_PROJECT_ORIGIN": hostile]) == nil)
    }
}

/// `--app` naming the project's own app keeps the project's team, as without it; another app does not take it.
@Test func theProjectsTeamGoesWithItsOwnApp() throws {
    let place = try Place(["xless.yml": xlessYML, "ov/app.yml": overlayYML])
    defer { place.cleanup() }
    for base in [["--dir", place.root.appendingPathComponent("appstore").path], ["--config", place.root.appendingPathComponent("ov/app.yml").path]] {
        func team(_ arguments: [String]) throws -> String? { try ReleaseSubmitCommand.parse(base + arguments).target.wanted().team }
        #expect(try team([]) == "ABCDE12345")
        #expect(try team(["--app", "com.example.app"]) == "ABCDE12345")
        #expect(try team(["--app", "com.example.app", "--platform", "ios"]) == "ABCDE12345")
        #expect(try team(["--app", "com.example.other"]) == nil)
        #expect(try team(["--app", "1234567890"]) == nil, "an app ID does not say whose app it is")
    }
}
