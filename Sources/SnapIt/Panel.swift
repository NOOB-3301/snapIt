import AppKit
import ImageIO
import ServiceManagement
import SnapItCore
import SwiftUI
import UniformTypeIdentifiers

/// Which tab of the menubar panel is showing, and where dropped files go.
@MainActor final class PanelState: ObservableObject {
    static let shared = PanelState()
    enum Tab: String, CaseIterable, Identifiable { case convert = "Convert", ask = "Ask Claude", history = "History"; var id: String { rawValue } }
    @Published var tab = Tab.convert

    /// Files every offline tool understands go to Convert; anything else goes to the Claude route.
    func stage(_ urls: [URL]) {
        if urls.allSatisfy({ url in ConvertModel.Tool.allCases.contains { $0.matches(url) } }) {
            ConvertModel.shared.stage(urls)
            tab = .convert
        } else {
            AskFilesModel.shared.stage(urls)
            tab = .ask
        }
    }
}

struct PanelView: View {
    @ObservedObject private var chibi = Chibi.shared
    @ObservedObject private var state = PanelState.shared
    @AppStorage("menubarAnimated") private var menubarAnimated = true
    @AppStorage("panelChibi") private var panelChibi = true
    @AppStorage("desktopChibi") private var desktopChibi = true
    @AppStorage("chibiSize") private var chibiSize = 140.0
    @AppStorage("sendText") private var sendText = true
    @AppStorage("sendURL") private var sendURL = true
    @AppStorage("region") private var region = "India"
    @AppStorage("currency") private var currency = "INR"
    @AppStorage("model") private var model = ""
    @AppStorage("tiredTokens") private var tiredTokens = 3_000_000.0
    @AppStorage("historyDays") private var historyDays = 30
    @AppStorage("outputFolder") private var outputFolder = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if panelChibi, let frame = chibi.frame {
                    Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit().frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("snapIt").font(.headline)
                    Text(chibi.mood.caption).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Claude Code today: \(chibi.tokensToday.formatted(.number.notation(.compactName))) tokens")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(IconStyle()).help("Settings").accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(IconStyle()).help("Quit snapIt").accessibilityLabel("Quit snapIt")
            }
            Button { SnapController.shared.begin() } label: {
                HStack {
                    Label("Snap the screen", systemImage: "viewfinder")
                    Spacer()
                    Text("⌃⌥S").font(.system(size: 11, design: .monospaced)).opacity(0.7)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
            if EnginePool.shared.cli == nil {
                Label("Claude Code was not found, so answers are off. Install it and log in.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .padding(Theme.s2).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.rCard))
            }
            if showSettings {
                HStack {
                    Text("Settings").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Done") { showSettings = false }.buttonStyle(ChipStyle())
                }
                ScrollView { settings }.frame(maxHeight: 360)
            } else {
                Picker("", selection: $state.tab) {
                    ForEach(PanelState.Tab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                switch state.tab {
                case .convert: ConvertView()
                case .ask: AskFilesView()
                case .history: HistoryView()
                }
            }
        }
        .padding(12)
        .frame(width: 350)
        .background(Button("") { AppDelegate.shared.closePopover() }.keyboardShortcut(.cancelAction).opacity(0))
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .gridCellColumns(2).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settings: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            caption("Chibi")
            row("Notch icon") { Toggle("Animate", isOn: $menubarAnimated) }
            row("In panel") { Toggle("Show", isOn: $panelChibi) }
            row("On desktop") { Toggle("Show", isOn: $desktopChibi) }
            if desktopChibi { row("Size") { Slider(value: $chibiSize, in: 80...260) } }
            caption("Snaps")
            row("Recognised text") { Toggle("Send with snaps", isOn: $sendText) }
            row("Page URL") { Toggle("Send with snaps", isOn: $sendURL) }
            row("Keep history") { HStack { TextField("", value: $historyDays, format: .number).frame(width: 50); Text("days (0 = forever)").font(.system(size: 11)).foregroundStyle(.secondary) } }
            caption("Claude")
            row("Model") {
                Picker("", selection: $model) {
                    Text("Claude Code default").tag(""); Text("Opus").tag("opus"); Text("Sonnet").tag("sonnet"); Text("Haiku (fastest)").tag("haiku")
                }.labelsHidden()
            }
            row("Shop in") { HStack { TextField("Region", text: $region); TextField("Currency", text: $currency).frame(width: 60) } }
            row("Tired above") { HStack { TextField("", value: $tiredTokens, format: .number).frame(width: 90); Text("tokens/day").font(.system(size: 11)).foregroundStyle(.secondary) } }
            caption("Files")
            row("Save to") {
                HStack {
                    TextField("next to the original", text: $outputFolder)
                    Button("Choose…") {
                        let picker = NSOpenPanel()
                        picker.canChooseDirectories = true
                        picker.canChooseFiles = false
                        NSApp.activate(ignoringOtherApps: true)
                        if picker.runModal() == .OK, let url = picker.url { outputFolder = url.path }
                        AppDelegate.shared.showPopover()
                    }
                }
            }
            caption("General")
            row("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { Log.write("launch at login: \(error.localizedDescription)"); launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            }
        }
        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
        .padding(.top, 4)
    }
}

/// A dashed box that takes dropped files or opens a file picker on click; staged files show as removable chips.
private struct DropZone: View {
    let files: [URL]
    let stage: ([URL]) -> Void
    let remove: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            if files.isEmpty {
                Image(systemName: "arrow.down.doc").font(.system(size: 16))
                Text("Drop files here, or click to choose").font(.system(size: 12))
            } else {
                FileChips(files: files, remove: remove)
            }
        }
        .foregroundStyle(targeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, minHeight: 56).padding(6)
        .background(RoundedRectangle(cornerRadius: Theme.rCard).fill(Color.accentColor.opacity(targeted ? 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
            .foregroundStyle(targeted ? Color.accentColor : .secondary))
        .contentShape(Rectangle())
        .onTapGesture {
            let picker = NSOpenPanel()
            picker.allowsMultipleSelection = true
            picker.canChooseDirectories = false
            NSApp.activate(ignoringOtherApps: true)
            if picker.runModal() == .OK { stage(picker.urls) }
            AppDelegate.shared.showPopover()
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(providers, then: stage)
            return true
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// Removable chips, one per staged file.
private struct FileChips: View {
    let files: [URL]
    let remove: (URL) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(files, id: \.self) { url in
                HStack(spacing: 4) {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                    Button { remove(url) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(url.lastPathComponent)")
                }
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }
}

/// Wraps children onto new lines when the row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 300).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, placed.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}

private struct ConvertView: View {
    @ObservedObject private var model = ConvertModel.shared
    private let sizes = ByteCountFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tool", selection: $model.tool) {
                ForEach(ConvertModel.Tool.allCases) { Text($0.title).tag($0) }
            }
            options
            DropZone(files: model.staged, stage: { model.stage($0) }, remove: { url in model.staged.removeAll { $0 == url } })
            HStack {
                if model.running { Button("Cancel") { model.cancel() }; ProgressView(value: model.progress) }
                else {
                    Button("Convert") { model.run() }.buttonStyle(.borderedProminent).disabled(model.staged.isEmpty)
                    Button("Clear") { model.clear() }.disabled(model.staged.isEmpty && model.jobs.isEmpty)
                }
            }
            if !model.jobs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.jobs) { job in jobRow(job) }
                    }
                }.frame(maxHeight: 110)
            }
        }
    }

