import XCTest
@testable import XlessCore

final class TextRedactionTests: XCTestCase {
    let r = HTTPTrace.placeholder

    func testPlainTextIsUnchanged() {
        let text = "==> TestFlight: build number 29012345\nxless apps list\nID         NAME\n6471234567 Hello\n"
        XCTAssertEqual(TextRedaction.redact(text), text)
    }

    func testAPEMPrivateKeyBlockIsHiddenWhole() {
        let text = """
        before
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgAAAA
        -----END PRIVATE KEY-----
        after
        """
        XCTAssertEqual(TextRedaction.redact(text), "before\n\(r)\nafter")
    }

    func testAnUnterminatedPEMHidesTheRest() {
        XCTAssertEqual(TextRedaction.redact("a\n-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\nmore"), "a\n\(r)")
    }

    func testACertificateIsKept() {
        let text = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
        XCTAssertEqual(TextRedaction.redact(text), text)
    }

    func testJWTsAndBearerTokens() {
        let jwt = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.c2lnbmF0dXJl"
        XCTAssertEqual(TextRedaction.redact("token \(jwt) end"), "token \(r) end")
        XCTAssertEqual(TextRedaction.redact("Authorization: Bearer abc.def"), "Authorization: \(r)")
        XCTAssertEqual(TextRedaction.redact("curl -H 'Bearer abcdef'"), "curl -H 'Bearer \(r)'")
    }

    func testTraceHeaderLinesFollowHTTPTrace() {
        XCTAssertEqual(TextRedaction.redact("> Cookie: myacinfo=abc; dqsid=x"), "> Cookie: \(r)")
        XCTAssertEqual(TextRedaction.redact("< scnt: AAAA"), "< scnt: \(r)")
        XCTAssertEqual(TextRedaction.redact("< X-Apple-ID-Session-Id: 123"), "< X-Apple-ID-Session-Id: \(r)")
        XCTAssertEqual(TextRedaction.redact("< Content-Type: application/json"), "< Content-Type: application/json")
        XCTAssertEqual(TextRedaction.redact("Set-Cookie: myacinfo=abc"), "Set-Cookie: \(r)")
        XCTAssertEqual(TextRedaction.redact("session: kept until 10:42"), "session: kept until 10:42", "a line that is no trace keeps a word that is no credential header")
    }

    func testSecretJSONAndFormFields() {
        XCTAssertEqual(TextRedaction.redact(#"{"password": "hunter2", "name": "ok"}"#), #"{"password": "\#(r)", "name": "ok"}"#)
        XCTAssertEqual(TextRedaction.redact(#""demoAccountPassword":"p w""#), #""demoAccountPassword":"\#(r)""#)
        XCTAssertEqual(TextRedaction.redact("accountName=a&password=x%20y&rememberMe=true"), "accountName=a&password=\(r)&rememberMe=true")
        XCTAssertEqual(TextRedaction.redact("XLESS_PASSPHRASE=abc"), "XLESS_PASSPHRASE=\(r)")
        XCTAssertEqual(TextRedaction.redact("ASC_KEY_P8_FILE=/secrets/asc.p8"), "ASC_KEY_P8_FILE=/secrets/asc.p8")
    }

    func testQueriesOfOtherHostsAreHidden() {
        XCTAssertEqual(TextRedaction.redact("PUT https://store-030.blobstore.apple.com/x?sig=abc&e=1 ok"),
                       "PUT https://store-030.blobstore.apple.com/x?\(r) ok")
        let asc = "GET https://api.appstoreconnect.apple.com/v1/apps?limit=200"
        XCTAssertEqual(TextRedaction.redact(asc), asc)
    }

    func testGivenValuesAreHiddenEverywhere() {
        XCTAssertEqual(TextRedaction.redact("Signed in to Apple as ada@example.com.", hiding: ["ada@example.com", ""]),
                       "Signed in to Apple as \(r).")
    }

    func testRedactingTwiceChangesNothingMore() {
        let text = "> Cookie: a=b\n{\"token\": \"x\"}\neyJa.eyJb.c\n-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----"
        let once = TextRedaction.redact(text)
        XCTAssertEqual(TextRedaction.redact(once), once)
    }
}
