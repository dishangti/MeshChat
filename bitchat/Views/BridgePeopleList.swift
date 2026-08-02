//
// BridgePeopleList.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import SwiftUI

/// Shared section header for the people sheet: a small glyph + label pair,
/// identical shape for every section (#mesh, across the bridge, …).
struct PeopleSectionHeader: View {
    @ThemedPalette private var palette
    let icon: String
    let iconColor: Color
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.bitchatSystem(size: 10))
                .foregroundColor(iconColor)
            Text(verbatim: title)
                .bitchatFont(size: 11, weight: .semibold)
                .foregroundColor(palette.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The people-sheet section for participants visible across the mesh bridge:
/// same place, beyond radio range. Bridged identities have no DM route, but
/// their authenticated per-cell Nostr key supports exact block and unblock.
struct BridgePeopleList: View {
    @EnvironmentObject private var peerListModel: PeerListModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @ThemedPalette private var palette

    private enum Strings {
        static let sectionTitle = String(localized: "bridge_people.section_title", defaultValue: "Across the Bridge", comment: "Section header in the people sheet for participants reachable via the mesh bridge")
        static let rowHint = String(localized: "bridge_people.accessibility.row_hint", defaultValue: "In your area, connected through the bridge", comment: "Accessibility hint for a person listed in the bridge section of the people sheet")
        static let blockedTooltip = String(localized: "geohash_people.tooltip.blocked", comment: "Tooltip shown next to blocked bridge participants")
        static let blockedState = String(localized: "mesh_peers.state.blocked", comment: "State label for a blocked bridge participant")
        static let unblock: LocalizedStringKey = "geohash_people.action.unblock"
        static let block: LocalizedStringKey = "geohash_people.action.block"
        static let unblockText = String(localized: "geohash_people.action.unblock", comment: "Accessibility action to unblock a bridge participant")
        static let blockText = String(localized: "geohash_people.action.block", comment: "Accessibility action to block a bridge participant")
    }

    var body: some View {
        // Not gated on the toggle: bridged people arrive over passive radio
        // (a serving neighbor's carriers) even while this device's own
        // bridge is off — whoever is visible in the timeline belongs in the
        // sheet.
        if !bridgeService.bridgedParticipants.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PeopleSectionHeader(
                    icon: "network",
                    iconColor: Color.cyan.opacity(0.9),
                    title: Strings.sectionTitle
                )

                ForEach(bridgeService.bridgedParticipants) { person in
                    let isBlocked = peerListModel.isBridgeUserBlocked(pubkeyHex: person.pubkey)
                    HStack(spacing: 4) {
                        Text(person.displayName)
                            .bitchatFont(size: 14)
                            .foregroundColor(palette.primary)
                        if isBlocked {
                            Image(systemName: "nosign")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.red)
                                .help(Strings.blockedTooltip)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(isBlocked ? Strings.unblock : Strings.block) {
                            setBlocked(!isBlocked, person: person)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        [person.displayName, isBlocked ? Strings.blockedState : nil]
                            .compactMap { $0 }
                            .joined(separator: ", ")
                    )
                    .accessibilityHint(Strings.rowHint)
                    .accessibilityActions {
                        Button(isBlocked ? Strings.unblockText : Strings.blockText) {
                            setBlocked(!isBlocked, person: person)
                        }
                    }
                }
            }
        }
    }

    private func setBlocked(_ blocked: Bool, person: BridgeService.BridgedParticipant) {
        if blocked {
            peerListModel.blockBridgeUser(pubkeyHex: person.pubkey, displayName: person.displayName)
        } else {
            peerListModel.unblockBridgeUser(pubkeyHex: person.pubkey, displayName: person.displayName)
        }
    }
}
