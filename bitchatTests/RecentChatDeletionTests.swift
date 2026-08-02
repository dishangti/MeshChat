// SPDX-License-Identifier: MIT

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Recent Chat Deletion Tests", .serialized)
struct RecentChatDeletionTests {
    @Test("Deletion rescans stale aliases and removes the whole identity conversation")
    @MainActor
    func deletionRescansStaleAliasesAndRemovesAllHistory() async throws {
        let harness = makeHarness()
        let noiseKey = Data(repeating: 0xA6, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)
        let shortPeerID = PeerID(publicKey: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()
        let otherNoiseKey = Data(repeating: 0xB7, count: 32)
        let otherPeerID = PeerID(hexData: otherNoiseKey)
        let otherFingerprint = otherNoiseKey.sha256Fingerprint()

        harness.conversations.append(
            message(
                id: "stable-before-dialog",
                sender: "Alice",
                peerID: stablePeerID,
                timestamp: 10,
                recipient: harness.viewModel.nickname
            ),
            to: .directPeer(stablePeerID)
        )
        harness.conversations.markUnread(.directPeer(stablePeerID))

        await waitUntil {
            harness.peerListModel.recentMeshRows.contains {
                $0.fingerprint == fingerprint
            }
        }
        let dialogRow = try #require(
            harness.peerListModel.recentMeshRows.first {
                $0.fingerprint == fingerprint
            }
        )
        #expect(dialogRow.conversationPeerIDs == [stablePeerID])

        // This alias appears after the UI captured its row. A confirmation
        // must act on current storage rather than that stale alias snapshot.
        harness.peerIdentityStore.setStablePeerID(
            stablePeerID,
            forShortID: shortPeerID
        )
        harness.conversations.append(
            message(
                id: "short-after-dialog",
                sender: "Alice",
                peerID: shortPeerID,
                timestamp: 20,
                recipient: harness.viewModel.nickname
            ),
            to: .directPeer(shortPeerID)
        )
        harness.conversations.markUnread(.directPeer(shortPeerID))

        harness.conversations.append(
            message(
                id: "unrelated-history",
                sender: "Bob",
                peerID: otherPeerID,
                timestamp: 30,
                recipient: harness.viewModel.nickname
            ),
            to: .directPeer(otherPeerID)
        )

        #expect(
            harness.peerListModel.deleteRecentChat(
                fingerprint: dialogRow.fingerprint
            ) == stablePeerID
        )

        await waitUntil {
            harness.conversations.conversationsByID[.directPeer(stablePeerID)] == nil
                && harness.conversations.conversationsByID[.directPeer(shortPeerID)] == nil
                && !harness.peerListModel.recentMeshRows.contains {
                    $0.fingerprint == fingerprint
                }
        }

