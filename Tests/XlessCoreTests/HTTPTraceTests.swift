import Foundation
import Testing
@testable import XlessCore

/// Collects what a trace prints.
final class TraceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    var text: String { lock.withLock { parts.joined(separator: "\n") } }
    var trace: HTTPTrace { HTTPTrace { [self] line in lock.withLock { parts.append(line) } } }
}

/// Fake secrets: none of them may appear anywhere in a trace.
let fakeSecrets = ["FAKE-JWT", "FAKE-COOKIE", "FAKE-SCNT", "FAKE-SESSION", "FAKE-HC", "FAKE-SIG", "FAKE-PASSWORD", "FAKE-M1",
                   "FAKE-M2", "FAKE-A", "FAKE-B", "FAKE-C", "FAKE-PRIVATE", "FAKE-KEY", "FAKE-TOKEN", "FAKE-SECRET", "FAKE-CODE",
                   "FAKE-CSRF", "FAKE-USER", "FAKE-PASS"]

func expectNoFakeSecret(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for secret in fakeSecrets { #expect(!text.contains(secret), "\(secret) leaked:\n\(text)", sourceLocation: sourceLocation) }
}

@Test func goldenTraceOfTheSRPSignInHidesEveryCredential() {
    let log = TraceLog()
    let body = #"{"accountName":"dev@example.com","c":"FAKE-C","m1":"FAKE-M1","m2":"FAKE-M2","rememberMe":"no","a":"FAKE-A"}"#
    log.trace.request(method: "POST", url: URL(string: "https://idmsa.apple.com/appleauth/auth/signin/complete?isRememberMeEnabled=false"),
                      headers: ["Content-Type": "application/json", "Cookie": "aasp=FAKE-COOKIE", "scnt": "FAKE-SCNT",
                                "X-Apple-ID-Session-Id": "FAKE-SESSION", "X-Apple-HC": "FAKE-HC", "Accept": "application/json"],
                      body: Data(body.utf8))
    log.trace.response(status: 409, url: URL(string: "https://idmsa.apple.com/appleauth/auth/signin/complete"),
                       headers: ["Set-Cookie": "myacinfo=FAKE-COOKIE; Secure", "scnt": "FAKE-SCNT", "Content-Type": "application/json;charset=UTF-8",
                                 "X-Apple-ID-Session-Id": "FAKE-SESSION"],
                       body: Data(#"{"authType":"hsa2","b":"FAKE-B"}"#.utf8))
    #expect(log.text == """
    > POST https://idmsa.apple.com/appleauth/auth/signin/complete?<redacted>
    > Accept: application/json
    > Content-Type: application/json
    > Cookie: <redacted>
    > scnt: <redacted>
    > X-Apple-HC: <redacted>
    > X-Apple-ID-Session-Id: <redacted>
    > {"a":"<redacted>","accountName":"dev@example.com","c":"<redacted>","m1":"<redacted>","m2":"<redacted>","rememberMe":"no"}
    < 409 https://idmsa.apple.com/appleauth/auth/signin/complete
    < Content-Type: application/json;charset=UTF-8
    < scnt: <redacted>
    < Set-Cookie: <redacted>
    < X-Apple-ID-Session-Id: <redacted>
    < {"authType":"hsa2","b":"<redacted>"}
    """)
    expectNoFakeSecret(log.text)
}

@Test func goldenTraceOfAnAPICallKeepsItsQueryAndHidesTheBearerAndNestedSecrets() {
    let log = TraceLog()
    log.trace.request(method: "GET", url: URL(string: "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bversion%5D=42&limit=200"),
                      headers: ["Authorization": "Bearer FAKE-JWT"], body: nil)
    let body = #"{"data":{"attributes":{"name":"CI","privateKey":"FAKE-PRIVATE","keyId":"ABC123"},"type":"apiKeys"},"included":[{"token":"FAKE-TOKEN","clientSecret":"FAKE-SECRET"}]}"#
    log.trace.response(status: 201, url: URL(string: "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bversion%5D=42&limit=200"),
                       headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    #expect(log.text == """
    > GET https://api.appstoreconnect.apple.com/v1/builds?filter%5Bversion%5D=42&limit=200
    > Authorization: <redacted>
    < 201 https://api.appstoreconnect.apple.com/v1/builds?filter%5Bversion%5D=42&limit=200
    < Content-Type: application/json
    < {"data":{"attributes":{"keyId":"ABC123","name":"CI","privateKey":"<redacted>"},"type":"apiKeys"},"included":[{"clientSecret":"<redacted>","token":"<redacted>"}]}
    """)
    expectNoFakeSecret(log.text)
}

@Test func presignedUploadURLsAndRedirectsLoseTheirQueryAndUserInfo() {
    #expect(HTTPTrace.redact(url: URL(string: "https://store-031.blobstore.apple.com/itmspod11-assets/a.ipa?X-Amz-Signature=FAKE-SIG&X-Amz-Credential=FAKE-KEY"))
            == "https://store-031.blobstore.apple.com/itmspod11-assets/a.ipa?<redacted>")
    #expect(HTTPTrace.redact(url: URL(string: "https://FAKE-USER:FAKE-PASS@developer.apple.com/path#frag")) == "https://developer.apple.com/path")
    #expect(HTTPTrace.redact(url: nil) == "-")
    let lines = HTTPTrace.redact(headers: ["Location": "https://download.developer.apple.com/x.xip?token=FAKE-TOKEN"])
    #expect(lines == ["Location: https://download.developer.apple.com/x.xip?<redacted>"])
}

@Test func headerNamesAreRedactedWhateverTheirCase() {
    let lines = HTTPTrace.redact(headers: ["COOKIE": "FAKE-COOKIE", "authorization": "FAKE-JWT", "X-CSRF-Token": "FAKE-CSRF",
                                           "csrf": "FAKE-CSRF", "X-Apple-Session-Token": "FAKE-SESSION", "Accept": "*/*"])
    expectNoFakeSecret(lines.joined(separator: "\n"))
    #expect(lines.contains("Accept: */*"))
    #expect(lines.count == 6)
}

@Test func formBodiesHideSecretFieldsAndOtherBodiesShowOnlyTheirSize() {
    let form = HTTPTrace.redact(body: Data("teamId=ABC&password=FAKE-PASSWORD&securityCode=FAKE-CODE&api%5Fkey=1".utf8),
                                contentType: "application/x-www-form-urlencoded; charset=UTF-8")
    #expect(form == "teamId=ABC&password=<redacted>&securityCode=<redacted>&api%5Fkey=<redacted>")
    let pem = HTTPTrace.redact(body: Data("-----BEGIN PRIVATE KEY-----\nFAKE-PRIVATE\n-----END PRIVATE KEY-----\n".utf8), contentType: "application/x-pem-file")
    #expect(pem == "<67 bytes, application/x-pem-file>")
    #expect(HTTPTrace.redact(body: Data("FAKE-CODE".utf8), contentType: nil) == "<9 bytes>")
    #expect(HTTPTrace.redact(body: Data("123456".utf8), contentType: "application/json") == "<6 bytes, application/json>")
    #expect(HTTPTrace.redact(body: Data([0xFF, 0x00, 0x46]), contentType: "application/octet-stream") == "<3 bytes, application/octet-stream>")
    #expect(HTTPTrace.redact(body: Data(), contentType: "application/json") == nil)
}

@Test func twoFactorCodesAndKeysInJSONAreHidden() {
    let text = HTTPTrace.redact(body: Data(#"{"securityCode":{"code":"FAKE-CODE"},"phoneNumber":{"id":1},"key":"FAKE-KEY","Password":"FAKE-PASSWORD"}"#.utf8),
                                contentType: "application/json") ?? ""
    expectNoFakeSecret(text)
    #expect(text.contains(#""securityCode":"<redacted>""#))
}

@Test func longBodiesAreCut() {
    let long = "{\"items\":[" + Array(repeating: "\"abcdefghij\"", count: 1000).joined(separator: ",") + "]}"
    let text = HTTPTrace.redact(body: Data(long.utf8), contentType: "application/json") ?? ""
    #expect(text.hasPrefix("{\"items\":[\"abcdefghij\""))
    #expect(text.contains("more characters)"))
    #expect(text.count < HTTPTrace.maxBodyCharacters + 40)
}

@Test func failuresShowTheErrorKindNotItsDescription() {
    let log = TraceLog()
    log.trace.failure(url: URL(string: "https://store.apple.com/u?sig=FAKE-SIG"), error: URLError(.timedOut))
    #expect(log.text == "! https://store.apple.com/u?<redacted> failed: URLError -1001")
}
