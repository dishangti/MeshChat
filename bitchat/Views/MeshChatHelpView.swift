// SPDX-License-Identifier: MIT

import SwiftUI

/// A task-oriented guide to MeshChat's connection, identity, notification,
/// and privacy controls. It stays separate from About and Settings so users
/// can learn what a control does without changing it accidentally.
struct MeshChatHelpView: View {
    @ThemedPalette private var palette

    private struct Topic: Identifiable {
        let id: String
        let icon: String
        let title: LocalizedStringKey
        let description: LocalizedStringKey
    }

    private struct SymbolItem: Identifiable {
        let id: String
        let icon: String
        let color: Color?
        let text: String
    }

    private let connectivityTopics = [
        Topic(
            id: "offline",
            icon: "antenna.radiowaves.left.and.right",
            title: "app_info.features.offline.title",
            description: "app_info.features.offline.description"
        ),
        Topic(
            id: "range",
            icon: "point.3.filled.connected.trianglepath.dotted",
            title: "app_info.features.extended_range.title",
            description: "app_info.features.extended_range.description"
        ),
        Topic(
            id: "bridge",
            icon: "network",
            title: "app_info.settings.bridge.title",
            description: "meshchat.help.bridge.description"
        ),
        Topic(
            id: "location",
            icon: "mappin.and.ellipse",
            title: "location_channels.sheet_title",
            description: "location_channels.description"
        )
    ]

    private let peopleTopics = [
        Topic(
            id: "recent",
            icon: "clock.arrow.circlepath",
            title: "mesh_peers.section.recent",
            description: "meshchat.help.recent.description"
        ),
        Topic(
            id: "managing-chats",
            icon: "trash",
            title: "meshchat.help.chats.title",
            description: "meshchat.help.chats.description"
        ),
        Topic(
            id: "mentions",
            icon: "at",
            title: "app_info.features.mentions.title",
            description: "app_info.features.mentions.description"
        ),
        Topic(
            id: "friends",
            icon: "person.crop.circle.badge.plus",
            title: "mesh_peers.section.friends",
            description: "meshchat.help.friends.description"
        ),
        Topic(
            id: "favorites",
            icon: "star.fill",
            title: "mesh_peers.section.friends",
            description: "meshchat.help.friends.description"
        ),
        Topic(
            id: "qr",
            icon: "qrcode.viewfinder",
            title: "verification.qr.title",
            description: "meshchat.help.qr.description"
        ),
        Topic(
            id: "verification",
            icon: "lock.shield",
            title: "fingerprint.action.mark_verified",
            description: "meshchat.help.verification.description"
        )
    ]

    private let privacyTopics = [
        Topic(
            id: "no-tracking",
            icon: "eye.slash",
            title: "app_info.privacy.no_tracking.title",
            description: "app_info.privacy.no_tracking.description"
        ),
        Topic(
            id: "ephemeral-identity",
            icon: "shuffle",
            title: "app_info.privacy.ephemeral.title",
            description: "app_info.privacy.ephemeral.description"
        ),
        Topic(
            id: "encryption",
            icon: "lock.fill",
            title: "app_info.features.encryption.title",
            description: "meshchat.help.privacy.description"
        ),
        Topic(
            id: "previews",
            icon: "eye.slash",
            title: "app_info.settings.hide_previews.title",
            description: "app_info.settings.hide_previews.subtitle"
        ),
        Topic(
            id: "identity-reset",
            icon: "key.horizontal",
            title: "app_info.settings.danger.identity_reset_button",
            description: "app_info.settings.danger.identity_reset_note"
        ),
        Topic(
            id: "data-erasure",
            icon: "trash",
            title: "app_info.settings.danger.erase_button",
            description: "app_info.settings.danger.erase_note"
        )
    ]

