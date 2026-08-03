//
// MessageBubble.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import BitFoundation
import SwiftUI

/// A compact directional bubble shared by text and media messages.
/// The small bottom corner conveys direction without relying on color alone.
struct MessageBubble<Content: View>: View {
    @ThemedPalette private var palette

    let isFromCurrentUser: Bool
    let highlightsFailure: Bool
    private let content: Content

    init(
        isFromCurrentUser: Bool,
        highlightsFailure: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.isFromCurrentUser = isFromCurrentUser
        self.highlightsFailure = highlightsFailure
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isFromCurrentUser {
                Spacer(minLength: 52)
            }

            content
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    MessageBubbleShape(isFromCurrentUser: isFromCurrentUser)
                        .fill(
                            isFromCurrentUser
                                ? palette.outgoingBubble
                                : palette.incomingBubble
                        )
                )
                .overlay {
                    MessageBubbleShape(isFromCurrentUser: isFromCurrentUser)
                        .stroke(
                            highlightsFailure
                                ? palette.alertRed.opacity(0.55)
                                : palette.divider.opacity(0.55),
                            lineWidth: highlightsFailure ? 1 : 0.5
                        )
                }
                .frame(maxWidth: 520, alignment: isFromCurrentUser ? .trailing : .leading)

            if !isFromCurrentUser {
                Spacer(minLength: 52)
            }
        }
        .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
    }
}

/// Measures the message body and its footer independently. The widest child
/// defines the bubble width; the body stays leading-aligned and metadata is
/// placed against the trailing edge without an expanding Spacer.
///
/// `Layout` is available on both iOS 16 and macOS 13, which lets short
/// messages keep their intrinsic width while long messages still accept the
/// finite width proposed by `MessageBubble` and wrap normally.
struct MessageBubbleContentLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 5) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let childProposal = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(childProposal) }

        return CGSize(
            width: sizes.map(\.width).max() ?? 0,
            height: sizes.map(\.height).reduce(0, +)
                + spacing * CGFloat(max(0, sizes.count - 1))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(childProposal) }
        var y = bounds.minY

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            let isMetadata = index == subviews.count - 1
            let x = isMetadata ? bounds.maxX - size.width : bounds.minX
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            y += size.height + spacing
        }
    }
}

/// iOS 16/macOS 13-compatible uneven rounded rectangle.
private struct MessageBubbleShape: Shape {
    let isFromCurrentUser: Bool

    func path(in rect: CGRect) -> Path {
        let largeRadius = min(16, rect.width / 2, rect.height / 2)
        let smallRadius = min(4, rect.width / 2, rect.height / 2)
        let bottomLeft = isFromCurrentUser ? largeRadius : smallRadius
        let bottomRight = isFromCurrentUser ? smallRadius : largeRadius

        var path = Path()
        path.move(to: CGPoint(x: largeRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - largeRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + largeRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + largeRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + largeRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Sender attribution shown only where the conversation can contain multiple
/// other people (public channels and private groups).
struct MessageBubbleSenderLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    let message: BitchatMessage

    @ViewBuilder
    var body: some View {
        if let peerID = message.senderPeerID,
           let url = URL(string: "bitchat://user/\(peerID.toPercentEncoded())") {
            Link(destination: url) {
                senderLabel
            }
            .buttonStyle(.plain)
        } else {
            senderLabel
        }
    }

    private var senderLabel: some View {
        Text(verbatim: message.sender)
            .bitchatFont(size: 12, weight: .semibold)
            .foregroundColor(
                conversationUIModel.senderColor(
                    for: message,
                    colorScheme: colorScheme
                )
            )
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// WhatsApp-style footer: timestamp and, for locally-sent private messages,
/// the real transport/read-receipt status already tracked by the model.
struct MessageBubbleMetadata: View {
    @ThemedPalette private var palette

    let message: BitchatMessage
    let deliveryStatus: DeliveryStatus
    let isFromCurrentUser: Bool
    @Binding var showDeliveryDetail: Bool

    private var showsDeliveryStatus: Bool {
        message.isPrivate && isFromCurrentUser
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                if message.isBridged {
                    Image(systemName: "network")
                        .font(.bitchatSystem(size: 9))
                        .foregroundColor(palette.secondary)
                        .accessibilityLabel(
                            AppLanguageSettings.localized(
                                "content.accessibility.bridged_message",
                                defaultValue: "Arrived across a mesh bridge",
                                comment: "Accessibility label for the glyph marking a message that arrived across a mesh bridge"
                            )
                        )
                }

                Text(verbatim: message.formattedTimestamp)
                    .bitchatFont(size: 10)
                    .foregroundColor(palette.secondary)

                if showsDeliveryStatus {
                    Button {
                        showDeliveryDetail.toggle()
                    } label: {
                        DeliveryStatusView(status: deliveryStatus)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    // Preserve the compact WhatsApp-style footer while making
                    // the actual hit shape a 44pt touch target.
                    .contentShape(Rectangle().inset(by: -12))
                    .accessibilityHint(
                        AppLanguageSettings.localized(
                            "content.accessibility.delivery_detail_hint",
                            comment: "Accessibility hint for the delivery status glyph explaining a tap reveals details"
                        )
                    )
                }
            }

            if showsDeliveryStatus,
               isFailure || showDeliveryDetail {
                Text(verbatim: deliveryStatus.bitchatDescription)
                    .bitchatFont(size: 11)
                    .foregroundColor(
                        isFailure ? palette.alertRed : palette.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = deliveryStatus { return true }
        return false
    }
}
