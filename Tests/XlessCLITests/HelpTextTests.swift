import ArgumentParser
import Testing
@testable import xless

/// `xless --help` says what xless is, on every system, and what it says of a command is the whole of it.
@Test func helpSaysWhatXlessIs() {
    #expect(Xless.configuration.abstract == "Set up, manage, build and ship Apple apps from the terminal.")
    let help = Xless.helpMessage(columns: 10_000)
    #expect(help.hasPrefix("OVERVIEW: Set up, manage, build and ship Apple apps from the terminal."), "\(help)")
    for only in ["from Linux", "on Linux", "without a Mac", "no Mac"] { #expect(!help.contains(only), "\(only): \(help)") }
}

#if !os(Windows) && !XLESS_WINDOWS_TARGETS
@Test func helpNamesEveryKindOfAppAndPackage() {
    #expect(PrepareCommand.configuration.abstract.hasPrefix("Overlays (Tauri, Cargo, React Native): "))
    #expect(PackageCommand.configuration.abstract == "Create the .ipa (iOS), or for macOS the notarized .zip (.dmg for Tauri and Cargo) or the App Store .pkg, in .xless/build/<platform>/out.")
    #expect(UploadCommand.configuration.abstract == "Upload the .ipa, or a macOS App Store .pkg, to App Store Connect and wait for TestFlight processing.")
}
#endif
