import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

/// A directory holding `xless-credential-<name>` scripts, and a HOME the helpers keep their files in.
private struct HelperDir {
    let root: URL
    var bin: URL { root.appendingPathComponent("bin") }
    var home: URL { root.appendingPathComponent("home") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-helper-\(UUID().uuidString)")
        for dir in [bin, home] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func script(_ name: String, _ body: String, mode: Int = 0o755) throws -> URL {
        let url = bin.appendingPathComponent("xless-credential-\(name)")
        try ExecutableFile.write("#!/bin/sh\n\(body)\n", to: url, mode: mode_t(mode), stage: .config)
        return url
    }

    var env: [String: String] { ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path] }

    func store(_ name: String, extra: [String: String] = [:], timeout: Double = 20) throws -> HelperSecretStore {
        HelperSecretStore(helper: try CredentialHelper.find(name: name, env: env.merging(extra) { $1 }, timeout: timeout))
    }

    func read(_ file: String) throws -> String { try String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) }
}

/// A helper keeping each credential as its `store` JSON in $HOME/creds/ (which is what `get` prints back).
private let fileHelper = #"""
mkdir -p "$HOME/creds"
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._@-' '_'; }
case "$1" in
store)
  json=$(cat)
  url=$(printf '%s' "$json" | sed -n 's/^{"ServerURL":"\([^"]*\)".*/\1/p')
  printf '%s' "$json" > "$HOME/creds/$(key "$url")" ;;
get)
  url=$(cat)
  f="$HOME/creds/$(key "$url")"
  if [ -f "$f" ]; then cat "$f"; else echo "credentials not found in native keychain"; exit 1; fi ;;
erase)
  url=$(cat)
  rm "$HOME/creds/$(key "$url")" ;;
list)
  printf '{"https://index.docker.io/v1/":"someone"'
  for f in "$HOME"/creds/*; do
    [ -f "$f" ] || continue
    url=$(sed -n 's/^{"ServerURL":"\([^"]*\)".*/\1/p' "$f")
    user=$(sed -n 's/.*"Username":"\(.*\)","Secret":".*/\1/p' "$f")
    printf ',"%s":"%s"' "$url" "$user"
  done
  printf '}' ;;
