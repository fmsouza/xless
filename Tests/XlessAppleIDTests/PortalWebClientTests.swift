import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
@testable import XlessAppleID

final class PortalWebClientTests: XCTestCase {
    nonisolated(unsafe) static let teams: [String: Any] = ["resultCode": 0, "teams": [
        ["teamId": "ABCDE12345", "name": "Example Ltd", "type": "Company/Organization", "status": "active"],
        ["teamId": "ZZZZZ99999", "name": "Jane Doe", "type": "Individual"],
    ]]

    func portal(team: String? = "ABCDE12345", _ handler: @escaping @Sendable (URLRequest) throws -> MockTransport.Reply) -> (PortalWebClient, MockTransport) {
        let mock = MockTransport(handler)
        return (PortalWebClient(web: AppleWebClient(transport: mock, stage: .account), teamID: team), mock)
    }

    func form(_ r: URLRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in r.bodyString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    func testListsTheTeamsWithoutATeamID() async throws {
        let (portal, mock) = portal(team: nil) { _ in .json(200, Self.teams) }
        let teams = try await portal.teams()
        XCTAssertEqual(teams.map(\.teamId), ["ABCDE12345", "ZZZZZ99999"])
        XCTAssertEqual(teams[0].name, "Example Ltd")
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(r.url?.absoluteString, "https://developer.apple.com/services-account/QH65B2/account/listTeams.action")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertNil(form(r)["teamId"])
    }

    func testAGetGoesAsAPostWithTheTeamAndTheQueryInTheBody() async throws {
        let (portal, mock) = portal { _ in .json(200, ["data": []]) }
        _ = try await portal.jsonAPI("GET", "v1/cloudContainers", query: [("filter[identifier]", "iCloud.com.example"), ("limit", "1")])
        let r = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.header("X-HTTP-Method-Override"), "GET")
        XCTAssertEqual(r.header("Content-Type"), "application/vnd.api+json")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as? [String: String]
        XCTAssertEqual(body?["teamId"], "ABCDE12345")
        XCTAssertEqual(body?["urlEncodedQueryParams"], "filter%5Bidentifier%5D=iCloud.com.example&limit=1")
    }

    func testAWriteFirstGetsTheCSRFTokensFromAListingAndEchoesThem() async throws {
        let (portal, mock) = portal { r in
            if r.url!.path.hasSuffix("listProvisioningProfiles.action") {
                return .json(200, ["resultCode": 0, "provisioningProfiles": []], headers: ["csrf": "pc1", "csrf_ts": "9"])
            }
            return .json(201, ["data": ["id": "X"]])
        }
        _ = try await portal.jsonAPI("POST", "v1/cloudContainers", body: Data("{}".utf8))
        _ = try await portal.jsonAPI("POST", "v1/cloudContainers", body: Data("{}".utf8))
        XCTAssertEqual(mock.requests.map { $0.url!.lastPathComponent }, ["listProvisioningProfiles.action", "cloudContainers", "cloudContainers"])
        let list = form(mock.requests[0])
        XCTAssertEqual(list["teamId"], "ABCDE12345")
        XCTAssertEqual(list["pageSize"], "1")
        XCTAssertNil(mock.requests[0].header("csrf"))
        XCTAssertEqual(mock.requests[1].header("csrf"), "pc1")
        XCTAssertEqual(mock.requests[1].header("csrf_ts"), "9")
        XCTAssertEqual(mock.requests[2].header("csrf"), "pc1")
    }

    func testACallNeedsATeam() async {
        let (portal, mock) = portal(team: nil) { _ in .json(200, [:]) }
        do { _ = try await portal.jsonAPI("GET", "v1/cloudContainers"); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.fix.contains("xless team use"))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testALegacyRefusalIsAnAccountErrorNamingTheFamily() async {
        let (portal, _) = portal { _ in .json(200, ["resultCode": 9401, "userString": "Something is wrong."]) }
        do { _ = try await portal.legacy("QH65B2/account/ios/identifiers/listApplicationGroups.action"); XCTFail("expected an error") }
        catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertEqual(e.cause, "the developer portal's web interface refused POST /services-account/QH65B2/account/ios/identifiers/listApplicationGroups.action (result 9401): Something is wrong.")
            XCTAssertTrue(e.fix.contains("undocumented") && e.fix.contains("https://developer.apple.com/account/resources"), e.fix)
        } catch { XCTFail("\(error)") }
    }

