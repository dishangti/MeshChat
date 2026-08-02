//
// BoundedIDSet.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

/// Insertion-ordered string set with a fixed capacity; the oldest entry is
/// evicted when full. Shared by the gateway and bridge loop-prevention
/// caches.
struct BoundedIDSet {
    private var members: Set<String> = []
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func contains(_ id: String) -> Bool {
        members.contains(id)
    }

    /// Returns false when the ID was already present.
    @discardableResult
    mutating func insert(_ id: String) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }
}
