import Foundation
import XlessASC
import XlessCore

/// What the `xless testflight` commands do once their arguments are valid; returns what goes to standard output and says
/// the rest (cancellations, notes, hints) on standard error.
struct TestFlightCLI {
    let testFlight: ASCTestFlight
    let apps: ASCApps
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    init(resources: ASCResources, json: Bool = false, terminal: @escaping () -> (any Confirming)? = { try? TerminalPrompter.forAccount() },
         say: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        testFlight = ASCTestFlight(resources: resources); apps = ASCApps(resources: resources)
        self.json = json; self.terminal = terminal; self.say = say
    }

    var builds: BuildCLI { BuildCLI(builds: ASCBuilds(resources: testFlight.resources)) }

    struct Listing<D: Encodable>: Encodable { var data: D; var included: [ASCAnyResource] }
    struct Result<D: Encodable>: Encodable { var result: String; var data: D }

    private func confirm(_ question: String, action: String, yes: Bool) throws -> Bool {
        guard try AccountConfirm.confirm(question, action: action, yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return false
        }
        return true
    }

    // MARK: Groups

    func groups(app argument: String) async throws -> String {
        let app = try await apps.resolve(argument)
        let groups = try await testFlight.groups(app: app.id)
        if json { return try ASCOutput.json(Listing(data: groups, included: [])) }
        guard !groups.isEmpty else { return "\(app.bundleID) has no TestFlight group; create one with `xless testflight groups create <name> --app \(app.bundleID)`\n" }
        return TextTable(["ID", "NAME", "TYPE", "ALL BUILDS", "FEEDBACK", "PUBLIC LINK"], groups.map { g in
            [g.id, g.name, g.kind, g.isInternal ? (g.attributes.hasAccessToAllBuilds == true ? "yes" : "no") : "-",
             g.attributes.feedbackEnabled == true ? "yes" : "no", Self.link(g)]
        }).rendered
    }

    static func link(_ g: ASCBetaGroup) -> String {
        guard let url = g.publicLink else { return "-" }
        return url + (g.publicLinkLimit.map { " (limit \($0))" } ?? "")
    }

    func createGroup(_ name: String, app argument: String, external: Bool, allBuilds: Bool, feedback: Bool?) async throws -> String {
        let app = try await apps.resolve(argument)
        let outcome = try await testFlight.createGroup(name: name, app: app.id, external: external, allBuilds: allBuilds, feedback: feedback)
        let g = outcome.value
        if case .unchanged = outcome {
            if allBuilds, g.attributes.hasAccessToAllBuilds != true {
                say("note: automatic distribution (--all-builds) cannot be turned on after a group is created")
            }
            if json { return try ASCOutput.json(Result(result: "existing", data: g)) }
            return "\(app.bundleID) already has the \(g.kind) group \(g.name) (\(g.id)); nothing was sent\n"
        }
        if json { return try ASCOutput.json(Result(result: "created", data: g)) }
        return "created the \(g.kind) group \(g.name) (\(g.id)) for \(app.bundleID)\(allBuilds && !external ? ", with every build (automatic distribution)" : "")\n"
    }

    func updateGroup(_ text: String, app argument: String, name: String?, feedback: Bool?) async throws -> String {
        let app = try await apps.resolve(argument)
        let group = try await testFlight.group(text, app: app.id, display: app.bundleID)
        if let name, name != group.name, try await testFlight.groups(app: app.id).contains(where: { $0.name == name }) {
            throw XlessError(.account, "\(app.bundleID) already has a group named \(name)", fix: "choose another name")
        }
        guard let updated = try await testFlight.updateGroup(group, .init(name: name, feedback: feedback)) else {
            if json { return try ASCOutput.json(Listing(data: group, included: [])) }
            return "group \(group.name) (\(group.id)) already has these settings; nothing was sent\n"
        }
        if json { return try ASCOutput.json(Listing(data: updated, included: [])) }
        return "updated group \(updated.name) (\(updated.id)): feedback \(updated.attributes.feedbackEnabled == true ? "on" : "off")\n"
    }

    func deleteGroup(_ text: String, app argument: String, yes: Bool) async throws -> String {
        let app = try await apps.resolve(argument)
        let group = try await testFlight.group(text, app: app.id, display: app.bundleID)
        guard try confirm("Delete the \(group.kind) TestFlight group \(group.name) of \(app.bundleID)? Its testers lose the builds they got through it.",
                          action: "deleting group \(group.id)", yes: yes) else { return "" }
        try await testFlight.deleteGroup(group)
        return json ? try ASCOutput.json(["deleted": group]) : "deleted group \(group.name) (\(group.id))\n"
    }

