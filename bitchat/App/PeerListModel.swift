import BitFoundation
import Combine
import Foundation
import SwiftUI

struct MeshPeerRow: Identifiable, Equatable {
    let peerID: PeerID
    /// Raw conversation keys that can represent this cryptographic identity
    /// (live short ID, stable Noise key, and optional Nostr mailbox key).
    let conversationPeerIDs: [PeerID]
    let displayName: String
    let isMe: Bool
    let hasUnread: Bool
    let unreadMessageCount: Int
    let isBlocked: Bool
    let isFavorite: Bool
    let isConnected: Bool
    let isReachable: Bool
    let isMutualFavorite: Bool
    /// True when this contact has a configured Nostr mailbox route. Nostr is
    /// store-and-forward, so this deliberately does not claim the remote app
    /// or any particular relay is online at this instant.
    let isNostrAvailable: Bool
    let encryptionStatus: EncryptionStatus
    let identityLockState: IdentityLockState
    /// Vouched-for by someone I verified, without an explicit verification of
    /// mine — rendered as the unfilled seal (verified gets the filled one).
    let showsVouchedBadge: Bool

    var id: String { peerID.id }

    /// Kept as a compatibility convenience for callers that distinguish an
    /// offline persisted verification from the live transport status.
    var showsVerifiedBadgeWhenOffline: Bool {
        !isConnected && identityLockState == .verified
    }
}

struct GeohashPersonRow: Identifiable, Equatable {
    let id: String
    let displayName: String
    let isMe: Bool
    let isTeleported: Bool
    let isBlocked: Bool
    let unreadMessageCount: Int
}

struct GroupChatRow: Identifiable, Equatable {
    let peerID: PeerID
    let name: String
    let memberCount: Int
    let isCreator: Bool
    let hasUnread: Bool
    let unreadMessageCount: Int

    var id: String { peerID.id }
}

/// A direct-message counterpart that remains visible after a non-friend leaves
/// the mesh. `id` is the full Noise fingerprint; every observed routing alias
/// is retained so the complete timeline can be consolidated before opening.
struct RecentMeshPeerRow: Identifiable, Equatable {
    let stablePeerID: PeerID
    let conversationPeerIDs: [PeerID]
    let noisePublicKey: Data
    let fingerprint: String
    let displayName: String
    let claimedNickname: String
    let lastMessageAt: Date
    let hasUnread: Bool
    let unreadMessageCount: Int
    let isBlocked: Bool
    let isNostrAvailable: Bool
    let identityLockState: IdentityLockState

    var id: String { fingerprint }
    var conversationPeerID: PeerID { stablePeerID }
}

private struct ResolvedRecentMeshIdentity {
    let stablePeerID: PeerID
    let noisePublicKey: Data
    let fingerprint: String
}

private struct RecentMeshConversationAccumulator {
    let identity: ResolvedRecentMeshIdentity
    var conversationPeerIDs: Set<PeerID>
    var lastMessageAt: Date
    var claimedNicknameFromMessages: String?
    var hasUnread: Bool
}

@MainActor
final class PeerListModel: ObservableObject {
    @Published private(set) var allPeers: [BitchatPeer] = []
    @Published private(set) var meshRows: [MeshPeerRow] = []
    @Published private(set) var recentMeshRows: [RecentMeshPeerRow] = []
    @Published private(set) var geohashPeople: [GeohashPersonRow] = []
    @Published private(set) var groupRows: [GroupChatRow] = []
    @Published private(set) var reachableMeshPeerCount = 0
    @Published private(set) var connectedMeshPeerCount = 0
    @Published private(set) var visibleGeohashPeerCount = 0
    @Published private(set) var renderID = ""

