import ArgumentParser
import Foundation
import XlessCargo

struct CargoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cargo", abstract: "Plain Cargo app helpers (type: cargo overlays).",
                                                    subcommands: [CargoInputsCommand.self])
}

/// `xless cargo inputs --config <overlay>`: the host directories of the overlay's path inputs, which `xless run`
/// mounts read-only at `/inputs/<name>` in the build container. Git inputs are cloned inside it and are not listed.
struct CargoInputsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inputs",
        abstract: "Print `name<TAB>absolute path` for each path input of a cargo overlay, one per line (read-only).",
        discussion: "Relative paths start at the source root (the overlay's `source:`, or --source). Git inputs print nothing.")
    @Option(name: .long, help: "Overlay file (type: cargo).") var config: String
    @Option(name: .long, help: "Use this directory as the app source instead of the overlay's `source:`.") var source: String?

    func run() throws {
        let url = URL(fileURLWithPath: config).standardizedFileURL
        for line in try CargoInputs.hostMountLines(overlayAt: url, sourceOverride: source) { print(line) }
    }
}
