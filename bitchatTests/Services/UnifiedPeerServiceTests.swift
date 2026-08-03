//
// UnifiedPeerServiceTests.swift
// bitchatTests
//
// Tests for UnifiedPeerService fingerprint and block resolution.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct UnifiedPeerServiceTests {

    @Test @MainActor
    func getFingerprint_prefersMeshService() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        let peerID = PeerID(str: "00000000000000CC")
        transport.peerFingerprints[peerID] = "fp-1"

        let fingerprint = service.getFingerprint(for: peerID)

        #expect(fingerprint == "fp-1")
    }

    @Test @MainActor
    func fullNoiseFingerprintLookupDoesNotOverwriteAuthenticatedShortBinding() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity
        )
        let noiseKey = Data(repeating: 0x6A, count: 32)
        let shortPeerID = PeerID(publicKey: noiseKey)
        let fullPeerID = PeerID(hexData: noiseKey)
        let authenticatedShortFingerprint = "authenticated-short-binding"
        transport.peerFingerprints[shortPeerID] = authenticatedShortFingerprint

        #expect(service.getFingerprint(for: shortPeerID) == authenticatedShortFingerprint)
        #expect(service.getFingerprint(for: fullPeerID) == noiseKey.sha256Fingerprint())
        #expect(service.getFingerprint(for: shortPeerID) == authenticatedShortFingerprint)
    }

    @Test @MainActor
    func isBlocked_usesSocialIdentity() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        let peerID = PeerID(str: "00000000000000DD")
        let fingerprint = "fp-blocked"
        transport.peerFingerprints[peerID] = fingerprint
        identity.setBlocked(fingerprint, isBlocked: true)

        #expect(service.isBlocked(peerID))
    }

    @Test @MainActor
    func setBlocked_persistsByFingerprintAndToggles() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        let peerID = PeerID(str: "00000000000000EE")
        let fingerprint = "fp-target"
        transport.peerFingerprints[peerID] = fingerprint

        // Blocking resolves and persists by the peer's fingerprint, and
        // scrubs the peer's carried public messages from the gossip archive
        // while the fingerprint↔peerID mapping is still known (the
        // archived-echo seed filter can't resolve offline strangers).
        let resolved = service.setBlocked(peerID, blocked: true)
        #expect(resolved == fingerprint)
        #expect(identity.isBlocked(fingerprint: fingerprint))
        #expect(service.isBlocked(peerID))
        #expect(transport.purgedArchivePeers == [peerID])

        // Unblocking clears it against the same identity, without purging.
        let unresolved = service.setBlocked(peerID, blocked: false)
        #expect(unresolved == fingerprint)
        #expect(!identity.isBlocked(fingerprint: fingerprint))
        #expect(!service.isBlocked(peerID))
        #expect(transport.purgedArchivePeers == [peerID])
    }

    // MARK: - Offline-favorite dedup (updatePeers phase 2)

    /// A mutual favorite that is also on the mesh must collapse to a single
    /// row keyed by the short mesh ID — even when the announced nickname no
    /// longer matches the one stored with the favorite.
    @Test @MainActor
    func updatePeers_mutualFavoriteOnMeshYieldsSingleRow() async {
        let favoritesService = FavoritesPersistenceService.shared

        let transport = MockTransport()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: TestIdentityManager())

        let noiseKey = Data(repeating: 0xAB, count: 32)
        favoritesService.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "alice")
        favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        defer {
            favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: false)
            favoritesService.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        let meshID = PeerID(publicKey: noiseKey)
        let snapshots = [TransportPeerSnapshot(
            peerID: meshID,
            nickname: "alice-renamed",
            isConnected: true,
            noisePublicKey: noiseKey,
            lastSeen: Date()
        )]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let rows = service.peers.filter { $0.noisePublicKey == noiseKey }
        #expect(rows.count == 1)
        #expect(rows.first?.peerID == meshID)
        #expect(rows.first?.isMutualFavorite == true)
        #expect(service.favorites.filter { $0.noisePublicKey == noiseKey }.count == 1)
    }

    /// Same collapse must hold for a reachable-but-not-connected favorite
    /// (relayed peers linger as "reachable" after their link drops).
    @Test @MainActor
    func updatePeers_reachableMutualFavoriteYieldsSingleRow() async {
        let favoritesService = FavoritesPersistenceService.shared

        let transport = MockTransport()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: TestIdentityManager())

        let noiseKey = Data(repeating: 0xCD, count: 32)
        favoritesService.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "bob")
        favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        defer {
            favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: false)
            favoritesService.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        let otherKey = Data(repeating: 0x11, count: 32)
        let snapshots = [
            // A live link is required for anyone to count as reachable.
            TransportPeerSnapshot(
                peerID: PeerID(publicKey: otherKey),
                nickname: "carol",
                isConnected: true,
                noisePublicKey: otherKey,
                lastSeen: Date()
            ),
            TransportPeerSnapshot(
                peerID: PeerID(publicKey: noiseKey),
                nickname: "bob",
                isConnected: false,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let bobRows = service.peers.filter { $0.noisePublicKey == noiseKey }
        #expect(bobRows.count == 1)
        #expect(bobRows.first?.peerID == PeerID(publicKey: noiseKey))
        #expect(bobRows.first?.isReachable == true)
    }

    /// A mutual favorite with no mesh presence still gets its offline row,
    /// keyed by the full noise-key PeerID.
    @Test @MainActor
    func updatePeers_offlineMutualFavoriteGetsOfflineRow() async {
        let favoritesService = FavoritesPersistenceService.shared

        let transport = MockTransport()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: TestIdentityManager())

        let noiseKey = Data(repeating: 0xEF, count: 32)
        favoritesService.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "dave")
        favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        defer {
            favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: false)
            favoritesService.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        transport.updatePeerSnapshots([])
        service.didUpdatePeerSnapshots([])

        let rows = service.peers.filter { $0.noisePublicKey == noiseKey }
        #expect(rows.count == 1)
        #expect(rows.first?.peerID == PeerID(hexData: noiseKey))
        #expect(rows.first?.isMutualFavorite == true)
    }

    @Test @MainActor
    func updatePeers_offlineOneWayFriendRemainsVisible() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xD1, count: 32)
        favoritesService.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "One Way"
        )

        transport.updatePeerSnapshots([])
        service.didUpdatePeerSnapshots([])

        let row = service.peers.first { $0.noisePublicKey == noiseKey }
        #expect(row?.peerID == PeerID(hexData: noiseKey))
        #expect(row?.isFavorite == true)
        #expect(row?.isMutualFavorite == false)
        #expect(row?.connectionState == .offline)
    }

    @Test @MainActor
    func connectedFriendRefreshesNostrIdentityOnlyOncePerSession() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: TestIdentityManager(),
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xD3, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        favoritesService.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "Alice"
        )
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]

        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        #expect(transport.sentFavoriteNotifications.count == 1)
        #expect(transport.sentFavoriteNotifications.first?.peerID == peerID)
        #expect(transport.sentFavoriteNotifications.first?.isFavorite == true)
    }

    @Test @MainActor
    func addFriend_savesContactWithoutPinningOrVerifyingIdentity() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xC4, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()
        identity.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: "Neighbor",
                claimedNickname: "Alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let result = service.addFriend(peerID)

        #expect(result == FriendPersistenceOutcome(displayName: "Neighbor", wasAdded: true))
        #expect(favoritesService.isFavorite(noiseKey))
        #expect(identity.getSocialIdentity(for: fingerprint)?.isFavorite == true)
        #expect(identity.getSocialIdentity(for: fingerprint)?.localPetname == "Neighbor")
        #expect(identity.signingPublicKey(forFingerprint: fingerprint) == nil)
        #expect(!identity.isVerified(fingerprint: fingerprint))
        #expect(transport.sentFavoriteNotifications.count == 1)
    }

    @Test @MainActor
    func addFriend_savesOptionalLocalPetnameAndRejectsInvalidInputBeforePersistence() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let validNoiseKey = Data(repeating: 0xC5, count: 32)
        let invalidNoiseKey = Data(repeating: 0xC6, count: 32)
        let validPeerID = PeerID(publicKey: validNoiseKey)
        let invalidPeerID = PeerID(publicKey: invalidNoiseKey)
        let snapshots = [
            TransportPeerSnapshot(
                peerID: validPeerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: validNoiseKey,
                lastSeen: Date()
            ),
            TransportPeerSnapshot(
                peerID: invalidPeerID,
                nickname: "Mallory",
                isConnected: true,
                noisePublicKey: invalidNoiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let added = service.addFriend(
            validPeerID,
            localPetname: "  Trail Buddy  "
        )
        let rejected = service.addFriend(
            invalidPeerID,
            localPetname: "bad\u{0007}name"
        )

        #expect(
            added == FriendPersistenceOutcome(
                displayName: "Trail Buddy",
                wasAdded: true
            )
        )
        #expect(
            identity.getSocialIdentity(
                for: validNoiseKey.sha256Fingerprint()
            )?.localPetname == "Trail Buddy"
        )
        #expect(favoritesService.isFavorite(validNoiseKey))
        #expect(rejected == nil)
        #expect(!favoritesService.isFavorite(invalidNoiseKey))
        #expect(
            identity.getSocialIdentity(
                for: invalidNoiseKey.sha256Fingerprint()
            ) == nil
        )
    }

    @Test @MainActor
    func addFriend_isIdempotentAndKeepsLocalPetnameSeparate() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xD2, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)
        identity.updateSocialIdentity(
            SocialIdentity(
                fingerprint: noiseKey.sha256Fingerprint(),
                localPetname: "Bestie",
                claimedNickname: "Alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )

        let first = service.addFriend(
            noisePublicKey: noiseKey,
            nostrPublicKey: "npub1alice",
            claimedNickname: "Alice"
        )
        let second = service.addFriend(
            noisePublicKey: noiseKey,
            nostrPublicKey: "npub1alice",
            claimedNickname: "Alice"
        )

        #expect(first == FriendPersistenceOutcome(displayName: "Bestie", wasAdded: true))
        #expect(second == FriendPersistenceOutcome(displayName: "Bestie", wasAdded: false))
        #expect(favoritesService.isFavorite(noiseKey))
        #expect(favoritesService.getFavoriteStatus(for: noiseKey)?.peerNickname == "Alice")
        #expect(identity.getSocialIdentity(for: noiseKey.sha256Fingerprint())?.localPetname == "Bestie")
        #expect(identity.pinnedSigningKey(for: noiseKey.sha256Fingerprint()) == nil)
        #expect(identity.cryptoUpsertCount == 0)
        #expect(transport.sentFavoriteNotifications.count == 1)
        #expect(transport.sentFavoriteNotifications.first?.peerID == peerID)
        #expect(transport.sentFavoriteNotifications.first?.isFavorite == true)
    }

    @Test @MainActor
    func addFriend_acceptsBitchatWireNicknameBeyondLocalInputLimit() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xB1, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let protocolNickname = String(repeating: "n", count: InputValidator.Limits.maxNicknameLength + 1)
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: protocolNickname,
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let result = service.addFriend(
            noisePublicKey: noiseKey,
            nostrPublicKey: nil,
            claimedNickname: protocolNickname
        )

        #expect(result == FriendPersistenceOutcome(displayName: protocolNickname, wasAdded: true))
        #expect(favoritesService.getFavoriteStatus(for: noiseKey)?.peerNickname == protocolNickname)
        #expect(identity.getSocialIdentity(for: noiseKey.sha256Fingerprint())?.claimedNickname == protocolNickname)
    }

    @Test @MainActor
    func addFriend_rejectsBlockedIdentity() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xD4, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Mallory",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let fingerprint = noiseKey.sha256Fingerprint()
        identity.setBlocked(fingerprint, isBlocked: true)
        let blocked = service.addFriend(
            noisePublicKey: noiseKey,
            nostrPublicKey: nil,
            claimedNickname: "Mallory"
        )
        #expect(blocked == nil)
        #expect(!favoritesService.isFavorite(noiseKey))
        #expect(transport.sentFavoriteNotifications.isEmpty)
    }

    @Test @MainActor
    func validatedQRRefreshesExistingFriendNostrRouteWithoutPriorKeyBinding() async throws {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xA4, count: 32)
        let signingKey = Data(repeating: 0xB4, count: 32)
        let npub = try Bech32.encode(
            hrp: "npub",
            data: Data(repeating: 0xC4, count: 32)
        )
        favoritesService.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "Alice"
        )
        #expect(
            service.refreshFriendNostrRouteFromValidatedQR(
                noisePublicKey: noiseKey,
                signingPublicKey: signingKey,
                nostrPublicKey: npub
            )
        )
        #expect(
            favoritesService.getFavoriteStatus(for: noiseKey)?.peerNostrPublicKey
                == npub
        )
        #expect(
            favoritesService.getFavoriteStatus(for: noiseKey)?.peerNickname
                == "Alice"
        )
    }

    @Test @MainActor
    func QRWithPinnedSigningKeyMismatchDoesNotChangeExistingFriendNostrRoute() async throws {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xA5, count: 32)
        let authenticatedSigningKey = Data(repeating: 0xB5, count: 32)
        let scannedSigningKey = Data(repeating: 0xB6, count: 32)
        let npub = try Bech32.encode(
            hrp: "npub",
            data: Data(repeating: 0xC5, count: 32)
        )
        favoritesService.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "Alice"
        )
        identity.bindAuthenticatedSigningPublicKey(
            authenticatedSigningKey,
            fingerprint: noiseKey.sha256Fingerprint()
        )

        #expect(
            !service.refreshFriendNostrRouteFromValidatedQR(
                noisePublicKey: noiseKey,
                signingPublicKey: scannedSigningKey,
                nostrPublicKey: npub
            )
        )
        #expect(
            favoritesService.getFavoriteStatus(for: noiseKey)?.peerNostrPublicKey
                == nil
        )
    }

    @Test @MainActor
    func addFriend_rejectsDurableFavoriteFailureBeforeIdentityOrNotification() async {
        let keychain = MockKeychain()
        keychain.shouldFailGenericSave = true
        let favoritesService = FavoritesPersistenceService(keychain: keychain)
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xD5, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let result = service.addFriend(
            noisePublicKey: noiseKey,
            nostrPublicKey: nil,
            claimedNickname: "Alice"
        )

        #expect(result == nil)
        #expect(!favoritesService.isFavorite(noiseKey))
        #expect(identity.cryptoUpsertCount == 0)
        #expect(identity.getSocialIdentity(for: noiseKey.sha256Fingerprint()) == nil)
        #expect(transport.sentFavoriteNotifications.isEmpty)
    }

    @Test @MainActor
    func addFriend_rollsBackNewFavoriteWhenSocialPersistenceFails() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        identity.shouldFailSocialPersistence = true
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xE1, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let result = service.addFriend(
            noisePublicKey: noiseKey,
            nostrPublicKey: nil,
            claimedNickname: "Alice"
        )

        #expect(result == nil)
        #expect(!favoritesService.isFavorite(noiseKey))
        #expect(identity.cryptoUpsertCount == 0)
        #expect(identity.getSocialIdentity(for: noiseKey.sha256Fingerprint()) == nil)
        #expect(transport.sentFavoriteNotifications.isEmpty)
    }

    @Test @MainActor
    func removeFriend_isRemovalOnlyAndClearsLocalSocialState() async {
        let favoritesService = FavoritesPersistenceService(keychain: MockKeychain())
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let service = UnifiedPeerService(
            meshService: transport,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity,
            favoritesService: favoritesService
        )
        let noiseKey = Data(repeating: 0xD7, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let snapshots = [
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)
        favoritesService.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "Alice"
        )
        identity.updateSocialIdentity(
            SocialIdentity(
                fingerprint: noiseKey.sha256Fingerprint(),
                localPetname: "Bestie",
                claimedNickname: "Alice",
                trustLevel: .unknown,
                isFavorite: true,
                isBlocked: false,
                notes: nil
            )
        )

        #expect(service.removeFriend(peerID))
        #expect(service.removeFriend(peerID))
        #expect(!favoritesService.isFavorite(noiseKey))
        #expect(
            identity.getSocialIdentity(for: noiseKey.sha256Fingerprint())?.isFavorite == false
        )
        #expect(
            identity.getSocialIdentity(for: noiseKey.sha256Fingerprint())?.localPetname == "Bestie"
        )
        #expect(transport.sentFavoriteNotifications.count == 1)
        #expect(transport.sentFavoriteNotifications.first?.peerID == peerID)
        #expect(transport.sentFavoriteNotifications.first?.isFavorite == false)
    }

    @Test @MainActor
    func setBlocked_unknownIdentityReturnsNil() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        // No fingerprint resolvable for this peer (offline & unknown).
        let peerID = PeerID(str: "00000000000000FF")

        #expect(service.setBlocked(peerID, blocked: true) == nil)
        #expect(!service.isBlocked(peerID))
    }
}

