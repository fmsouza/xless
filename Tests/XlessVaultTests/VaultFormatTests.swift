import Crypto
import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

// Store format 2 (#138): every field authenticated, a minimum reader version, unknown fields kept, old stores upgraded.

private let full = VaultEntry.Metadata(teamID: "TEAM123456", keyID: "KEY1234567", issuerID: "issuer", certificateID: "CERT1",
                                       created: Date(timeIntervalSince1970: 1_790_000_000), expires: Date(timeIntervalSince1970: 1_800_000_000),
                                       role: "ADMIN", certificateType: "DISTRIBUTION", services: "apns,siwa")

/// An entry sealed as releases before format 2 sealed them.
private func legacySeal(_ name: String, _ kind: VaultEntry.Kind, _ metadata: VaultEntry.Metadata, _ secret: String, key: SymmetricKey) throws -> VaultEntry {
    let aad = try #require(VaultEntry(name: name, kind: kind, metadata: metadata, sealed: Data(), format: 1).associatedData)
    let sealed = try #require(try AES.GCM.seal(Data(secret.utf8), using: key, authenticating: aad).combined)
    return VaultEntry(name: name, kind: kind, metadata: metadata, sealed: sealed, format: 1)
}

/// A store as releases before format 2 wrote it (version 1, entries of format 1), on disk in `t`.
@discardableResult
private func makeLegacy(_ t: TempStore, entries: [(String, VaultEntry.Kind, VaultEntry.Metadata, String)]) throws -> SymmetricKey {
    var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "correct horse battery"), kdf: testKDF())
    file.version = 1
    file.minimumReaderVersion = 1
    file.entries = try entries.map { try legacySeal($0.0, $0.1, $0.2, $0.3, key: key) }
    try t.store.create(file)
    return key
}

/// Edits the store file's JSON in place, as someone with write access to it (or a newer xless) could.
private func editJSON(_ t: TempStore, _ body: (inout [String: Any]) throws -> Void) throws {
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t.location.file)) as? [String: Any])
    try body(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: t.location.file)
}

private func entries(_ o: [String: Any]) throws -> [[String: Any]] { try #require(o["entries"] as? [[String: Any]]) }

private func secretStore(_ t: TempStore, cache: (any VaultKeyCache)? = nil, prompter: ScriptedPrompter) -> VaultSecretStore {
    VaultSecretStore(store: t.store, cache: cache, prompter: { prompter })
}

private func opens(_ entry: VaultEntry?, _ key: SymmetricKey) -> String? {
    guard let entry else { return nil }
    return try? VaultCrypto.open(entry, dataKey: key).utf8String()
}

@Test func everyFieldOfACurrentEntryIsAuthenticatedSetOrNot() throws {
    let key = SymmetricKey(size: .bits256)
    for meta in [full, VaultEntry.Metadata()] {
        let entry = try VaultCrypto.seal(name: "N", kind: .authKey, metadata: meta, secret: SecretBytes(utf8: "v"), dataKey: key)
        #expect(entry.format == 2)
        #expect(opens(entry, key) == "v")
        let changes: [(inout VaultEntry.Metadata) -> Void] = [
            { $0.teamID = $0.teamID == nil ? "OTHER12345" : nil }, { $0.keyID = $0.keyID == nil ? "K" : nil },
            { $0.issuerID = $0.issuerID == nil ? "i" : nil }, { $0.certificateID = $0.certificateID == nil ? "C" : nil },
            { $0.created = $0.created == nil ? Date(timeIntervalSince1970: 1) : nil }, { $0.expires = $0.expires == nil ? Date(timeIntervalSince1970: 1) : nil },
            { $0.role = $0.role == nil ? "ADMIN" : nil }, { $0.certificateType = $0.certificateType == nil ? "DEVELOPMENT" : nil },
            { $0.services = $0.services == nil ? "apns" : nil }, { $0.unknown["color"] = .string("red") },
        ]
        for (i, change) in changes.enumerated() {
            var altered = meta
            change(&altered)
            let e = VaultEntry(name: "N", kind: .authKey, metadata: altered, sealed: entry.sealed)
            #expect(opens(e, key) == nil, "change \(i) on \(meta == full ? "a full" : "an empty") entry went unnoticed")
        }
        #expect(opens(VaultEntry(name: "M", kind: .authKey, metadata: meta, sealed: entry.sealed), key) == nil)
        #expect(opens(VaultEntry(name: "N", kind: .generic, metadata: meta, sealed: entry.sealed), key) == nil)
        // Read as format 1, it is not the same associated data.
        #expect(opens(VaultEntry(name: "N", kind: .authKey, metadata: meta, sealed: entry.sealed, format: 1), key) == nil)
    }
}

@Test func strippingAFieldInTheFileFailsTheEntry() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (_, key) = try t.make(entries: [("XLESS_DIST_KEY", .signingKey, full, "pem")])
    try editJSON(t) { o in
        var list = try entries(o)
        var meta = try #require(list[0]["metadata"] as? [String: Any])
        meta["certificateType"] = nil
        list[0]["metadata"] = meta
        o["entries"] = list
    }
    let file = try #require(try t.store.read())
    do { _ = try VaultCrypto.open(file.entries[0], dataKey: key); Issue.record("opened a stripped entry") } catch let e as VaultError {
        #expect(e.kind == .tampered)
    }
}