*) exit 2 ;;
esac
"""#

private let pem = "-----BEGIN PRIVATE KEY-----\nMIG\"quote\\back/slash\té\n-----END PRIVATE KEY-----\n"

@Test func aHelperKeepsEntriesWithTheirMetadataAndExactValues() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("files", fileHelper)
    let store = try dir.store("files")
    #expect(try store.catalog()?.entries.isEmpty == true) // the docker credential is not xless's
    let meta = VaultEntry.Metadata(teamID: "ABCDE12345", keyID: "2X9R4HXF34", issuerID: "69a6de7e-f8f8-47e3-e053-5b8c7c11a4d1",
                                   created: Date(timeIntervalSince1970: 1_700_000_000.7), role: "ADMIN,FINANCE")
    try store.update(reason: "test") { _ in [.add(name: "ASC_KEY_P8@ABCDE12345", kind: .ascAPIKey, metadata: meta, secret: SecretBytes(utf8: pem))] }
    let catalog = try #require(try store.catalog())
    let entry = try #require(catalog.entry(named: "ASC_KEY_P8@ABCDE12345"))
    #expect(entry.kind == .ascAPIKey)
    #expect(entry.metadata == meta)
    #expect(try store.secret(entry, in: catalog, reason: "test").utf8String() == pem)

    let secrets = Secrets(env: [:], fallback: VaultResolver(secrets: store, team: "ABCDE12345"))
    #expect(try secrets.optional("ASC_KEY_P8") == pem)
    #expect(try secrets.optional("ASC_KEY_ID") == "2X9R4HXF34")
    #expect(try secrets.optional("ASC_ISSUER_ID") == "69a6de7e-f8f8-47e3-e053-5b8c7c11a4d1")
    #expect(try secrets.optional("XLESS_DIST_KEY") == nil)

    // Taken names are refused; replace and remove work.
    #expect(throws: VaultError.self) {
        try store.update(reason: "test") { _ in [.add(name: "ASC_KEY_P8@ABCDE12345", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "x"))] }
    }
    try store.update(reason: "test") { _ in [.replace(name: "ASC_KEY_P8@ABCDE12345", kind: .ascAPIKey, metadata: .init(keyID: "NEWKEY0000"), secret: SecretBytes(utf8: "v2"))] }
    #expect(try store.catalog()?.entry(named: "ASC_KEY_P8@ABCDE12345")?.metadata.keyID == "NEWKEY0000")
    try store.update(reason: "test") { _ in [.remove(name: "ASC_KEY_P8@ABCDE12345"), .remove(name: "NOT_THERE")] }
    #expect(try store.catalog()?.entries.isEmpty == true)
}

@Test func aCredentialTheHelperNoLongerHasIsMissing() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("files", fileHelper)
    let store = try dir.store("files")
    #expect(try store.get("GONE") == nil)
    let gone = VaultEntry(name: "GONE", kind: .generic, metadata: .init(), sealed: Data())
    let e = #expect(throws: VaultError.self) { try store.secret(gone, in: SecretCatalog(id: "x", entries: [gone]), reason: "test") }
    #expect(e?.kind == .noEntry)
}

@Test func aHelperThatHangsIsStoppedWithItsChildren() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("hang", "sleep 600 & sleep 600")
    let store = try dir.store("hang", timeout: 1)
    let started = Date()
    let e = #expect(throws: VaultError.self) { try store.catalog() }
    #expect(e?.cause.contains("did not finish within 1 s") == true, "\(e?.cause ?? "")")
    #expect(Date().timeIntervalSince(started) < 15)
}

@Test func aHelperWhoseChildKeepsItsOutputOpenIsStopped() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("linger", "printf '{}'; (sleep 600) & exit 0")
    let started = Date()
    let e = #expect(throws: VaultError.self) { try dir.store("linger", timeout: 1).catalog() }
    #expect(e?.cause.contains("did not finish") == true)
    #expect(Date().timeIntervalSince(started) < 15)
}

@Test func junkFromAHelperIsAnErrorThatDoesNotQuoteIt() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("junk", "cat > /dev/null; echo 'SECRET-LOOKING JUNK'")
    let store = try dir.store("junk")
    for call in [{ _ = try store.catalog() }, { _ = try store.get("A") }] as [() throws -> Void] {
        let e = #expect(throws: VaultError.self) { try call() }
        #expect(e?.cause.contains("not a credential helper's JSON answer") == true)
        #expect(e?.description.contains("JUNK") == false)
    }
    // An `xless:` credential whose description is not xless's.
    try dir.script("label", #"printf '{"xless:A":"not json"}'"#)
    let e = #expect(throws: VaultError.self) { try dir.store("label").catalog() }
    #expect(e?.cause.contains("xless:A") == true)
}

@Test func aFailedGetIsNeverQuotedButAFailedListIs() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("fail", #"cat > /dev/null; echo "boom: keyring is locked"; exit 3"#)
    let store = try dir.store("fail")
    let list = #expect(throws: VaultError.self) { try store.catalog() }
    #expect(list?.cause.contains("list failed (exit 3): boom: keyring is locked") == true, "\(list?.cause ?? "")")
    let get = #expect(throws: VaultError.self) { try store.get("A") }
    #expect(get?.cause.contains("exit 3") == true)
    #expect(get?.cause.contains("boom") == false)
}

@Test func tooMuchOutputIsCutShort() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("flood", "exec cat /dev/zero")
    let e = #expect(throws: VaultError.self) { try dir.store("flood").catalog() }
    #expect(e?.cause.contains("more than 4 MiB") == true)
}

@Test func theHelperSeesOnlyTheVerbAndAnAllowedEnvironment() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("spy", #"""
    { printf 'argc=%s\n' "$#"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; env; } >> "$HOME/seen"
    cat > /dev/null
    printf '{}'
    """#)
    let store = try dir.store("spy", extra: ["ASC_KEY_P8": "LEAKED", "XLESS_DIST_KEY_FILE": "/leak", "FOO": "bar",
                                            "PASSWORD_STORE_DIR": "/pw", "LC_ALL": "C", "GNUPGHOME": "/g"])
    _ = try store.catalog()
    try store.update(reason: "test") { _ in [.add(name: "N", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "THE-SECRET-VALUE"))] }
    let seen = try dir.read("seen")
    #expect(seen.contains("argc=1\narg=list\n") && seen.contains("argc=1\narg=store\n"), "\(seen)")
    #expect(!seen.contains("LEAKED") && !seen.contains("/leak") && !seen.contains("FOO=") && !seen.contains("THE-SECRET-VALUE"))
    #expect(seen.contains("PASSWORD_STORE_DIR=/pw") && seen.contains("LC_ALL=C") && seen.contains("GNUPGHOME=/g"))
}

@Test func aHelperThatStopsReadingDoesNotKillXless() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("deaf", "exit 0")
    let big = SecretBytes(utf8: String(repeating: "A", count: 1 << 20))
    try dir.store("deaf").store(name: "BIG", kind: .generic, metadata: .init(), secret: big)
}

@Test func secretsThatAreNotTextAreRefused() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("files", fileHelper)
    let store = try dir.store("files")
    for bytes in [[0x41, 0x00, 0x42], [0xff, 0xfe]] as [[UInt8]] {
        let e = #expect(throws: VaultError.self) { try store.store(name: "BIN", kind: .generic, metadata: .init(), secret: SecretBytes(copying: bytes)) }
        #expect(e?.kind == .invalidSecret)
    }
}

@Test func onlyASafeHelperOnPathIsRun() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    #expect(throws: VaultError.self) { try dir.store("missing") }
    let helper = try dir.script("files", fileHelper, mode: 0o775)
    let e = #expect(throws: VaultError.self) { try dir.store("files") }
    #expect(e?.cause.contains("can be written by other users") == true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.bin.path)
    #expect(throws: VaultError.self) { try dir.store("files") }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.bin.path)
    #expect(try dir.store("files").helper.executable == helper.resolvingSymlinksInPath().path)
    // Relative PATH entries are never searched.
    #expect(throws: VaultError.self) { try CredentialHelper.find(name: "files", env: ["PATH": "bin:.", "HOME": dir.home.path]) }
    // A name is never a path.
    #expect(throws: VaultError.self) { try CredentialHelper.find(name: "../bin/sh", env: dir.env) }
    // Not executable: skipped.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
    #expect(throws: VaultError.self) { try dir.store("files") }
}

@Test func theConfiguredStoreFollowsConfigYml() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("files", fileHelper)
    var env = dir.env
    env["XDG_CONFIG_HOME"] = dir.root.appendingPathComponent("config").path
    env["XDG_DATA_HOME"] = dir.root.appendingPathComponent("data").path
    guard case .vault(let vault) = try ConfiguredSecretStore.load(env: env, cache: nil, prompter: { nil }) else { Issue.record("not the vault"); return }
    #expect(vault.vault.location.directory.path.hasPrefix(dir.root.path))
    let file = UserConfig.file(env: env)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("secrets:\n  backend: helper\n  helper: files\n".utf8).write(to: file)
    guard case .helper(let helper) = try ConfiguredSecretStore.load(env: env, cache: nil, prompter: { nil }) else { Issue.record("not the helper"); return }
    #expect(helper.helper.name == "files")
    try Data("secrets:\n  backend: helper\n  helper: nope\n".utf8).write(to: file)
    #expect(throws: VaultError.self) { try ConfiguredSecretStore.load(env: env, cache: nil, prompter: { nil }) }
}

@Test func theHelperInheritsNoOpenFileOfXless() throws {
    #if os(Linux)
    let dir = try HelperDir()
    defer { dir.cleanup() }
    let marker = dir.root.appendingPathComponent("open-in-xless")
    try Data("x".utf8).write(to: marker)
    let fd = open(marker.path, O_RDONLY) // no O_CLOEXEC: a child would inherit it
    #expect(fd >= 3)
    defer { close(fd) }
    try dir.script("fds", #"for f in /proc/$$/fd/*; do readlink "$f"; done > "$HOME/fds"; printf '{}'"#)
    _ = try dir.store("fds").catalog()
    let fds = try dir.read("fds")
    #expect(!fds.contains("open-in-xless"), "\(fds)")
    #endif
}

/// A stand-in for `pass`: entries in clear under $PASSWORD_STORE_DIR (what the reference helper needs of it).
private let stubPass = #"""
set -eu
d=$PASSWORD_STORE_DIR
case "$1" in
  insert) mkdir -p "$(dirname "$d/$4")"; echo "Enter contents of $4:"; cat > "$d/$4.gpg" ;;
  show) [ -f "$d/$2.gpg" ] || exit 1; cat "$d/$2.gpg" ;;
  rm) rm -rf "${d:?}/$4" ;;
