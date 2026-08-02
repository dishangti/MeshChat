//
//  UnifiedPeerService.swift
//  bitchat
//
//  Unified peer state management combining mesh connectivity and favorites
// SPDX-License-Identifier: MIT
//

import BitLogger
import BitFoundation
import Foundation
import Combine
import SwiftUI

/// Result of the idempotent, device-local "add friend" intent.
///
/// Friendship reuses the existing favorite relationship because that is the
/// relationship the routing stack already understands for offline delivery,
/// Nostr reachability, and courier selection. `wasAdded` lets callers avoid
/// sending duplicate social notifications when an already-saved friend is
/// added again.
struct FriendPersistenceOutcome: Equatable {
    let displayName: String
    let wasAdded: Bool
}

/// Single source of truth for peer state, combining mesh connectivity and favorites
@MainActor
final class UnifiedPeerService: ObservableObject, TransportPeerEventsDelegate {
    
    // MARK: - Published Properties
    
    @Published private(set) var peers: [BitchatPeer] = []
    @Published private(set) var connectedPeerIDs: Set<PeerID> = []
    @Published private(set) var favorites: [BitchatPeer] = []
    @Published private(set) var mutualFavorites: [BitchatPeer] = []
    
    // MARK: - Private Properties
    
    private var peerIndex: [PeerID: BitchatPeer] = [:]
    private var fingerprintCache: [PeerID: String] = [:]
    private let meshService: Transport
    private let idBridge: NostrIdentityBridge
    private let identityManager: SecureIdentityStateManagerProtocol
    weak var messageRouter: MessageRouter?
    private let favoritesService: FavoritesPersistenceService
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(
        meshService: Transport,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        favoritesService: FavoritesPersistenceService? = nil
    ) {
        self.meshService = meshService
        self.idBridge = idBridge
        self.identityManager = identityManager
        self.favoritesService = favoritesService ?? .shared
        
        // Subscribe to changes from both services
        setupSubscriptions()
        
        // Perform initial update
        Task { @MainActor in
            updatePeers()
        }
    }
    
    // MARK: - Setup
    
    private func setupSubscriptions() {
        // Subscribe to mesh peer updates via delegate (preferred over publishers)
        meshService.peerEventsDelegate = self
        
        // Also listen for favorite change notifications
        NotificationCenter.default.publisher(for: .favoriteStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePeers()
            }
            .store(in: &cancellables)
    }

    // TransportPeerEventsDelegate
    func didUpdatePeerSnapshots(_: [TransportPeerSnapshot]) {
        updatePeers()
    }
    
    // MARK: - Core Update Logic
    
