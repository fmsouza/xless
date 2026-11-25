import Foundation

/// One process of a run. Its words go to the system as they are, never through a shell.
public struct RunStep: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        case shown
        /// Returned, and not shown.
        case captured
        /// Shown, and returned.
        case both
        /// Written to this file (0600), and not shown.
        case file(String)
    }

    public var words: [String]
    public var environment: [String: String]
    public var directory: String?
    public var output = Output.shown
    /// Its standard error goes nowhere: a question whose answer is its exit code.
    public var quiet = false

    public init(_ words: [String], environment: [String: String], directory: String? = nil, output: Output = .shown, quiet: Bool = false) {
        self.words = words
        self.environment = environment
        self.directory = directory
        self.output = output
        self.quiet = quiet
    }
}

/// A step that runs.
public struct StartedStep: Sendable {
    public let pid: Int32
    /// Where its output comes from, when it is returned.
    public let reading: Int32?
    let shows: Bool
}

/// What a run needs of the system it is on. Everything else in this library is the same everywhere: a host for another
/// system is another implementation of this.
public protocol RunHost: AnyObject, Sendable {
    var processID: Int32 { get }
    var hostName: String { get }
    /// As the images' names have it: arm64 or amd64.
    var architecture: String { get }
    var isMac: Bool { get }
    var now: Date { get }
    /// The directory a relative path starts at, as the user sees it (`$PWD`).
    var currentDirectory: String { get }

    /// A line on standard output, and one on standard error.
    func show(_ line: String)
    func say(_ line: String)

    /// The file that running `name` starts; nil: there is none.
    func program(_ name: String, path: String?) -> String?
    func start(_ step: RunStep) throws -> StartedStep
    /// Waits for it; its exit code (128 + the signal that ended it) and what it printed, when that is returned.
    func finish(_ step: StartedStep) -> (code: Int32, output: String)
    /// Becomes `words`; comes back only when it cannot be started, with why.
    func become(_ words: [String], environment: [String: String]) -> String

    /// From here on a request to stop the run (a signal that would end it) is given to `stop`, on a thread of its own, with the
    /// exit code it asks for.
    func onStop(_ stop: @escaping @Sendable (Int32) -> Void) throws
    /// Whether the run has been asked to stop.
    var stopping: Bool { get }
    /// Ends this process now.
    func end(_ code: Int32) -> Never
    /// A fault of this process's own that leaves no chance to clean up removes `path` too (a directory: once it is empty).
    func removeOnFault(_ path: String, isDirectory: Bool)

    /// The process runs (and is not a dead one nobody waited for).
    func isRunning(_ pid: Int32) -> Bool
    /// When it started, the same text whoever asks; empty: unknown.
    func started(_ pid: Int32) -> String
    func commandLine(_ pid: Int32) -> String
    /// The processes of this machine, by the process that started them.
    func children() -> [Int32: [Int32]]
    func terminate(_ pid: Int32)
    func pause(_ seconds: Double)

    /// The path with every symbolic link resolved; nil: there is no such file.
    func realPath(_ path: String) -> String?
    /// The same file or directory, whatever the spellings.
    func isSame(_ a: String, _ b: String) -> Bool
    func isReadable(_ path: String) -> Bool
    /// A regular file, or a link to one.
    func isFile(_ path: String) -> Bool
    /// A new empty file that only this user can read.
    func temporaryFile() throws -> String
    /// Makes `path` another name of `file`; false: there is a `path` already (or it cannot).
    func link(_ file: String, _ path: String) -> Bool
    /// `path` is `file` from now on, in one step.
    func rename(_ file: String, _ path: String) -> Bool
    /// Makes a directory that is not there; false: it is (or it cannot).
    func makeDirectory(_ path: String) -> Bool
    func removeFile(_ path: String)
    func removeEmptyDirectory(_ path: String)
    /// Removes a directory and what is in it, without following a link.
    func removeTree(_ path: String)
}
