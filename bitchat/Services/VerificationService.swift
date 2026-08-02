import Foundation
import Security

/// QR verification scaffolding: schema, signing, and basic challenge/response helpers.
final class VerificationService {
    static let shared = VerificationService()
    private static let maximumScannedURLByteCount = 2_048

    private struct QRCacheEntry {
        let nickname: String
        let npub: String?
        let noiseKey: Data
        let signingKey: Data
        let builtAt: Date
        let value: String
    }

    // Injected running transport (do NOT create new BLEService). Noise
    // identity operations go through the transport's narrow noise* wrappers
    // so the raw NoiseEncryptionService is never exposed.
    private var transport: Transport?
    private var qrCache: QRCacheEntry?
    func configure(with transport: Transport) { self.transport = transport }

    /// Encapsulates the data encoded into a verification QR
    struct VerificationQR: Codable, Equatable {
        let v: Int
        let noiseKeyHex: String
        let signKeyHex: String
        let npub: String?
        let nickname: String
        let ts: Int64
        let nonceB64: String
        var sigHex: String

        static let context = "bitchat-verify-v1"

        private static let currentVersion = 1
        private static let publicKeyByteCount = 32
        private static let signatureByteCount = 64
        private static let nonceByteCount = 16
        private static let maximumCanonicalFieldByteCount = 255
        fileprivate static let maximumFutureClockSkew: TimeInterval = 60

        /// Canonical bytes used for signature (deterministic ordering)
        func canonicalBytes() -> Data {
            var out = Data()
            func appendField(_ s: String) {
                let d = s.data(using: .utf8) ?? Data()
                out.append(UInt8(min(d.count, 255)))
                out.append(d.prefix(255))
            }
            appendField(Self.context)
            appendField(String(v))
            appendField(noiseKeyHex.lowercased())
            appendField(signKeyHex.lowercased())
            appendField(npub ?? "")
            appendField(nickname)
            appendField(String(ts))
            appendField(nonceB64)
            return out
        }

        func toURLString() -> String {
            var comps = URLComponents()
            comps.scheme = ChatURLScheme.canonical
            comps.host = "verify"
            comps.queryItems = [
                URLQueryItem(name: "v", value: String(v)),
                URLQueryItem(name: "noise", value: noiseKeyHex),
                URLQueryItem(name: "sign", value: signKeyHex),
                URLQueryItem(name: "nick", value: nickname),
                URLQueryItem(name: "ts", value: String(ts)),
                URLQueryItem(name: "nonce", value: nonceB64),
                URLQueryItem(name: "sig", value: sigHex)
            ] + (npub != nil ? [URLQueryItem(name: "npub", value: npub)] : [])
            return comps.string ?? ""
        }

        static func fromURL(_ url: URL) -> VerificationQR? {
            guard ChatURLScheme.accepts(url.scheme), url.host?.lowercased() == "verify",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }

            var seenNames = Set<String>()
            for item in items {
                guard seenNames.insert(item.name).inserted else { return nil }
            }

            func val(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
            guard let vStr = val("v"), let v = Int(vStr), vStr == String(v),
                  let noise = val("noise"), let sign = val("sign"),
                  let nick = val("nick"), let tsStr = val("ts"), let ts = Int64(tsStr), tsStr == String(ts),
                  let nonce = val("nonce"), let sig = val("sig") else { return nil }

            let npub: String?
            if let item = items.first(where: { $0.name == "npub" }) {
                guard let value = item.value else { return nil }
                npub = value
            } else {
                npub = nil
            }

            let qr = VerificationQR(
                v: v,
                noiseKeyHex: noise,
                signKeyHex: sign,
                npub: npub,
                nickname: nick,
                ts: ts,
                nonceB64: nonce,
                sigHex: sig
            )
            return qr.hasValidStructure ? qr : nil
        }

        fileprivate var hasValidUnsignedFields: Bool {
            guard v == Self.currentVersion,
                  Self.exactHexData(noiseKeyHex, byteCount: Self.publicKeyByteCount) != nil,
                  Self.exactHexData(signKeyHex, byteCount: Self.publicKeyByteCount) != nil,
                  Self.decodeNonce(nonceB64)?.count == Self.nonceByteCount,
                  Self.normalizedProtocolNickname(nickname) != nil,
                  Self.isValidNpub(npub) else {
                return false
            }
            return true
        }

        fileprivate var hasValidStructure: Bool {
            hasValidUnsignedFields
                && Self.exactHexData(sigHex, byteCount: Self.signatureByteCount) != nil
        }

        private static func exactHexData(_ value: String, byteCount: Int) -> Data? {
            guard value.utf8.count == byteCount * 2,
                  let data = Data(hexString: value),
                  data.count == byteCount else {
                return nil
            }
            return data
        }