    private func updatePeers() {
        let meshPeers = meshService.currentPeerSnapshots()
        // If we have no direct links at all, peers should not be marked reachable
        // "Reachable" means mesh-attached via at least one live link.
        let hasAnyConnected = meshPeers.contains { $0.isConnected }
        let favorites = favoritesService.favorites
        
        var enrichedPeers: [BitchatPeer] = []
        var connected: Set<PeerID> = []
        var addedPeerIDs: Set<PeerID> = []
        var meshNoiseKeys: Set<Data> = []

        // Phase 1: Add all mesh peers (connected and reachable)
        for peerInfo in meshPeers {
            let peerID = peerInfo.peerID
            guard peerID != meshService.myPeerID else { continue }  // Never add self

            let peer = buildPeerFromMesh(
                peerInfo: peerInfo,
                favorites: favorites,
                meshAttached: hasAnyConnected
            )

            enrichedPeers.append(peer)
            if peer.isConnected { connected.insert(peerID) }
            addedPeerIDs.insert(peerID)

            // Update fingerprint cache
            if let publicKey = peerInfo.noisePublicKey {
                meshNoiseKeys.insert(publicKey)
                fingerprintCache[peerID] = publicKey.sha256Fingerprint()
            }
        }

        // Phase 2: Add offline favorites that we actively favorite.
        // Mesh rows use the short 16-hex peer ID while favorites are keyed by
        // the full 32-byte noise key, so dedup must compare noise keys — a
        // PeerID comparison between the two forms can never match.
        for (favoriteKey, favorite) in favorites where favorite.isFavorite {
            if meshNoiseKeys.contains(favoriteKey) { continue }

            let peerID = PeerID(hexData: favoriteKey)
            if addedPeerIDs.contains(peerID) { continue }

            let peer = buildPeerFromFavorite(favorite: favorite, peerID: peerID)
            enrichedPeers.append(peer)
            addedPeerIDs.insert(peerID)

            // Update fingerprint cache
            fingerprintCache[peerID] = favoriteKey.sha256Fingerprint()
        }
        
        // Phase 3: Sort peers
        enrichedPeers.sort { lhs, rhs in
            // Connectivity rank: connected > reachable > others
            func rank(_ p: BitchatPeer) -> Int { p.isConnected ? 2 : (p.isReachable ? 1 : 0) }
            let lr = rank(lhs), rr = rank(rhs)
            if lr != rr { return lr > rr }
            // Then favorites inside same rank
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            // Finally alphabetical
            return lhs.displayName < rhs.displayName
        }
        
        // Phase 4: Build subsets and indices
        var favoritesList: [BitchatPeer] = []
        var mutualsList: [BitchatPeer] = []
        var newIndex: [PeerID: BitchatPeer] = [:]
        
        for peer in enrichedPeers {
            newIndex[peer.peerID] = peer
            
            if peer.isFavorite {
                favoritesList.append(peer)
            }
            if peer.isMutualFavorite {
                mutualsList.append(peer)
            }
        }
        
        // Phase 5: Keep every friend the local user explicitly saved. A
        // one-way favorite is still a contact and must remain visible while
        // offline; mutuality only controls Nostr availability, not whether the
        // person exists in the contact list.
        let filtered = enrichedPeers.filter { p in
            p.isConnected || p.isReachable || p.isFavorite
        }
        self.peers = filtered
        self.connectedPeerIDs = connected
        self.favorites = favoritesList
        self.mutualFavorites = mutualsList
        self.peerIndex = newIndex
        
        // Log summary (commented out to reduce noise)
        // let connectedCount = connected.count
        // let offlineCount = enrichedPeers.count - connectedCount
        // Peer update: \(enrichedPeers.count) total (\(connectedCount) connected, \(offlineCount) offline)
    }
    
    // MARK: - Peer Building Helpers
    
    private func buildPeerFromMesh(
        peerInfo: TransportPeerSnapshot,
        favorites: [Data: FavoritesPersistenceService.FavoriteRelationship],
        meshAttached: Bool
    ) -> BitchatPeer {
        // Determine reachability based on lastSeen and identity trust
        let now = Date()
        let fingerprint = peerInfo.noisePublicKey?.sha256Fingerprint()
        let isVerified = fingerprint.map { identityManager.isVerified(fingerprint: $0) } ?? false
        let isFav = peerInfo.noisePublicKey.flatMap { favorites[$0]?.isFavorite } ?? false
        let retention: TimeInterval = (isVerified || isFav) ? TransportConfig.bleReachabilityRetentionVerifiedSeconds : TransportConfig.bleReachabilityRetentionUnverifiedSeconds
        // A peer is reachable if we recently saw them AND we are attached to the mesh
        let withinRetention = now.timeIntervalSince(peerInfo.lastSeen) <= retention
        let isReachable = peerInfo.isConnected ? true : (withinRetention && meshAttached)

        var peer = BitchatPeer(
            peerID: peerInfo.peerID,
            noisePublicKey: peerInfo.noisePublicKey ?? Data(),
            nickname: peerInfo.nickname,
            lastSeen: peerInfo.lastSeen,
            isConnected: peerInfo.isConnected,
            isReachable: isReachable,
            localPetname: localPetname(forFingerprint: fingerprint)
        )
        
        // Check for favorite status
        if let noiseKey = peerInfo.noisePublicKey,
           let favoriteStatus = favorites[noiseKey] {
            peer.favoriteStatus = favoriteStatus
            peer.nostrPublicKey = favoriteStatus.peerNostrPublicKey
        }
        
        return peer
    }
    