    @ViewBuilder private func jobRow(_ job: ConvertModel.Job) -> some View {
        HStack(spacing: 6) {
            if let error = job.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("\(job.input.lastPathComponent): \(error)").font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                Spacer(minLength: 0)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: job.input.path)).resizable().frame(width: 16, height: 16)
                Text(job.input.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(saving(job)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if let first = job.outputs.first {
                    Button { model.reveal(first) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(IconStyle()).help("Show in Finder").accessibilityLabel("Show in Finder")
                }
            }
        }
    }

    private func saving(_ job: ConvertModel.Job) -> String {
        var text = "\(sizes.string(fromByteCount: Int64(job.before))) → \(sizes.string(fromByteCount: Int64(job.after)))"
        if job.before > 0, job.after < job.before { text += "  −\(100 - job.after * 100 / job.before)%" }
        return text
    }

    @ViewBuilder private var options: some View {
        switch model.tool {
        case .resizeImage:
            HStack {
                Text("Longest side"); TextField("px", value: $model.maxDimension, format: .number.grouping(.never)).frame(width: 60); Text("px")
                Menu("%") { ForEach([75, 50, 25], id: \.self) { value in Button("\(value)% of original") { model.applyPercent(value) } } }.frame(width: 50)
                Picker("", selection: $model.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }.labelsHidden()
            }
        case .pdfToImages:
            HStack {
                Picker("Format", selection: $model.pdfImageFormat) { Text("PNG").tag(ImageFormat.png); Text("JPG").tag(ImageFormat.jpg) }
                Picker("DPI", selection: $model.dpi) { Text("72").tag(72); Text("150").tag(150); Text("300").tag(300) }
            }
        case .shrinkPDF:
            Picker("Level", selection: $model.shrink) { Text("Balanced").tag(PDFShrink.balanced); Text("Smallest").tag(PDFShrink.smallest) }.pickerStyle(.segmented)
        case .convertVideo:
            Picker("Output", selection: $model.videoPreset) {
                ForEach(Convert.videoPresets, id: \.preset) { Text($0.name).tag($0.preset) }
            }
        case .imagesToPDF:
            Text("One page per image, in the order added.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AskFilesView: View {
    @ObservedObject private var model = AskFilesModel.shared
    @State private var targeted = false
    private let examples = ["Find the largest files in Downloads", "Summarise the PDF I attach", "Tidy the screenshots on my Desktop"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ask Claude to do anything on this Mac. It works on your real files.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { model.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(IconStyle()).disabled(model.turns.isEmpty && model.files.isEmpty)
                    .help("New chat (also reloads ~/.claude.json)").accessibilityLabel("New chat")
            }
            Group {
                if model.turns.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(examples, id: \.self) { example in
                            Button(example) { model.instruction = example }.buttonStyle(ChipStyle())
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AnswerView(turns: model.turns, busy: model.running, canRegenerate: false)
                }
            }.frame(height: 260)
            if !model.status.isEmpty {
                HStack(spacing: 6) {
                    if model.running { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !model.files.isEmpty { FileChips(files: model.files) { url in model.files.removeAll { $0 == url } } }
            composer
        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard).stroke(Color.accentColor, lineWidth: targeted ? 1.5 : 0))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(providers) { model.stage($0) }
            return true
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button {
                let picker = NSOpenPanel()
                picker.allowsMultipleSelection = true
                picker.canChooseDirectories = false
                NSApp.activate(ignoringOtherApps: true)
                if picker.runModal() == .OK { model.stage(picker.urls) }
                AppDelegate.shared.showPopover()
            } label: { Image(systemName: "paperclip") }
                .buttonStyle(IconStyle()).help("Attach files").accessibilityLabel("Attach files")
            McpMenu(onChange: { model.restartEngine() }, disabled: model.running)
            TextField("Ask Claude…", text: $model.instruction, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                .onSubmit { model.send() }.padding(.vertical, 4)
            Button { if model.running { model.cancel() } else { model.send() } } label: {
                Image(systemName: model.running ? "stop.fill" : "arrow.up").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white).frame(width: 26, height: 26).background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain).help(model.running ? "Stop" : "Send").accessibilityLabel(model.running ? "Stop" : "Send")
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.rComposer))
        .overlay(RoundedRectangle(cornerRadius: Theme.rComposer).stroke(.separator, lineWidth: 0.5))
    }
}

private struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search snaps", text: $query).textFieldStyle(.roundedBorder)
                Button(confirmClear ? "Delete all \(store.items.count) snaps?" : "Clear all") {
                    if confirmClear { store.clearAll(); confirmClear = false }
                    else {
                        confirmClear = true
                        // A dialog would need the app active; the notch panel is non-activating, so the button itself asks.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmClear = false }
                    }
                }
                .foregroundStyle(confirmClear ? Color.red : .primary).disabled(store.items.isEmpty)
            }
            let records = store.matching(query)
            if records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "viewfinder").font(.system(size: 20))
                    Text(store.items.isEmpty ? "No snaps yet. Press ⌃⌥S over anything." : "Nothing matches.").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, Theme.s3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(records) { record in HistoryRow(record: record, store: store) }
                    }
                }.frame(maxHeight: 200)
            }
        }
    }
}

private struct HistoryRow: View {
    let record: SnapRecord
    let store: HistoryStore
    @State private var hover = false
    @State private var thumb: NSImage?
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        HStack(spacing: 8) {
            Button { SnapController.shared.reopen(record) } label: {
                HStack(spacing: 8) {
                    Group {
                        if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
                        else { Color.gray.opacity(0.2) }
                    }
                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: Theme.rSmall))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.title).font(.system(size: 13)).lineLimit(1)
                        Text(record.date.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { store.delete(record) } label: { Image(systemName: "trash") }
                .buttonStyle(IconStyle()).opacity(hover ? 1 : 0).help("Delete").accessibilityLabel("Delete")
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(.quaternary.opacity(hover ? 0.5 : 0), in: RoundedRectangle(cornerRadius: Theme.rSmall))
        .onHover { hover = $0 }
        .task(id: record.id) {
            let key = record.id.uuidString as NSString
            if let cached = Self.cache.object(forKey: key) { thumb = cached; return }
            guard let data = store.imagePNG(record) else { return }
            let image = await Task.detached(priority: .utility) { Self.downscale(data) }.value
            if let image { Self.cache.setObject(image, forKey: key); thumb = image }
        }
    }

    private nonisolated static func downscale(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 72,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
