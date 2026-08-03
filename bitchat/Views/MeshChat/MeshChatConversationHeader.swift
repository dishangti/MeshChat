// SPDX-License-Identifier: MIT

import BitFoundation
import SwiftUI

/// A compact conversation header that keeps transport and trust states
/// distinct instead of flattening them into a generic online/offline dot.
struct MeshChatConversationHeader: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @ThemedPalette private var palette

    @State private var carriedMailCount = 0
    @State private var pendingHistoryDeletion: ConversationID?
    @State private var pendingFriendAddition: FriendAdditionTarget?
    @State private var pendingFriendRemoval: HeaderFriendRemovalTarget?

    let onOpenHome: () -> Void
    let onOpenLocations: () -> Void
    let onOpenNotices: () -> Void
    let onOpenSettings: () -> Void
    let onOpenVerification: () -> Void
    let onShareChannel: (String) -> Void

    private var privateHeader: PrivateConversationHeaderState? {
        privateConversationModel.selectedHeaderState
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenHome) {
                Image(systemName: "house")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                AppLanguageSettings.localized(
                     "content.accessibility.home",
                    defaultValue: "Home",
                    comment: "Accessibility label for returning from a conversation to the MeshChat home screen"
                )
            )

            Button(action: primaryHeaderAction) {
                HStack(spacing: 10) {
                    conversationAvatar

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(conversationTitle)
                                .font(.headline)
                                .foregroundStyle(palette.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if let identityLockState = privateHeader?.identityLockState {
                                Image(systemName: identityLockState.icon)
                                    .font(.caption)
                                    .foregroundStyle(identityLockState.color)
                                    .accessibilityLabel(
                                        identityLockState.accessibilityDescription
                                    )
                            }
                        }

                        HStack(spacing: 5) {
                            if let statusSymbol {
                                Image(systemName: statusSymbol)
                                    .font(.caption2)
                            }
                            Text(conversationSubtitle)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .foregroundStyle(subtitleColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            if let privateHeader, privateHeader.supportsFriendAction {
                Button(role: privateHeader.isFavorite ? .destructive : nil) {
                    if privateHeader.isFavorite {
                        pendingFriendRemoval = friendRemovalTarget(
                            for: privateHeader
                        )
                    } else {
                        pendingFriendAddition = FriendAdditionTarget(
                            peerID: privateHeader.headerPeerID,
                            displayName: privateHeader.displayName
                        )
                    }
                } label: {
                    Image(
                        systemName: privateHeader.isFavorite
                            ? "star.fill"
                            : "person.badge.plus"
                    )
                        .foregroundStyle(privateHeader.isFavorite ? Color.yellow : palette.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    privateHeader.isFavorite
                        ? AppLanguageSettings.localized("content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite")
                        : AppLanguageSettings.localized("content.accessibility.add_favorite", comment: "Accessibility label to add a favorite")
                )
            }

            if privateHeader == nil {
                Button(action: onOpenLocations) {
                    Image(systemName: locationChannelSymbol)
                        .foregroundStyle(locationChannelColor)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    AppLanguageSettings.localized(
                         "content.accessibility.location_channels",
                        comment: "Accessibility label for the location channels button"
                    )
                )
            }

            Button(action: onOpenNotices) {
                Image(systemName: "pin")
                    .foregroundStyle(palette.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                AppLanguageSettings.localized(
                     "content.accessibility.notices",
                    defaultValue: "Notices",
                    comment: "Accessibility label for the notices button"
                )
            )

            Menu {
                Button(action: onOpenVerification) {
                    Label("verification.qr.title", systemImage: "qrcode.viewfinder")
                }

                if privateHeader == nil, case .location(let channel) = locationChannelsModel.selectedChannel {
                    Button {
                        locationChannelsModel.toggleBookmark(channel.geohash)
                    } label: {
                        Label(
                            locationChannelsModel.isBookmarked(channel.geohash)
                                ? "location_channels.accessibility.remove_bookmark"
                                : "location_channels.accessibility.add_bookmark",
                            systemImage: locationChannelsModel.isBookmarked(channel.geohash)
                                ? "bookmark.slash"
                                : "bookmark"
                        )
                    }

                    Button {
                        onShareChannel(channel.geohash)
                    } label: {
                        Label("channel.share.action", systemImage: "square.and.arrow.up")
                    }
                }

                if let privateHeader, !privateHeader.isGroupConversation {
                    Button {
                        appChromeModel.showNicknameEditor(for: privateHeader.headerPeerID)
                    } label: {
                        Label("fingerprint.local_alias.label", systemImage: "person.text.rectangle")
                    }

                    Button {
                        appChromeModel.showFingerprint(for: privateHeader.headerPeerID)
                    } label: {
                        Label("mesh_peers.action.fingerprint", systemImage: "checkmark.seal")
                    }

                    if privateHeader.isFavorite {
                        Button(role: .destructive) {
                            pendingFriendRemoval = friendRemovalTarget(
                                for: privateHeader
                            )
                        } label: {
                            Label(
                                AppLanguageSettings.localized(
                                     "content.accessibility.remove_favorite",
                                    defaultValue: "Remove Friend",
                                    comment: "Conversation menu action that removes a friend"
                                ),
                                systemImage: "person.badge.minus"
                            )
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    pendingHistoryDeletion = currentConversationID
                } label: {
                    Label(
                        AppLanguageSettings.localized(
                             "content.clear.confirm_action",
                            defaultValue: "Delete Chat History",
                            comment: "Conversation menu action that deletes the current chat history"
                        ),
                        systemImage: "trash"
                    )
                }

                Divider()

                Button(action: onOpenSettings) {
                    Label("app_info.tab.settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(
                AppLanguageSettings.localized(
                     "content.actions.title",
                    defaultValue: "Actions",
                    comment: "Accessibility label for the conversation actions menu"
                )
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 0.5)
        }
        .onAppear {
            locationChannelsModel.refreshMeshChannelsIfNeeded()
        }
        .onReceive(CourierStore.shared.$carriedCount) { count in
            carriedMailCount = count
        }
        .sheet(
            item: $pendingFriendAddition,
            onDismiss: { pendingFriendAddition = nil }
        ) { target in
            FriendAdditionSheetView(target: target) { localNickname in
                privateConversationModel.addFriend(
                    peerID: target.peerID,
                    localNickname: localNickname
                )
            }
        }
        .confirmationDialog(
            AppLanguageSettings.localized(
                 "content.clear.confirm_title",
                defaultValue: "Delete Chat History?",
                comment: "Title confirming deletion of the current chat history"
            ),
            isPresented: historyDeletionConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let target = pendingHistoryDeletion {
                Button(
                    AppLanguageSettings.localized(
                         "content.clear.confirm_action",
                        defaultValue: "Delete Chat History",
                        comment: "Destructive action that deletes the current chat history"
                    ),
                    role: .destructive
                ) {
                    conversationUIModel.clearConversationHistory(target)
                    pendingHistoryDeletion = nil
                }
            }
            Button("common.cancel", role: .cancel) {
                pendingHistoryDeletion = nil
            }
        } message: {
            Text(
                AppLanguageSettings.localized(
                     "content.clear.confirm_message",
                    defaultValue: "This deletes the chat history stored on this device. Other participants keep their copies.",
                    comment: "Explanation shown before deleting the current chat history"
                )
            )
        }
        .confirmationDialog(
            friendRemovalConfirmationTitle,
            isPresented: friendRemovalConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let target = pendingFriendRemoval {
                Button(
                    AppLanguageSettings.localized(
                         "content.accessibility.remove_favorite",
                        defaultValue: "Remove Friend",
                        comment: "Destructive action that removes a friend"
                    ),
                    role: .destructive
                ) {
                    peerListModel.removeFriend(peerID: target.peerID)
                    pendingFriendRemoval = nil
                }
            }
            Button("common.cancel", role: .cancel) {
                pendingFriendRemoval = nil
            }
        } message: {
            Text(
                AppLanguageSettings.localized(
                     "friends.remove.confirm_message",
                    defaultValue: "This only removes the friend relationship. Chat history, local nickname, block status, and verification are kept.",
                    comment: "Explanation shown before removing a friend"
                )
            )
        }
    }
}

struct FriendAdditionTarget: Identifiable {
    let peerID: PeerID
    let displayName: String

    var id: String { peerID.id }
}

private struct HeaderFriendRemovalTarget {
    let peerID: PeerID
    let displayName: String
}

struct FriendAdditionSheetView: View {
    private enum Feedback {
        case invalidNickname
        case persistenceFailed
    }

    private enum Strings {
        static let invalidNickname: LocalizedStringKey =
            "fingerprint.local_alias.invalid"
        static let persistenceFailed: LocalizedStringKey =
            "verification.scan.status.persistence_failed"
    }

    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette
    @State private var nicknameDraft = ""
    @State private var feedback: Feedback?

    let target: FriendAdditionTarget
    let onAdd: (String?) -> Bool

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("friends.action.add")
                    .bitchatFont(size: 16, weight: .bold)
                Spacer()
                SheetCloseButton { dismiss() }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: target.displayName)
                    .bitchatFont(size: 18, weight: .semibold)

                Text("fingerprint.local_alias.label")
                    .bitchatFont(size: 12, weight: .bold)
                    .foregroundColor(palette.secondary)

                TextField(
                    AppLanguageSettings.localized(
                        "fingerprint.local_alias.placeholder",
                        defaultValue: "Nickname on this device",
                        comment: "Placeholder for an optional device-local nickname while adding a friend"
                    ),
                    text: $nicknameDraft
                )
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .onSubmit(addFriend)
                .onChange(of: nicknameDraft) { _ in feedback = nil }
                .accessibilityIdentifier("add-friend-local-nickname-field")

                Text("friends.add.nickname_optional_hint")
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)

                if let feedback {
                    Label(
                        feedback == .invalidNickname
                            ? Strings.invalidNickname
                            : Strings.persistenceFailed,
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .bitchatFont(size: 11, weight: .medium)
                    .foregroundColor(.orange)
                }
            }

            Button("friends.action.add", action: addFriend)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 460, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .themedSheetBackground()
    }

    private func addFriend() {
        let trimmed = nicknameDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let localNickname: String?
        if trimmed.isEmpty {
            localNickname = nil
        } else if let validated = InputValidator.validateNickname(trimmed) {
            localNickname = validated
        } else {
            feedback = .invalidNickname
            return
        }

        guard onAdd(localNickname) else {
            feedback = .persistenceFailed
            return
        }
        dismiss()
    }
}

private extension MeshChatConversationHeader {
    var currentConversationID: ConversationID {
        if let privateHeader {
            return .directPeer(privateHeader.conversationPeerID)
        }
        return ConversationID(channelID: locationChannelsModel.selectedChannel)
    }

    var historyDeletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingHistoryDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingHistoryDeletion = nil
                }
            }
        )
    }

    var friendRemovalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingFriendRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingFriendRemoval = nil
                }
            }
        )
    }

    var friendRemovalConfirmationTitle: String {
        guard let target = pendingFriendRemoval else { return "" }
        let format = AppLanguageSettings.localized(
             "friends.remove.confirm_title",
            defaultValue: "Remove %@ from Friends?",
            comment: "Title confirming removal of a named friend"
        )
        return String(
            format: format,
            locale: .current,
            target.displayName
        )
    }

    func friendRemovalTarget(
        for header: PrivateConversationHeaderState
    ) -> HeaderFriendRemovalTarget {
        let stablePeerID: PeerID
        if header.conversationPeerID.noiseKey != nil {
            stablePeerID = header.conversationPeerID
        } else if let peer = peerListModel.allPeers.first(where: {
            $0.peerID == header.headerPeerID && $0.noisePublicKey.count == 32
        }) {
            stablePeerID = PeerID(hexData: peer.noisePublicKey)
        } else {
            stablePeerID = header.headerPeerID
        }
        return HeaderFriendRemovalTarget(
            peerID: stablePeerID,
            displayName: header.displayName
        )
    }

    var conversationTitle: String {
        if let privateHeader { return privateHeader.displayName }
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            return AppLanguageSettings.localized(
                 "location_channels.mesh_label",
                defaultValue: "#mesh",
                comment: "Name of the local mesh channel"
            )
        case .location(let channel):
            return "#\(channel.geohash.lowercased())"
        }
    }

    var conversationSubtitle: String {
        if let privateHeader {
            if privateHeader.isGroupConversation {
                return AppLanguageSettings.localized(
                     "content.accessibility.group_chat",
                    comment: "Accessibility label for the group chat indicator"
                )
            }
            switch privateHeader.availability {
            case .bluetoothConnected:
                return AppLanguageSettings.localized(
                     "content.accessibility.connected_mesh",
                    comment: "Accessibility label for mesh-connected peer indicator"
                )
            case .meshReachable:
                return AppLanguageSettings.localized(
                     "content.accessibility.reachable_mesh",
                    comment: "Accessibility label for mesh-reachable peer indicator"
                )
            case .nostrAvailable:
                return AppLanguageSettings.localized(
                     "content.accessibility.available_nostr",
                    comment: "Accessibility label for Nostr-available peer indicator"
                )
            case .offline:
                return AppLanguageSettings.localized(
                     "mesh_peers.state.offline",
                    comment: "State label for a peer that is not currently reachable"
                )
            }
        }

        let count: Int
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            count = peerListModel.reachableMeshPeerCount + bridgeService.bridgedPeerCount
        case .location:
            count = peerListModel.visibleGeohashPeerCount
        }
        let format = AppLanguageSettings.localized(
             "content.accessibility.people_count",
            comment: "Accessibility label announcing number of people in header"
        )
        return String(format: format, locale: .current, count)
    }

    var statusSymbol: String? {
        guard let privateHeader else {
            if carriedMailCount > 0 { return "figure.walk" }
            if locationChannelsModel.gatewayEnabled { return "globe" }
            return nil
        }
        if privateHeader.isGroupConversation { return "person.3.fill" }
        switch privateHeader.availability {
        case .bluetoothConnected:
            return "dot.radiowaves.left.and.right"
        case .meshReachable:
            return "point.3.filled.connected.trianglepath.dotted"
        case .nostrAvailable:
            return "globe"
        case .offline:
            return "antenna.radiowaves.left.and.right.slash"
        }
    }

    var subtitleColor: Color {
        guard let privateHeader else { return palette.secondary }
        switch privateHeader.availability {
        case .bluetoothConnected, .meshReachable:
            return palette.accent
        case .nostrAvailable:
            return .purple
        case .offline:
            return palette.secondary
        }
    }

    @ViewBuilder
    var conversationAvatar: some View {
        let symbol: String = {
            if let privateHeader {
                return privateHeader.isGroupConversation ? "person.3.fill" : "person.fill"
            }
            switch locationChannelsModel.selectedChannel {
            case .mesh: return "antenna.radiowaves.left.and.right"
            case .location: return "location.fill"
            }
        }()

        ZStack {
            Circle()
                .fill(avatarGradient)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    var avatarGradient: LinearGradient {
        let colors: [Color]
        if privateHeader != nil {
            colors = [.orange, .pink]
        } else {
            switch locationChannelsModel.selectedChannel {
            case .mesh:
                colors = [.blue, .cyan]
            case .location:
                colors = [.green, .teal]
            }
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var locationChannelSymbol: String {
        switch locationChannelsModel.selectedChannel {
        case .mesh: return "antenna.radiowaves.left.and.right"
        case .location: return "location.fill"
        }
    }

    var locationChannelColor: Color {
        switch locationChannelsModel.selectedChannel {
        case .mesh: return .blue
        case .location: return .green
        }
    }

    func primaryHeaderAction() {
        if let privateHeader, !privateHeader.isGroupConversation {
            appChromeModel.showFingerprint(for: privateHeader.headerPeerID)
        } else if privateHeader == nil {
            onOpenHome()
        }
    }
}
