//
// ChannelShareTests.swift
// bitchatTests
//
// SPDX-License-Identifier: MIT
//

import Testing
@testable import bitchat

struct ChannelShareTests {
    @Test func payloadIncludesGeohashDeepLinkAndStoreURL() {
        let text = ChannelShare.payload(forGeohash: "u4pru")
        #expect(text.contains("#u4pru"))
        #expect(text.contains("bitchat://geohash/u4pru"))
        #expect(text.contains(ChannelShare.appStoreURL))
        #expect(!text.lowercased().contains("i'm in"))
    }

    @Test func precisionWarningStartsAtNeighborhood() {
        #expect(!ChannelShare.shouldWarn(forGeohash: "u4pru")) // city = 5
        #expect(ChannelShare.shouldWarn(forGeohash: "u4pruy")) // neighborhood = 6
        #expect(ChannelShare.shouldWarn(forGeohash: "u4pruyzd"))
    }
}
