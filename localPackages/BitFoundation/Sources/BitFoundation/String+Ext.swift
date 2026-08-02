//
// String+Ext.swift
// BitFoundation
//
// SPDX-License-Identifier: MIT
//

public extension StringProtocol {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedOrNilIfEmpty: String? {
        let trimmed = self.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
