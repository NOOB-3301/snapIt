import AppKit
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
                    Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit().frame(width: 84, height: 84)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("snapIt").font(.headline)
                    Text(chibi.mood.caption).font(.caption).foregroundStyle(.secondary)
                    Text("Claude Code today: \(chibi.tokensToday.formatted(.number.notation(.compactName))) tokens")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button { SnapController.shared.begin() } label: {
                Label("Snap the screen   ⌃⌥S", systemImage: "viewfinder").frame(maxWidth: .infinity)
            }.controlSize(.large)
            if EnginePool.shared.cli == nil {
                Text("Claude Code was not found, so answers are off. Install it and log in.").font(.caption).foregroundStyle(.red)
            }
            Picker("", selection: $state.tab) {
                ForEach(PanelState.Tab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch state.tab {
            case .convert: ConvertView()
            case .ask: AskFilesView()
            case .history: HistoryView()
            }
            Divider()
            DisclosureGroup("Settings", isExpanded: $showSettings) { settings }
            HStack { Spacer(); Button("Quit snapIt") { NSApp.terminate(nil) } }
        }
        .padding(12)
        .frame(width: 350)
        .background(Button("") { AppDelegate.shared.closePopover() }.keyboardShortcut(.cancelAction).opacity(0))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Animate notch icon", isOn: $menubarAnimated)
            Toggle("Show chibi in this panel", isOn: $panelChibi)
            Toggle("Show chibi on desktop", isOn: $desktopChibi)
            if desktopChibi { HStack { Text("Size"); Slider(value: $chibiSize, in: 80...260) } }
            Toggle("Send recognised text with snaps", isOn: $sendText)
            Toggle("Send browser page URL with snaps", isOn: $sendURL)
            HStack { Text("Shop in"); TextField("Region", text: $region); TextField("Currency", text: $currency).frame(width: 60) }
            Picker("Model", selection: $model) {
                Text("Claude Code default").tag(""); Text("Opus").tag("opus"); Text("Sonnet").tag("sonnet"); Text("Haiku (fastest)").tag("haiku")
            }
            HStack { Text("Tired above"); TextField("", value: $tiredTokens, format: .number).frame(width: 90); Text("tokens/day") }
            HStack { Text("Keep history"); TextField("", value: $historyDays, format: .number).frame(width: 50); Text("days (0 = forever)") }
            HStack {
                Text("Save to"); TextField("next to the original", text: $outputFolder)
                Button("Choose…") {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = true
                    picker.canChooseFiles = false
                    NSApp.activate(ignoringOtherApps: true)
                    if picker.runModal() == .OK, let url = picker.url { outputFolder = url.path }
                    AppDelegate.shared.showPopover()
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { Log.write("launch at login: \(error.localizedDescription)"); launchAtLogin = SMAppService.mainApp.status == .enabled }
            }
        }.font(.callout).padding(.top, 4)
    }
}

/// A dashed box that takes dropped files or opens a file picker on click.
private struct DropZone: View {
    let files: [URL]
    let stage: ([URL]) -> Void

    var body: some View {
        Text(files.isEmpty ? "Drop files here, or click to choose"
             : "\(files.count) file\(files.count == 1 ? "" : "s"): " + files.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (files.count > 3 ? "…" : ""))
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 50).padding(6)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.secondary))
            .contentShape(Rectangle())
            .onTapGesture {
                let picker = NSOpenPanel()
                picker.allowsMultipleSelection = true
                picker.canChooseDirectories = false
                NSApp.activate(ignoringOtherApps: true)
                if picker.runModal() == .OK { stage(picker.urls) }
                AppDelegate.shared.showPopover()
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadFileURLs(providers, then: stage)
                return true
            }
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
            DropZone(files: model.staged) { model.stage($0) }
            HStack {
                if model.running { Button("Cancel") { model.cancel() }; ProgressView(value: model.progress) }
                else {
                    Button("Convert") { model.run() }.disabled(model.staged.isEmpty)
                    Button("Clear") { model.clear() }.disabled(model.staged.isEmpty && model.jobs.isEmpty)
                }
            }
            if !model.jobs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.jobs) { job in
                            HStack {
                                Text(line(job)).font(.caption).foregroundStyle(job.error == nil ? Color.secondary : Color.red).textSelection(.enabled)
                                Spacer()
                                if let first = job.outputs.first { Button("Show") { model.reveal(first) }.controlSize(.small) }
                            }
                        }
                    }
                }.frame(maxHeight: 110)
            }
        }
    }

    private func line(_ job: ConvertModel.Job) -> String {
        if let error = job.error { return "\(job.input.lastPathComponent): \(error)" }
        return "\(job.input.lastPathComponent)  ·  \(sizes.string(fromByteCount: Int64(job.before))) → \(sizes.string(fromByteCount: Int64(job.after)))"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For anything the tools above cannot do, like PDF to Excel. Claude works on copies; results land next to your files.")
                .font(.caption).foregroundStyle(.secondary)
            DropZone(files: model.files) { model.stage($0) }
            HStack {
                TextField("What should be done with them?", text: $model.instruction).textFieldStyle(.roundedBorder).onSubmit { model.send() }
                if model.running { Button("Stop") { model.cancel() } }
                else {
                    Button("Go") { model.send() }
                    Button("Clear") { model.files = []; model.turns = []; model.status = "" }.disabled(model.files.isEmpty && model.turns.isEmpty)
                }
            }
            if !model.status.isEmpty {
                HStack(spacing: 6) {
                    if model.running { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !model.turns.isEmpty { AnswerView(turns: model.turns).frame(height: 150) }
        }
    }
}

private struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var query = ""
    private static let dates: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search snaps", text: $query).textFieldStyle(.roundedBorder)
                Button("Clear all") { store.clearAll() }.disabled(store.items.isEmpty)
            }
            let records = store.matching(query)
            if records.isEmpty {
                Text(store.items.isEmpty ? "No snaps yet. Press ⌃⌥S over anything." : "Nothing matches.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(records) { record in
                            HStack {
                                Button { SnapController.shared.reopen(record) } label: {
                                    VStack(alignment: .leading) {
                                        Text(record.title).lineLimit(1)
                                        Text(Self.dates.string(from: record.date)).font(.caption2).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { store.delete(record) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }.frame(maxHeight: 200)
            }
        }
    }
}
