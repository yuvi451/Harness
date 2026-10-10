import Foundation
import Security

public struct OpenAIIDTokenValidator {
    public init() {}
    public func validate(_ token: String, jwks: Data, clientID: String, nonce: String?, now: Date) throws -> ChatGPTIdentity {
        guard token.utf8.count <= 65_536, jwks.count <= 262_144, now.timeIntervalSince1970.isFinite else { throw ChatGPTAuthenticationError.invalidIdentity }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let headerData = Data(oauthBase64URL: String(pieces[0])), let payloadData = Data(oauthBase64URL: String(pieces[1])),
              let signature = Data(oauthBase64URL: String(pieces[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256",
              header["crit"] == nil, let kid = header["kid"] as? String, !kid.isEmpty, kid.utf8.count <= 256,
              let keys = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any], let allKeys = keys["keys"] as? [[String: Any]], allKeys.count <= 64 else { throw ChatGPTAuthenticationError.invalidIdentity }
        let matches = allKeys.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }
        guard matches.count == 1, let jwk = matches.first, jwk["alg"] == nil || jwk["alg"] as? String == "RS256",
              jwk["use"] == nil || jwk["use"] as? String == "sig",
              let nString = jwk["n"] as? String, let eString = jwk["e"] as? String,
              let modulus = Data(oauthBase64URL: nString), let exponent = Data(oauthBase64URL: eString),
              (256...512).contains(modulus.count), (1...4).contains(exponent.count), signature.count == modulus.count else { throw ChatGPTAuthenticationError.invalidIdentity }
        if let ops = jwk["key_ops"] as? [String], !ops.contains("verify") { throw ChatGPTAuthenticationError.invalidIdentity }
        let der = Self.der(0x30, Self.integer(modulus) + Self.integer(exponent))
        var securityError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits: modulus.count * 8] as CFDictionary, &securityError),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("\(pieces[0]).\(pieces[1])".utf8) as CFData, signature as CFData, &securityError),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              claims["iss"] as? String == OpenAIAuth.issuer, let subject = claims["sub"] as? String, !subject.isEmpty, subject.utf8.count <= 512,
              let expires = Self.number(claims["exp"]), let issued = Self.number(claims["iat"]), expires > now.timeIntervalSince1970 - 5,
              issued <= now.timeIntervalSince1970 + 5 else { throw ChatGPTAuthenticationError.invalidIdentity }
        let audiences = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String] ?? [])
        guard audiences.contains(clientID), !audiences.isEmpty else { throw ChatGPTAuthenticationError.invalidIdentity }
        if audiences.count > 1 || claims["azp"] != nil { guard claims["azp"] as? String == clientID else { throw ChatGPTAuthenticationError.invalidIdentity } }
        if let nonce { guard claims["nonce"] as? String == nonce else { throw ChatGPTAuthenticationError.invalidIdentity } }
        if claims["nbf"] != nil { guard let nbf = Self.number(claims["nbf"]), nbf <= now.timeIntervalSince1970 + 5 else { throw ChatGPTAuthenticationError.invalidIdentity } }
        let email = (claims["email"] as? String).flatMap { $0.utf8.count <= 320 ? $0 : nil }
        return ChatGPTIdentity(issuer: OpenAIAuth.issuer, subject: subject, email: email)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func integer(_ value: Data) -> Data {
        var data = value
        if let first = data.first, first & 128 != 0 { data.insert(0, at: 0) }
        return der(0x02, data)
    }
    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        var bytes = Data([tag])
        if value.count < 128 { bytes.append(UInt8(value.count)) }
        else {
            var length = value.count, encoded: [UInt8] = []
            while length > 0 { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 }
            bytes.append(128 | UInt8(encoded.count)); bytes.append(contentsOf: encoded)
        }
        bytes.append(value); return bytes
    }
}

extension Data {
    var oauthBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(oauthBase64URL value: String) {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}