@Test func aNewStoreIsVersionTwoAndItsEntriesSayTheirFormat() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: [("N", .generic, .init(), "v")])
    let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t.location.file)) as? [String: Any])
    #expect(o["version"] as? Int == 2)
    #expect(o["minimumReaderVersion"] as? Int == 2)
    #expect(try entries(o)[0]["version"] as? Int == 2)
}

@Test func aVersionOneStoreOpensAsOlderReleasesWroteIt() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let key = try makeLegacy(t, entries: [("ASC_KEY_P8", .ascAPIKey, .init(teamID: "TEAM123456", keyID: "K1", role: "ADMIN"), "p8")])
    let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t.location.file)) as? [String: Any])
    let first = try entries(o)[0]
    #expect(o["version"] as? Int == 1 && o["minimumReaderVersion"] == nil && first["version"] == nil)
    let file = try #require(try t.store.read())
    #expect(file.version == 1 && file.minimumReaderVersion == 1 && file.isWritable && file.needsUpgrade)
    #expect(opens(file.entries[0], key) == "p8")
    #expect(opens(file.entries[0], try VaultCrypto.unwrap(file, passphrase: SecretBytes(utf8: "correct horse battery"))) == "p8")
}

@Test func aKeylessWriteKeepsAVersionOneStore() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let key = try makeLegacy(t, entries: [("A", .generic, .init(), "a"), ("B", .generic, .init(role: "ADMIN"), "b")])
    let prompter = ScriptedPrompter([])
    try secretStore(t, prompter: prompter).update(reason: "removing A") { _ in [.remove(name: "A")] }
    #expect(prompter.asked == 0)
    let file = try #require(try t.store.read())
    #expect(file.version == 1 && file.entries.map(\.name) == ["B"] && file.entries[0].format == 1)
    #expect(opens(file.entries[0], key) == "b")
}

