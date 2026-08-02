//
// ChatVerificationCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatVerificationCoordinator` against a mock
// `ChatVerificationContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Challenge handling, QR kickoff, a real Ed25519 response, identity persistence
// ordering, fingerprint verification, verified-set loading, timeout/fail-closed
// paths, and the mutual-verification notification are covered here against an
// injected context and verification service.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatVerificationContext` proving that
/// `ChatVerificationCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatVerificationContext: ChatVerificationContext {
    // Fingerprints & verification state
    var fingerprintsByPeerID: [PeerID: String] = [:]
    var verifiedFingerprints: Set<String> = []
    var persistedFingerprints: Set<String> = []
    private(set) var identityVerifiedCalls: [(fingerprint: String, verified: Bool)] = []
    private(set) var storedVerifiedCalls: [(fingerprint: String, verified: Bool)] = []
    private(set) var saveIdentityStateCount = 0
    var blockedFingerprints: Set<String> = []
    var pinnedSigningKeys: [String: Data] = [:]
    private(set) var eventOrder: [String] = []

    func getFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func persistedVerifiedFingerprints() -> Set<String> { persistedFingerprints }

    func setIdentityVerified(fingerprint: String, verified: Bool) {
        eventOrder.append("verified:\(verified)")
        identityVerifiedCalls.append((fingerprint, verified))
    }

    func setStoredVerified(_ fingerprint: String, verified: Bool) {
        storedVerifiedCalls.append((fingerprint, verified))
    }

    func isVerifiedFingerprint(_ fingerprint: String) -> Bool {
        verifiedFingerprints.contains(fingerprint)
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        blockedFingerprints.contains(fingerprint)
    }

    func pinnedSigningPublicKey(for fingerprint: String) -> Data? {
        pinnedSigningKeys[fingerprint]
    }

    func saveIdentityState() { saveIdentityStateCount += 1 }

    private(set) var vouchToConnectedVerifiedPeersCount = 0
    func vouchToConnectedVerifiedPeers() { vouchToConnectedVerifiedPeersCount += 1 }

    // Encryption status
    private(set) var encryptionStatuses: [PeerID: EncryptionStatus?] = [:]
    private(set) var updatedEncryptionStatusPeers: [PeerID] = []
    private(set) var invalidatedEncryptionCachePeers: [PeerID?] = []
    private(set) var notifyUIChangedCount = 0

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        encryptionStatuses[peerID] = status
    }

    func updateEncryptionStatus(for peerID: PeerID) {
        updatedEncryptionStatusPeers.append(peerID)
    }

    func invalidateEncryptionCache(for peerID: PeerID?) {
        invalidatedEncryptionCachePeers.append(peerID)
    }

    func notifyUIChanged() { notifyUIChangedCount += 1 }

    // Peers
    var unifiedPeers: [BitchatPeer] = []
    var unifiedFavorites: [BitchatPeer] = []
    private(set) var stablePeerIDCache: [PeerID: PeerID] = [:]

    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? {
        unifiedPeers.first { $0.peerID == peerID }
    }

    func unifiedFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func resolveNickname(for peerID: PeerID) -> String { "anon\(peerID.id.prefix(4))" }
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? { stablePeerIDCache[shortPeerID] }

    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID) {
        stablePeerIDCache[shortPeerID] = stablePeerID
    }

    struct PersistedIdentityCall {
        let peerID: PeerID
        let noisePublicKey: Data
        let signingPublicKey: Data
        let claimedNickname: String
    }
    var persistedIdentityDisplayName: String? = "alice"
    private(set) var persistedIdentityCalls: [PersistedIdentityCall] = []

    func persistVerifiedIdentity(
        peerID: PeerID,
        expectedNoisePublicKey: Data,
        signingPublicKey: Data,
        claimedNickname: String
    ) -> String? {
        eventOrder.append("identity")
        persistedIdentityCalls.append(
            PersistedIdentityCall(
                peerID: peerID,
                noisePublicKey: expectedNoisePublicKey,
                signingPublicKey: signingPublicKey,
                claimedNickname: claimedNickname
            )
        )
        return persistedIdentityDisplayName
    }

    // Noise sessions & verification transport
    var myNoiseStaticKey = Data(repeating: 0x42, count: 32)
    var establishedNoiseSessions: Set<PeerID> = []
    var noiseSessionKeysByPeerID: [PeerID: Data] = [:]
    private(set) var installedCallbacks: (onPeerAuthenticated: (PeerID, String) -> Void, onHandshakeRequired: (PeerID) -> Void)?
    private(set) var triggeredHandshakes: [PeerID] = []
    private(set) var privateMediaAuthenticatedPeers: [PeerID] = []
    private(set) var securePrivateMessageRetryAliases: [[PeerID]] = []
    private(set) var sentChallenges: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []
    private(set) var sentResponses: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []

    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {
        installedCallbacks = (onPeerAuthenticated, onHandshakeRequired)
    }

    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? { noiseSessionKeysByPeerID[peerID] }
    func noiseStaticPublicKeyData() -> Data { myNoiseStaticKey }
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool {
        establishedNoiseSessions.contains(peerID)
    }
    func triggerHandshake(with peerID: PeerID) { triggeredHandshakes.append(peerID) }
    func privateMediaPeerDidAuthenticate(_ peerID: PeerID) {
        privateMediaAuthenticatedPeers.append(peerID)
    }

    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID]) {
        securePrivateMessageRetryAliases.append(peerIDAliases)
    }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentChallenges.append((peerID, noiseKeyHex, nonceA))
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentResponses.append((peerID, noiseKeyHex, nonceA))
    }

    // Notifications
    private(set) var postedLocalNotifications: [(title: String, body: String, identifier: String)] = []

    func postLocalNotification(title: String, body: String, identifier: String) {
        postedLocalNotifications.append((title, body, identifier))
    }
}

