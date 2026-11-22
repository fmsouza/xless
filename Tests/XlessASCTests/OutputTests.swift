import Testing
import Foundation
@testable import XlessASC

/// `--json` output is a contract: keys sorted, two-space indent, slashes unescaped, one trailing newline.
@Test func jsonOutputIsStable() throws {
    let resource = ASCAnyResource(type: "apps", id: "1", attributes: ["name": .string("Hello/World"), "bundleId": .string("a.b"), "sku": .null,
                                                                     "count": .int(3)])
    let golden = """
    {
      "attributes" : {
        "bundleId" : "a.b",
        "count" : 3,
        "name" : "Hello/World",
        "sku" : null
      },
      "id" : "1",
      "type" : "apps"
    }

    """
    #expect(try ASCOutput.json(resource) == golden)
}

@Test func tablesPadEveryColumnButTheLast() {
    let table = TextTable(["ID", "NAME", "BUNDLE ID"], [["1", "Hello", "com.example.hello"], ["12345", "Ünïcode", "x"]])
    #expect(table.rendered == """
    ID     NAME     BUNDLE ID
    1      Hello    com.example.hello
    12345  Ünïcode  x

    """)
}

@Test func anEmptyTableIsItsHeader() {
    #expect(TextTable(["ID", "NAME"], []).rendered == "ID  NAME\n")
}
