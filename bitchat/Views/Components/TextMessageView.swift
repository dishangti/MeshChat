//
// TextMessageView.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import SwiftUI
import BitFoundation

struct TextMessageView: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    let message: BitchatMessage
    let showsSenderName: Bool
    /// Value snapshot of the message's mutable delivery status, captured at
    /// construction. `BitchatMessage` is a reference type mutated in place by
    /// `ConversationStore`, and SwiftUI compares reference-typed view fields
    /// by identity — so a status-only change (e.g. delivered → read) on the
    /// SAME instance would otherwise compare "unchanged" and this row's body
    /// would be skipped even though the parent list re-rendered. Snapshotting
    /// the enum makes the change visible to SwiftUI's structural diff.
    private let deliveryStatus: DeliveryStatus
    @State private var expandedMessageIDs: Set<String> = []
    @State private var showDeliveryDetail = false

    init(message: BitchatMessage, showsSenderName: Bool = true) {
        self.message = message
        self.showsSenderName = showsSenderName
        self.deliveryStatus = message.deliveryStatus
    }

    var body: some View {
        let isFromCurrentUser = conversationUIModel.isSentByCurrentUser(message)
        let isLong = message.content.isLongForDisplay()
        let isExpanded = expandedMessageIDs.contains(message.id)
        let cashuLinks = message.content.extractCashuLinks()
        let lightningLinks = message.content.extractLightningLinks()

        return MessageBubble(
            isFromCurrentUser: isFromCurrentUser,
            highlightsFailure: isFailure
        ) {
            MessageBubbleContentLayout(spacing: 5) {
                VStack(alignment: .leading, spacing: 5) {
                    if showsSenderName && !isFromCurrentUser {
                        MessageBubbleSenderLabel(message: message)
                    }

                    Text(
                        conversationUIModel.formatMessageContent(
                            message,
                            colorScheme: colorScheme,
                            theme: theme
                        )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(
                        isLong && !isExpanded
                            ? TransportConfig.uiLongMessageLineLimit
                            : nil
                    )

                    if isLong {
                        let labelKey = isExpanded
                            ? LocalizedStringKey("content.message.show_less")
                            : LocalizedStringKey("content.message.show_more")
                        Button(labelKey) {
                            if isExpanded {
                                expandedMessageIDs.remove(message.id)
                            } else {
                                expandedMessageIDs.insert(message.id)
                            }
                        }
                        .bitchatFont(size: 11, weight: .medium)
                        .foregroundColor(palette.accentBlue)
                    }

                    if !lightningLinks.isEmpty || !cashuLinks.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(lightningLinks, id: \.self) { link in
                                PaymentChipView(paymentType: .lightning(link))
                            }
                            ForEach(cashuLinks, id: \.self) { link in
                                PaymentChipView(paymentType: .cashu(link))
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                MessageBubbleMetadata(
                    message: message,
                    deliveryStatus: deliveryStatus,
                    isFromCurrentUser: isFromCurrentUser,
                    showDeliveryDetail: $showDeliveryDetail
                )
            }
        }
        // Collapse the revealed caption when the status advances (e.g.
        // sending → sent → delivered) so a detail opened for one state
        // doesn't linger and silently morph into another. Guarded write:
        // under a message storm many rows change status within one frame,
        // and an unconditional state write per change trips SwiftUI's
        // "tried to update multiple times per frame" re-entrancy warning.
        .onChange(of: deliveryStatus) { _ in
            if showDeliveryDetail {
                showDeliveryDetail = false
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = deliveryStatus { return true }
        return false
    }
}

// Wrapped in #if DEBUG because the preview depends on _PreviewHelpers
// (PreviewKeychainManager, BitchatMessage.preview), a development asset
// excluded from archive builds.
#if DEBUG
#Preview {
    let keychain = PreviewKeychainManager()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(),
        identityManager: SecureIdentityStateManager(keychain)
    )
    let privateConversationModel = PrivateConversationModel(
        chatViewModel: viewModel,
        conversations: viewModel.conversations
    )
    let conversationUIModel = ConversationUIModel(
        chatViewModel: viewModel,
        privateConversationModel: privateConversationModel,
        conversations: viewModel.conversations
    )
    
    Group {
        List {
            TextMessageView(message: .preview)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .light)
        
        List {
            TextMessageView(message: .preview)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .dark)
    }
    .environmentObject(conversationUIModel)
}
#endif
