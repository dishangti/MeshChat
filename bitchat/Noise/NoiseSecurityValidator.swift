//
// NoiseSecurityValidator.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import Foundation

struct NoiseSecurityValidator {
    
    /// Validate message size
    static func validateMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxMessageSize
    }

    static func validateCiphertextSize(_ data: Data) -> Bool {
        data.count <= NoiseSecurityConstants.maxMessageSize
            + NoiseSecurityConstants.transportCiphertextOverhead
    }

    static func validatePrivateFileMessageSize(_ data: Data) -> Bool {
        data.count <= NoiseSecurityConstants.maxPrivateFilePlaintextSize
    }

    static func validatePrivateFileCiphertextSize(_ data: Data) -> Bool {
        data.count <= NoiseSecurityConstants.maxPrivateFileCiphertextSize
    }
    
    /// Validate handshake message size
    static func validateHandshakeMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxHandshakeMessageSize
    }
}
