import Darwin
import Foundation

public enum EngineEvent: Equatable {
    case text(String)      // answer text delta
    case newBlock          // a new text block starts (e.g. after a tool call)
    case status(String)    // tool activity, for the status line
    case done
    case failed(String)
}

/// Parses one line of `claude -p --output-format stream-json`.
public func parseEngineLine(_ line: String) -> EngineEvent? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    switch obj["type"] as? String {
    case "stream_event":
        guard let event = obj["event"] as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String { return .text(text) }
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any], let type = block["type"] as? String else { return nil }
            if type == "text" { return .newBlock }
            if type.hasSuffix("tool_use") { return .status(toolStatus(block["name"] as? String ?? "")) }
            if type == "thinking" { return .status("Thinking…") }
        default: break
        }
        return nil
    case "result":
        if obj["is_error"] as? Bool == true { return .failed(obj["result"] as? String ?? "Claude returned an error") }
        return .done
    default:
        return nil
    }
}

/// The status line for a tool call.
func toolStatus(_ name: String) -> String {
    switch name {
    case "WebFetch": return "Reading a page…"
    case "WebSearch": return "Searching the web…"
    case "Bash": return "Running a command…"
    case "Read", "Glob", "Grep": return "Looking at files…"
    case "Write", "Edit": return "Writing a file…"
    default:
        let parts = name.components(separatedBy: "__")
        return name.hasPrefix("mcp__") && parts.count >= 2 ? "Using \(parts[1])…" : "Working…"
    }
}

public struct EngineOptions {
    public var tools = ["WebSearch", "WebFetch"]      // built-in tools
    public var disallowed: [String] = []              // --disallowedTools rules
    public var cwd = FileManager.default.temporaryDirectory
    public var restricted = false
    public var mcpConfig: URL?                        // file written by McpStore
    public var mcpServers: [String] = []              // names inside that file
    public var environment: [String: String]?         // nil = inherited, minus CLAUDE*
    public var silenceTimeout: TimeInterval = 30
    public init() {}
}

/// One long-lived headless Claude Code process. Start it early so it is warm; each `send` is one turn
/// and the process keeps the conversation. It uses the user's Claude Code login; no credentials pass through here.
public final class ClaudeSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "snapit.engine")
    private var buffer = Data()
    private var handler: ((EngineEvent) -> Void)?
    private var watchdog: DispatchWorkItem?
    /// Seconds without any event from the CLI before a turn is failed.
    public var silenceTimeout: TimeInterval = 30

    public static func findCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let shell = Process(), pipe = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The CLI arguments. With default options this is the snap route's list, unchanged.
    public static func arguments(model: String, systemPrompt: String, options: EngineOptions) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose", "--strict-mcp-config", "--setting-sources", "",
                    "--disable-slash-commands", "--no-session-persistence"]
        if options.restricted { args += ["--permission-prompts", "none", "--restricted"] }
        let allowed = options.tools + options.mcpServers.map { "mcp__\($0)" }
        args += ["--tools", options.tools.joined(separator: ","), "--allowedTools", allowed.joined(separator: ",")]
        if let mcpConfig = options.mcpConfig { args += ["--mcp-config", mcpConfig.path] }
        if !options.disallowed.isEmpty { args += ["--disallowedTools"] + options.disallowed }
        args += ["--system-prompt", systemPrompt]
        if !model.isEmpty { args += ["--model", model] }
        return args
    }

    public init(cli: String, model: String, systemPrompt: String, options: EngineOptions = EngineOptions()) throws {
        process.executableURL = URL(fileURLWithPath: cli)
        // Isolated from the user's own Claude Code setup: only the servers named in the options load, and no
        // settings, hooks or skills. The tools are those in the options; the snap route has only web tools.
        process.arguments = Self.arguments(model: model, systemPrompt: systemPrompt, options: options)
        silenceTimeout = options.silenceTimeout
        process.environment = options.environment ?? ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        process.currentDirectoryURL = options.cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.queue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.finish(.failed("Claude stopped unexpectedly")) }
        }
        try process.run()
    }

    public var isAlive: Bool { process.isRunning }

    /// Events arrive on a background queue. Exactly one `.done` or `.failed` ends the turn.
    public func send(text: String, images: [Data], onEvent: @escaping (EngineEvent) -> Void) {
        queue.async {
            self.handler = onEvent
            self.armWatchdog()
            var content: [[String: Any]] = []
            for image in images {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.base64EncodedString()]])
            }
            content.append(["type": "text", "text": text])
            let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            guard self.process.isRunning, var line = try? JSONSerialization.data(withJSONObject: message) else {
                self.finish(.failed("Claude is not running")); return
            }
            line.append(0x0A)
            do { try self.input.fileHandleForWriting.write(contentsOf: line) }
            catch { self.finish(.failed("Could not reach Claude: \(error.localizedDescription)")) }
        }
    }

    public func cancel() {
        queue.async {
            self.handler = nil
            self.watchdog?.cancel()
            if self.process.isRunning { Self.killTree(self.process.processIdentifier) }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard handler != nil else { continue }
            armWatchdog()
            guard let event = parseEngineLine(line) else { continue }
            if event == .done { finish(.done) } else if case .failed = event { finish(event) } else { handler?(event) }
        }
    }

    private func finish(_ event: EngineEvent) {
        watchdog?.cancel()
        guard let handler else { return }
        self.handler = nil
        handler(event)
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.failed("Claude did not respond in time"))
            if self.process.isRunning { Self.killTree(self.process.processIdentifier) }
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + silenceTimeout, execute: item)
    }

    /// Foundation cannot start a new process group, so signal descendants before the CLI itself; nothing is left orphaned.
    private static func killTree(_ pid: pid_t) {
        let count = proc_listchildpids(pid, nil, 0)
        if count > 0 {
            var kids = [pid_t](repeating: 0, count: Int(count))
            let got = proc_listchildpids(pid, &kids, Int32(MemoryLayout<pid_t>.size * kids.count))
            for kid in kids.prefix(max(0, Int(got))) { killTree(kid) }
        }
        kill(pid, SIGTERM)
    }
}