    // MARK: Testers

    func testers(app argument: String, group text: String?) async throws -> String {
        let app = try await apps.resolve(argument)
        let groups = try await testFlight.groups(app: app.id)
        var group: ASCBetaGroup?
        if let text {
            guard let g = ASCTestFlight.pick(text, from: groups) else { throw ASCTestFlight.noGroup(text, app: app.bundleID, among: groups) }
            group = g
        }
        let listing = try await testFlight.testers(app: app.id, group: group?.id)
        if json { return try ASCOutput.json(Listing(data: listing.items, included: listing.included)) }
        guard !listing.items.isEmpty else {
            return group.map { "group \($0.name) has no tester\n" } ?? "\(app.bundleID) has no TestFlight tester\n"
        }
        let names = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return TextTable(["ID", "EMAIL", "NAME", "STATE", "INVITED BY", "GROUPS"], listing.items.map { t in
            [t.id, t.email, t.fullName, (t.attributes.state ?? "").lowercased().replacingOccurrences(of: "_", with: " "),
             t.attributes.inviteType == "PUBLIC_LINK" ? "public link" : (t.attributes.inviteType ?? "").lowercased(),
             (t.groupIDs ?? []).compactMap { names[$0] }.sorted().joined(separator: ", ")]
        }).rendered
    }

    struct Added: Encodable { var email: String; var result: String; var data: ASCBetaTester }