esac
"""#

@Test func theShippedPassHelperKeepsWhatXlessGivesIt() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/credential-helpers/xless-credential-pass")
    try dir.script("pass", try String(contentsOf: shipped, encoding: .utf8).replacingOccurrences(of: "#!/bin/sh\n", with: ""))
    let tools = dir.root.appendingPathComponent("tools")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let pass = tools.appendingPathComponent("pass")
    try ExecutableFile.write("#!/bin/sh\n\(stubPass)\n", to: pass, stage: .config)
    var env = dir.env
    env["PATH"] = "\(dir.bin.path):\(tools.path):/usr/bin:/bin"
    env["PASSWORD_STORE_DIR"] = dir.home.appendingPathComponent("pw").path
    let store = HelperSecretStore(helper: try CredentialHelper.find(name: "pass", env: env))

    let tricky = pem + "\u{1}\u{1f}\u{7f}\r\n\n"
    let meta = VaultEntry.Metadata(teamID: "ABCDE12345", certificateID: "C1", expires: Date(timeIntervalSince1970: 1_900_000_000))
    try store.update(reason: "test") { _ in
        [.add(name: "XLESS_DIST_KEY@ABCDE12345", kind: .signingKey, metadata: meta, secret: SecretBytes(utf8: tricky)),
         .add(name: "XLESS_DEMO_PASSWORD", kind: .password, metadata: .init(), secret: SecretBytes(utf8: ""))]
    }
    let catalog = try store.existingCatalog()
    #expect(catalog.entries.map(\.name).sorted() == ["XLESS_DEMO_PASSWORD", "XLESS_DIST_KEY@ABCDE12345"])
    let entry = try #require(catalog.entry(named: "XLESS_DIST_KEY@ABCDE12345"))
    #expect(entry.kind == .signingKey && entry.metadata == meta)
    #expect(try store.secret(entry, in: catalog, reason: "test").utf8String() == tricky)
    #expect(try store.secret(try #require(catalog.entry(named: "XLESS_DEMO_PASSWORD")), in: catalog, reason: "test").isEmpty)
    #expect(try VaultResolver(secrets: store).preferring(team: "ABCDE12345").lookup("XLESS_DIST_KEY", stage: .sign) == tricky)
    try store.update(reason: "test") { _ in [.remove(name: "XLESS_DEMO_PASSWORD")] }
    #expect(try store.existingCatalog().entries.map(\.name) == ["XLESS_DIST_KEY@ABCDE12345"])
}

@Test func aFailedStoreIsNeverQuotedAndLookupsListOnce() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    // Echoes its request back, then fails: the value must not reach the error.
    try dir.script("echo", #"if [ "$1" = list ]; then echo list >> "$HOME/runs"; printf '%s' '{"xless:A":"{\"kind\":\"generic\"}"}'; exit 0; fi; cat; exit 1"#)
    let store = try dir.store("echo")
    let e = #expect(throws: VaultError.self) { try store.store(name: "A", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "TOP-SECRET")) }
    #expect(e?.cause.contains("store failed (exit 1)") == true)
    #expect(e?.description.contains("TOP-SECRET") == false)
    // One `list` for any number of lookups (the vault's metadata check is not needed here either).
    let resolver = VaultResolver(secrets: store)
    for _ in 0..<3 { _ = try? resolver.lookup("B", stage: .config) }
    #expect(try dir.read("runs") == "list\n")
}

// MARK: - The test write before a key Apple offers once (#141), and the writers' lock

/// `fileHelper`, steered by files in $HOME: `fail-<verb>` makes that verb fail, `lose` makes `get` answer another value,
/// `log` records each verb, and `slow` makes `store` log `start`/`end` around a pause.
private let steeredHelper = #"""
[ -f "$HOME/log" ] && echo "$1" >> "$HOME/log"
if [ -f "$HOME/fail-$1" ]; then echo "broken $1" >&2; exit 1; fi
if [ "$1" = get ] && [ -f "$HOME/lose" ]; then
  url=$(cat)
  printf '{"ServerURL":"%s","Username":"{}","Secret":"something else"}' "$url"
  exit 0