@Test func theFirstWriteWithTheKeyUpgradesEveryEntry() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let key = try makeLegacy(t, entries: [("ASC_KEY_P8", .ascAPIKey, .init(teamID: "TEAM123456", keyID: "K1", role: "ADMIN"), "p8"),
                                          ("NOTE", .generic, .init(), "note")])
    let prompter = ScriptedPrompter(["correct horse battery"])
    try secretStore(t, prompter: prompter).update(reason: "importing NEW") { _ in
        [.add(name: "NEW", kind: .password, metadata: .init(), secret: SecretBytes(utf8: "new"))]
    }
    #expect(prompter.asked == 1)
    let file = try #require(try t.store.read())
    #expect(file.version == 2 && file.minimumReaderVersion == 2 && !file.needsUpgrade)
    #expect(file.entries.map(\.format) == [2, 2, 2])
    #expect(file.entries.map { opens($0, key) } == ["p8", "note", "new"])
    #expect(file.entries[0].metadata.role == "ADMIN")
    // The role is now authenticated: stripping it fails the entry.
    try editJSON(t) { o in
        var list = try entries(o)
        var meta = try #require(list[0]["metadata"] as? [String: Any])
        meta["role"] = nil
        list[0]["metadata"] = meta
        o["entries"] = list
    }
    #expect(opens(try t.store.read()?.entry(named: "ASC_KEY_P8"), key) == nil)
}

@Test func anUpdateWithACachedKeyUpgradesWithoutAsking() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let key = try makeLegacy(t, entries: [("A", .generic, .init(), "a"), ("B", .generic, .init(), "b")])
    let cache = MemoryCache()
    let file = try #require(try t.store.read())
    try cache.store(id: file.id, key: VaultCrypto.keyBytes(key), seconds: 60)
    let prompter = ScriptedPrompter([])
    try secretStore(t, cache: cache, prompter: prompter).update(reason: "removing A") { _ in [.remove(name: "A")] }
    #expect(prompter.asked == 0)
    let after = try #require(try t.store.read())
    #expect(after.version == 2 && after.entries.map(\.format) == [2] && opens(after.entries[0], key) == "b")
}

@Test func passwdUpgradesToo() throws {
    var (file, key) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "old passphrase"), kdf: testKDF())
    file.version = 1
    file.minimumReaderVersion = 1
    file.entries = [try legacySeal("N", .generic, .init(role: "ADMIN"), "v", key: key)]
    let upgraded = try VaultCrypto.rewrap(try VaultCrypto.upgrade(file, dataKey: key), dataKey: key, passphrase: SecretBytes(utf8: "new passphrase"), kdf: testKDF())
    #expect(upgraded.version == 2 && upgraded.entries[0].format == 2)
    let again = try VaultCrypto.unwrap(upgraded, passphrase: SecretBytes(utf8: "new passphrase"))
    #expect(opens(upgraded.entries[0], again) == "v")
    #expect(throws: VaultError.self) { try VaultCrypto.upgrade(file, dataKey: SymmetricKey(size: .bits256)) }
}

@Test func aTamperedEntryIsLeftAsItIsByTheUpgrade() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let key = try makeLegacy(t, entries: [("GOOD", .generic, .init(), "good"), ("BAD", .generic, .init(keyID: "K1"), "bad")])
    try editJSON(t) { o in
        var list = try entries(o)
        list[1]["metadata"] = ["keyID": "K2"]
        o["entries"] = list
    }
    try secretStore(t, prompter: ScriptedPrompter(["correct horse battery"])).update(reason: "importing NEW") { _ in
        [.add(name: "NEW", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "new"))]
    }
    let file = try #require(try t.store.read())
    #expect(file.version == 2)
    #expect(opens(file.entry(named: "GOOD"), key) == "good" && opens(file.entry(named: "NEW"), key) == "new")
    #expect(opens(file.entry(named: "BAD"), key) == nil)
}

@Test func anOlderEntryPutIntoACurrentStoreNeverOpens() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (_, key) = try t.make(entries: [("N", .generic, .init(role: "ADMIN"), "v")])
    // A format-1 seal of the same entry without its role (an old copy, stripped) put in its place.
    let old = try legacySeal("N", .generic, .init(), "v", key: key)
    try editJSON(t) { o in
        var list = try entries(o)
        list[0]["metadata"] = [String: Any]()
        list[0]["sealed"] = old.sealed.base64EncodedString()
        list[0]["version"] = nil
        o["entries"] = list
    }
    let file = try #require(try t.store.read())
    #expect(file.entries[0].format == 0)
    #expect(opens(file.entries[0], key) == nil)
    try editJSON(t) { o in
        var list = try entries(o)
        list[0]["version"] = 1
        o["entries"] = list
    }
    #expect(opens(try t.store.read()?.entries[0], key) == nil)
}

