import BitFoundation
import Combine
import Foundation

struct FingerprintPresentationState: Equatable {
    let peerNickname: String
    let encryptionStatus: EncryptionStatus
    let theirFingerprint: String?
    let myFingerprint: String
    let isVerified: Bool
    /// User-assigned local alias (petname), if any — distinct from the
    /// peer-claimed nickname.
    let localPetname: String?
    /// Number of currently-valid vouches from peers the user verified
    /// (0 when the peer is explicitly verified — the stronger badge wins).
    let voucherCount: Int
    /// Display names of the (verified) vouchers, where known.
    let voucherNames: [String]

    /// Vouched for by ≥1 peer the user verified (and not explicitly verified).
    var isVouched: Bool { voucherCount > 0 }

    var canToggleVerification: Bool {
        encryptionStatus == .noiseSecured || encryptionStatus == .noiseVerified
    }

    /// Alias field is editable once we know who we're looking at.
    var canEditLocalAlias: Bool {
        theirFingerprint != nil
    }
}

struct FriendVerificationCandidate: Identifiable, Equatable {
    let qr: VerificationService.VerificationQR
    let fingerprint: String
    let existingLocalPetname: String?

    /// A scan instance, not merely an identity. This prevents a completion
    /// from an older QR replacing the state of a newer QR for the same peer.
    var id: String { "\(fingerprint):\(qr.nonceB64):\(qr.sigHex)" }
    var claimedNickname: String { qr.nickname }
}

enum FriendVerificationState: Equatable {
    case idle
    case ready
    case verifying
    case verified(peerID: PeerID, displayName: String)
    case failed(FriendVerificationFailure)
}

enum VerificationScanOutcome: Equatable {
    case candidate(FriendVerificationCandidate)
    case rejected(FriendVerificationFailure)
}

@MainActor
final class VerificationModel: ObservableObject {
    @Published private(set) var currentNickname: String
    @Published private(set) var selectedPeerID: PeerID?
    @Published private(set) var friendCandidate: FriendVerificationCandidate?
    @Published private(set) var friendVerificationState: FriendVerificationState = .idle

    private let chatViewModel: ChatViewModel
    private let peerIdentityStore: PeerIdentityStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        privateConversationModel: PrivateConversationModel,
        peerIdentityStore: PeerIdentityStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        self.currentNickname = chatViewModel.nickname
        self.selectedPeerID = privateConversationModel.selectedPeerID