    func testAPendingLicenseAgreementSaysWhereToAcceptIt() async {
        let (portal, _) = portal(team: nil) { _ in
            .json(200, ["resultCode": 1100, "userString": "The Program License Agreement has been updated and needs to be reviewed."])
        }
        do { _ = try await portal.teams(); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("agreements"), e.cause)
            XCTAssertTrue(e.fix.contains("developer.apple.com/account"))
        } catch { XCTFail("\(error)") }
    }

    func testAnHTMLAnswerIsNotTakenForJSON() async {
        let (portal, _) = portal(team: nil) { _ in .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)) }
        do { _ = try await portal.teams(); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("session may have expired"), e.cause)
        } catch { XCTFail("\(error)") }
    }
}

final class AppleTeamsTests: XCTestCase {
    let team = PortalTeam(teamId: "ABCDE12345", name: "Example  Ltd ")

    func testMatchesByNameIgnoringCaseAndSpacing() {
        let p = OlympusProvider(providerId: 7, name: "example ltd")
        XCTAssertEqual(AppleTeams.match(team, in: [OlympusProvider(providerId: 1, name: "Other"), p]), .one(p))
        XCTAssertEqual(AppleTeams.match(team, in: [OlympusProvider(providerId: 1, name: "Example GmbH")]), .none)
        let twins = [OlympusProvider(providerId: 7, name: "Example Ltd"), OlympusProvider(providerId: 8, name: "EXAMPLE LTD")]
        XCTAssertEqual(AppleTeams.match(team, in: twins), .several(twins))
    }

    func testSelectsTheGivenTeamOrTheOnlyOne() throws {
        let teams = [PortalTeam(teamId: "ABCDE12345", name: "A"), PortalTeam(teamId: "ZZZZZ99999", name: "B")]
        XCTAssertEqual(try AppleTeams.select("ZZZZZ99999", from: teams).name, "B")
        XCTAssertEqual(try AppleTeams.select(nil, from: [teams[0]]).teamId, "ABCDE12345")
        XCTAssertThrowsError(try AppleTeams.select(nil, from: teams)) { XCTAssertTrue(($0 as? XlessError)?.fix.contains("--team") ?? false) }
        XCTAssertThrowsError(try AppleTeams.select("QQQQQ11111", from: teams)) {
            XCTAssertTrue(($0 as? XlessError)?.cause.contains("not a member of team QQQQQ11111") ?? false)
        }
    }

    func testAmongSeveralTeamsTheOneThatIsKnownServesWhenNoneIsGiven() throws {
        let teams = [PortalTeam(teamId: "ABCDE12345", name: "A"), PortalTeam(teamId: "ZZZZZ99999", name: "B")]
        XCTAssertEqual(try AppleTeams.select(nil, preferring: ["ZZZZZ99999"], from: teams).name, "B")
        XCTAssertEqual(try AppleTeams.select(nil, preferring: ["QQQQQ11111", "ABCDE12345"], from: teams).name, "A", "one it is no member of is passed over")
        XCTAssertEqual(try AppleTeams.select("ZZZZZ99999", preferring: ["ABCDE12345"], from: teams).name, "B", "the given one comes first")
        XCTAssertEqual(try AppleTeams.select(nil, preferring: ["ZZZZZ99999"], from: [teams[0]]).name, "A", "the only one")
        XCTAssertThrowsError(try AppleTeams.select(nil, preferring: ["QQQQQ11111"], from: teams))
    }

