import Foundation
import Testing
@testable import XlessCore

@Test func aBuildsEnvironmentHasNoVariableThatItHasNoUseFor() {
    let base = ["PATH": "/opt/bin:bin::.:/usr/bin", "HOME": "/Users/me", "TMPDIR": "/t", "LC_ALL": "C", "GITHUB_TOKEN": "secret", "NPM_TOKEN": "secret", "SSH_AUTH_SOCK": "/s", "AWS_SECRET_ACCESS_KEY": "secret",
                "ASC_KEY_P8": "secret", "DYLD_INSERT_LIBRARIES": "/x", "NODE_OPTIONS": "--require /x", "RUBYOPT": "-r/x", "GIT_SSH_COMMAND": "x", "XLESS_SESSION": "/x", "XLESS_CONFIG_HOME": "x", "HTTPS_PROXY": "http://p"]
    #expect(BuildPlaces.environment(base, home: "/h", temporary: "/h/tmp") == [
        "PATH": "/opt/bin:/usr/bin", "LC_ALL": "C", "HTTPS_PROXY": "http://p", "HOME": "/h", "CFFIXED_USER_HOME": "/h", "TMPDIR": "/h/tmp", "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1",
    ])
    #expect(BuildPlaces.environment([:], home: "/h", temporary: "/t")["LANG"] == "en_US.UTF-8")
    #expect(BuildPlaces.variables.isDisjoint(with: SecretEnvironment.names))
}

@Test func ofAHomeOnlyTheToolsAreOpen() throws {
    let fm = FileManager.default, made = fm.temporaryDirectory.appendingPathComponent("xless-places-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: made) }
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    let home = BuildSandbox.real(made.path) + "/me"
    func directory(_ path: String) throws { try fm.createDirectory(atPath: "\(home)/\(path)", withIntermediateDirectories: true) }
    func program(_ path: String) throws {
        try directory((path as NSString).deletingLastPathComponent)
        _ = fm.createFile(atPath: "\(home)/\(path)", contents: Data(), attributes: [.posixPermissions: 0o755])
    }
    for path in [".rustup/toolchains/stable", ".rustup/downloads", ".nvm/versions/node/v22/lib", ".nvm/versions/node/v22/private", ".local/share/keys", ".local/lib", "bin", "lib", "share", ".cargo/registry",
                 "tools/ruby/3/lib", "tools/ruby/3/share"] { try directory(path) }
    for path in [".nvm/versions/node/v22/bin/node", ".local/bin/x", ".cargo/bin/cargo", "tools/ruby/3/bin/ruby", ".cargo/credentials.toml"] { try program(path) }
    try fm.createSymbolicLink(atPath: "\(home)/bin/ruby", withDestinationPath: "../tools/ruby/3/bin/ruby")
    let path = [".nvm/versions/node/v22/bin", ".local/bin", "bin", ".cargo/bin", "not-there"].map { "\(home)/\($0)" } + [home, "/usr/bin"]
    let found = BuildPlaces.tools(["PATH": path.joined(separator: ":")], home: home, closed: [BuildSandbox.real(made.path)])
    #expect(Set(found.reads) == Set([
        ".rustup/toolchains", ".nvm/versions/node/v22/bin", ".nvm/versions/node/v22/lib", ".local/bin", ".local/lib", "bin", ".cargo/bin", "tools/ruby/3/bin", "tools/ruby/3/lib", "tools/ruby/3/share",
    ].map { "\(home)/\($0)" }))
    #expect(found.variables == ["RUSTUP_HOME": "\(home)/.rustup"])
    // one whose variable says so is elsewhere
    try directory("elsewhere/toolchains")
    #expect(BuildPlaces.tools(["PATH": "/usr/bin", "RUSTUP_HOME": "\(home)/elsewhere"], home: home, closed: [BuildSandbox.real(made.path)]).reads == ["\(home)/elsewhere/toolchains"])
    // what is open anyway needs no rule
    #expect(BuildPlaces.tools(["PATH": path.joined(separator: ":")], home: home, closed: []).reads.isEmpty)
}

@Test func aHomeAndWhatIsAboveItIsBroad() {
    for path in ["/", "/Users", "/Users/me", "/Users/other", "/Volumes", "/Volumes/Disk", "/private", "/private/tmp", "/private/var/folders"] { #expect(BuildPlaces.isBroad(path, home: "/Users/me"), "\(path)") }
    for path in ["/Users/me/app", "/Users/other/app", "/Volumes/Disk/app", "/private/tmp/app", "/opt/app"] { #expect(!BuildPlaces.isBroad(path, home: "/Users/me"), "\(path)") }
    #expect(BuildPlaces.isBroad("/srv", home: "/srv/me"))
}

@Test func secretsAreClosedWhereverTheyAre() {
    let secrets = BuildPlaces.secrets(["ASC_KEY_P8_FILE": "/w/key.p8", "XLESS_TESTFLIGHT_ENV": "/w/env", "XDG_CONFIG_HOME": "/c", "XDG_RUNTIME_DIR": "/r"], home: "/Users/me")
    for path in ["/w/key.p8", "/w/env", "/c/xless", "/r/xless", "/r/xless-agent", "/Users/me/.local/share/xless", "/Users/me/.cache/xless/secrets", "/Users/me/.ssh", "/Users/me/Library/Keychains"] {
        #expect(secrets.contains(path), "\(path)")
    }
    #expect(BuildPlaces.secrets([:], home: "/Users/me").contains("/Users/me/.config/xless"))
}