fi
if [ "$1" = store ] && [ -f "$HOME/slow" ]; then
  echo start >> "$HOME/slow"; sleep 0.3; echo end >> "$HOME/slow"
fi
"""# + "\n" + fileHelper

private func steered(_ dir: HelperDir, lock: VaultLocation? = nil) throws -> HelperSecretStore {
    try dir.script("steered", steeredHelper)
    return HelperSecretStore(helper: try CredentialHelper.find(name: "steered", env: dir.env), lock: lock)
}

private func touch(_ dir: HelperDir, _ file: String) throws { try Data().write(to: dir.home.appendingPathComponent(file)) }

private func probeFiles(_ dir: HelperDir) throws -> [String] {
    let creds = dir.home.appendingPathComponent("creds")
    return ((try? FileManager.default.contentsOfDirectory(atPath: creds.path)) ?? []).filter { $0.contains("probe") }
}

@Test func theProbeStoresReadsBackAndErasesOncePerProcess() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    let store = try steered(dir)
    try touch(dir, "log")
    try store.probeWrites(reason: "storing the new API key")
    try store.probeWrites(reason: "storing the new API key")
    #expect(try dir.read("log") == "store\nget\nerase\n")
    #expect(try probeFiles(dir).isEmpty)
    #expect(try store.catalog()?.entries.isEmpty == true)
}

@Test func aProbeCatchesAHelperThatCannotStore() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    let store = try steered(dir)
    try touch(dir, "fail-store")
    let e = #expect(throws: VaultError.self) { try store.probeWrites(reason: "storing the new API key") }
    #expect(e?.kind == .helper)
    #expect(e?.cause.contains("test write") == true && e?.cause.contains("before storing the new API key") == true, "\(e?.cause ?? "")")
    #expect(e?.fix.contains("nothing was created") == true)
    #expect(try probeFiles(dir).isEmpty)
    // Not remembered as passed: once the helper works, the next probe runs.
    try FileManager.default.removeItem(at: dir.home.appendingPathComponent("fail-store"))
    try store.probeWrites(reason: "x")
}

@Test func aProbeCatchesAHelperThatLosesTheValue() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    let store = try steered(dir)
    try touch(dir, "lose")
    let e = #expect(throws: VaultError.self) { try store.probeWrites(reason: "storing the new auth key") }
    #expect(e?.cause.contains("another value") == true, "\(e?.cause ?? "")")
    #expect(try probeFiles(dir).isEmpty) // erased again
}

@Test func aProbeEntryTheHelperCannotEraseIsNamed() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    let store = try steered(dir)
    try touch(dir, "fail-erase")
    let e = #expect(throws: VaultError.self) { try store.probeWrites(reason: "storing the new auth key") }
    #expect(e?.cause.contains("may still hold the throwaway entry xless-helper-probe.") == true, "\(e?.cause ?? "")")
    #expect(e?.fix.contains("xless secrets rm xless-helper-probe.") == true)
    let left = try #require(try store.catalog()?.entries.first)
    #expect(left.name.hasPrefix("xless-helper-probe.") && left.kind == .generic)
}

@Test func concurrentHelperWritesTakeTurnsUnderTheVaultsLock() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    let lock = VaultLocation(directory: dir.root.appendingPathComponent("data/xless/vault"))
    _ = try steered(dir, lock: lock)
    try Data().write(to: dir.home.appendingPathComponent("slow"))
    final class Failures: @unchecked Sendable {
        let lock = NSLock()
        var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
    }
    let failures = Failures()
    DispatchQueue.concurrentPerform(iterations: 3) { i in
        do {
            // One store object per "command", as two xless processes would have.
            let store = try steered(dir, lock: lock)
            try store.update(reason: "test") { _ in [.add(name: "ENTRY_\(i)", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "v\(i)"))] }
        } catch { failures.add("\(error)") }
    }
    #expect(failures.all.isEmpty, "\(failures.all)")
    #expect(try dir.read("slow") == String(repeating: "start\nend\n", count: 3))
    #expect(try steered(dir).catalog()?.entries.count == 3)
    // The lock's directory is made private, as the vault's.
    let attributes = try FileManager.default.attributesOfItem(atPath: lock.directory.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o700)
}

@Test func theConfiguredHelperUsesTheVaultsLockFile() throws {
    let dir = try HelperDir()
    defer { dir.cleanup() }
    try dir.script("files", fileHelper)
    let env = dir.env.merging(["XDG_CONFIG_HOME": dir.root.appendingPathComponent("config").path,
                               "XDG_DATA_HOME": dir.root.appendingPathComponent("data").path]) { $1 }
    let file = UserConfig.file(env: env)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("secrets:\n  backend: helper\n  helper: files\n".utf8).write(to: file)
    guard case .helper(let helper) = try ConfiguredSecretStore.load(env: env, cache: nil, prompter: { nil }) else {
        Issue.record("not the helper"); return
    }
    #expect(helper.writersLock == VaultLocation.standard(env: env))
    try helper.update(reason: "test") { _ in [.add(name: "A", kind: .generic, metadata: .init(), secret: SecretBytes(utf8: "a"))] }
    #expect(FileManager.default.fileExists(atPath: VaultLocation.standard(env: env).lockFile.path))
}
