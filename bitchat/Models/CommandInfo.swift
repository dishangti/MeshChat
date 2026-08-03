//
// CommandsInfo.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import Foundation

// MARK: - CommandInfo Enum

enum CommandInfo: String, Identifiable {
    // Raw values must match the aliases CommandProcessor actually accepts —
    // the suggestion panel is the app's only command-discovery surface, and
    // suggesting a spelling the processor rejects teaches users dead ends.
    case block
    case clear
    case group
    case help
    case hug
    case message = "msg"
    case slap
    case pay
    case unblock
    case who
    case favorite = "fav"
    case unfavorite = "unfav"
    case ping
    case trace
    case drop

    var id: String { rawValue }

    var alias: String { "/" + rawValue }

    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite, .ping, .trace:
            return "<" + AppLanguageSettings.localized("content.input.nickname_placeholder") + ">"
        case .group:
            return "<" + AppLanguageSettings.localized("content.input.group_placeholder") + ">"
        case .pay:
            return "<" + AppLanguageSettings.localized("content.input.token_placeholder") + ">"
        case .drop:
            return "<" + AppLanguageSettings.localized("content.input.note_placeholder") + ">"
        case .clear, .help, .who:
            return nil
        }
    }

    var description: String {
        switch self {
        case .block:        AppLanguageSettings.localized("content.commands.block")
        case .clear:        AppLanguageSettings.localized("content.commands.clear")
        case .group:        AppLanguageSettings.localized("content.commands.group")
        case .help:         AppLanguageSettings.localized("content.commands.help")
        case .hug:          AppLanguageSettings.localized("content.commands.hug")
        case .message:      AppLanguageSettings.localized("content.commands.message")
        case .pay:          AppLanguageSettings.localized("content.commands.pay")
        case .slap:         AppLanguageSettings.localized("content.commands.slap")
        case .unblock:      AppLanguageSettings.localized("content.commands.unblock")
        case .who:          AppLanguageSettings.localized("content.commands.who")
        case .favorite:     AppLanguageSettings.localized("content.commands.favorite")
        case .unfavorite:   AppLanguageSettings.localized("content.commands.unfavorite")
        case .ping:         AppLanguageSettings.localized("content.commands.ping")
        case .trace:        AppLanguageSettings.localized("content.commands.trace")
        case .drop:         AppLanguageSettings.localized("content.commands.drop")
        }
    }

    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        var commands: [CommandInfo] = [.block, .unblock, .clear, .drop, .help, .hug, .message, .slap, .who]
        // Cashu tokens are bearer instruments: in a public geohash any nearby
        // stranger can redeem one, so don't *suggest* /pay there (the
        // processor still allows it behind an explicit "public" confirm).
        // Payments make sense in every DM and in mesh public.
        if !isGeoPublic {
            commands.append(.pay)
        }
        // The processor rejects favorites, groups, and mesh diagnostics in
        // geohash contexts, so only suggest them where they work: mesh.
        if isGeoPublic || isGeoDM {
            return commands
        }
        return commands + [.favorite, .unfavorite, .ping, .trace, .group]
    }
}
