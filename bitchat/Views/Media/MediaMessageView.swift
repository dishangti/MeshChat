//
//  MediaMessageView.swift
//  bitchat
//
//  Created by Islam on 30/03/2026.
//

import SwiftUI
import BitFoundation

struct MediaMessageView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    let message: BitchatMessage
    let media: BitchatMessage.Media
    let showsSenderName: Bool
    /// Value snapshot of the message's mutable delivery status, captured at
    /// construction (see `TextMessageView.deliveryStatus`): `BitchatMessage`
    /// is a reference type mutated in place, and SwiftUI compares reference
    /// fields by identity, so without the snapshot a status-only change
    /// (send progress, delivered → read) would not re-render this row.
    private let deliveryStatus: DeliveryStatus
    @State private var showDeliveryDetail = false

    @Binding var imagePreviewURL: URL?

    init(
        message: BitchatMessage,
        media: BitchatMessage.Media,
        imagePreviewURL: Binding<URL?>,
        showsSenderName: Bool = true
    ) {
        self.message = message
        self.media = media
        self.showsSenderName = showsSenderName
        self.deliveryStatus = message.deliveryStatus
        self._imagePreviewURL = imagePreviewURL
    }

    var body: some View {
        let isFromMe = conversationUIModel.isMediaMessageFromCurrentUser(message)
        let state = mediaSendState(for: deliveryStatus, isFromMe: isFromMe)
        let cancelAction: (() -> Void)? = state.canCancel ? { conversationUIModel.cancelMediaSend(messageID: message.id) } : nil

        return MessageBubble(
            isFromCurrentUser: isFromMe,
            highlightsFailure: isFailure
        ) {
            MessageBubbleContentLayout(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    if showsSenderName && !isFromMe {
                        MessageBubbleSenderLabel(message: message)
                            .padding(.bottom, 2)
                    }

                    Group {
                        switch media {
                        case .voice(let url):
                            VoiceNoteView(
                                url: url,
                                isSending: state.isSending,
                                sendProgress: state.progress,
                                isLive: conversationUIModel.isLiveVoiceMessage(message),
                                onCancel: cancelAction
                            )
                            // WaveformView uses GeometryReader and therefore
                            // has no useful intrinsic width of its own.
                            .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                        case .image(let url):
                            BlockRevealImageView(
                                url: url,
                                revealProgress: state.progress,
                                isSending: state.isSending,
                                onCancel: cancelAction,
                                initiallyBlurred: !isFromMe,
                                onOpen: {
                                    if !state.isSending {
                                        imagePreviewURL = url
                                    }
                                },
                                onDelete: !isFromMe ? { conversationUIModel.deleteMediaMessage(messageID: message.id) } : nil
                            )
                            .frame(idealWidth: 280, maxWidth: 280)
                        }
                    }
                }

                MessageBubbleMetadata(
                    message: message,
                    deliveryStatus: deliveryStatus,
                    isFromCurrentUser: isFromMe,
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

    private func mediaSendState(for deliveryStatus: DeliveryStatus, isFromMe: Bool) -> (isSending: Bool, progress: Double?, canCancel: Bool) {
        // A received message is never in a send state: BitchatMessage defaults
        // private messages to .sending, so an incoming message's status must
        // not drive the reveal mask or disable the reveal tap.
        guard isFromMe else { return (false, nil, false) }
        var isSending = false
        var progress: Double?
        switch deliveryStatus {
        case .sending:
            isSending = true
            progress = 0
        case .partiallyDelivered(let reached, let total):
            if total > 0 {
                isSending = true
                progress = Double(reached) / Double(total)
            }
        case .notSentYet, .sent, .carried, .read, .delivered, .failed:
            break
        }
        let canCancel = isSending && conversationUIModel.isSentByCurrentUser(message)
        let clamped = progress.map { max(0, min(1, $0)) }
        return (isSending, isSending ? clamped : nil, canCancel)
    }
}
