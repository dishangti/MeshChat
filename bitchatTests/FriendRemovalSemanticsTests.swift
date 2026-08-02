//
// FriendRemovalSemanticsTests.swift
// bitchatTests
//
// SPDX-License-Identifier: MIT
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Friend Removal Semantics", .serialized)
struct FriendRemovalSemanticsTests {
    @Test("Removing an offline friend preserves every independent local state")
    @MainActor
    func removingFriendPreservesHistoryNicknameTrustVerificationAndBlock() throws {
        let keychain = MockKeychain()
        let identityManager = SecureIdentityStateManager(keychain)
        let peerIdentityStore = PeerIdentityStore()
        let transport = MockTransport()
        let viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identityManager,
            transport: transport,
            peerIdentityStore: peerIdentityStore,
            panicNetworkLifecycle: .noop,
            panicBridgeReset: {}
        )
        let noiseKey = Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max)
        })
        let stablePeerID = PeerID(hexData: noiseKey)
        let conversationID = ConversationID.directPeer(stablePeerID)
        let fingerprint = noiseKey.sha256Fingerprint()
        let favorites = FavoritesPersistenceService.shared
        defer {
            _ = favorites.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        #expect(favorites.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "Alice"
        ))
        identityManager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noiseKey,
            signingPublicKey: Data(repeating: 0xA5, count: 32),
            claimedNickname: "Alice"
        )
        identityManager.updateSocialIdentity(SocialIdentity(
            fingerprint: fingerprint,
            localPetname: "Trail Friend",
            claimedNickname: "Alice",
            trustLevel: .verified,
            isFavorite: true,
            isBlocked: true,
            notes: "Keep this note"
        ))
        identityManager.setVerified(
            fingerprint: fingerprint,
            verified: true
        )
        peerIdentityStore.setFingerprint(
            fingerprint,
            for: stablePeerID
        )
        peerIdentityStore.setVerified(
            fingerprint,
            verified: true
        )
        let message = BitchatMessage(
            id: "friend-history",
            sender: "Alice",
            content: "This history stays local.",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: stablePeerID
        )
        viewModel.conversations.append(
            message,
            to: conversationID
        )

        #expect(viewModel.isFavorite(peerID: stablePeerID))
        #expect(viewModel.isPeerBlocked(stablePeerID))
        #expect(identityManager.isVerified(fingerprint: fingerprint))
        #expect(peerIdentityStore.isVerified(fingerprint))

        #expect(viewModel.removeFriend(peerID: stablePeerID))

        #expect(!favorites.isFavorite(noiseKey))
        #expect(!viewModel.isFavorite(peerID: stablePeerID))
        #expect(
            viewModel.conversations.conversationsByID[conversationID]?
                .messages.map(\.id) == [message.id]
        )
        let social = try #require(
            identityManager.getSocialIdentity(for: fingerprint)
        )
        #expect(social.localPetname == "Trail Friend")
        #expect(social.claimedNickname == "Alice")
        #expect(social.trustLevel == .verified)
        #expect(!social.isFavorite)
        #expect(social.isBlocked)
        #expect(social.notes == "Keep this note")
        #expect(identityManager.isVerified(fingerprint: fingerprint))
        #expect(peerIdentityStore.isVerified(fingerprint))
        #expect(viewModel.isPeerBlocked(stablePeerID))
    }
}
