import BitFoundation
import BitLogger
import Foundation
import Security

enum FriendVerificationFailure: Equatable {
    case invalidPayload
    case invalidLocalPetname
    case selfIdentity
    case blocked
    case signingKeyMismatch
    case peerNotFound
    case peerUnavailable
    case activeSessionMismatch
    case invalidResponse
    case persistenceRejected
    case timedOut
}

enum FriendVerificationStartResult: Equatable {
    case started(peerID: PeerID, claimedNickname: String)
    case alreadyPending(peerID: PeerID, claimedNickname: String)
    case failed(FriendVerificationFailure)
}

enum FriendVerificationCompletion: Equatable {
    case verified(
        peerID: PeerID,
        displayName: String
    )
    case failed(peerID: PeerID?, reason: FriendVerificationFailure)
}

/// The narrow surface `ChatVerificationCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatVerificationCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatVerificationContext: AnyObject {
    // MARK: Fingerprints & verification state
    func getFingerprint(for peerID: PeerID) -> String?
    /// The UI-facing verified-fingerprint set (peer identity store backed).
    var verifiedFingerprints: Set<String> { get set }
    /// The persisted verified-fingerprint set from the identity manager.
    func persistedVerifiedFingerprints() -> Set<String>
    /// Persists the verified flag in the identity manager.
    func setIdentityVerified(fingerprint: String, verified: Bool)
    /// Updates the UI-facing verified flag in the peer identity store.
    func setStoredVerified(_ fingerprint: String, verified: Bool)
    func isVerifiedFingerprint(_ fingerprint: String) -> Bool
    func isBlockedFingerprint(_ fingerprint: String) -> Bool
    /// Ed25519 key previously bound to this full fingerprint inside Noise.
    func authenticatedSigningPublicKey(for fingerprint: String) -> Data?
    func recordIdentityConflict(
        forFingerprint fingerprint: String,
        reason: PeerIdentityConflictReason
    )
    func saveIdentityState()
    /// After a fingerprint becomes verified, run a transitive-vouch pass over
    /// currently connected peers (so verifying a peer you're already connected
    /// to sends vouches immediately, and the new identity propagates onward).
    func vouchToConnectedVerifiedPeers()

    // MARK: Encryption status
    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID)
    func updateEncryptionStatus(for peerID: PeerID)
    func invalidateEncryptionCache(for peerID: PeerID?)
    /// Signals that verification state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Peers
    var unifiedPeers: [BitchatPeer] { get }
    var unifiedFavorites: [BitchatPeer] { get }
    /// The peer's current entry in the unified peer service, if known.
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer?
    func unifiedFingerprint(for peerID: PeerID) -> String?
    func resolveNickname(for peerID: PeerID) -> String
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID?
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID)
    /// Persists the authenticated QR identity without changing the friend
    /// relationship. Exact Noise-key and block/self checks are repeated at
    /// this write boundary.
    func persistVerifiedIdentity(
        peerID: PeerID,
        expectedNoisePublicKey: Data,
        signingPublicKey: Data,
        claimedNickname: String
    ) -> String?

    // MARK: Noise sessions & verification transport
    /// Installs the Noise service's session callbacks (single registration point).
    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    )
    /// Resolves the peer's Noise static key from the active Noise session, if any.
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data?
    /// Atomically identifies the active verification transport generation and
    /// its complete remote Noise static key.
    func verificationSessionBinding(
        for peerID: PeerID
    ) -> MeshVerificationSessionBinding?
    /// Our own Noise static public key.
    func noiseStaticPublicKeyData() -> Data
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool
    func triggerHandshake(with peerID: PeerID)
    func privateMediaPeerDidAuthenticate(_ peerID: PeerID)
    /// Retries only private messages previously transmitted through a secure
    /// session and still pending an ack. Both ephemeral and stable aliases
    /// are supplied because either can own the outbox entry.
    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID])
    func sendVerifyChallenge(
        to peerID: PeerID,
        noiseKeyHex: String,
        nonceA: Data,
        sessionGeneration: UUID
    )
    func sendVerifyResponse(
        to peerID: PeerID,
        noiseKeyHex: String,
        nonceA: Data,
        sessionGeneration: UUID
    )

    // MARK: Notifications (shared with `ChatNostrContext`)
    /// Posts a generic local user notification.
    func postLocalNotification(title: String, body: String, identifier: String)
}

