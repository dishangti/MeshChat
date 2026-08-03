import XCTest
@testable import bitchat

final class VerificationServiceTests: XCTestCase {
    func test_buildMyQRString_roundTripsSuccessfully() throws {
        let (service, noise) = makeService()
        let nickname = "alice-\(UUID().uuidString)"
        let npub = try makeValidNpub()

        let qrString = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: npub))
        let parsed = try XCTUnwrap(service.verifyScannedQR(qrString))

        XCTAssertEqual(parsed.nickname, nickname)
        XCTAssertEqual(parsed.npub, npub)
        XCTAssertEqual(parsed.routableNpub, npub)
        XCTAssertEqual(parsed.noiseKeyHex, noise.getStaticPublicKeyData().hexEncodedString())
        XCTAssertEqual(parsed.signKeyHex, noise.getSigningPublicKeyData().hexEncodedString())
    }

    func test_verifyScannedQR_acceptsSelfSignedHybridWithoutAttributingNoiseKey() throws {
        let (scanner, _) = makeService()
        let (_, victimNoise) = makeService()
        let (_, attackerNoise) = makeService()
        let victimNoiseKey = victimNoise.getStaticPublicKeyData()
        let attackerSigningKey = attackerNoise.getSigningPublicKeyData()
        let qrString = try makeSignedQR(
            noise: attackerNoise,
            noiseKeyHex: victimNoiseKey.hexEncodedString(),
            signKeyHex: attackerSigningKey.hexEncodedString(),
            nickname: "hybrid-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970)
        )

        // The scan proves possession of the embedded signing key only. It
        // cannot prove that the signer owns the separately declared Noise key.
        let parsed = try XCTUnwrap(scanner.verifyScannedQR(qrString))
        XCTAssertEqual(parsed.noiseKeyHex, victimNoiseKey.hexEncodedString())
        XCTAssertEqual(parsed.signKeyHex, attackerSigningKey.hexEncodedString())
        XCTAssertNotEqual(
            attackerSigningKey,
            victimNoise.getSigningPublicKeyData()
        )
    }

    func test_buildMyQRString_returnsCachedValueForSameInputs() throws {
        let (service, _) = makeService()
        let nickname = "cache-\(UUID().uuidString)"

        let first = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        let second = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))

        XCTAssertEqual(first, second)
    }

    func test_buildMyQRString_refreshesBeforeBitchatFreshnessExpires() throws {
        var instant = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = MockTransport()
        let service = VerificationService(now: { instant })
        service.configure(with: transport)

        let first = try XCTUnwrap(
            service.buildMyQRString(nickname: "Alice", npub: nil)
        )
        instant.addTimeInterval(59)
        XCTAssertEqual(
            service.buildMyQRString(nickname: "Alice", npub: nil),
            first
        )

        instant.addTimeInterval(2)
        let refreshed = try XCTUnwrap(
            service.buildMyQRString(nickname: "Alice", npub: nil)
        )
        XCTAssertNotEqual(refreshed, first)
        let refreshedQR = try XCTUnwrap(
            VerificationService.VerificationQR.fromURL(
                XCTUnwrap(URL(string: refreshed))
            )
        )
        XCTAssertEqual(refreshedQR.ts, 1_700_000_061)
    }

    func test_buildMyQRString_cacheIsScopedToTheCurrentIdentity() throws {
        let service = VerificationService()
        let firstTransport = MockTransport()
        service.configure(with: firstTransport)

        let nickname = "id-cache-\(UUID().uuidString)"
        let first = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        let firstQR = try XCTUnwrap(VerificationService.VerificationQR.fromURL(XCTUnwrap(URL(string: first))))

        let secondTransport = MockTransport()
        service.configure(with: secondTransport)
        let second = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        let secondQR = try XCTUnwrap(VerificationService.VerificationQR.fromURL(XCTUnwrap(URL(string: second))))

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(firstQR.noiseKeyHex, secondQR.noiseKeyHex)
        XCTAssertNotEqual(firstQR.signKeyHex, secondQR.signKeyHex)
    }

    func test_buildMyQRString_acceptsBitchatWireNicknameAndRejectsOversizeOrInvalidNpub() throws {
        let (service, _) = makeService()

        XCTAssertNil(service.buildMyQRString(nickname: " ", npub: nil))
        XCTAssertNotNil(
            service.buildMyQRString(
                nickname: String(repeating: "a", count: InputValidator.Limits.maxNicknameLength + 1),
                npub: nil
            )
        )
        XCTAssertNil(
            service.buildMyQRString(
                nickname: String(repeating: "a", count: 256),
                npub: nil
            )
        )
        XCTAssertNil(service.buildMyQRString(nickname: "alice", npub: "npub1not-valid"))
    }

    func test_verificationQR_keepsCanonicalSchemeAndAcceptsMeshChatAlias() throws {
        let (_, noise) = makeService()
        let canonicalString = try makeSignedQR(
            noise: noise,
            nickname: "alias-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970)
        )
        let canonicalURL = try XCTUnwrap(URL(string: canonicalString))

        XCTAssertEqual(canonicalURL.scheme, ChatURLScheme.canonical)

        var aliasComponents = try XCTUnwrap(
            URLComponents(url: canonicalURL, resolvingAgainstBaseURL: false)
        )
        aliasComponents.scheme = ChatURLScheme.meshChatAlias
        let aliasURL = try XCTUnwrap(aliasComponents.url)

        XCTAssertNotNil(VerificationService.VerificationQR.fromURL(aliasURL))
    }

    func test_verificationQR_emitsUnchangedBitchatV1URLShape() throws {
        let (service, _) = makeService()
        let qrString = try XCTUnwrap(
            service.buildMyQRString(nickname: "Alice", npub: nil)
        )
        let components = try XCTUnwrap(URLComponents(string: qrString))

        XCTAssertEqual(components.scheme, "bitchat")
        XCTAssertEqual(components.host, "verify")
        XCTAssertEqual(
            components.queryItems?.map(\.name),
            ["v", "noise", "sign", "nick", "ts", "nonce", "sig"]
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "v" })?.value,
            "1"
        )
        XCTAssertEqual(
            VerificationService.VerificationQR.context,
            "bitchat-verify-v1"
        )
    }

    func test_verifyScannedQR_rejectsExpiredPayload() throws {
        let (service, noise) = makeService()
        let oldTimestamp = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "expired-\(UUID().uuidString)",
            npub: nil,
            ts: oldTimestamp
        )

        XCTAssertNil(service.verifyScannedQR(qrString, maxAge: 60))
    }

    func test_verifyScannedQR_capsCallerSuppliedMaximumAge() throws {
        let (service, noise) = makeService()
        let oldTimestamp = Int64(
            Date()
                .addingTimeInterval(-(TransportConfig.verificationQRMaxAgeSeconds + 60))
                .timeIntervalSince1970
        )
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "bounded-age-\(UUID().uuidString)",
            npub: nil,
            ts: oldTimestamp
        )

        XCTAssertNil(service.verifyScannedQR(qrString, maxAge: 3_600))
    }

    func test_verifyScannedQR_acceptsBitchatClockSkewWithinLifetime() throws {
        let (service, noise) = makeService()
        let nearFuture = try makeSignedQR(
            noise: noise,
            nickname: "near-future-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().addingTimeInterval(120).timeIntervalSince1970)
        )
        let farFuture = try makeSignedQR(
            noise: noise,
            nickname: "far-future-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(
                Date()
                    .addingTimeInterval(
                        TransportConfig.verificationQRMaxAgeSeconds + 60
                    )
                    .timeIntervalSince1970
            )
        )

        XCTAssertNotNil(service.verifyScannedQR(nearFuture))
        XCTAssertNil(service.verifyScannedQR(farFuture))
    }

    func test_verifyScannedQR_rejectsInvalidMaximumAge() throws {
        let (service, noise) = makeService()
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "bad-age-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970)
        )

        XCTAssertNil(service.verifyScannedQR(qrString, maxAge: -1))
        XCTAssertNil(service.verifyScannedQR(qrString, maxAge: .infinity))
    }

    func test_verifyScannedQR_rejectsOversizedRawURLBeforeParsing() throws {
        let (service, noise) = makeService()
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "url-size-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970)
        )
        let oversized = qrString + "&ignored=" + String(repeating: "a", count: 2_048)

        XCTAssertGreaterThan(oversized.utf8.count, 2_048)
        XCTAssertNil(service.verifyScannedQR(oversized))
    }

    func test_verifyScannedQR_rejectsTamperedSignature() throws {
        let (service, noise) = makeService()
        let badSignature = Data(repeating: 0xAA, count: 64)
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "tampered-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970),
            signatureOverride: badSignature
        )

        XCTAssertNil(service.verifyScannedQR(qrString))
    }

    func test_verificationQR_rejectsUnsupportedVersionAndDuplicateQueryNames() throws {
        let (service, noise) = makeService()
        let unsupported = try makeSignedQR(
            noise: noise,
            version: 2,
            nickname: "v2-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970)
        )

        XCTAssertNil(service.verifyScannedQR(unsupported))
        XCTAssertNil(
            VerificationService.VerificationQR.fromURL(
                try XCTUnwrap(URL(string: unsupported))
            )
        )

        let valid = try makeSignedQR(
            noise: noise,
            nickname: "duplicate-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970)
        )
        var components = try XCTUnwrap(
            URLComponents(string: valid)
        )
        components.queryItems?.append(URLQueryItem(name: "nick", value: "mallory"))
        let duplicate = try XCTUnwrap(components.string)

        XCTAssertNil(service.verifyScannedQR(duplicate))
        XCTAssertNil(
            VerificationService.VerificationQR.fromURL(
                try XCTUnwrap(URL(string: duplicate))
            )
        )
    }

    func test_verificationQR_rejectsNoncanonicalNumericRepresentations() throws {
        let (service, noise) = makeService()
        let valid = try makeSignedQR(
            noise: noise,
            nickname: "numeric-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970)
        )
        var components = try XCTUnwrap(URLComponents(string: valid))

        components.queryItems = components.queryItems?.map { item in
            guard item.name == "ts", let value = item.value else { return item }
            return URLQueryItem(name: item.name, value: "0" + value)
        }
        let leadingZeroTimestamp = try XCTUnwrap(components.string)
        XCTAssertNil(service.verifyScannedQR(leadingZeroTimestamp))

        components = try XCTUnwrap(URLComponents(string: valid))
        components.queryItems = components.queryItems?.map { item in
            item.name == "v" ? URLQueryItem(name: item.name, value: "01") : item
        }
        let leadingZeroVersion = try XCTUnwrap(components.string)
        XCTAssertNil(service.verifyScannedQR(leadingZeroVersion))
    }

    func test_verifyScannedQR_rejectsMalformedExactLengthFields() throws {
        let (service, noise) = makeService()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nickname = "malformed-\(UUID().uuidString)"

        let shortNoiseKey = try makeSignedQR(
            noise: noise,
            noiseKeyHex: String(repeating: "a", count: 62),
            nickname: nickname,
            npub: nil,
            ts: timestamp
        )
        let nonHexNoiseKey = try makeSignedQR(
            noise: noise,
            noiseKeyHex: String(repeating: "z", count: 64),
            nickname: nickname,
            npub: nil,
            ts: timestamp
        )
        let shortSigningKey = try makeSignedQR(
            noise: noise,
            signKeyHex: String(repeating: "b", count: 62),
            nickname: nickname,
            npub: nil,
            ts: timestamp
        )
        let shortSignature = try makeSignedQR(
            noise: noise,
            nickname: nickname,
            npub: nil,
            ts: timestamp,
            signatureOverride: Data(repeating: 0x01, count: 63)
        )

        XCTAssertNil(service.verifyScannedQR(shortNoiseKey))
        XCTAssertNil(service.verifyScannedQR(nonHexNoiseKey))
        XCTAssertNil(service.verifyScannedQR(shortSigningKey))
        XCTAssertNil(service.verifyScannedQR(shortSignature))
    }

    func test_verifyScannedQR_rejectsMalformedOrWrongLengthNonce() throws {
        let (service, noise) = makeService()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let malformed = try makeSignedQR(
            noise: noise,
            nickname: "bad-nonce-\(UUID().uuidString)",
            npub: nil,
            ts: timestamp,
            nonceB64: "not base64!"
        )
        let wrongLength = try makeSignedQR(
            noise: noise,
            nickname: "short-nonce-\(UUID().uuidString)",
            npub: nil,
            ts: timestamp,
            nonceB64: Data(repeating: 0x01, count: 15).base64EncodedString()
        )

        XCTAssertNil(service.verifyScannedQR(malformed))
        XCTAssertNil(service.verifyScannedQR(wrongLength))
    }

    func test_verifyScannedQR_rejectsInvalidNickname() throws {
        let (service, noise) = makeService()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let invalidNicknames = [
            "",
            " alice ",
            "alice\u{0007}",
            String(repeating: "a", count: 256),
            String(repeating: "🇨🇳", count: 32)
        ]

        for nickname in invalidNicknames {
            let qrString = try makeSignedQR(
                noise: noise,
                nickname: nickname,
                npub: nil,
                ts: timestamp
            )
            XCTAssertNil(service.verifyScannedQR(qrString), "Accepted invalid nickname: \(nickname.debugDescription)")
        }

        let compatibleLongNickname = String(
            repeating: "a",
            count: InputValidator.Limits.maxNicknameLength + 1
        )
        let compatibleQR = try makeSignedQR(
            noise: noise,
            nickname: compatibleLongNickname,
            npub: nil,
            ts: timestamp
        )
        XCTAssertEqual(
            service.verifyScannedQR(compatibleQR)?.nickname,
            compatibleLongNickname
        )
    }

    func test_verifyScannedQR_acceptsOriginalBitchatOpaqueNpubWithoutRoutingIt() throws {
        let (service, noise) = makeService()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let originalOpaqueNpub = "npub1testvalue"
        XCTAssertNil(
            service.buildMyQRString(
                nickname: "local-emission-\(UUID().uuidString)",
                npub: originalOpaqueNpub
            )
        )
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "opaque-npub-\(UUID().uuidString)",
            npub: originalOpaqueNpub,
            ts: timestamp
        )

        let parsed = try XCTUnwrap(service.verifyScannedQR(qrString))
        XCTAssertEqual(parsed.npub, originalOpaqueNpub)
        XCTAssertNil(parsed.routableNpub)
    }

    func test_verifyScannedQR_acceptsEmptyOpaqueNpubButRejectsOversizedValue() throws {
        let (service, noise) = makeService()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let empty = try makeSignedQR(
            noise: noise,
            nickname: "empty-npub-\(UUID().uuidString)",
            npub: "",
            ts: timestamp
        )
        let parsed = try XCTUnwrap(service.verifyScannedQR(empty))
        XCTAssertEqual(parsed.npub, "")
        XCTAssertNil(parsed.routableNpub)

        let oversized = try makeSignedQR(
            noise: noise,
            nickname: "oversized-npub-\(UUID().uuidString)",
            npub: String(repeating: "n", count: 256),
            ts: timestamp
        )
        XCTAssertNil(service.verifyScannedQR(oversized))
    }

    func test_buildVerifyChallenge_roundTripsThroughNoisePayload() throws {
        let (service, _) = makeService()
        let noiseKeyHex = String(repeating: "ab", count: 32)
        let nonce = Data([0x01, 0x02, 0x03, 0x04])

        let encoded = service.buildVerifyChallenge(noiseKeyHex: noiseKeyHex, nonceA: nonce)
        let payload = try XCTUnwrap(NoisePayload.decode(encoded))
        let parsed = try XCTUnwrap(service.parseVerifyChallenge(payload.data))

        XCTAssertEqual(payload.type, .verifyChallenge)
        XCTAssertEqual(parsed.noiseKeyHex, noiseKeyHex)
        XCTAssertEqual(parsed.nonceA, nonce)
    }

    func test_buildVerifyResponse_roundTripsAndVerifiesSignature() throws {
        let (service, noise) = makeService()
        let noiseKeyHex = String(repeating: "cd", count: 32)
        let nonce = Data([0x10, 0x20, 0x30, 0x40, 0x50])

        let encoded = try XCTUnwrap(service.buildVerifyResponse(noiseKeyHex: noiseKeyHex, nonceA: nonce))
        let payload = try XCTUnwrap(NoisePayload.decode(encoded))
        let parsed = try XCTUnwrap(service.parseVerifyResponse(payload.data))

        XCTAssertEqual(payload.type, .verifyResponse)
        XCTAssertEqual(parsed.noiseKeyHex, noiseKeyHex)
        XCTAssertEqual(parsed.nonceA, nonce)
        XCTAssertTrue(
            service.verifyResponseSignature(
                noiseKeyHex: parsed.noiseKeyHex,
                nonceA: parsed.nonceA,
                signature: parsed.signature,
                signerPublicKeyHex: noise.getSigningPublicKeyData().hexEncodedString()
            )
        )
        XCTAssertFalse(
            service.verifyResponseSignature(
                noiseKeyHex: parsed.noiseKeyHex,
                nonceA: Data([0xFF]),
                signature: parsed.signature,
                signerPublicKeyHex: noise.getSigningPublicKeyData().hexEncodedString()
            )
        )
    }

    private func makeService() -> (VerificationService, NoiseEncryptionService) {
        // The service consumes Noise identity operations through the
        // Transport's narrow noise* wrappers; the mock transport's backing
        // encryption service is returned for direct assertions.
        let transport = MockTransport()
        let service = VerificationService()
        service.configure(with: transport)
        return (service, transport.mockNoiseService)
    }

    private func makeSignedQR(
        noise: NoiseEncryptionService,
        version: Int = 1,
        noiseKeyHex: String? = nil,
        signKeyHex: String? = nil,
        nickname: String,
        npub: String?,
        ts: Int64,
        nonceB64: String = Data((0..<16).map(UInt8.init)).base64EncodedString(),
        signatureOverride: Data? = nil
    ) throws -> String {
        var payload = VerificationService.VerificationQR(
            v: version,
            noiseKeyHex: noiseKeyHex ?? noise.getStaticPublicKeyData().hexEncodedString(),
            signKeyHex: signKeyHex ?? noise.getSigningPublicKeyData().hexEncodedString(),
            npub: npub,
            nickname: nickname,
            ts: ts,
            nonceB64: nonceB64,
            sigHex: ""
        )
        let signature = try XCTUnwrap(signatureOverride ?? noise.signData(payload.canonicalBytes()))
        payload.sigHex = signature.hexEncodedString()
        return payload.toURLString()
    }

    private func makeValidNpub() throws -> String {
        try Bech32.encode(hrp: "npub", data: Data((0..<32).map(UInt8.init)))
    }
}
