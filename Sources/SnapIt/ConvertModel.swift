import AppKit
import Combine
import ImageIO
import SnapItCore
import UniformTypeIdentifiers

/// A fixed output folder when it is usable, otherwise nil meaning "next to the original".
enum ConvertOutput {
    static var folder: URL? {
        guard let path = Pref.d.string(forKey: "outputFolder"), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        return url
    }
}

/// Staged files, per-tool options and the batch runner around the offline converters.
@MainActor final class ConvertModel: ObservableObject {
    static let shared = ConvertModel()

    enum Tool: String, CaseIterable, Identifiable {
        case imagesToPDF, pdfToImages, resizeImage, convertVideo, shrinkPDF
        var id: String { rawValue }

        var title: String {
            switch self {
            case .imagesToPDF: return "Images to PDF"
            case .pdfToImages: return "PDF to images"
            case .resizeImage: return "Resize image"
            case .convertVideo: return "Convert video"
            case .shrinkPDF: return "Shrink PDF"
            }
        }

        var accepts: [UTType] {
            switch self {
            case .imagesToPDF, .resizeImage: return [.image]
            case .pdfToImages, .shrinkPDF: return [.pdf]
            case .convertVideo: return [.movie]
            }
        }

        func matches(_ url: URL) -> Bool {
            guard let type = UTType(filenameExtension: url.pathExtension) ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) else { return false }
            return accepts.contains { type.conforms(to: $0) }
        }
    }

    struct Job: Identifiable {
        let id = UUID()
        var input: URL
        var outputs: [URL] = []
        var error: String?
        var before: Int = 0
        var after: Int = 0
    }

    @Published var staged: [URL] = []
    @Published var tool = Tool.imagesToPDF
    @Published var running = false
    @Published var jobs: [Job] = []
    @Published var progress = 0.0
    @Published var maxDimension = 1600 { didSet { percent = nil } }
    @Published var imageFormat = ImageFormat.jpg
    @Published var pdfImageFormat = ImageFormat.png
    @Published var dpi = 150
    @Published var shrink = PDFShrink.balanced
    @Published var videoPreset = Convert.videoPresets[0].preset

    // Percent is kept apart so a batch scales every file by its own size, not the largest one's.
    private var percent: Int?
    private var token = UUID()

    private struct Options: Sendable {
        var maxDimension: Int
        var percent: Int?
        var imageFormat: ImageFormat
        var pdfImageFormat: ImageFormat
        var dpi: Int
        var shrink: PDFShrink
        var videoPreset: String
    }

    func stage(_ urls: [URL]) {
        Chibi.shared.touch()
        var accepted: [URL] = []
        for url in urls {
            guard Tool.allCases.contains(where: { $0.matches(url) }) else {
                jobs.append(Job(input: url, error: "No convert tool handles \(url.lastPathComponent)"))
                continue
            }
            accepted.append(url)
        }
        guard !accepted.isEmpty else { return }
        staged += accepted
        if !accepted.contains(where: { tool.matches($0) }), let next = Tool.allCases.first(where: { $0.matches(accepted[0]) }) { tool = next }
    }

    /// Percent of the longest side, for a percent field next to the pixels field.
    func applyPercent(_ value: Int) {
        guard value > 0 else { maxDimension = 0; return }
        let longest = staged.compactMap { Self.longestSide($0) }.max() ?? 0
        maxDimension = longest > 0 ? max(1, longest * value / 100) : 0
        percent = value
    }

    func run() {
        guard !running, !staged.isEmpty else { return }
        let inputs = staged, choice = tool, dir = ConvertOutput.folder
        let options = Options(maxDimension: maxDimension, percent: percent, imageFormat: imageFormat,
                              pdfImageFormat: pdfImageFormat, dpi: dpi, shrink: shrink, videoPreset: videoPreset)
        let batches = choice == .imagesToPDF ? [inputs] : inputs.map { [$0] }
        jobs = []
        progress = 0
        running = true
        Chibi.shared.activity = .carry
        token = UUID()
        let mine = token
        Task {
            for (index, batch) in batches.enumerated() {
                let result = await Task.detached(priority: .userInitiated) { await Self.convert(batch, choice, options, dir) }.value
                guard self.token == mine else { return }
                self.jobs.append(Job(input: batch[0], outputs: result.outputs, error: result.error, before: result.before, after: result.after))
                self.progress = Double(index + 1) / Double(batches.count)
                if let error = result.error { Log.write("convert \(choice.rawValue) failed on \(batch[0].lastPathComponent): \(error)") }
            }
            self.running = false
            Chibi.shared.activity = nil
            if self.jobs.contains(where: { $0.error == nil && !$0.outputs.isEmpty }) { Chibi.shared.celebrate() }
        }
    }

    /// Stops starting new work; a file already inside a converter finishes and its result is dropped.
    func cancel() {
        token = UUID()
        guard running else { return }
        running = false
        Chibi.shared.activity = nil
    }

    func clear() {
        cancel()
        staged = []
        jobs = []
        progress = 0
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private nonisolated static func convert(_ inputs: [URL], _ tool: Tool, _ options: Options, _ dir: URL?) async
        -> (outputs: [URL], before: Int, after: Int, error: String?) {
        guard let input = inputs.first else { return ([], 0, 0, "Nothing to convert") }
        let before = size(inputs)
        do {
            let outputs: [URL]
            switch tool {
            case .imagesToPDF:
                outputs = [try Convert.imagesToPDF(inputs, outDir: dir)]
            case .pdfToImages:
                outputs = try Convert.pdfToImages(input, format: options.pdfImageFormat, dpi: options.dpi, outDir: dir)
            case .resizeImage:
                let limit = options.percent.flatMap { p in longestSide(input).map { max(1, $0 * p / 100) } }
                    ?? (options.maxDimension > 0 ? options.maxDimension : nil)
                outputs = [try Convert.resizeImage(input, maxDimension: limit, format: options.imageFormat, outDir: dir)]
            case .shrinkPDF:
                outputs = [try Convert.shrinkPDF(input, level: options.shrink, outDir: dir)]
            case .convertVideo:
                outputs = [try await Convert.convertVideo(input, preset: options.videoPreset, outDir: dir)]
            }
            return (outputs, before, size(outputs), nil)
        } catch {
            return ([], before, 0, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private nonisolated static func size(_ urls: [URL]) -> Int {
        urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private nonisolated static func longestSide(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }
}