    func addTesters(_ emails: [String], app argument: String, group text: String, firstName: String?, lastName: String?) async throws -> String {
        let app = try await apps.resolve(argument)
        let group = try await testFlight.group(text, app: app.id, display: app.bundleID)
        let members = try await testFlight.members(of: group)
        let users = group.isInternal ? try await testFlight.userEmails() : nil
        if group.isInternal, users == nil {
            say("note: this API key may not read the team's users (Admin only), so Apple decides whether each address is one")
        }
        var lines: [String] = []
        var added: [Added] = []
        for email in emails {
            let request = BetaTesterRequest(email: email, firstName: firstName, lastName: lastName)
            let outcome: ASCTestFlight.TesterAddition
            do { outcome = try await testFlight.add(request, to: group, members: members, users: users) } catch {
                for line in lines { say(line) }
                if !lines.isEmpty { say("(the addresses above were handled before \(email) failed)") }
                throw error
            }
            let t = outcome.tester
            switch outcome {
            case .created: lines.append("added \(t.email) to group \(group.name) (new tester \(t.id)); Apple emails them the invitation")
            case .added: lines.append("added \(t.email) to group \(group.name) (tester \(t.id))")
            case .alreadyInGroup: lines.append("\(t.email) is already in group \(group.name) (tester \(t.id)); nothing was sent")
            }
            let result = switch outcome { case .created: "created"; case .added: "added"; case .alreadyInGroup: "already-in-group" }
            added.append(Added(email: email, result: result, data: t))
        }
        if !group.isInternal, group.attributes.publicLinkEnabled != true {
            say("note: external testers get a build once Apple approves it (`xless testflight beta-review submit <build> --app \(app.bundleID)`)")
        }
        if json { return try ASCOutput.json(["results": added]) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The testers `emails` name, among `pool`; an error naming the ones that are not there.
    private func pick(_ emails: [String], from pool: [ASCBetaTester], where place: String, fix: String) throws -> [ASCBetaTester] {
        var found: [ASCBetaTester] = []
        var missing: [String] = []
        for email in emails {
            if let t = pool.first(where: { UserEmail.same($0.email, email) }) {
                if !found.contains(where: { $0.id == t.id }) { found.append(t) }
            } else { missing.append(email) }
        }
        if !missing.isEmpty { throw XlessError(.account, "\(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") not a tester of \(place); nothing was sent", fix: fix) }
        return found
    }

    func removeTesters(_ emails: [String], app argument: String, group text: String?, yes: Bool) async throws -> String {
        let app = try await apps.resolve(argument)
        if let text {
            let group = try await testFlight.group(text, app: app.id, display: app.bundleID)
            let testers = try pick(emails, from: try await testFlight.members(of: group), where: "group \(group.name)",
                                   fix: "see the group's testers with `xless testflight testers list --app \(app.bundleID) --group \"\(group.name)\"`")
            guard try confirm("Remove \(testers.map(\.email).joined(separator: ", ")) from the TestFlight group \(group.name)? They lose the builds they got through it.",
                              action: "removing testers from group \(group.id)", yes: yes) else { return "" }
            try await testFlight.remove(testers, from: group)
            return json ? try ASCOutput.json(["removed": testers]) : "removed \(testers.map(\.email).joined(separator: ", ")) from group \(group.name)\n"
        }
        let testers = try pick(emails, from: try await testFlight.testers(app: app.id).items, where: app.bundleID,
                               fix: "see the app's testers with `xless testflight testers list --app \(app.bundleID)`")
        guard try confirm("Remove \(testers.map(\.email).joined(separator: ", ")) from every TestFlight group and build of \(app.bundleID)?",
                          action: "removing testers from \(app.bundleID)", yes: yes) else { return "" }
        try await testFlight.remove(testers, fromApp: app.id)
        return json ? try ASCOutput.json(["removed": testers]) : "removed \(testers.map(\.email).joined(separator: ", ")) from \(app.bundleID)\n"
    }

    func invite(_ emails: [String], app argument: String) async throws -> String {
        let app = try await apps.resolve(argument)
        let testers = try pick(emails, from: try await testFlight.testers(app: app.id).items, where: app.bundleID,
                               fix: "add them to a group first: `xless testflight testers add <email> --group <group> --app \(app.bundleID)`")
        var lines: [String] = []
        var sent: [[String: String]] = []
        for t in testers {
            let id = try await testFlight.invite(t, app: app.id)
            lines.append("Apple emails \(t.email) an invitation to test \(app.bundleID)\(id.map { " (invitation \($0))" } ?? "")")
            sent.append(["email": t.email, "tester": t.id, "invitation": id ?? ""])
        }
        return json ? try ASCOutput.json(["invited": sent]) : lines.joined(separator: "\n") + "\n"
    }

    // MARK: Builds

    func buildGroups(add: Bool, _ reference: BuildReference, app: String?, platform: BuildPlatform?, groups texts: [String], yes: Bool) async throws -> String {
        let b = try await builds.resolve(reference, app: app, platform: platform)
        guard let appID = b.appID else { throw XlessError(.account, "App Store Connect did not say which app build \(b.id) belongs to", fix: "pass --app") }
        let display = b.bundleID ?? appID
        let all = try await testFlight.groups(app: appID)
        var groups: [ASCBetaGroup] = []
        for text in texts {
            guard let g = ASCTestFlight.pick(text, from: all) else { throw ASCTestFlight.noGroup(text, app: display, among: all) }
            if !groups.contains(where: { $0.id == g.id }) { groups.append(g) }
        }
        let current = try await testFlight.groupIDs(with: b.id, app: appID)
        let names = { (gs: [ASCBetaGroup]) in gs.map(\.name).joined(separator: ", ") }
        if add {
            if b.build.isExpired { throw XlessError(.account, "build \(b.name) (\(b.id)) is expired: testers can no longer install it", fix: "upload a new build") }
            let missing = groups.filter { !current.contains($0.id) }
            guard !missing.isEmpty else { return report(b, "build \(b.name) is already in \(names(groups)); nothing was sent") }
            try await testFlight.addBuild(b.id, to: missing)
            if missing.contains(where: { !$0.isInternal }) {
                say("note: external testers get the build once Apple approves it: `xless testflight beta-review submit \(b.id)`")
            }
            return report(b, "added build \(b.name) (\(b.id)) to \(names(missing))")
        }
        let present = groups.filter { current.contains($0.id) }
        guard !present.isEmpty else { return report(b, "build \(b.name) is in none of \(names(groups)); nothing was sent") }
        guard try confirm("Remove build \(b.name) from \(names(present))? Their testers can no longer install it.",
                          action: "removing build \(b.id) from groups", yes: yes) else { return "" }
        try await testFlight.removeBuild(b.id, from: present)
        return report(b, "removed build \(b.name) (\(b.id)) from \(names(present))")
    }

    private func report(_ b: ASCBuildDetail, _ line: String) -> String {
        json ? ((try? ASCOutput.json(Listing(data: b.build, included: b.included))) ?? "") : line + "\n"
    }

    func whatsNew(_ reference: BuildReference, app: String?, platform: BuildPlatform?) async throws -> String {
        let b = try await builds.resolve(reference, app: app, platform: platform)
        let items = try await testFlight.whatsNew(build: b.id)
        if json { return try ASCOutput.json(Listing(data: items, included: [])) }
        guard !items.isEmpty else { return "build \(b.name) has no What to Test\n" }
        return items.map { "\($0.attributes.locale ?? "?"):\n\($0.attributes.whatsNew ?? "")\n" }.joined(separator: "\n")
    }

    func setWhatsNew(_ reference: BuildReference, app: String?, platform: BuildPlatform?, locale: String, text: String) async throws -> String {
        let b = try await builds.resolve(reference, app: app, platform: platform)
        let outcome = try await testFlight.setWhatsNew(build: b.id, locale: locale, text: text)
        if json { return try ASCOutput.json(Listing(data: outcome.value, included: [])) }
        switch outcome {
        case .created: return "set What to Test (\(locale)) of build \(b.name)\n"
        case .updated: return "updated What to Test (\(locale)) of build \(b.name)\n"
        case .unchanged: return "What to Test (\(locale)) of build \(b.name) is already this text; nothing was sent\n"
        }
    }

    // MARK: Beta information

    struct BetaInfo: Encodable { var localizations: [ASCBetaAppLocalization]; var reviewDetail: ASCBetaReviewDetail; var licenseAgreement: ASCBetaLicense }

    func betaInfo(app argument: String, locale: String?) async throws -> String {
        let app = try await apps.resolve(argument)
        var locs = try await testFlight.localizations(app: app.id)
        if let locale { locs = locs.filter { $0.attributes.locale == locale } }
        let detail = try await testFlight.reviewDetail(app: app.id)
        let license = try await testFlight.license(app: app.id)
        if json { return try ASCOutput.json(BetaInfo(localizations: locs, reviewDetail: detail, licenseAgreement: license)) }
        var rows: [[String]] = []
        for l in locs {
            let a = l.attributes
            let loc = a.locale ?? "?"
            rows += [["\(loc) description", a.description ?? ""], ["\(loc) feedback email", a.feedbackEmail ?? ""],
                     ["\(loc) marketing URL", a.marketingUrl ?? ""], ["\(loc) privacy policy URL", a.privacyPolicyUrl ?? ""]]
        }
        if locs.isEmpty { rows.append(["localizations", locale.map { "none for \($0)" } ?? "none"]) }
        let r = detail.attributes
        rows += [["review contact", [r.contactFirstName, r.contactLastName].compactMap { $0 }.joined(separator: " ")],
                 ["review contact email", r.contactEmail ?? ""], ["review contact phone", r.contactPhone ?? ""],
                 ["review notes", r.notes ?? ""], ["demo account", r.demoAccountName ?? ""],
                 ["demo account required", r.demoAccountRequired == true ? "yes" : "no"],
                 ["license agreement", license.attributes.agreementText.map { "\($0.count) characters" } ?? "Apple's standard"]]
        return TextTable(["APP", "\(app.bundleID) (\(app.id))"], rows).rendered
    }

    /// Sets what differs: the locale's texts, the review details (the password from its secret, only when it must go),
    /// the license agreement.
    func setBetaInfo(app argument: String, locale: String, text: BetaInfoText, review: BetaReviewChange?, license: String?,
                     password: (String) throws -> String) async throws -> String {
        let app = try await apps.resolve(argument)
        var lines: [String] = []
        var detail = try await testFlight.reviewDetail(app: app.id)
        if let review {
            let have = detail.attributes
            let required = review.demoAccountRequired ?? have.demoAccountRequired ?? false
            if review.touchesDemoAccount, required, (review.demoAccountName ?? have.demoAccountName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                throw XlessError(.account, "App Review signs in with the demo account, which has no name; nothing was sent",
                                 fix: "give --demo-account-name (the password comes from the secret --demo-password-secret-name names, XLESS_DEMO_PASSWORD by default)")
            }
            let diff = review.diff(from: have)
            if let updated = try await testFlight.updateReviewDetail(detail, review, password: password) {
                detail = updated
                lines.append("updated the beta App Review details: \(diff.fields.joined(separator: ", "))")
            } else {
                lines.append("the beta App Review details already match; nothing was sent")
            }
        }
        if !text.isEmpty {
            switch try await testFlight.setLocalization(app: app.id, locale: locale, text) {
            case .created?: lines.append("created the beta information for \(locale)")
            case .updated?: lines.append("updated the beta information for \(locale)")
            case .unchanged?, nil: lines.append("the beta information for \(locale) already matches; nothing was sent")
            }
        }
        if let license {
            let current = try await testFlight.license(app: app.id)
            lines.append(try await testFlight.updateLicense(current, text: license) == nil
                         ? "the beta license agreement is already this text; nothing was sent" : "updated the beta license agreement")
        }
        if json {
            let locs = try await testFlight.localizations(app: app.id).filter { $0.attributes.locale == locale }
            return try ASCOutput.json(BetaInfo(localizations: locs, reviewDetail: detail, licenseAgreement: try await testFlight.license(app: app.id)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Beta app review

    func submit(_ reference: BuildReference, app: String?, platform: BuildPlatform?) async throws -> String {
        let b = try await builds.resolve(reference, app: app, platform: platform)
        if b.build.isExpired { throw XlessError(.account, "build \(b.name) (\(b.id)) is expired", fix: "upload a new build and submit that one") }
        guard b.build.processingState == "VALID" else {
            throw XlessError(.account, "build \(b.name) (\(b.id)) is \(b.build.processingState.lowercased()), and only a processed (valid) build can be submitted",
                             fix: "wait for it with `xless builds wait \(b.id)`, then submit it")
        }
        let outcome = try await testFlight.submit(build: b.id)
        let s = outcome.value
        let state = Self.reviewState(s.attributes.betaReviewState)
        if json { return try ASCOutput.json(Result(result: { if case .created = outcome { "submitted" } else { "existing" } }(), data: s)) }
        if case .unchanged = outcome { return "build \(b.name) was already submitted for beta app review (\(state)); nothing was sent\n" }
        return "submitted build \(b.name) (\(b.id)) for beta app review (submission \(s.id), \(state)); `xless testflight beta-review status \(b.id)` follows it\n"
    }

    static func reviewState(_ raw: String?) -> String { (raw ?? "waiting for review").lowercased().replacingOccurrences(of: "_", with: " ") }

    struct Status: Encodable { var build: ASCBuild; var submission: ASCBetaSubmission?; var externalBuildState: String? }

    func status(_ reference: BuildReference, app: String?, platform: BuildPlatform?) async throws -> String {
        let b = try await builds.resolve(reference, app: app, platform: platform)
        let s = try await testFlight.submission(build: b.id)
        if json { return try ASCOutput.json(Status(build: b.build, submission: s, externalBuildState: b.externalBetaState)) }
        var rows = [["BUILD", "\(b.name) (\(b.id))"], ["BETA APP REVIEW", s.map { Self.reviewState($0.attributes.betaReviewState) } ?? "not submitted"]]
        if let date = s?.attributes.submittedDate { rows.append(["SUBMITTED", date]) }
        if let ext = b.externalBetaState { rows.append(["EXTERNAL TESTING", ext.lowercased().replacingOccurrences(of: "_", with: " ")]) }
        var out = TextTable(["", ""], rows).rendered
        if s == nil { out += "submit it with `xless testflight beta-review submit \(b.id)`\n" }
        if s?.attributes.betaReviewState == "REJECTED" { out += "Apple emails the reasons; App Store Connect → TestFlight shows them too\n" }
        return out
    }

    // MARK: Public links

    func publicLink(_ action: PublicLinkAction, group text: String, app argument: String, limit: Int??, yes: Bool) async throws -> String {
        let app = try await apps.resolve(argument)
        let group = try await testFlight.group(text, app: app.id, display: app.bundleID)
        if case .show = action {
            if json { return try ASCOutput.json(Listing(data: group, included: [])) }
            guard let url = group.publicLink else { return "group \(group.name) has no public link\(group.isInternal ? " (internal groups cannot have one)" : "")\n" }
            return url + (group.publicLinkLimit.map { " (at most \($0) testers)" } ?? " (no tester limit)") + "\n"
        }
        guard !group.isInternal else {
            throw XlessError(.account, "group \(group.name) is internal, and only external groups have public links", fix: "use an external group (`xless testflight groups create <name> --external --app \(app.bundleID)`)")
        }
        let change: ASCTestFlight.GroupChange
        if case .enable = action {
            change = .init(publicLink: true, publicLinkLimit: limit)
        } else {
            guard group.attributes.publicLinkEnabled == true else { return json ? try ASCOutput.json(Listing(data: group, included: [])) : "group \(group.name) has no public link; nothing was sent\n" }
            guard try confirm("Disable the public link of \(group.name)? Nobody new can join through it.", action: "disabling the public link of group \(group.id)", yes: yes) else { return "" }
            change = .init(publicLink: false)
        }
        guard let updated = try await testFlight.updateGroup(group, change) else {
            return json ? try ASCOutput.json(Listing(data: group, included: [])) : "the public link of \(group.name) already has these settings; nothing was sent\n" + (group.publicLink.map { $0 + "\n" } ?? "")
        }
        if json { return try ASCOutput.json(Listing(data: updated, included: [])) }
        if case .disable = action { return "disabled the public link of \(updated.name)\n" }
        if updated.attributes.publicLink == nil { say("note: App Store Connect did not send the link back; `xless testflight public-link show \"\(updated.name)\" --app \(app.bundleID)` reads it") }
        return (updated.attributes.publicLink ?? "public link enabled") + (updated.publicLinkLimit.map { " (at most \($0) testers)" } ?? "") + "\n"
    }

    enum PublicLinkAction { case show, enable, disable }
}
