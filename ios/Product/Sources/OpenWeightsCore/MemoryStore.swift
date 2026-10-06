import Foundation

public struct RememberedFact: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public let savedAt: Date
    public init(id: UUID = UUID(), text: String, savedAt: Date = Date()) {
        self.id = id; self.text = text; self.savedAt = savedAt
    }
}

public enum MemoryError: LocalizedError {
    case empty, tooLong, noMatch, invalidSnapshot, missingFact, changedFact
    public var errorDescription: String? {
        switch self {
        case .empty: return "The memory was empty. Use forget_memory to remove a saved fact."
        case .tooLong: return "Keep each memory under 160 characters, one fact."
        case .noMatch: return "No saved memory matches that. Call read_memory, then try the exact fact."
        case .missingFact: return "This saved fact no longer exists. Reopen Saved memory."
        case .changedFact: return "This saved fact changed. Reopen it before editing."
        case .invalidSnapshot: return "The saved memory file is invalid. It has been preserved for recovery."
        }
    }
}

public actor MemoryStore {
    public static let maximumFacts = 24
    public static let maximumFactCharacters = 160
    public static let maximumTotalCharacters = 1000
    private struct Snapshot: Codable { var version = 1; var facts: [RememberedFact] }
    private let file: URL
    private var facts: [RememberedFact]

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { throw StoreError.unsupportedVersion(snapshot.version) }
            guard snapshot.facts.count <= Self.maximumFacts,
                  Set(snapshot.facts.map(\.id)).count == snapshot.facts.count,
                  snapshot.facts.allSatisfy({ !$0.text.isEmpty && $0.text.utf16.count <= Self.maximumFactCharacters }),
                  snapshot.facts.reduce(0, { $0 + $1.text.utf16.count }) <= Self.maximumTotalCharacters else {
                throw MemoryError.invalidSnapshot
            }
            facts = snapshot.facts.sorted { $0.savedAt < $1.savedAt }
        } else { facts = [] }
    }
    public func list() -> [RememberedFact] { facts }
    @discardableResult public func remember(_ text: String, now: Date = Date()) throws -> String {
        let value = try checked(text)
        guard !facts.contains(where: { equal($0.text, value) }) else { return "Already remembered." }
        let next = Array((facts + [RememberedFact(text: value, savedAt: now)]).suffix(Self.maximumFacts))
        try commit(budgeted(next, protecting: next.last?.id))
        return "Remembered."
    }
    @discardableResult public func replace(old: String, new: String) throws -> String {
        let value = try checked(new)
        guard let found = matching(old) else { throw MemoryError.noMatch }
        if facts.contains(where: { $0.id != found.id && equal($0.text, value) }) {
            try commit(facts.filter { $0.id != found.id })
            return "That is already remembered. The old version is forgotten."
        }
        var next = facts
        next[next.firstIndex(where: { $0.id == found.id })!].text = value
        try commit(budgeted(next, protecting: found.id))
        return "Updated."
    }
    @discardableResult public func replace(id: UUID, expectedText: String, new: String) throws -> String {
        let value = try checked(new)
        guard let found = facts.first(where: { $0.id == id }) else { throw MemoryError.missingFact }
        guard found.text == expectedText else { throw MemoryError.changedFact }
        if facts.contains(where: { $0.id != id && equal($0.text, value) }) {
            try commit(facts.filter { $0.id != id })
            return "That is already remembered. The old version is forgotten."
        }
        var next = facts
        next[next.firstIndex(where: { $0.id == id })!].text = value
        try commit(budgeted(next, protecting: id))
        return "Updated."
    }
    @discardableResult public func forget(id: UUID) throws -> String {
        guard facts.contains(where: { $0.id == id }) else { throw MemoryError.missingFact }
        try commit(facts.filter { $0.id != id })
        return "Forgotten."
    }
    @discardableResult public func forget(_ query: String) throws -> String {
        guard let found = matching(query) else { throw MemoryError.noMatch }
        try commit(facts.filter { $0.id != found.id })
        return "Forgotten."
    }
    public func forgetAll() throws { try commit([]) }
    public func toolRead() -> String {
        guard !facts.isEmpty else { return "Nothing is saved about this user yet." }
        let prefix = "Things you have been told about this user in earlier conversations. Use them if they are relevant and ignore them otherwise."
        return prefix + facts.enumerated().map { "\n\($0.offset + 1). \($0.element.text)" }.joined()
    }
    public static func normalizedFact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func checked(_ text: String) throws -> String {
        let value = Self.normalizedFact(text)
        guard !value.isEmpty else { throw MemoryError.empty }
        // Android budgets UTF-16 code units. Keep the same ceiling for supplementary characters.
        guard value.utf16.count <= Self.maximumFactCharacters else { throw MemoryError.tooLong }
        return value
    }
    private func equal(_ left: String, _ right: String) -> Bool { left.lowercased() == right.lowercased() }
    private func matching(_ query: String) -> RememberedFact? {
        let value = Self.normalizedFact(query)
        guard !value.isEmpty else { return nil }
        if let exact = facts.first(where: { equal($0.text, value) }) { return exact }
        let matches = facts.filter { $0.text.lowercased().contains(value.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
    }
    private func budgeted(_ values: [RememberedFact], protecting id: UUID?) -> [RememberedFact] {
        var kept = values
        while kept.reduce(0, { $0 + $1.text.utf16.count }) > Self.maximumTotalCharacters,
              let index = kept.firstIndex(where: { $0.id != id }) { kept.remove(at: index) }
        return kept
    }
    private func commit(_ next: [RememberedFact]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Snapshot(facts: next)).write(to: file, options: .atomic)
        facts = next
    }
}
