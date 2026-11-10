import AppKit
import SwiftUI

@MainActor final class NotchState: ObservableObject {
    static let shared = NotchState()
    @Published var expanded = false
    /// The physical notch of the screen the app sits on; zero width on a display without one.
    @Published var notch = CGSize(width: 0, height: 24)
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // AppKit would otherwise push a window out of the menu bar area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class HoverView: NSView {
    var onEnter: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
}

/// The app's home: a black tab that blends into the notch and drops open into the panel on hover.
@MainActor final class NotchController {
    private let panel: NotchPanel
    private let state = NotchState.shared
    private var size = CGSize(width: 80, height: 24)
    private var timer: Timer?
    private var openedAt = Date.distantPast
    private var pointerEntered = false

    init() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // above the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)   // the panel is always black, like the notch
        panel.isReleasedWhenClosed = false

        let hover = HoverView()
        let host = NSHostingView(rootView: NotchView { [weak self] size in self?.resize(to: size) })
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        hover.addSubview(host)
        hover.onEnter = { [weak self] in
            // A short dwell, so brushing past on the way to a menu does not open it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let self, self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.expand()
            }
        }
        panel.contentView = hover

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        layout()
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfAbandoned() }
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first }

    private func layout() {
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            state.notch = CGSize(width: 0, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        place()
    }

    private func place() {
        guard let frame = screen?.frame else { return }
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func resize(to newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0, newSize != size else { return }
        size = newSize
        place()
    }

    func expand() {
        guard !state.expanded else { return }
        Chibi.shared.touch()
        openedAt = Date()
        pointerEntered = false
        state.expanded = true
    }

    func collapse() {
        guard state.expanded else { return }
        state.expanded = false
        // Hand the keyboard back to the app underneath.
        if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }
    }

    func toggle() { state.expanded ? collapse() : expand() }

    /// Open stays open while the pointer is over it, while it has the keyboard, or while something is being dragged.
    private func closeIfAbandoned() {
        guard state.expanded, !panel.isKeyWindow, NSEvent.pressedMouseButtons == 0 else { return }
        if panel.frame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation) { pointerEntered = true; return }
        // Opened by a click elsewhere (the desktop chibi): give the pointer time to arrive before treating it as abandoned.
        if !pointerEntered, Date().timeIntervalSince(openedAt) < 5 { return }
        collapse()
    }
}

private struct NotchView: View {
    @ObservedObject private var state = NotchState.shared
    @ObservedObject private var chibi = Chibi.shared
    let onSize: (CGSize) -> Void
    private let ear: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            // Always visible: her head left of the notch, what she is doing right of it.
            HStack(spacing: 0) {
                Group {
                    if let head = chibi.head { Image(decorative: head, scale: 1).resizable().interpolation(.high).scaledToFit().padding(.vertical, 5) }
                    else { Image(systemName: "camera.viewfinder") }
                }.frame(width: ear, height: state.notch.height)
                Spacer(minLength: state.notch.width)
                Image(systemName: glyph).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: state.notch.width > 0 || state.expanded ? ear : 0, height: state.notch.height)
            }
            .contentShape(Rectangle())
            .onTapGesture { AppDelegate.shared.togglePopover() }
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { false }, set: { if $0 { AppDelegate.shared.showPopover() } })) { providers in
                loadFileURLs(providers) { PanelState.shared.stage($0); AppDelegate.shared.showPopover() }
                return true
            }
            if state.expanded { PanelView() }
        }
        .background(UnevenRoundedRectangle(bottomLeadingRadius: state.expanded ? 18 : 10, bottomTrailingRadius: state.expanded ? 18 : 10).fill(.black))
        .fixedSize()
        .background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size, initial: true) { _, size in onSize(size) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var glyph: String {
        switch chibi.mood {
        case .thinking, .talking: return "ellipsis"
        case .carry: return "arrow.triangle.2.circlepath"
        case .snap: return "viewfinder"
        case .happy: return "checkmark"
        case .tired: return "battery.25percent"
        case .sleep: return "moon.zzz.fill"
        case .idle, .dragged: return state.expanded ? "chevron.up" : ""
        }
    }
}

/// Collects the file URLs of a drop, then calls back once on the main thread.
@MainActor func loadFileURLs(_ providers: [NSItemProvider], then: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async { if let url { urls.append(url) }; group.leave() }
        }
    }
    group.notify(queue: .main) { if !urls.isEmpty { then(urls) } }
}
