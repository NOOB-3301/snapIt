import CoreGraphics
import Foundation
import ImageIO

public enum Sprites {
    /// Removes a magenta key background, with a soft edge and spill suppression.
    public static func keyed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
            let magenta = min(r, b) - g
            if magenta <= 40 { continue }
            let alpha = magenta >= 110 ? 0 : 255 * (110 - magenta) / 70
            p[i] = UInt8(min(r, g + 40) * alpha / 255)
            p[i + 1] = UInt8(g * alpha / 255)
            p[i + 2] = UInt8(min(b, g + 40) * alpha / 255)
            p[i + 3] = UInt8(alpha)
        }
        return ctx.makeImage()
    }

    /// Splits a 2x2 sheet into frames: top-left, top-right, bottom-left, bottom-right.
    public static func frames(of sheet: CGImage) -> [CGImage] {
        let w = sheet.width / 2, h = sheet.height / 2
        return [(0, 0), (1, 0), (0, 1), (1, 1)].compactMap { sheet.cropping(to: CGRect(x: $0.0 * w, y: $0.1 * h, width: w, height: h)) }
    }

    /// Loads every `<state>.png` in a folder as keyed frames.
    public static func load(directory: URL) -> [String: [CGImage]] {
        var out: [String: [CGImage]] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "png" {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let clean = keyed(image) else { continue }
            let frames = frames(of: clean)
            if frames.count == 4 { out[file.deletingPathExtension().lastPathComponent.lowercased()] = frames }
        }
        return out
    }

    /// Crops all frames to the smallest box that holds the visible pixels of every frame.
    public static func trimmed(_ frames: [CGImage]) -> [CGImage] {
        var box = CGRect.null
        for frame in frames {
            let w = frame.width, h = frame.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = ctx.data else { continue }
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 24 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            } }
        }
        guard !box.isNull else { return frames }
        return frames.compactMap { $0.cropping(to: box) }
    }
}
