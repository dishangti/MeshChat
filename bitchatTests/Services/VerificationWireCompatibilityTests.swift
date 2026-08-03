import CryptoKit
import XCTest
@testable import bitchat

/// Fixed-byte contracts shared with the original Bitchat verification v1
/// implementation. These fixtures intentionally do not derive their expected
/// bytes from the production encoder.
final class VerificationWireCompatibilityTests: XCTestCase {
    private let noiseKeyHex =
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    private let signingKeyHex =
        "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"
    private let nonce = Data((0..<16).map(UInt8.init))

    func test_qrCanonicalBytesMatchBitchatV1Fixture() throws {
        let qr = makeQR()
        let expected = try XCTUnwrap(Data(hexString:
            "11626974636861742d7665726966792d7631" +
            "0131" +
            "4030303131323233333434353536363737383839396161626263636464656566663030313132323333343435353636373738383939616162626363646465656666" +
            "4066666565646463636262616139393838373736363535343433333232313130306666656564646363626261613939383837373636353534343333323231313030" +
            "00" +
            "05416c696365" +
            "0a31373030303030303030" +
            "1641414543417751464267634943516f4c4441304f4477"
        ))

        XCTAssertEqual(qr.canonicalBytes(), expected)
        XCTAssertEqual(VerificationService.VerificationQR.context, "bitchat-verify-v1")
    }

    func test_qrURLMatchesBitchatV1SchemeFieldsAndOrder() {
        let qr = makeQR()
        let expected =
            "bitchat://verify?v=1" +
            "&noise=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" +
            "&sign=ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100" +
            "&nick=Alice" +
            "&ts=1700000000" +
            "&nonce=AAECAwQFBgcICQoLDA0ODw" +
            "&sig=a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf"

        XCTAssertEqual(qr.toURLString(), expected)
    }

    func test_qrWithNpubMatchesBitchatV1FieldOrderAndSignatureBytes() throws {
        let npub =
            "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzqujme"
        let qr = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: noiseKeyHex,
            signKeyHex: signingKeyHex,
            npub: npub,
            nickname: "Alice",
            ts: 1_700_000_000,
            nonceB64: nonce.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""),
            sigHex:
                "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" +
                "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf" +
                "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf" +
                "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
        )
        let expectedCanonical = try XCTUnwrap(Data(hexString:
            "11626974636861742d7665726966792d7631" +
            "0131" +
            "4030303131323233333434353536363737383839396161626263636464656566663030313132323333343435353636373738383939616162626363646465656666" +
            "4066666565646463636262616139393838373736363535343433333232313130306666656564646363626261613939383837373636353534343333323231313030" +
            "3f6e70756231717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717a71756a6d65" +
            "05416c696365" +
            "0a31373030303030303030" +
            "1641414543417751464267634943516f4c4441304f4477"
        ))
        let expectedURL =
            "bitchat://verify?v=1" +
            "&noise=\(noiseKeyHex)" +
            "&sign=\(signingKeyHex)" +
            "&nick=Alice" +
            "&ts=1700000000" +
            "&nonce=AAECAwQFBgcICQoLDA0ODw" +
            "&sig=\(qr.sigHex)" +
            "&npub=\(npub)"

        XCTAssertEqual(qr.canonicalBytes(), expectedCanonical)
        XCTAssertEqual(qr.toURLString(), expectedURL)
        let decoded = try XCTUnwrap(
            VerificationService.VerificationQR.fromURL(
                try XCTUnwrap(URL(string: expectedURL))
            )
        )
        XCTAssertEqual(decoded, qr)
    }

    func test_verifyChallengeMatchesBitchatV1TypeAndTLVFixture() throws {
        let service = VerificationService()
        let encoded = service.buildVerifyChallenge(
            noiseKeyHex: noiseKeyHex,
            nonceA: nonce
        )
        let expected = try XCTUnwrap(Data(hexString:
            "100140" +
            "30303131323233333434353536363737383839396161626263636464656566663030313132323333343435353636373738383939616162626363646465656666" +
            "0210000102030405060708090a0b0c0d0e0f"
        ))

        XCTAssertEqual(encoded, expected)
        let decoded = try XCTUnwrap(NoisePayload.decode(encoded))
        XCTAssertEqual(decoded.type.rawValue, 0x10)
        XCTAssertEqual(decoded.type, .verifyChallenge)
        let parsed = try XCTUnwrap(service.parseVerifyChallenge(decoded.data))
        XCTAssertEqual(parsed.noiseKeyHex, noiseKeyHex)
        XCTAssertEqual(parsed.nonceA, nonce)
    }

    func test_verifyResponseMatchesBitchatV1TypeTLVsAndSignatureContext() throws {
        let transport = MockTransport()
        let service = VerificationService()
        service.configure(with: transport)

        let encoded = try XCTUnwrap(service.buildVerifyResponse(
            noiseKeyHex: noiseKeyHex,
            nonceA: nonce
        ))
        let decoded = try XCTUnwrap(NoisePayload.decode(encoded))
        let parsed = try XCTUnwrap(service.parseVerifyResponse(decoded.data))

        XCTAssertEqual(decoded.type.rawValue, 0x11)
        XCTAssertEqual(decoded.type, .verifyResponse)
        XCTAssertEqual(parsed.noiseKeyHex, noiseKeyHex)
        XCTAssertEqual(parsed.nonceA, nonce)
        XCTAssertEqual(parsed.signature.count, 64)

        var legacySignedBytes = Data("bitchat-verify-resp-v1".utf8)
        legacySignedBytes.append(UInt8(noiseKeyHex.utf8.count))
        legacySignedBytes.append(Data(noiseKeyHex.utf8))
        legacySignedBytes.append(nonce)
        let signingPublicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: transport.noiseSigningPublicKeyData()
        )
        XCTAssertTrue(signingPublicKey.isValidSignature(
            parsed.signature,
            for: legacySignedBytes
        ))

        var expected = Data([0x11, 0x01, 0x40])
        expected.append(Data(noiseKeyHex.utf8))
        expected.append(contentsOf: [0x02, 0x10])
        expected.append(nonce)
        expected.append(contentsOf: [0x03, 0x40])
        expected.append(parsed.signature)
        XCTAssertEqual(encoded, expected)
    }

    private func makeQR() -> VerificationService.VerificationQR {
        VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: noiseKeyHex,
            signKeyHex: signingKeyHex,
            npub: nil,
            nickname: "Alice",
            ts: 1_700_000_000,
            nonceB64: nonce.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""),
            sigHex:
                "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" +
                "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf" +
                "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf" +
                "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
        )
    }
}
