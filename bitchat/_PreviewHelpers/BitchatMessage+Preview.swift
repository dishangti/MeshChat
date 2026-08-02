//
// BitchatMessage+Preview.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import BitFoundation
import Foundation

extension BitchatMessage {
    static var preview: BitchatMessage {
        BitchatMessage(
            id: UUID().uuidString,
            sender: "John Doe",
            content: "Hello",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: "Jane Doe",
            senderPeerID: nil,
            mentions: nil,
            deliveryStatus: .sent
        )
    }
}
