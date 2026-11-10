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
            if type.hasSuffix("tool_use") {
                return .status(block["name"] as? String == "WebFetch" ? "Reading a page…" : "Searching the web…")
            }
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

    public init(cli: String, model: String, systemPrompt: String) throws {
        process.executableURL = URL(fileURLWithPath: cli)
        // Isolated from the user's own Claude Code setup: no MCP servers, settings, hooks or skills.
        // Only web tools exist, so nothing here can touch files or run commands.
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose", "--strict-mcp-config", "--setting-sources", "",
                    "--disable-slash-commands", "--no-session-persistence",
                    "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch",
                    "--system-prompt", systemPrompt]
        if !model.isEmpty { args += ["--model", model] }
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
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
    public func send(text: String, imagePNG: Data?, onEvent: @escaping (EngineEvent) -> Void) {
        queue.async {
            self.handler = onEvent
            self.armWatchdog()
            var content: [[String: Any]] = []
            if let imagePNG {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": imagePNG.base64EncodedString()]])
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
            if self.process.isRunning { self.process.terminate() }
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
            if self.process.isRunning { self.process.terminate() }
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + silenceTimeout, execute: item)
    }
}
