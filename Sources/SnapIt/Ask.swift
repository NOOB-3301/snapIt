import AppKit
import Combine
import SnapItCore
import SwiftUI

enum QuickAction: String, CaseIterable, Identifiable {
    case explain = "Explain", summarise = "Summarise", find = "Find", translate = "Translate"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .explain: return "lightbulb"
        case .summarise: return "list.bullet"
        case .find: return "magnifyingglass"
        case .translate: return "character.bubble"
        }
    }
    var prompt: String {
        switch self {
        case .explain: return "Explain this clearly. If it is a problem or a derivation, go step by step."
        case .summarise: return "Summarise this in a few short bullet points."
        case .find: return "Find more about this on the web. Work out what I most likely want: other stores and prices for a product, related reading for an article, fixes for an error message, or the identity and source of a picture. Give direct links."
        case .translate: return "Translate the text in this into English. Keep the structure of the original."
        }
    }
}

/// One snap and the conversation about it. Saved to history before the first request goes out.
@MainActor final class SnapSession: ObservableObject {
    let thumbnail: NSImage
    @Published var extraThumbnails: [NSImage] = []
    @Published var turns: [Turn] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var context = SnapContext()
    @Published var deadLinks: [String] = []

    private let png: Data
    private var extras: [Data] = []
    private var unsent: [Data] = []   // later snaps the running Claude process has not seen yet
    private let contextTask: Task<SnapContext, Never>
    private var record: SnapRecord
    private var saved = false
    private var storedContextLine: String?
    private var lastSent = ""
    private var engine: ClaudeSession?
    private var retried = false
    private var asked = Date()
    private var sawText = false

    init(image: CGImage, front: NSRunningApplication?) {
        thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        png = SnapSession.encode(image)
        record = SnapRecord(title: "")
        let app = front?.localizedName, bundleID = front?.bundleIdentifier
        let title = front.flatMap { Probe.windowTitle(pid: $0.processIdentifier) }
        let wantText = Pref.d.bool(forKey: "sendText"), wantURL = Pref.d.bool(forKey: "sendURL")
        contextTask = Task {
            async let text = wantText ? Probe.recognizeText(image) : nil
            async let url = wantURL ? Probe.browserURL(bundleID: bundleID) : nil
            return SnapContext(app: app, title: title, url: await url, text: await text)
        }
        context = SnapContext(app: app, title: title)
        Task { context = await contextTask.value }
    }

    /// Reopens a conversation from history. The next question re-sends the snap with what was said so far.
    init?(record: SnapRecord) {
        guard let data = HistoryStore.shared.imagePNG(record), let image = NSImage(data: data) else { return nil }
        thumbnail = image
        png = data
        self.record = record
        saved = true
        storedContextLine = record.context
        contextTask = Task { SnapContext() }
        turns = record.turns
    }