    func testATeamTheProjectNamesIsTheOneOrAnError() throws {
        let teams = [PortalTeam(teamId: "ABCDE12345", name: "A"), PortalTeam(teamId: "ZZZZZ99999", name: "B")]
        XCTAssertEqual(try AppleTeams.select(nil, project: "ZZZZZ99999", preferring: ["ZZZZZ99999", "ABCDE12345"], from: teams).name, "B")
        for mine in [teams, [teams[0]]] { // never another one, the API key's or the only one
            XCTAssertThrowsError(try AppleTeams.select(nil, project: "QQQQQ11111", preferring: ["QQQQQ11111", "ABCDE12345"], from: mine)) {
                let e = $0 as? XlessError
                XCTAssertEqual(e?.stage, .account)
                XCTAssertTrue(e?.cause.contains("xless.yml") == true && e?.cause.contains("QQQQQ11111") == true && e?.cause.contains("ABCDE12345 A") == true, e?.cause ?? "")
                XCTAssertTrue(e?.fix.contains("--team") == true, e?.fix ?? "")
            }
        }
        XCTAssertEqual(try AppleTeams.select("ABCDE12345", project: "QQQQQ11111", from: teams).name, "A", "--team says which")
        XCTAssertThrowsError(try AppleTeams.select(nil, project: "ZZZZZ99999", from: teams), "a command that must be told") { XCTAssertTrue(($0 as? XlessError)?.cause.contains("none was chosen") == true) }
        XCTAssertThrowsError(try AppleTeams.select(nil, project: "ZZZZZ99999", from: [])) { XCTAssertTrue(($0 as? XlessError)?.cause.contains("no developer team") == true) }
    }