@Test func aStoreANewerXlessWroteIsReadButNeverRewritten() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (_, key) = try t.make(entries: [("KNOWN", .generic, .init(), "known")])
    try editJSON(t) { o in
        o["version"] = 3
        o["minimumReaderVersion"] = 3
        var list = try entries(o)
        var future = list[0]
        future["name"] = "FUTURE"
        future["version"] = 3
        list.append(future)
        o["entries"] = list
    }
    let before = try Data(contentsOf: t.location.file)
    let file = try #require(try t.store.read())
    #expect(file.version == 3 && !file.isWritable)
    #expect(opens(file.entry(named: "KNOWN"), key) == "known")
    do { _ = try VaultCrypto.open(try #require(file.entry(named: "FUTURE")), dataKey: key); Issue.record("opened a newer entry") } catch let e as VaultError {
        #expect(e.kind == .newerFormat && e.fix.contains("upgrade xless"))
    }
    let store = secretStore(t, prompter: ScriptedPrompter([]))
    let catalog = try store.existingCatalog()
    #expect(throws: VaultError.self) { try catalog.requireWritable() }
    for attempt in [{ try t.store.update { $0 } },
                    { try store.update(reason: "removing KNOWN") { _ in [.remove(name: "KNOWN")] } }] as [() throws -> Void] {
        do { try attempt(); Issue.record("rewrote a newer store") } catch let e as VaultError {
            #expect(e.kind == .newerFormat)
            #expect(e.cause.contains("newer xless") && e.fix.contains("unchanged"))
        }
    }
    #expect(try Data(contentsOf: t.location.file) == before)
}

@Test func fieldsThisXlessDoesNotKnowSurviveARewrite() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (_, key) = try t.make(entries: [("KNOWN", .generic, .init(teamID: "TEAM123456"), "known")])
    let future: [String: Any] = ["list": [1, 2.5, true, NSNull(), "x"], "nested": ["a": "b"]]
    try editJSON(t) { o in
        o["version"] = 3 // a newer xless whose additions survive this one's rewrites
        o["future"] = future
        var list = try entries(o)
        list[0]["note"] = "kept"
        var newer = list[0]
        newer["name"] = "NEWER"
        newer["version"] = 3
        var meta = try #require(newer["metadata"] as? [String: Any])
        meta["color"] = "red"
        newer["metadata"] = meta
        list.append(newer)
        o["entries"] = list
    }
    let read = try #require(try t.store.read())
    #expect(read.isWritable && read.minimumReaderVersion == 2)
    try secretStore(t, prompter: ScriptedPrompter(["correct horse battery"])).update(reason: "importing NEW") { _ in
        [.add(name: "NEW", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "new"))]
    }
    let after = try #require(try t.store.read())
    #expect(after.version == 3 && after.unknown == read.unknown && !after.unknown.isEmpty)
    #expect(after.entry(named: "NEWER") == read.entry(named: "NEWER"))
    #expect(after.entry(named: "NEWER")?.metadata.unknown["color"] == .string("red"))
    #expect(after.entry(named: "KNOWN")?.unknown["note"] == .string("kept"))
    #expect(opens(after.entry(named: "KNOWN"), key) == "known" && opens(after.entry(named: "NEW"), key) == "new")
    let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: t.location.file)) as? [String: Any])
    let nested = try #require(o["future"] as? [String: Any])
    #expect(nested["nested"] as? [String: String] == ["a": "b"])
    #expect((nested["list"] as? [Any])?.count == 5)
    #expect(after.unknown["future"] == .object(["list": .array([.integer(1), .number(2.5), .bool(true), .null, .string("x")]),
                                                 "nested": .object(["a": .string("b")])]))
}