    private func buildPeerFromFavorite(
        favorite: FavoritesPersistenceService.FavoriteRelationship,
        peerID: PeerID
    ) -> BitchatPeer {
        var peer = BitchatPeer(
            peerID: peerID,
            noisePublicKey: favorite.peerNoisePublicKey,
            nickname: favorite.peerNickname,
            lastSeen: favorite.lastUpdated,
            isConnected: false,
            isReachable: false,
            localPetname: localPetname(forFingerprint: favorite.peerNoisePublicKey.sha256Fingerprint())
        )
        
        peer.favoriteStatus = favorite
        peer.nostrPublicKey = favorite.peerNostrPublicKey
        
        return peer
    }
    
    /// Rebuild peer rows after a social-identity write (local alias, etc.) so
    /// display names update without waiting for a mesh event.
    func refreshPeers() {
        updatePeers()
    }

    private func localPetname(forFingerprint fingerprint: String?) -> String? {
        guard let fingerprint,
              let petname = identityManager.getSocialIdentity(for: fingerprint)?.localPetname,
              !petname.isEmpty else {
            return nil
        }
        return petname
    }

    // MARK: - Public Methods

    /// Saves a known mesh peer as a contact without changing verification
    /// state. The relationship remains explicitly unverified until the user
    /// completes a fingerprint or QR proof.
    @discardableResult
    func addFriend(_ peerID: PeerID) -> FriendPersistenceOutcome? {
        let resolvedPeer: BitchatPeer?
        if let noiseKey = peerID.noiseKey {
            let shortPeerID = PeerID(publicKey: noiseKey)
            resolvedPeer = getPeer(by: peerID) ?? getPeer(by: shortPeerID)
        } else {
            resolvedPeer = getPeer(by: peerID)
        }
        guard let peer = resolvedPeer,
              peer.noisePublicKey.count == 32 else {
            return nil
        }
        return addFriend(
            noisePublicKey: peer.noisePublicKey,
            nostrPublicKey: peer.nostrPublicKey,
            claimedNickname: peer.nickname
        )
    }

    /// Saves contact metadata obtained from a signed QR. This operation does
    /// not pin the QR signing key and does not mark the identity as verified.
    /// Callers are responsible for validating the signed QR at the action
    /// boundary.
    @discardableResult
    func addFriend(
        noisePublicKey: Data,
        nostrPublicKey: String?,
        claimedNickname: String
    ) -> FriendPersistenceOutcome? {
        guard noisePublicKey.count == 32,
              noisePublicKey != meshService.noiseStaticPublicKeyData(),
              let normalizedNickname = VerificationService.VerificationQR
                .normalizedProtocolNickname(claimedNickname) else {
            return nil
        }

        let fingerprint = noisePublicKey.sha256Fingerprint()
        guard !identityManager.isBlocked(fingerprint: fingerprint) else {
            return nil
        }

        let existingSocial = identityManager.getSocialIdentity(for: fingerprint)
        guard existingSocial?.isBlocked != true else { return nil }
        let wasAlreadyFriend = favoritesService.isFavorite(noisePublicKey)
        guard favoritesService.addFavorite(
            peerNoisePublicKey: noisePublicKey,
            peerNostrPublicKey: nostrPublicKey,
            peerNickname: normalizedNickname
        ) else {
            return nil
        }

        var social = existingSocial ?? SocialIdentity(
            fingerprint: fingerprint,
            localPetname: nil,
            claimedNickname: normalizedNickname,
            trustLevel: .unknown,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )
        social.claimedNickname = normalizedNickname
        social.isFavorite = true
        guard identityManager.persistSocialIdentity(social) else {
            if !wasAlreadyFriend {
                _ = favoritesService.removeFavorite(peerNoisePublicKey: noisePublicKey)
            }
            return nil
        }

        if !wasAlreadyFriend {
            let shortPeerID = PeerID(publicKey: noisePublicKey)
            if let messageRouter {
                messageRouter.sendFavoriteNotification(to: shortPeerID, isFavorite: true)
            } else {
                meshService.sendFavoriteNotification(to: shortPeerID, isFavorite: true)
            }
        }

        updatePeers()
        return FriendPersistenceOutcome(
            displayName: social.localPetname?.trimmedOrNilIfEmpty ?? normalizedNickname,
            wasAdded: !wasAlreadyFriend
        )
    }