        #expect(
            !harness.conversations.directConversationsContainMessage(
                withID: "stable-before-dialog"
            )
        )
        #expect(
            !harness.conversations.directConversationsContainMessage(
                withID: "short-after-dialog"
            )
        )
        #expect(
            !harness.conversations.unreadConversations.contains(
                .directPeer(stablePeerID)
            )
        )
        #expect(
            !harness.conversations.unreadConversations.contains(
                .directPeer(shortPeerID)
            )
        )
        #expect(
            harness.conversations.conversationsByID[.directPeer(otherPeerID)]?
                .messages.map(\.id) == ["unrelated-history"]
        )
        #expect(
            harness.peerListModel.recentMeshRows.contains {
                $0.fingerprint == otherFingerprint
            }
        )
    }

    @Test("A new message after deletion recreates Recent")
    @MainActor
    func newMessageAfterDeletionRecreatesRecent() async throws {
        let harness = makeHarness()
        let noiseKey = Data(repeating: 0xC8, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()

        harness.conversations.append(
            message(
                id: "old-message",
                sender: "Casey",
                peerID: stablePeerID,
                timestamp: 10,
                recipient: harness.viewModel.nickname
            ),
            to: .directPeer(stablePeerID)
        )
        await waitUntil {
            harness.peerListModel.recentMeshRows.contains {
                $0.fingerprint == fingerprint
            }
        }

        #expect(
            harness.peerListModel.deleteRecentChat(fingerprint: fingerprint)
                == stablePeerID
        )
        await waitUntil {
            harness.conversations.conversationsByID[.directPeer(stablePeerID)] == nil
                && !harness.peerListModel.recentMeshRows.contains {
                    $0.fingerprint == fingerprint
                }
        }

        harness.conversations.append(
            message(
                id: "new-message",
                sender: "Casey",
                peerID: stablePeerID,
                timestamp: 40,
                recipient: harness.viewModel.nickname
            ),
            to: .directPeer(stablePeerID)
        )

        await waitUntil {
            harness.peerListModel.recentMeshRows.first {
                $0.fingerprint == fingerprint
            }?.lastMessageAt == Date(timeIntervalSince1970: 40)
        }
        #expect(
            harness.conversations.conversationsByID[.directPeer(stablePeerID)]?
                .messages.map(\.id) == ["new-message"]
        )
    }

    @Test("A message arriving after confirmation survives an in-flight deletion")
    @MainActor
    func postBoundaryMessageSurvivesInFlightDeletion() async throws {
        let harness = makeHarness()
        harness.transport.deferDeletedPrivateMediaPersistence = true
        let noiseKey = Data(repeating: 0xD9, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)
        let fingerprint = noiseKey.sha256Fingerprint()
        let mediaID = "media-\(String(repeating: "d", count: 32))"

        harness.conversations.append(
            BitchatMessage(
                id: mediaID,
                sender: "Dana",
                content: "\(MimeType.Category.image.messagePrefix)old.jpg",
                timestamp: Date(timeIntervalSince1970: 10),
                isRelay: false,
                isPrivate: true,
                recipientNickname: harness.viewModel.nickname,
                senderPeerID: stablePeerID
            ),
            to: .directPeer(stablePeerID)
        )
        await waitUntil {
            harness.peerListModel.recentMeshRows.contains {
                $0.fingerprint == fingerprint
            }
        }

        #expect(
            harness.peerListModel.deleteRecentChat(fingerprint: fingerprint)
                == stablePeerID
        )
        #expect(harness.transport.deletedPrivateMediaMessageIDBatches == [[mediaID]])

        harness.conversations.append(
            message(
                id: "arrival-after-confirmation",
                sender: "Dana",
                peerID: stablePeerID,
                timestamp: 50,
                recipient: harness.viewModel.nickname
            ),
            to: .directPeer(stablePeerID)
        )
        harness.transport.resolveNextDeletedPrivateMediaPersistence(true)

        await waitUntil {
            harness.conversations.conversationsByID[.directPeer(stablePeerID)]?
                .messages.map(\.id) == ["arrival-after-confirmation"]
                && harness.peerListModel.recentMeshRows.first {
                    $0.fingerprint == fingerprint
                }?.lastMessageAt == Date(timeIntervalSince1970: 50)
        }
        #expect(
            harness.conversations.conversationsByID[.directPeer(stablePeerID)]?
                .messages.map(\.id) == ["arrival-after-confirmation"]
        )
    }
}

private extension RecentChatDeletionTests {
    @MainActor
    struct Harness {
        let viewModel: ChatViewModel
        let transport: MockTransport
        let conversations: ConversationStore
        let peerIdentityStore: PeerIdentityStore
        let peerListModel: PeerListModel
    }

    @MainActor
    func makeHarness() -> Harness {
        let keychain = MockKeychain()
        let conversations = ConversationStore()
        let peerIdentityStore = PeerIdentityStore()
        let transport = MockTransport()
        let suiteName = "RecentChatDeletionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let locationManager = LocationChannelManager(storage: defaults)
        let viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: transport,
            conversations: conversations,
            peerIdentityStore: peerIdentityStore,
            locationManager: locationManager,
            readReceiptsDefaults: defaults
        )
        let peerListModel = PeerListModel(
            chatViewModel: viewModel,
            conversations: conversations,
            locationChannelsModel: LocationChannelsModel(
                manager: locationManager
            ),
            peerIdentityStore: peerIdentityStore
        )
        return Harness(
            viewModel: viewModel,
            transport: transport,
            conversations: conversations,
            peerIdentityStore: peerIdentityStore,
            peerListModel: peerListModel
        )
    }

    @MainActor
    func message(
        id: String,
        sender: String,
        peerID: PeerID,
        timestamp: TimeInterval,
        recipient: String
    ) -> BitchatMessage {
        BitchatMessage(
            id: id,
            sender: sender,
            content: "message \(id)",
            timestamp: Date(timeIntervalSince1970: timestamp),
            isRelay: false,
            isPrivate: true,
            recipientNickname: recipient,
            senderPeerID: peerID
        )
    }

    @MainActor
    func waitUntil(
        timeout: TimeInterval = TestConstants.settleTimeout,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