    /// PNG, scaled down so the longer side is at most 1568 px (larger adds upload time, not detail the model uses).
    private static func encode(_ image: CGImage) -> Data {
        let scale = min(1, 1568 / CGFloat(max(image.width, image.height)))
        var output = image
        if scale < 1 {
            let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                output = ctx.makeImage() ?? image
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, output, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    var contextLine: String {
        if let storedContextLine { return storedContextLine }
        var parts = [[context.app, context.title].compactMap { $0 }.joined(separator: " — ")]
        if context.text != nil { parts.append("text read") }
        if context.url != nil { parts.append("page URL") }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// Drops the Claude process so the next question starts a new one with the current servers.
    func refresh() {
        guard !busy else { return }
        engine?.cancel()
        engine = nil
        unsent = []
        EnginePool.shared.refresh()
        status = "Session restarted"
    }

    /// A later snap joins this conversation; it goes out with the next question. History keeps only the first snap.
    func add(image: CGImage) {
        let data = SnapSession.encode(image)
        extras.append(data)
        unsent.append(data)
        extraThumbnails.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
    }

    var lastAnswer: String { turns.last(where: { $0.role == "assistant" })?.text ?? "" }

    /// `shown` goes in the transcript; `sending` is the full instruction when a quick action stands behind a short label.
    func ask(_ shown: String, sending: String? = nil) {
        guard !busy else { return }
        turns.append(Turn(role: "user", text: shown))
        lastSent = sending ?? shown
        retried = false
        send()
    }

    /// Sends the last question again. The snap and question are kept, so nothing has to be re-captured.
    func retry() {
        guard !busy else { return }
        if lastSent.isEmpty, let last = turns.last(where: { $0.role == "user" }) { lastSent = last.text }
        guard !lastSent.isEmpty else { return }
        if turns.last?.role == "assistant" { turns.removeLast() }
        send()
    }

    private func persist() {
        record.turns = turns.filter { !$0.text.isEmpty }
        record.context = contextLine
        if record.title.isEmpty {
            let place = context.title ?? context.app
            record.title = String(((turns.first?.text ?? "Snap") + (place.map { " — \($0)" } ?? "")).prefix(80))
        }
        if saved { HistoryStore.shared.update(record) } else { HistoryStore.shared.save(record, imagePNG: png); saved = true }
    }

    func stop() {
        engine?.cancel()
        engine = nil
        finish(error: nil)
    }

    private func send() {
        let question = lastSent
        error = nil
        busy = true
        sawText = false
        status = "Thinking…"
        asked = Date()
        Chibi.shared.activity = .thinking
        let earlier = Array(turns.dropLast())
        persist()
        turns.append(Turn(role: "assistant", text: ""))
        Task { @MainActor in
            let context = await contextTask.value
            guard busy else { return }
            // A fresh process knows nothing yet: give it the image, the context and what was said so far.
            var text = question, images: [Data] = unsent
            if engine?.isAlive != true {
                guard let fresh = EnginePool.shared.take() else {
                    finish(error: EnginePool.shared.cli == nil
                           ? "Claude Code was not found. Install it, run `claude` once in Terminal to log in, then retry."
                           : "Could not start Claude Code.")
                    return
                }
                engine = fresh
                images = [png] + extras
                text = SnapSession.prompt(question: question, context: context, earlier: earlier)
            }
            let current = engine
            unsent = []
            current?.send(text: text, images: images) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.engine === current else { return }   // ignore a stopped or replaced process
                    self.handle(event)
                }
            }
        }
    }

    private static func prompt(question: String, context: SnapContext, earlier: [Turn]) -> String {
        var parts: [String] = []
        if let app = context.app { parts.append("App: \(app)" + (context.title.map { " — window \"\($0)\"" } ?? "")) }
        if let url = context.url { parts.append("Page URL: \(url)") }
        if let text = context.text { parts.append("Text recognised in the selection:\n\"\"\"\n\(text.prefix(6000))\n\"\"\"") }
        if !earlier.isEmpty {
            parts.append("Earlier in this conversation:\n" + earlier.map { "\($0.role == "user" ? "User" : "You"): \($0.text)" }.joined(separator: "\n\n"))
        }
        parts.append(question)
        return parts.joined(separator: "\n\n")
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .text(let delta):
            if !sawText {
                sawText = true
                Log.write(String(format: "first text after %.2f s", Date().timeIntervalSince(asked)))
            }
            status = ""
            Chibi.shared.activity = .talking
            turns[turns.count - 1].text += delta
        case .newBlock:
            let text = turns[turns.count - 1].text
            if !text.isEmpty, !text.hasSuffix("\n\n") { turns[turns.count - 1].text += "\n\n" }
        case .status(let message):
            status = message
            Chibi.shared.activity = .thinking
        case .done:
            Log.write(String(format: "answer done after %.2f s", Date().timeIntervalSince(asked)))
            finish(error: nil)
            Chibi.shared.celebrate()
            checkLinks()
        case .failed(let message):
            Log.write("engine failed: \(message)")
            engine?.cancel()
            engine = nil
            if !retried, !sawText {          // one automatic retry on a fresh process
                retried = true
                turns.removeLast()
                send()
            } else {
                finish(error: SnapSession.explain(message))
            }
        }
    }

    private func finish(error message: String?) {
        busy = false
        status = ""
        error = message
        Chibi.shared.activity = nil
        if turns.last?.role == "assistant", turns.last?.text.isEmpty == true { turns.removeLast() }
        if saved { persist() }
    }

    private static func explain(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("login") || lower.contains("api key") || lower.contains("authenticat") {
            return "Claude Code is not logged in. Run `claude` in Terminal and log in, then retry."
        }
        if lower.contains("limit") { return "Claude usage limit reached. \(message)" }
        return message
    }

    /// Asks each linked server whether the page exists; clear misses get struck through in the answer.
    private func checkLinks() {
        let answer = lastAnswer
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s)\]>"'`]+"#) else { return }
        let found = regex.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)).compactMap { Range($0.range, in: answer).map { String(answer[$0]) } }
        let links = Array(Set(found.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:*")) })).prefix(15)
        guard !links.isEmpty else { return }
        status = "Checking \(links.count) link\(links.count == 1 ? "" : "s")…"
        Task { @MainActor in
            var dead: [String] = []
            await withTaskGroup(of: String?.self) { group in
                for link in links {
                    group.addTask {
                        guard let url = URL(string: link) else { return link }
                        var request = URLRequest(url: url, timeoutInterval: 8)
                        request.httpMethod = "HEAD"
                        do {
                            let (_, response) = try await URLSession.shared.data(for: request)
                            // Stores often answer robots with 403 or 503; only a plain "not here" counts as dead.
                            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
                            return code == 404 || code == 410 ? link : nil
                        } catch let error as URLError where error.code == .cannotFindHost || error.code == .dnsLookupFailed {
                            return link
                        } catch { return nil }
                    }
                }
                for await result in group { if let result { dead.append(result) } }
            }
            deadLinks = dead
            if !busy { status = dead.isEmpty ? "" : "\(dead.count) of \(links.count) links look dead" }
        }
    }
}

@MainActor final class AskPanelController: NSObject, NSWindowDelegate {
    let session: SnapSession
    var onClose: (() -> Void)?
    private let panel: NSPanel