extension ChatViewModel: ChatVerificationContext {
    // `getFingerprint(for:)`, `verifiedFingerprints`, `saveIdentityState()`,
    // `updateEncryptionStatus(for:)`, `invalidateEncryptionCache(for:)`,
    // `notifyUIChanged()`, `unifiedPeer(for:)`, `unifiedFingerprint(for:)`,
    // `isVerifiedFingerprint(_:)`, `setEncryptionStatus(_:for:)`,
    // `resolveNickname(for:)`, `cachedStablePeerID(for:)`,
    // `cacheStablePeerID(_:for:)`, `noiseSessionPublicKeyData(for:)`,
    // `hasEstablishedNoiseSession(with:)`, and `triggerHandshake(with:)` are
    // shared requirements with the other contexts or satisfied by existing
    // `ChatViewModel` members. The members below flatten nested service
    // accesses into intent-named calls.

    func persistedVerifiedFingerprints() -> Set<String> {
        identityManager.getVerifiedFingerprints()
    }

    func setIdentityVerified(fingerprint: String, verified: Bool) {
        identityManager.setVerified(fingerprint: fingerprint, verified: verified)
    }

    func setStoredVerified(_ fingerprint: String, verified: Bool) {
        peerIdentityStore.setVerified(fingerprint, verified: verified)
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        identityManager.isBlocked(fingerprint: fingerprint)
    }

    func authenticatedSigningPublicKey(for fingerprint: String) -> Data? {
        identityManager.authenticatedSigningPublicKey(forFingerprint: fingerprint)
    }

    func recordIdentityConflict(
        forFingerprint fingerprint: String,
        reason: PeerIdentityConflictReason
    ) {
        peerIdentityStore.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: reason
        )
    }

    func vouchToConnectedVerifiedPeers() {
        vouchCoordinator.vouchToConnectedVerifiedPeers()
    }

    var unifiedPeers: [BitchatPeer] {
        unifiedPeerService.peers
    }

    var unifiedFavorites: [BitchatPeer] {
        unifiedPeerService.favorites
    }

    func persistVerifiedIdentity(
        peerID: PeerID,
        expectedNoisePublicKey: Data,
        signingPublicKey: Data,
        claimedNickname: String
    ) -> String? {
        unifiedPeerService.persistVerifiedIdentity(
            peerID: peerID,
            expectedNoisePublicKey: expectedNoisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: claimedNickname
        )
    }

    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {
        meshService.installNoiseSessionCallbacks(
            onPeerAuthenticated: onPeerAuthenticated,
            onHandshakeRequired: onHandshakeRequired
        )
    }

    func noiseStaticPublicKeyData() -> Data {
        meshService.noiseStaticPublicKeyData()
    }

    func verificationSessionBinding(
        for peerID: PeerID
    ) -> MeshVerificationSessionBinding? {
        verifyTransport?.verificationSessionBinding(for: peerID)
    }

    func privateMediaPeerDidAuthenticate(_ peerID: PeerID) {
        mediaTransferCoordinator.peerDidAuthenticate(peerID.toShort())
    }

    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID]) {
        messageRouter.retrySecurePrivateMessagesAfterAuthentication(for: peerIDAliases)
    }

    /// QR verification rides the mesh's Noise sessions only.
    private var verifyTransport: MeshVerifying? { meshService as? MeshVerifying }

    func sendVerifyChallenge(
        to peerID: PeerID,
        noiseKeyHex: String,
        nonceA: Data,
        sessionGeneration: UUID
    ) {
        verifyTransport?.sendVerifyChallenge(
            to: peerID,
            noiseKeyHex: noiseKeyHex,
            nonceA: nonceA,
            sessionGeneration: sessionGeneration
        )
    }

    func sendVerifyResponse(
        to peerID: PeerID,
        noiseKeyHex: String,
        nonceA: Data,
        sessionGeneration: UUID
    ) {
        verifyTransport?.sendVerifyResponse(
            to: peerID,
            noiseKeyHex: noiseKeyHex,
            nonceA: nonceA,
            sessionGeneration: sessionGeneration
        )
    }

    func postLocalNotification(title: String, body: String, identifier: String) {
        NotificationService.shared.sendSecurityNotification(
            title: title,
            body: body,
            identifier: identifier
        )
    }
}