private final class TestIdentityManager: SecureIdentityStateManagerProtocol {
    private var socialIdentities: [String: SocialIdentity] = [:]
    private var favorites: Set<String> = []
    private var blockedNostr: Set<String> = []
    private var verified: Set<String> = []
    private var pinnedSigningKeys: [String: Data] = [:]
    private(set) var cryptoUpsertCount = 0
    var shouldFailSocialPersistence = false

    func forceSave() {}

    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        socialIdentities[fingerprint]
    }

    func upsertCryptographicIdentity(
        fingerprint: String,
        noisePublicKey: Data,
        signingPublicKey: Data?,
        claimedNickname: String?
    ) {
        if let existing = pinnedSigningKeys[fingerprint],
           let signingPublicKey,
           existing != signingPublicKey {
            return
        }
        cryptoUpsertCount += 1
        if let signingPublicKey {
            pinnedSigningKeys[fingerprint] = signingPublicKey
        }
    }

    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] {
        []
    }

    func updateSocialIdentity(_ identity: SocialIdentity) {
        socialIdentities[identity.fingerprint] = identity
    }

    func persistSocialIdentity(_ identity: SocialIdentity) -> Bool {
        guard !shouldFailSocialPersistence else { return false }
        updateSocialIdentity(identity)
        return true
    }

    func isFavorite(fingerprint: String) -> Bool {
        favorites.contains(fingerprint)
    }

    func isBlocked(fingerprint: String) -> Bool {
        socialIdentities[fingerprint]?.isBlocked ?? false
    }

    func setBlocked(_ fingerprint: String, isBlocked: Bool) {
        var identity = socialIdentities[fingerprint] ?? SocialIdentity(
            fingerprint: fingerprint,
            localPetname: nil,
            claimedNickname: "",
            trustLevel: .unknown,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )
        identity.isBlocked = isBlocked
        socialIdentities[fingerprint] = identity
    }

    func getBlockedSocialIdentities() -> [SocialIdentity] {
        socialIdentities.values.filter(\.isBlocked)
    }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostr.contains(pubkeyHexLowercased)
    }

    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        if isBlocked {
            blockedNostr.insert(pubkeyHexLowercased)
        } else {
            blockedNostr.remove(pubkeyHexLowercased)
        }
    }

    func getBlockedNostrPubkeys() -> Set<String> {
        blockedNostr
    }

    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState) {}

    func clearAllIdentityData() {
        socialIdentities.removeAll()
        favorites.removeAll()
        blockedNostr.removeAll()
        verified.removeAll()
        pinnedSigningKeys.removeAll()
    }

    func markPrivateMediaCapable(fingerprint: String) {}
    func hasObservedPrivateMediaCapability(fingerprint: String) -> Bool { false }
    func bindAuthenticatedSigningPublicKey(_ signingPublicKey: Data, fingerprint: String) {
        pinnedSigningKeys[fingerprint] = signingPublicKey
    }
    func authenticatedSigningPublicKey(forFingerprint fingerprint: String) -> Data? {
        pinnedSigningKeys[fingerprint]
    }

    func pinnedSigningKey(for fingerprint: String) -> Data? {
        pinnedSigningKeys[fingerprint]
    }

    func removeEphemeralSession(peerID: PeerID) {}

    func setVerified(fingerprint: String, verified: Bool) {
        if verified {
            self.verified.insert(fingerprint)
        } else {
            self.verified.remove(fingerprint)
        }
    }

    func isVerified(fingerprint: String) -> Bool {
        verified.contains(fingerprint)
    }

    func getVerifiedFingerprints() -> Set<String> {
        verified
    }

    // MARK: Vouching (unused by these tests)

    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool {
        false
    }

    func validVouchers(for fingerprint: String) -> [VouchRecord] {
        []
    }

    func isVouched(fingerprint: String) -> Bool {
        false
    }

    func lastVouchBatchSent(to fingerprint: String) -> Date? {
        nil
    }

    func markVouchBatchSent(to fingerprint: String, at date: Date) {}

    func signingPublicKey(forFingerprint fingerprint: String) -> Data? {
        pinnedSigningKeys[fingerprint]
    }

    func mostRecentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String] {
        []
    }
}
