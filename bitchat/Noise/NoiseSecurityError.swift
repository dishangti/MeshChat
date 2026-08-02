//
// NoiseSecurityError.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import Foundation

enum NoiseSecurityError: Error {
    case sessionExpired
    case sessionExhausted
    case messageTooLarge
    case invalidPeerID
    case rateLimitExceeded
}
