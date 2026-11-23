import Foundation
import Testing
@testable import XlessCore
@testable import XlessVault

private func parse(_ text: String) throws -> [(key: String, value: String)] {
    let bytes = Array(text.utf8)
    return try bytes.withUnsafeBytes { try HelperJSON.members($0) }.map { ($0.key, $0.value.utf8String()) }
}

private let tricky = "-----BEGIN PRIVATE KEY-----\nab\"c\\d/e\tf\r\u{1}\u{7f} é 😀\n-----END PRIVATE KEY-----\n\n"

@Test func anObjectRoundTripsEveryByteOfItsValues() throws {
    let built = HelperJSON.object([("ServerURL", SecretBytes(utf8: "xless:A@B")), ("Secret", SecretBytes(utf8: tricky))])
    let text = built.utf8String()
    #expect(!text.contains("\n") && !text.contains("\t"))
    #expect(text.hasPrefix("{\"ServerURL\":\"xless:A@B\",\"Secret\":\"-----BEGIN"))
    #expect(text.contains("\\u0001") && text.contains("\\u007f") && text.contains("é 😀"))
    let back = try parse(text)
    #expect(back.map(\.key) == ["ServerURL", "Secret"])
    #expect(back[1].value == tricky)
    // Foundation reads the same text the same way.
    let foundation = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
    #expect(foundation?["Secret"] == tricky)
}

@Test func anyJSONEscapeIsRead() throws {
    let members = try parse(" {\n \"a\" : \"\\u00e9\\ud83d\\ude00\\/\\b\\f\" , \"b\":\"\"}\n")
    #expect(members.map(\.key) == ["a", "b"])
    #expect(members[0].value == "é😀/\u{8}\u{c}")
    #expect(members[1].value == "")
    #expect(try parse("{}").isEmpty)
    // What Foundation's encoder writes reads back.
    let data = try JSONSerialization.data(withJSONObject: ["Secret": tricky, "Username": "{\"kind\":\"generic\"}"])
    let read = try parse(String(decoding: data, as: UTF8.self))
    #expect(Dictionary(uniqueKeysWithValues: read.map { ($0.key, $0.value) })["Secret"] == tricky)
}

@Test func anythingButAFlatObjectOfStringsIsMalformed() {
    for junk in ["", "hello", "[]", "{", "{\"a\"}", "{\"a\":1}", "{\"a\":\"b\"} x", "{\"a\":{\"b\":\"c\"}}", "{\"a\":\"b\",}",
                 "{\"a\":\"\\x\"}", "{\"a\":\"\\ud83d\"}", "{\"a\":\"\\ude00\"}", "{\"a\":\"\\u12\"}", "{\"a\":\"raw\nnewline\"}",
                 "{\"a\":\"unterminated}", "{\"a\":null}", "credentials not found in native keychain"] {
        #expect(throws: HelperJSON.Malformed.self, "\(junk)") { try parse(junk) }
    }
}
