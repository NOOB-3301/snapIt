import AVFoundation
import AppKit
import ImageIO
import PDFKit

public enum ConvertError: LocalizedError {
    case unreadable(URL), writeFailed(URL), notSmaller, unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not read \(url.lastPathComponent)"
        case .writeFailed(let url): return "Could not write \(url.lastPathComponent)"
        case .notSmaller: return "Already compact, no smaller version was kept"
        case .unsupported(let what): return what
        }
    }
}

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpg, png, heic
    var uti: CFString { (self == .jpg ? "public.jpeg" : self == .png ? "public.png" : "public.heic") as CFString }
}

public enum PDFShrink: String, CaseIterable, Sendable { case balanced, smallest }

/// Every converter writes a new file and never touches its input.
public enum Convert {
    /// `<dir>/<name>.<ext>`, with -2, -3… appended if that already exists.
    public static func freeURL(dir: URL, name: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(name).\(ext)"), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(n).\(ext)"); n += 1
        }
        return url
    }

    private static func target(_ input: URL, _ suffix: String, _ ext: String, _ outDir: URL?) -> URL {
        freeURL(dir: outDir ?? input.deletingLastPathComponent(), name: input.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    private static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.uti, 1, nil) else { throw ConvertError.writeFailed(url) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed(url) }
    }

    /// One page per image, each page shaped like its image and fitted inside A4.
    public static func imagesToPDF(_ inputs: [URL], outDir: URL? = nil) throws -> URL {
        guard let first = inputs.first else { throw ConvertError.unsupported("No images given") }
        let doc = PDFDocument()
        for url in inputs {
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { throw ConvertError.unreadable(url) }
            let landscape = image.size.width > image.size.height
            let limit = landscape ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842)
            let scale = min(limit.width / image.size.width, limit.height / image.size.height)
            let box = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            guard let page = PDFPage(image: image, options: [.mediaBox: box, .compressionQuality: 0.85, .upscaleIfSmaller: true]) else { throw ConvertError.unreadable(url) }
            doc.insert(page, at: doc.pageCount)
        }
        let out = target(first, "", "pdf", outDir)
        guard doc.write(to: out) else { throw ConvertError.writeFailed(out) }
        return out
    }

    public static func pdfToImages(_ pdf: URL, format: ImageFormat = .png, dpi: Int = 150, outDir: URL? = nil) throws -> [URL] {
        guard let doc = PDFDocument(url: pdf), doc.pageCount > 0 else { throw ConvertError.unreadable(pdf) }
        if doc.isLocked { throw ConvertError.unsupported("\(pdf.lastPathComponent) is password protected") }
        let scale = CGFloat(dpi) / 72
        var outputs: [URL] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            var size = page.bounds(for: .mediaBox).size
            if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConvertError.unreadable(pdf) }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            guard let image = ctx.makeImage() else { throw ConvertError.unreadable(pdf) }
            let out = target(pdf, String(format: "-p%02d", index + 1), format.rawValue, outDir)
            try write(image, to: out, format: format, quality: 0.9)
            outputs.append(out)
        }
        return outputs
    }

    /// Scales so the longer side is at most `maxDimension` (nil keeps size) and re-encodes. Honours EXIF rotation.
    public static func resizeImage(_ input: URL, maxDimension: Int?, format: ImageFormat? = nil, quality: Double = 0.8, outDir: URL? = nil) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int else { throw ConvertError.unreadable(input) }
        let longest = max(pw, ph)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(maxDimension ?? longest, longest)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ConvertError.unreadable(input) }
        let ext = input.pathExtension.lowercased()
        let outFormat = format ?? (ext == "png" ? .png : ext == "heic" ? .heic : .jpg)
        let out = target(input, "-resized", outFormat.rawValue, outDir)
        try write(image, to: out, format: outFormat, quality: quality)
        return out
    }

    /// Recompresses the images inside a PDF. Text stays text. Throws `.notSmaller` if nothing was gained.
    public static func shrinkPDF(_ pdf: URL, level: PDFShrink = .balanced, outDir: URL? = nil) throws -> URL {
        guard let doc = PDFDocument(url: pdf), doc.pageCount > 0 else { throw ConvertError.unreadable(pdf) }
        if doc.isLocked { throw ConvertError.unsupported("\(pdf.lastPathComponent) is password protected") }
        var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if level == .smallest { options[.optimizeImagesForScreenOption] = true }
        let out = target(pdf, "-small", "pdf", outDir)
        guard doc.write(to: out, withOptions: options) else { throw ConvertError.writeFailed(out) }
        let before = (try? pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before { try? FileManager.default.removeItem(at: out); throw ConvertError.notSmaller }
        return out
    }

    public static let videoPresets: [(name: String, preset: String)] = [
        ("HEVC 1080p (smallest)", AVAssetExportPresetHEVC1920x1080),
        ("H.264 1080p", AVAssetExportPreset1920x1080),
        ("H.264 720p", AVAssetExportPreset1280x720),
        ("H.264 540p", AVAssetExportPreset960x540),
    ]

    /// Re-encodes to MP4. Reads what AVFoundation reads (MOV, MP4, M4V); not MKV, WebM or AVI.
    public static func convertVideo(_ input: URL, preset: String = AVAssetExportPresetHEVC1920x1080, outDir: URL? = nil) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard (try? await asset.load(.isExportable)) == true, let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.unsupported("\(input.lastPathComponent) is not a video this Mac can convert (MOV, MP4 and M4V work)")
        }
        session.shouldOptimizeForNetworkUse = true
        let out = target(input, "-converted", "mp4", outDir)
        do { try await session.export(to: out, as: .mp4) }
        catch { try? FileManager.default.removeItem(at: out); throw error }
        return out
    }
}
