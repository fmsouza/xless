import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XlessCore

@Test func headersAreThoseOfTheAnswerAndRepeatedOnesAreOne() {
    let headers = WinHTTPHeaders.parse("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nSet-Cookie: a=1; Path=/\r\nset-cookie: b=2\r\nX-Empty:\r\nno colon\r\nLocation: https://a.example/?x=1:2\r\n\r\n")
    #expect(headers == ["Content-Type": "text/plain", "Set-Cookie": "a=1; Path=/, b=2", "X-Empty": "", "Location": "https://a.example/?x=1:2"])
    #expect(WinHTTPHeaders.parse("") == [:] && WinHTTPHeaders.parse("HTTP/1.1 204 No Content\r\n\r\n") == [:])
}

@Test func theVariablesNameTheProxyElseTheSystemDoes() throws {
    #expect(try WinHTTPProxy(env: [:]) == .system)
    #expect(try WinHTTPProxy(env: ["HTTPS_PROXY": "", "NO_PROXY": "a.example"]) == .system)
    #expect(try WinHTTPProxy(env: ["https_proxy": "http://proxy.example:8080"]) == .named("https=proxy.example:8080", bypass: ""))
    #expect(try WinHTTPProxy(env: ["HTTP_PROXY": "proxy.example:3128/", "HTTPS_PROXY": "http://[::1]:81"]) == .named("http=proxy.example:3128 https=[::1]:81", bypass: ""))
    #expect(try WinHTTPProxy(env: ["ALL_PROXY": "http://proxy.example"]) == .named("http=proxy.example:80 https=proxy.example:80", bypass: ""))
    #expect(try WinHTTPProxy(env: ["ALL_PROXY": "http://all.example", "HTTPS_PROXY": "http://one.example:1", "NO_PROXY": "localhost, .corp.example;10.0.0.1 *.other.example"])
        == .named("http=all.example:80 https=one.example:1", bypass: "localhost;*.localhost;corp.example;*.corp.example;10.0.0.1;other.example;*.other.example"))
    #expect(try WinHTTPProxy(env: ["HTTPS_PROXY": "http://p.example:1", "NO_PROXY": "a.example,*"]) == WinHTTPProxy.none)
}

@Test(arguments: ["https://proxy.example:443", "socks5://proxy.example:1080", "http://user:pw-value@proxy.example:1", "http://user@proxy.example:1", "http://", "http://p.example/path",
                  "http://p.example:1?x", "http://a;b.example:1"])
func aProxyThatCannotBeUsedIsRefusedAndNotGoneWithout(_ text: String) {
    for name in ["HTTPS_PROXY", "ALL_PROXY"] {
        let e = #expect(throws: XlessError.self) { try WinHTTPProxy(env: [name: text]) }
        #expect(e?.stage == .config && e?.cause.contains(name) == true)
        #expect(e?.description.contains("pw-value") == false)
    }
}

@Test func aBypassThatIsNoNameIsRefused() {
    #expect(throws: XlessError.self) { try WinHTTPProxy(env: ["HTTPS_PROXY": "http://p.example:1", "NO_PROXY": "a.example,<local>"]) }
}

@Test func failuresAreOfURLErrorsKinds() {
    #expect(WinHTTPFailure.of(12002, secure: 0).0 == .timedOut)
    #expect(WinHTTPFailure.of(12029, secure: 0).0 == .cannotConnectToHost)
    #expect(WinHTTPFailure.of(12030, secure: 0).0 == .networkConnectionLost)
    #expect(WinHTTPFailure.of(12175, secure: 0x08).0 == .serverCertificateHasUnknownRoot)
    #expect(WinHTTPFailure.of(12175, secure: 0x18).0 == .serverCertificateUntrusted)
    #expect(WinHTTPFailure.of(12175, secure: 0x20).0 == .serverCertificateHasBadDate)
    #expect(WinHTTPFailure.of(12175, secure: 0x8000_0000).0 == .secureConnectionFailed)
    #expect(WinHTTPFailure.of(0xFFFF_FFFF, secure: 0).0 == .cannotConnectToHost)
    #expect(WinHTTPFailure.of(1, secure: 0).0 == .unknown)
}
