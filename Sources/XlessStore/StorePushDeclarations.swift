import Foundation
import XlessASC
import XlessCore

// The `declarations` part: content rights, the age rating, the licence agreement, export compliance and accessibility.
// Each is managed only when app.yml has its key; within `ageRating`, `encryption` and `accessibility`, only the answers
// app.yml gives are compared.

extension PushContext {
    mutating func planDeclarations() async throws {
        planContentRights()
        try await planAgeRating()
        try await planEULA()
        try await planEncryption()
        try await planAccessibility()
    }

    mutating func planContentRights() {
        guard let wanted = app.contentRights, wanted != target.app.attributes.contentRightsDeclaration else { return }
        add(StoreChange(.update, .declarations, "content rights",
                        fields: [StoreFieldChange("contentRightsDeclaration", from: target.app.attributes.contentRightsDeclaration, to: wanted)],
                        requests: [.update("apps", id: target.app.id, attributes: ["contentRightsDeclaration": .string(wanted)])]))
    }

    mutating func planAgeRating() async throws {
        guard let wanted = app.ageRating, !wanted.isEmpty, let info = target.info else { return }
        let declaration: ASCAnyResource
        switch try await asc.ageRatingDeclaration(of: info.id) {
        case .forbidden: return
        case .absent:
            note("App Store Connect has no age rating declaration for the app information yet; ageRating is not sent")
            return
        case .value(let d): declaration = d
        }
        var diff = FieldDiff()
        for key in wanted.values.keys.sorted() { diff.value(key, want: wanted[key], have: StoreScalar(declaration.attributes?[key])) }
        guard !diff.isEmpty else { return }
        try requireEditableInfo("the age rating (\(diff.fields.map(\.name).joined(separator: ", ")))")
        add(StoreChange(.update, .declarations, "age rating", fields: diff.fields,
                        requests: [.update("ageRatingDeclarations", id: declaration.id, attributes: diff.attributes)]))
    }

    mutating func planEULA() async throws {
        guard let wanted = app.eula else { return }
        let current = try await asc.eula(of: target.app.id)
        if case .forbidden = current { return }
        switch wanted {
        case .standard:
            guard let eula = current.value else { return }
            add(StoreChange(.delete, .declarations, "licence agreement", fields: [StoreFieldChange("agreement", from: "custom", to: "standard")],
                            requests: [.delete("endUserLicenseAgreements", id: eula.id)]))
        case .custom(let file, let territories):
            guard let url = StoreManifest.resolve(file, in: dir), case .success(let read) = ManifestText.read(url, isURL: false), let text = read else {
                throw XlessError(.account, "\(name)/\(file) (app.yml's eula.file) cannot be read", fix: "`xless store validate` says why")
            }
            let codes: [String]
            switch territories ?? .all {
            case .only(let list): codes = list.sorted()
            case .all:
                guard let all = try await asc.territories().value, !all.isEmpty else {
                    throw XlessError(.account, "App Store Connect did not list its territories, so `territories: all` cannot be sent", fix: "list the territories in eula.territories")
                }
                codes = all.sorted()
            }
            let relationships: [String: JSONValue] = ["territories": StoreRequest.links("territories", codes)]
            guard let eula = current.value else {
                add(StoreChange(.create, .declarations, "licence agreement",
                                fields: [StoreFieldChange("agreementText", from: nil, to: text), StoreFieldChange("territories", from: nil, to: codes.joined(separator: ", "))],
                                requests: [.create("endUserLicenseAgreements", attributes: ["agreementText": .string(text)],
                                                   relationships: relationships.merging(["app": StoreRequest.link("apps", target.app.id)]) { a, _ in a })]))
                return
            }
            var diff = FieldDiff()
            diff.text("agreementText", want: text, have: eula.text)
            var rel: [String: JSONValue] = [:]
            if Set(eula.territories) != Set(codes) {
                rel = relationships
                diff.fields.append(StoreFieldChange("territories", from: eula.territories.sorted().joined(separator: ", "), to: codes.joined(separator: ", ")))
            }
            guard !diff.isEmpty else { return }
            add(StoreChange(.update, .declarations, "licence agreement", fields: diff.fields,
                            requests: [.update("endUserLicenseAgreements", id: eula.id, attributes: diff.attributes, relationships: rel)]))
        }
    }

