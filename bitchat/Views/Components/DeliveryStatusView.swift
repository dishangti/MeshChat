//
// DeliveryStatusView.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import SwiftUI
import BitFoundation

extension DeliveryStatus {
    /// Localized, user-facing description of the status. Used for macOS
    /// tooltips, the tap-to-reveal caption under a message, and VoiceOver —
    /// the glyphs alone are unexplained 10pt icons.
    var bitchatDescription: String {
        switch self {
        case .notSentYet:
            return AppLanguageSettings.localized("content.delivery.not_sent_yet", defaultValue: "Not sent yet", comment: "Delivery status description for a message that has not entered any send pipeline")
        case .sending:
            return AppLanguageSettings.localized("content.delivery.sending", comment: "Delivery status description while a private message is being sent")
        case .sent:
            return AppLanguageSettings.localized("content.delivery.sent", comment: "Delivery status description for a sent but not yet confirmed private message")
        case .carried:
            return AppLanguageSettings.localized("content.delivery.carried", defaultValue: "Carried by a friend who may meet them", comment: "Delivery status description for messages handed to a courier for physical delivery")
        case .delivered(let nickname, _):
            return String(
                format: AppLanguageSettings.localized("content.delivery.delivered_to", comment: "Tooltip for delivered private messages"),
                locale: .current,
                nickname
            )
        case .read(let nickname, _):
            return String(
                format: AppLanguageSettings.localized("content.delivery.read_by", comment: "Tooltip for read private messages"),
                locale: .current,
                nickname
            )
        case .failed(let reason):
            return String(
                format: AppLanguageSettings.localized("content.delivery.failed", comment: "Tooltip for failed message delivery"),
                locale: .current,
                reason
            )
        case .partiallyDelivered(let reached, let total):
            return String(
                format: AppLanguageSettings.localized("content.delivery.delivered_members", comment: "Tooltip for partially delivered messages"),
                locale: .current,
                reached,
                total
            )
        }
    }
}

struct DeliveryStatusView: View {
    @ThemedPalette private var palette
    let status: DeliveryStatus

    // MARK: - Computed Properties

    private var secondaryTextColor: Color { palette.secondary }

    // MARK: - Body

    var body: some View {
        statusGlyph
            .help(status.bitchatDescription)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.bitchatDescription)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch status {
        case .notSentYet:
            // Normally hidden by callers; shown as a hollow dotted circle if
            // it ever surfaces so the state is visible rather than invisible.
            Image(systemName: "circle.dotted")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))

        case .sending:
            Image(systemName: "clock")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.8))

        case .sent:
            Image(systemName: "checkmark")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))

        case .carried:
            Image(systemName: "figure.walk")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.8))

        case .delivered:
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10, weight: .semibold))
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10, weight: .semibold))
            }
            .foregroundColor(secondaryTextColor.opacity(0.9))

        case .read:
            // Same double-check silhouette as delivered; blue is the familiar
            // WhatsApp-style read receipt and avoids a shape jump.
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10, weight: .bold))
            }
            .foregroundColor(palette.accentBlue)

        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(palette.alertRed)

        case .partiallyDelivered(let reached, let total):
            HStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10))
                Text(verbatim: "\(reached)/\(total)")
                    .bitchatFont(size: 10)
            }
            .foregroundColor(secondaryTextColor.opacity(0.6))
        }
    }
}

#Preview {
    let statuses: [DeliveryStatus] = [
        .notSentYet,
        .sending,
        .sent,
        .carried,
        .delivered(to: "John Doe", at: Date()),
        .read(by: "Jane Doe", at: Date()),
        .failed(reason: "Offline"),
        .partiallyDelivered(reached: 2, total: 5)
    ]
    
    List {
        ForEach(statuses, id: \.self) { status in
            HStack {
                Text(status.displayText)
                Spacer()
                DeliveryStatusView(status: status)
            }
        }
    }
    .environment(\.colorScheme, .light)

    List {
        ForEach(statuses, id: \.self) { status in
            HStack {
                Text(status.displayText)
                Spacer()
                DeliveryStatusView(status: status)
            }
        }
    }
    .environment(\.colorScheme, .dark)
}