        bind(privateConversationModel: privateConversationModel)
    }

    func myQRString() -> String {
        let npub = try? chatViewModel.idBridge.getCurrentNostrIdentity()?.npub
        return VerificationService.shared.buildMyQRString(nickname: currentNickname, npub: npub) ?? ""
    }

    func verifyScannedPayload(_ payload: String) -> VerificationScanOutcome {
        guard let qr = VerificationService.shared.verifyScannedQR(payload) else {
            friendCandidate = nil
            friendVerificationState = .failed(.invalidPayload)
            return .rejected(.invalidPayload)
        }

        guard let noisePublicKey = Data(hexString: qr.noiseKeyHex),
              let signingPublicKey = Data(hexString: qr.signKeyHex) else {
            friendCandidate = nil
            friendVerificationState = .failed(.invalidPayload)
            return .rejected(.invalidPayload)
        }

        if noisePublicKey == chatViewModel.meshService.noiseStaticPublicKeyData() {
            friendCandidate = nil
            friendVerificationState = .failed(.selfIdentity)
            return .rejected(.selfIdentity)
        }

        let fingerprint = noisePublicKey.sha256Fingerprint()
        if chatViewModel.identityManager.isBlocked(fingerprint: fingerprint) {
            friendCandidate = nil
            friendVerificationState = .failed(.blocked)
            return .rejected(.blocked)
        }

        let pinnedSigningKey = chatViewModel.identityManager
            .authenticatedSigningPublicKey(forFingerprint: fingerprint)
            ?? chatViewModel.identityManager.signingPublicKey(forFingerprint: fingerprint)
        if let pinnedSigningKey,
           pinnedSigningKey != signingPublicKey {
            friendCandidate = nil
            friendVerificationState = .failed(.signingKeyMismatch)
            return .rejected(.signingKeyMismatch)
        }

        let candidate = FriendVerificationCandidate(
            qr: qr,
            fingerprint: fingerprint,
            existingLocalPetname: chatViewModel.identityManager
                .getSocialIdentity(for: fingerprint)?
                .localPetname
        )
        if let previous = friendCandidate, previous.id != candidate.id {
            chatViewModel.cancelFriendVerification(with: previous.qr)
        }
        friendCandidate = candidate
        friendVerificationState = .ready
        return .candidate(candidate)
    }

    @discardableResult
    func startEncryptionVerification() -> FriendVerificationStartResult {
        guard let candidate = friendCandidate else {
            friendVerificationState = .failed(.invalidPayload)
            return .failed(.invalidPayload)
        }

        friendVerificationState = .verifying
        let result = chatViewModel.beginFriendVerification(
            with: candidate.qr
        ) { [weak self] completion in
            guard let self else { return }
            // A proof can finish after the sheet was dismissed or while the
            // user is confirming a different QR. Keep the authorized core
            // operation intact, but never let that stale completion replace
            // the currently visible friend's state.
            guard self.friendCandidate?.id == candidate.id else { return }
            switch completion {
            case .verified(let peerID, let displayName):
                self.friendVerificationState = .verified(
                    peerID: peerID,
                    displayName: displayName
                )
            case .failed(_, let reason):
                self.friendVerificationState = .failed(reason)
            }
        }

        if case .failed(let reason) = result {
            friendVerificationState = .failed(reason)
        }
        return result
    }

    /// Adds the currently scanned identity as a contact without changing its
    /// verification state. The signed QR is revalidated at the action boundary.
    @discardableResult
    func addFriendFromCandidate() -> Bool {
        guard let candidate = friendCandidate,
              let identity = validatedCandidateIdentity(
                candidate,
                requireFreshSignature: true
              ) else { return false }
        guard chatViewModel.addFriend(
            noisePublicKey: identity.noisePublicKey,
            nostrPublicKey: identity.qr.npub,
            claimedNickname: identity.qr.nickname
        ) != nil else {
            return false
        }
        objectWillChange.send()
        return true
    }

    func isFriend(_ candidate: FriendVerificationCandidate) -> Bool {
        guard let noisePublicKey = Data(hexString: candidate.qr.noiseKeyHex) else {
            return false
        }
        return chatViewModel.isFavorite(peerID: PeerID(hexData: noisePublicKey))
    }

    /// Saves a local nickname for a scanned identity independently of friend
    /// and verification state.
    @discardableResult
    func setLocalPetname(
        _ petname: String?,
        for candidate: FriendVerificationCandidate
    ) -> Bool {
        // The QR was signature-checked when the candidate was created. A local
        // nickname does not consume the QR's network identity metadata, so it
        // may still be edited after the QR freshness window expires. We do
        // re-check self/block/pinned-key boundaries before writing.
        guard let identityData = validatedCandidateIdentity(
            candidate,
            requireFreshSignature: false
        ) else { return false }

        let trimmed = petname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if let trimmed, !trimmed.isEmpty {
            guard let validated = InputValidator.validateNickname(trimmed) else { return false }
            normalized = validated
        } else {
            normalized = nil
        }

        var identity: SocialIdentity
        if let existing = chatViewModel.identityManager
            .getSocialIdentity(for: candidate.fingerprint) {
            identity = existing
        } else {
            identity = SocialIdentity(
                fingerprint: candidate.fingerprint,
                localPetname: nil,
                claimedNickname: identityData.qr.nickname,
                trustLevel: .unknown,
                isFavorite: chatViewModel.isFavorite(
                    peerID: PeerID(hexData: identityData.noisePublicKey)
                ),
                isBlocked: false,
                notes: nil
            )
        }
        guard !identity.isBlocked else { return false }
        identity.localPetname = normalized
        guard chatViewModel.identityManager.persistSocialIdentity(identity) else {
            return false
        }

        friendCandidate = FriendVerificationCandidate(
            qr: candidate.qr,
            fingerprint: candidate.fingerprint,
            existingLocalPetname: normalized
        )
        chatViewModel.unifiedPeerService.refreshPeers()
        NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
        objectWillChange.send()
        return true
    }

    private func validatedCandidateIdentity(
        _ candidate: FriendVerificationCandidate,
        requireFreshSignature: Bool
    ) -> (
        qr: VerificationService.VerificationQR,
        noisePublicKey: Data,
        signingPublicKey: Data
    )? {
        guard friendCandidate?.id == candidate.id else {
            friendVerificationState = .failed(.invalidPayload)
            return nil
        }

        let qr: VerificationService.VerificationQR
        if requireFreshSignature {
            guard let revalidated = VerificationService.shared.verifyScannedQR(
                candidate.qr.toURLString()
            ) else {
                friendVerificationState = .failed(.invalidPayload)
                return nil
            }
            qr = revalidated
        } else {
            qr = candidate.qr
        }

        guard let noisePublicKey = Data(hexString: qr.noiseKeyHex),
              let signingPublicKey = Data(hexString: qr.signKeyHex),
              noisePublicKey.sha256Fingerprint() == candidate.fingerprint else {
            friendVerificationState = .failed(.invalidPayload)
            return nil
        }
        guard noisePublicKey != chatViewModel.meshService.noiseStaticPublicKeyData() else {
            friendVerificationState = .failed(.selfIdentity)
            return nil
        }
        guard !chatViewModel.identityManager.isBlocked(fingerprint: candidate.fingerprint),
              chatViewModel.identityManager
                .getSocialIdentity(for: candidate.fingerprint)?.isBlocked != true else {
            friendVerificationState = .failed(.blocked)
            return nil
        }
        if let pinnedSigningKey = chatViewModel.identityManager
            .authenticatedSigningPublicKey(forFingerprint: candidate.fingerprint)
            ?? chatViewModel.identityManager
                .signingPublicKey(forFingerprint: candidate.fingerprint),
           pinnedSigningKey != signingPublicKey {
            friendVerificationState = .failed(.signingKeyMismatch)
            return nil
        }
        return (qr, noisePublicKey, signingPublicKey)
    }

    func resetFriendVerificationFlow() {
        if let qr = friendCandidate?.qr {
            chatViewModel.cancelFriendVerification(with: qr)
        }
        friendCandidate = nil
        friendVerificationState = .idle
    }

    func verifyFingerprint(for peerID: PeerID) {
        chatViewModel.verifyFingerprint(for: peerID)
    }

    func unverifyFingerprint(for peerID: PeerID) {
        chatViewModel.unverifyFingerprint(for: peerID)
    }

    /// Persist a local alias for this peer. Empty/whitespace clears it so the
    /// claimed nickname shows again. Display paths prefer `localPetname`
    /// when set (#1439).
    @discardableResult
    func setLocalPetname(_ petname: String?, for peerID: PeerID) -> Bool {
        let statusPeerID = chatViewModel.getShortIDForNoiseKey(peerID)
        guard let fingerprint = chatViewModel.getFingerprint(for: statusPeerID) else { return false }

        let trimmed = petname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if let trimmed, !trimmed.isEmpty {
            guard let validated = InputValidator.validateNickname(trimmed) else { return false }
            normalized = validated
        } else {
            normalized = nil
        }

        let existing = chatViewModel.identityManager.getSocialIdentity(for: fingerprint)
        let claimed = existing?.claimedNickname
            ?? chatViewModel.meshService.peerNickname(peerID: statusPeerID)
            ?? chatViewModel.resolveNickname(for: statusPeerID)
        var identity: SocialIdentity
        if let existing {
            identity = existing
        } else {
            identity = SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: claimed,
                trustLevel: .unknown,
                isFavorite: chatViewModel.isFavorite(peerID: statusPeerID),
                isBlocked: false,
                notes: nil
            )
        }
        guard !identity.isBlocked else { return false }
        identity.localPetname = normalized
        guard chatViewModel.identityManager.persistSocialIdentity(identity) else {
            return false
        }
        // Rebuild peer rows so PeerList / DM header pick up the new display name
        // without waiting for an unrelated mesh event.
        chatViewModel.unifiedPeerService.refreshPeers()
        NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
        objectWillChange.send()
        return true
    }

    func isVerified(peerID: PeerID) -> Bool {
        guard let fingerprint = chatViewModel.getFingerprint(for: peerID) else { return false }
        return peerIdentityStore.isVerified(fingerprint)
    }

    func fingerprintPresentation(for peerID: PeerID) -> FingerprintPresentationState {
        let statusPeerID = chatViewModel.getShortIDForNoiseKey(peerID)
        let encryptionStatus = chatViewModel.getEncryptionStatus(for: statusPeerID)
        let theirFingerprint = chatViewModel.getFingerprint(for: statusPeerID)
        let peerNickname = resolveDisplayName(for: peerID, statusPeerID: statusPeerID)
        let isVerified = theirFingerprint.map { peerIdentityStore.isVerified($0) } ?? false
        let localPetname = theirFingerprint
            .flatMap { chatViewModel.identityManager.getSocialIdentity(for: $0)?.localPetname }

        // Vouch state is recomputed on read: only vouchers still in the
        // verified set count, so removing a verification silently retires the
        // vouches that peer gave.
        let vouchers: [VouchRecord]
        if !isVerified, let theirFingerprint {
            vouchers = chatViewModel.identityManager.validVouchers(for: theirFingerprint)
        } else {
            vouchers = []
        }
        let voucherNames = vouchers.compactMap { record -> String? in
            guard let social = chatViewModel.identityManager.getSocialIdentity(for: record.voucherFingerprint) else {
                return nil
            }
            if let petname = social.localPetname, !petname.isEmpty { return petname }
            return social.claimedNickname.isEmpty ? nil : social.claimedNickname
        }

        return FingerprintPresentationState(
            peerNickname: peerNickname,
            encryptionStatus: encryptionStatus,
            theirFingerprint: theirFingerprint,
            myFingerprint: chatViewModel.getMyFingerprint(),
            isVerified: isVerified,
            localPetname: localPetname,
            voucherCount: vouchers.count,
            voucherNames: voucherNames
        )
    }

    private func bind(privateConversationModel: PrivateConversationModel) {
        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentNickname)

        privateConversationModel.$selectedPeerID
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedPeerID)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Vouch state changes (ChatVouchCoordinator.notifyPeerTrustChanged)
        // are signalled via this notification rather than a published
        // property, so an open fingerprint sheet refreshes its vouched badge
        // live when a vouch batch is accepted.
        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func resolveDisplayName(for peerID: PeerID, statusPeerID: PeerID) -> String {
        // Prefer an explicit local alias even when a live peer row exists —
        // peer.displayName already does this once UnifiedPeerService rebuilds,
        // but read social identity directly so the fingerprint sheet header
        // updates before that rebuild lands.
        if let fingerprint = chatViewModel.getFingerprint(for: statusPeerID),
           let pet = chatViewModel.identityManager.getSocialIdentity(for: fingerprint)?.localPetname,
           !pet.isEmpty {
            return pet
        }
        if let peer = chatViewModel.getPeer(byID: statusPeerID) {
            return peer.displayName
        }
        if let name = chatViewModel.meshService.peerNickname(peerID: statusPeerID) {
            return name
        }
        if let data = peerID.noiseKey {
            if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: data),
               !favorite.peerNickname.isEmpty {
                return favorite.peerNickname
            }
            let fingerprint = data.sha256Fingerprint()
            if let social = chatViewModel.identityManager.getSocialIdentity(for: fingerprint) {
                if !social.claimedNickname.isEmpty {
                    return social.claimedNickname
                }
            }
        }

        return String(localized: "common.unknown", comment: "Label for an unknown peer")
    }
}