    private let chatViewModel: ChatViewModel
    private let conversations: ConversationStore
    private let locationChannelsModel: LocationChannelsModel
    private let peerIdentityStore: PeerIdentityStore
    private let locationPresenceStore: LocationPresenceStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        conversations: ConversationStore,
        locationChannelsModel: LocationChannelsModel? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        locationPresenceStore: LocationPresenceStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.conversations = conversations
        self.locationChannelsModel = locationChannelsModel ?? LocationChannelsModel()
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        self.locationPresenceStore = locationPresenceStore ?? chatViewModel.locationPresenceStore
        self.allPeers = chatViewModel.allPeers

        bind()
        refresh()
    }

    func colorForMeshPeer(id peerID: PeerID, isDark: Bool) -> Color {
        chatViewModel.colorForMeshPeer(id: peerID, isDark: isDark)
    }

    func colorForGeohashPerson(id: String, isDark: Bool) -> Color {
        chatViewModel.colorForNostrPubkey(id, isDark: isDark)
    }

    func participantCount(for geohash: String) -> Int {
        chatViewModel.geohashParticipantCount(for: geohash)
    }

    func startConversation(with peerID: PeerID) {
        chatViewModel.startPrivateChat(with: peerID)
    }

    /// Consolidates every known short/full routing alias before navigation so
    /// the opened timeline and unread state both represent the whole identity.
    @discardableResult
    func prepareRecentConversationForOpening(
        _ recentPeer: RecentMeshPeerRow
    ) -> PeerID {
        let destination = ConversationID.directPeer(recentPeer.stablePeerID)
        for peerID in recentPeer.conversationPeerIDs where peerID != recentPeer.stablePeerID {
            conversations.migrateConversation(
                from: .directPeer(peerID),
                to: destination
            )
        }
        return recentPeer.stablePeerID
    }

    /// Deletes every message that belonged to this Recent identity when the
    /// user confirmed the action. The fingerprint remains stable while a
    /// confirmation dialog is open, whereas its row and routing aliases may
    /// change. Resolve the current store again before merging aliases and
    /// using the private-chat deletion transaction; that transaction owns
    /// media tombstones, transfer cancellation, file cleanup, and final
    /// conversation removal.
    @discardableResult
    func deleteRecentChat(fingerprint: String) -> PeerID? {
        let currentMatches = conversations.conversationIDs.compactMap {
            conversationID -> (peerID: PeerID, identity: ResolvedRecentMeshIdentity)? in
            guard case .direct(let handle) = conversationID else { return nil }
            let peerID = handle.routingPeerID
            guard isEligibleRecentMeshPeerID(peerID),
                  let identity = resolveRecentMeshIdentity(for: peerID),
                  identity.fingerprint == fingerprint else {
                return nil
            }
            return (peerID, identity)
        }

        guard let stablePeerID = recentMeshRows.first(where: {
            $0.fingerprint == fingerprint
        })?.stablePeerID ?? currentMatches.first?.identity.stablePeerID else {
            return nil
        }

        let destination = ConversationID.directPeer(stablePeerID)
        let currentPeerIDs = Set(currentMatches.map(\.peerID)).sorted {
            $0.id < $1.id
        }
        for peerID in currentPeerIDs where peerID != stablePeerID {
            conversations.migrateConversation(
                from: .directPeer(peerID),
                to: destination
            )
        }

        chatViewModel.deletePrivateChat(stablePeerID)
        return stablePeerID
    }

    @discardableResult
    func deleteRecentConversation(
        _ recentPeer: RecentMeshPeerRow
    ) -> PeerID? {
        deleteRecentChat(fingerprint: recentPeer.fingerprint)
    }

    @discardableResult
    func addFriend(peerID: PeerID) -> Bool {
        chatViewModel.addFriend(peerID: peerID)
    }

    /// Adds an offline recent by its persisted Noise identity instead of
    /// requiring a live UnifiedPeerService row.
    @discardableResult
    func addFriend(recentPeer: RecentMeshPeerRow) -> Bool {
        chatViewModel.addFriend(
            noisePublicKey: recentPeer.noisePublicKey,
            nostrPublicKey: chatViewModel.idBridge.getNostrPublicKey(
                for: recentPeer.noisePublicKey
            ),
            claimedNickname: recentPeer.claimedNickname
        ) != nil
    }

    func removeFriend(peerID: PeerID) {
        chatViewModel.removeFriend(peerID: peerID)
    }

    func openGeohashDirectMessage(with pubkeyHex: String) {
        chatViewModel.startGeohashDM(withPubkeyHex: pubkeyHex)
    }

    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        chatViewModel.blockGeohashUser(
            pubkeyHexLowercased: pubkeyHexLowercased,
            displayName: displayName
        )
    }

    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        chatViewModel.unblockGeohashUser(
            pubkeyHexLowercased: pubkeyHexLowercased,
            displayName: displayName
        )
    }

    func isBridgeUserBlocked(pubkeyHex: String) -> Bool {
        chatViewModel.isBridgeUserBlocked(pubkeyHex: pubkeyHex)
    }

    func blockBridgeUser(pubkeyHex: String, displayName: String) {
        chatViewModel.blockBridgeUser(pubkeyHex: pubkeyHex, displayName: displayName)
    }

    func unblockBridgeUser(pubkeyHex: String, displayName: String) {
        chatViewModel.unblockBridgeUser(pubkeyHex: pubkeyHex, displayName: displayName)
    }

    private func bind() {
        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.allPeers = peers
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationPresenceStore.$teleportedGeo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        conversations.$unreadConversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // ConversationStore emits this stream after each mutation is
        // consistent. Listening here keeps Recents current for background DMs
        // without weakening PrivateInboxModel's selected-chat isolation.
        conversations.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard Self.affectsRecentMeshRows(change) else { return }
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.groupStore.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$identityConflicts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.participantTracker.$visiblePeople
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$selectedChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$teleported
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        let myPeerID = chatViewModel.meshService.myPeerID
        let meshRows = allPeers.map { peer in
            let isMe = peer.peerID == myPeerID
            let fingerprint = isMe ? nil : chatViewModel.getFingerprint(for: peer.peerID)
            let isVerifiedFingerprint = fingerprint.map { peerIdentityStore.isVerified($0) } ?? false
            let identityLockState = peerIdentityStore.identityLockState(
                fingerprint: fingerprint
            )
            // Vouched is subordinate to verified and must never soften an
            // active identity conflict with a positive trust badge.
            let vouchedBadge = identityLockState != .identityMismatch
                && !isVerifiedFingerprint
                && (fingerprint.map { chatViewModel.isVouchedFingerprint($0) } ?? false)
            let hasNostrRoute = peer.hasNostrRoute
            var conversationPeerIDs = Set([peer.peerID])
            if peer.noisePublicKey.count == 32 {
                conversationPeerIDs.insert(PeerID(hexData: peer.noisePublicKey))
            }
            if let nostrPublicKey = peer.nostrPublicKey {
                conversationPeerIDs.insert(PeerID(nostr_: nostrPublicKey))
            }
            let hasUnread = chatViewModel.hasUnreadMessages(for: peer.peerID)
            let unreadMessageCount = max(
                conversations.unreadMessageCount(
                    forDirectPeerIDs: conversationPeerIDs
                ),
                hasUnread ? 1 : 0
            )

            return MeshPeerRow(
                peerID: peer.peerID,
                conversationPeerIDs: conversationPeerIDs.sorted { $0.id < $1.id },
                displayName: isMe ? chatViewModel.nickname : peer.displayName,
                isMe: isMe,
                hasUnread: hasUnread,
                unreadMessageCount: unreadMessageCount,
                isBlocked: !isMe && chatViewModel.isPeerBlocked(peer.peerID),
                isFavorite: peer.favoriteStatus?.isFavorite ?? false,
                isConnected: peer.isConnected,
                isReachable: peer.isReachable,
                isMutualFavorite: peer.isMutualFavorite,
                isNostrAvailable: hasNostrRoute,
                encryptionStatus: chatViewModel.getEncryptionStatus(for: peer.peerID),
                identityLockState: identityLockState,
                showsVouchedBadge: vouchedBadge
            )
        }

        let meshCounts = meshRows.reduce(into: (reachable: 0, connected: 0)) { counts, row in
            guard !row.isMe else { return }
            if row.isConnected {
                counts.connected += 1
                counts.reachable += 1
            } else if row.isReachable {
                counts.reachable += 1
            }
        }

        let geohashPeople = buildGeohashPeople()
        let groupRows = buildGroupRows()
        let recentMeshRows = buildRecentMeshRows()

        self.meshRows = meshRows
        self.recentMeshRows = recentMeshRows
        reachableMeshPeerCount = meshCounts.reachable
        connectedMeshPeerCount = meshCounts.connected
        self.geohashPeople = geohashPeople
        visibleGeohashPeerCount = geohashPeople.count
        self.groupRows = groupRows
        renderID = (
            meshRows.map {
                let aliases = $0.conversationPeerIDs.map(\.id).joined(separator: ",")
                return "\($0.id)-\(aliases)-\($0.displayName)-\($0.isConnected)-\($0.isReachable)-\($0.isNostrAvailable)-\($0.hasUnread)-\($0.unreadMessageCount)-\($0.isFavorite)-\($0.isBlocked)"
            } +
            geohashPeople.map {
                "geo:\($0.id)-\($0.isTeleported)-\($0.isBlocked)-\($0.unreadMessageCount)-\($0.displayName)"
            } +
            groupRows.map {
                "group:\($0.id)-\($0.name)-\($0.memberCount)-\($0.hasUnread)-\($0.unreadMessageCount)"
            } +
            recentMeshRows.map {
                let aliases = $0.conversationPeerIDs.map(\.id).joined(separator: ",")
                return "recent:\($0.id)-\(aliases)-\($0.displayName)-\($0.lastMessageAt.timeIntervalSince1970)-\($0.hasUnread)-\($0.unreadMessageCount)-\($0.isBlocked)"
            }
        ).joined(separator: "|")
    }

    private static func affectsRecentMeshRows(_ change: ConversationChange) -> Bool {
        switch change {
        case .appended(let id, _),
             .updated(let id, _),
             .messageRemoved(let id, _),
             .cleared(let id),
             .removed(let id),
             .unreadChanged(let id, _):
            if case .direct = id { return true }
            return false
        case .migrated(let source, let destination):
            if case .direct = source { return true }
            if case .direct = destination { return true }
            return false
        case .statusChanged:
            return false
        }
    }

    private func buildRecentMeshRows() -> [RecentMeshPeerRow] {
        let onlineFingerprints = Set(
            allPeers.compactMap { peer -> String? in
                guard peer.isConnected || peer.isReachable,
                      peer.noisePublicKey.count == 32 else { return nil }
                return peer.noisePublicKey.sha256Fingerprint()
            }
        )
        var accumulated: [String: RecentMeshConversationAccumulator] = [:]

        for conversationID in conversations.conversationIDs {
            guard case .direct(let handle) = conversationID else { continue }
            let routingPeerID = handle.routingPeerID
            guard let conversation = conversations.conversationsByID[conversationID] else {
                continue
            }
            // Local status rows use the private timeline for presentation, but
            // they do not establish that the user actually chatted with this
            // identity and therefore must not create or rank a Recent entry.
            let userMessages = conversation.messages.filter {
                $0.isPrivate && $0.sender != "system"
            }
            guard isEligibleRecentMeshPeerID(routingPeerID),
                  let lastMessage = userMessages.last,
                  let identity = resolveRecentMeshIdentity(for: routingPeerID),
                  identity.noisePublicKey != chatViewModel.meshService.noiseStaticPublicKeyData(),
                  !onlineFingerprints.contains(identity.fingerprint),
                  !chatViewModel.isFavorite(peerID: identity.stablePeerID) else {
                continue
            }

            let messageNickname = recentClaimedNickname(
                in: userMessages,
                localPeerID: chatViewModel.meshService.myPeerID
            )
            let unread = conversations.unreadConversations.contains(conversationID)

            if var existing = accumulated[identity.fingerprint] {
                existing.hasUnread = existing.hasUnread || unread
                existing.conversationPeerIDs.insert(routingPeerID)
                if lastMessage.timestamp > existing.lastMessageAt {
                    existing.lastMessageAt = lastMessage.timestamp
                    if let messageNickname {
                        existing.claimedNicknameFromMessages = messageNickname
                    }
                }
                accumulated[identity.fingerprint] = existing
            } else {
                accumulated[identity.fingerprint] = RecentMeshConversationAccumulator(
                    identity: identity,
                    conversationPeerIDs: [routingPeerID],
                    lastMessageAt: lastMessage.timestamp,
                    claimedNicknameFromMessages: messageNickname,
                    hasUnread: unread
                )
            }
        }

        return accumulated.values.map { item in
            let social = chatViewModel.identityManager.getSocialIdentity(
                for: item.identity.fingerprint
            )
            let livePeer = allPeers.first {
                $0.noisePublicKey == item.identity.noisePublicKey
            }
            let claimedNickname = social?.claimedNickname.trimmedOrNilIfEmpty
                ?? livePeer?.nickname.trimmedOrNilIfEmpty
                ?? item.claimedNicknameFromMessages?.trimmedOrNilIfEmpty
                ?? "anon\(item.identity.fingerprint.prefix(4))"
            let displayName = social?.localPetname?.trimmedOrNilIfEmpty
                ?? livePeer?.localPetname?.trimmedOrNilIfEmpty
                ?? claimedNickname
            let isNostrAvailable = FavoritesPersistenceService.shared
                .getFavoriteStatus(for: item.identity.noisePublicKey)?
                .peerNostrPublicKey != nil

            return RecentMeshPeerRow(
                stablePeerID: item.identity.stablePeerID,
                conversationPeerIDs: item.conversationPeerIDs.sorted {
                    $0.id < $1.id
                },
                noisePublicKey: item.identity.noisePublicKey,
                fingerprint: item.identity.fingerprint,
                displayName: displayName,
                claimedNickname: claimedNickname,
                lastMessageAt: item.lastMessageAt,
                hasUnread: item.hasUnread,
                unreadMessageCount: max(
                    conversations.unreadMessageCount(
                        forDirectPeerIDs: item.conversationPeerIDs
                            .union([item.identity.stablePeerID])
                    ),
                    item.hasUnread ? 1 : 0
                ),
                isBlocked: social?.isBlocked == true
                    || chatViewModel.identityManager.isBlocked(
                        fingerprint: item.identity.fingerprint
                    ),
                isNostrAvailable: isNostrAvailable,
                identityLockState: peerIdentityStore.identityLockState(
                    fingerprint: item.identity.fingerprint
                )
            )
        }
        .sorted { lhs, rhs in
            if lhs.lastMessageAt != rhs.lastMessageAt {
                return lhs.lastMessageAt > rhs.lastMessageAt
            }
            return lhs.fingerprint < rhs.fingerprint
        }
    }

    private func isEligibleRecentMeshPeerID(_ peerID: PeerID) -> Bool {
        guard peerID != chatViewModel.meshService.myPeerID,
              !peerID.isGroup,
              !peerID.isGeoChat,
              !peerID.isGeoDM,
              !peerID.isBridge else {
            return false
        }
        return peerID.isShort || peerID.noiseKey != nil
    }

    private func resolveRecentMeshIdentity(
        for peerID: PeerID
    ) -> ResolvedRecentMeshIdentity? {
        if let noisePublicKey = peerID.noiseKey {
            return makeRecentMeshIdentity(noisePublicKey: noisePublicKey)
        }
        guard peerID.isShort else { return nil }

        if let livePeer = allPeers.first(where: {
            $0.peerID == peerID && $0.noisePublicKey.count == 32
        }) {
            return makeRecentMeshIdentity(noisePublicKey: livePeer.noisePublicKey)
        }
        if let stablePeerID = peerIdentityStore.stablePeerID(forShortID: peerID),
           let noisePublicKey = stablePeerID.noiseKey,
           PeerID(publicKey: noisePublicKey) == peerID {
            return makeRecentMeshIdentity(noisePublicKey: noisePublicKey)
        }

        let candidates = chatViewModel.identityManager
            .getCryptoIdentitiesByPeerIDPrefix(peerID)
            .filter {
                $0.publicKey.count == 32
                    && PeerID(publicKey: $0.publicKey) == peerID
                    && $0.fingerprint == $0.publicKey.sha256Fingerprint()
            }
        guard candidates.count == 1, let identity = candidates.first else {
            return nil
        }
        return makeRecentMeshIdentity(noisePublicKey: identity.publicKey)
    }

    private func makeRecentMeshIdentity(
        noisePublicKey: Data
    ) -> ResolvedRecentMeshIdentity? {
        guard noisePublicKey.count == 32 else { return nil }
        return ResolvedRecentMeshIdentity(
            stablePeerID: PeerID(hexData: noisePublicKey),
            noisePublicKey: noisePublicKey,
            fingerprint: noisePublicKey.sha256Fingerprint()
        )
    }

    private func recentClaimedNickname(
        in messages: [BitchatMessage],
        localPeerID: PeerID
    ) -> String? {
        for message in messages.reversed() {
            let sentLocally = message.senderPeerID == localPeerID
            if sentLocally {
                if let recipient = message.recipientNickname?.trimmedOrNilIfEmpty {
                    return recipient
                }
            } else if let sender = message.sender.trimmedOrNilIfEmpty {
                return sender
            }
        }
        return nil
    }

    private func buildGroupRows() -> [GroupChatRow] {
        let myFingerprint = chatViewModel.meshService.noiseIdentityFingerprint()
        return chatViewModel.groupStore.groups.map { group in
            let hasUnread = chatViewModel.hasUnreadMessages(for: group.peerID)
            return GroupChatRow(
                peerID: group.peerID,
                name: group.name,
                memberCount: group.members.count,
                isCreator: group.creatorFingerprint == myFingerprint,
                hasUnread: hasUnread,
                unreadMessageCount: max(
                    conversations.unreadMessageCount(for: .directPeer(group.peerID)),
                    hasUnread ? 1 : 0
                )
            )
        }
    }

    private func buildGeohashPeople() -> [GeohashPersonRow] {
        let myHex = currentGeohashIdentityHex()
        let teleportedSet = Set(locationPresenceStore.teleportedGeo.map { $0.lowercased() })

        return chatViewModel.visibleGeohashPeople().map { person in
            let isMe = person.id == myHex
            let conversationPeerID = PeerID(nostr_: person.id)
            return GeohashPersonRow(
                id: person.id,
                displayName: person.displayName,
                isMe: isMe,
                isTeleported: teleportedSet.contains(person.id.lowercased()) || (isMe && locationChannelsModel.teleported),
                isBlocked: !isMe && chatViewModel.isGeohashUserBlocked(pubkeyHexLowercased: person.id),
                unreadMessageCount: isMe
                    ? 0
                    : conversations.unreadMessageCount(
                        for: .directPeer(conversationPeerID)
                    )
            )
        }
    }

    private func currentGeohashIdentityHex() -> String? {
        guard case .location(let channel) = locationChannelsModel.selectedChannel,
              let identity = try? chatViewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) else {
            return nil
        }

        return identity.publicKeyHex.lowercased()
    }
}
