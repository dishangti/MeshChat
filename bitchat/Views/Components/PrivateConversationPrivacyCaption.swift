//
// PrivateConversationPrivacyCaption.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import BitFoundation
import SwiftUI

/// Conversation-level encryption truth shown above the private composer.
/// Message bubbles intentionally carry no lock or verification badges; this
/// single banner is the authoritative place for the live encryption state.
struct PrivateConversationPrivacyCaption: View {
    @ThemedPalette private var palette

    let peerID: PeerID?
    let encryptionStatus: EncryptionStatus?

    var body: some View {
        let presentation = presentation

        HStack(spacing: 6) {
            Image(systemName: presentation.icon)
                .font(.caption2)
            Text(verbatim: presentation.text)
                .font(.caption.weight(.medium))
                .lineLimit(2)
        }
        .foregroundStyle(presentation.tint)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(presentation.tint.opacity(0.08))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(presentation.tint.opacity(0.16))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var presentation: Presentation {
        if peerID?.isGroup == true {
            return Presentation(
                icon: "lock.fill",
                text: AppLanguageSettings.localized(
                    "content.private.caption_group",
                    comment: "Caption above the group chat composer noting messages are encrypted to group members"
                ),
                tint: palette.success
            )
        }

        // Geohash DMs use encrypted Nostr envelopes and do not expose a Noise
        // handshake state, but they are still end-to-end encrypted.
        if peerID?.isGeoDM == true {
            return encryptedPresentation
        }

        switch encryptionStatus {
        case .noiseSecured, .noiseVerified:
            return encryptedPresentation

        case .noiseHandshaking:
            return Presentation(
                icon: "lock.rotation",
                text: privateStatusText(
                    AppLanguageSettings.localized(
                        "encryption.status.establishing",
                        comment: "Status text when encryption is being established"
                    )
                ),
                tint: palette.warning
            )

        case .noHandshake:
            return Presentation(
                icon: "lock.open",
                text: privateStatusText(
                    AppLanguageSettings.localized(
                        "encryption.status.not_encrypted",
                        comment: "Status text when no encryption handshake happened"
                    )
                ),
                tint: palette.warning
            )

        case .some(.none):
            return Presentation(
                icon: "lock.slash",
                text: privateStatusText(
                    AppLanguageSettings.localized(
                        "encryption.status.failed",
                        comment: "Status text when encryption failed"
                    )
                ),
                tint: palette.alertRed
            )

        case nil:
            return Presentation(
                icon: "lock.open",
                text: privateConversationText,
                tint: palette.secondary
            )
        }
    }

    private var encryptedPresentation: Presentation {
        Presentation(
            icon: "lock.fill",
            text: AppLanguageSettings.localized(
                "content.private.caption_encrypted",
                comment: "Caption above the private chat composer once the session is end-to-end encrypted"
            ),
            tint: palette.success
        )
    }

    private var privateConversationText: String {
        AppLanguageSettings.localized(
            "content.private.caption",
            comment: "Caption above the private chat composer before encryption is established"
        )
    }

    private func privateStatusText(_ status: String) -> String {
        "\(privateConversationText) · \(status)"
    }

    private struct Presentation {
        let icon: String
        let text: String
        let tint: Color
    }
}