    func testAmongProvidersOfOneNameTheAPIKeysIssuerTellsWithoutAsking() async throws {
        let ps = [OlympusProvider(providerId: 1, name: "Other"), OlympusProvider(providerId: 7, name: "Example Ltd", publicProviderId: "ISSUER-7"),
                  OlympusProvider(providerId: 8, name: "Example Ltd", publicProviderId: "ISSUER-8")]
        let (first, m1) = asc(ps, current: 8)
        let there = try await AppleTeams.useProvider(for: team, asc: first, issuers: ["issuer-8"], choose: nil)
        XCTAssertEqual(there.providerId, 8)
        XCTAssertEqual(posts(m1), 0, "the current one is looked at first")
        let (second, m2) = asc(ps, current: 1)
        let found = try await AppleTeams.useProvider(for: team, asc: second, issuers: ["ISSUER-8"], choose: nil)
        XCTAssertEqual(found.providerId, 8)
        XCTAssertEqual(m2.requests.filter { $0.httpMethod == "POST" }.map(\.bodyString), [#"{"provider":{"providerId":7}}"#, #"{"provider":{"providerId":8}}"#])
        let (neither, _) = asc(ps, current: 1)
        let chosen = try await AppleTeams.useProvider(for: team, asc: neither, issuers: ["ISSUER-9"]) { $0[0] }
        XCTAssertEqual(chosen.providerId, 7, "no key tells: a person chooses")
    }

    /// The current provider is the person's, in their browser too: looking for the right one leaves it as it was.
    func testLookingForTheKeysProviderLeavesTheCurrentOneWhenItIsNotFound() async throws {
        let ps = [OlympusProvider(providerId: 1, name: "Other", publicProviderId: "ISSUER-1"), OlympusProvider(providerId: 7, name: "Example Ltd", publicProviderId: "ISSUER-7"),
                  OlympusProvider(providerId: 8, name: "Example Ltd", publicProviderId: "ISSUER-8")]
        func current(_ asc: ASCWebClient) async throws -> Int? { try await asc.session().provider?.providerId }
        for start in [1, 7] {
            let (asc, _) = asc(ps, current: start)
            do { _ = try await AppleTeams.useProvider(for: team, asc: asc, issuers: ["ISSUER-9"], choose: nil); XCTFail("expected an error") } catch let e as XlessError {
                XCTAssertTrue(e.cause.contains("2 teams named"), e.cause)
            }
            let now = try await current(asc)
            XCTAssertEqual(now, start)
            do { _ = try await AppleTeams.useProvider(for: team, asc: asc, issuers: ["ISSUER-9"]) { _ in throw XlessError(.account, "nobody chose", fix: "-") } } catch let e as XlessError {
                XCTAssertEqual(e.cause, "nobody chose")
            }
            let after = try await current(asc)
            XCTAssertEqual(after, start)
        }
        // A switch that fails on the way.
        let (broken, m) = self.asc(ps, current: 1, refusing: [8])
        do { _ = try await AppleTeams.useProvider(for: team, asc: broken, issuers: ["ISSUER-8"]) { $0[0] }; XCTFail("expected an error") } catch {}
        let now = try await current(broken)
        XCTAssertEqual(now, 1)
        XCTAssertEqual(m.requests.filter { $0.httpMethod == "POST" }.compactMap(\.bodyString).last, #"{"provider":{"providerId":1}}"#)
    }

    /// App Store Connect with `providers`, currently on `current`; records the switches.
    func asc(_ providers: [OlympusProvider], current: Int, refusing: Set<Int> = []) -> (ASCWebClient, MockTransport) {
        let now = Box(current)
        let mock = MockTransport { r in
            if r.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: [String: Int]]
                guard !refusing.contains(body["provider"]!["providerId"]!) else { return .init(status: 500) }
                now.value = body["provider"]!["providerId"]!
                return .init(status: 200)
            }
            let p = providers.first { $0.providerId == now.value }!
            return .json(200, ["provider": ["providerId": p.providerId, "name": p.name, "publicProviderId": p.publicProviderId as Any? ?? NSNull()],
                               "availableProviders": providers.map { ["providerId": $0.providerId, "name": $0.name] }])
        }
        return (ASCWebClient(web: AppleWebClient(transport: mock, stage: .account)), mock)
    }

    func posts(_ mock: MockTransport) -> Int { mock.requests.filter { $0.httpMethod == "POST" }.count }

    func testSwitchesToTheTeamsProviderOnlyWhenNeeded() async throws {
        let ps = [OlympusProvider(providerId: 1, name: "Other"), OlympusProvider(providerId: 7, name: "Example Ltd")]
        let (onOther, m1) = asc(ps, current: 1)
        let p = try await AppleTeams.useProvider(for: team, asc: onOther, choose: nil)
        XCTAssertEqual(p.providerId, 7)
        XCTAssertEqual(posts(m1), 1)
        let (already, m2) = asc(ps, current: 7)
        _ = try await AppleTeams.useProvider(for: team, asc: already, choose: nil)
        XCTAssertEqual(posts(m2), 0)
    }

    func testAMismatchedNameIsAnErrorAndSwitchesNothing() async {
        let (asc, mock) = asc([OlympusProvider(providerId: 1, name: "Example GmbH")], current: 1)
        do { _ = try await AppleTeams.useProvider(for: team, asc: asc, choose: nil); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.cause.contains("no team named \"Example  Ltd \""), e.cause)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(posts(mock), 0)
    }

    func testSeveralProvidersWithTheNameAreChosenByAPersonOrRefused() async throws {
        let ps = [OlympusProvider(providerId: 1, name: "Other"), OlympusProvider(providerId: 7, name: "Example Ltd"),
                  OlympusProvider(providerId: 8, name: "Example Ltd")]
        let (noTerminal, m1) = asc(ps, current: 1)
        do { _ = try await AppleTeams.useProvider(for: team, asc: noTerminal, choose: nil); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("2 teams named"), e.cause)
        }
        XCTAssertEqual(posts(m1), 0)
        let (asked, m2) = asc(ps, current: 1)
        let offered = Box<[Int]>([])
        let p = try await AppleTeams.useProvider(for: team, asc: asked) { options in
            offered.value = options.map(\.providerId)
            return options[1]
        }
        XCTAssertEqual(offered.value, [7, 8])
        XCTAssertEqual(p.providerId, 8)
        XCTAssertEqual(m2.requests.filter { $0.httpMethod == "POST" }.map(\.bodyString), [#"{"provider":{"providerId":8}}"#])
    }
}
