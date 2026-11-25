import Testing
@testable import XlessCore

@Test(arguments: [(nil, true), ("", true), ("0", true), ("1", false), ("true", false)] as [(String?, Bool)])
func inputIsAskedForUnlessTheVariableSaysNot(value: String?, isOn: Bool) {
    #expect(InputGate.allows(env: value.map { ["XLESS_NO_INPUT": $0] } ?? [:]) == isOn)
}

@Test func theOptionIsTakenOutOfTheArgumentsWhereverItIs() {
    #expect(InputGate.taking(["xless", "--no-input", "keys", "list"]).arguments == ["xless", "keys", "list"])
    #expect(InputGate.taking(["xless", "keys", "list", "--no-input"]).isOff)
    #expect(!InputGate.taking(["xless", "keys", "list"]).isOff)
    let passed = InputGate.taking(["xless", "run", "app", "--", "--no-input"])
    #expect(passed.arguments == ["xless", "run", "app", "--", "--no-input"] && !passed.isOff)
    #expect(InputGate.taking(["--no-input"]).arguments == ["--no-input"]) // the program's own name is never an option
}

@Test func anInputThatIsOffIsAnErrorOfItsOwnExitCode() throws {
    try InputGate.$forced.withValue(false) { try InputGate.require("the passphrase", fix: "-") }
    let error = #expect(throws: XlessError.self) {
        try InputGate.$forced.withValue(true) { try InputGate.require("the secret store's passphrase (exporting NOTE)", fix: "run `xless unlock`") }
    }
    #expect(error?.stage == .input)
    #expect(error?.stage.exitCode == 23)
    #expect(error?.description == "[input] --no-input (XLESS_NO_INPUT): xless would ask for the secret store's passphrase (exporting NOTE) — run `xless unlock`")
    #expect(InputGate.refused?.stage == .input) // remembered: the command ends with it
    #expect(Stage.allCases.filter { $0 != .input }.allSatisfy { $0.exitCode != 23 })
}

@Test func inputIsNotAStageOfThePipeline() {
    #expect(!StagePolicy.pipeline.contains(.input))
    #expect(StagePolicy.shipRangeProblem(from: .input, last: .upload, simulator: false) != nil)
}
