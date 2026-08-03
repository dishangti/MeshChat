import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeArchitectureViewModel(
    locationManager: LocationChannelManager? = nil
) -> ChatViewModel {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let locationManager = locationManager ?? makeArchitectureLocationManager()

    return ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: MockTransport(),
        locationManager: locationManager
    )
}

@MainActor
private func makeArchitectureLocationManager() -> LocationChannelManager {
    let suiteName = "AppArchitectureTests.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    return LocationChannelManager(storage: storage)
}

private func makeArchitectureSnapshot(
    peerID: PeerID,
    nickname: String,
    connected: Bool,
    noisePublicKey: Data
) -> TransportPeerSnapshot {
    TransportPeerSnapshot(
        peerID: peerID,
        nickname: nickname,
        isConnected: connected,
        noisePublicKey: noisePublicKey,
        lastSeen: Date()
    )
}

@MainActor
private func makeArchitectureMessage(
    id: String,
    timestamp: TimeInterval = 0,
    content: String? = nil,
    isPrivate: Bool = false,
    senderPeerID: PeerID = PeerID(str: "peer-a")
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "alice",
        content: content ?? "message \(id)",
        timestamp: Date(timeIntervalSince1970: timestamp),
        isRelay: false,
        originalSender: nil,
        isPrivate: isPrivate,
        recipientNickname: isPrivate ? "builder" : nil,
        senderPeerID: senderPeerID
    )
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    pollNanoseconds: UInt64 = 20_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let timeout = Double(timeoutNanoseconds) / 1_000_000_000
    let deadline = Date().addingTimeInterval(timeout)

    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
}

@Suite("App Architecture Tests", .serialized)
struct AppArchitectureTests {

    @Test("PeerIdentityStore owns fingerprint, mapping, and verification state")
    @MainActor
    func peerIdentityStoreOwnsIdentityState() {
        let store = PeerIdentityStore()
        let shortPeerID = PeerID(str: "peer-short")
        let stablePeerID = PeerID(str: "peer-stable")
        let canonicalPeerID = PeerID(str: "peer-canonical")

        store.setStablePeerID(stablePeerID, forShortID: shortPeerID)
        store.setFingerprint("fp-1", for: shortPeerID)
        store.setCachedEncryptionStatus(.noiseHandshaking, for: shortPeerID)
        store.setEncryptionStatus(.noiseSecured, for: shortPeerID)
        store.setVerified("fp-1", verified: true)

        let migratedFingerprint = store.migrateFingerprintMapping(
            from: shortPeerID,
            to: canonicalPeerID
        )

        #expect(store.stablePeerID(forShortID: shortPeerID) == stablePeerID)
        #expect(store.shortPeerID(forStablePeerID: stablePeerID) == shortPeerID)
        #expect(migratedFingerprint == "fp-1")
        #expect(store.fingerprint(for: shortPeerID) == nil)
        #expect(store.fingerprint(for: canonicalPeerID) == "fp-1")
        #expect(store.selectedPrivateChatFingerprint == "fp-1")
        #expect(store.encryptionStatus(for: shortPeerID) == .noiseSecured)
        #expect(store.cachedEncryptionStatus(for: shortPeerID) == nil)
        #expect(store.isVerified("fp-1"))

        store.clearAll()

        #expect(store.encryptionStatuses.isEmpty)
        #expect(store.verifiedFingerprints.isEmpty)
        #expect(store.peerFingerprintsByPeerID.isEmpty)
        #expect(store.selectedPrivateChatFingerprint == nil)
        #expect(store.stablePeerID(forShortID: shortPeerID) == nil)
    }

    @Test("Identity locks use gray, green, and permanently latched yellow states")
    @MainActor
    func identityLocksUseThreePermanentSecurityStates() {
        let store = PeerIdentityStore()
        let routeID = PeerID(str: "1122334455667788")
        let fingerprint = Data(repeating: 0x11, count: 32).sha256Fingerprint()

        #expect(IdentityLockState.unverified.icon == "lock.fill")
        #expect(IdentityLockState.verified.icon == "lock.fill")
        #expect(IdentityLockState.identityMismatch.icon == "lock.fill")
        #expect(IdentityLockState.unverified.color == .gray)
        #expect(IdentityLockState.verified.color == .green)
        #expect(IdentityLockState.identityMismatch.color == .yellow)
        #expect(store.identityLockState(fingerprint: nil) == .unverified)

        // Transport availability does not affect the identity-only lock.
        store.setEncryptionStatus(EncryptionStatus.none, for: routeID)
        #expect(store.identityLockState(fingerprint: fingerprint) == .unverified)

        store.setVerified(fingerprint.uppercased(), verified: true)
        #expect(store.identityLockState(fingerprint: fingerprint) == .verified)

        store.recordIdentityConflict(
            forFingerprint: fingerprint.uppercased(),
            reason: .signingKeyMismatch,
            detectedAt: Date(timeIntervalSince1970: 42)
        )
        #expect(store.identityLockState(fingerprint: fingerprint) == .identityMismatch)
        #expect(store.identityConflicts[fingerprint]?.reason == .signingKeyMismatch)

        // Verification changes are independent and never clear the history.
        store.setVerified(fingerprint, verified: false)
        store.setVerified(fingerprint, verified: true)
        #expect(store.identityLockState(fingerprint: fingerprint) == .identityMismatch)

        store.clearAll()
        #expect(store.identityConflicts.isEmpty)
        #expect(store.identityLockState(fingerprint: fingerprint) == .unverified)
    }

