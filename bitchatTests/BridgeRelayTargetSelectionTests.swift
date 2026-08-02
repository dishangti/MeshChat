import Testing
@testable import bitchat

@Suite("Bridge relay target selection")
@MainActor
struct BridgeRelayTargetSelectionTests {
    @Test func coversEveryCellWithABoundedNumberOfUniqueRelays() {
        let cells = (0..<9).map { "cell-\($0)" }
        let targets = BridgeRelayTargetSelector.targets(
            cells: cells,
            perCellCount: 5
        ) { cell, count in
            (0..<count).map { "wss://\(cell)-relay-\($0).example" }
        }

        #expect(targets.count == 10)
        #expect(Set(targets).count == targets.count)
        for cell in cells {
            #expect(targets.contains("wss://\(cell)-relay-0.example"))
        }
    }

    @Test func deduplicatesSharedRegionalRelaysDeterministically() {
        let cells = ["north", "center", "south"]
        let targets = BridgeRelayTargetSelector.targets(
            cells: cells,
            perCellCount: 3
        ) { cell, _ in
            ["wss://shared.example", "wss://\(cell).example"]
        }

        #expect(targets == [
            "wss://shared.example",
            "wss://north.example",
            "wss://center.example",
            "wss://south.example"
        ])
    }
}
