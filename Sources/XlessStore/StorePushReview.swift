import Foundation
import XlessASC
import XlessCore

// The `review` part: App Review's contact, notes and demo account. Apple never gives the demo account's password back
// (and xless never asks for it), so it cannot be compared: it is sent, from the secret `passwordSecret` names, when the
// review details are created with a demo account, when the demo account becomes required or its name changes, and
// with `--resend-demo-account`. Within `review`, a key that is absent is left as App Store Connect has it; "" clears it.
// `attachments` lists files uploaded for App Review (compared by MD5, like screenshots).

extension PushContext {
    mutating func planReview() async throws {
        guard let review = app.review else { return }
        let current: StorePart<ASCKeptResource<StoreReviewDetailAttributes>>
        if let id = target.versionID { current = try await asc.reviewDetailResource(of: id) } else { current = .absent }
        if case .forbidden = current { return }
        let have = current.value?.attributes

        var diff = FieldDiff()
        let contact = review.contact
        diff.text("contactFirstName", want: contact?.firstName, have: have?.contactFirstName, clears: false)
        diff.text("contactLastName", want: contact?.lastName, have: have?.contactLastName, clears: false)
        diff.text("contactPhone", want: contact?.phone, have: have?.contactPhone, clears: false)
        diff.text("contactEmail", want: contact?.email, have: have?.contactEmail, clears: false)
        diff.text("notes", want: review.notes, have: have?.notes, clears: false)
        var secret: String?
        if let demo = review.demoAccount {
            if let required = demo.required, required != have?.demoAccountRequired {
                diff.attributes["demoAccountRequired"] = .bool(required)
                diff.fields.append(StoreFieldChange("demoAccountRequired", from: have?.demoAccountRequired.map { "\($0)" }, to: "\(required)"))
            }
            let nameChanges = diff.fields.count
            diff.text("demoAccountName", want: demo.name, have: have?.demoAccountName, clears: false)
            let accountChanged = diff.fields.count > nameChanges || diff.attributes["demoAccountRequired"] == .bool(true)
            if demo.required == true, have == nil || accountChanged || options.resendDemoAccount {
                guard let name = demo.passwordSecret else {
                    throw XlessError(.account, "\(self.name)/app.yml: App Review signs in with the demo account, and review.demoAccount.passwordSecret names no secret for its password",
                                     fix: "store the password (`xless secrets import XLESS_DEMO_PASSWORD --file <file> --kind password`) and add `passwordSecret: XLESS_DEMO_PASSWORD`")
                }
                if let problem = SecretEnvironment.passwordNameProblem(name) {
                    throw XlessError(.account, "\(self.name)/app.yml: review.demoAccount.passwordSecret \(name) \(problem); nothing is sent as the demo password",
                                     fix: "keep the demo password in its own secret, e.g. XLESS_DEMO_PASSWORD")
                }
                secret = name
                if have != nil, !accountChanged, demo.name != nil { diff.attributes["demoAccountName"] = .string(demo.name!) }
                diff.fields.append(StoreFieldChange("demoAccountPassword", from: nil, to: nil, secret: name))
            }
        }
        // The attachments app.yml lists, uploaded onto the review details (created for them when App Store Connect has none).
        var attachments: (work: StoreMediaWork?, fields: [StoreFieldChange], pruned: [StoreChange]) = (nil, [], [])
        if let paths = review.attachments {
            var remote: [ASCKeptResource<StoreMediaAttributes>] = []
            if let existing = current.value { remote = try await asc.reviewAttachments(of: existing.id) }
            attachments = try planFiles(.reviewAttachments, subject: "App Review attachments", paths: paths, remote: remote, parent: current.value?.id ?? "{id}")
        }
        for change in attachments.pruned {
            try requireEditableVersion(change.subject)
            add(change)
        }
        if !diff.isEmpty { try requireEditableVersion("App Review's \(diff.fields.map(\.name).joined(separator: ", "))") }
        if attachments.work != nil { try requireEditableVersion("App Review attachments") }
        if let existing = current.value {
            if !diff.isEmpty {
                add(StoreChange(.update, .review, "App Review details", fields: diff.fields,
                                requests: [.update("appStoreReviewDetails", id: existing.id, attributes: diff.attributes, secret: secret)]))
            }
            if let work = attachments.work {
                add(StoreChange(.update, .review, "App Review attachments", fields: attachments.fields, requests: [], media: work))
            }
        } else if !diff.isEmpty || attachments.work != nil {
            add(StoreChange(.create, .review, "App Review details", fields: diff.fields.filter { $0.to != nil || $0.secret != nil } + attachments.fields,
                            requests: [.create("appStoreReviewDetails", attributes: diff.attributes.filter { $0.value != .null },
                                               relationships: ["appStoreVersion": StoreRequest.link("appStoreVersions", target.versionID ?? "{version}")],
                                               secret: secret)],
                            media: attachments.work))
        }
    }
}
