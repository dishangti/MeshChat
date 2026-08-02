// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import bitchat

struct ThemeTests {
    @Test
    func freshAndInvalidThemeValuesResolveConsistently() {
        #expect(AppTheme.defaultTheme == .aurora)
        #expect(AppTheme.aurora.rawValue == "aurora")
        #expect(Set(AppTheme.allCases.map(\.rawValue)) == Set(["matrix", "aurora"]))
        #expect(AppTheme.resolve(AppTheme.defaultTheme.rawValue) == .aurora)
        #expect(AppTheme.resolve("unknown-theme") == .aurora)
    }

    @Test
    func obsoleteAuroraValueIsRewrittenUsingTheCurrentRawValue() throws {
        let suiteName = "ThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("obsolete-theme-value", forKey: AppTheme.storageKey)

        #expect(AppTheme.migratePersistedSelection(in: defaults) == .aurora)
        #expect(defaults.string(forKey: AppTheme.storageKey) == AppTheme.aurora.rawValue)
    }

    @Test
    func currentThemeValueDoesNotChangeDuringMigration() throws {
        let suiteName = "ThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppTheme.matrix.rawValue, forKey: AppTheme.storageKey)

        #expect(AppTheme.migratePersistedSelection(in: defaults) == .matrix)
        #expect(defaults.string(forKey: AppTheme.storageKey) == AppTheme.matrix.rawValue)
    }
}
