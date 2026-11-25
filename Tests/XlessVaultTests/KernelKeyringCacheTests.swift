import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

/// With a session keyring (Linux; not under Docker's default seccomp profile, nor on macOS).
private let keyringAvailable = KernelKeyring.isAvailable
private let hold = SecretHold(seconds: 1800, idle: 600, maximum: 7200)

@Test(.enabled(if: keyringAvailable)) func theKeyringKnowsWhenThePassphraseWasTyped() throws {
    let cache = KernelKeyringCache(), id = "test-\(UUID().uuidString)", key = SecretBytes(utf8: "unwrapped-data-key")
    defer { _ = try? cache.forget(id: id) }
    try cache.store(key, id: id, place: "", hold: hold, typedAgo: 0)
    #expect((0...2).contains(try #require(cache.held(id: id)?.typedAgo)))
    try cache.store(key, id: id, place: "", hold: hold, typedAgo: 500) // a renewal
    #expect((500...502).contains(try #require(cache.held(id: id)?.typedAgo)))
    #expect((1798...1800).contains(Int(try #require(cache.held(id: id)?.expires).timeIntervalSinceNow.rounded(.up))))
    #expect(try cache.load(id: id, using: true) { $0 == key } == key)
    #expect(try cache.forget(id: id))
    #expect(cache.held(id: id) == nil)
}

@Test(.enabled(if: keyringAvailable)) func aRenewalInTheKeyringIsNoLongerThanTheMaximumSinceThePassphraseWasTyped() throws {
    let cache = KernelKeyringCache(), id = "test-\(UUID().uuidString)", key = SecretBytes(utf8: "unwrapped-data-key")
    defer { _ = try? cache.forget(id: id) }
    try cache.store(key, id: id, place: "", hold: SecretHold(seconds: 1800, idle: 600, maximum: 2000), typedAgo: 1500)
    #expect(Int(try #require(cache.held(id: id)?.expires).timeIntervalSinceNow.rounded(.up)) <= 500)
    #expect(throws: VaultError.self) { try cache.store(key, id: id, place: "", hold: hold, typedAgo: 7200) }
}

@Test(.enabled(if: keyringAvailable)) func aKeyOfAnOlderXlessIsHeldButNobodyKnowsSinceWhen() throws {
    let cache = KernelKeyringCache(), id = "test-\(UUID().uuidString)"
    defer { _ = try? cache.forget(id: id) }
    try KernelKeyring.store(name: KernelKeyringCache.keyName(id), secret: SecretBytes(utf8: "unwrapped-data-key"), timeout: 60)
    #expect(cache.held(id: id) == HeldUnlock(backend: .keyring, expires: nil))
}