        private static func decodeNonce(_ value: String) -> Data? {
            guard value.utf8.count == 22 || value.utf8.count == 24,
                  value.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 43, 45, 47, 48...57, 61, 65...90, 95, 97...122:
                          return true
                      default:
                          return false
                      }
                  }) else {
                return nil
            }

            var normalized = value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let remainder = normalized.count % 4
            guard remainder != 1 else { return nil }
            if remainder != 0 {
                normalized.append(String(repeating: "=", count: 4 - remainder))
            }
            guard let decoded = Data(base64Encoded: normalized) else { return nil }

            let standardPadded = decoded.base64EncodedString()
            let urlSafeUnpadded = standardPadded
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            guard value == standardPadded || value == urlSafeUnpadded else { return nil }
            return decoded
        }

        /// Verification QR v1 prefixes canonical fields with one byte, so a
        /// peer nickname follows Bitchat's 255-byte wire limit rather than the
        /// stricter 50-character limit used for new local profile input. This
        /// preserves interoperability with existing Bitchat identities while
        /// still rejecting truncation ambiguity, controls, and non-canonical
        /// whitespace or Unicode normalization.
        /// Applies the nickname constraints shared by Bitchat's announce wire
        /// and verification QR. This is intentionally wider than the local
        /// profile/alias input limit so existing peers with long protocol-
        /// valid names remain interoperable at every persistence boundary.
        static func normalizedProtocolNickname(_ value: String) -> String? {
            guard let trimmed = value.trimmedOrNilIfEmpty?.normalizedNickname,
                  trimmed == value,
                  value.utf8.count <= maximumCanonicalFieldByteCount else {
                return nil
            }
            guard value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }) else {
                return nil
            }
            return trimmed
        }

        private static func isValidNpub(_ value: String?) -> Bool {
            guard let value else { return true }
            guard let decoded = try? Bech32.decode(value),
                  decoded.hrp == "npub",
                  decoded.data.count == publicKeyByteCount,
                  let canonical = try? Bech32.encode(hrp: "npub", data: decoded.data) else {
                return false
            }
            return canonical == value
        }
    }

    // MARK: - Public API

    /// Build a signed QR string for the current identity
    func buildMyQRString(nickname: String, npub: String?) -> String? {
        guard let transport = transport else { return nil }
        let noiseKeyData = transport.noiseStaticPublicKeyData()
        let signingKeyData = transport.noiseSigningPublicKeyData()
        let noiseKey = noiseKeyData.hexEncodedString()
        let signKey = signingKeyData.hexEncodedString()
        let ts = Int64(Date().timeIntervalSince1970)
        var nonce = Data(count: 16)
        let nonceLength = nonce.count
        let randomStatus = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, nonceLength, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { return nil }
        let nonceB64 = nonce.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payload = VerificationQR(v: 1, noiseKeyHex: noiseKey, signKeyHex: signKey, npub: npub, nickname: nickname, ts: ts, nonceB64: nonceB64, sigHex: "")
        guard payload.hasValidUnsignedFields else { return nil }

        if let cached = qrCache,
           cached.nickname == nickname,
           cached.npub == npub,
           cached.noiseKey == noiseKeyData,
           cached.signingKey == signingKeyData,
           Date().timeIntervalSince(cached.builtAt) >= 0,
           Date().timeIntervalSince(cached.builtAt) < 60 {
            return cached.value
        }

        let msg = payload.canonicalBytes()
        guard let sig = transport.noiseSignData(msg) else { return nil }
        let signed = VerificationQR(v: payload.v,
                                    noiseKeyHex: payload.noiseKeyHex,
                                    signKeyHex: payload.signKeyHex,
                                    npub: payload.npub,
                                    nickname: payload.nickname,
                                    ts: payload.ts,
                                    nonceB64: payload.nonceB64,
                                    sigHex: sig.hexEncodedString())
        guard signed.hasValidStructure else { return nil }
        let out = signed.toURLString()
        qrCache = QRCacheEntry(
            nickname: nickname,
            npub: npub,
            noiseKey: noiseKeyData,
            signingKey: signingKeyData,
            builtAt: Date(),
            value: out
        )
        return out
    }

    /// Verify a scanned QR and return the parsed payload if valid (signature + freshness checks)
    func verifyScannedQR(_ urlString: String, maxAge: TimeInterval = TransportConfig.verificationQRMaxAgeSeconds) -> VerificationQR? {
        guard urlString.utf8.count <= Self.maximumScannedURLByteCount,
              maxAge.isFinite, maxAge >= 0,
              let url = URL(string: urlString),
              let qr = VerificationQR.fromURL(url) else { return nil }
        // Freshness
        let now = Date().timeIntervalSince1970
        let age = now - Double(qr.ts)
        let boundedMaxAge = min(maxAge, TransportConfig.verificationQRMaxAgeSeconds)
        let futureClockSkew = min(boundedMaxAge, VerificationQR.maximumFutureClockSkew)
        guard age.isFinite, age <= boundedMaxAge, age >= -futureClockSkew else { return nil }
        // Verify signature using embedded ed25519 signKey
        guard let sig = Data(hexString: qr.sigHex), let signKey = Data(hexString: qr.signKeyHex) else { return nil }
        guard let transport = transport else { return nil }
        let ok = transport.noiseVerifySignature(sig, for: qr.canonicalBytes(), publicKey: signKey)
        return ok ? qr : nil
    }

    // MARK: - Noise payloads (scaffold only)

    func buildVerifyChallenge(noiseKeyHex: String, nonceA: Data) -> Data {
        // TLV: [0x01 len noiseKeyHex ascii] [0x02 len nonceA]
        var tlv = Data()
        let n0: [UInt8] = [0x01, UInt8(min(noiseKeyHex.count, 255))]
        tlv.append(contentsOf: n0)
        tlv.append(noiseKeyHex.data(using: .utf8)!.prefix(255))
        tlv.append(0x02)
        tlv.append(UInt8(min(nonceA.count, 255)))
        tlv.append(nonceA.prefix(255))
        return NoisePayload(type: .verifyChallenge, data: tlv).encode()
    }

    func buildVerifyResponse(noiseKeyHex: String, nonceA: Data) -> Data? {
        // Sign context: verify-response | noiseKeyHex | nonceA
        var msg = Data("bitchat-verify-resp-v1".utf8)
        let nk = noiseKeyHex.data(using: .utf8) ?? Data()
        msg.append(UInt8(min(nk.count, 255))); msg.append(nk.prefix(255))
        msg.append(nonceA)
        guard let transport = transport, let sig = transport.noiseSignData(msg) else { return nil }
        var tlv = Data()
        tlv.append(0x01); tlv.append(UInt8(min(nk.count, 255))); tlv.append(nk.prefix(255))
        tlv.append(0x02); tlv.append(UInt8(min(nonceA.count, 255))); tlv.append(nonceA.prefix(255))
        tlv.append(0x03); tlv.append(UInt8(min(sig.count, 255))); tlv.append(sig.prefix(255))
        return NoisePayload(type: .verifyResponse, data: tlv).encode()
    }

    func parseVerifyChallenge(_ data: Data) -> (noiseKeyHex: String, nonceA: Data)? {
        var idx = 0
        func take(_ n: Int) -> Data? {
            guard idx + n <= data.count else { return nil }
            let d = data[idx..<(idx+n)]
            idx += n
            return Data(d)
        }
        // Expect type already stripped; we receive only TLV here
        // TLV 0x01 noiseKeyHex
        guard let t1 = take(1), t1[0] == 0x01, let l1 = take(1), let s1 = take(Int(l1[0])),
              let noiseStr = String(data: s1, encoding: .utf8) else { return nil }
        // TLV 0x02 nonceA
        guard let t2 = take(1), t2[0] == 0x02, let l2 = take(1), let nA = take(Int(l2[0])) else { return nil }
        return (noiseStr, nA)
    }

    func parseVerifyResponse(_ data: Data) -> (noiseKeyHex: String, nonceA: Data, signature: Data)? {
        var idx = 0
        func take(_ n: Int) -> Data? {
            guard idx + n <= data.count else { return nil }
            let d = data[idx..<(idx+n)]
            idx += n
            return Data(d)
        }
        guard let t1 = take(1), t1[0] == 0x01, let l1 = take(1), let s1 = take(Int(l1[0])),
              let noiseStr = String(data: s1, encoding: .utf8) else { return nil }
        guard let t2 = take(1), t2[0] == 0x02, let l2 = take(1), let nA = take(Int(l2[0])) else { return nil }
        guard let t3 = take(1), t3[0] == 0x03, let l3 = take(1), let sig = take(Int(l3[0])) else { return nil }
        return (noiseStr, nA, sig)
    }

    func verifyResponseSignature(noiseKeyHex: String, nonceA: Data, signature: Data, signerPublicKeyHex: String) -> Bool {
        var msg = Data("bitchat-verify-resp-v1".utf8)
        let nk = noiseKeyHex.data(using: .utf8) ?? Data()
        msg.append(UInt8(min(nk.count, 255))); msg.append(nk.prefix(255))
        msg.append(nonceA)
        guard let transport = transport, let pub = Data(hexString: signerPublicKeyHex) else { return false }
        return transport.noiseVerifySignature(signature, for: msg, publicKey: pub)
    }
}
