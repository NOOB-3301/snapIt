import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import SnapItCore

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapit-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func bitmap(_ w: Int, _ h: Int, noisy: Bool = false) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in 0..<(w * h) {
        p[i * 4] = noisy ? UInt8.random(in: 0...255) : UInt8(i % 256)
        p[i * 4 + 1] = noisy ? UInt8.random(in: 0...255) : 120
        p[i * 4 + 2] = noisy ? UInt8.random(in: 0...255) : 60
        p[i * 4 + 3] = 255
    }
    return ctx
}

private func writePNG(_ w: Int, _ h: Int, to url: URL, noisy: Bool = false) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, bitmap(w, h, noisy: noisy).makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func pixelSize(_ url: URL) -> (Int, Int) {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    return (image.width, image.height)
}

@Test func freeURLNeverCollides() throws {
    let dir = tempDir()
    let first = Convert.freeURL(dir: dir, name: "a", ext: "txt")
    try Data().write(to: first)
    let second = Convert.freeURL(dir: dir, name: "a", ext: "txt")
    try Data().write(to: second)
    #expect(first.lastPathComponent == "a.txt")
    #expect(second.lastPathComponent == "a-2.txt")
    #expect(Convert.freeURL(dir: dir, name: "a", ext: "txt").lastPathComponent == "a-3.txt")
}

@Test func resizeKeepsOriginalAndScales() throws {
    let dir = tempDir(), input = dir.appendingPathComponent("photo.png")
    writePNG(800, 600, to: input)
    let before = try Data(contentsOf: input)
    let out = try Convert.resizeImage(input, maxDimension: 200, format: .jpg)
    #expect(out.lastPathComponent == "photo-resized.jpg")
    #expect(pixelSize(out) == (200, 150))
    #expect(try Data(contentsOf: input) == before)
    // Never upscales, and a second run does not overwrite the first.
    let again = try Convert.resizeImage(input, maxDimension: 5000, format: .jpg)
    #expect(again.lastPathComponent == "photo-resized-2.jpg")
    #expect(pixelSize(again) == (800, 600))
    let heic = try Convert.resizeImage(input, maxDimension: 100, format: .heic)
    #expect(pixelSize(heic) == (100, 75))
}

@Test func imagesToPDFAndBack() throws {
    let dir = tempDir(), a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
    writePNG(400, 300, to: a)
    writePNG(300, 600, to: b)
    let pdf = try Convert.imagesToPDF([a, b])
    let doc = try #require(PDFDocument(url: pdf))
    #expect(doc.pageCount == 2)
    let firstPage = doc.page(at: 0)!.bounds(for: .mediaBox).size
    #expect(abs(firstPage.width / firstPage.height - 400.0 / 300.0) < 0.01)
    #expect(firstPage.width <= 842.5 && firstPage.height <= 842.5)

    let images = try Convert.pdfToImages(pdf, format: .jpg, dpi: 72)
    #expect(images.map(\.lastPathComponent) == ["a-p01.jpg", "a-p02.jpg"])
    let (w, h) = pixelSize(images[0])
    #expect(abs(Double(w) - Double(firstPage.width)) <= 1 && abs(Double(h) - Double(firstPage.height)) <= 1)
}

@Test func shrinkPDFIsSmallerOrRefuses() throws {
    let dir = tempDir(), image = dir.appendingPathComponent("noise.png")
    writePNG(1200, 1200, to: image, noisy: true)
    // A PDF holding a losslessly stored noisy image: JPEG recompression must win.
    let pdf = dir.appendingPathComponent("big.pdf")
    var box = CGRect(x: 0, y: 0, width: 600, height: 600)
    let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.draw(bitmap(1200, 1200, noisy: true).makeImage()!, in: box)
    ctx.endPDFPage()
    ctx.closePDF()
    let before = try Data(contentsOf: pdf)
    let out = try Convert.shrinkPDF(pdf, level: .smallest)
    #expect(PDFDocument(url: out)?.pageCount == 1)
    #expect(try Data(contentsOf: out).count < before.count)
    #expect(try Data(contentsOf: pdf) == before)
    // Shrinking the already-shrunk file must not leave a useless copy behind.
    #expect(throws: ConvertError.self) { try Convert.shrinkPDF(out, level: .balanced) }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("big-small-small.pdf").path))
}

@Test func videoConvertsToMP4() async throws {
    let dir = tempDir(), input = dir.appendingPathComponent("clip.mov")
    let writer = try AVAssetWriter(outputURL: input, fileType: .mov)
    let track = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
    writer.add(track)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<15 {
        while !track.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 16), CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        #expect(adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 15)))
    }
    track.markAsFinished()
    await writer.finishWriting()
    let before = try Data(contentsOf: input)

    let out = try await Convert.convertVideo(input, preset: AVAssetExportPreset960x540)
    #expect(out.lastPathComponent == "clip-converted.mp4")
    let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
    #expect(tracks.count == 1)
    #expect(try Data(contentsOf: input) == before)

    let notVideo = dir.appendingPathComponent("fake.mkv")
    try Data("nope".utf8).write(to: notVideo)
    await #expect(throws: ConvertError.self) { try await Convert.convertVideo(notVideo) }
}