extension ChatVerificationContext {
    func privateMediaPeerDidAuthenticate(_ peerID: PeerID) {}
}

@MainActor
final class ChatVerificationCoordinator {
    struct PendingVerification {
        let noisePublicKey: Data
        let signingPublicKey: Data
        let claimedNickname: String
        let nonceA: Data
        let deadline: Date
        var sent: Bool
        var sessionGeneration: UUID?
        var completions: [(FriendVerificationCompletion) -> Void]

        var noiseKeyHex: String { noisePublicKey.hexEncodedString() }
        var signKeyHex: String { signingPublicKey.hexEncodedString() }
    }

    private enum NotificationCopy {
        static var successTitle: String {
            String(localized: "notification.verification.success.title", defaultValue: "Verified", comment: "Notification title after the user successfully verifies another person's encryption identity")
        }

        static func successBody(peerName: String) -> String {
            String(
                format: String(localized: "notification.verification.success.body", defaultValue: "You verified %@", comment: "Notification body after successful encryption verification; %@ is the other person's display name"),
                locale: .current,
                peerName
            )
        }

        static var mutualTitle: String {
            String(localized: "notification.verification.mutual.title", defaultValue: "Mutual verification", comment: "Notification title when two people have verified each other's encryption identities")
        }

        static func mutualBody(peerName: String) -> String {
            String(
                format: String(localized: "notification.verification.mutual.body", defaultValue: "You and %@ verified each other", comment: "Notification body when verification is mutual; %@ is the other person's display name"),
                locale: .current,
                peerName
            )
        }
    }

    private unowned let context: any ChatVerificationContext
    private let verificationService: VerificationService
    private let verificationTimeout: TimeInterval
    private let now: () -> Date
    private var pendingQRVerifications: [PeerID: PendingVerification] = [:]
    private var timeoutTasks: [PeerID: Task<Void, Never>] = [:]
    private var lastVerifyNonceByPeer: [PeerID: Data] = [:]
    private var lastInboundVerifyChallengeAt: [String: Date] = [:]
    private var lastMutualToastAt: [String: Date] = [:]

    init(
        context: any ChatVerificationContext,
        verificationService: VerificationService = .shared,
        verificationTimeout: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.verificationService = verificationService
        self.verificationTimeout = max(1, verificationTimeout)
        self.now = now
    }

    func verifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = context.getFingerprint(for: peerID) else { return }

