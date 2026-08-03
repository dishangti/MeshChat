// SPDX-License-Identifier: MIT

import BitFoundation
import Foundation
import SwiftUI

/// A conversation-first sidebar for the MeshChat shell.
///
/// This view intentionally owns presentation only. Channel selection is
/// committed through `LocationChannelsModel`; opening a private or group
/// conversation is delegated to the shell so there is still a single owner
/// for navigation state.
struct MeshChatSidebarView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var privateInboxModel: PrivateInboxModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @ObservedObject private var bridgeService = BridgeService.shared

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ThemedPalette private var palette

    @State private var searchText = ""
    @State private var pendingFriendRemoval: SidebarFriendRemovalTarget?
    @State private var pendingRecentChatDeletion: RecentChatDeletionTarget?
    @FocusState private var isNicknameFocused: Bool

    let activePeerID: PeerID?
    let showsConversationSelection: Bool
    let onOpenChannel: (ChannelID) -> Void
    let onOpenPeer: (PeerID) -> Void
    let onOpenLocations: () -> Void
    let onOpenNotices: () -> Void
    let onOpenAppInfo: () -> Void
    let onOpenSettings: () -> Void
    let onOpenVerification: () -> Void
    let onPanic: () -> Void
    var onDeleteActiveRecent: () -> Void = {}

    private enum Strings {
        static var people: String {
            AppLanguageSettings.localized(
             "content.header.people",
            comment: "Title for the people list sheet"
            )
        }
        static var friends: String {
            AppLanguageSettings.localized(
             "mesh_peers.section.friends",
            defaultValue: "Friends",
            comment: "Section title for saved mesh friends"
            )
        }
        static var nearbySection: String {
            AppLanguageSettings.localized(
             "mesh_peers.section.nearby",
            defaultValue: "Nearby",
            comment: "Section title for nearby mesh people who are not friends"
            )
        }
        static var recent: String {
            AppLanguageSettings.localized(
             "mesh_peers.section.recent",
            defaultValue: "Recent",
            comment: "Section title for offline non-friends with direct-message history"
            )
        }
        static var channels: String {
            AppLanguageSettings.localized(
             "location_channels.title",
            comment: "Title for location channels"
            )
        }
        static let locationMenu = "#location"
        static var mesh: String {
            AppLanguageSettings.localized(
             "location_channels.mesh_label",
            comment: "Label for the mesh channel row"
            )
        }
        static var bookmarks: String {
            AppLanguageSettings.localized(
             "location_channels.bookmarked_section_title",
            comment: "Section title for bookmarked location channels"
            )
        }
        static var groups: String {
            AppLanguageSettings.localized(
             "groups.section.header",
            comment: "Section header above the private groups list"
            )
        }
        static var notices: String {
            AppLanguageSettings.localized(
             "notices.title",
            defaultValue: "Notices",
            comment: "Title of the notices surface"
            )
        }
        static var scanQRCode: String {
            AppLanguageSettings.localized(
             "verification.qr.title",
            defaultValue: "QR Code",
            comment: "Action that opens the global identity QR screen"
            )
        }
        static var setNickname: String {
            AppLanguageSettings.localized(
             "fingerprint.local_alias.label",
            defaultValue: "Local Nickname",
            comment: "Action that opens the local nickname editor"
            )
        }
        static var settings: String {
            AppLanguageSettings.localized(
             "app_info.tab.settings",
            defaultValue: "Settings",
            comment: "Settings pane label"
            )
        }

        static var connected: String {
            AppLanguageSettings.localized(
             "content.accessibility.connected_mesh",
            comment: "State label for a directly connected mesh peer"
            )
        }
        static var reachable: String {
            AppLanguageSettings.localized(
             "content.accessibility.reachable_mesh",
            comment: "State label for a peer reachable through the mesh"
            )
        }
        static var nostr: String {
            AppLanguageSettings.localized(
             "content.accessibility.available_nostr",
            comment: "State label for a peer available through Nostr"
            )
        }
        static var offline: String {
            AppLanguageSettings.localized(
             "mesh_peers.state.offline",
            comment: "State label for an unavailable peer"
            )
        }
        static var favorite: String {
            AppLanguageSettings.localized(
             "mesh_peers.state.favorite",
            comment: "State label for a favorite peer"
            )
        }
        static var unread: String {
            AppLanguageSettings.localized(
             "mesh_peers.state.unread",
            comment: "State label for an unread conversation"
            )
        }
        static var blocked: String {
            AppLanguageSettings.localized(
             "mesh_peers.state.blocked",
            comment: "State label for a blocked peer"
            )
        }
        static var vouched: String {
            AppLanguageSettings.localized(
             "mesh_peers.state.vouched",
            comment: "State label for a vouched peer"
            )
        }
        static var creator: String {
            AppLanguageSettings.localized(
             "groups.state.creator",
            comment: "State label for a group creator"
            )
        }

        static var directMessage: String {
            AppLanguageSettings.localized(
             "content.actions.direct_message",
            comment: "Action opening a direct message"
            )
        }
        static var showFingerprint: String {
            AppLanguageSettings.localized(
             "mesh_peers.action.fingerprint",
            comment: "Action opening a peer's fingerprint and verification screen"
            )
        }
        static var addFavorite: String {
            AppLanguageSettings.localized(
             "friends.action.add",
            comment: "Action adding a friend"
            )
        }
        static var removeFavorite: String {
            AppLanguageSettings.localized(
             "content.accessibility.remove_favorite",
            comment: "Action removing a favorite"
            )
        }
        static var deleteRecentChat: String {
            AppLanguageSettings.localized(
             "recent_chat.delete.action",
            defaultValue: "Delete Chat",
            comment: "Action deleting a chat from the Recent section"
            )
        }
        static var block: String {
            AppLanguageSettings.localized(
             "geohash_people.action.block",
            comment: "Action blocking a peer"
            )
        }
        static var unblock: String {
            AppLanguageSettings.localized(
             "geohash_people.action.unblock",
            comment: "Action unblocking a peer"
            )
        }
        static var openDMHint: String {
            AppLanguageSettings.localized(
             "mesh_peers.accessibility.open_dm_hint",
            comment: "Hint for opening a private chat"
            )
        }
        static var appInfoHint: String {
            AppLanguageSettings.localized(
             "meshchat.help.open_hint",
            comment: "Hint for opening Help from the brand header"
            )
        }
        static var noneNearby: String {
            AppLanguageSettings.localized(
             "geohash_people.none_nearby",
            comment: "Empty people-list state"
            )
        }
        static var teleported: String {
            AppLanguageSettings.localized(
             "geohash_people.state.teleported",
            comment: "State label for someone who joined the location channel remotely"
            )
        }
        static var nearby: String {
            AppLanguageSettings.localized(
             "geohash_people.state.nearby",
            comment: "State label for someone physically near the location channel"
            )
        }
        static var you: String {
            AppLanguageSettings.localized(
             "geohash_people.state.you",
            comment: "State label marking the current user"
            )
        }
        static var cancel: String {
            AppLanguageSettings.localized(
             "common.cancel",
            comment: "Cancel action"
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            accountHeader
            searchField

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    publicChannelsSection
                    groupsSection
                    peersSection

                    if hasSearchQuery && !hasConversationSearchResults {
                        Text(verbatim: Strings.noneNearby)
                            .bitchatFont(size: 13)
                            .foregroundColor(palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()
            utilityBar
        }
        .frame(minWidth: 280, idealWidth: 320, maxHeight: .infinity)
        .background(ThemedRootBackground())
        .foregroundColor(palette.primary)
        .confirmationDialog(
            friendRemovalConfirmationTitle,
            isPresented: friendRemovalConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let target = pendingFriendRemoval {
                Button(Strings.removeFavorite, role: .destructive) {
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
        .confirmationDialog(
            recentChatDeletionConfirmationTitle,
            isPresented: recentChatDeletionConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let target = pendingRecentChatDeletion {
                Button(Strings.deleteRecentChat, role: .destructive) {
                    let activePeerAtConfirmation = activePeerID
                    let wasShowingConversation = showsConversationSelection
                    let deletedPeerID = peerListModel.deleteRecentChat(
                        fingerprint: target.fingerprint
                    )
                    pendingRecentChatDeletion = nil
                    if MeshChatRecentDeletionNavigation.shouldShowHome(
                        afterDeleting: deletedPeerID,
                        activePeerID: activePeerAtConfirmation,
                        wasShowingConversation: wasShowingConversation
                    ) {
                        onDeleteActiveRecent()
                    }
                }
            }
            Button("common.cancel", role: .cancel) {
                pendingRecentChatDeletion = nil
            }
        } message: {
            Text(
                AppLanguageSettings.localized(
                     "recent_chat.delete.confirm_message",
                    defaultValue: "This deletes the local chat history and removes this person from Recent. Their local nickname, block status, and verification are kept. New messages can make the chat appear again.",
                    comment: "Explanation shown before deleting a Recent chat"
                )
            )
        }
    }
}

private struct SidebarFriendRemovalTarget {
    let peerID: PeerID
    let displayName: String
}

private struct RecentChatDeletionTarget {
    let fingerprint: String
    let displayName: String
}

private extension MeshChatSidebarView {
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

    var recentChatDeletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRecentChatDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRecentChatDeletion = nil
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

    var recentChatDeletionConfirmationTitle: String {
        guard let target = pendingRecentChatDeletion else { return "" }
        let format = AppLanguageSettings.localized(
             "recent_chat.delete.confirm_title",
            defaultValue: "Delete Chat with %@?",
            comment: "Title confirming deletion of a named Recent chat"
        )
        return String(
            format: format,
            locale: .current,
            target.displayName
        )
    }

    func friendRemovalTarget(
        for peer: MeshPeerRow
    ) -> SidebarFriendRemovalTarget {
        let stablePeerID: PeerID
        if let livePeer = peerListModel.allPeers.first(where: {
            $0.peerID == peer.peerID && $0.noisePublicKey.count == 32
        }) {
            stablePeerID = PeerID(hexData: livePeer.noisePublicKey)
        } else {
            stablePeerID = peer.peerID
        }
        return SidebarFriendRemovalTarget(
            peerID: stablePeerID,
            displayName: peer.displayName
        )
    }
}

enum MeshChatRecentDeletionNavigation {
    static func shouldShowHome(
        afterDeleting deletedPeerID: PeerID?,
        activePeerID: PeerID?,
        wasShowingConversation: Bool
    ) -> Bool {
        guard wasShowingConversation,
              let deletedPeerID,
              let activePeerID else {
            return false
        }
        return activePeerID == deletedPeerID
            || activePeerID.toShort() == deletedPeerID.toShort()
    }
}

// MARK: - Header and search

private extension MeshChatSidebarView {
    var accountHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(palette.accent.opacity(0.18))
                Text(verbatim: nicknameInitial)
                    .bitchatFont(size: 17, weight: .semibold)
                    .foregroundColor(palette.accent)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .onTapGesture(count: 3, perform: onPanic)
            .onTapGesture(count: 1, perform: onOpenAppInfo)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("app_info.app_name")
            .accessibilityHint(Strings.appInfoHint)

            VStack(alignment: .leading, spacing: 2) {
                Text("app_info.app_name")
                    .bitchatFont(size: 17, weight: .semibold)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 3, perform: onPanic)
                    .onTapGesture(count: 1, perform: onOpenAppInfo)

                HStack(spacing: 1) {
                    Text(verbatim: "@")
                        .foregroundColor(palette.secondary)
                    TextField(
                        "content.input.nickname_placeholder",
                        text: Binding(
                            get: { appChromeModel.nickname },
                            set: { appChromeModel.setNickname($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .focused($isNicknameFocused)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .modifier(FocusEffectDisabledModifier())
                    .onSubmit {
                        appChromeModel.validateAndSaveNickname()
                    }
                    .onChange(of: isNicknameFocused) { focused in
                        if !focused {
                            appChromeModel.validateAndSaveNickname()
                        }
                    }
                }
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.bitchatSystem(size: 15, weight: .semibold))
                    .foregroundColor(palette.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.settings)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.bitchatSystem(size: 13))
                .foregroundColor(palette.secondary)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $searchText,
                prompt: Text(verbatim: Strings.people)
                    .foregroundColor(palette.secondary.opacity(0.75))
            )
            .textFieldStyle(.plain)
            .bitchatFont(size: 14)
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .modifier(FocusEffectDisabledModifier())
            .accessibilityLabel(Strings.people)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.bitchatSystem(size: 15))
                        .foregroundColor(palette.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.cancel)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.secondary.opacity(0.1))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    var nicknameInitial: String {
        let trimmed = appChromeModel.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased(with: .current)
    }
}

// MARK: - Conversation sections

private extension MeshChatSidebarView {
    @ViewBuilder
    var publicChannelsSection: some View {
        if showsMeshChannel || showsCurrentLocation || !filteredBookmarks.isEmpty {
            sidebarSectionHeader(icon: "bubble.left.and.bubble.right.fill", title: Strings.channels)

            if showsMeshChannel {
                channelRow(
                    title: Strings.mesh,
                    subtitle: nil,
                    icon: "antenna.radiowaves.left.and.right",
                    count: peerListModel.reachableMeshPeerCount,
                    isSelected: showsConversationSelection && locationChannelsModel.selectedChannel.isMesh
                ) {
                    openChannel(.mesh)
                }
            }

            if case .location(let channel) = locationChannelsModel.selectedChannel,
               matchesCurrentLocation(channel) {
                channelRow(
                    title: "#\(channel.geohash)",
                    subtitle: channel.level.displayName,
                    icon: "number",
                    count: peerListModel.participantCount(for: channel.geohash),
                    isSelected: showsConversationSelection
                ) {
                    openChannel(.location(channel))
                }
            }

            if !filteredBookmarks.isEmpty {
                sidebarSubsectionLabel(Strings.bookmarks)
                ForEach(filteredBookmarks, id: \.self) { geohash in
                    channelRow(
                        title: "#\(geohash)",
                        subtitle: locationChannelsModel.bookmarkNames[geohash],
                        icon: "bookmark.fill",
                        count: peerListModel.participantCount(for: geohash),
                        isSelected: isSelected(geohash: geohash)
                    ) {
                        openBookmarkedChannel(geohash)
                    }
                    .onAppear {
                        locationChannelsModel.resolveBookmarkNameIfNeeded(for: geohash)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var groupsSection: some View {
        if !filteredGroups.isEmpty {
            sidebarSectionHeader(icon: "person.3.fill", title: Strings.groups)

            ForEach(filteredGroups) { group in
                groupRow(group)
            }
        }
    }

    @ViewBuilder
    var peersSection: some View {
        if case .location = locationChannelsModel.selectedChannel {
            if !filteredGeohashPeople.isEmpty {
                sidebarSectionHeader(icon: "mappin.and.ellipse", title: Strings.people)
                ForEach(filteredGeohashPeople) { person in
                    geohashPersonRow(person)
                }
            }
        } else {
            if !filteredFriends.isEmpty {
                sidebarSectionHeader(icon: "star.fill", title: Strings.friends)

                ForEach(filteredFriends) { peer in
                    peerRow(peer)
                }
            }

            if !filteredRecentPeers.isEmpty {
                sidebarSectionHeader(icon: "clock.fill", title: Strings.recent)

                ForEach(filteredRecentPeers) { peer in
                    recentPeerRow(peer)
                }
            }

            if !filteredNearbyPeers.isEmpty {
                sidebarSectionHeader(icon: "person.2.fill", title: Strings.nearbySection)

                ForEach(filteredNearbyPeers) { peer in
                    peerRow(peer)
                }
            }

            if !hasSearchQuery {
                BridgePeopleList()

                if filteredPeers.isEmpty
                    && filteredRecentPeers.isEmpty
                    && bridgeService.bridgedParticipants.isEmpty {
                    Text(verbatim: Strings.noneNearby)
                        .bitchatFont(size: 13)
                        .foregroundColor(palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    func sidebarSectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.bitchatSystem(size: 11, weight: .semibold))
            Text(verbatim: title)
                .bitchatFont(size: 12, weight: .semibold)
        }
        .foregroundColor(palette.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    func sidebarSubsectionLabel(_ title: String) -> some View {
        Text(verbatim: title)
            .bitchatFont(size: 11, weight: .medium)
            .foregroundColor(palette.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    func channelRow(
        title: String,
        subtitle: String?,
        icon: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.bitchatSystem(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? palette.accent : palette.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(
                            (isSelected ? palette.accent : palette.secondary).opacity(0.1)
                        )
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .bitchatFont(size: 14, weight: isSelected ? .semibold : .regular)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if count > 0 {
                    countBadge(count, emphasized: false)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.bitchatSystem(size: 11, weight: .bold))
                        .foregroundColor(palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(selectionBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(channelAccessibilityLabel(title: title, subtitle: subtitle, count: count))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func groupRow(_ group: GroupChatRow) -> some View {
        let hasUnread = group.hasUnread || privateInboxModel.unreadPeerIDs.contains(group.peerID)
        let isSelected = showsConversationSelection && activePeerID == group.peerID

        return Button {
            onOpenPeer(group.peerID)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(palette.secondary.opacity(0.12))
                    Image(systemName: "person.3.fill")
                        .font(.bitchatSystem(size: 13, weight: .semibold))
                        .foregroundColor(palette.primary)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(verbatim: "#\(group.name)")
                            .bitchatFont(size: 14, weight: hasUnread ? .semibold : .regular)
                            .foregroundColor(palette.primary)
                            .lineLimit(1)
                        if group.isCreator {
                            Image(systemName: "crown.fill")
                                .font(.bitchatSystem(size: 9))
                                .foregroundColor(.yellow)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(verbatim: groupMemberCount(group.memberCount))
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                }

                Spacer(minLength: 8)

                if hasUnread {
                    unreadBadge
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .background(selectionBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(groupAccessibilityLabel(group, hasUnread: hasUnread))
        .accessibilityHint(AppLanguageSettings.localized("groups.accessibility.open_group_hint"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func peerRow(_ peer: MeshPeerRow) -> some View {
        let hasUnread = peerHasUnread(peer)
        let isSelected = showsConversationSelection && activePeerID == peer.peerID
        let peerColor = peerListModel.colorForMeshPeer(
            id: peer.peerID,
            isDark: colorScheme == .dark
        )

        return Button {
            onOpenPeer(peer.peerID)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(peerColor.opacity(0.16))
                    Text(verbatim: peerInitial(peer.displayName))
                        .bitchatFont(size: 14, weight: .semibold)
                        .foregroundColor(peerColor)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: peer.displayName)
                        .bitchatFont(size: 14, weight: hasUnread ? .semibold : .regular)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Image(systemName: availabilityIcon(for: peer))
                            .font(.bitchatSystem(size: 9, weight: .medium))
                        Text(verbatim: availabilityText(for: peer))
                            .bitchatFont(size: 11)
                            .lineLimit(1)
                    }
                    .foregroundColor(availabilityColor(for: peer))
                }

                Spacer(minLength: 6)
                peerStatusBadges(peer, hasUnread: hasUnread)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .background(selectionBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Strings.directMessage) {
                onOpenPeer(peer.peerID)
            }
            if peer.isFavorite {
                Button(Strings.removeFavorite, role: .destructive) {
                    pendingFriendRemoval = friendRemovalTarget(for: peer)
                }
            } else {
                Button(Strings.addFavorite) {
                    _ = peerListModel.addFriend(peerID: peer.peerID)
                }
            }
            Button(Strings.setNickname) {
                appChromeModel.showNicknameEditor(for: peer.peerID)
            }
            Button(Strings.showFingerprint) {
                appChromeModel.showFingerprint(for: peer.peerID)
            }
            if peer.isBlocked {
                Button(Strings.unblock) {
                    conversationUIModel.unblock(
                        peerID: peer.peerID,
                        displayName: peer.displayName
                    )
                }
            } else {
                Button(Strings.block, role: .destructive) {
                    conversationUIModel.block(
                        peerID: peer.peerID,
                        displayName: peer.displayName
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peerAccessibilityLabel(peer, hasUnread: hasUnread))
        .accessibilityHint(Strings.openDMHint)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            onOpenPeer(peer.peerID)
        }
        .accessibilityActions {
            if peer.isFavorite {
                Button(Strings.removeFavorite, role: .destructive) {
                    pendingFriendRemoval = friendRemovalTarget(for: peer)
                }
            } else {
                Button(Strings.addFavorite) {
                    _ = peerListModel.addFriend(peerID: peer.peerID)
                }
            }
            Button(Strings.setNickname) {
                appChromeModel.showNicknameEditor(for: peer.peerID)
            }
            Button(Strings.showFingerprint) {
                appChromeModel.showFingerprint(for: peer.peerID)
            }
            Button(peer.isBlocked ? Strings.unblock : Strings.block) {
                if peer.isBlocked {
                    conversationUIModel.unblock(
                        peerID: peer.peerID,
                        displayName: peer.displayName
                    )
                } else {
                    conversationUIModel.block(
                        peerID: peer.peerID,
                        displayName: peer.displayName
                    )
                }
            }
        }
    }

    func recentPeerRow(_ peer: RecentMeshPeerRow) -> some View {
        let hasUnread = recentPeerHasUnread(peer)
        let isSelected = showsConversationSelection
            && (activePeerID.map(peer.conversationPeerIDs.contains) == true
                || activePeerID?.toShort() == peer.stablePeerID.toShort())
        let peerColor = peerListModel.colorForMeshPeer(
            id: peer.stablePeerID,
            isDark: colorScheme == .dark
        )

        return Button {
            openRecentPeer(peer)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(peerColor.opacity(0.16))
                    Text(verbatim: peerInitial(peer.displayName))
                        .bitchatFont(size: 14, weight: .semibold)
                        .foregroundColor(peerColor)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: peer.displayName)
                        .bitchatFont(size: 14, weight: hasUnread ? .semibold : .regular)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.bitchatSystem(size: 9, weight: .medium))
                            .accessibilityHidden(true)
                        Text(verbatim: Strings.offline)
                            .lineLimit(1)
                        Text(verbatim: "•")
                            .accessibilityHidden(true)
                        Text(peer.lastMessageAt, style: .relative)
                            .lineLimit(1)
                    }
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                }

                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    if hasUnread {
                        unreadBadge
                    }
                    Image(systemName: peer.identityLockState.icon)
                        .font(.bitchatSystem(size: 11))
                        .foregroundColor(peer.identityLockState.color)
                        .accessibilityHidden(true)
                    if peer.isBlocked {
                        Image(systemName: "nosign")
                            .font(.bitchatSystem(size: 11))
                            .foregroundColor(.red)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .background(selectionBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Strings.directMessage) {
                openRecentPeer(peer)
            }
            Button(Strings.addFavorite) {
                _ = peerListModel.addFriend(recentPeer: peer)
            }
            Button(Strings.setNickname) {
                appChromeModel.showNicknameEditor(for: peer.stablePeerID)
            }
            Button(Strings.showFingerprint) {
                appChromeModel.showFingerprint(for: peer.stablePeerID)
            }
            if peer.isBlocked {
                Button(Strings.unblock) {
                    conversationUIModel.unblock(
                        peerID: peer.stablePeerID,
                        displayName: peer.displayName
                    )
                }
            } else {
                Button(Strings.block, role: .destructive) {
                    conversationUIModel.block(
                        peerID: peer.stablePeerID,
                        displayName: peer.displayName
                    )
                }
            }
            Divider()
            Button(Strings.deleteRecentChat, role: .destructive) {
                pendingRecentChatDeletion = RecentChatDeletionTarget(
                    fingerprint: peer.fingerprint,
                    displayName: peer.displayName
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recentPeerAccessibilityLabel(peer, hasUnread: hasUnread))
        .accessibilityHint(Strings.openDMHint)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            openRecentPeer(peer)
        }
        .accessibilityActions {
            Button(Strings.addFavorite) {
                _ = peerListModel.addFriend(recentPeer: peer)
            }
            Button(Strings.setNickname) {
                appChromeModel.showNicknameEditor(for: peer.stablePeerID)
            }
            Button(Strings.showFingerprint) {
                appChromeModel.showFingerprint(for: peer.stablePeerID)
            }
            Button(peer.isBlocked ? Strings.unblock : Strings.block) {
                if peer.isBlocked {
                    conversationUIModel.unblock(
                        peerID: peer.stablePeerID,
                        displayName: peer.displayName
                    )
                } else {
                    conversationUIModel.block(
                        peerID: peer.stablePeerID,
                        displayName: peer.displayName
                    )
                }
            }
            Button(Strings.deleteRecentChat, role: .destructive) {
                pendingRecentChatDeletion = RecentChatDeletionTarget(
                    fingerprint: peer.fingerprint,
                    displayName: peer.displayName
                )
            }
        }
    }

    func geohashPersonRow(_ person: GeohashPersonRow) -> some View {
        let personColor = peerListModel.colorForGeohashPerson(
            id: person.id,
            isDark: colorScheme == .dark
        )
        let rowColor = person.isMe ? Color.orange : personColor

        return Button {
            guard !person.isMe else { return }
            peerListModel.openGeohashDirectMessage(with: person.id)
            // The model publishes the canonical routing PeerID. Defer one
            // turn so the shell can reveal that exact conversation without
            // trying to derive identity state in the view.
            DispatchQueue.main.async {
                if let selectedPeerID = privateConversationModel.selectedPeerID {
                    onOpenPeer(selectedPeerID)
                }
            }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(rowColor.opacity(0.16))
                    Image(systemName: person.isTeleported ? "face.dashed" : "mappin.and.ellipse")
                        .font(.bitchatSystem(size: 13, weight: .semibold))
                        .foregroundColor(rowColor)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: person.displayName)
                        .bitchatFont(size: 14, weight: person.isMe ? .semibold : .regular)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: person.isMe ? Strings.you : (person.isTeleported ? Strings.teleported : Strings.nearby))
                        .bitchatFont(size: 11)
                        .foregroundColor(person.isTeleported ? Color.purple : palette.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if person.isBlocked {
                    Image(systemName: "nosign")
                        .font(.bitchatSystem(size: 11))
                        .foregroundColor(.red)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(person.isMe)
        .contextMenu {
            if !person.isMe {
                Button(person.isBlocked ? Strings.unblock : Strings.block) {
                    if person.isBlocked {
                        peerListModel.unblockGeohashUser(
                            pubkeyHexLowercased: person.id,
                            displayName: person.displayName
                        )
                    } else {
                        peerListModel.blockGeohashUser(
                            pubkeyHexLowercased: person.id,
                            displayName: person.displayName
                        )
                    }
                }
            }
        }
        .accessibilityLabel(geohashPersonAccessibilityLabel(person))
        .accessibilityHint(person.isMe ? "" : Strings.openDMHint)
        .accessibilityActions {
            if !person.isMe {
                Button(person.isBlocked ? Strings.unblock : Strings.block) {
                    if person.isBlocked {
                        peerListModel.unblockGeohashUser(
                            pubkeyHexLowercased: person.id,
                            displayName: person.displayName
                        )
                    } else {
                        peerListModel.blockGeohashUser(
                            pubkeyHexLowercased: person.id,
                            displayName: person.displayName
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Status presentation

private extension MeshChatSidebarView {
    @ViewBuilder
    func peerStatusBadges(_ peer: MeshPeerRow, hasUnread: Bool) -> some View {
        HStack(spacing: 5) {
            if hasUnread {
                unreadBadge
            }

            Image(systemName: peer.identityLockState.icon)
                .font(.bitchatSystem(size: 11))
                .foregroundColor(peer.identityLockState.color)
                .accessibilityHidden(true)

            if peer.showsVouchedBadge {
                Image(systemName: "checkmark.seal")
                    .font(.bitchatSystem(size: 11))
                    .foregroundColor(.teal)
                    .accessibilityHidden(true)
            }

            if peer.isFavorite {
                Image(systemName: "star.fill")
                    .font(.bitchatSystem(size: 11))
                    .foregroundColor(.yellow)
                    .accessibilityHidden(true)
            }

            if peer.isBlocked {
                Image(systemName: "nosign")
                    .font(.bitchatSystem(size: 11))
                    .foregroundColor(.red)
                    .accessibilityHidden(true)
            }
        }
    }

    var unreadBadge: some View {
        Image(systemName: "envelope.fill")
            .font(.bitchatSystem(size: 10, weight: .semibold))
            .foregroundColor(.orange)
            .padding(5)
            .background(Circle().fill(Color.orange.opacity(0.13)))
            .accessibilityHidden(true)
    }

    func countBadge(_ count: Int, emphasized: Bool) -> some View {
        Text(verbatim: "\(count)")
            .bitchatFont(size: 11, weight: emphasized ? .bold : .medium)
            .foregroundColor(emphasized ? Color.white : palette.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    emphasized ? Color.orange : palette.secondary.opacity(0.12)
                )
            )
    }

    func availabilityText(for peer: MeshPeerRow) -> String {
        if peer.isConnected { return Strings.connected }
        if peer.isReachable { return Strings.reachable }
        if peer.isMutualFavorite { return Strings.nostr }
        return Strings.offline
    }

    func availabilityIcon(for peer: MeshPeerRow) -> String {
        if peer.isConnected { return "antenna.radiowaves.left.and.right" }
        if peer.isReachable { return "point.3.filled.connected.trianglepath.dotted" }
        if peer.isMutualFavorite { return "globe" }
        return "antenna.radiowaves.left.and.right.slash"
    }

    func availabilityColor(for peer: MeshPeerRow) -> Color {
        if peer.isConnected { return palette.accent }
        if peer.isReachable { return palette.accentBlue }
        if peer.isMutualFavorite { return .purple }
        return palette.secondary
    }

    func selectionBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(isSelected ? palette.accent.opacity(0.13) : Color.clear)
            .padding(.horizontal, 6)
    }
}

// MARK: - Utilities

private extension MeshChatSidebarView {
    @ViewBuilder
    var utilityBar: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 6
            ) {
                utilityButtons
            }
            .padding(8)
        } else {
            HStack(spacing: 2) {
                utilityButtons
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
        }
    }

    @ViewBuilder
    var utilityButtons: some View {
        utilityButton(
            icon: "number",
            title: Strings.locationMenu,
            action: onOpenLocations
        )
        utilityButton(
            icon: "pin.fill",
            title: Strings.notices,
            action: onOpenNotices
        )
        utilityButton(
            icon: "qrcode.viewfinder",
            title: Strings.scanQRCode,
            action: onOpenVerification
        )
        utilityButton(
            icon: "gearshape",
            title: Strings.settings,
            action: onOpenSettings
        )
    }

    func utilityButton(
        icon: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.bitchatSystem(size: 15, weight: .semibold))
                Text(verbatim: title)
                    .bitchatFont(size: 10, weight: .medium)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Filtering, navigation, and accessibility

private extension MeshChatSidebarView {
    var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasSearchQuery: Bool { !normalizedSearch.isEmpty }

    var showsMeshChannel: Bool {
        matches([Strings.mesh, "mesh", "#mesh"])
    }

    var showsCurrentLocation: Bool {
        guard case .location(let channel) = locationChannelsModel.selectedChannel else {
            return false
        }
        return matchesCurrentLocation(channel)
    }

    var filteredBookmarks: [String] {
        let selectedGeohash: String? = {
            guard case .location(let channel) = locationChannelsModel.selectedChannel else {
                return nil
            }
            return channel.geohash.lowercased()
        }()

        return locationChannelsModel.bookmarks.filter { geohash in
            guard geohash.lowercased() != selectedGeohash else { return false }
            return matches([
                geohash,
                "#\(geohash)",
                locationChannelsModel.bookmarkNames[geohash] ?? ""
            ])
        }
    }

    var filteredGroups: [GroupChatRow] {
        peerListModel.groupRows
            .filter { matches([$0.name, "#\($0.name)", Strings.groups]) }
            .sorted { lhs, rhs in
                if lhs.hasUnread != rhs.hasUnread { return lhs.hasUnread }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var filteredPeers: [MeshPeerRow] {
        peerListModel.meshRows
            .filter { !$0.isMe }
            .filter { peer in
                matches([
                    peer.displayName,
                    availabilityText(for: peer),
                    peer.isFavorite ? Strings.favorite : "",
                    peer.isBlocked ? Strings.blocked : "",
                    peerHasUnread(peer) ? Strings.unread : ""
                ])
            }
            .sorted { lhs, rhs in
                let lhsUnread = peerHasUnread(lhs)
                let rhsUnread = peerHasUnread(rhs)
                if lhsUnread != rhsUnread { return lhsUnread }

                let lhsRank = availabilityRank(lhs)
                let rhsRank = availabilityRank(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }

                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    var filteredFriends: [MeshPeerRow] {
        filteredPeers.filter(\.isFavorite)
    }

    var filteredNearbyPeers: [MeshPeerRow] {
        filteredPeers.filter { !$0.isFavorite }
    }

    var filteredRecentPeers: [RecentMeshPeerRow] {
        peerListModel.recentMeshRows.filter { peer in
            matches([
                peer.displayName,
                peer.claimedNickname,
                Strings.recent,
                Strings.offline,
                peer.isBlocked ? Strings.blocked : "",
                recentPeerHasUnread(peer) ? Strings.unread : ""
            ])
        }
    }

    var filteredGeohashPeople: [GeohashPersonRow] {
        peerListModel.geohashPeople
            .filter { person in
                matches([
                    person.displayName,
                    person.isMe ? Strings.you : "",
                    person.isTeleported ? Strings.teleported : Strings.nearby,
                    person.isBlocked ? Strings.blocked : ""
                ])
            }
            .sorted { lhs, rhs in
                if lhs.isMe != rhs.isMe { return lhs.isMe }
                if lhs.isTeleported != rhs.isTeleported { return !lhs.isTeleported }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    var hasConversationSearchResults: Bool {
        let hasCommonResults = showsMeshChannel || showsCurrentLocation
            || !filteredBookmarks.isEmpty || !filteredGroups.isEmpty
        if case .location = locationChannelsModel.selectedChannel {
            return hasCommonResults || !filteredGeohashPeople.isEmpty
        }
        return hasCommonResults || !filteredPeers.isEmpty
            || !filteredRecentPeers.isEmpty
    }

    func recentPeerHasUnread(_ peer: RecentMeshPeerRow) -> Bool {
        peer.hasUnread || peer.conversationPeerIDs.contains {
            privateInboxModel.unreadPeerIDs.contains($0)
        }
    }

    func openRecentPeer(_ peer: RecentMeshPeerRow) {
        onOpenPeer(peerListModel.prepareRecentConversationForOpening(peer))
    }

    func matches(_ candidates: [String]) -> Bool {
        guard hasSearchQuery else { return true }
        return candidates.contains { candidate in
            candidate.localizedStandardContains(normalizedSearch)
        }
    }

    func matchesCurrentLocation(_ channel: GeohashChannel) -> Bool {
        matches([
            channel.geohash,
            "#\(channel.geohash)",
            channel.level.displayName,
            locationChannelsModel.bookmarkNames[channel.geohash] ?? "",
            locationChannelsModel.locationName(for: channel.level) ?? ""
        ])
    }

    func availabilityRank(_ peer: MeshPeerRow) -> Int {
        if peer.isConnected { return 0 }
        if peer.isReachable { return 1 }
        if peer.isMutualFavorite { return 2 }
        return 3
    }

    func peerHasUnread(_ peer: MeshPeerRow) -> Bool {
        peer.hasUnread || privateInboxModel.unreadPeerIDs.contains(peer.peerID)
    }

    func isSelected(geohash: String) -> Bool {
        guard showsConversationSelection else { return false }
        guard case .location(let channel) = locationChannelsModel.selectedChannel else {
            return false
        }
        return channel.geohash.caseInsensitiveCompare(geohash) == .orderedSame
    }

    func openChannel(_ channel: ChannelID) {
        locationChannelsModel.select(channel)
        onOpenChannel(channel)
    }

    func openBookmarkedChannel(_ geohash: String) {
        let channel = ChannelID.location(geohashChannel(for: geohash))
        locationChannelsModel.openLocationChannel(for: geohash)
        onOpenChannel(channel)
    }

    func geohashChannel(for geohash: String) -> GeohashChannel {
        let normalized = geohash.lowercased()
        if case .location(let selected) = locationChannelsModel.selectedChannel,
           selected.geohash.lowercased() == normalized {
            return selected
        }
        if let available = locationChannelsModel.availableChannels.first(where: {
            $0.geohash.lowercased() == normalized
        }) {
            return available
        }
        return GeohashChannel(level: level(forGeohashLength: normalized.count), geohash: normalized)
    }

    func level(forGeohashLength length: Int) -> GeohashChannelLevel {
        switch length {
        case 0...2: return .region
        case 3...4: return .province
        case 5: return .city
        case 6: return .neighborhood
        case 7: return .block
        case 8...12: return .building
        default: return .block
        }
    }

    func peerInitial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased(with: .current)
    }

    func groupMemberCount(_ count: Int) -> String {
        String(
            format: AppLanguageSettings.localized(
                 "groups.member_count %@",
                comment: "Member count shown next to a group name"
            ),
            locale: .current,
            "\(count)"
        )
    }

    func channelAccessibilityLabel(title: String, subtitle: String?, count: Int) -> String {
        var parts = [title]
        if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if count > 0 { parts.append("\(count)") }
        return parts.joined(separator: ", ")
    }

    func groupAccessibilityLabel(_ group: GroupChatRow, hasUnread: Bool) -> String {
        var parts = [group.name, groupMemberCount(group.memberCount)]
        if group.isCreator { parts.append(Strings.creator) }
        if hasUnread { parts.append(Strings.unread) }
        return parts.joined(separator: ", ")
    }

    func peerAccessibilityLabel(_ peer: MeshPeerRow, hasUnread: Bool) -> String {
        var parts = [peer.displayName, availabilityText(for: peer)]
        parts.append(peer.identityLockState.accessibilityDescription)
        if peer.showsVouchedBadge { parts.append(Strings.vouched) }
        if peer.isFavorite { parts.append(Strings.favorite) }
        if hasUnread { parts.append(Strings.unread) }
        if peer.isBlocked { parts.append(Strings.blocked) }
        return parts.joined(separator: ", ")
    }

    func recentPeerAccessibilityLabel(
        _ peer: RecentMeshPeerRow,
        hasUnread: Bool
    ) -> String {
        var parts = [peer.displayName, Strings.offline, Strings.recent]
        parts.append(peer.identityLockState.accessibilityDescription)
        if hasUnread { parts.append(Strings.unread) }
        if peer.isBlocked { parts.append(Strings.blocked) }
        return parts.joined(separator: ", ")
    }

    func geohashPersonAccessibilityLabel(_ person: GeohashPersonRow) -> String {
        var parts = [person.displayName]
        if person.isMe { parts.append(Strings.you) }
        parts.append(person.isTeleported ? Strings.teleported : Strings.nearby)
        if person.isBlocked { parts.append(Strings.blocked) }
        return parts.joined(separator: ", ")
    }
}
