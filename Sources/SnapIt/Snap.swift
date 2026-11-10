import AppKit
import ScreenCaptureKit
import Vision

struct SnapContext {
    var app: String?
    var title: String?
    var url: String?
    var text: String?
}

enum Probe {
    static func windowTitle(pid: pid_t) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        return (front?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Front tab URL of a known browser. macOS asks for permission once per browser; a refusal just returns nil.
    static func browserURL(bundleID: String?) async -> String? {
        let chromium = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac"]
        guard let bundleID else { return nil }
        let script: String
        if bundleID == "com.apple.Safari" { script = "tell application id \"\(bundleID)\" to return URL of front document" }
        else if chromium.contains(bundleID) { script = "tell application id \"\(bundleID)\" to return URL of active tab of front window" }
        else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: nil); return }
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                let url = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: url.hasPrefix("http") ? url : nil)
            }
        }
    }

    static func recognizeText(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
        }
    }
}

enum Capture {
    /// A still of every display, without snapIt's own windows.
    static func allDisplays() async throws -> [(NSScreen, CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        var shots: [(NSScreen, CGImage)] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
            shots.append((screen, image))
        }
        return shots
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the frozen screen; drag selects a region, Enter takes the whole screen, Esc cancels.
private final class OverlayView: NSView {
    private let image: CGImage
    var onSelect: ((CGImage, NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private let dim = CAShapeLayer(), outline = CAShapeLayer()
    private let hint = CALayer(), badge = CALayer()
    private let text = CATextLayer(), badgeText = CATextLayer()
    private var start: NSPoint?

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        let root = CALayer()
        root.contents = image
        layer = root
        wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.cgColor
        outline.lineWidth = 1
        outline.shadowColor = NSColor.black.cgColor
        outline.shadowOpacity = 0.6
        outline.shadowRadius = 3
        outline.shadowOffset = .zero
        root.addSublayer(dim)
        root.addSublayer(outline)
        let hintWidth: CGFloat = 400
        hint.frame = CGRect(x: frame.width / 2 - hintWidth / 2, y: frame.height - 70, width: hintWidth, height: 26)
        Self.style(hint, text, "Drag to select  ·  Enter for whole screen  ·  Esc to cancel")
        badge.isHidden = true
        root.addSublayer(hint)
        Self.style(badge, badgeText, "")
        root.addSublayer(badge)
        show(nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// A pill with its text centred vertically; CATextLayer cannot do that by itself.
    private static func style(_ pill: CALayer, _ label: CATextLayer, _ string: String) {
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        pill.cornerRadius = 13
        label.string = string
        label.fontSize = 12
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.cgColor
        label.contentsScale = 2
        label.frame = CGRect(x: 0, y: 5, width: pill.bounds.width, height: 16)
        label.autoresizingMask = [.layerWidthSizable]
        if label.superlayer == nil { pill.addSublayer(label) }
    }

    private func show(_ selection: NSRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection { path.addRect(selection) }
        dim.path = path
        outline.path = selection.map { CGPath(rect: $0, transform: nil) }
        if let selection {
            let scale = CGFloat(image.width) / bounds.width
            badgeText.string = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
            let width: CGFloat = 96
            badge.frame = CGRect(x: min(max(selection.maxX - width, 4), bounds.width - width - 4),
                                 y: max(selection.minY - 34, 4), width: width, height: 26)
            badgeText.frame = CGRect(x: 0, y: 5, width: width, height: 16)
            badge.isHidden = false
        } else { badge.isHidden = true }
        CATransaction.commit()
    }

    private func selection(to event: NSEvent) -> NSRect? {
        guard let start else { return nil }
        let now = convert(event.locationInWindow, from: nil)
        return NSRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y)).intersection(bounds)
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) { show(selection(to: event)) }
    override func mouseUp(with event: NSEvent) {
        if let rect = selection(to: event), rect.width > 6, rect.height > 6 { finish(rect) } else { show(nil) }
        start = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }                                   // Esc
        else if event.keyCode == 36 || event.keyCode == 76 { finish(bounds) }    // Return, Enter
    }

    private func finish(_ rect: NSRect) {
        let scale = CGFloat(image.width) / bounds.width
        // The image has a top-left origin, the view a bottom-left one.
        let crop = CGRect(x: rect.minX * scale, y: (bounds.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = image.cropping(to: crop), let window else { onCancel?(); return }
        onSelect?(cropped, window.convertToScreen(rect))
    }
}

@MainActor final class SnapController {
    static let shared = SnapController()
    private var overlays: [NSPanel] = []
    private var panels: [AskPanelController] = []
    private var starting = false

    func begin() {
        guard overlays.isEmpty, !starting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            explainPermission()
            return
        }
        starting = true
        let front = NSWorkspace.shared.frontmostApplication
        let began = Date()
        AppDelegate.shared.closePopover()
        Chibi.shared.activity = .snap
        Task { @MainActor in
            defer { starting = false }
            do {
                let shots = try await Capture.allDisplays()
                for (screen, image) in shots { addOverlay(screen: screen, image: image, front: front) }
                Log.write(String(format: "overlay shown in %.0f ms", Date().timeIntervalSince(began) * 1000))
            } catch {
                Chibi.shared.activity = nil
                Log.write("capture failed: \(error.localizedDescription)")
                explainPermission()
            }
        }
    }

    private func addOverlay(screen: NSScreen, image: CGImage, front: NSRunningApplication?) {
        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        view.onCancel = { [weak self] in self?.end() }
        view.onSelect = { [weak self] cropped, rect in
            self?.end()
            self?.openAsk(image: cropped, near: rect, front: front)
        }
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        overlays.append(panel)
        // Keys go to the overlay under the pointer; the app underneath stays the active app.
        if screen.frame.contains(NSEvent.mouseLocation) || overlays.count == 1 {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func end() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        Chibi.shared.activity = nil
    }

    private func openAsk(image: CGImage, near rect: NSRect, front: NSRunningApplication?) {
        // A snap taken while a chat is open joins the newest chat instead of opening another window.
        if let latest = panels.last {
            latest.session.add(image: image)
            latest.bringToFront()
        } else {
            show(SnapSession(image: image, front: front), near: rect)
        }
    }

    func reopen(_ record: SnapRecord) {
        guard let session = SnapSession(record: record) else { return }
        AppDelegate.shared.closePopover()
        show(session, near: nil)
    }

    private func show(_ session: SnapSession, near rect: NSRect?) {
        let controller = AskPanelController(session: session, near: rect)
        controller.onClose = { [weak self, weak controller] in self?.panels.removeAll { $0 === controller } }
        panels.append(controller)
    }

    private func explainPermission() {
        let alert = NSAlert()
        alert.messageText = "snapIt needs Screen Recording permission"
        alert.informativeText = "Turn on snapIt under Privacy & Security → Screen & System Audio Recording, then quit and reopen snapIt."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
