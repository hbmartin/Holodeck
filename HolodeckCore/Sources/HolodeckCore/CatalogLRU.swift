/// Owned by CatalogService's actor; hits promote entries without repeating validation or decoding.
nonisolated struct CatalogLRU<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var access: UInt64
    }
    let limit: Int
    private(set) var cost = 0
    private var generation: UInt64 = 0
    private var entries: [Key: Entry] = [:]

    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        generation &+= 1
        entry.access = generation
        entries[key] = entry
        return entry.value
    }

    mutating func removeValue(for key: Key) {
        if let previous = entries.removeValue(forKey: key) { cost -= previous.cost }
    }

    mutating func removeAll() { entries.removeAll(); cost = 0 }

    mutating func insert(_ value: Value, for key: Key, cost newCost: Int) {
        if let previous = entries.removeValue(forKey: key) { cost -= previous.cost }
        guard newCost <= limit else { return }
        while cost > limit - newCost, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            cost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        generation &+= 1
        entries[key] = Entry(value: value, cost: newCost, access: generation)
        cost += newCost
    }
}