    /// Persists the exact identity proven by the QR challenge-response without
    /// adding a friend. Friend and verification states deliberately remain
    /// independent.
    @discardableResult
    func persistVerifiedIdentity(
        peerID: PeerID,
        expectedNoisePublicKey: Data,
        signingPublicKey: Data,
        claimedNickname: String
    ) -> String? {
        guard expectedNoisePublicKey.count == 32,
              signingPublicKey.count == 32,
              expectedNoisePublicKey != meshService.noiseStaticPublicKeyData() else {
            return nil
        }

        let shortPeerID = PeerID(publicKey: expectedNoisePublicKey)
        guard peerID.toShort() == shortPeerID,
              let peer = getPeer(by: peerID) ?? getPeer(by: shortPeerID),
              peer.noisePublicKey == expectedNoisePublicKey else {
            return nil
        }

        let fingerprint = expectedNoisePublicKey.sha256Fingerprint()
        guard !identityManager.isBlocked(fingerprint: fingerprint) else {
            return nil
        }
        if let pinnedSigningPublicKey = identityManager
            .authenticatedSigningPublicKey(forFingerprint: fingerprint)
            ?? identityManager.signingPublicKey(forFingerprint: fingerprint),
           pinnedSigningPublicKey != signingPublicKey {
            return nil
        }

        let normalizedNickname = VerificationService.VerificationQR
            .normalizedProtocolNickname(peer.nickname)
            ?? VerificationService.VerificationQR.normalizedProtocolNickname(claimedNickname)
        guard let normalizedNickname else { return nil }

        var social = identityManager.getSocialIdentity(for: fingerprint) ?? SocialIdentity(
            fingerprint: fingerprint,
            localPetname: nil,
            claimedNickname: normalizedNickname,
            trustLevel: .unknown,
            isFavorite: favoritesService.isFavorite(expectedNoisePublicKey),
            isBlocked: false,
            notes: nil
        )
        guard !social.isBlocked else { return nil }
        social.claimedNickname = normalizedNickname
        social.isFavorite = favoritesService.isFavorite(expectedNoisePublicKey)
        guard identityManager.persistVerifiedIdentity(
            fingerprint: fingerprint,
            noisePublicKey: expectedNoisePublicKey,
            signingPublicKey: signingPublicKey,
            socialIdentity: social
        ) else {
            return nil
        }

        updatePeers()
        return social.localPetname?.trimmedOrNilIfEmpty ?? normalizedNickname
    }

    /// Removes only an existing friend relationship. Repeated or stale UI
    /// actions can never add the peer back.
    @discardableResult
    func removeFriend(_ peerID: PeerID) -> Bool {
        guard let peer = getPeer(by: peerID),
              peer.noisePublicKey.count == 32 else {
            return false
        }
        guard favoritesService.isFavorite(peer.noisePublicKey) else {
            return true
        }
        guard favoritesService.removeFavorite(
            peerNoisePublicKey: peer.noisePublicKey
        ) else {
            return false
        }

        let fingerprint = peer.noisePublicKey.sha256Fingerprint()
        if var social = identityManager.getSocialIdentity(for: fingerprint) {
            social.isFavorite = false
            identityManager.updateSocialIdentity(social)
        }

        if let messageRouter {
            messageRouter.sendFavoriteNotification(to: peer.peerID, isFavorite: false)
        } else {
            meshService.sendFavoriteNotification(to: peer.peerID, isFavorite: false)
        }
        updatePeers()
        return true
    }
    
    /// Get peer by ID
    func getPeer(by peerID: PeerID) -> BitchatPeer? {
        return peerIndex[peerID]
    }
    
