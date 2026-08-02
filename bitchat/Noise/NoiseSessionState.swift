//
// NoiseSessionState.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

enum NoiseSessionState: Equatable {
    case uninitialized
    case handshaking
    case established
}
