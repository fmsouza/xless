import ArgumentParser
import Testing
import XlessCore
@testable import xless

/// `sign` and `ship` (so `xless run … --no-provisioning-updates`): the flag only restricts.
@Test func signAndShipTakeNoProvisioningUpdates() throws {
    #expect(try SignRunCommand.parse(["--platform", "ios"]).updatesOff.flag == false)
    #expect(try SignRunCommand.parse(["--platform", "ios", "--no-provisioning-updates"]).updatesOff.flag)
    #expect(try ShipCommand.parse(["--platform", "ios", "--no-provisioning-updates"]).updatesOff.flag)
    #expect(try Xless.parseAsRoot(["sign", "--platform", "ios", "--no-provisioning-updates"]) is SignRunCommand)
    #expect(throws: (any Error).self) { _ = try SignRunCommand.parse(["--platform", "ios", "--provisioning-updates"]) }
}

@Test func eitherTheFlagOrTheConfigTurnsProvisioningUpdatesOff() throws {
    func reason(flag: Bool, config: Bool) -> String? { ProvisioningUpdatesOption.reason(flag: flag, config: config) }
    #expect(reason(flag: false, config: true) == nil)
    #expect(reason(flag: true, config: true) == "--no-provisioning-updates")
    #expect(reason(flag: false, config: false) == "provisioningUpdates: false")
    #expect(reason(flag: true, config: false) == "--no-provisioning-updates")
}