@Test func aNewerStoreThisXlessCannotDecodeIsNeverCalledCorrupt() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    try t.make(entries: [("N", .generic, .init(), "v")])
    try editJSON(t) { o in
        o["version"] = 3
        var list = try entries(o)
        list[0]["kind"] = "future-kind"
        o["entries"] = list
    }
    do { _ = try t.store.read(); Issue.record("read a store it cannot decode") } catch let e as VaultError {
        #expect(e.kind == .newerFormat && e.fix.contains("upgrade xless") && !e.fix.contains("secrets init"))
    }
    // The same damage in a store of a format this xless knows is an integrity error.
    try editJSON(t) { o in o["version"] = 2 }
    do { _ = try t.store.read(); Issue.record("read a malformed store") } catch let e as VaultError { #expect(e.kind == .tampered) }
}

@Test func theKeyAndKeyCheckOfAVersionOneStoreAuthenticateWhatOlderReleasesWrote() throws {
    var (file, _) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "pass phrase"), kdf: testKDF())
    // The previous release's layout, which put the file's version (always 1 there) into both.
    var header = Data("xless-vault-header/1\u{0}xless-vault\u{0}\(file.id)\u{0}scrypt\u{0}".utf8)
    header.append(file.kdf.salt)
    header.append(Data("\u{0}1024\u{0}8\u{0}1".utf8))
    let check = Data("xless-vault-key-check/1\u{0}\(file.id)".utf8)
    for version in [1, 2, 3] {
        file.version = version
        #expect(file.headerAssociatedData == header && file.keyCheckAssociatedData == check)
    }
}

@Test func anEntryMarkerTheStoreVersionMakesInvalidIsWrittenBackAsItWasRead() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    let (_, key) = try t.make(entries: [("A", .generic, .init(), "a"), ("B", .generic, .init(), "b")])
    try editJSON(t) { o in o["version"] = 1 } // set back: every entry now carries a marker a version-1 store does not have
    let read = try #require(try t.store.read())
    #expect(read.entries.map(\.format) == [0, 0])
    try secretStore(t, prompter: ScriptedPrompter([])).update(reason: "removing A") { _ in [.remove(name: "A")] }
    try editJSON(t) { o in
        o["version"] = 2
        o["minimumReaderVersion"] = 2
    }
    #expect(opens(try t.store.read()?.entry(named: "B"), key) == "b")
}

@Test func listShowsTypeRoleAndServices() throws {
    let entry = try VaultCrypto.seal(name: "XLESS_APNS_KEY", kind: .authKey, metadata: full, secret: SecretBytes(utf8: "p8"),
                                     dataKey: SymmetricKey(size: .bits256))
    let file = SecretCatalog(id: "x", entries: [entry])
    let list = VaultReport.list(file)
    let header = try #require(list.split(separator: "\n").first)
    #expect(header.contains("TYPE") && header.contains("ROLE") && header.contains("SERVICES"))
    #expect(list.contains("DISTRIBUTION") && list.contains("ADMIN") && list.contains("apns,siwa"))
}

@Test func statusSaysWhenTheStoreIsOldOrNewer() throws {
    let t = try TempStore()
    defer { t.cleanup() }
    var (file, _) = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "pass phrase"), kdf: testKDF())
    let current = VaultReport.status(location: t.location, file: file, unlocked: nil)
    #expect(current.contains("version 2") && !current.contains("sealed again") && !current.contains("newer xless"))
    file.version = 1
    file.minimumReaderVersion = 1
    #expect(VaultReport.status(location: t.location, file: file, unlocked: nil).contains("sealed again with every field"))
    file.version = 3
    file.minimumReaderVersion = 3
    #expect(VaultReport.status(location: t.location, file: file, unlocked: nil).contains("upgrade xless"))
}