@Test func keyerRemovesMagentaOnly() throws {
    let ctx = bitmap(4, 2)
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 32)
    let colours: [[UInt8]] = [[255, 0, 255], [253, 6, 245], [43, 58, 103], [255, 243, 220], [255, 107, 94], [31, 111, 120], [255, 255, 255], [0, 0, 0]]
    for (i, c) in colours.enumerated() { p[i * 4] = c[0]; p[i * 4 + 1] = c[1]; p[i * 4 + 2] = c[2]; p[i * 4 + 3] = 255 }
    let keyed = try #require(Sprites.keyed(ctx.makeImage()!))
    let out = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.draw(keyed, in: CGRect(x: 0, y: 0, width: 4, height: 2))
    let q = out.data!.bindMemory(to: UInt8.self, capacity: 32)
    let alphas = (0..<8).map { q[$0 * 4 + 3] }
    #expect(alphas[0] == 0 && alphas[1] == 0)            // pure and near magenta vanish
    #expect(alphas[2...].allSatisfy { $0 == 255 })       // hair, hoodie, ribbon, shorts, white, black stay
    #expect(Sprites.frames(of: keyed).count == 4)
}

@Test func parsesEngineStream() {
    #expect(parseEngineLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#) == .text("Hi"))
    #expect(parseEngineLine(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"WebSearch"}}}"#) == .status("Searching the web…"))
    #expect(parseEngineLine(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#) == .newBlock)
    #expect(parseEngineLine(#"{"type":"result","is_error":false,"result":"ok"}"#) == .done)
    #expect(parseEngineLine(#"{"type":"result","is_error":true,"result":"Please run /login"}"#) == .failed("Please run /login"))
    #expect(parseEngineLine(#"{"type":"system","subtype":"init"}"#) == nil)
    #expect(parseEngineLine("not json") == nil)
}

@Test func usageLogReadsRealLogLines() throws {
    let since = try #require(ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z"))
    func line(_ stamp: String, id: String = "msg_a", type: String = "assistant", usage: String = #"{"input_tokens":2,"output_tokens":173,"cache_creation_input_tokens":7868,"cache_read_input_tokens":27743}"#) -> String {
        #"{"type":"\#(type)","timestamp":"\#(stamp)","message":{"id":"\#(id)","usage":\#(usage)}}"#
    }
    // Claude Code writes fractional seconds, which the default ISO8601 formatter rejects.
    let hit = try #require(UsageLog.tokens(line("2026-11-10T09:53:27.162Z"), since: since))
    #expect(hit.id == "msg_a")
    #expect(hit.tokens == 2 + 173 + 7868)          // cache reads are excluded
    #expect(UsageLog.tokens(line("2026-11-10T09:53:27Z"), since: since)?.tokens == hit.tokens)

    // One message is logged once per content block: the id is what stops the double count.
    let blocks = [line("2026-11-10T09:53:27.162Z"), line("2026-11-10T09:53:28.001Z"), line("2026-11-10T09:53:29Z", id: "msg_b")]
    var seen: Set<String> = [], total = 0
    for block in blocks {
        guard let hit = UsageLog.tokens(block, since: since), seen.insert(hit.id).inserted else { continue }
        total += hit.tokens
    }
    #expect(seen.count == 2)
    #expect(total == hit.tokens * 2)

    #expect(UsageLog.tokens(line("2026-11-09T23:59:59.999Z"), since: since) == nil)
    #expect(UsageLog.tokens(line("2026-11-10T09:53:27.162Z", type: "user"), since: since) == nil)
    #expect(UsageLog.tokens(line("2026-11-10T09:53:27.162Z", usage: #"{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":900}"#), since: since) == nil)
    #expect(UsageLog.tokens(line("not-a-date"), since: since) == nil)
    #expect(UsageLog.tokens(#"{"type":"assistant","message":{"usage":{"output_tokens":5}}}"#, since: since) == nil)
    #expect(UsageLog.tokens("not json", since: since) == nil)
    #expect(UsageLog.tokens("", since: since) == nil)
}

/// Talks to the real Claude Code CLI, so it only runs on request: SNAPIT_LIVE=1 ./test.sh
@Test(.enabled(if: ProcessInfo.processInfo.environment["SNAPIT_LIVE"] == "1"))
func liveEngineAnswersAboutAnImageAndRemembers() async throws {
    let cli = try #require(ClaudeSession.findCLI())
    let session = try ClaudeSession(cli: cli, model: "", systemPrompt: "Answer in one short sentence.")
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    let ctx = bitmap(64, 64)
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)

    func ask(_ text: String, image: Data?) async -> (String, EngineEvent) {
        await withCheckedContinuation { done in
            var answer = ""
            session.send(text: text, imagePNG: image) { event in
                switch event {
                case .text(let delta): answer += delta
                case .done, .failed: done.resume(returning: (answer, event))
                default: break
                }
            }
        }
    }
    let first = await ask("What single colour fills this image? One word.", image: png as Data)
    #expect(first.1 == .done)
    #expect(first.0.lowercased().contains("red"))
    let second = await ask("Repeat the colour you just named, in capitals.", image: nil)
    #expect(second.0.contains("RED"))
    session.cancel()
}
