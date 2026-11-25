import Foundation
import Testing
import XlessCore
@testable import XlessAgent

@Test func aFrameRoundTrips() throws {
    var w = WireWriter()
    w.put(UInt8(7)); w.put(UInt32(70000)); w.put(Int64(-5)); w.put("naïve"); w.put(bytes: [1, 2, 3])
    let frame = w.frame(code: .get)
    let parsed = try frame.withUnsafeBytes { try AgentFrame.header($0) }
    let header = try #require(parsed)
    #expect(header.code == AgentCode.get.rawValue)
    #expect(header.version == AgentProtocol.version)
    #expect(header.length == frame.count - AgentFrame.headerSize)
    try frame.withUnsafeBytes { raw in
        var r = WireReader(UnsafeRawBufferPointer(rebasing: raw[AgentFrame.headerSize...]))
        let small = try r.uint8(), medium = try r.uint32(), large = try r.int64()
        let text = try r.string(max: 10), bytes = try r.bytes(max: 3)
        #expect(small == 7 && medium == 70000 && large == -5)
        #expect(text == "naïve")
        #expect(bytes == [1, 2, 3])
        try r.end()
    }
}

@Test func aHeaderIsReadOnlyOnceItIsWhole() throws {
    let frame = WireWriter().frame(code: .status)
    for n in 0..<AgentFrame.headerSize {
        let header = try frame.withUnsafeBytes { try AgentFrame.header(UnsafeRawBufferPointer(rebasing: $0[..<n])) }
        #expect(header == nil)
    }
}

@Test func junkIsNotAFrame() {
    #expect(throws: AgentError.self) { try Array("GET / HTTP/1.1\r\n".utf8).withUnsafeBytes { try AgentFrame.header($0) } }
    #expect(throws: AgentError.self) { try [UInt8](repeating: 0, count: 12).withUnsafeBytes { try AgentFrame.header($0) } }
}

@Test func aFieldThatLiesAboutItsLengthIsRefused() throws {
    func reading(_ bytes: [UInt8], _ body: (inout WireReader) throws -> Void) throws {
        try bytes.withUnsafeBytes { var r = WireReader($0); try body(&r) }
    }
    #expect(throws: AgentError.self) { try reading([0, 0, 0, 9, 1]) { _ = try $0.bytes(max: 100) } }        // longer than the body
    #expect(throws: AgentError.self) { try reading([255, 255, 255, 255, 1]) { _ = try $0.bytes(max: 100) } }
    #expect(throws: AgentError.self) { try reading([0, 0, 0, 2, 1, 2]) { _ = try $0.bytes(max: 1) } }       // longer than allowed
    #expect(throws: AgentError.self) { try reading([0, 0, 0]) { _ = try $0.uint32() } }
    #expect(throws: AgentError.self) { try reading([0, 0, 0, 1, 0xFF]) { _ = try $0.string(max: 4) } }      // not UTF-8
    #expect(throws: AgentError.self) { try reading([1]) { try $0.end() } }                                  // bytes left over
}

@Test func secretBytesOnTheWireGoToZeroedMemoryOnly() throws {
    let frame = {
        var w = WireWriter()
        w.put(secret: SecretBytes(utf8: "hunter2"))
        return w.frame(code: .put)
    }()
    try frame.withUnsafeBytes { raw in
        var r = WireReader(UnsafeRawBufferPointer(rebasing: raw[AgentFrame.headerSize...]))
        let read = try r.secret(max: 100)
        #expect(read.utf8String() == "hunter2")
    }
    #expect("\(frame)".contains("hunter2") == false)
    #expect(String(reflecting: frame).contains("hunter2") == false)
}

@Test func anAgentErrorNamesNoSecretAndHasAFix() {
    let e = AgentError.versionMismatch(theirs: "9.9.9")
    #expect(e.description.contains("9.9.9"))
    #expect(e.description.contains("xless lock"))
}
