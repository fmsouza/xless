import BigInt
import Crypto
import Foundation
import XlessCore

/// An SRP group: a safe prime N and its generator g (RFC 5054 Appendix A).
struct SRPGroup: Sendable {
    let N: BigUInt
    let g: BigUInt
    /// N's length in bytes: the width PAD() fills to.
    var size: Int { (N.bitWidth + 7) / 8 }

    static let rfc5054_1024 = SRPGroup(N: BigUInt("""
        EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE4\
        8E495C1D6089DAD15DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC68EDBC3C05726CC02FD4CBF4976EAA9A\
        FD5138FE8376435B9FC61D2FC0EB06E3
        """, radix: 16)!, g: 2)

    static let rfc5054_2048 = SRPGroup(N: BigUInt("""
        AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D\
        CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74\
        7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D\
        5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6\
        94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73
        """, radix: 16)!, g: 2)
}

/// The client half of SRP-6a as Apple's sign-in (`idmsa.apple.com/appleauth/auth/signin/{init,complete}`) runs it:
/// k = H(N | PAD(g)), u = H(PAD(A) | PAD(B)), x = H(s | H(":" | passwordKey)) (no user name in x),
/// S = (B − k·gˣ)^(a + u·x) mod N, K = H(S), M1 = H(H(N) ⊕ H(PAD(g)) | H(I) | s | A | B | K), M2 = H(A | M1 | K).
/// Numbers go on the wire as minimal big-endian bytes. The password never leaves this process: only A, M1 and M2 do.
struct AppleSRPClient<H: HashFunction> {
    let group: SRPGroup
    private let a: BigUInt
    let A: BigUInt

    init(group: SRPGroup = .rfc5054_2048, privateKey: BigUInt? = nil) {
        self.group = group
        var a = privateKey ?? Self.randomPrivateKey()
        var A = group.g.power(a, modulus: group.N)
        while privateKey == nil && A.isZero {
            a = Self.randomPrivateKey()
            A = group.g.power(a, modulus: group.N)
        }
        self.a = a
        self.A = A
    }

    /// A, the public key sent in `signin/init`.
    var publicKey: [UInt8] { Array(A.serialize()) }

    var k: BigUInt { BigUInt(Data(Self.hash(Array(group.N.serialize()) + pad(group.g)))) }

    func u(serverPublicKey B: BigUInt) -> BigUInt { BigUInt(Data(Self.hash(pad(A) + pad(B)))) }

    static func x(salt: [UInt8], message: [UInt8]) -> BigUInt { BigUInt(Data(hash(salt + hash(message)))) }

    func premasterSecret(x: BigUInt, serverPublicKey B: BigUInt) throws -> BigUInt {
        let N = group.N
        guard !(B % N).isZero else { throw invalidServerKey() }
        let u = u(serverPublicKey: B)
        guard !u.isZero else { throw invalidServerKey() }
        let kv = (k * group.g.power(x, modulus: N)) % N
        let base = (B % N + N - kv) % N
        return base.power(a + u * x, modulus: N)
    }

    /// M1 (sent in `signin/complete` as `m1`) and M2 (the expected server proof, sent as `m2`).
    func proofs(accountName: String, passwordKey: [UInt8], salt: [UInt8], serverPublicKey: [UInt8]) throws -> (m1: [UInt8], m2: [UInt8]) {
        let B = BigUInt(Data(serverPublicKey))
        let x = Self.x(salt: salt, message: [0x3a] + passwordKey)
        let S = try premasterSecret(x: x, serverPublicKey: B)
        let K = Self.hash(Array(S.serialize()))
        let hN = Self.hash(Array(group.N.serialize())), hg = Self.hash(pad(group.g))
        let nXorG = zip(hN, hg).map { $0 ^ $1 }
        let a = Array(A.serialize()), b = Array(B.serialize())
        var m1Input: [UInt8] = nXorG
        m1Input += Self.hash(Array(accountName.utf8))
        m1Input += salt
        m1Input += a
        m1Input += b
        m1Input += K
        let m1 = Self.hash(m1Input)
        let m2 = Self.hash(a + m1 + K)
        return (m1, m2)
    }

    private func pad(_ n: BigUInt) -> [UInt8] {
        let raw = Array(n.serialize())
        return raw.count >= group.size ? raw : [UInt8](repeating: 0, count: group.size - raw.count) + raw
    }

    private static func hash(_ data: [UInt8]) -> [UInt8] { Array(H.hash(data: data)) }

    private static func randomPrivateKey() -> BigUInt {
        BigUInt(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private func invalidServerKey() -> XlessError {
        XlessError(.sdk, "Apple's sign-in sent an invalid SRP server key", fix: "re-run xless xcode download; if it keeps failing, Apple's sign-in may have changed")
    }
}

typealias AppleSRP = AppleSRPClient<SHA256>
