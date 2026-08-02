//
// TestConstants.swift
// bitchatTests
//
// SPDX-License-Identifier: MIT
//

import Foundation

// Kept local until the test-helper module is split out.
struct TestConstants {
    static let defaultTimeout: TimeInterval = 5.0
    static let longTimeout: TimeInterval = 10.0
    
    static let testNickname1 = "Alice"
    static let testNickname2 = "Bob"
    static let testNickname3 = "Charlie"
    static let testNickname4 = "David"
    
    static let testMessage1 = "Hello, World!"
    static let testMessage2 = "How are you?"
    static let testMessage3 = "This is a test message"
    static let testLongMessage = String(repeating: "This is a long message. ", count: 100)
    
    static let testSignature = Data(repeating: 0xAB, count: 64)
}
