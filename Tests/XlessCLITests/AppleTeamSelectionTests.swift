import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessAppleID
import XlessCore
@testable import xless

// Which team a web-session command uses where nothing says: the one of the xless.yml here, or an error.

/// The developer portal of an Apple ID with `teams`.
private struct Portal: AppleTransport {
    let teams: [String]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = ["resultCode": 0, "teams": teams.map { ["teamId": $0, "name": "Team \($0)", "type": "Individual"] }]
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    func download(_ request: URLRequest, to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        throw XlessError(.account, "unexpected download", fix: "-")
    }
}

private func session(_ teams: [String]) -> AppleWebSession {
    AppleWebSession(web: AppleWebClient(transport: Portal(teams: teams), stage: .account), appleID: "me@example.com", kept: nil)
}

private func project(_ team: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-team-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "bundleID: com.example.app\nteamID: \(team)\nversion: 1.0.0\nbuild: 1\nplatforms:\n  ios: { minimumOS: '17.0', product: App }\n"
        .write(to: dir.appendingPathComponent("xless.yml"), atomically: true, encoding: .utf8)
    return dir
}

@Test func theTeamOfTheProjectHereIsTheOneOrAnError() async throws {
    let here = try project("ZZZZZ99999"), elsewhere = try project("QQQQQ11111")
    defer { for dir in [here, elsewhere] { try? FileManager.default.removeItem(at: dir) } }
    let both = session(["ABCDE12345", "ZZZZZ99999"]), one = session(["ABCDE12345"])
    #expect(try await AppleWebCLI.selectTeam(nil, in: both, directory: here, keyTeam: "ABCDE12345").teamId == "ZZZZZ99999")
    for (s, known) in [(both, true), (both, false), (one, true), (one, false)] {
        let error = await #expect(throws: XlessError.self) { try await AppleWebCLI.selectTeam(nil, in: s, known: known, directory: elsewhere, keyTeam: "ABCDE12345") }
        #expect(error?.cause.contains("QQQQQ11111") == true && error?.fix.contains("--team") == true, "\(error.map(String.init(describing:)) ?? "")")
    }
    #expect(try await AppleWebCLI.selectTeam("ABCDE12345", in: both, directory: elsewhere, keyTeam: nil).teamId == "ABCDE12345")
    #expect(try await AppleWebCLI.selectTeam(nil, in: both, directory: FileManager.default.temporaryDirectory, keyTeam: "ABCDE12345").teamId == "ABCDE12345")
}