    /// General interface symbols belong in Help rather than Info because they
    /// answer a usage question. Identity lock colors remain beside the
    /// verification instructions above so their security context is explicit.
    private let symbolItems = [
        SymbolItem(id: "mesh-connected", icon: "antenna.radiowaves.left.and.right", color: nil, text: AppLanguageSettings.localized("app_info.legend.mesh_connected")),
        SymbolItem(id: "mesh-relayed", icon: "point.3.filled.connected.trianglepath.dotted", color: nil, text: AppLanguageSettings.localized("app_info.legend.mesh_relayed")),
        SymbolItem(id: "nostr", icon: "globe", color: nil, text: AppLanguageSettings.localized("app_info.legend.nostr")),
        SymbolItem(id: "bridged", icon: "network", color: .cyan, text: AppLanguageSettings.localized("app_info.legend.bridged")),
        SymbolItem(id: "offline", icon: "person", color: nil, text: AppLanguageSettings.localized("app_info.legend.offline")),
        SymbolItem(id: "location-nearby", icon: "mappin.and.ellipse", color: nil, text: AppLanguageSettings.localized("app_info.legend.location_nearby")),
        SymbolItem(id: "teleported", icon: "face.dashed", color: nil, text: AppLanguageSettings.localized("app_info.legend.teleported")),
        SymbolItem(id: "encryption-failed", icon: "exclamationmark.triangle", color: .orange, text: AppLanguageSettings.localized("app_info.legend.encryption_failed")),
        SymbolItem(id: "private-message", icon: "lock.fill", color: .orange, text: AppLanguageSettings.localized("app_info.legend.private_message")),
        SymbolItem(id: "favorite", icon: "star.fill", color: nil, text: AppLanguageSettings.localized("mesh_peers.state.favorite")),
        SymbolItem(id: "unread", icon: "envelope.fill", color: nil, text: AppLanguageSettings.localized("app_info.legend.unread")),
        SymbolItem(id: "blocked", icon: "nosign", color: nil, text: AppLanguageSettings.localized("app_info.legend.blocked"))
    ]

    private var primary: Color { palette.primary }
    private var secondary: Color { palette.secondary }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                topicSection("app_info.settings.connectivity.title", topics: connectivityTopics)
                peopleSection
                notificationsSection
                topicSection("app_info.privacy.title", topics: privacyTopics)
                symbolsSection
            }
            .padding()
        }
        .accessibilityIdentifier("meshchat.help.page")
    }

    private var header: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.bitchatSystem(size: 32))
                .foregroundColor(palette.accent)
                .accessibilityHidden(true)

            Text("meshchat.help.title")
                .bitchatFont(size: 26, weight: .bold)
                .foregroundColor(primary)

            Text("meshchat.help.introduction")
                .bitchatFont(size: 14)
                .foregroundColor(secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func topicSection(_ title: LocalizedStringKey, topics: [Topic]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title)

            ForEach(topics) { topic in
                topicRow(topic)
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("content.header.people")

            ForEach(peopleTopics) { topic in
                VStack(alignment: .leading, spacing: 8) {
                    topicRow(topic)

                    if topic.id == "verification" {
                        verificationLegend
                    }
                }
            }
        }
    }

    private var verificationLegend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            verificationState(
                icon: "lock.fill",
                iconColor: IdentityLockState.unverified.color,
                label: "fingerprint.badge.not_verified"
            )
            verificationState(
                icon: "lock.fill",
                iconColor: IdentityLockState.verified.color,
                label: "fingerprint.badge.verified"
            )
            verificationState(
                icon: "lock.fill",
                iconColor: IdentityLockState.identityMismatch.color,
                label: "identity.status.mismatch"
            )
        }
        .padding(.horizontal, 12)
    }

    private func verificationState(
        icon: String,
        iconColor: Color,
        label: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .accessibilityHidden(true)
            Text(label)
                .bitchatFont(size: 11, weight: .semibold)
                .foregroundColor(primary)
        }
        .accessibilityElement(children: .combine)
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("app_info.settings.notifications.title")

            topicRow(
                Topic(
                    id: "notifications",
                    icon: "bell.badge",
                    title: "app_info.settings.notifications.title",
                    description: "meshchat.help.notifications.description"
                )
            )
        }
    }

    private var symbolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("app_info.legend.title")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(symbolItems) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(item.color ?? primary)
                            .frame(width: 24)
                            .accessibilityHidden(true)

                        Text(verbatim: item.text)
                            .bitchatFont(size: 12)
                            .foregroundColor(secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(palette.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func topicRow(_ topic: Topic) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: topic.icon)
                .font(.bitchatSystem(size: 18))
                .foregroundColor(palette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title)
                    .bitchatFont(size: 14, weight: .semibold)
                    .foregroundColor(primary)

                Text(topic.description)
                    .bitchatFont(size: 12)
                    .foregroundColor(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(palette.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Help") {
    MeshChatHelpView()
}

#Preview("Help – Dynamic Type") {
    MeshChatHelpView()
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
