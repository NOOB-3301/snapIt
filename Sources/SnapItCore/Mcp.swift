import Foundation

public enum Mcp {
    /// Names of the user-scope servers in the contents of ~/.claude.json, sorted.
    public static func serverNames(in claudeJSON: Data) -> [String] {
        let root = (try? JSONSerialization.jsonObject(with: claudeJSON)) as? [String: Any]
        return ((root?["mcpServers"] as? [String: Any])?.keys).map { $0.sorted() } ?? []
    }

    /// A --mcp-config document with only the selected servers that still exist. Nil when none do.
    public static func config(from claudeJSON: Data, selected: [String]) -> (data: Data, names: [String])? {
        let root = (try? JSONSerialization.jsonObject(with: claudeJSON)) as? [String: Any]
        let all = root?["mcpServers"] as? [String: Any] ?? [:]
        let kept = all.filter { selected.contains($0.key) }
        guard !kept.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": kept]) else { return nil }
        return (data, kept.keys.sorted())
    }
}