// MARK: - Helpers

/// Builds the raw verify-challenge TLV as it arrives at the coordinator
/// (i.e. with the `NoisePayload` type byte already stripped).
private func makeVerifyChallengeTLV(noiseKeyHex: String, nonceA: Data) -> Data {
    var tlv = Data()
    tlv.append(0x01)
    tlv.append(UInt8(noiseKeyHex.count))
    tlv.append(Data(noiseKeyHex.utf8))
    tlv.append(0x02)
    tlv.append(UInt8(nonceA.count))
    tlv.append(nonceA)
    return tlv
}

private struct SignedVerificationFixture {
    let transport: MockTransport
    let service: VerificationService
    let qr: VerificationService.VerificationQR

    var noisePublicKey: Data { transport.noiseStaticPublicKeyData() }
    var signingPublicKey: Data { transport.noiseSigningPublicKeyData() }
}

private func makeSignedVerificationFixture(
    npub: String? = nil,
    nickname: String = "alice"
) throws -> SignedVerificationFixture {
    let transport = MockTransport()
    let service = VerificationService()
    service.configure(with: transport)
    let url = try #require(
        service.buildMyQRString(nickname: nickname, npub: npub)
    )
    let qr = try #require(service.verifyScannedQR(url))
    return SignedVerificationFixture(
        transport: transport,
        service: service,
        qr: qr
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatVerificationCoordinator` against
/// `MockChatVerificationContext` with no `ChatViewModel`.
struct ChatVerificationCoordinatorContextTests {

    @Test @MainActor
    func verifyAndUnverifyFingerprint_updateBothStoresAndStatus() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")

        // Unknown fingerprint: nothing happens.
        coordinator.verifyFingerprint(for: peerID)
        #expect(context.identityVerifiedCalls.isEmpty)

        context.fingerprintsByPeerID[peerID] = "fp"
        coordinator.verifyFingerprint(for: peerID)
        coordinator.unverifyFingerprint(for: peerID)

        #expect(context.identityVerifiedCalls.map(\.fingerprint) == ["fp", "fp"])
        #expect(context.identityVerifiedCalls.map(\.verified) == [true, false])
        #expect(context.storedVerifiedCalls.map(\.verified) == [true, false])
        #expect(context.saveIdentityStateCount == 2)
        #expect(context.updatedEncryptionStatusPeers == [peerID, peerID])
    }

    @Test @MainActor
    func beginQRVerification_sendsChallengeOrTriggersHandshake() async throws {
        let fixture = try makeSignedVerificationFixture()
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(
            context: context,
            verificationService: fixture.service
        )
        let noiseKey = fixture.noisePublicKey
        let peerID = PeerID(str: "1122334455667788")
        let qr = fixture.qr

        // No matching peer -> not started.
        #expect(!coordinator.beginQRVerification(with: qr))

        // Matching peer without an established session -> handshake first.
        context.unifiedPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: noiseKey,
                nickname: "alice",
                isConnected: true
            )
        ]
        #expect(coordinator.beginQRVerification(with: qr))
        #expect(context.triggeredHandshakes == [peerID])
        #expect(context.sentChallenges.isEmpty)

        // Already pending -> short-circuits without re-triggering.
        #expect(coordinator.beginQRVerification(with: qr))
        #expect(context.triggeredHandshakes == [peerID])

        // Fresh coordinator with an established session -> immediate challenge.
        let context2 = MockChatVerificationContext()
        context2.unifiedPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: noiseKey,
                nickname: "alice",
                isConnected: true
            )
        ]
        context2.establishedNoiseSessions = [peerID]
        context2.noiseSessionKeysByPeerID[peerID] = noiseKey
        let coordinator2 = ChatVerificationCoordinator(
            context: context2,
            verificationService: fixture.service
        )
        #expect(coordinator2.beginQRVerification(with: qr))
        #expect(context2.sentChallenges.count == 1)
        #expect(context2.sentChallenges.first?.noiseKeyHex == qr.noiseKeyHex)
        #expect(context2.triggeredHandshakes.isEmpty)
    }

    @Test @MainActor
    func handleVerifyChallengePayload_respondsOncePerNonceForOurKeyOnly() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let myHex = context.myNoiseStaticKey.hexEncodedString()
        let nonce = Data(repeating: 0x07, count: 16)
        let payload = makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: nonce)

        coordinator.handleVerifyChallengePayload(from: peerID, payload: payload)
        #expect(context.sentResponses.count == 1)
        #expect(context.sentResponses.first?.noiseKeyHex.lowercased() == myHex)
        #expect(context.sentResponses.first?.nonceA == nonce)

        // Same nonce again: deduplicated, no second response.
        coordinator.handleVerifyChallengePayload(from: peerID, payload: payload)
        #expect(context.sentResponses.count == 1)

        // A challenge for someone else's key is ignored.
        let otherHex = Data(repeating: 0x99, count: 32).hexEncodedString()
        let otherPayload = makeVerifyChallengeTLV(
            noiseKeyHex: otherHex,
            nonceA: Data(repeating: 0x08, count: 16)
        )
        coordinator.handleVerifyChallengePayload(from: peerID, payload: otherPayload)
        #expect(context.sentResponses.count == 1)
    }

    @Test @MainActor
    func loadVerifiedFingerprints_syncsPersistedSetAndRefreshesUI() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        context.persistedFingerprints = ["fp1", "fp2"]

        coordinator.loadVerifiedFingerprints()

        #expect(context.verifiedFingerprints == ["fp1", "fp2"])
        #expect(context.invalidatedEncryptionCachePeers == [nil])
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func installedNoiseCallbacks_publishStatusAndStableIDs() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0x33, count: 32)
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        context.cacheStablePeerID(
            PeerID(hexData: Data(repeating: 0x44, count: 32)),
            for: peerID
        )
        context.verifiedFingerprints = ["fp-verified"]

        coordinator.setupNoiseCallbacks()
        let callbacks = context.installedCallbacks

        // Authenticated with a verified fingerprint -> verified status and a
        // cached stable peer ID derived from the session key.
        callbacks?.onPeerAuthenticated(peerID, "fp-verified")
        await waitForMainQueue()
        #expect(context.encryptionStatuses[peerID] == .noiseVerified)
        let stablePeerID = PeerID(hexData: noiseKey)
        #expect(context.stablePeerIDCache[peerID] == stablePeerID)
        #expect(context.invalidatedEncryptionCachePeers.contains(peerID))
        #expect(context.privateMediaAuthenticatedPeers == [peerID])
        #expect(context.securePrivateMessageRetryAliases == [[peerID, stablePeerID]])

        // Handshake required -> handshaking status.
        callbacks?.onHandshakeRequired(peerID)
        await waitForMainQueue()
        #expect(context.encryptionStatuses[peerID] == .noiseHandshaking)
    }

    @Test @MainActor
    func handleVerifyChallengePayload_postsMutualVerificationToastOncePerMinute() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let myHex = context.myNoiseStaticKey.hexEncodedString()
        context.fingerprintsByPeerID[peerID] = "fp-mutual"
        context.verifiedFingerprints = ["fp-mutual"]

        coordinator.handleVerifyChallengePayload(
            from: peerID,
            payload: makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: Data(repeating: 0x07, count: 16))
        )

        // Already-verified peer challenging us: mutual-verification toast.
        #expect(context.postedLocalNotifications.count == 1)
        #expect(context.postedLocalNotifications.first?.title == "Mutual verification")
        #expect(context.postedLocalNotifications.first?.body.hasSuffix("verified each other") == true)
        #expect(context.postedLocalNotifications.first?.identifier.hasPrefix("verify-mutual-") == true)

        // A fresh nonce inside the per-fingerprint toast cooldown stays silent.
        coordinator.handleVerifyChallengePayload(
            from: peerID,
            payload: makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: Data(repeating: 0x08, count: 16))
        )
        #expect(context.postedLocalNotifications.count == 1)
        #expect(context.sentResponses.count == 2)
    }

    @Test @MainActor
    func validResponse_persistsIdentityWithoutAddingFriendAndCompletesOnce() throws {
        let canonicalNpub = try Bech32.encode(
            hrp: "npub",
            data: Data((0..<32).map(UInt8.init))
        )
        let fixture = try makeSignedVerificationFixture(
            npub: canonicalNpub,
            nickname: "Alice"
        )
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(
            context: context,
            verificationService: fixture.service
        )
        let noiseKey = fixture.noisePublicKey
        let signingKey = fixture.signingPublicKey
        let peerID = PeerID(publicKey: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()
        let qr = fixture.qr
        context.unifiedPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: noiseKey,
                nickname: "Alice",
                isConnected: true
            )
        ]
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        context.fingerprintsByPeerID[peerID] = fingerprint
        context.persistedIdentityDisplayName = "Bestie"

        var completions: [FriendVerificationCompletion] = []
        let start = coordinator.beginFriendVerification(
            with: qr
        ) { completions.append($0) }
        #expect(start == .started(peerID: peerID, claimedNickname: "Alice"))
        let challenge = try #require(context.sentChallenges.first)

        // Repeating the same scan joins the in-flight proof rather than
        // toggling or sending a second challenge.
        var duplicateCompletions: [FriendVerificationCompletion] = []
        let duplicate = coordinator.beginFriendVerification(
            with: qr
        ) { duplicateCompletions.append($0) }
        #expect(duplicate == .alreadyPending(peerID: peerID, claimedNickname: "Alice"))
        #expect(context.sentChallenges.count == 1)

        let encodedResponse = try #require(
            fixture.service.buildVerifyResponse(
                noiseKeyHex: noiseKey.hexEncodedString(),
                nonceA: challenge.nonceA
            )
        )
        let response = try #require(NoisePayload.decode(encodedResponse))
        coordinator.handleVerifyResponsePayload(
            from: peerID,
            payload: response.data
        )

        #expect(context.persistedIdentityCalls.count == 1)
        #expect(context.persistedIdentityCalls.first?.noisePublicKey == noiseKey)
        #expect(context.persistedIdentityCalls.first?.signingPublicKey == signingKey)
        #expect(context.persistedIdentityCalls.first?.claimedNickname == "Alice")
        #expect(context.eventOrder.prefix(2) == ["identity", "verified:true"])
        #expect(context.identityVerifiedCalls.map(\.fingerprint) == [fingerprint])
        #expect(context.identityVerifiedCalls.map(\.verified) == [true])
        let expected = FriendVerificationCompletion.verified(
            peerID: peerID,
            displayName: "Bestie"
        )
        #expect(completions == [expected])
        #expect(duplicateCompletions == [expected])

        // A replay after completion has no pending proof and cannot persist a
        // second identity write.
        coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)
        #expect(context.persistedIdentityCalls.count == 1)
    }

    @Test @MainActor
    func beginFriendVerification_rejectsSelfBlockedAndPinnedKeyMismatch() throws {
        let fixture = try makeSignedVerificationFixture()
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(
            context: context,
            verificationService: fixture.service
        )
        let noiseKey = fixture.noisePublicKey
        let signingKey = fixture.signingPublicKey
        let qr = fixture.qr

        context.myNoiseStaticKey = noiseKey
        #expect(
            coordinator.beginFriendVerification(
                with: qr,
                completion: { _ in }
            ) == .failed(.selfIdentity)
        )

        context.myNoiseStaticKey = Data(repeating: 0x42, count: 32)
        context.blockedFingerprints = [noiseKey.sha256Fingerprint()]
        #expect(
            coordinator.beginFriendVerification(
                with: qr,
                completion: { _ in }
            ) == .failed(.blocked)
        )

        context.blockedFingerprints.removeAll()
        context.pinnedSigningKeys[noiseKey.sha256Fingerprint()] = Data(
            repeating: 0x88,
            count: 32
        )
        #expect(
            coordinator.beginFriendVerification(
                with: qr,
                completion: { _ in }
            ) == .failed(.signingKeyMismatch)
        )
        #expect(signingKey != context.pinnedSigningKeys[noiseKey.sha256Fingerprint()])
        #expect(context.triggeredHandshakes.isEmpty)
        #expect(context.persistedIdentityCalls.isEmpty)
    }

    @Test @MainActor
    func timeoutAndActiveSessionMismatch_neverPersistIdentityOrVerification() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let fixture = try makeSignedVerificationFixture()
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(
            context: context,
            verificationService: fixture.service,
            verificationTimeout: 10,
            now: { clock }
        )
        let noiseKey = fixture.noisePublicKey
        let peerID = PeerID(publicKey: noiseKey)
        let qr = fixture.qr
        context.unifiedPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: noiseKey,
                nickname: "alice",
                isConnected: true
            )
        ]

        var timeoutCompletions: [FriendVerificationCompletion] = []
        _ = coordinator.beginFriendVerification(with: qr) {
            timeoutCompletions.append($0)
        }
        clock.addTimeInterval(11)
        coordinator.expirePendingFriendVerifications(at: clock)
        #expect(timeoutCompletions == [.failed(peerID: peerID, reason: .timedOut)])
        #expect(context.persistedIdentityCalls.isEmpty)
        #expect(context.identityVerifiedCalls.isEmpty)

        // A fresh proof whose peer-ID now owns a different authenticated
        // Noise key must fail closed even if the response signature is valid.
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        var mismatchCompletions: [FriendVerificationCompletion] = []
        _ = coordinator.beginFriendVerification(with: qr) {
            mismatchCompletions.append($0)
        }
        let challenge = try #require(context.sentChallenges.last)
        context.noiseSessionKeysByPeerID[peerID] = Data(repeating: 0x99, count: 32)
        let encodedResponse = try #require(
            fixture.service.buildVerifyResponse(
                noiseKeyHex: noiseKey.hexEncodedString(),
                nonceA: challenge.nonceA
            )
        )
        let response = try #require(NoisePayload.decode(encodedResponse))
        coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)
        #expect(
            mismatchCompletions == [
                .failed(peerID: peerID, reason: .activeSessionMismatch)
            ]
        )
        #expect(context.persistedIdentityCalls.isEmpty)
        #expect(context.identityVerifiedCalls.isEmpty)
    }

    @Test @MainActor
    func cancelFriendVerification_discardsDeferredAndSentProofs() async throws {
        let fixture = try makeSignedVerificationFixture(nickname: "Alice")
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(
            context: context,
            verificationService: fixture.service
        )
        let noiseKey = fixture.noisePublicKey
        let peerID = PeerID(publicKey: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()
        context.unifiedPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: noiseKey,
                nickname: "Alice",
                isConnected: true
            )
        ]
        coordinator.setupNoiseCallbacks()

        var completions: [FriendVerificationCompletion] = []
        let deferredStart = coordinator.beginFriendVerification(
            with: fixture.qr
        ) { completions.append($0) }
        #expect(deferredStart == .started(peerID: peerID, claimedNickname: "Alice"))
        #expect(context.triggeredHandshakes == [peerID])

        coordinator.cancelFriendVerification(with: fixture.qr)
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        context.installedCallbacks?.onPeerAuthenticated(peerID, fingerprint)
        await waitForMainQueue()
        #expect(context.sentChallenges.isEmpty)

        let sentStart = coordinator.beginFriendVerification(
            with: fixture.qr
        ) { completions.append($0) }
        #expect(sentStart == .started(peerID: peerID, claimedNickname: "Alice"))
        let challenge = try #require(context.sentChallenges.first)

        coordinator.cancelFriendVerification(with: fixture.qr)
        let encodedResponse = try #require(
            fixture.service.buildVerifyResponse(
                noiseKeyHex: noiseKey.hexEncodedString(),
                nonceA: challenge.nonceA
            )
        )
        let response = try #require(NoisePayload.decode(encodedResponse))
        coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)

        #expect(context.sentChallenges.count == 1)
        #expect(context.persistedIdentityCalls.isEmpty)
        #expect(context.identityVerifiedCalls.isEmpty)
        #expect(context.storedVerifiedCalls.isEmpty)
        #expect(context.saveIdentityStateCount == 0)
        #expect(completions.isEmpty)
    }

    @Test @MainActor
    func resetForPanic_discardsDeferredAndSentProofs() async throws {
        let fixture = try makeSignedVerificationFixture(nickname: "Alice")
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(
            context: context,
            verificationService: fixture.service
        )
        let noiseKey = fixture.noisePublicKey
        let peerID = PeerID(publicKey: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()
        context.unifiedPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: noiseKey,
                nickname: "Alice",
                isConnected: true
            )
        ]
        coordinator.setupNoiseCallbacks()

        var completions: [FriendVerificationCompletion] = []
        let deferredStart = coordinator.beginFriendVerification(
            with: fixture.qr
        ) { completions.append($0) }
        #expect(deferredStart == .started(peerID: peerID, claimedNickname: "Alice"))
        #expect(context.triggeredHandshakes == [peerID])

        coordinator.resetForPanic()
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        context.installedCallbacks?.onPeerAuthenticated(peerID, fingerprint)
        await waitForMainQueue()
        #expect(context.sentChallenges.isEmpty)

        let sentStart = coordinator.beginFriendVerification(
            with: fixture.qr
        ) { completions.append($0) }
        #expect(sentStart == .started(peerID: peerID, claimedNickname: "Alice"))
        let challenge = try #require(context.sentChallenges.first)

        coordinator.resetForPanic()
        let encodedResponse = try #require(
            fixture.service.buildVerifyResponse(
                noiseKeyHex: noiseKey.hexEncodedString(),
                nonceA: challenge.nonceA
            )
        )
        let response = try #require(NoisePayload.decode(encodedResponse))
        coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)

        #expect(context.sentChallenges.count == 1)
        #expect(context.persistedIdentityCalls.isEmpty)
        #expect(context.identityVerifiedCalls.isEmpty)
        #expect(context.storedVerifiedCalls.isEmpty)
        #expect(context.saveIdentityStateCount == 0)
        #expect(completions.isEmpty)
    }
}

/// The installed callbacks hop through `DispatchQueue.main.async`; tests must
/// let that queue drain before asserting.
@MainActor
private func waitForMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
