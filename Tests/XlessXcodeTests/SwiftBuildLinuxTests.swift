import Foundation
import Testing
import XlessCore
@testable import XlessXcode

// MARK: swbuild's output stream

private func frame(_ json: String) -> Data { Data("\(json.utf8.count)\n\(json)\n".utf8) }

@Test func swbuildMessagesAreLengthFramedJSON() {
    var data = frame(#"{"kind":"taskStarted","id":1,"ruleInfo":"CompileC a.o a.c"}"#)
    data += frame(#"{"kind":"taskOutput","taskID":1,"data":"x\n{not a frame}\nScript-1.sh: line 4: ditto: command not found\n"}"#)
    data += frame(#"{"kind":"taskComplete","id":1,"result":"failed"}"#)
    data += frame(#"{"kind":"error","message":"'x.h' file not found"}"#)
    data += frame(#"{"kind":"error","message":"'x.h' file not found"}"#)
    data += frame(#"{"kind":"warning","message":"unused"}"#)
    data += frame(#"{"kind":"buildCompleted","result":"failed"}"#)
    #expect(SwiftBuildOutput.messages(data).count == 7)
    let s = SwiftBuildOutput.summarize(data)
    #expect(s == .init(succeeded: false, errors: ["'x.h' file not found"], warnings: ["unused"], failedTasks: ["CompileC a.o a.c"], tasks: 1,
                       commandsNotFound: ["Script-1.sh: line 4: ditto: command not found"],
                       failedTaskOutput: [["x", "{not a frame}", "Script-1.sh: line 4: ditto: command not found"]]))
    #expect(s.failedTaskOutput == [["x", "{not a frame}", "Script-1.sh: line 4: ditto: command not found"]])
    #expect(SwiftBuildOutput.summarize(frame(#"{"kind":"buildCompleted","result":"ok"}"#)).succeeded)
    // A truncated frame ends the parse instead of misreading the rest.
    #expect(SwiftBuildOutput.messages(Data("40\n{\"kind\":\"error\"}".utf8)).isEmpty)
}

@Test func shimRefusalsAreFoundInAnyTasksOutputAndFailedTasksKeepTheirTail() {
    // Task 1 succeeds although its script's `[ "`xcrun --find actool`" ]` was refused (CocoaPods' Copy Pods Resources);
    // task 2 fails with copypng's reason on stderr, split across two messages, after 25 lines of output.
    var data = frame(#"{"kind":"taskStarted","id":1,"ruleInfo":"PhaseScriptExecution [CP] Copy Pods Resources"}"#)
    data += frame(#"{"kind":"taskStarted","id":2,"ruleInfo":"CopyPNGFile b.png a.png"}"#)
    data += frame(#"{"kind":"taskOutput","taskID":1,"data":"xcrun shim: unsupported call: xcrun --find actool\nrsync ok\n"}"#)
    data += frame(#"{"kind":"taskOutput","taskID":2,"data":"\#((1...25).map { "line \($0)\\n" }.joined())copypng shim: unsupported call (ancill"}"#)
    data += frame(#"{"kind":"taskOutput","taskID":2,"data":"ary chunk iCCP): copypng a.png b.png\n"}"#)
    data += frame(#"{"kind":"taskComplete","id":1,"result":"success"}"#)
    data += frame(#"{"kind":"taskComplete","id":2,"result":"failed"}"#)
    data += frame(#"{"kind":"buildCompleted","result":"failed"}"#)
    let s = SwiftBuildOutput.summarize(data)
    let copypng = "copypng shim: unsupported call (ancillary chunk iCCP): copypng a.png b.png"
    #expect(s.shimRefusals == ["xcrun shim: unsupported call: xcrun --find actool", copypng])
    #expect(s.failedTasks == ["CopyPNGFile b.png a.png"])
    #expect(s.failedTaskOutput == [(7...25).map { "line \($0)" } + [copypng]])
    #expect(s.firstShimRefusal == copypng)   // the failed task's, not the earlier one
    for line in ["actool shim: unsupported call (unknown option --foo): actool --foo", "xless-ld64 shim: unsupported call (x): ld",
                 "PlistBuddy shim: unsupported call (option -x): PlistBuddy -x"] {
        #expect(SwiftBuildOutput.isShimRefusal(line[...]), "\(line)")
    }
    for line in ["unsupported call", "error: shim: unsupported", "the shim: unsupported calls are listed"] {
        #expect(!SwiftBuildOutput.isShimRefusal(line[...]), "\(line)")
    }
}

// MARK: The Linux environment

private let env = SwiftBuildEnvironment(sdk: DarwinSDK(bundle: URL(fileURLWithPath: "/sdk/darwin.artifactbundle")),
                                        shimDirectory: URL(fileURLWithPath: "/opt/xless/shims"),
                                        toolchainInclude: URL(fileURLWithPath: "/opt/xless/toolchain/usr/include"))

@Test func linuxEnvironmentOverridesAndToolset() throws {
    let o = env.overrides(toolset: URL(fileURLWithPath: "/dd/xless/toolset.json"))
    #expect(o["SWIFT_SDK_TOOLSETS"] == "/dd/xless/toolset.json")
    for (k, v) in ["CODE_SIGNING_ALLOWED": "NO", "LM_SKIP_METADATA_EXTRACTION": "YES", "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",
                   "STRIP_BITCODE_FROM_COPIED_FILES": "NO", "SWIFT_STDLIB_TOOL_STRIP_BITCODE": "NO", "CLANG_WARN_DOCUMENTATION_COMMENTS": "NO"] {
        #expect(o[k] == v, "\(k)")
    }
    #expect(o["SWIFT_LIBRARY_PATH"] == "/sdk/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$(PLATFORM_NAME)")
    #expect(o["OTHER_CFLAGS"] == "$(inherited) -idirafter /opt/xless/toolchain/usr/include")
    #expect(o["OTHER_CPLUSPLUSFLAGS"] == "$(inherited) -idirafter /opt/xless/toolchain/usr/include")
    #expect(o["OTHER_SWIFT_FLAGS"] == "$(inherited) -Xcc -idirafter -Xcc /opt/xless/toolchain/usr/include -enable-experimental-feature AssumeResilientCxxTypes")
    let toolset = try #require(try JSONSerialization.jsonObject(with: env.toolset()) as? [String: Any])
    #expect(toolset["rootPath"] as? String == "/sdk/darwin.artifactbundle/toolset/bin")
    #expect((toolset["linker"] as? [String: String])?["path"] == "/opt/xless/shims/xless-ld64")
    #expect((toolset["librarian"] as? [String: String])?["path"] == "llvm-lib")
    let p = env.processEnvironment(path: "/usr/bin:/bin")
    #expect(p["SDKROOT"] == .some(nil))
    #expect(p["XCODE_EXTRA_PLATFORM_FOLDERS"] == "/sdk/darwin.artifactbundle/Developer/Platforms")
    #expect(p["PATH"] == "/sdk/darwin.artifactbundle/toolset/bin:/usr/bin:/bin")
    #expect(p["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] == "/opt/xless/shims/swift-build")
    #expect(p["TAR_OPTIONS"] == "--warning=no-unknown-keyword --exclude=._*")
}

@Test func theAppSwiftToolchainCompiles() throws {
    // Ruling R10: the toolset names its compilers, and it comes before the image's own Swift on PATH.
    let swift = SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3")
    let e = SwiftBuildEnvironment(sdk: env.sdk, shimDirectory: env.shimDirectory, toolchainInclude: env.toolchainInclude, swift: swift)
    let toolset = try #require(try JSONSerialization.jsonObject(with: e.toolset()) as? [String: Any])
    #expect((toolset["swiftCompiler"] as? [String: String])?["path"] == "/opt/xless/toolchains/swift-6.2.3/usr/bin/swiftc")
    #expect((toolset["cCompiler"] as? [String: String])?["path"] == "/opt/xless/toolchains/swift-6.2.3/usr/bin/clang")
    #expect((toolset["cxxCompiler"] as? [String: String])?["path"] == "/opt/xless/toolchains/swift-6.2.3/usr/bin/clang++")
    #expect((toolset["linker"] as? [String: String])?["path"] == "/opt/xless/shims/xless-ld64")
    #expect(e.processEnvironment(path: "/opt/xless/shims:/usr/bin:/bin")["PATH"]
        == "/sdk/darwin.artifactbundle/toolset/bin:/opt/xless/shims:/opt/xless/toolchains/swift-6.2.3/usr/bin:/usr/bin:/bin")
    // Defaults Apple's clang has and the toolchain's lacks become build settings (the dependency scanner, Swift's importer).
    let flagged = SwiftBuildEnvironment(sdk: env.sdk, shimDirectory: env.shimDirectory, toolchainInclude: env.toolchainInclude,
                                        swift: SwiftToolchain(version: "6.2.3", root: "/t", clangFlags: ["-fdefine-target-os-macros"]))
    let o = flagged.overrides(toolset: URL(fileURLWithPath: "/dd/toolset.json"))
    #expect(o["OTHER_CFLAGS"] == "$(inherited) -idirafter /opt/xless/toolchain/usr/include -fdefine-target-os-macros")
    #expect(o["OTHER_CPLUSPLUSFLAGS"] == "$(inherited) -idirafter /opt/xless/toolchain/usr/include -fdefine-target-os-macros")
    #expect(o["OTHER_SWIFT_FLAGS"] == "$(inherited) -Xcc -idirafter -Xcc /opt/xless/toolchain/usr/include -Xcc -fdefine-target-os-macros -enable-experimental-feature AssumeResilientCxxTypes")
    // A derived TARGET_OS_ definition (docker/toolchain/target-os/derived.txt) passes as one word.
    let derived = "-DTARGET_OS_ARROW=(TARGET_OS_OSX?(__is_target_arch(arm64)?1:__is_target_arch(arm64e)):0)"
    let two = SwiftBuildEnvironment(sdk: env.sdk, shimDirectory: env.shimDirectory, toolchainInclude: env.toolchainInclude,
                                    swift: SwiftToolchain(version: "6.2.3", root: "/t", clangFlags: ["-fdefine-target-os-macros", derived]))
        .overrides(toolset: URL(fileURLWithPath: "/dd/toolset.json"))
    #expect(two["OTHER_CFLAGS"] == "$(inherited) -idirafter /opt/xless/toolchain/usr/include -fdefine-target-os-macros \(derived)")
    #expect(two["OTHER_SWIFT_FLAGS"]?.contains("-Xcc -fdefine-target-os-macros -Xcc \(derived) ") == true)
    // Without one, and with the image's own Swift (the default chain's record, root "/"), the toolset leaves the
    // compilers to the toolchain on PATH.
    let plain = try #require(try JSONSerialization.jsonObject(with: env.toolset()) as? [String: Any])
    #expect(plain["swiftCompiler"] == nil && plain["cCompiler"] == nil)
    let engine = SwiftBuildEnvironment(sdk: env.sdk, shimDirectory: env.shimDirectory, toolchainInclude: env.toolchainInclude,
                                       swift: SwiftToolchain(version: "6.4", root: "/"))
    let own = try #require(try JSONSerialization.jsonObject(with: engine.toolset()) as? [String: Any])
    #expect(own["swiftCompiler"] == nil && own["cCompiler"] == nil && own["cxxCompiler"] == nil)
    #expect((own["linker"] as? [String: String])?["path"] == "/opt/xless/shims/xless-ld64")
}

@Test func linuxEnvironmentNeedsTheReactNativeImage() {
    #expect(throws: XlessError.self) { try SwiftBuildEnvironment.fromProcess(["HOME": "/root"], stage: .build) }
    let e = try? SwiftBuildEnvironment.fromProcess(["XLESS_SHIM_DIR": "/s", "XLESS_TOOLCHAIN_INCLUDE": "/i", "XDG_CONFIG_HOME": "/c"], stage: .build)
    #expect(e?.sdk.bundle.path == "/c/swiftpm/swift-sdks/darwin.artifactbundle")
}

// MARK: xcodebuild

/// The exact call Expo's `expo-modules-jsi/apple/scripts/build-xcframework.sh` makes (SDK 57) for the device slice.
let expoJSIBuild = ["build", "-scheme", "ExpoModulesJSI", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
                            "-derivedDataPath", "/p/.DerivedData", "-configuration", "Release", "-quiet",
                            "-disableAutomaticPackageResolution", "-skipPackagePluginValidation", "-skipMacroValidation", "-parallelizeTargets",
                            "SYMROOT=/p/.DerivedData/Build/Products", "OBJROOT=/p/.DerivedData/Build/Intermediates.noindex",
                            "BUILD_LIBRARY_FOR_DISTRIBUTION=YES", "SKIP_INSTALL=NO", "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym",
                            "COMPILER_INDEX_STORE_ENABLE=NO", "SWIFT_COMPILATION_MODE=wholemodule", "CLANG_ENABLE_CODE_COVERAGE=NO",
                            "CLANG_COVERAGE_MAPPING=NO"]

@Test func xcodebuildParsesExpoPackageBuild() throws {
    guard case .buildPackage(let b) = try XcodebuildShim.parse(expoJSIBuild) else { Issue.record("not a package build"); return }
    #expect(b.scheme == "ExpoModulesJSI" && b.configuration == "Release" && b.derivedDataPath == "/p/.DerivedData" && b.quiet)
    #expect(b.settings.count == 9 && b.settings[0] == .init(name: "SYMROOT", value: "/p/.DerivedData/Build/Products"))
    // -disableAutomaticPackageResolution is SwiftPM's --disable-automatic-resolution.
    #expect(b.disableAutomaticResolution)
    #expect(XcodebuildShim.dumpPIFArguments(for: b) == ["package", "--build-system", "swiftbuild", "--experimental-build-dylibs-as-frameworks",
                                                       "--disable-local-rpath", "--disable-automatic-resolution", "dump-pif"])
    #expect(try XcodebuildShim.parse(["-version"]) == .version)
}

@Test(arguments: [
    ["-version", "-json"], ["-create-xcframework", "-framework", "a.framework", "-output", "a.xcframework"],
    ["build", "-scheme", "S", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", "d"],
    ["build", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS"],          // no derived data
    ["build", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "d"],
    ["build", "-workspace", "A.xcworkspace", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d"],
    ["archive", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d"],
    ["build", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d", "lower=1"],
    ["-showBuildSettings"],
    ["build", "-scheme", "S", "-scheme", "T", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d"],
    ["build", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d", "-derivedDataPath", "/e"],
    ["build", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d", "A=1", "A=2"],
    ["build", "-scheme", "S", "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "/d", "ÄB=1"],
])
func xcodebuildRefusesOtherCalls(_ args: [String]) {
    #expect(throws: XcodebuildShim.Unsupported.self) { try XcodebuildShim.parse(args) }
}

@Test func xcodebuildVersionComesFromTheSDKMetadata() {
    func meta(_ v: String) -> ToolchainMeta { ToolchainMeta(xcodeVersion: v, xcodeBuild: "27A266a", buildMachineOSBuild: "x", compiler: "c", platforms: [:]) }
    #expect(XcodebuildShim.versionText(meta("2700")) == "Xcode 27.0\nBuild version 27A266a\n")
    #expect(XcodebuildShim.versionText(meta("2710")) == "Xcode 27.1\nBuild version 27A266a\n")
    #expect(XcodebuildShim.versionText(meta("2701")) == "Xcode 27.0.1\nBuild version 27A266a\n")
    // Non-ASCII digits are not parsed (no crash): the value is printed as it is.
    #expect(XcodebuildShim.versionText(meta("２７００")) == "Xcode ２７００\nBuild version 27A266a\n")
    #expect(XcodebuildShim.versionText(meta("27٠٠")) == "Xcode 27٠٠\nBuild version 27A266a\n")
}

@Test func xcodebuildBuildsThePackageProductAsXcodeWould() throws {
    #expect(XcodebuildShim.dumpPIFArguments == ["package", "--build-system", "swiftbuild", "--experimental-build-dylibs-as-frameworks",
                                               "--disable-local-rpath", "dump-pif"])
    let pif = #"""
    [{"type":"workspace","contents":{"guid":"W"}},
     {"type":"target","contents":{"guid":"PACKAGE-PRODUCT:apple_Kit.Kit","name":"Kit-product"}},
     {"type":"target","contents":{"guid":"PACKAGE-TARGET:Kit","name":"Kit"}},
     {"type":"target","contents":{"guid":"PACKAGE-PRODUCT:apple_Kit2.Kit2","name":"Kit2-product"}}]
    """#
    guard case .buildPackage(let b) = try XcodebuildShim.parse(["build", "-scheme", "Kit", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
                                                                "-derivedDataPath", "/d", "-configuration", "Release", "SKIP_INSTALL=NO",
                                                                "CODE_SIGNING_ALLOWED=YES"]) else { return }
    // A command-line setting may not replace one the Linux build needs.
    #expect(throws: XcodebuildShim.Unsupported.self) {
        try XcodebuildShim.packageRequest(packagePIF: Data(pif.utf8), build: b, overrides: ["CODE_SIGNING_ALLOWED": "NO", "X": "1"])
    }
    var allowed = b
    allowed.settings.removeAll { $0.name == "CODE_SIGNING_ALLOWED" }
    allowed.settings.append(.init(name: "Y", value: "2"))
    let data = try XcodebuildShim.packageRequest(packagePIF: Data(pif.utf8), build: allowed, overrides: ["CODE_SIGNING_ALLOWED": "NO", "X": "1"])
    let r = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((r["configuredTargets"] as? [[String: String]])?.first?["guid"] == "PACKAGE-PRODUCT:apple_Kit.Kit")
    let params = try #require(r["parameters"] as? [String: Any])
    #expect(params["configurationName"] as? String == "Release" && params["action"] as? String == "build")
    let table = ((params["overrides"] as? [String: Any])?["commandLine"] as? [String: Any])?["table"] as? [String: String]
    // Command-line settings are added; -sdk iphoneos is SDKROOT.
    #expect(table == ["CODE_SIGNING_ALLOWED": "NO", "X": "1", "SKIP_INSTALL": "NO", "Y": "2", "SDKROOT": "iphoneos"])
    let missing = XcodebuildShim.PackageBuild(scheme: "Nope", configuration: "Release", derivedDataPath: "/d", settings: [], quiet: true)
    #expect(throws: XlessError.self) { try XcodebuildShim.packageRequest(packagePIF: Data(pif.utf8), build: missing, overrides: [:]) }
}

// MARK: Swift packages of a workspace

@Test func packageListPrintsRevisionPins() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("ExtPkg/ExtPkg.xcworkspace"))
    #expect(try XcodePackageList.lines(ws) == ["greetingkit\thttps://example.com/swift/GreetingKit.git\t83cca1bb83e4f45fe6dc0d8d6c52c5f656c51051"])
    #expect(try XcodePackageList.lines(try XcodeWorkspace.load(fixturesDir.appendingPathComponent("HelloRN/HelloRN.xcodeproj"))).isEmpty)
}

@Test func packageListRefusesVersionRequirements() throws {
    let src = fixturesDir.appendingPathComponent("ExtPkg")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pkglist-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.copyItem(at: src, to: tmp)
    let pbx = tmp.appendingPathComponent("ExtPkg.xcodeproj/project.pbxproj")
    let text = try String(contentsOf: pbx, encoding: .utf8)
        .replacingOccurrences(of: "kind = revision;\n\t\t\t\trevision = 83cca1bb83e4f45fe6dc0d8d6c52c5f656c51051;",
                              with: "kind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = 1.0.0;")
    try text.write(to: pbx, atomically: true, encoding: .utf8)
    let ws = try XcodeWorkspace.load(tmp.appendingPathComponent("ExtPkg.xcworkspace"))
    #expect(throws: XlessError.self) { try XcodePackageList.lines(ws) }
}

// MARK: The runner

@Test func prepareOverridesWritesTheToolsetAndExtraWins() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swbrun-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let o = try SwiftBuildRunner.prepareOverrides(env, directory: dir, extra: ["CODE_SIGNING_ALLOWED": "YES", "HERMES_CLI_PATH": "/h"], stage: .build)
    #expect(o["CODE_SIGNING_ALLOWED"] == "YES" && o["HERMES_CLI_PATH"] == "/h")
    #expect(o["SWIFT_SDK_TOOLSETS"] == dir.appendingPathComponent("toolset.json").path)
    #expect(FileManager.default.contents(atPath: dir.appendingPathComponent("toolset.json").path) == env.toolset())
}

/// A stand-in `swbuild` on the base environment's PATH records its argv and environment and answers two messages.
@Test func runnerRunsSwbuildInTheLinuxEnvironment() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swbrun-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fake = dir.appendingPathComponent("bin/swbuild")
    try ExecutableFile.write(#"""
    #!/bin/sh
    echo "$@" > "$(dirname "$0")/../argv"
    env > "$(dirname "$0")/../env"
    m='{"kind":"error","message":"boom"}'; printf '%s\n%s\n' "${#m}" "$m"
    m='{"kind":"buildCompleted","result":"failed"}'; printf '%s\n%s\n' "${#m}" "$m"
    exit 1
    """#, to: fake, stage: .build)
    let base = ["PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin", "SDKROOT": "/x", "KEEP": "1", "ASC_KEY_P8": "secret"]
    let s = try SwiftBuildRunner.build(pif: URL(fileURLWithPath: "/w.pif"), request: URL(fileURLWithPath: "/r.json"),
                                       derivedData: URL(fileURLWithPath: "/dd"), environment: env, log: dir.appendingPathComponent("log"),
                                       extraEnvironment: ["EXTRA": "2", "KEEP": nil], stage: .build, baseEnvironment: base)
    #expect(!s.succeeded && s.errors == ["boom"])
    let argv = try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8)
    #expect(argv == "build /w.pif --derivedDataPath /dd --buildRequestFile /r.json\n")
    let vars = Set(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8).split(separator: "\n").map(String.init))
    #expect(vars.contains("EXTRA=2") && !vars.contains("KEEP=1") && !vars.contains { $0.hasPrefix("SDKROOT=") || $0.hasPrefix("ASC_KEY_P8=") })
    #expect(vars.contains("PATH=/sdk/darwin.artifactbundle/toolset/bin:" + dir.appendingPathComponent("bin").path + ":/usr/bin:/bin"))
    #expect(vars.contains("__XCODE_BUILT_PRODUCTS_DIR_PATHS=/opt/xless/shims/swift-build"))
}

@Test func xcodebuildRefusesDirectoriesThatAreNotPlainPackages() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let build = XcodebuildShim.PackageBuild(scheme: "Kit", configuration: "Release", derivedDataPath: dir.appendingPathComponent("dd").path,
                                            settings: [], quiet: true)
    #expect(throws: XlessError.self) { try XcodebuildShim.buildPackage(build, in: dir, environment: env) }   // no Package.swift
    try Data("// swift-tools-version: 6.0\n".utf8).write(to: dir.appendingPathComponent("Package.swift"))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Kit.xcodeproj"), withIntermediateDirectories: true)
    #expect(throws: XlessError.self) { try XcodebuildShim.buildPackage(build, in: dir, environment: env) }   // an Xcode project
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("dd").path))
}
