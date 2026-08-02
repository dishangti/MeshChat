//
// NoiseSessionError.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

enum NoiseSessionError: Error, Equatable {
    case invalidState
    case notEstablished
    case sessionNotFound
    case alreadyEstablished
    case peerIdentityMismatch
}

/// The manager owns the exact attempt's one bounded recovery. Packet handling
/// must not launch its historical second, immediate restart for this failure.
struct NoiseManagedHandshakeFailure: Error {
    let underlying: Error
}
