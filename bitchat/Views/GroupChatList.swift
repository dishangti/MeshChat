import BitFoundation
import SwiftUI

/// Compact "groups" section for the people sheet: one row per private group
/// this device belongs to, tappable to open the group chat window.
struct GroupChatList: View {
    @ThemedPalette private var palette

    let groups: [GroupChatRow]
    let onTapGroup: (PeerID) -> Void

    private enum Strings {
        static var header: String { AppLanguageSettings.localized("groups.section.header", comment: "Section header above the private groups list") }
        static var creator: String { AppLanguageSettings.localized("groups.state.creator", comment: "State label for a group the user created") }
        static var unread: String { AppLanguageSettings.localized("mesh_peers.state.unread", comment: "State label for a peer with unread private messages") }
        static var newMessagesTooltip: String { AppLanguageSettings.localized("mesh_peers.tooltip.new_messages", comment: "Tooltip for the unread messages indicator") }
        static var openGroupHint: String { AppLanguageSettings.localized("groups.accessibility.open_group_hint", comment: "Accessibility hint on a group row explaining activation opens the group chat") }
        static var memberCountFormat: String { AppLanguageSettings.localized("groups.member_count %@", comment: "Member count shown next to a group name; placeholder is the count") }
    }

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Same glyph+label header shape as #mesh / across the bridge.
                PeopleSectionHeader(
                    icon: "person.3.fill",
                    iconColor: palette.primary,
                    title: Strings.header
                )

                ForEach(groups) { group in
                    HStack(spacing: 4) {
                        Text("#\(group.name)")
                            .bitchatFont(size: 14)
                            .foregroundColor(palette.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(String(format: Strings.memberCountFormat, locale: .current, "\(group.memberCount)"))
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)

                        if group.isCreator {
                            Image(systemName: "crown.fill")
                                .font(.bitchatSystem(size: 9))
                                .foregroundColor(.yellow)
                                .help(Strings.creator)
                        }

                        Spacer()

                        if group.unreadMessageCount > 0 {
                            Text(verbatim: group.unreadMessageCount > 99 ? "99+" : "\(group.unreadMessageCount)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, group.unreadMessageCount > 9 ? 5 : 0)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Capsule().fill(palette.accent))
                                .fixedSize()
                                .help(Strings.newMessagesTooltip)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { onTapGroup(group.peerID) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityDescription(for: group))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Strings.openGroupHint)
                }
            }
        }
    }

    private func accessibilityDescription(for group: GroupChatRow) -> String {
        var parts: [String] = [
            group.name,
            String(format: Strings.memberCountFormat, locale: .current, "\(group.memberCount)")
        ]
        if group.isCreator { parts.append(Strings.creator) }
        if group.unreadMessageCount > 0 {
            parts.append("\(Strings.unread): \(group.unreadMessageCount)")
        }
        return parts.joined(separator: ", ")
    }
}