    @Test("Identity conflict latches persist by normalized full fingerprint")
    @MainActor
    func identityConflictLatchesPersistByFullFingerprint() throws {
        let keychain = MockKeychain()
        let store = PeerIdentityStore(keychain: keychain)
        let noiseKey = Data((0..<32).map(UInt8.init))
        let fingerprint = noiseKey.sha256Fingerprint()
        let detectedAt = Date(timeIntervalSince1970: 1_234.5)

        store.recordIdentityConflict(
            forFingerprint: fingerprint.uppercased(),
            reason: .authenticatedSigningKeyMismatch,
            detectedAt: detectedAt
        )
        let originalConflict = try #require(store.identityConflicts[fingerprint])
        let persistedData = try #require(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            )
        )
        let persistedText = try #require(
            String(data: persistedData, encoding: .utf8)
        )

        #expect(persistedText.contains(fingerprint))
        #expect(!persistedText.contains(noiseKey.hexEncodedString()))
        #expect(persistedText.contains("authenticatedSigningKeyMismatch"))

        let restored = PeerIdentityStore(keychain: keychain)
        let restoredConflict = try #require(restored.identityConflicts[fingerprint])
        #expect(restored.identityConflicts.count == 1)
        #expect(restoredConflict.id == originalConflict.id)
        #expect(restoredConflict.reason == .authenticatedSigningKeyMismatch)
        #expect(restoredConflict.detectedAt == detectedAt)

        restored.setVerified(fingerprint, verified: true)
        #expect(restored.identityLockState(fingerprint: fingerprint) == .identityMismatch)
    }

    @Test("QR identity-binding conflicts persist as permanent yellow locks")
    @MainActor
    func qrIdentityBindingConflictPersistsAsPermanentYellowLock() throws {
        let keychain = MockKeychain()
        let fingerprint = Data(repeating: 0x19, count: 32).sha256Fingerprint()
        let store = PeerIdentityStore(keychain: keychain)

        store.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .qrIdentityBindingMismatch
        )

        let persistedData = try #require(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            )
        )
        let persistedText = try #require(
            String(data: persistedData, encoding: .utf8)
        )
        #expect(persistedText.contains("qrIdentityBindingMismatch"))

        let restored = PeerIdentityStore(keychain: keychain)
        #expect(
            restored.identityConflicts[fingerprint]?.reason
                == .qrIdentityBindingMismatch
        )
        restored.setVerified(fingerprint, verified: true)
        #expect(restored.identityLockState(fingerprint: fingerprint) == .identityMismatch)
        #expect(IdentityLockState.identityMismatch.color == .yellow)
    }

    @Test("Authenticated malformed-data conflict reasons persist")
    @MainActor
    func authenticatedMalformedConflictReasonsPersist() {
        let keychain = MockKeychain()
        let dataFingerprint = Data(repeating: 0x21, count: 32).sha256Fingerprint()
        let peerStateFingerprint = Data(repeating: 0x22, count: 32).sha256Fingerprint()
        let store = PeerIdentityStore(keychain: keychain)

        store.recordIdentityConflict(
            forFingerprint: dataFingerprint,
            reason: .malformedAuthenticatedData
        )
        store.recordIdentityConflict(
            forFingerprint: peerStateFingerprint,
            reason: .malformedAuthenticatedPeerState
        )

        let restored = PeerIdentityStore(keychain: keychain)
        #expect(
            restored.identityConflicts[dataFingerprint]?.reason
                == .malformedAuthenticatedData
        )
        #expect(
            restored.identityConflicts[peerStateFingerprint]?.reason
                == .malformedAuthenticatedPeerState
        )
    }

    @Test("Unavailable Keychain reads preserve and merge the durable snapshot")
    @MainActor
    func unavailableIdentityConflictSnapshotIsMergedAfterStorageReturns() throws {
        let keychain = MockKeychain()
        let durableFingerprint = Data(repeating: 0x31, count: 32).sha256Fingerprint()
        let pendingFingerprint = Data(repeating: 0x32, count: 32).sha256Fingerprint()
        let seedingStore = PeerIdentityStore(keychain: keychain)
        seedingStore.recordIdentityConflict(
            forFingerprint: durableFingerprint,
            reason: .signingKeyMismatch,
            detectedAt: Date(timeIntervalSince1970: 10)
        )
        let durableSnapshot = try #require(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            )
        )

        keychain.simulatedReadError = .deviceLocked
        let lockedStore = PeerIdentityStore(keychain: keychain)
        lockedStore.recordIdentityConflict(
            forFingerprint: durableFingerprint,
            reason: .malformedAuthenticatedData,
            detectedAt: Date(timeIntervalSince1970: 20)
        )
        lockedStore.recordIdentityConflict(
            forFingerprint: pendingFingerprint,
            reason: .malformedAuthenticatedData,
            detectedAt: Date(timeIntervalSince1970: 20)
        )

        #expect(
            lockedStore.identityConflicts[durableFingerprint]?.reason
                == .malformedAuthenticatedData
        )
        #expect(
            lockedStore.identityConflicts[pendingFingerprint]?.reason
                == .malformedAuthenticatedData
        )
        #expect(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            ) == durableSnapshot
        )

        keychain.simulatedReadError = nil
        #expect(
            lockedStore.identityLockState(fingerprint: durableFingerprint)
                == .identityMismatch
        )
        #expect(lockedStore.identityConflicts.count == 2)
        #expect(
            lockedStore.identityConflicts[durableFingerprint]?.reason
                == .signingKeyMismatch
        )

        let restored = PeerIdentityStore(keychain: keychain)
        #expect(
            restored.identityConflicts[durableFingerprint]?.reason
                == .signingKeyMismatch
        )
        #expect(
            restored.identityConflicts[pendingFingerprint]?.reason
                == .malformedAuthenticatedData
        )
    }

    @Test("Unknown persisted conflict reasons keep the snapshot opaque")
    @MainActor
    func unknownPersistedConflictReasonIsNotOverwritten() throws {
        let keychain = MockKeychain()
        let futureFingerprint = Data(repeating: 0x41, count: 32).sha256Fingerprint()
        let pendingFingerprint = Data(repeating: 0x42, count: 32).sha256Fingerprint()
        let seedingStore = PeerIdentityStore(keychain: keychain)
        seedingStore.recordIdentityConflict(
            forFingerprint: futureFingerprint,
            reason: .malformedAuthenticatedData
        )

        let seededData = try #require(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            )
        )
        var snapshot = try #require(
            JSONSerialization.jsonObject(with: seededData)
                as? [String: Any]
        )
        var conflicts = try #require(snapshot["conflicts"] as? [[String: Any]])
        conflicts[0]["reason"] = "futureAuthenticatedConflict"
        snapshot["conflicts"] = conflicts
        let futureSnapshot = try JSONSerialization.data(withJSONObject: snapshot)
        #expect(
            keychain.saveIdentityKey(
                futureSnapshot,
                forKey: PeerIdentityStore.identityConflictStorageKey
            )
        )

        let store = PeerIdentityStore(keychain: keychain)
        store.recordIdentityConflict(
            forFingerprint: pendingFingerprint,
            reason: .malformedAuthenticatedData
        )

        #expect(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            ) == futureSnapshot
        )
        #expect(
            store.identityLockState(fingerprint: pendingFingerprint)
                == .identityMismatch
        )
    }

    @Test("Unavailable conflict storage suppresses positive verification")
    @MainActor
    func unavailableIdentityConflictStorageSuppressesVerifiedState() {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .deviceLocked
        let store = PeerIdentityStore(keychain: keychain)
        let fingerprint = Data(repeating: 0x51, count: 32).sha256Fingerprint()
        store.setVerified(fingerprint, verified: true)

        #expect(store.identityLockState(fingerprint: fingerprint) == .unverified)

        keychain.simulatedReadError = nil
        #expect(store.identityLockState(fingerprint: fingerprint) == .verified)
    }

    @Test("Stronger conflict reasons cannot be downgraded")
    @MainActor
    func strongerIdentityConflictCannotBeDowngraded() {
        let store = PeerIdentityStore()
        let fingerprint = Data(repeating: 0x61, count: 32).sha256Fingerprint()

        store.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .authenticatedSigningKeyMismatch,
            detectedAt: Date(timeIntervalSince1970: 10)
        )
        store.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .malformedAuthenticatedData,
            detectedAt: Date(timeIntervalSince1970: 20)
        )

        #expect(
            store.identityConflicts[fingerprint]?.reason
                == .authenticatedSigningKeyMismatch
        )
        #expect(
            store.identityConflicts[fingerprint]?.detectedAt
                == Date(timeIntervalSince1970: 20)
        )
    }

    @Test("A conflict follows its fingerprint across routing-ID changes")
    @MainActor
    func identityConflictIsScopedToFingerprintAcrossRoutingChanges() {
        let store = PeerIdentityStore()
        let fingerprint = Data(repeating: 0x71, count: 32).sha256Fingerprint()
        let otherFingerprint = Data(repeating: 0x72, count: 32).sha256Fingerprint()
        let oldRoute = PeerID(str: "1111111111111111")
        let newRoute = PeerID(str: "2222222222222222")

        store.setVerified(fingerprint, verified: true)
        store.setVerified(otherFingerprint, verified: true)
        store.setFingerprint(fingerprint.uppercased(), for: oldRoute)
        store.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .malformedAuthenticatedData
        )

        #expect(
            store.identityLockState(fingerprint: store.fingerprint(for: oldRoute))
                == .identityMismatch
        )
        #expect(store.identityLockState(fingerprint: otherFingerprint) == .verified)

        #expect(
            store.migrateFingerprintMapping(from: oldRoute, to: newRoute)
                == fingerprint
        )
        #expect(store.fingerprint(for: oldRoute) == nil)
        #expect(
            store.identityLockState(fingerprint: store.fingerprint(for: newRoute))
                == .identityMismatch
        )

        // Reusing a routing ID for another identity cannot inherit the flag.
        store.setFingerprint(otherFingerprint, for: oldRoute)
        #expect(
            store.identityLockState(fingerprint: store.fingerprint(for: oldRoute))
                == .verified
        )
    }

    @Test("Incomplete fingerprints cannot create permanent identity flags")
    @MainActor
    func invalidFingerprintCannotLatchIdentityConflict() {
        let store = PeerIdentityStore()

        store.recordIdentityConflict(
            forFingerprint: "1122334455667788",
            reason: .claimedPeerIDMismatch
        )
        store.recordIdentityConflict(
            forFingerprint: String(repeating: "z", count: 64),
            reason: .claimedPeerIDMismatch
        )

        #expect(store.identityConflicts.isEmpty)
    }

    @Test("A failed conflict write is retried without losing the latch")
    @MainActor
    func identityConflictPersistenceRetriesWithoutClearing() {
        let keychain = MockKeychain()
        let fingerprint = Data(repeating: 0x81, count: 32).sha256Fingerprint()
        let store = PeerIdentityStore(keychain: keychain)
        keychain.simulatedSaveError = .deviceLocked

        store.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .noiseStaticKeyMismatch
        )
        #expect(store.identityConflicts[fingerprint] != nil)
        #expect(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            ) == nil
        )

        keychain.simulatedSaveError = nil
        #expect(store.identityLockState(fingerprint: fingerprint) == .identityMismatch)
        #expect(
            PeerIdentityStore(keychain: keychain).identityConflicts[fingerprint]
                != nil
        )
    }

    @Test("Panic clear deletes persisted identity conflict latches")
    @MainActor
    func panicClearDeletesIdentityConflictLatches() {
        let keychain = MockKeychain()
        let fingerprint = Data(repeating: 0x91, count: 32).sha256Fingerprint()
        let store = PeerIdentityStore(keychain: keychain)
        store.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .claimedPeerIDMismatch
        )

        store.clearAll()

        #expect(
            keychain.getIdentityKey(
                forKey: PeerIdentityStore.identityConflictStorageKey
            ) == nil
        )
        #expect(PeerIdentityStore(keychain: keychain).identityConflicts.isEmpty)
    }

    @Test("Identity conflict presentation suppresses positive trust signals")
    func identityConflictPresentationSuppressesPositiveTrust() {
        let state = FingerprintPresentationState(
            peerNickname: "Alice",
            encryptionStatus: .noiseVerified,
            identityLockState: .identityMismatch,
            theirFingerprint: "alice-fingerprint",
            myFingerprint: "my-fingerprint",
            isVerified: false,
            localPetname: nil,
            voucherCount: 2,
            voucherNames: ["Bob", "Carol"]
        )

        #expect(!state.isVouched)
        #expect(!state.canToggleVerification)
        #expect(state.showsVerificationStatus)

        let pendingSessionState = FingerprintPresentationState(
            peerNickname: "Alice",
            encryptionStatus: EncryptionStatus.none,
            identityLockState: .identityMismatch,
            theirFingerprint: nil,
            myFingerprint: "my-fingerprint",
            isVerified: false,
            localPetname: nil,
            voucherCount: 0,
            voucherNames: []
        )
        #expect(!pendingSessionState.canToggleVerification)
        #expect(pendingSessionState.showsVerificationStatus)
    }

    @Test("ChatViewModel publishes transport identity conflicts to UI state")
    @MainActor
    func chatViewModelPublishesIdentityConflicts() {
        let viewModel = makeArchitectureViewModel()
        let fingerprint = Data(repeating: 0xA1, count: 32).sha256Fingerprint()
        let otherFingerprint = Data(repeating: 0xA2, count: 32).sha256Fingerprint()
        viewModel.peerIdentityStore.setVerified(fingerprint, verified: true)
        viewModel.peerIdentityStore.setVerified(otherFingerprint, verified: true)

        viewModel.didReceiveTransportEvent(
            .peerIdentityConflictDetected(
                fingerprint: fingerprint.uppercased(),
                reason: .claimedPeerIDMismatch,
                detectedAt: Date(timeIntervalSince1970: 42)
            )
        )

        #expect(
            viewModel.peerIdentityStore.identityLockState(fingerprint: fingerprint)
                == .identityMismatch
        )
        #expect(
            viewModel.peerIdentityStore.identityConflicts[fingerprint]?.reason
                == .claimedPeerIDMismatch
        )
        #expect(
            viewModel.peerIdentityStore.identityLockState(
                fingerprint: otherFingerprint
            ) == .verified
        )
    }

    @Test("LocationPresenceStore normalizes and resets geohash presence state")
    @MainActor
    func locationPresenceStoreNormalizesPresenceState() {
        let store = LocationPresenceStore()

        store.setCurrentGeohash("U4PRUY")
        store.replaceGeoNicknames([
            "ABCDEF": "alice",
            "123456": "bob"
        ])
        store.markTeleported("ABCDEF")
        store.replaceTeleportedGeo(Set(["FEDCBA", "123456"]))

        #expect(store.currentGeohash == "u4pruy")
        #expect(store.geoNicknames["abcdef"] == "alice")
        #expect(store.geoNicknames["123456"] == "bob")
        #expect(store.teleportedGeo == Set(["fedcba", "123456"]))

        store.reset()

        #expect(store.currentGeohash == nil)
        #expect(store.geoNicknames.isEmpty)
        #expect(store.teleportedGeo.isEmpty)
    }

    @Test("LocationPresenceStore bounds and prunes teleported geohash participants")
    @MainActor
    func locationPresenceStoreBoundsTeleportedParticipants() {
        let store = LocationPresenceStore(teleportedGeoCapacity: 2)

        store.setCurrentGeohash("u4pruy")
        store.markTeleported("AAAAAA")
        store.markTeleported("BBBBBB")
        store.markTeleported("CCCCCC")

        #expect(store.teleportedGeo == Set(["bbbbbb", "cccccc"]))

        store.retainTeleportedGeo(keeping: Set(["CCCCCC"]))
        #expect(store.teleportedGeo == Set(["cccccc"]))

        store.setCurrentGeohash("u4pruz")
        #expect(store.teleportedGeo.isEmpty)
    }

    @Test("LocationPresenceStore bounds geohash nicknames and clears on channel switch")
    @MainActor
    func locationPresenceStoreBoundsGeoNicknames() {
        let store = LocationPresenceStore(geoNicknameCapacity: 2)

        store.setCurrentGeohash("u4pruy")
        store.setNickname("alice", for: "AAAAAA")
        store.setNickname("bob", for: "BBBBBB")
        store.setNickname("carol", for: "CCCCCC")

        #expect(store.geoNicknames == ["bbbbbb": "bob", "cccccc": "carol"])

        store.retainGeoNicknames(keeping: Set(["CCCCCC"]))
        #expect(store.geoNicknames == ["cccccc": "carol"])

        store.setCurrentGeohash("u4pruz")
        #expect(store.geoNicknames.isEmpty)
    }

    @Test("PeerHandle equality and hashing use the canonical identity only")
    func peerHandleEqualityUsesCanonicalIdentity() {
        let first = PeerHandle(id: "noise:abc123", routingPeerID: PeerID(str: "peer-a"))
        let second = PeerHandle(id: "noise:abc123", routingPeerID: PeerID(str: "peer-b"))

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    @Test("Deleting Recent returns Home only for the active peer identity")
    func recentDeletionNavigationMatchesStableAndShortPeerIDs() {
        let deletedNoiseKey = Data(repeating: 0xA1, count: 32)
        let deletedStablePeerID = PeerID(hexData: deletedNoiseKey)
        let deletedShortPeerID = PeerID(publicKey: deletedNoiseKey)
        let anotherPeerID = PeerID(str: "0011223344556677")

        #expect(
            MeshChatRecentDeletionNavigation.shouldShowHome(
                afterDeleting: deletedStablePeerID,
                activePeerID: deletedShortPeerID,
                wasShowingConversation: true
            )
        )
        #expect(
            !MeshChatRecentDeletionNavigation.shouldShowHome(
                afterDeleting: deletedStablePeerID,
                activePeerID: anotherPeerID,
                wasShowingConversation: true
            )
        )
        #expect(
            !MeshChatRecentDeletionNavigation.shouldShowHome(
                afterDeleting: deletedStablePeerID,
                activePeerID: deletedShortPeerID,
                wasShowingConversation: false
            )
        )
    }

    @Test("ConversationStore orders timelines and replaces duplicates by message ID")
    @MainActor
    func conversationStoreOrdersAndDedupsMessages() {
        let store = ConversationStore()
        let older = makeArchitectureMessage(id: "m1", timestamp: 1, content: "first")
        let newer = makeArchitectureMessage(id: "m2", timestamp: 2, content: "second")
        let replacement = makeArchitectureMessage(id: "m2", timestamp: 2, content: "second-updated")

        store.append(newer, to: .mesh)
        store.append(older, to: .mesh)
        store.upsertByID(replacement, in: .mesh)

        let messages = store.conversation(for: .mesh).messages
        #expect(messages.map(\.id) == ["m1", "m2"])
        #expect(messages.last?.content == "second-updated")
    }

    @Test("ConversationStore tracks unread direct conversations by routing peer ID")
    @MainActor
    func conversationStoreTracksUnreadDirectConversations() {
        let store = ConversationStore()
        let peerID = PeerID(str: "peer-1")
        let message = makeArchitectureMessage(id: "dm-1", isPrivate: true, senderPeerID: peerID)

        store.append(message, to: .directPeer(peerID))
        store.markUnread(.directPeer(peerID))

        #expect(store.conversation(for: .directPeer(peerID)).messages.map(\.id) == ["dm-1"])
        #expect(store.unreadDirectRoutingPeerIDs() == Set([peerID]))
        #expect(store.conversation(for: .directPeer(peerID)).isUnread)

        store.markRead(.directPeer(peerID))
        #expect(store.unreadDirectRoutingPeerIDs().isEmpty)
        #expect(!store.conversation(for: .directPeer(peerID)).isUnread)
    }

    @Test("ConversationStore derives the selected conversation from channel and private peer")
    @MainActor
    func conversationStoreTracksSelectedConversationContext() {
        let store = ConversationStore()
        let peerID = PeerID(str: "0011223344556677")
        let geohashChannel = ChannelID.location(GeohashChannel(level: .city, geohash: "9q8yy"))

        store.setActiveChannel(geohashChannel)
        store.setSelectedPrivatePeer(peerID)

        #expect(store.activeChannel == geohashChannel)
        #expect(store.selectedPrivatePeerID == peerID)
        // The open private chat wins the derived selection.
        #expect(store.selectedConversationID == ConversationID.directPeer(peerID))

        store.setSelectedPrivatePeer(nil)
        // Selection falls back to the active public channel.
        #expect(store.selectedConversationID == ConversationID(channelID: geohashChannel))

        store.setActiveChannel(.mesh)
        #expect(store.activeChannel == ChannelID.mesh)
        #expect(store.selectedPrivatePeerID == nil)
        #expect(store.selectedConversationID == ConversationID.mesh)
    }

    @Test("ConversationStore re-keys a direct conversation via the migrate intent")
    @MainActor
    func conversationStoreMigratesDirectConversationsBetweenPeerIDs() {
        let store = ConversationStore()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let shortPeerID = PeerID(str: "0011223344556677")
        let fullPeerID = PeerID(hexData: noiseKey)

        store.append(
            makeArchitectureMessage(id: "dm-1", timestamp: 1, isPrivate: true, senderPeerID: shortPeerID),
            to: .directPeer(shortPeerID)
        )
        store.markUnread(.directPeer(shortPeerID))
        store.setSelectedPrivatePeer(shortPeerID)

        store.migrateConversation(from: .directPeer(shortPeerID), to: .directPeer(fullPeerID))

        // Raw keying: the old peer's conversation is gone, the new peer's
        // conversation holds the timeline, unread and selection carried over.
        #expect(store.conversationsByID[.directPeer(shortPeerID)] == nil)
        #expect(Set(store.directMessagesByRoutingPeerID().keys) == Set([fullPeerID]))
        #expect(store.directMessagesByRoutingPeerID()[fullPeerID]?.map(\.id) == ["dm-1"])
        #expect(store.unreadDirectRoutingPeerIDs() == Set([fullPeerID]))
        #expect(store.selectedPrivatePeerID == fullPeerID)
        #expect(store.selectedConversationID == ConversationID.directPeer(fullPeerID))
    }

    @Test("PrivateInboxModel reads direct message state from the ConversationStore")
    @MainActor
    func privateInboxModelReadsDirectMessageStateFromConversationStore() {
        let store = ConversationStore()
        let inboxModel = PrivateInboxModel(conversations: store)
        let messagePeerID = PeerID(str: "peer-1")
        let unreadOnlyPeerID = PeerID(str: "peer-2")
        let selectedOnlyPeerID = PeerID(str: "peer-3")

        store.append(
            makeArchitectureMessage(id: "dm-1", isPrivate: true, senderPeerID: messagePeerID),
            to: .directPeer(messagePeerID)
        )
        store.markUnread(.directPeer(messagePeerID))
        store.markUnread(.directPeer(unreadOnlyPeerID))
        store.setSelectedPrivatePeer(selectedOnlyPeerID)

        // Reads are synchronous against the single-writer store.
        #expect(inboxModel.selectedPeerID == selectedOnlyPeerID)
        #expect(inboxModel.unreadPeerIDs == Set([messagePeerID, unreadOnlyPeerID]))
        #expect(inboxModel.messages(for: messagePeerID).map(\.id) == ["dm-1"])
        #expect(inboxModel.messages(for: unreadOnlyPeerID).isEmpty)
        #expect(inboxModel.messages(for: selectedOnlyPeerID).isEmpty)
    }

    @Test("PrivateInboxModel republishes only for the selected conversation")
    @MainActor
    func privateInboxModelIsolatesBackgroundConversations() {
        let store = ConversationStore()
        let inboxModel = PrivateInboxModel(conversations: store)
        let selectedPeerID = PeerID(str: "peer-selected")
        let backgroundPeerID = PeerID(str: "peer-background")
        store.setSelectedPrivatePeer(selectedPeerID)

        var emissions = 0
        let cancellable = inboxModel.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        let baseline = emissions
        store.append(
            makeArchitectureMessage(id: "dm-bg-1", isPrivate: true, senderPeerID: backgroundPeerID),
            to: .directPeer(backgroundPeerID)
        )
        // An append to a background chat does not republish the model.
        #expect(emissions == baseline)

        store.append(
            makeArchitectureMessage(id: "dm-sel-1", isPrivate: true, senderPeerID: selectedPeerID),
            to: .directPeer(selectedPeerID)
        )
        #expect(emissions == baseline + 1)
        #expect(inboxModel.messages(for: selectedPeerID).map(\.id) == ["dm-sel-1"])
    }

    @Test("PrivateInboxModel republishes read receipts for the selected DM (ephemeral- and stable-keyed)")
    @MainActor
    func privateInboxModelRepublishesReadReceiptsForSelectedConversation() {
        // A DM's messages can live under BOTH .directPeer(ephemeral) and
        // .directPeer(stableKey) (mirroring shares one BitchatMessage
        // instance); the view's read-receipt update must fire no matter
        // which of the two keys the selection holds.
        let ephemeralPeerID = PeerID(str: "abcdef1234567890")
        let stablePeerID = PeerID(str: String(repeating: "ab", count: 32))

        for selectedPeerID in [ephemeralPeerID, stablePeerID] {
            let store = ConversationStore()
            let inboxModel = PrivateInboxModel(conversations: store)
            store.setSelectedPrivatePeer(selectedPeerID)

            // One shared instance mirrored into both direct conversations,
            // exactly like `mirrorToEphemeralIfNeeded`.
            let message = makeArchitectureMessage(
                id: "dm-read-1",
                isPrivate: true,
                senderPeerID: ephemeralPeerID
            )
            store.append(message, to: .directPeer(ephemeralPeerID))
            store.upsertByID(message, in: .directPeer(stablePeerID))

            var emissions = 0
            let cancellable = inboxModel.objectWillChange.sink { _ in emissions += 1 }
            defer { cancellable.cancel() }

            // ID-only intent — the exact call `ChatDeliveryCoordinator`
            // makes when a READ ack arrives.
            let read = DeliveryStatus.read(by: "builder", at: Date(timeIntervalSince1970: 100))
            #expect(store.setDeliveryStatus(read, forMessageID: "dm-read-1"))

            // The fan-out emits .statusChanged for both containing
            // conversations; exactly the selected one republishes the model.
            #expect(emissions == 1)
            #expect(inboxModel.messages(for: selectedPeerID).first?.deliveryStatus == read)
        }
    }

    @Test("PublicChatModel ignores appends to background conversations")
    @MainActor
    func publicChatModelIsolatesBackgroundConversations() {
        let store = ConversationStore()
        store.setActiveChannel(.mesh)
        let model = PublicChatModel(conversations: store)

        var emissions = 0
        let cancellable = model.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        store.append(makeArchitectureMessage(id: "mesh-1"), to: .mesh)
        let afterActiveAppend = emissions
        #expect(afterActiveAppend >= 1)
        #expect(model.messages.map(\.id) == ["mesh-1"])

        // Appends to a background geohash channel and to a private chat do
        // not invalidate the observer of the active conversation.
        store.append(makeArchitectureMessage(id: "geo-1"), to: .geohash("u4pruyd"))
        store.append(
            makeArchitectureMessage(id: "dm-1", isPrivate: true),
            to: .directPeer(PeerID(str: "peer-1"))
        )
        #expect(emissions == afterActiveAppend)
        #expect(model.messages.map(\.id) == ["mesh-1"])

        // Switching the channel retargets the observation.
        store.setActiveChannel(.location(GeohashChannel(level: .neighborhood, geohash: "u4pruyd")))
        #expect(model.messages.map(\.id) == ["geo-1"])
        store.append(makeArchitectureMessage(id: "geo-2", timestamp: 1), to: .geohash("u4pruyd"))
        #expect(model.messages.map(\.id) == ["geo-1", "geo-2"])
    }

    @Test("AppChromeModel mirrors nickname and unread state through focused models")
    @MainActor
    func appChromeModelMirrorsNicknameAndUnreadState() async {
        let viewModel = makeArchitectureViewModel()
        let conversations = ConversationStore()
        let privateInboxModel = PrivateInboxModel(conversations: conversations)
        let chromeModel = AppChromeModel(chatViewModel: viewModel, privateInboxModel: privateInboxModel)

        chromeModel.setNickname("builder")
        await waitUntil {
            viewModel.nickname == "builder" && chromeModel.nickname == "builder"
        }

        #expect(viewModel.nickname == "builder")
        #expect(chromeModel.nickname == "builder")
        #expect(!chromeModel.hasUnreadPrivateMessages)

        let peerID = PeerID(str: "peer-1")
        conversations.markUnread(.directPeer(peerID))
        await waitUntil {
            chromeModel.hasUnreadPrivateMessages
        }

        #expect(chromeModel.hasUnreadPrivateMessages)
    }

    @Test("AppChromeModel owns fingerprint and screenshot presentation state")
    @MainActor
    func appChromeModelOwnsPresentationState() {
        let viewModel = makeArchitectureViewModel()
        let privateInboxModel = PrivateInboxModel(conversations: ConversationStore())
        let chromeModel = AppChromeModel(chatViewModel: viewModel, privateInboxModel: privateInboxModel)
        let peerID = PeerID(str: "peer-2")

        chromeModel.showFingerprint(for: peerID)
        chromeModel.presentAppInfo()
        chromeModel.isLocationChannelsSheetPresented = true
        chromeModel.triggerScreenshotPrivacyWarning()

        #expect(chromeModel.showingFingerprintFor == peerID)
        #expect(chromeModel.isAppInfoPresented)
        #expect(chromeModel.shouldSuppressScreenshotNotification)
        #expect(chromeModel.showScreenshotPrivacyWarning)

        chromeModel.clearFingerprint()
        #expect(chromeModel.showingFingerprintFor == nil)
    }

    @Test("App information can open Help, Info, or Settings directly")
    @MainActor
    func appChromeModelSelectsRequestedInfoPane() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppInfoPane.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppInfoPane.storageKey)
            } else {
                defaults.removeObject(forKey: AppInfoPane.storageKey)
            }
        }
        let viewModel = makeArchitectureViewModel()
        let chromeModel = AppChromeModel(
            chatViewModel: viewModel,
            privateInboxModel: PrivateInboxModel(conversations: ConversationStore())
        )

        chromeModel.presentAppInfo(pane: .settings)
        #expect(defaults.string(forKey: AppInfoPane.storageKey) == AppInfoPane.settings.rawValue)

        chromeModel.presentAppInfo(pane: .info)
        #expect(defaults.string(forKey: AppInfoPane.storageKey) == AppInfoPane.info.rawValue)

        chromeModel.presentAppInfo()
        #expect(defaults.string(forKey: AppInfoPane.storageKey) == AppInfoPane.help.rawValue)
    }

    @Test("AppChromeModel closes every transient surface for panic")
    @MainActor
    func appChromeModelClosesTransientSurfacesForPanic() {
        let viewModel = makeArchitectureViewModel()
        let privateInboxModel = PrivateInboxModel(conversations: ConversationStore())
        let chromeModel = AppChromeModel(chatViewModel: viewModel, privateInboxModel: privateInboxModel)

        chromeModel.showFingerprint(for: PeerID(str: "peer-panic"))
        chromeModel.isAppInfoPresented = true
        chromeModel.isLocationChannelsSheetPresented = true
        chromeModel.presentNotices(geoTab: true)
        chromeModel.showBluetoothAlert = true
        chromeModel.bluetoothAlertMessage = "sensitive transport state"
        chromeModel.showScreenshotPrivacyWarning = true

        chromeModel.dismissTransientSurfacesForPanic()

        #expect(chromeModel.showingFingerprintFor == nil)
        #expect(!chromeModel.isAppInfoPresented)
        #expect(!chromeModel.isLocationChannelsSheetPresented)
        #expect(!chromeModel.isNoticesSheetPresented)
        #expect(!chromeModel.noticesSheetPrefersGeoTab)
        #expect(!chromeModel.showBluetoothAlert)
        #expect(chromeModel.bluetoothAlertMessage.isEmpty)
        #expect(!chromeModel.showScreenshotPrivacyWarning)
    }

    @Test("AppChromeModel labels shared Nostr blocks without inventing a location source")
    @MainActor
    func appChromeModelUsesNeutralNostrBlockSource() {
        let viewModel = makeArchitectureViewModel()
        let privateInboxModel = PrivateInboxModel(conversations: ConversationStore())
        let chromeModel = AppChromeModel(chatViewModel: viewModel, privateInboxModel: privateInboxModel)
        let pubkey = String(repeating: "a", count: 64)
        viewModel.identityManager.setNostrBlocked(pubkey, isBlocked: true)

        let row = chromeModel.blockedPeople().first { $0.stableID == pubkey }
        #expect(row?.source == .nostr)
        #expect(row?.source != .mesh)

        if let row {
            chromeModel.unblock(row)
        }
        #expect(!viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: pubkey))
    }

    @Test("Blocked rows with the same claimed name remain identity-distinguishable")
    func blockedRowsExposeDistinctCryptographicHints() {
        let first = BlockedPersonRow(
            source: .mesh,
            stableID: "111111abcdef222222222222222222222222222222222222222222aaaaaa",
            displayName: "alice"
        )
        let second = BlockedPersonRow(
            source: .mesh,
            stableID: "111111abcdef333333333333333333333333333333333333333333bbbbbb",
            displayName: "alice"
        )

        #expect(first.displayName == second.displayName)
        #expect(first.identityHint != second.identityHint)
        #expect(first.id != second.id)
    }

    @Test("Settings lists and unblocks a blocked mesh friend by stable identity")
    @MainActor
    func appChromeModelManagesBlockedMeshFriend() throws {
        let viewModel = makeArchitectureViewModel()
        let privateInboxModel = PrivateInboxModel(conversations: ConversationStore())
        let chromeModel = AppChromeModel(
            chatViewModel: viewModel,
            privateInboxModel: privateInboxModel
        )
        let fingerprint = String(repeating: "a", count: 64)
        viewModel.identityManager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: "Bestie",
                claimedNickname: "alice",
                trustLevel: .verified,
                isFavorite: true,
                isBlocked: true,
                notes: nil
            )
        )

        let row = try #require(
            chromeModel.blockedPeople().first { $0.stableID == fingerprint }
        )
        #expect(row.source == .mesh)
        #expect(row.displayName == "Bestie")
        #expect(viewModel.identityManager.isBlocked(fingerprint: fingerprint))

        chromeModel.unblock(row)

        #expect(!viewModel.identityManager.isBlocked(fingerprint: fingerprint))
        #expect(!chromeModel.blockedPeople().contains { $0.stableID == fingerprint })
    }

    @Test("Blocked people with equal names have deterministic identity order")
    @MainActor
    func blockedPeopleEqualNamesUseStableIdentityOrder() {
        let viewModel = makeArchitectureViewModel()
        let privateInboxModel = PrivateInboxModel(conversations: ConversationStore())
        let chromeModel = AppChromeModel(
            chatViewModel: viewModel,
            privateInboxModel: privateInboxModel
        )
        let firstFingerprint = String(repeating: "1", count: 64)
        let secondFingerprint = String(repeating: "2", count: 64)

        for fingerprint in [secondFingerprint, firstFingerprint] {
            viewModel.identityManager.updateSocialIdentity(
                SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: "Same Name",
                    claimedNickname: "same",
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: true,
                    notes: nil
                )
            )
        }

        let matchingIDs = chromeModel.blockedPeople()
            .filter { $0.displayName == "Same Name" }
            .map(\.stableID)
        #expect(matchingIDs == [firstFingerprint, secondFingerprint])
    }

    @Test("PrivateConversationModel resolves canonical header state for the selected DM")
    @MainActor
    func privateConversationModelResolvesSelectedHeaderState() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }
        let locationChannelsModel = LocationChannelsModel(manager: makeArchitectureLocationManager())
        let conversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )

        let noiseKey = Data((0..<32).map(UInt8.init))
        let shortPeerID = PeerID(str: "0011223344556677")
        let fullPeerID = PeerID(hexData: noiseKey)
        transport.peerNicknames[shortPeerID] = "alice"
        transport.reachablePeers.insert(shortPeerID)
        viewModel.allPeers = [
            BitchatPeer(
                peerID: shortPeerID,
                noisePublicKey: noiseKey,
                nickname: "alice",
                isConnected: false,
                isReachable: true
            )
        ]

        conversationModel.startConversation(with: fullPeerID)
        await waitUntil {
            conversationModel.selectedPeerID == fullPeerID
        }

        #expect(conversationModel.selectedPeerID == fullPeerID)
        #expect(conversationModel.selectedHeaderState?.headerPeerID == shortPeerID)
        #expect(conversationModel.selectedHeaderState?.displayName == "alice")
        #expect(conversationModel.selectedHeaderState?.availability == .meshReachable)
        #expect(conversationModel.selectedHeaderState?.encryptionStatus == .noHandshake)
        #expect(
            conversationModel.selectedHeaderState?.identityLockState
                == .unverified
        )

        conversationModel.endConversation()
        await waitUntil {
            conversationModel.selectedPeerID == nil
        }
        #expect(conversationModel.selectedPeerID == nil)
        #expect(conversationModel.selectedHeaderState == nil)
    }

    @Test("Legacy private header accessibility includes identity mismatch")
    @MainActor
    func legacyPrivateHeaderAccessibilityIncludesMismatch() {
        let peerID = PeerID(str: "0011223344556677")
        let headerState = PrivateConversationHeaderState(
            conversationPeerID: peerID,
            headerPeerID: peerID,
            displayName: "Alice",
            availability: .offline,
            isFavorite: false,
            encryptionStatus: EncryptionStatus.none,
            identityLockState: .identityMismatch
        )

        let label = contentPrivateHeaderAccessibilityLabel(for: headerState)
        #expect(label.contains("Alice"))
        #expect(
            label.contains(
                IdentityLockState.identityMismatch.accessibilityDescription
            )
        )
    }

    @Test("ConversationUIModel mirrors composer state and forwards sends")
    @MainActor
    func conversationUIModelMirrorsComposerStateAndForwardsSends() async {
        let locationManager = makeArchitectureLocationManager()
        let viewModel = makeArchitectureViewModel(locationManager: locationManager)
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }

        locationManager.select(.mesh)
        let locationChannelsModel = LocationChannelsModel(manager: locationManager)
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )
        let uiModel = ConversationUIModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel,
            conversations: viewModel.conversations
        )
        let geohashChannel = ChannelID.location(GeohashChannel(level: .city, geohash: "9q8yy"))
        defer {
            locationManager.select(.mesh)
        }
        viewModel.nickname = "builder"
        viewModel.autocompleteSuggestions = ["alice"]
        viewModel.showAutocomplete = true
        locationChannelsModel.select(geohashChannel)

        await waitUntil {
            viewModel.activeChannel == geohashChannel &&
            uiModel.currentNickname == "builder" &&
            uiModel.showAutocomplete &&
            uiModel.autocompleteSuggestions == ["alice"] &&
            !uiModel.canSendMediaInCurrentContext
        }

        #expect(viewModel.activeChannel == geohashChannel)
        #expect(uiModel.currentNickname == "builder")
        #expect(uiModel.showAutocomplete)
        #expect(uiModel.autocompleteSuggestions == ["alice"])
        #expect(!uiModel.canSendMediaInCurrentContext)

        locationChannelsModel.select(ChannelID.mesh)
        await waitUntil {
            viewModel.activeChannel == ChannelID.mesh &&
            uiModel.canSendMediaInCurrentContext
        }

        #expect(viewModel.activeChannel == ChannelID.mesh)
        #expect(uiModel.canSendMediaInCurrentContext)

        uiModel.sendMessage("hello mesh")

        await waitUntil {
            transport.sentMessages.last?.content == "hello mesh"
        }

        #expect(transport.sentMessages.last?.content == "hello mesh")
    }

    @Test("ConversationUIModel removes verified sender seals on identity conflict")
    @MainActor
    func conversationUIModelSuppressesConflictedSenderSeals() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }
        let peerID = PeerID(str: "0011223344556677")
        let fingerprint = Data(repeating: 0xB1, count: 32).sha256Fingerprint()
        transport.peerFingerprints[peerID] = fingerprint
        viewModel.peerIdentityStore.setVerified(fingerprint, verified: true)

        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(
                manager: makeArchitectureLocationManager()
            )
        )
        let uiModel = ConversationUIModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel,
            conversations: viewModel.conversations
        )
        let message = makeArchitectureMessage(
            id: "verified-private-message",
            isPrivate: true,
            senderPeerID: peerID
        )

        #expect(uiModel.showsVerifiedSeal(for: message))
        try? await Task.sleep(nanoseconds: 100_000_000)

        var refreshed = false
        let cancellable = uiModel.objectWillChange.sink { _ in
            refreshed = true
        }
        defer { cancellable.cancel() }

        viewModel.peerIdentityStore.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .signingKeyMismatch
        )
        await waitUntil { refreshed }

        #expect(refreshed)
        #expect(!uiModel.showsVerifiedSeal(for: message))
    }

    @Test("VerificationModel bridges selected conversation and fingerprint actions")
    @MainActor
    func verificationModelBridgesSelectedConversationAndFingerprintActions() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }

        let peerID = PeerID(str: "0011223344556677")
        let fingerprint = "verified-fingerprint"
        let locationChannelsModel = LocationChannelsModel(manager: makeArchitectureLocationManager())
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel
        )

        transport.peerFingerprints[peerID] = fingerprint
        transport.peerNicknames[peerID] = "alice"
        viewModel.allPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: Data((0..<32).map(UInt8.init)),
                nickname: "alice",
                isConnected: true,
                isReachable: true
            )
        ]

        privateConversationModel.startConversation(with: peerID)
        await waitUntil {
            verificationModel.selectedPeerID == peerID
        }

        let presentation = verificationModel.fingerprintPresentation(for: peerID)
        #expect(verificationModel.selectedPeerID == peerID)
        #expect(presentation.peerNickname == "alice")
        #expect(presentation.theirFingerprint == fingerprint)
        #expect(!presentation.myFingerprint.isEmpty)
        #expect(!verificationModel.isVerified(peerID: peerID))

        #expect(!verificationModel.setLocalPetname("bad\u{0007}name", for: peerID))
        #expect(
            verificationModel.fingerprintPresentation(for: peerID).localPetname == nil
        )
        #expect(verificationModel.setLocalPetname("  Buddy  ", for: peerID))
        #expect(
            verificationModel.fingerprintPresentation(for: peerID).localPetname == "Buddy"
        )

        verificationModel.verifyFingerprint(for: peerID)
        await waitUntil {
            verificationModel.isVerified(peerID: peerID)
        }
        #expect(verificationModel.isVerified(peerID: peerID))

        verificationModel.unverifyFingerprint(for: peerID)
        await waitUntil {
            !verificationModel.isVerified(peerID: peerID)
        }
        #expect(!verificationModel.isVerified(peerID: peerID))
    }

    @Test("VerificationModel keeps QR nickname, friend, and verification actions separate")
    @MainActor
    func verificationModelPreviewsSignedFriendQRBeforeStartingTransport() throws {
        let viewModel = makeArchitectureViewModel()
        VerificationService.shared.configure(with: viewModel.meshService)

        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: makeArchitectureLocationManager())
        )
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel
        )

        let friendTransport = MockTransport()
        let friendQRService = VerificationService()
        friendQRService.configure(with: friendTransport)
        let payload = try #require(
            friendQRService.buildMyQRString(nickname: "Alice", npub: nil)
        )

        let outcome = verificationModel.verifyScannedPayload(payload)
        guard case .candidate(let candidate) = outcome else {
            Issue.record("Expected a signed QR to produce a confirmation candidate")
            return
        }

        #expect(candidate.claimedNickname == "Alice")
        #expect(candidate.fingerprint == friendTransport.mockNoiseService.getStaticPublicKeyData().sha256Fingerprint())
        #expect(verificationModel.friendCandidate == candidate)
        #expect(verificationModel.friendVerificationState == .ready)

        #expect(!verificationModel.setLocalPetname("Alice\u{0007}", for: candidate))
        #expect(verificationModel.friendVerificationState == .ready)

        let noiseKey = friendTransport.mockNoiseService.getStaticPublicKeyData()
        #expect(verificationModel.setLocalPetname("  Neighbor  ", for: candidate))
        #expect(!verificationModel.isFriend(candidate))
        #expect(!verificationModel.isVerified(peerID: PeerID(publicKey: noiseKey)))
        let socialBeforeAdding = viewModel.identityManager.getSocialIdentity(
            for: candidate.fingerprint
        )
        #expect(socialBeforeAdding?.localPetname == "Neighbor")
        #expect(socialBeforeAdding?.isFavorite == false)
        #expect(verificationModel.friendVerificationState == .ready)

        defer {
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey)
        }
        #expect(verificationModel.addFriendFromCandidate())
        #expect(verificationModel.isFriend(candidate))
        #expect(!verificationModel.isVerified(peerID: PeerID(publicKey: noiseKey)))
        #expect(
            viewModel.identityManager
                .getSocialIdentity(for: candidate.fingerprint)?.localPetname == "Neighbor"
        )
        #expect(verificationModel.friendVerificationState == .ready)
    }

    @Test("VerificationModel reports an authentic expired Bitchat QR precisely")
    @MainActor
    func verificationModelDistinguishesExpiredBitchatQR() throws {
        let viewModel = makeArchitectureViewModel()
        VerificationService.shared.configure(with: viewModel.meshService)
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: PrivateConversationModel(
                chatViewModel: viewModel,
                conversations: viewModel.conversations,
                locationChannelsModel: LocationChannelsModel(
                    manager: makeArchitectureLocationManager()
                )
            )
        )

        let friendTransport = MockTransport()
        var qr = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: friendTransport.noiseStaticPublicKeyData()
                .hexEncodedString(),
            signKeyHex: friendTransport.noiseSigningPublicKeyData()
                .hexEncodedString(),
            npub: nil,
            nickname: "Alice",
            ts: Int64(
                Date().addingTimeInterval(
                    -(TransportConfig.verificationQRMaxAgeSeconds + 1)
                ).timeIntervalSince1970
            ),
            nonceB64: Data((0..<16).map(UInt8.init)).base64EncodedString(),
            sigHex: ""
        )
        qr.sigHex = try #require(
            friendTransport.noiseSignData(qr.canonicalBytes())
        ).hexEncodedString()

        #expect(
            verificationModel.verifyScannedPayload(qr.toURLString())
                == .rejected(.expiredPayload)
        )
        #expect(verificationModel.friendCandidate == nil)
        #expect(
            verificationModel.friendVerificationState
                == .failed(.expiredPayload)
        )
    }

    @Test("Opaque legacy npub never becomes a Nostr route when adding a friend")
    @MainActor
    func verificationModelDoesNotPersistOpaqueLegacyNpub() throws {
        let viewModel = makeArchitectureViewModel()
        VerificationService.shared.configure(with: viewModel.meshService)
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: PrivateConversationModel(
                chatViewModel: viewModel,
                conversations: viewModel.conversations,
                locationChannelsModel: LocationChannelsModel(
                    manager: makeArchitectureLocationManager()
                )
            )
        )

        let friendTransport = MockTransport()
        let noiseKey = friendTransport.noiseStaticPublicKeyData()
        var qr = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: noiseKey.hexEncodedString(),
            signKeyHex: friendTransport.noiseSigningPublicKeyData()
                .hexEncodedString(),
            npub: "npub1testvalue",
            nickname: "Legacy Alice",
            ts: Int64(Date().timeIntervalSince1970),
            nonceB64: Data((0..<16).map(UInt8.init)).base64EncodedString(),
            sigHex: ""
        )
        qr.sigHex = try #require(
            friendTransport.noiseSignData(qr.canonicalBytes())
        ).hexEncodedString()

        guard case .candidate = verificationModel.verifyScannedPayload(
            qr.toURLString()
        ) else {
            Issue.record("Expected the original-style signed QR to be accepted")
            return
        }
        defer {
            FavoritesPersistenceService.shared.removeFavorite(
                peerNoisePublicKey: noiseKey
            )
        }

        #expect(verificationModel.addFriendFromCandidate())
        #expect(
            FavoritesPersistenceService.shared
                .getFavoriteStatus(for: noiseKey)?.peerNostrPublicKey == nil
        )
    }

    @Test("Hybrid QR marks the authenticated signing-key holder, not its claimed Noise identity")
    @MainActor
    func verificationModelAttributesHybridQRToSigningKeyHolder() throws {
        let keychain = MockKeychain()
        let identityManager = SecureIdentityStateManager(keychain)
        let peerIdentityStore = PeerIdentityStore(keychain: keychain)
        let viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identityManager,
            transport: MockTransport(),
            peerIdentityStore: peerIdentityStore,
            locationManager: makeArchitectureLocationManager()
        )
        VerificationService.shared.configure(with: viewModel.meshService)
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: PrivateConversationModel(
                chatViewModel: viewModel,
                conversations: viewModel.conversations,
                locationChannelsModel: LocationChannelsModel(
                    manager: makeArchitectureLocationManager()
                )
            ),
            peerIdentityStore: peerIdentityStore
        )

        let victim = MockTransport()
        let attacker = MockTransport()
        let victimNoiseKey = victim.noiseStaticPublicKeyData()
        let victimFingerprint = victimNoiseKey.sha256Fingerprint()
        let attackerSigningKey = attacker.noiseSigningPublicKeyData()
        let keyHolderFingerprint = Data(repeating: 0xA7, count: 32)
            .sha256Fingerprint()
        identityManager.bindAuthenticatedSigningPublicKey(
            victim.noiseSigningPublicKeyData(),
            fingerprint: victimFingerprint
        )
        identityManager.bindAuthenticatedSigningPublicKey(
            attackerSigningKey,
            fingerprint: keyHolderFingerprint
        )

        var hybridQR = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: victimNoiseKey.hexEncodedString(),
            signKeyHex: attackerSigningKey.hexEncodedString(),
            npub: nil,
            nickname: "Alice",
            ts: Int64(Date().timeIntervalSince1970),
            nonceB64: Data((0..<16).map(UInt8.init)).base64EncodedString(),
            sigHex: ""
        )
        hybridQR.sigHex = try #require(
            attacker.noiseSignData(hybridQR.canonicalBytes())
        ).hexEncodedString()

        let outcome = verificationModel.verifyScannedPayload(
            hybridQR.toURLString()
        )
        guard case .candidate(let candidate) = outcome else {
            Issue.record("Expected the self-consistent hybrid QR to pass scan validation")
            return
        }

        #expect(candidate.fingerprint == victimFingerprint)
        #expect(
            peerIdentityStore.identityConflicts[keyHolderFingerprint]?.reason
                == .qrIdentityBindingMismatch
        )
        #expect(
            peerIdentityStore.identityLockState(
                fingerprint: keyHolderFingerprint
            ) == .identityMismatch
        )
        #expect(peerIdentityStore.identityConflicts[victimFingerprint] == nil)
        #expect(
            peerIdentityStore.identityLockState(fingerprint: victimFingerprint)
                == .unverified
        )
    }

    @Test("QR friend addition rechecks a newly pinned signing key")
    @MainActor
    func verificationModelRejectsCandidateWhenSigningPinChangesBeforeAdd() throws {
        let viewModel = makeArchitectureViewModel()
        VerificationService.shared.configure(with: viewModel.meshService)
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: PrivateConversationModel(
                chatViewModel: viewModel,
                conversations: viewModel.conversations,
                locationChannelsModel: LocationChannelsModel(
                    manager: makeArchitectureLocationManager()
                )
            )
        )

        let friendTransport = MockTransport()
        let friendQRService = VerificationService()
        friendQRService.configure(with: friendTransport)
        let payload = try #require(
            friendQRService.buildMyQRString(nickname: "Alice", npub: nil)
        )
        guard case .candidate(let candidate) = verificationModel.verifyScannedPayload(payload) else {
            Issue.record("Expected a signed QR to produce a confirmation candidate")
            return
        }

        let noiseKey = friendTransport.mockNoiseService.getStaticPublicKeyData()
        viewModel.identityManager.bindAuthenticatedSigningPublicKey(
            Data(repeating: 0xA5, count: 32),
            fingerprint: candidate.fingerprint
        )

        #expect(!verificationModel.addFriendFromCandidate())
        #expect(verificationModel.friendVerificationState == .failed(.signingKeyMismatch))
        #expect(!FavoritesPersistenceService.shared.isFavorite(noiseKey))
    }

    @Test("VerificationModel rejects scanning this device's own QR")
    @MainActor
    func verificationModelRejectsOwnQR() throws {
        let viewModel = makeArchitectureViewModel()
        VerificationService.shared.configure(with: viewModel.meshService)
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: makeArchitectureLocationManager())
        )
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel
        )
        let payload = try #require(
            VerificationService.shared.buildMyQRString(nickname: "Me", npub: nil)
        )

        #expect(verificationModel.verifyScannedPayload(payload) == .rejected(.selfIdentity))
        #expect(verificationModel.friendCandidate == nil)
        #expect(verificationModel.friendVerificationState == .failed(.selfIdentity))
    }

    @Test("VerificationModel refreshes when peer trust changes (vouch accepted)")
    @MainActor
    func verificationModelRefreshesOnPeerTrustChange() async {
        let viewModel = makeArchitectureViewModel()
        var privateConversationModel: PrivateConversationModel? = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: makeArchitectureLocationManager())
        )
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel!
        )

        // PrivateConversationModel happens to observe the same notification
        // and re-assign its published selection, which would ripple into
        // VerificationModel; release it so this test pins VerificationModel's
        // own subscription rather than that incidental chain.
        privateConversationModel = nil

        // The bound @Published sources replay their current values on
        // subscription; let those initial main-queue emissions settle so the
        // sink below observes only the trust-change signal.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // ChatVouchCoordinator.notifyPeerTrustChanged() signals accepted
        // vouches via "peerStatusUpdated"; an open fingerprint sheet must
        // re-render its vouched badge from that signal alone.
        var refreshed = false
        let cancellable = verificationModel.objectWillChange.sink { _ in
            refreshed = true
        }
        defer { cancellable.cancel() }

        NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
        await waitUntil { refreshed }
        #expect(refreshed)
    }

    @Test("PeerListModel publishes mesh and geohash directory state")
    @MainActor
    func peerListModelPublishesDirectoryState() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }

        let myPeerID = PeerID(str: "me-peer")
        let otherPeerID = PeerID(str: "0011223344556677")
        let geohash = "9q8yy"
        let remoteGeoID = String(repeating: "b", count: 64)
        let locationManager = makeArchitectureLocationManager()
        let locationChannelsModel = LocationChannelsModel(manager: locationManager)
        let otherNoiseKey = Data((0..<32).map(UInt8.init))
        let verifiedFingerprint = otherNoiseKey.sha256Fingerprint()

        transport.myPeerID = myPeerID
        transport.peerFingerprints[otherPeerID] = verifiedFingerprint
        transport.peerNicknames[otherPeerID] = "alice"
        transport.reachablePeers.insert(otherPeerID)
        viewModel.nickname = "builder"
        viewModel.verifiedFingerprints.insert(verifiedFingerprint)
        viewModel.markPrivateChatUnread(otherPeerID)
        transport.updatePeerSnapshots([
            makeArchitectureSnapshot(
                peerID: myPeerID,
                nickname: "builder",
                connected: true,
                noisePublicKey: Data(repeating: 0, count: 32)
            ),
            makeArchitectureSnapshot(
                peerID: otherPeerID,
                nickname: "alice",
                connected: false,
                noisePublicKey: otherNoiseKey
            )
        ])

        locationManager.select(.location(GeohashChannel(level: .city, geohash: geohash)))
        await waitUntil {
            if case .location(let channel) = locationManager.selectedChannel {
                return channel.geohash == geohash && !viewModel.allPeers.isEmpty
            }
            return false
        }

        viewModel.participantTracker.setActiveGeohash(geohash)
        viewModel.teleportedGeo = Set([remoteGeoID])
        viewModel.participantTracker.recordParticipant(pubkeyHex: remoteGeoID, geohash: geohash)
        if let myGeoID = try? viewModel.idBridge.deriveIdentity(forGeohash: geohash).publicKeyHex.lowercased() {
            viewModel.participantTracker.recordParticipant(pubkeyHex: myGeoID, geohash: geohash)
        }

        let peerListModel = PeerListModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )

        await waitUntil {
            peerListModel.reachableMeshPeerCount == 1 &&
            peerListModel.connectedMeshPeerCount == 0 &&
            peerListModel.meshRows.contains(where: { $0.peerID == otherPeerID && $0.hasUnread }) &&
            peerListModel.geohashPeople.contains(where: { $0.id == remoteGeoID && $0.isTeleported })
        }

        let meshRow = peerListModel.meshRows.first(where: { $0.peerID == otherPeerID })
        #expect(peerListModel.reachableMeshPeerCount == 1)
        #expect(peerListModel.connectedMeshPeerCount == 0)
        #expect(meshRow?.displayName == "alice")
        #expect(meshRow?.showsVerifiedBadgeWhenOffline == true)
        #expect(meshRow?.identityLockState == .verified)
        #expect(meshRow?.hasUnread == true)
        #expect(peerListModel.visibleGeohashPeerCount >= 1)
        #expect(peerListModel.participantCount(for: geohash) >= 1)
        #expect(peerListModel.geohashPeople.contains(where: { $0.id == remoteGeoID && $0.isTeleported }))

        viewModel.participantTracker.clear()
        viewModel.teleportedGeo = []
        locationManager.markTeleported(for: geohash, false)
        locationManager.select(ChannelID.mesh)
        await waitUntil {
            if case ChannelID.mesh = locationManager.selectedChannel {
                return true
            }
            return false
        }
    }

    @Test("PeerListModel hides vouch badge during identity mismatch")
    @MainActor
    func peerListModelSuppressesConflictedVouchBadge() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }
        let myPeerID = PeerID(str: "me-peer")
        let peerID = PeerID(str: "0011223344556677")
        let noiseKey = Data(repeating: 0xA1, count: 32)
        let fingerprint = noiseKey.sha256Fingerprint()

        transport.myPeerID = myPeerID
        transport.peerFingerprints[peerID] = fingerprint
        transport.peerNicknames[peerID] = "Alice"
        _ = viewModel.identityManager.recordVouch(
            voucheeFingerprint: fingerprint,
            voucherFingerprint: "voucher-fingerprint",
            timestamp: Date()
        )
        transport.updatePeerSnapshots([
            makeArchitectureSnapshot(
                peerID: myPeerID,
                nickname: "Me",
                connected: true,
                noisePublicKey: Data(repeating: 0, count: 32)
            ),
            makeArchitectureSnapshot(
                peerID: peerID,
                nickname: "Alice",
                connected: true,
                noisePublicKey: noiseKey
            )
        ])

        let model = PeerListModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(
                manager: makeArchitectureLocationManager()
            )
        )
        await waitUntil {
            model.meshRows.first(where: { $0.peerID == peerID })?
                .showsVouchedBadge == true
        }
        #expect(
            model.meshRows.first(where: { $0.peerID == peerID })?
                .showsVouchedBadge == true
        )

        viewModel.peerIdentityStore.recordIdentityConflict(
            forFingerprint: fingerprint,
            reason: .authenticatedSigningKeyMismatch
        )
        await waitUntil {
            guard let row = model.meshRows.first(where: { $0.peerID == peerID }) else {
                return false
            }
            return row.identityLockState == .identityMismatch
                && !row.showsVouchedBadge
        }

        let conflictedRow = model.meshRows.first(where: { $0.peerID == peerID })
        #expect(conflictedRow?.identityLockState == .identityMismatch)
        #expect(conflictedRow?.showsVouchedBadge == false)
    }

    @Test("PeerListModel publishes deduplicated offline non-friend recents by last message")
    @MainActor
    func peerListModelPublishesOfflineRecentConversations() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }
        let locationChannelsModel = LocationChannelsModel(manager: makeArchitectureLocationManager())
        let model = PeerListModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )
        let aliceNoiseKey = Data(repeating: 0xA1, count: 32)
        let bobNoiseKey = Data(repeating: 0xB2, count: 32)
        let aliceShortID = PeerID(publicKey: aliceNoiseKey)
        let aliceStableID = PeerID(hexData: aliceNoiseKey)
        let bobStableID = PeerID(hexData: bobNoiseKey)
        let aliceFingerprint = aliceNoiseKey.sha256Fingerprint()
        let bobFingerprint = bobNoiseKey.sha256Fingerprint()

        viewModel.identityManager.upsertCryptographicIdentity(
            fingerprint: aliceFingerprint,
            noisePublicKey: aliceNoiseKey,
            signingPublicKey: nil,
            claimedNickname: "Alice"
        )
        viewModel.identityManager.upsertCryptographicIdentity(
            fingerprint: bobFingerprint,
            noisePublicKey: bobNoiseKey,
            signingPublicKey: nil,
            claimedNickname: "Bob"
        )
        viewModel.peerIdentityStore.setStablePeerID(
            aliceStableID,
            forShortID: aliceShortID
        )
        #expect(viewModel.getFingerprint(for: aliceStableID) == aliceFingerprint)
        #expect(viewModel.getFingerprint(for: aliceShortID) == nil)
        viewModel.identityManager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: aliceFingerprint,
                localPetname: "Neighbor",
                claimedNickname: "Alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )

        viewModel.conversations.append(
            makeArchitectureMessage(
                id: "alice-short",
                timestamp: 10,
                isPrivate: true,
                senderPeerID: aliceShortID
            ),
            to: .directPeer(aliceShortID)
        )
        viewModel.conversations.append(
            makeArchitectureMessage(
                id: "alice-short-older-alias-extra",
                timestamp: 11,
                isPrivate: true,
                senderPeerID: aliceShortID
            ),
            to: .directPeer(aliceShortID)
        )
        viewModel.conversations.append(
            makeArchitectureMessage(
                id: "bob-stable",
                timestamp: 20,
                isPrivate: true,
                senderPeerID: bobStableID
            ),
            to: .directPeer(bobStableID)
        )
        viewModel.conversations.append(
            makeArchitectureMessage(
                id: "alice-stable",
                timestamp: 30,
                isPrivate: true,
                senderPeerID: aliceStableID
            ),
            to: .directPeer(aliceStableID)
        )
        viewModel.conversations.markUnread(.directPeer(aliceStableID))

        // Empty selections and non-mesh direct timelines never become Recents.
        viewModel.conversations.setSelectedPrivatePeer(PeerID(publicKey: Data(repeating: 0xC3, count: 32)))
        let groupID = PeerID(groupID: Data(repeating: 0xD4, count: 16))
        viewModel.conversations.append(
            makeArchitectureMessage(id: "group", timestamp: 40, isPrivate: true, senderPeerID: groupID),
            to: .directPeer(groupID)
        )
        let geoID = PeerID(nostr_: String(repeating: "e", count: 64))
        viewModel.conversations.append(
            makeArchitectureMessage(id: "geo", timestamp: 50, isPrivate: true, senderPeerID: geoID),
            to: .directPeer(geoID)
        )
        let selfStableID = PeerID(hexData: transport.noiseStaticPublicKeyData())
        viewModel.conversations.append(
            makeArchitectureMessage(id: "self", timestamp: 60, isPrivate: true, senderPeerID: transport.myPeerID),
            to: .directPeer(selfStableID)
        )
        let systemOnlyPeer = PeerID(hexData: Data(repeating: 0xE5, count: 32))
        viewModel.conversations.append(
            BitchatMessage(
                id: "system-only",
                sender: "system",
                content: "local status",
                timestamp: Date(timeIntervalSince1970: 70),
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: nil,
                senderPeerID: systemOnlyPeer
            ),
            to: .directPeer(systemOnlyPeer)
        )

        await waitUntil {
            model.recentMeshRows.count == 2
                && model.recentMeshRows.first?.lastMessageAt
                    == Date(timeIntervalSince1970: 30)
                && model.recentMeshRows.first?.hasUnread == true
        }

        #expect(model.recentMeshRows.map(\.fingerprint) == [aliceFingerprint, bobFingerprint])
        #expect(model.recentMeshRows.map(\.lastMessageAt) == [
            Date(timeIntervalSince1970: 30),
            Date(timeIntervalSince1970: 20)
        ])
        #expect(model.recentMeshRows.first?.displayName == "Neighbor")
        #expect(model.recentMeshRows.first?.claimedNickname == "Alice")
        #expect(model.recentMeshRows.first?.conversationPeerID == aliceStableID)
        #expect(Set(model.recentMeshRows.first?.conversationPeerIDs ?? []) == [
            aliceShortID,
            aliceStableID
        ])
        #expect(model.recentMeshRows.first?.hasUnread == true)
        #expect(model.recentMeshRows.first?.identityLockState == .unverified)

        viewModel.peerIdentityStore.setVerified(
            aliceFingerprint,
            verified: true
        )
        await waitUntil {
            model.recentMeshRows.first?.identityLockState == .verified
        }
        #expect(model.recentMeshRows.first?.identityLockState == .verified)

        viewModel.peerIdentityStore.recordIdentityConflict(
            forFingerprint: aliceFingerprint,
            reason: .authenticatedSigningKeyMismatch
        )
        await waitUntil {
            model.recentMeshRows.first?.identityLockState == .identityMismatch
        }
        #expect(
            model.recentMeshRows.first?.identityLockState
                == .identityMismatch
        )
        viewModel.peerIdentityStore.setVerified(
            aliceFingerprint,
            verified: false
        )
        viewModel.peerIdentityStore.setVerified(
            aliceFingerprint,
            verified: true
        )
        await waitUntil {
            model.recentMeshRows.first?.identityLockState == .identityMismatch
        }

        if let aliceRecent = model.recentMeshRows.first {
            #expect(model.prepareRecentConversationForOpening(aliceRecent) == aliceStableID)
        }
        await waitUntil {
            viewModel.conversations.conversationsByID[.directPeer(aliceShortID)] == nil
                && viewModel.conversations.conversationsByID[.directPeer(aliceStableID)]?
                    .messages.count == 3
        }
        #expect(
            viewModel.conversations.conversationsByID[.directPeer(aliceStableID)]?
                .messages.map(\.id) == [
                    "alice-short",
                    "alice-short-older-alias-extra",
                    "alice-stable"
                ]
        )
        viewModel.conversations.markRead(.directPeer(aliceStableID))
        await waitUntil { model.recentMeshRows.first?.hasUnread == false }
        #expect(model.recentMeshRows.first?.hasUnread == false)

        transport.updatePeerSnapshots([
            makeArchitectureSnapshot(
                peerID: PeerID(publicKey: bobNoiseKey),
                nickname: "Bob",
                connected: true,
                noisePublicKey: bobNoiseKey
            )
        ])
        await waitUntil { model.recentMeshRows.map(\.fingerprint) == [aliceFingerprint] }
        #expect(model.recentMeshRows.map(\.fingerprint) == [aliceFingerprint])
    }

    @Test("An offline Recent can be added as a friend without a live peer row")
    @MainActor
    func peerListModelAddsOfflineRecentAsFriend() async throws {
        let viewModel = makeArchitectureViewModel()
        let model = PeerListModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: makeArchitectureLocationManager())
        )
        let noiseKey = Data(repeating: 0xC7, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()
        defer {
            _ = FavoritesPersistenceService.shared.removeFavorite(
                peerNoisePublicKey: noiseKey
            )
        }

        viewModel.identityManager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noiseKey,
            signingPublicKey: nil,
            claimedNickname: "Casey"
        )
        viewModel.conversations.append(
            makeArchitectureMessage(
                id: "casey-dm",
                timestamp: 100,
                isPrivate: true,
                senderPeerID: stablePeerID
            ),
            to: .directPeer(stablePeerID)
        )
        await waitUntil { model.recentMeshRows.count == 1 }
        let recent = try #require(model.recentMeshRows.first)

        #expect(model.addFriend(recentPeer: recent))
        await waitUntil { model.recentMeshRows.isEmpty }

        #expect(FavoritesPersistenceService.shared.isFavorite(noiseKey))
        #expect(model.recentMeshRows.isEmpty)
        #expect(viewModel.identityManager.getSocialIdentity(for: fingerprint)?.isFavorite == true)
        #expect(!viewModel.peerIdentityStore.isVerified(fingerprint))
    }
}