        context.setIdentityVerified(fingerprint: fingerprint, verified: true)
        context.saveIdentityState()
        context.setStoredVerified(fingerprint, verified: true)
        context.updateEncryptionStatus(for: peerID)
        // Verifying a peer is a vouch trigger: push attestations to my other
        // connected verified peers (and to this one if already connected).
        context.vouchToConnectedVerifiedPeers()
    }

    func unverifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = context.getFingerprint(for: peerID) else { return }
        context.setIdentityVerified(fingerprint: fingerprint, verified: false)
        context.saveIdentityState()
        context.setStoredVerified(fingerprint, verified: false)
        context.updateEncryptionStatus(for: peerID)
    }

    func loadVerifiedFingerprints() {
        context.verifiedFingerprints = context.persistedVerifiedFingerprints()
        let sample = Array(context.verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount))
            .map { $0.prefix(8) }
            .joined(separator: ", ")
        SecureLogger.info("🔐 Verified loaded: \(context.verifiedFingerprints.count) [\(sample)]", category: .security)

        let offlineFavorites = context.unifiedFavorites.filter { !$0.isConnected }
        for favorite in offlineFavorites {
            let fingerprint = context.unifiedFingerprint(for: favorite.peerID)
            let isVerified = fingerprint.flatMap { context.isVerifiedFingerprint($0) } ?? false
            let shortFingerprint = fingerprint?.prefix(8) ?? "nil"
            SecureLogger.info(
                "⭐️ Favorite offline: \(favorite.nickname) fp=\(shortFingerprint) verified=\(isVerified)",
                category: .security
            )
        }

        context.invalidateEncryptionCache(for: nil)
        context.notifyUIChanged()
    }

    func setupNoiseCallbacks() {
        context.installNoiseSessionCallbacks(
            onPeerAuthenticated: { [weak self] peerID, fingerprint in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    SecureLogger.debug("🔐 Authenticated: \(peerID)", category: .security)
                    self.context.privateMediaPeerDidAuthenticate(peerID)

                    if self.context.isVerifiedFingerprint(fingerprint) {
                        self.context.setEncryptionStatus(.noiseVerified, for: peerID)
                    } else {
                        self.context.setEncryptionStatus(.noiseSecured, for: peerID)
                    }

                    self.context.invalidateEncryptionCache(for: peerID)

                    var authenticatedStablePeerID: PeerID?
                    if let keyData = self.context.noiseSessionPublicKeyData(for: peerID) {
                        let stablePeerID = PeerID(hexData: keyData)
                        authenticatedStablePeerID = stablePeerID
                        if self.context.cachedStablePeerID(for: peerID) != stablePeerID {
                            // The freshly authenticated Noise key outranks a
                            // stale announce-derived alias.
                            self.context.cacheStablePeerID(stablePeerID, for: peerID)
                        }
                        SecureLogger.debug(
                            "🗺️ Mapped short peerID to Noise key for header continuity: \(peerID) -> \(stablePeerID.id.prefix(8))…",
                            category: .session
                        )
                    }

                    // A locally established session may have belonged to the
                    // peer's previous app process. The first ciphertext sent
                    // into that stale session is retained by MessageRouter;
                    // retry it now that this newly authenticated/replacement
                    // session can actually decrypt it.
                    var peerIDAliases = [peerID]
                    if let stablePeerID = authenticatedStablePeerID
                        ?? self.context.cachedStablePeerID(for: peerID),
                       stablePeerID != peerID {
                        // Conversations can migrate from the ephemeral BLE ID
                        // to the authenticated Noise-key ID. Retry both aliases
                        // because either may own the retained outbox entry.
                        peerIDAliases.append(stablePeerID)
                    }
                    self.context.retrySecurePrivateMessagesAfterAuthentication(for: peerIDAliases)

                    if var pending = self.pendingQRVerifications[peerID], pending.sent == false {
                        guard let binding = self.context.verificationSessionBinding(
                            for: peerID
                        ), binding.remoteStaticPublicKey == pending.noisePublicKey else {
                            self.completePendingVerification(
                                for: peerID,
                                with: .failed(peerID: peerID, reason: .activeSessionMismatch)
                            )
                            return
                        }
                        self.context.sendVerifyChallenge(
                            to: peerID,
                            noiseKeyHex: pending.noiseKeyHex,
                            nonceA: pending.nonceA,
                            sessionGeneration: binding.sessionGeneration
                        )
                        pending.sent = true
                        pending.sessionGeneration = binding.sessionGeneration
                        self.pendingQRVerifications[peerID] = pending
                        SecureLogger.debug("📤 Sent deferred verify challenge to \(peerID) after handshake", category: .security)
                    }
                }
            },
            onHandshakeRequired: { [weak self] peerID in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.context.setEncryptionStatus(.noiseHandshaking, for: peerID)
                    self.context.invalidateEncryptionCache(for: peerID)
                }
            }
        )
    }

    @discardableResult
    func beginFriendVerification(
        with qr: VerificationService.VerificationQR,
        completion: @escaping (FriendVerificationCompletion) -> Void
    ) -> FriendVerificationStartResult {
        expirePendingFriendVerifications()

        // Revalidate the complete signed payload at the action boundary. The
        // confirmation screen can remain open beyond the QR freshness window,
        // and compatibility callers can construct `VerificationQR` directly;
        // neither path may persist unverified nickname or Nostr metadata.
        guard let validatedQR = verificationService.verifyScannedQR(qr.toURLString()),
              let noisePublicKey = Data(hexString: validatedQR.noiseKeyHex),
              noisePublicKey.count == 32,
              let signingPublicKey = Data(hexString: validatedQR.signKeyHex),
              signingPublicKey.count == 32 else {
            return .failed(.invalidPayload)
        }
        let claimedNickname = validatedQR.nickname

        guard noisePublicKey != context.noiseStaticPublicKeyData() else {
            return .failed(.selfIdentity)
        }

        let fingerprint = noisePublicKey.sha256Fingerprint()
        guard !context.isBlockedFingerprint(fingerprint) else {
            return .failed(.blocked)
        }
        guard let peer = context.unifiedPeers.first(where: {
            $0.noisePublicKey == noisePublicKey
        }) else {
            return .failed(.peerNotFound)
        }
        guard peer.isConnected || peer.isReachable else {
            return .failed(.peerUnavailable)
        }

        let peerID = peer.peerID
        if var pending = pendingQRVerifications[peerID] {
            guard pending.noisePublicKey == noisePublicKey,
                  pending.signingPublicKey == signingPublicKey else {
                let noiseKeyChanged = pending.noisePublicKey != noisePublicKey
                return .failed(
                    noiseKeyChanged
                        ? .activeSessionMismatch
                        : .signingKeyMismatch
                )
            }
            pending.completions.append(completion)
            pendingQRVerifications[peerID] = pending
            return .alreadyPending(
                peerID: peerID,
                claimedNickname: pending.claimedNickname
            )
        }

        let activeBinding = context.verificationSessionBinding(for: peerID)
        if let activeBinding,
           activeBinding.remoteStaticPublicKey != noisePublicKey {
            return .failed(.activeSessionMismatch)
        }

        var nonce = Data(count: 16)
        let randomStatus = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            return .failed(.invalidPayload)
        }

        var pending = PendingVerification(
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: claimedNickname,
            nonceA: nonce,
            deadline: now().addingTimeInterval(verificationTimeout),
            sent: false,
            sessionGeneration: nil,
            completions: [completion]
        )
        pendingQRVerifications[peerID] = pending
        scheduleTimeout(for: peerID)

        if let activeBinding {
            context.sendVerifyChallenge(
                to: peerID,
                noiseKeyHex: pending.noiseKeyHex,
                nonceA: nonce,
                sessionGeneration: activeBinding.sessionGeneration
            )
            pending.sent = true
            pending.sessionGeneration = activeBinding.sessionGeneration
            pendingQRVerifications[peerID] = pending
        } else {
            context.triggerHandshake(with: peerID)
        }

        return .started(peerID: peerID, claimedNickname: claimedNickname)
    }

    /// Compatibility surface for older call sites. `true` means the proof was
    /// started (or was already pending), not that verification has completed.
    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        switch beginFriendVerification(with: qr, completion: { _ in }) {
        case .started, .alreadyPending:
            return true
        case .failed:
            return false
        }
    }

    /// Cancels one user-dismissed QR proof without touching any other
    /// in-flight peer. No completion is delivered because the presenting flow
    /// has explicitly discarded its state.
    func cancelFriendVerification(with qr: VerificationService.VerificationQR) {
        guard let noisePublicKey = Data(hexString: qr.noiseKeyHex),
              let peerID = pendingQRVerifications.first(where: {
                  $0.value.noisePublicKey == noisePublicKey
              })?.key else {
            return
        }
        discardPendingVerification(for: peerID)
    }

    /// Panic wipe must synchronously invalidate every pre-wipe nonce, callback,
    /// and timeout before transport identity replacement or service restart.
    func resetForPanic() {
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll(keepingCapacity: false)
        pendingQRVerifications.removeAll(keepingCapacity: false)
        lastVerifyNonceByPeer.removeAll(keepingCapacity: false)
        lastInboundVerifyChallengeAt.removeAll(keepingCapacity: false)
        lastMutualToastAt.removeAll(keepingCapacity: false)
    }

    func handleVerifyChallengePayload(
        from peerID: PeerID,
        payload: Data,
        sessionGeneration: UUID?
    ) {
        guard let sessionGeneration,
              context.verificationSessionBinding(for: peerID)?.sessionGeneration
                == sessionGeneration else {
            return
        }
        guard let challenge = verificationService.parseVerifyChallenge(payload) else { return }

        let myNoiseHex = context.noiseStaticPublicKeyData()
            .hexEncodedString()
            .lowercased()
        guard challenge.noiseKeyHex.lowercased() == myNoiseHex else { return }
        guard lastVerifyNonceByPeer[peerID] != challenge.nonceA else { return }

        lastVerifyNonceByPeer[peerID] = challenge.nonceA

        if let fingerprint = context.getFingerprint(for: peerID) {
            lastInboundVerifyChallengeAt[fingerprint] = Date()

            if context.isVerifiedFingerprint(fingerprint) {
                maybeSendMutualVerificationNotification(
                    fingerprint: fingerprint,
                    peerID: peerID,
                    bodyName: context.unifiedPeer(for: peerID)?.nickname
                        ?? context.resolveNickname(for: peerID),
                    notificationPrefix: "verify-mutual"
                )
            }
        }

        context.sendVerifyResponse(
            to: peerID,
            noiseKeyHex: challenge.noiseKeyHex,
            nonceA: challenge.nonceA,
            sessionGeneration: sessionGeneration
        )
    }

    func handleVerifyResponsePayload(
        from peerID: PeerID,
        payload: Data,
        sessionGeneration: UUID?
    ) {
        guard let pending = pendingQRVerifications[peerID] else { return }
        guard now() <= pending.deadline else {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .timedOut)
            )
            return
        }
        guard let response = verificationService.parseVerifyResponse(payload),
              Data(hexString: response.noiseKeyHex) == pending.noisePublicKey,
              response.nonceA == pending.nonceA else {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .invalidResponse)
            )
            return
        }

        // The challenge and response must use the same local Noise generation.
        // This generation is internal metadata; the Bitchat QR and payload
        // bytes remain unchanged.
        guard let sessionGeneration,
              pending.sessionGeneration == sessionGeneration,
              let binding = context.verificationSessionBinding(for: peerID),
              binding.sessionGeneration == sessionGeneration,
              binding.remoteStaticPublicKey == pending.noisePublicKey else {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .activeSessionMismatch)
            )
            return
        }

        let activeNoisePublicKey = binding.remoteStaticPublicKey
        let fingerprint = activeNoisePublicKey.sha256Fingerprint()
        guard context.getFingerprint(for: peerID).map({
            $0.caseInsensitiveCompare(fingerprint) == .orderedSame
        }) ?? true else {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .activeSessionMismatch)
            )
            return
        }
        guard !context.isBlockedFingerprint(fingerprint) else {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .blocked)
            )
            return
        }
        let isValid = verificationService.verifyResponseSignature(
            noiseKeyHex: response.noiseKeyHex,
            nonceA: response.nonceA,
            signature: response.signature,
            signerPublicKeyHex: pending.signKeyHex
        )
        guard isValid else {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .invalidResponse)
            )
            return
        }

        // The QR signature alone proves only its embedded Ed25519 key. Here,
        // the fresh response also arrived through the exact Noise static-key
        // session and verifies over our nonce, so a conflicting signing key
        // is finally attributable to this complete Noise fingerprint.
        if let pinnedSigningKey = context.authenticatedSigningPublicKey(
            for: fingerprint
        ),
           pinnedSigningKey != pending.signingPublicKey {
            context.recordIdentityConflict(
                forFingerprint: fingerprint,
                reason: .qrIdentityBindingMismatch
            )
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .signingKeyMismatch)
            )
            return
        }

        // Persist the proven key binding before publishing the verification
        // badge. This intentionally leaves the friend relationship unchanged.
        guard let peerName = context.persistVerifiedIdentity(
            peerID: peerID,
            expectedNoisePublicKey: activeNoisePublicKey,
            signingPublicKey: pending.signingPublicKey,
            claimedNickname: pending.claimedNickname
        ) else {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .persistenceRejected)
            )
            return
        }

        let shortFingerprint = fingerprint.prefix(8)
        SecureLogger.info("🔐 Marking verified fingerprint: \(shortFingerprint)", category: .security)
        context.setIdentityVerified(fingerprint: fingerprint, verified: true)
        context.saveIdentityState()
        context.setStoredVerified(fingerprint, verified: true)

        context.postLocalNotification(
            title: NotificationCopy.successTitle,
            body: NotificationCopy.successBody(peerName: peerName),
            identifier: "verify-success-\(peerID)-\(UUID().uuidString)"
        )

        if let challengeTime = lastInboundVerifyChallengeAt[fingerprint],
           Date().timeIntervalSince(challengeTime) < 600 {
            maybeSendMutualVerificationNotification(
                fingerprint: fingerprint,
                peerID: peerID,
                bodyName: peerName,
                notificationPrefix: "verify-mutual"
            )
        }

        context.updateEncryptionStatus(for: peerID)
        // QR verification just completed — same vouch trigger as manual verify.
        context.vouchToConnectedVerifiedPeers()
        completePendingVerification(
            for: peerID,
            with: .verified(
                peerID: peerID,
                displayName: peerName
            )
        )
    }
}

