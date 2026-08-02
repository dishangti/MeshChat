// SPDX-License-Identifier: MIT

import SwiftUI

/// The quiet landing surface shown before the user chooses a conversation.
/// On iPhone the conversation directory itself is the NavigationStack root;
/// this companion fills the detail column on iPad and Mac.
struct MeshChatHomeView: View {
    @EnvironmentObject private var peerListModel: PeerListModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @ThemedPalette private var palette

    let onOpenMesh: () -> Void
    let onOpenLocations: () -> Void
    let onOpenVerification: () -> Void

    private var peopleCountText: String {
        let format = String(
            localized: "content.accessibility.people_count",
            comment: "Number of reachable people shown on the MeshChat home screen"
        )
        let count = peerListModel.reachableMeshPeerCount + bridgeService.bridgedPeerCount
        return String(format: format, locale: .current, count)
    }

    var body: some View {
        ZStack {
            ThemedRootBackground()

            VStack(spacing: 22) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("app_info.app_name")
                        .bitchatFont(size: 28, weight: .bold)
                    Text("app_info.tagline")
                        .bitchatFont(size: 14)
                        .foregroundStyle(palette.secondary)
                }

                VStack(spacing: 10) {
                    homeAction(
                        title: String(localized: "location_channels.mesh_label", defaultValue: "#mesh"),
                        subtitle: peopleCountText,
                        icon: "antenna.radiowaves.left.and.right",
                        action: onOpenMesh
                    )

                    HStack(spacing: 10) {
                        compactAction(title: "#location", icon: "number", action: onOpenLocations)
                        compactAction(title: "Verify", icon: "qrcode", action: onOpenVerification)
                    }
                }
                .frame(maxWidth: 460)

                Text("content.empty.switch_hint")
                    .bitchatFont(size: 12)
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(32)
        }
    }

    private func homeAction(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(palette.accent.opacity(0.13)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .bitchatFont(size: 16, weight: .semibold)
                    Text(verbatim: subtitle)
                        .bitchatFont(size: 12)
                        .foregroundStyle(palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedOverlayPanel()
    }

    private func compactAction(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .bitchatFont(size: 13, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.primary)
        .themedOverlayPanel()
    }
}
