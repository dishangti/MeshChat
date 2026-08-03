import SwiftUI
import BitFoundation

struct MeshPeerList: View {
    @EnvironmentObject private var peerListModel: PeerListModel
    @ThemedPalette private var palette
    let onTapPeer: (PeerID) -> Void
    let onRemoveFriend: (PeerID) -> Void
    let onShowFingerprint: (PeerID) -> Void
    /// Adds the selected peer without changing verification state.
    var onAddFriend: ((PeerID) -> Void)? = nil
    /// Opens the device-local nickname editor for the selected identity.
    var onSetNickname: ((PeerID) -> Void)? = nil
    /// Optional so existing call sites (and previews/tests) keep compiling;
    /// when absent the block/unblock context-menu entry is hidden.
    var onToggleBlock: ((MeshPeerRow) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme

    @State private var orderedIDs: [String] = []

    private enum Strings {
        static let noneNearby: LocalizedStringKey = "geohash_people.none_nearby"
        static var friendsSection: String {
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
        static var blockedTooltip: String { AppLanguageSettings.localized("geohash_people.tooltip.blocked", comment: "Tooltip shown next to a blocked peer indicator") }
        static var newMessagesTooltip: String { AppLanguageSettings.localized("mesh_peers.tooltip.new_messages", comment: "Tooltip for the unread messages indicator") }
        static var connected: String { AppLanguageSettings.localized("content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator") }
        static var reachable: String { AppLanguageSettings.localized("content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator") }
        static var nostr: String { AppLanguageSettings.localized("content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator") }
        static var offline: String { AppLanguageSettings.localized("mesh_peers.state.offline", comment: "State label for a peer that is not currently reachable") }
        static var favorite: String { AppLanguageSettings.localized("mesh_peers.state.favorite", comment: "State label for a favorited peer") }
        static var unread: String { AppLanguageSettings.localized("mesh_peers.state.unread", comment: "State label for a peer with unread private messages") }
        static var blocked: String { AppLanguageSettings.localized("mesh_peers.state.blocked", comment: "State label for a blocked peer") }
        static var vouched: String { AppLanguageSettings.localized("mesh_peers.state.vouched", comment: "State label for a peer vouched for by someone the user verified") }
        static var vouchedTooltip: String { AppLanguageSettings.localized("mesh_peers.tooltip.vouched", comment: "Tooltip for the vouched (unfilled seal) badge next to a peer") }
        static var addFavorite: String { AppLanguageSettings.localized("friends.action.add", comment: "Action that adds a person as a friend") }
        static var removeFavorite: String { AppLanguageSettings.localized("content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite") }
        static var showFingerprint: String { AppLanguageSettings.localized("mesh_peers.action.fingerprint", comment: "Context menu action that shows a peer's fingerprint/verification screen") }
        static var setNickname: String { AppLanguageSettings.localized("fingerprint.local_alias.label", comment: "Context menu action that edits a local nickname") }
        static var openDMHint: String { AppLanguageSettings.localized("mesh_peers.accessibility.open_dm_hint", comment: "Accessibility hint on a peer row explaining activation opens a private chat") }
        static var directMessage: String { AppLanguageSettings.localized("content.actions.direct_message", comment: "Action that opens a private chat with the person") }
        static var block: String { AppLanguageSettings.localized("geohash_people.action.block", comment: "Context menu action to block a person") }
        static var unblock: String { AppLanguageSettings.localized("geohash_people.action.unblock", comment: "Context menu action to unblock a person") }
    }

    var body: some View {
        let currentIDs = peerListModel.meshRows.map(\.id)
        let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
        let peers: [MeshPeerRow] = displayIDs.compactMap { id in
            peerListModel.meshRows.first(where: { $0.id == id })
        }
        let sectionedPeers = peers.filter(\.isFavorite) + peers.filter { !$0.isFavorite }

        if peerListModel.meshRows.isEmpty {
            // Match the section's row rhythm (same size, indent, and vertical
            // padding as a peer row) so the empty state reads as the list's
            // only line, not a floating caption.
            Text(Strings.noneNearby)
                .bitchatFont(size: 14)
                .foregroundColor(palette.secondary)
                .padding(.horizontal)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<sectionedPeers.count, id: \.self) { idx in
                    let peer = sectionedPeers[idx]
                    let isMe = peer.isMe

                    if idx == 0 || sectionedPeers[idx - 1].isFavorite != peer.isFavorite {
                        PeopleSectionHeader(
                            icon: peer.isFavorite ? "star.fill" : "person.2.fill",
                            iconColor: peer.isFavorite ? .yellow : palette.accent,
                            title: peer.isFavorite ? Strings.friendsSection : Strings.nearbySection
                        )
                    }

                    HStack(spacing: 4) {
                        let assigned = peerListModel.colorForMeshPeer(id: peer.peerID, isDark: colorScheme == .dark)
                        let baseColor = isMe ? Color.orange : assigned
                        // Mesh rows keep their leading glyph: unlike the
                        // homogeneous bridge/groups sections, it encodes HOW
                        // the peer is reachable (radio, relayed, nostr-only).
                        if isMe {
                            Image(systemName: "person.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isConnected {
                            // Mesh-connected peer: radio icon
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                                .help(Strings.connected)
                        } else if peer.isReachable {
                            // Mesh-reachable (relayed): point.3 icon
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                                .help(Strings.reachable)
                        } else if peer.isNostrAvailable {
                            // A configured store-and-forward mailbox route;
                            // this does not claim the remote app is live.
                            Image(systemName: "globe")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.purple)
                                .help(Strings.nostr)
                        } else {
                            // Offline: slashed variant of the connected glyph
                            // (dimmed) — clearer than a generic person icon.
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(palette.secondary)
                                .help(Strings.offline)
                        }

                        let (base, suffix) = peer.displayName.splitSuffix()
                        HStack(spacing: 0) {
                            Text(base)
                                .bitchatFont(size: 14)
                                .foregroundColor(baseColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !suffix.isEmpty {
                                let suffixColor = isMe ? Color.orange.opacity(0.6) : baseColor.opacity(0.6)
                                Text(suffix)
                                    .bitchatFont(size: 14)
                                    .foregroundColor(suffixColor)
                            }
                        }

                        if peer.isBlocked {
                            Image(systemName: "nosign")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.red)
                                .help(Strings.blockedTooltip)
                        }

                        if !isMe {
                            Image(systemName: peer.identityLockState.icon)
                                .font(.bitchatSystem(size: 10))
                                // Lock glyph ink is bottom-heavy next to text.
                                .offset(y: -0.5)
                                .foregroundColor(peer.identityLockState.color)
                                .help(peer.identityLockState.accessibilityDescription)

                            // Vouched (transitively verified): unfilled seal,
                            // deliberately distinct from verified's filled one.
                            // Never shown alongside a verified badge.
                            if peer.showsVouchedBadge {
                                Image(systemName: "checkmark.seal")
                                    .font(.bitchatSystem(size: 10))
                                    .foregroundColor(baseColor)
                                    .help(Strings.vouchedTooltip)
                            }
                        }

                        Spacer()

                        // Unread message indicator for this peer
                        if peer.unreadMessageCount > 0 {
                            Text(verbatim: peer.unreadMessageCount > 99 ? "99+" : "\(peer.unreadMessageCount)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, peer.unreadMessageCount > 9 ? 5 : 0)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Capsule().fill(palette.accent))
                                .fixedSize()
                                .help(Strings.newMessagesTooltip)
                        }

                        if !isMe, peer.isFavorite || onAddFriend != nil {
                            Button(action: {
                                if peer.isFavorite {
                                    onRemoveFriend(peer.peerID)
                                } else {
                                    onAddFriend?(peer.peerID)
                                }
                            }) {
                                Image(systemName: peer.isFavorite ? "star.fill" : "person.badge.plus")
                                    .font(.bitchatSystem(size: 12))
                                    .foregroundColor(peer.isFavorite ? .yellow : palette.secondary)
                                    // Widen the tap target beyond the bare glyph;
                                    // height stays row-bound so neighboring rows
                                    // keep their own taps.
                                    .frame(width: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    // count:2 must attach before count:1 or the single tap
                    // shadows it (same ordering the header logo relies on).
                    .onTapGesture(count: 2) { if !isMe { onShowFingerprint(peer.peerID) } }
                    .onTapGesture { if !isMe { onTapPeer(peer.peerID) } }
                    .contextMenu {
                        if !isMe {
                            Button(Strings.directMessage) {
                                onTapPeer(peer.peerID)
                            }
                            if peer.isFavorite {
                                Button(Strings.removeFavorite) {
                                    onRemoveFriend(peer.peerID)
                                }
                            } else if let onAddFriend {
                                Button(Strings.addFavorite) { onAddFriend(peer.peerID) }
                            }
                            if let onSetNickname {
                                Button(Strings.setNickname) { onSetNickname(peer.peerID) }
                            }
                            Button(Strings.showFingerprint) {
                                onShowFingerprint(peer.peerID)
                            }
                            if let onToggleBlock {
                                if peer.isBlocked {
                                    Button(Strings.unblock) {
                                        onToggleBlock(peer)
                                    }
                                } else {
                                    Button(Strings.block, role: .destructive) {
                                        onToggleBlock(peer)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityDescription(for: peer))
                    .accessibilityAddTraits(isMe ? [] : .isButton)
                    .accessibilityHint(isMe ? "" : Strings.openDMHint)
                    .accessibilityActions {
                        if !isMe {
                            if peer.isFavorite {
                                Button(Strings.removeFavorite) {
                                    onRemoveFriend(peer.peerID)
                                }
                            } else if let onAddFriend {
                                Button(Strings.addFavorite) { onAddFriend(peer.peerID) }
                            }
                            if let onSetNickname {
                                Button(Strings.setNickname) { onSetNickname(peer.peerID) }
                            }
                            Button(Strings.showFingerprint) {
                                onShowFingerprint(peer.peerID)
                            }
                            if let onToggleBlock {
                                Button(peer.isBlocked ? Strings.unblock : Strings.block) {
                                    onToggleBlock(peer)
                                }
                            }
                        }
                    }
                }
            }
            // Seed and update order outside result builder
            .onAppear {
                orderedIDs = currentIDs
            }
            .onChange(of: currentIDs) { ids in
                var newOrder = orderedIDs
                newOrder.removeAll { !ids.contains($0) }
                for id in ids where !newOrder.contains(id) { newOrder.append(id) }
                if newOrder != orderedIDs { orderedIDs = newOrder }
            }
        }
    }

    /// One spoken sentence per row: name, how they're reachable, and any
    /// state badges — the visual row is icon soup for VoiceOver otherwise.
    private func accessibilityDescription(for peer: MeshPeerRow) -> String {
        var parts: [String] = [peer.displayName]
        if !peer.isMe {
            if peer.isConnected {
                parts.append(Strings.connected)
            } else if peer.isReachable {
                parts.append(Strings.reachable)
            } else if peer.isNostrAvailable {
                parts.append(Strings.nostr)
            } else {
                parts.append(Strings.offline)
            }
            parts.append(peer.identityLockState.accessibilityDescription)
        }
        if peer.showsVouchedBadge { parts.append(Strings.vouched) }
        if peer.isFavorite { parts.append(Strings.favorite) }
        if peer.unreadMessageCount > 0 {
            parts.append("\(Strings.unread): \(peer.unreadMessageCount)")
        }
        if peer.isBlocked { parts.append(Strings.blocked) }
        return parts.joined(separator: ", ")
    }
}
