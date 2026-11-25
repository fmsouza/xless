import ArgumentParser
#if os(Windows)
import CXlessWindows
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XlessASC
import XlessCore
@testable import xless

private let idA = "2f1c7a9e-0b1d-4f7a-9c33-5b2d8e0f1a11"
private let idB = "7b0e3c1d-4a5f-4e6b-8d22-9c1f0a2b3c44"

private func build(_ id: String, number: String, state: String = "VALID", expired: Bool = false, encryption: Bool? = false,
                   version: String = "PRV1", declaration: String? = nil) -> String {
    let enc = encryption.map { #","usesNonExemptEncryption":\#($0)"# } ?? ""
    let decl = declaration.map { #","appEncryptionDeclaration":{"data":{"type":"appEncryptionDeclarations","id":"\#($0)"}}"# } ?? ""
    return #"{"type":"builds","id":"\#(id)","attributes":{"version":"\#(number)","uploadedDate":"2026-11-20T10:15:00.000-08:00","expirationDate":"2027-02-18T10:15:00.000-08:00","expired":\#(expired),"minOsVersion":"17.0","processingState":"\#(state)","buildAudienceType":"APP_STORE_ELIGIBLE"\#(enc)},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"\#(version)"}},"app":{"data":{"type":"apps","id":"1234567890"}}\#(decl)}}"#
}
private let prv1 = #"{"type":"preReleaseVersions","id":"PRV1","attributes":{"version":"1.2.0","platform":"IOS"}}"#
private let appRes = #"{"type":"apps","id":"1234567890","attributes":{"bundleId":"com.example.app","name":"Example"}}"#
private func many(_ items: [String], included: [String] = [prv1, appRes]) -> String {
    #"{"data":[\#(items.joined(separator: ","))],"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}
private func one(_ item: String, included: [String] = [prv1, appRes]) -> String {
    #"{"data":\#(item),"included":[\#(included.joined(separator: ","))],"links":{"self":"x"}}"#
}

private final class Said: @unchecked Sendable { var lines: [String] = [] }

private func cli(_ t: FakeTransport, json: Bool = false, terminal: (any Confirming)? = nil, said: Said = Said()) -> BuildCLI {
    let creds = try! ASCCredentials.fromSecrets(Secrets(env: fakeKeyEnv, fallback: nil), stage: .account)
    return BuildCLI(builds: ASCBuilds(resources: ASCResources(client: ASCClient(credentials: creds, transport: t, sleep: { _ in }))),
                    json: json, terminal: { terminal }, say: { said.lines.append($0) }, sleep: { _ in })
}

@Test func buildsAreInTheAppleAccountGroup() {
    let help = Xless.helpMessage()
    let group = help.range(of: "APPLE ACCOUNT SUBCOMMANDS", options: .caseInsensitive)
    #expect(group.map { help[$0.upperBound...].contains("builds") } == true, "\(help)")
}

@Test func buildArgumentsAreCheckedBeforeAnythingIsSent() throws {
    #expect(throws: (any Error).self) { try BuildsShowCommand.parse(["42"]) }
    #expect(throws: (any Error).self) { try BuildsShowCommand.parse(["../v1/apps"]) }
    #expect(throws: (any Error).self) { try BuildsShowCommand.parse(["1.2+42", "--platform", "watchos"]) }
    #expect(throws: (any Error).self) { try BuildsShowCommand.parse(["1.2+42", "--app", "not an app"]) }
    #expect(throws: (any Error).self) { try BuildsListCommand.parse(["--state", "done"]) }
    #expect(throws: (any Error).self) { try BuildsListCommand.parse(["--limit", "0"]) }
    #expect(throws: (any Error).self) { try BuildsListCommand.parse(["--app-version", "one"]) }
    #expect(throws: (any Error).self) { try BuildsWaitCommand.parse([idA, "--timeout", "2d"]) }
    #expect(throws: (any Error).self) { try BuildsWaitCommand.parse([idA, "--timeout", "25h"]) }
    #expect(throws: (any Error).self) { try BuildsUpdateCommand.parse([idA]) }
    #expect(throws: (any Error).self) { try BuildsUpdateCommand.parse([idA, "--uses-non-exempt-encryption", "maybe"]) }
    #expect(throws: (any Error).self) { try BuildsUpdateCommand.parse([idA, "--encryption-declaration", "../x"]) }
    let show = try BuildsShowCommand.parse(["1.2.0+42", "--app", "com.example.app", "--platform", "macos", "--json"])
    #expect(show.selection.reference == .version("1.2.0", number: "42") && show.selection.platform.value == .macOS && show.output.json)
    let list = try BuildsListCommand.parse(["--state", "valid,processing", "--state", "valid", "--expired"])
    #expect(try list.parsedStates() == [.valid, .processing] && list.expired && list.limit == 50)
    let update = try BuildsUpdateCommand.parse([idA, "--uses-non-exempt-encryption", "false"])
    #expect(try update.encryption() == false)
    _ = try BuildsExpireCommand.parse([idA, "--yes"])
    #expect(try WaitTimeout.seconds("90s") == 90 && WaitTimeout.seconds("30m") == 1800 && WaitTimeout.seconds("2h") == 7200 && WaitTimeout.seconds("600") == 600)
    #expect(WaitTimeout.display(3600) == "1h" && WaitTimeout.display(1800) == "30m" && WaitTimeout.display(90) == "90s")
}

@Test func listPrintsATableWithTheAppWhenNoneWasNamed() async throws {
    let t = FakeTransport([(200, many([build(idA, number: "42"), build(idB, number: "43", state: "PROCESSING", encryption: nil)]))])
    let said = Said()
    let out = try await cli(t, said: said).list(app: nil, filter: BuildFilter(), limit: 2)
    let lines = out.split(separator: "\n")
    #expect(lines[0].hasPrefix("ID ") && lines[0].contains("APP") && lines[0].hasSuffix("UPLOADED    EXPIRES"))
    #expect(lines[1].hasPrefix(idA) && lines[1].contains("com.example.app") && lines[1].contains("1.2.0") && lines[1].contains("valid")
            && lines[1].contains("  no  ") && lines[1].hasSuffix("2026-11-20  2027-02-18"))
    #expect(lines[2].contains("processing") && lines[2].contains("not answered"))
    #expect(said.lines == ["note: showing the 2 most recently uploaded builds; --limit shows more"])
}

@Test func listByAppLooksTheAppUpAndLeavesItsColumnOut() async throws {
    let t = FakeTransport([(200, #"{"data":[\#(appRes)],"links":{"self":"x"}}"#), (200, many([build(idA, number: "42")]))])
    let out = try await cli(t).list(app: "com.example.app", filter: BuildFilter(), limit: 50)
    #expect(t.requests[1].url!.query!.contains("filter%5Bapp%5D=1234567890") || t.requests[1].url!.query!.contains("filter[app]=1234567890"))
    #expect(!out.contains("APP ") && !out.contains("com.example.app"))

    let empty = FakeTransport([(200, many([]))])
    #expect(try await cli(empty).list(app: "1234567890", filter: BuildFilter(), limit: 50) == "no build matches (expired builds are left out: --expired lists them)\n")
}

@Test func listJSONKeepsAppleShapeWithIncluded() async throws {
    let t = FakeTransport([(200, many([build(idA, number: "42")]))])
    let out = try await cli(t, json: true).list(app: nil, filter: BuildFilter(), limit: 50)
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    #expect(doc["data"]?[0]?["id"] == .string(idA) && doc["data"]?[0]?["attributes"]?["processingState"] == .string("VALID"))
    #expect(doc["included"]?[0]?["type"] == .string("preReleaseVersions"))
}

@Test func showSaysWhenExportComplianceIsUnanswered() async throws {
    let t = FakeTransport([(200, one(build(idA, number: "42", encryption: nil)))])
    let out = try await cli(t).show(.id(idA), app: nil, platform: nil)
    #expect(out.contains("Example (com.example.app)") && out.contains("NON-EXEMPT ENCRYPTION   not answered") && out.contains("ENCRYPTION DECLARATION  none"))
    #expect(out.contains("`xless builds update \(idA) --uses-non-exempt-encryption false`"))

    let answered = FakeTransport([(200, one(build(idA, number: "42", declaration: "DECL1"),
                                            included: [prv1, appRes, #"{"type":"appEncryptionDeclarations","id":"DECL1","attributes":{"appEncryptionDeclarationState":"APPROVED"}}"#]))])
    let text = try await cli(answered).show(.id(idA), app: nil, platform: nil)
    #expect(text.contains("DECL1 (approved)") && !text.contains("not answered"))
}

@Test func waitReportsChangesAndEndsValid() async throws {
    let t = FakeTransport([(200, one(build(idA, number: "42", state: "PROCESSING"))), (200, one(build(idA, number: "42", state: "PROCESSING"))),
                           (200, one(build(idA, number: "42", state: "VALID")))])
    let said = Said()
    let out = try await cli(t, said: said).wait(.id(idA), appID: nil, platform: nil, timeout: 3600)
    #expect(out == "build 1.2.0+42 (\(idA)) is valid\n")
    #expect(said.lines == ["build 1.2.0+42 (\(idA)): processing", "build 1.2.0+42 (\(idA)): valid"])
    #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func waitFailsOnInvalidAndOnTimeout() async throws {
    let invalid = FakeTransport([(200, one(build(idA, number: "42", state: "INVALID")))])
    do { _ = try await cli(invalid).wait(.id(idA), appID: nil, platform: nil, timeout: 60); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.stage == .account && e.cause == "build 1.2.0+42 (\(idA)) processing ended invalid" && e.fix.contains("higher build number"))
    }
    let never = FakeTransport((0..<5).map { _ in (200, many([])) })
    var c = cli(never)
    c.sleep = { _ in try await Task.sleep(for: .milliseconds(600)) }
    do { _ = try await c.wait(.version("1.2.0", number: "42"), appID: nil, platform: nil, timeout: 1); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.cause == "build 1.2.0+42 did not appear within 1s" && e.fix.contains("xless builds wait 1.2.0+42"))
    }
    #expect((2...3).contains(never.requests.count))
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

#if os(Windows)
@Test func ctrlCCancelsTheWaitWhichOnlyRead() async throws {
    let flag = Interrupt.Flag()
    let once = Once()
    let t = FakeTransport((0..<1000).map { _ in (200, one(build(idA, number: "42", state: "PROCESSING"))) })
    do {
        _ = try await Interrupt.cancelling(flag: flag) {
            var c = cli(t)
            c.sleep = { _ in
                if once.first() { xless_interrupt_raise() } // a real one would be for every process of this console
                try await Task.sleep(for: .seconds(30))
            }
            return try await c.wait(.id(idA), appID: nil, platform: nil, timeout: 3600)
        }
        Issue.record("expected the wait to stop")
    } catch {
        #expect(error is CancellationError, "\(error)")
        #expect(flag.interrupted)
    }
    #expect(t.requests.count == 1 && t.requests[0].httpMethod == "GET")
}
#else
@Test func aSignalCancelsTheWaitWhichOnlyRead() async throws {
    // What the signal does before the wait it does after it, whole: what passes signals on to the tools blocks the others.
    var mine = sigaction(), before = sigaction(), after = sigaction()
    mine.sa_flags = Int32(SA_RESTART)
    sigaddset(&mine.sa_mask, SIGTTIN)
    mine.handler = { _ in }
    sigaction(SIGUSR2, &mine, &before)
    defer { sigaction(SIGUSR2, &before, nil) }
    let flag = Interrupt.Flag()
    let once = Once()
    let t = FakeTransport((0..<1000).map { _ in (200, one(build(idA, number: "42", state: "PROCESSING"))) })
    do {
        _ = try await Interrupt.cancelling(on: SIGUSR2, flag: flag) {
            var c = cli(t)
            // The signal is sent from inside the wait, while the handler is surely installed (a process-wide kill, as
            // Ctrl-C is: raise() would target a thread that may block it).
            c.sleep = { _ in
                if once.first() { kill(getpid(), SIGUSR2) }
                try await Task.sleep(for: .seconds(30))
            }
            return try await c.wait(.id(idA), appID: nil, platform: nil, timeout: 3600)
        }
        Issue.record("expected the wait to stop")
    } catch {
        #expect(error is CancellationError, "\(error)")
        #expect(flag.interrupted)
    }
    #expect(t.requests.count == 1 && t.requests[0].httpMethod == "GET")
    sigaction(SIGUSR2, nil, &after)
    #expect(sigismember(&after.sa_mask, SIGTTIN) == 1)
    #expect(after.sa_flags & Int32(SA_RESTART) != 0)
}

private extension sigaction {
    var handler: @convention(c) (Int32) -> Void {
        get { { _ in } }
        set {
            #if os(Linux)
            __sigaction_handler.sa_handler = newValue
            #else
            __sigaction_u.__sa_handler = newValue
            #endif
        }
    }
}
#endif

@Test func expireAsksAndNeverExpiresTwice() async throws {
    let t = FakeTransport([(200, one(build(idA, number: "42"))), (200, one(build(idA, number: "42", expired: true)))])
    let out = try await cli(t, terminal: FakeTerminal(answer: true)).expire(.id(idA), app: nil, platform: nil, yes: false)
    #expect(out == "expired build 1.2.0+42 (\(idA))\n")
    #expect(t.requests.map(\.httpMethod) == ["GET", "PATCH"])

    let no = FakeTransport([(200, one(build(idA, number: "42")))])
    let said = Said()
    #expect(try await cli(no, terminal: FakeTerminal(answer: false), said: said).expire(.id(idA), app: nil, platform: nil, yes: false) == "")
    #expect(said.lines == ["cancelled; nothing was sent"] && no.requests.count == 1)

    let already = FakeTransport([(200, one(build(idA, number: "42", expired: true)))])
    let text = try await cli(already, terminal: nil).expire(.id(idA), app: nil, platform: nil, yes: false)
    #expect(text == "build 1.2.0+42 (\(idA)) is already expired; nothing was sent\n" && already.requests.count == 1)
}

@Test func updateSendsOnlyWhatDiffers() async throws {
    let same = FakeTransport([(200, one(build(idA, number: "42", encryption: false)))])
    #expect(try await cli(same).update(.id(idA), app: nil, platform: nil, usesNonExemptEncryption: false, declaration: nil)
            == "build 1.2.0+42 (\(idA)) already has these values; nothing was sent\n")
    #expect(same.requests.count == 1)

    let t = FakeTransport([(200, one(build(idA, number: "42", encryption: nil))),
                           (200, #"{"data":[{"type":"appEncryptionDeclarations","id":"DECL1","attributes":{"createdDate":"2026-01-01T00:00:00Z"}}],"links":{"self":"x"}}"#),
                           (200, one(build(idA, number: "42", encryption: false))), (204, "")])
    let out = try await cli(t).update(.id(idA), app: nil, platform: nil, usesNonExemptEncryption: false, declaration: "DECL1")
    #expect(out == "updated build 1.2.0+42 (\(idA)): uses non-exempt encryption not answered → no, encryption declaration none → DECL1\n")
    #expect(t.requests.map(\.httpMethod) == ["GET", "GET", "PATCH", "PATCH"])
    #expect(t.requests[3].url!.path == "/v1/builds/\(idA)/relationships/appEncryptionDeclaration")
}

@Test func updateRefusesAnotherAppsDeclaration() async throws {
    let t = FakeTransport([(200, one(build(idA, number: "42"))),
                           (200, #"{"data":[{"type":"appEncryptionDeclarations","id":"DECL1","attributes":{"createdDate":"2026-01-01T00:00:00Z","appEncryptionDeclarationState":"APPROVED"}}],"links":{"self":"x"}}"#)])
    do { _ = try await cli(t).update(.id(idA), app: nil, platform: nil, usesNonExemptEncryption: nil, declaration: "OTHER"); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.cause == "OTHER is not an encryption declaration of com.example.app; nothing was sent")
        #expect(e.fix == "use one of the app's: DECL1 (approved, 2026-01-01)")
    }
    #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func updateChecksTheDeclarationBeforeChangingAnything() async throws {
    let t = FakeTransport([(200, one(build(idA, number: "42", encryption: nil))),
                           (200, #"{"data":[],"links":{"self":"x"}}"#)])
    do {
        _ = try await cli(t).update(.id(idA), app: nil, platform: nil, usesNonExemptEncryption: false, declaration: "OTHER")
        Issue.record("expected an error")
    } catch let e as XlessError {
        #expect(e.cause.hasSuffix("nothing was sent") && e.fix.hasPrefix("the app has none"))
    }
    #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func aBuildIDWithAnotherAppIsRefused() async throws {
    let t = FakeTransport([(200, one(build(idA, number: "42")))])
    do { _ = try await cli(t).show(.id(idA), app: "999", platform: nil); Issue.record("expected an error") } catch let e as XlessError {
        #expect(e.cause == "build \(idA) is a build of com.example.app, not of 999")
    }
}
