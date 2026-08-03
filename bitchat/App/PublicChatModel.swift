import BitFoundation
import Combine
import SwiftUI

/// Feature model for the active public (mesh/geohash) timeline.
///
/// Observes ONE `Conversation` object in the single-writer
/// `ConversationStore` — the active channel's. It also owns the lightweight,
/// per-channel unread-ID sets used by directory badges; private-chat mutations
/// still do not invalidate this model.
/// `messages` reads the observed conversation's backing array directly;
/// there is no mirror copy.
@MainActor
final class PublicChatModel: ObservableObject {
    @Published private(set) var activeChannel: ChannelID
    @Published private var unreadMessageIDsByConversation: [ConversationID: Set<String>] = [:]

    /// The active public conversation's timeline.
    var messages: [BitchatMessage] { activeConversation.messages }

    /// Unread human messages received while this public channel was not the
    /// visible conversation. Reading a badge never creates a conversation.
    func unreadMessageCount(for channel: ChannelID) -> Int {
        let id = ConversationID(channelID: channel)
        return unreadMessageIDsByConversation[id]?.count ?? 0
    }

    /// Updates which public channel is actually on screen. Passing `nil`
    /// covers Home, a private conversation, and inactive app scenes.
    func setVisibleChannel(_ channel: ChannelID?) {
        let nextID = channel.map(ConversationID.init(channelID:))
        visibleConversationID = nextID
        if let nextID {
            clearUnreadMessages(in: nextID)
        }
    }

    private let conversations: ConversationStore
    private var activeConversation: Conversation
    private var visibleConversationID: ConversationID?
    private var activeConversationCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(conversations: ConversationStore) {
        let channel = conversations.activeChannel
        self.conversations = conversations
        self.activeChannel = channel
        self.activeConversation = conversations.conversation(for: ConversationID(channelID: channel))

        observeActiveConversation()
        bind()
    }

    private func bind() {
        conversations.$activeChannel
            .dropFirst()
            .sink { [weak self] channel in
                guard let self else { return }
                self.activeChannel = channel
                self.retargetActiveConversation(to: channel)
            }
            .store(in: &cancellables)

        // The store replaces a conversation's object when it is removed
        // (panic clear); retarget to the fresh instance so the observation
        // never goes stale.
        conversations.changes
            .sink { [weak self] change in
                guard let self else { return }

                switch change {
                case .appended(let id, let message):
                    self.trackUnreadMessage(message, in: id)

                case .updated(let id, let messageID):
                    self.reconcileUnreadMessage(withID: messageID, in: id)

                case .messageRemoved(let id, let messageID):
                    self.removeUnreadMessage(withID: messageID, from: id)

                case .cleared(let id):
                    self.clearUnreadMessages(in: id)

                case .removed(let id):
                    self.clearUnreadMessages(in: id)
                    if id == self.activeConversation.id {
                        self.retargetActiveConversation(to: self.activeChannel)
                    }

                case .migrated(let source, let destination):
                    self.migrateUnreadMessages(from: source, to: destination)

                case .statusChanged, .unreadChanged:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func trackUnreadMessage(_ message: BitchatMessage, in id: ConversationID) {
        guard isPublicConversation(id),
              id != visibleConversationID,
              countsAsUnread(message) else { return }

        var updated = unreadMessageIDsByConversation
        var messageIDs = updated[id, default: []]
        guard messageIDs.insert(message.id).inserted else { return }
        updated[id] = messageIDs
        unreadMessageIDsByConversation = updated
    }

    private func reconcileUnreadMessage(withID messageID: String, in id: ConversationID) {
        guard unreadMessageIDsByConversation[id]?.contains(messageID) == true else { return }
        guard let message = conversations.conversationsByID[id]?.message(withID: messageID),
              countsAsUnread(message) else {
            removeUnreadMessage(withID: messageID, from: id)
            return
        }
    }

    private func removeUnreadMessage(withID messageID: String, from id: ConversationID) {
        var updated = unreadMessageIDsByConversation
        guard var messageIDs = updated[id], messageIDs.remove(messageID) != nil else { return }
        if messageIDs.isEmpty {
            updated.removeValue(forKey: id)
        } else {
            updated[id] = messageIDs
        }
        unreadMessageIDsByConversation = updated
    }

    private func clearUnreadMessages(in id: ConversationID) {
        var updated = unreadMessageIDsByConversation
        guard updated.removeValue(forKey: id) != nil else { return }
        unreadMessageIDsByConversation = updated
    }

    private func migrateUnreadMessages(from source: ConversationID, to destination: ConversationID) {
        var updated = unreadMessageIDsByConversation
        guard let sourceIDs = updated.removeValue(forKey: source) else { return }
        if isPublicConversation(destination), destination != visibleConversationID {
            updated[destination, default: []].formUnion(sourceIDs)
        }
        unreadMessageIDsByConversation = updated
    }

    private func isPublicConversation(_ id: ConversationID) -> Bool {
        switch id {
        case .mesh, .geohash:
            return true
        case .direct:
            return false
        }
    }

    private func countsAsUnread(_ message: BitchatMessage) -> Bool {
        message.sender != "system"
            && !message.content.trimmed.isEmpty
            && !message.isArchivedEcho
    }

    private func retargetActiveConversation(to channel: ChannelID) {
        let conversation = conversations.conversation(for: ConversationID(channelID: channel))
        guard conversation !== activeConversation else {
            // Same object (e.g. re-selected channel): keep the existing
            // observation, but `messages` may still differ from what views
            // last rendered, so republish.
            objectWillChange.send()
            return
        }
        objectWillChange.send()
        activeConversation = conversation
        observeActiveConversation()
    }

    private func observeActiveConversation() {
        activeConversationCancellable = activeConversation.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}