    /// `rect` is the selection on screen; nil (a conversation reopened from history) centres the panel.
    init(session: SnapSession, near rect: NSRect?) {
        self.session = session
        let size = NSSize(width: 460, height: 520)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        if let rect {
            let visible = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame ?? .zero
            var x = rect.maxX + 12
            if x + size.width > visible.maxX { x = rect.minX - size.width - 12 }
            if x < visible.minX { x = visible.maxX - size.width - 12 }
            let y = min(max(rect.maxY - size.height, visible.minY), visible.maxY - size.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.title = "snapIt"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 300)
        panel.delegate = self
        let host = NSHostingView(rootView: AskView(session: session) { [weak self] in self?.panel.close() })
        host.autoresizingMask = [.width, .height]
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .popover   // .windowBackground if maths over a busy background reads badly
        material.blendingMode = .behindWindow
        material.state = .active
        host.frame = material.bounds
        material.addSubview(host)
        panel.contentView = material
        panel.makeKeyAndOrderFront(nil)
    }

    func bringToFront() { panel.orderFrontRegardless() }

    func windowWillClose(_ notification: Notification) {
        session.stop()
        onClose?()
    }
}

private struct AskView: View {
    @ObservedObject var session: SnapSession
    let close: () -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    private var thumbnails: [NSImage] { [session.thumbnail] + session.extraThumbnails }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.turns.isEmpty { emptyState } else {
                AnswerView(turns: session.turns, deadLinks: session.deadLinks, busy: session.busy,
                           onRegenerate: { session.retry() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            statusRow
            composer
        }
        .ignoresSafeArea()
        .onAppear { focused = true }
        // Esc stops a running answer first; only an idle panel closes.
        .background(Button("") { if session.busy { session.stop() } else { close() } }.keyboardShortcut(.cancelAction).opacity(0))
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Array(thumbnails.prefix(4).enumerated()), id: \.offset) { _, image in Thumb(image: image) }
            if thumbnails.count > 4 {
                Text("+\(thumbnails.count - 4)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(session.contextLine).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(session.contextLine)
            Spacer(minLength: 0)
            Button { session.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconStyle()).disabled(session.busy)
                .help("Restart Claude session and reload ~/.claude.json").accessibilityLabel("Restart Claude session")
        }
        .padding(.leading, 68).padding(.trailing, Theme.s3)
        .frame(height: 44)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                ForEach(QuickAction.allCases) { action in
                    Button { session.ask(action.rawValue, sending: action.prompt) } label: { Label(action.rawValue, systemImage: action.symbol) }
                        .buttonStyle(ChipStyle())
                }
            }
            Text("or type a question · Return alone explains").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var statusRow: some View {
        if let error = session.error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Spacer()
                Button("Retry") { session.retry() }.buttonStyle(ChipStyle())
            }
            .font(.system(size: 11)).padding(.horizontal, Theme.s3).padding(.vertical, Theme.s1)
        } else if !session.status.isEmpty, session.status != "Thinking…" {
            HStack(spacing: 6) {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s1)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Menu {
                ForEach(QuickAction.allCases) { action in
                    Button(action.rawValue) { session.ask(action.rawValue, sending: action.prompt) }.disabled(session.busy)
                }
                Divider()
                Button("Copy recognised text") { copy(session.context.text ?? "") }.disabled(session.context.text == nil)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button).buttonStyle(IconStyle()).menuIndicator(.hidden).fixedSize()
                .help("Quick actions").accessibilityLabel("Quick actions")
            McpMenu(onChange: { session.refresh() }, disabled: session.busy)
            TextField(session.turns.isEmpty ? "Ask about this…  (Enter alone = Explain)" : "Ask a follow-up…", text: $question, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...5)
                .focused($focused).onSubmit(submit).padding(.vertical, 4)
            sendButton
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.rComposer))
        .overlay(RoundedRectangle(cornerRadius: Theme.rComposer).stroke(.separator, lineWidth: 0.5))
        .padding(10)
    }

    private var sendButton: some View {
        let empty = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let dim = !session.busy && empty && !session.turns.isEmpty
        return Button { if session.busy { session.stop() } else { submit() } } label: {
            Image(systemName: session.busy ? "stop.fill" : "arrow.up").font(.system(size: 12, weight: .bold))
                .foregroundStyle(dim ? Color.secondary : Color.white)
                .frame(width: 26, height: 26)
                .background(dim ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor), in: Circle())
        }
        .buttonStyle(.plain)
        .help(session.busy ? "Stop" : "Send").accessibilityLabel(session.busy ? "Stop" : "Send")
    }

    private func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !session.turns.isEmpty { return }
        question = ""
        if text.isEmpty { session.ask(QuickAction.explain.rawValue, sending: QuickAction.explain.prompt) } else { session.ask(text) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A 32 pt snap thumbnail that opens a larger preview.
private struct Thumb: View {
    let image: NSImage
    @State private var open = false
    var body: some View {
        Button { open = true } label: {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.rSmall).stroke(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain).help("Show snap").accessibilityLabel("Show snap")
        .popover(isPresented: $open) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 480, maxHeight: 360).padding(Theme.s2)
        }
    }
}