private extension ChatVerificationCoordinator {
    func scheduleTimeout(for peerID: PeerID) {
        timeoutTasks[peerID]?.cancel()
        let nanoseconds = UInt64(verificationTimeout * 1_000_000_000)
        timeoutTasks[peerID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.expirePendingFriendVerifications()
        }
    }

    func completePendingVerification(
        for peerID: PeerID,
        with completion: FriendVerificationCompletion
    ) {
        guard let pending = pendingQRVerifications.removeValue(forKey: peerID) else {
            return
        }
        timeoutTasks.removeValue(forKey: peerID)?.cancel()
        for handler in pending.completions {
            handler(completion)
        }
    }

    func discardPendingVerification(for peerID: PeerID) {
        pendingQRVerifications.removeValue(forKey: peerID)
        timeoutTasks.removeValue(forKey: peerID)?.cancel()
    }

    func maybeSendMutualVerificationNotification(
        fingerprint: String,
        peerID: PeerID,
        bodyName: String,
        notificationPrefix: String
    ) {
        let now = Date()
        let lastToast = lastMutualToastAt[fingerprint] ?? .distantPast
        guard now.timeIntervalSince(lastToast) > 60 else { return }

        lastMutualToastAt[fingerprint] = now
        context.postLocalNotification(
            title: NotificationCopy.mutualTitle,
            body: NotificationCopy.mutualBody(peerName: bodyName),
            identifier: "\(notificationPrefix)-\(peerID)-\(UUID().uuidString)"
        )
    }
}

extension ChatVerificationCoordinator {
    /// Expires pending QR proofs. The explicit `at` argument keeps timeout
    /// behavior deterministic in focused tests and lifecycle callers; the
    /// scheduled task uses the coordinator's injected clock.
    func expirePendingFriendVerifications(at date: Date? = nil) {
        let referenceDate = date ?? now()
        let expiredPeerIDs = pendingQRVerifications.compactMap { peerID, pending in
            pending.deadline <= referenceDate ? peerID : nil
        }
        for peerID in expiredPeerIDs {
            completePendingVerification(
                for: peerID,
                with: .failed(peerID: peerID, reason: .timedOut)
            )
        }
    }
}