    /// Get peer ID for nickname
    func getPeerID(for nickname: String) -> PeerID? {
        // Normalize both sides: the query may come from typed content and
        // stored names may predate NFC-at-ingest (e.g. persisted favorites).
        let target = nickname.normalizedNickname
        for peer in peers {
            if peer.displayName.normalizedNickname == target || peer.nickname.normalizedNickname == target {
                return peer.peerID
            }
        }
        return nil
    }
    
    /// Check if peer is blocked
    func isBlocked(_ peerID: PeerID) -> Bool {
        // Get fingerprint
        guard let fingerprint = getFingerprint(for: peerID) else { return false }
        
        // Check SecureIdentityStateManager for block status
        if let identity = identityManager.getSocialIdentity(for: fingerprint) {
            return identity.isBlocked
        }
        
        return false
    }

    /// Block or unblock a mesh peer by its stable Noise identity.
    ///
    /// The block is keyed by the peer's fingerprint, resolved from `peerID`
    /// (cache / mesh session / known-peer Noise key). This works even when the
    /// peer is offline — including offline favorites — so the exact tapped peer
    /// is (un)blocked unambiguously instead of being re-resolved by a
    /// display-name string that two peers could share.
    /// - Returns: the resolved fingerprint, or `nil` if the identity is unknown.
    @discardableResult
    func setBlocked(_ peerID: PeerID, blocked: Bool) -> String? {
        guard let fingerprint = getFingerprint(for: peerID) else {
            SecureLogger.warning(
                "⚠️ Cannot \(blocked ? "block" : "unblock") - unknown identity for peer: \(peerID)",
                category: .session
            )
            return nil
        }
        identityManager.setBlocked(fingerprint, isBlocked: blocked)
        if blocked {
            // Purge while the fingerprint↔peerID mapping is still known: the
            // archived-echo seed filter can't resolve offline strangers, so
            // scrub their carried messages now rather than at relaunch.
            (meshService as? MeshPublicArchiving)?.purgeArchivedPublicMessages(from: peerID)
        }
        updatePeers()
        return fingerprint
    }

    func getFingerprint(for peerID: PeerID) -> String? {
        // Check cache first
        if let cached = fingerprintCache[peerID] {
            return cached
        }

        // A full Noise-key conversation ID is already the authenticated
        // identity material. Derive its fingerprint directly so an offline
        // non-friend can still be named, verified, or blocked from Recents.
        if let noisePublicKey = peerID.noiseKey {
            let fingerprint = noisePublicKey.sha256Fingerprint()
            fingerprintCache[peerID] = fingerprint
            return fingerprint
        }
        
        // Try to get from mesh service
        if let fingerprint = meshService.getFingerprint(for: peerID) {
            fingerprintCache[peerID] = fingerprint
            return fingerprint
        }
        
        // Try to get from peer's public key
        if let peer = getPeer(by: peerID) {
            let fingerprint = peer.noisePublicKey.sha256Fingerprint()
            fingerprintCache[peerID] = fingerprint
            return fingerprint
        }

        // Announcements persist the full Noise identity even for people who
        // were never added as friends. Resolve an offline short ID only when
        // its 64-bit prefix identifies exactly one cached identity; guessing
        // across a collision would attach social actions to the wrong person.
        if peerID.isShort {
            let candidates = identityManager.getCryptoIdentitiesByPeerIDPrefix(peerID)
                .filter {
                    $0.publicKey.count == 32
                        && PeerID(publicKey: $0.publicKey) == peerID
                        && $0.fingerprint == $0.publicKey.sha256Fingerprint()
                }
            guard candidates.count == 1, let identity = candidates.first else {
                return nil
            }
            fingerprintCache[peerID] = identity.fingerprint
            fingerprintCache[PeerID(hexData: identity.publicKey)] = identity.fingerprint
            return identity.fingerprint
        }
        
        return nil
    }
    
    // MARK: - Compatibility Methods (for easy migration)

    var blockedUsers: Set<String> {
        Set(peers.compactMap { peer in
            isBlocked(peer.peerID) ? getFingerprint(for: peer.peerID) : nil
        })
    }
}
