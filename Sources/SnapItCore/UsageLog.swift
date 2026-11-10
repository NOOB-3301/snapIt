import Foundation

public enum UsageLog {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// One logged assistant message: its id and its fresh tokens, or nil when the line is not a usage record on/after `since`.
    /// The id matters because Claude Code writes one line per content block, all repeating the same message and its usage.
    public static func tokens(_ line: String, since: Date) -> (id: String, tokens: Int)? {
        guard line.contains("\"usage\""),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let stamp = obj["timestamp"] as? String,
              let date = fractional.date(from: stamp) ?? plain.date(from: stamp), date >= since,
              let message = obj["message"] as? [String: Any],
              let id = message["id"] as? String,
              let usage = message["usage"] as? [String: Any] else { return nil }
        // Cache reads cost a fraction of fresh tokens; counting them would tire the chibi after one prompt.
        let total = (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        return total > 0 ? (id, total) : nil
    }
}