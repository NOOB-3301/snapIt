import Foundation
import SnapItCore

/// Reads today's tokens from Claude Code's own session logs and sets the companion's energy level.
@MainActor enum Usage {
    private static var timer: Timer?

    static func startMonitoring() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }

    static func refresh() {
        Task.detached(priority: .utility) {
            let tokens = readTodaysTokens()
            await MainActor.run {
                Chibi.shared.tokensToday = tokens
                Chibi.shared.tired = Double(tokens) >= Pref.d.double(forKey: "tiredTokens")
            }
        }
    }

    private nonisolated static func readTodaysTokens() -> Int {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var seen: Set<String> = [], total = 0
        for project in projects {
            guard let logs = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for log in logs where log.pathExtension == "jsonl" {
                let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard modified >= startOfDay, let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard let hit = UsageLog.tokens(String(line), since: startOfDay), seen.insert(hit.id).inserted else { continue }
                    total += hit.tokens
                }
            }
        }
        return total
    }
}