    /// The answers a new encryption declaration takes (all required). `exempt` and `usesEncryption` are Apple's verdict
    /// and an old answer: read, never sent.
    static let encryptionAnswers = ["appDescription", "availableOnFrenchStore", "containsProprietaryCryptography", "containsThirdPartyCryptography"]

    mutating func planEncryption() async throws {
        guard let wanted = app.encryption else { return }
        let given = Self.encryptionAnswers.filter { wanted[$0] != nil }
        guard !given.isEmpty else { return }
        let current = try await asc.encryption(of: target.app.id)
        if case .forbidden = current { return }
        let have = current.value ?? [:]
        var diff = FieldDiff()
        for key in given { diff.value(key, want: wanted[key], have: StoreScalar(have[key])) }
        guard !diff.isEmpty else { return }
        let missing = Self.encryptionAnswers.filter { wanted[$0] == nil }
        guard missing.isEmpty else {
            throw XlessError(.account, "\(name)/app.yml: export compliance differs, and a new encryption declaration needs every answer; encryption has no \(missing.joined(separator: ", "))",
                             fix: "answer \(Self.encryptionAnswers.joined(separator: ", ")) under `encryption:`")
        }
        var attributes: [String: JSONValue] = [:]
        for key in Self.encryptionAnswers { attributes[key] = wanted[key]!.json }
        let fields = Self.encryptionAnswers.map { StoreFieldChange($0, from: StoreScalar(have[$0])?.description, to: wanted[$0]!.description) }
            .filter { $0.from != $0.to }
        add(StoreChange(.create, .declarations, "export compliance", fields: fields,
                        requests: [.create("appEncryptionDeclarations", attributes: attributes, relationships: ["app": StoreRequest.link("apps", target.app.id)])]))
        if wanted["containsProprietaryCryptography"] == .bool(true) || wanted["availableOnFrenchStore"] == .bool(true) {
            note("App Store Connect may ask for a compliance document for this encryption declaration; `store push` does not upload one yet")
        }
    }

    mutating func planAccessibility() async throws {
        guard let wanted = app.accessibility, !wanted.isEmpty else { return }
        let current = try await asc.accessibility(of: target.app.id)
        if case .forbidden = current { return }
        let declarations = current.value ?? []
        func declaration(_ family: String, _ state: String) -> ASCAnyResource? {
            declarations.first { $0.attributes?["deviceFamily"]?.string == family && $0.attributes?["state"]?.string == state }
        }
        for family in wanted.values.keys.sorted() {
            let answers = wanted[family]!
            let draft = declaration(family, "DRAFT"), published = declaration(family, "PUBLISHED")
            let have = (draft ?? published)?.attributes ?? [:]
            var diff = FieldDiff()
            for key in answers.values.keys.sorted() {
                diff.value(key, want: answers[key].map { .bool($0) }, have: StoreScalar(have[key]))
            }
            guard !diff.isEmpty else { continue }
            let subject = "accessibility \(family)"
            if let draft {
                var attributes = diff.attributes
                attributes["publish"] = .bool(true)
                add(StoreChange(.update, .declarations, subject, fields: diff.fields,
                                requests: [.update("accessibilityDeclarations", id: draft.id, attributes: attributes)]))
            } else {
                // A new declaration starts from the published answers app.yml does not mention, then is published.
                var attributes: [String: JSONValue] = ["deviceFamily": .string(family)]
                for (key, value) in published?.attributes ?? [:] where key.hasPrefix("supports") { attributes[key] = value }
                for (key, value) in answers.values { attributes[key] = .bool(value) }
                add(StoreChange(.create, .declarations, subject, fields: diff.fields,
                                requests: [.create("accessibilityDeclarations", attributes: attributes, relationships: ["app": StoreRequest.link("apps", target.app.id)]),
                                           StoreRequest(method: "PATCH", path: "/v1/accessibilityDeclarations/{id}",
                                                        body: StoreRequest.document(type: "accessibilityDeclarations", id: "{id}", attributes: ["publish": .bool(true)], relationships: [:]))]))
            }
        }
    }
}
