//
// PrivateChatDeletionTests.swift
// bitchatTests
//
// SPDX-License-Identifier: MIT
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
private func makePrivateChatDeletionViewModel() -> (
    viewModel: ChatViewModel,
    transport: MockTransport
) {
    let keychain = MockKeychain()
    let transport = MockTransport()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: transport,
        panicNetworkLifecycle: .noop,
        panicBridgeReset: {}
    )
    return (viewModel, transport)
}

private func deletionTextMessage(
    id: String,
    peerID: PeerID,
    recipient: String
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "Peer",
        content: "message",
        timestamp: Date(),
        isRelay: false,
        isPrivate: true,
        recipientNickname: recipient,
        senderPeerID: peerID
    )
}

private func deletionMediaMessage(
    id: String,
    peerID: PeerID,
    recipient: String
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "Peer",
        content: "\(MimeType.Category.image.messagePrefix)incoming.jpg",
        timestamp: Date(),
        isRelay: false,
        isPrivate: true,
        recipientNickname: recipient,
        senderPeerID: peerID
    )
}

struct PrivateChatDeletionTests {
    @Test("A normal clear keeps the empty conversation but clears unread")
    @MainActor
    func normalClearMarksAnEmptyTimelineRead() {
        let (viewModel, _) = makePrivateChatDeletionViewModel()
        let peerID = PeerID(str: String(repeating: "1", count: 64))
        let conversationID = ConversationID.directPeer(peerID)
        viewModel.seedPrivateChat([
            deletionTextMessage(
                id: "clear-text",
                peerID: peerID,
                recipient: viewModel.nickname
            )
        ], for: peerID)
        viewModel.startPrivateChat(with: peerID)
        viewModel.markPrivateChatUnread(peerID)

        viewModel.clearPrivateChat(peerID)

        #expect(
            viewModel.conversations.conversationsByID[conversationID]?
                .messages.isEmpty == true
        )
        #expect(
            !viewModel.conversations.unreadConversations
                .contains(conversationID)
        )
        #expect(viewModel.conversations.selectedPrivatePeerID == peerID)
        #expect(viewModel.selectedPrivateChatPeer == peerID)
        #expect(
            viewModel.conversations.selectedConversationID
                == conversationID
        )
    }

    @Test("A successful delete removes the empty conversation and unread state")
    @MainActor
    func successfulDeleteRemovesConversationAndUnread() {
        let (viewModel, _) = makePrivateChatDeletionViewModel()
        let peerID = PeerID(str: String(repeating: "2", count: 64))
        let conversationID = ConversationID.directPeer(peerID)
        let activeChannel = ChannelID.location(
            GeohashChannel(level: .city, geohash: "u4pruy")
        )
        let activePublicConversationID = ConversationID(
            channelID: activeChannel
        )
        viewModel.conversations.setActiveChannel(activeChannel)
        viewModel.seedPrivateChat([
            deletionTextMessage(
                id: "delete-text",
                peerID: peerID,
                recipient: viewModel.nickname
            )
        ], for: peerID)
        viewModel.startPrivateChat(with: peerID)
        viewModel.markPrivateChatUnread(peerID)

        #expect(viewModel.conversations.selectedPrivatePeerID == peerID)
        #expect(
            viewModel.conversations.selectedConversationID
                == conversationID
        )

        viewModel.deletePrivateChat(peerID)

        #expect(
            viewModel.conversations.conversationsByID[conversationID] == nil
        )
        #expect(
            !viewModel.conversations.unreadConversations
                .contains(conversationID)
        )
        #expect(viewModel.conversations.selectedPrivatePeerID == nil)
        #expect(viewModel.selectedPrivateChatPeer == nil)
        #expect(viewModel.conversations.activeChannel == activeChannel)
        #expect(
            viewModel.conversations.selectedConversationID
                == activePublicConversationID
        )
    }

    @Test("A failed media journal preserves the conversation and unread state")
    @MainActor
    func failedDeletePreservesMessagesAndUnread() {
        let (viewModel, transport) = makePrivateChatDeletionViewModel()
        transport.persistDeletedPrivateMediaResult = false
        let peerID = PeerID(str: String(repeating: "3", count: 64))
        let conversationID = ConversationID.directPeer(peerID)
        let mediaID = "media-\(String(repeating: "a", count: 32))"
        viewModel.seedPrivateChat([
            deletionMediaMessage(
                id: mediaID,
                peerID: peerID,
                recipient: viewModel.nickname
            )
        ], for: peerID)
        viewModel.startPrivateChat(with: peerID)
        viewModel.markPrivateChatUnread(peerID)

        viewModel.deletePrivateChat(peerID)

        #expect(
            viewModel.conversations.conversationsByID[conversationID]?
                .messages.contains(where: { $0.id == mediaID }) == true
        )
        #expect(
            viewModel.conversations.unreadConversations
                .contains(conversationID)
        )
        #expect(viewModel.conversations.selectedPrivatePeerID == peerID)
        #expect(viewModel.selectedPrivateChatPeer == peerID)
        #expect(
            viewModel.conversations.selectedConversationID
                == conversationID
        )
    }

    @Test("A post-boundary arrival keeps the conversation and unread state")
    @MainActor
    func deletePreservesArrivalDuringJournalIO() {
        let (viewModel, transport) = makePrivateChatDeletionViewModel()
        transport.deferDeletedPrivateMediaPersistence = true
        let peerID = PeerID(str: String(repeating: "4", count: 64))
        let conversationID = ConversationID.directPeer(peerID)
        let mediaID = "media-\(String(repeating: "b", count: 32))"
        viewModel.seedPrivateChat([
            deletionMediaMessage(
                id: mediaID,
                peerID: peerID,
                recipient: viewModel.nickname
            )
        ], for: peerID)
        viewModel.startPrivateChat(with: peerID)
        viewModel.markPrivateChatUnread(peerID)

        viewModel.deletePrivateChat(peerID)
        let arrival = deletionTextMessage(
            id: "arrival-after-delete",
            peerID: peerID,
            recipient: viewModel.nickname
        )
        #expect(viewModel.appendPrivateMessage(arrival, to: peerID))
        transport.resolveNextDeletedPrivateMediaPersistence(true)

        #expect(
            viewModel.conversations.conversationsByID[conversationID]?
                .messages.map(\.id) == [arrival.id]
        )
        #expect(
            viewModel.conversations.unreadConversations
                .contains(conversationID)
        )
        #expect(viewModel.conversations.selectedPrivatePeerID == peerID)
        #expect(viewModel.selectedPrivateChatPeer == peerID)
        #expect(
            viewModel.conversations.selectedConversationID
                == conversationID
        )
    }

    @Test("Delete preserves an active live voice row and unread state")
    @MainActor
    func deletePreservesActiveLiveVoice() throws {
        let (viewModel, _) = makePrivateChatDeletionViewModel()
        let peerID = PeerID(str: String(repeating: "5", count: 64))
        let conversationID = ConversationID.directPeer(peerID)
        let burstID = Data(
            repeating: 0xD5,
            count: VoiceBurstPacket.burstIDSize
        )
        let start = try #require(VoiceBurstPacket(
            burstID: burstID,
            seq: 0,
            kind: .start(codec: .aacLC16kMono)
        ))
        let cancel = try #require(VoiceBurstPacket(
            burstID: burstID,
            seq: 1,
            kind: .canceled
        ))
        let coordinator = viewModel.liveVoiceCoordinator
        defer {
            coordinator.handleVoiceFramePayload(
                from: peerID,
                payload: cancel.encode(),
                timestamp: Date()
            )
        }
        coordinator.handleVoiceFramePayload(
            from: peerID,
            payload: start.encode(),
            timestamp: Date()
        )
        let liveMessage = try #require(
            viewModel.conversations.conversationsByID[conversationID]?
                .messages.first
        )
        #expect(coordinator.isLiveVoiceMessage(liveMessage))
        viewModel.markPrivateChatUnread(peerID)

        viewModel.deletePrivateChat(peerID)

        #expect(
            viewModel.conversations.conversationsByID[conversationID]?
                .messages.map(\.id) == [liveMessage.id]
        )
        #expect(
            viewModel.conversations.unreadConversations
                .contains(conversationID)
        )
    }
}
