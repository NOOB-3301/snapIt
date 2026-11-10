import AppKit
import Foundation

struct Turn: Codable, Equatable {
    var role: String   // "user" or "assistant"
    var text: String
}

struct SnapRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var turns: [Turn] = []
    var context: String = ""
    var image: String = ""
}

/// Conversations live in one JSON file, their snaps in `images/`, both under Application Support.
@MainActor final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var items: [SnapRecord] = []

    private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("snapIt")
    private var fileURL: URL { dir.appendingPathComponent("history.json") }
    private var imagesURL: URL { dir.appendingPathComponent("images") }

    private init() {
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        items = (try? JSONDecoder().decode([SnapRecord].self, from: Data(contentsOf: fileURL))) ?? []
        items.sort { $0.date > $1.date }
        prune()
    }

    func imageURL(_ name: String) -> URL? {
        name.isEmpty ? nil : imagesURL.appendingPathComponent(name)
    }

    func imagePNG(_ record: SnapRecord) -> Data? {
        guard let url = imageURL(record.image) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Writes the snap before the request goes out, so a retry never needs a new selection.
    func save(_ record: SnapRecord, imagePNG: Data) {
        let name = "\(record.id.uuidString).png"
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try? imagePNG.write(to: imagesURL.appendingPathComponent(name))
        var stored = record
        stored.image = name
        items.removeAll { $0.id == record.id }
        items.insert(stored, at: 0)
        persist()
    }

    func update(_ record: SnapRecord) {
        guard let index = items.firstIndex(where: { $0.id == record.id }) else { return }
        var stored = record
        stored.image = items[index].image   // the caller never learns the generated file name
        items[index] = stored
        persist()
    }

    func delete(_ record: SnapRecord) {
        items.removeAll { $0.id == record.id }
        if let url = imageURL(record.image) { try? FileManager.default.removeItem(at: url) }
        persist()
    }

    func clearAll() {
        for record in items { if let url = imageURL(record.image) { try? FileManager.default.removeItem(at: url) } }
        items = []
        persist()
    }

    func matching(_ query: String) -> [SnapRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(q) || $0.turns.contains { $0.text.lowercased().contains(q) } }
    }

    func prune() {
        let days = Pref.d.object(forKey: "historyDays") == nil ? 30 : Pref.d.integer(forKey: "historyDays")
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let old = items.filter { $0.date < cutoff }
        guard !old.isEmpty else { return }
        for record in old { if let url = imageURL(record.image) { try? FileManager.default.removeItem(at: url) } }
        items.removeAll { $0.date < cutoff }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}