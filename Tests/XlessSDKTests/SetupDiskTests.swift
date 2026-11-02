import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

private let table = ["XLESS_SETUP_CACHE_GB": "17", "XLESS_SETUP_DOCKER_GB": "40"]

@Test func perArchitectureFiguresComeFromVersionsEnv() {
    let n = SetupDisk.needs(archs: 1, exporting: 1, env: [:], table: table)
    #expect(n.cache == SetupDisk.Need(key: "XLESS_SETUP_CACHE_GB", perArchGB: 17, archs: 1))
    #expect(n.docker == SetupDisk.Need(key: "XLESS_SETUP_DOCKER_GB", perArchGB: 40, archs: 1))
    #expect(n.cache.spoken == "17 GB")
}

@Test func bothArchitecturesDoubleTheNeed() {
    let n = SetupDisk.needs(archs: 2, exporting: 2, env: [:], table: table)
    #expect(n.cache.totalGB == 34)
    #expect(n.docker.totalGB == 80)
    #expect(n.docker.spoken == "80 GB (40 GB per architecture × 2)")
}

@Test func anExistingExportNeedsNoCacheSpace() {
    let n = SetupDisk.needs(archs: 2, exporting: 1, env: [:], table: table)
    #expect(n.cache.totalGB == 17)
    #expect(SetupDisk.needs(archs: 1, exporting: 0, env: [:], table: table).cache.totalGB == 0)
}

@Test func theEnvironmentWinsOverVersionsEnv() {
    let n = SetupDisk.needs(archs: 1, exporting: 1, env: ["XLESS_SETUP_CACHE_GB": "5", "XLESS_SETUP_DOCKER_GB": " 7 "], table: table)
    #expect(n.cache.perArchGB == 5)
    #expect(n.docker.perArchGB == 7)
    // Not a whole number: ignored, versions.env's value stands.
    #expect(SetupDisk.perArchGB("XLESS_SETUP_CACHE_GB", env: ["XLESS_SETUP_CACHE_GB": "lots"], table: table) == 17)
    // Neither: the built-in figure.
    #expect(SetupDisk.perArchGB("XLESS_SETUP_DOCKER_GB", env: [:], table: [:]) == SetupDisk.fallback["XLESS_SETUP_DOCKER_GB"])
}

@Test func theRepositorysTableHasBothFigures() throws {
    let text = try String(contentsOf: repoRoot.appendingPathComponent("versions.env"), encoding: .utf8)
    let env = KnownXcodes.parseEnv(text)
    #expect(env["XLESS_SETUP_CACHE_GB"].flatMap { Int($0) } == SetupDisk.fallback["XLESS_SETUP_CACHE_GB"])
    #expect(env["XLESS_SETUP_DOCKER_GB"].flatMap { Int($0) } == SetupDisk.fallback["XLESS_SETUP_DOCKER_GB"])
    #expect(env["XLESS_SETUP_NATIVE_GB"].flatMap { Int($0) } == SetupDisk.fallback["XLESS_SETUP_NATIVE_GB"])
    #expect(env["XLESS_SETUP_DISK_GB"] == nil)
}

@Test func aNativeSetupAsksForTheCacheOnlyWhenItExports() {
    let t = table.merging(["XLESS_SETUP_NATIVE_GB": "10"]) { $1 }
    let n = SetupDisk.nativeNeeds(exporting: true, env: [:], table: t)
    #expect(n.cache.totalGB == 17)
    #expect(n.native == SetupDisk.Need(key: "XLESS_SETUP_NATIVE_GB", perArchGB: 10, archs: 1))
    #expect(SetupDisk.nativeNeeds(exporting: false, env: ["XLESS_SETUP_NATIVE_GB": "3"], table: t).cache.totalGB == 0)
    #expect(SetupDisk.nativeNeeds(exporting: false, env: ["XLESS_SETUP_NATIVE_GB": "3"], table: t).native.totalGB == 3)
}

@Test func theRefusalNamesThePathAndBothFigures() {
    let need = SetupDisk.Need(key: "XLESS_SETUP_DOCKER_GB", perArchGB: 50, archs: 2)
    #expect(SetupDisk.shortfall(freeGB: 100, path: "/var/lib/docker", what: "Docker's data root", need: need) == nil)
    #expect(SetupDisk.shortfall(freeGB: 99, path: "/var/lib/docker", what: "Docker's data root", need: need)
            == "99 GB free under /var/lib/docker for Docker's data root; xless setup needs about 100 GB (50 GB per architecture × 2) there")
}

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
