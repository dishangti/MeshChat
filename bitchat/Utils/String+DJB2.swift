//
// String+DJB2.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import Foundation

extension String {
    func djb2() -> UInt64 {
        var hash: UInt64 = 5381
        for b in utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        return hash
    }
}
