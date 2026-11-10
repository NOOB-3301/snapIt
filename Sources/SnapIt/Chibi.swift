import AppKit
import Combine
import SnapItCore

enum Mood: String {
    case idle, thinking, talking, happy, snap, carry, tired, sleep, dragged
    var caption: String {
        switch self {
        case .idle: return "Ready"
        case .thinking: return "Thinking…"
        case .talking: return "Answering…"
        case .happy: return "Done!"
        case .snap: return "Pick something on screen"
        case .carry: return "Converting…"
        case .tired: return "Tired: heavy Claude day"
        case .sleep: return "Zzz"
        case .dragged: return "Whoa!"
        }
    }
}

/// The companion's state and current animation frame, shared by the menubar icon, the panel and the desktop window.
@MainActor final class Chibi: ObservableObject {
    static let shared = Chibi()
    @Published private(set) var frame: CGImage?
    @Published private(set) var head: CGImage?
    @Published private(set) var mood = Mood.idle
    @Published var tokensToday = 0

    var activity: Mood? { didSet { touch() } }
    var dragging = false
    var tired = false
    private var happyUntil = Date.distantPast
    private var lastTouch = Date()
    private var sprites: [String: [CGImage]] = [:]
    private var heads: [CGImage] = []
    private var tick = 0
    private var timer: Timer?
    // Long neutral holds with one blink, so idle does not look twitchy.
    private let idleLoop = [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 3, 3, 3, 3, 0, 0, 2, 3, 3, 1, 1, 1].flatMap { [$0, $0] }   // 2 ticks each: ticks run at ~9 fps

    func touch() { lastTouch = Date() }
    func celebrate() { happyUntil = Date().addingTimeInterval(2.5); touch() }

    func start() {
        // Bundled sprites first, then the user's own folder so single states can be replaced without rebuilding.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("sprites") { sprites = Sprites.load(directory: bundled) }
        let custom = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("snapIt/sprites")
        sprites.merge(Sprites.load(directory: custom)) { _, new in new }
        heads = Sprites.trimmed(sprites["menubar"] ?? [])
        Log.write("sprites loaded: \(sprites.keys.sorted().joined(separator: ", "))")
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        step()
    }

    private func currentMood() -> Mood {
        if dragging { return .dragged }
        if let activity { return activity }
        if Date() < happyUntil { return .happy }
        if tired { return .tired }
        return Date().timeIntervalSince(lastTouch) > 300 ? .sleep : .idle
    }

    private func step() {
        tick += 1
        let now = currentMood()
        if now != mood { mood = now }
        let index: Int
        switch now {
        case .idle: index = idleLoop[tick % idleLoop.count]
        case .sleep, .tired: index = (tick / 6) % 4
        default: index = tick % 4
        }
        if let frames = sprites[now.rawValue] ?? sprites["idle"] { frame = frames[index] }

        guard heads.count == 4 else { return }
        let headIndex: Int
        if !Pref.d.bool(forKey: "menubarAnimated") { headIndex = 0 }
        else {
            switch now {
            case .sleep, .tired: headIndex = (tick / 12) % 2 == 0 ? 3 : 1
            case .idle, .happy: headIndex = tick % 44 == 0 ? 1 : 0          // an occasional blink
            default: headIndex = (tick / 4) % 2 == 0 ? 2 : 1                // busy
            }
        }
        if head !== heads[headIndex] { head = heads[headIndex] }
    }
}

/// The optional floating chibi: drag to move, click to open the panel, drop files to convert them.
@MainActor final class DesktopChibi {
    private let panel: NSPanel
    private var subscription: AnyCancellable?

    init() {
        let size = Pref.d.double(forKey: "chibiSize")
        let visible = NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: visible.maxX - size - 40, y: visible.minY + 20)
        if Pref.d.object(forKey: "chibiX") != nil { origin = NSPoint(x: Pref.d.double(forKey: "chibiX"), y: Pref.d.double(forKey: "chibiY")) }
        panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let view = ChibiView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        subscription = Chibi.shared.$frame.sink { [weak view] frame in view?.layer?.contents = frame }
        // Keep it reachable if the saved spot is on a display that is no longer attached.
        if !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size - 40, y: visible.minY + 20))
        }
        panel.orderFrontRegardless()
    }

    func resize(_ size: Double) {
        guard abs(panel.frame.width - size) > 0.5 else { return }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: size, height: size)), display: true)
    }

    func close() { panel.orderOut(nil) }
}

private final class ChibiView: NSView {
    private var grabPoint = NSPoint.zero, grabOrigin = NSPoint.zero, moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        grabPoint = NSEvent.mouseLocation
        grabOrigin = window?.frame.origin ?? .zero
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        if !moved, hypot(now.x - grabPoint.x, now.y - grabPoint.y) < 4 { return }
        moved = true
        Chibi.shared.dragging = true
        window?.setFrameOrigin(NSPoint(x: grabOrigin.x + now.x - grabPoint.x, y: grabOrigin.y + now.y - grabPoint.y))
    }

    override func mouseUp(with event: NSEvent) {
        Chibi.shared.dragging = false
        Chibi.shared.touch()
        if moved, let origin = window?.frame.origin {
            Pref.d.set(origin.x, forKey: "chibiX")
            Pref.d.set(origin.y, forKey: "chibiY")
        } else {
            AppDelegate.shared.togglePopover()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        PanelState.shared.stage(urls)
        AppDelegate.shared.showPopover()
        return true
    }
}
