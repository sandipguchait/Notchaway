import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TopBarStyle: String, CaseIterable, Identifiable {
    case matchWallpaper
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchWallpaper: return "Match wallpaper"
        case .black: return "Black"
        }
    }
}

struct WallpaperProcessor {
    private let workspace = NSWorkspace.shared
    private let fileManager = FileManager.default

    func applyTopBar(to screen: NSScreen, heightInPoints: CGFloat, style: TopBarStyle) throws {
        guard let displayID = screen.displayID else { throw WallpaperError.missingDisplayID }

        let original = try originalWallpaperRecord(for: screen, displayID: displayID)
        let sourceURL = original.url

        let pixelWidth = Int(CGDisplayPixelsWide(displayID))
        let pixelHeight = Int(CGDisplayPixelsHigh(displayID))
        guard pixelWidth > 0, pixelHeight > 0 else { throw WallpaperError.invalidDisplaySize }

        let pointsToPixels = CGFloat(pixelHeight) / max(screen.frame.height, 1)
        let barPixels = min(CGFloat(pixelHeight), max(1, heightInPoints * pointsToPixels))

        let sourceCG = try loadCGImage(from: sourceURL)
        let output = try renderedWallpaper(
            source: sourceCG,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            topBarHeight: barPixels,
            style: style
        )

        let destination = try outputURL(for: displayID)
        try output.write(to: destination, options: .atomic)

        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
            .allowClipping: NSNumber(value: false),
            .fillColor: NSColor.black
        ]

        try workspace.setDesktopImageURL(destination, for: screen, options: options)
    }

    func restoreAllBuiltInDisplays() throws {
        for screen in NSScreen.screens where screen.isBuiltIn {
            guard let displayID = screen.displayID,
                  let record = loadRecord(for: displayID) else { continue }

            let options = decodedOptions(from: record.optionsData) ?? workspace.desktopImageOptions(for: screen) ?? [:]
            try workspace.setDesktopImageURL(record.url, for: screen, options: options)
            removeRecord(for: displayID)
        }
    }

    private func originalWallpaperRecord(for screen: NSScreen, displayID: CGDirectDisplayID) throws -> WallpaperRecord {
        if let stored = loadRecord(for: displayID), fileManager.fileExists(atPath: stored.url.path) {
            return stored
        }

        guard let currentURL = workspace.desktopImageURL(for: screen) else {
            throw WallpaperError.missingWallpaper
        }

        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let optionsData = try? NSKeyedArchiver.archivedData(withRootObject: options, requiringSecureCoding: false)
        let record = WallpaperRecord(url: currentURL, optionsData: optionsData)
        saveRecord(record, for: displayID)
        return record
    }

    private func loadCGImage(from url: URL) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }

        guard let image = NSImage(contentsOf: url) else {
            throw WallpaperError.cannotReadWallpaper
        }
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return cgImage
        }
        throw WallpaperError.cannotReadWallpaper
    }

    private func renderedWallpaper(source: CGImage,
                                   pixelWidth: Int,
                                   pixelHeight: Int,
                                   topBarHeight: CGFloat,
                                   style: TopBarStyle) throws -> Data {
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WallpaperError.cannotEncodeWallpaper
        }

        context.interpolationQuality = .high
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let sourceSize = CGSize(width: source.width, height: source.height)
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            throw WallpaperError.cannotReadWallpaper
        }

        // Fill the entire display while preserving aspect ratio, then center-crop.
        let scale = max(width / sourceSize.width, height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = CGRect(
            x: (width - drawSize.width) / 2,
            y: (height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.draw(source, in: drawRect)

        let bar = min(height, max(1, topBarHeight))
        switch style {
        case .black:
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: height - bar, width: width, height: bar))
        case .matchWallpaper:
            extendWallpaperColor(in: context, barRows: Int(bar.rounded(.up)))
        }

        guard let rendered = context.makeImage() else {
            throw WallpaperError.cannotEncodeWallpaper
        }
        return try pngData(from: rendered)
    }

    /// Fills the top `barRows` with colors sampled just below the bar, then fades back into the wallpaper.
    /// Expects an 8-bit RGBA bitmap context, whose memory rows run top to bottom.
    private func extendWallpaperColor(in context: CGContext, barRows requestedRows: Int) {
        guard let data = context.data else { return }
        let width = context.width
        let height = context.height
        let bytesPerRow = context.bytesPerRow
        guard width > 0, height > 1 else { return }

        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        let barRows = min(max(requestedRows, 1), height - 1)
        let sampleRows = min(height - barRows, max(8, barRows / 2))

        var columnSums = [Double](repeating: 0, count: width * 3)
        for row in barRows..<(barRows + sampleRows) {
            let base = row * bytesPerRow
            for x in 0..<width {
                let p = base + x * 4
                columnSums[x * 3] += Double(pixels[p])
                columnSums[x * 3 + 1] += Double(pixels[p + 1])
                columnSums[x * 3 + 2] += Double(pixels[p + 2])
            }
        }

        // Horizontal box blur so wallpaper detail doesn't turn into vertical streaks.
        var prefix = [Double](repeating: 0, count: (width + 1) * 3)
        for x in 0..<width {
            for c in 0..<3 {
                prefix[(x + 1) * 3 + c] = prefix[x * 3 + c] + columnSums[x * 3 + c]
            }
        }

        let radius = max(1, width / 80)
        var colors = [Double](repeating: 0, count: width * 3)
        for x in 0..<width {
            let lo = max(0, x - radius)
            let hi = min(width, x + radius + 1)
            let count = Double((hi - lo) * sampleRows)
            for c in 0..<3 {
                colors[x * 3 + c] = (prefix[hi * 3 + c] - prefix[lo * 3 + c]) / count
            }
        }

        for row in 0..<barRows {
            let base = row * bytesPerRow
            for x in 0..<width {
                let p = base + x * 4
                pixels[p] = UInt8(clamping: Int(colors[x * 3].rounded()))
                pixels[p + 1] = UInt8(clamping: Int(colors[x * 3 + 1].rounded()))
                pixels[p + 2] = UInt8(clamping: Int(colors[x * 3 + 2].rounded()))
                pixels[p + 3] = 255
            }
        }

        let blendRows = min(height - barRows, max(8, barRows))
        for i in 0..<blendRows {
            let t = Double(i + 1) / Double(blendRows + 1)
            let barWeight = 1 - t * t * (3 - 2 * t)
            let base = (barRows + i) * bytesPerRow
            for x in 0..<width {
                let p = base + x * 4
                for c in 0..<3 {
                    let original = Double(pixels[p + c])
                    let blended = colors[x * 3 + c] * barWeight + original * (1 - barWeight)
                    pixels[p + c] = UInt8(clamping: Int(blended.rounded()))
                }
            }
        }
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WallpaperError.cannotEncodeWallpaper
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw WallpaperError.cannotEncodeWallpaper
        }
        return data as Data
    }

    private func outputURL(for displayID: CGDirectDisplayID) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("NotchAway", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("display-\(displayID).png")
    }

    private func recordKey(for displayID: CGDirectDisplayID) -> String {
        "notchAway.originalWallpaper.\(displayID)"
    }

    private func saveRecord(_ record: WallpaperRecord, for displayID: CGDirectDisplayID) {
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: recordKey(for: displayID))
        }
    }

    private func loadRecord(for displayID: CGDirectDisplayID) -> WallpaperRecord? {
        guard let data = UserDefaults.standard.data(forKey: recordKey(for: displayID)) else { return nil }
        return try? JSONDecoder().decode(WallpaperRecord.self, from: data)
    }

    private func removeRecord(for displayID: CGDirectDisplayID) {
        UserDefaults.standard.removeObject(forKey: recordKey(for: displayID))
    }

    private func decodedOptions(from data: Data?) -> [NSWorkspace.DesktopImageOptionKey: Any]? {
        guard let data else { return nil }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [NSWorkspace.DesktopImageOptionKey: Any]
    }
}

private struct WallpaperRecord: Codable {
    let url: URL
    let optionsData: Data?
}

enum WallpaperError: LocalizedError {
    case missingDisplayID
    case missingWallpaper
    case cannotReadWallpaper
    case invalidDisplaySize
    case cannotEncodeWallpaper

    var errorDescription: String? {
        switch self {
        case .missingDisplayID: return "Display identifier is unavailable."
        case .missingWallpaper: return "The current desktop wallpaper could not be found."
        case .cannotReadWallpaper: return "The current wallpaper image could not be read."
        case .invalidDisplaySize: return "The display resolution is invalid."
        case .cannotEncodeWallpaper: return "The processed wallpaper could not be created."
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    var isBuiltIn: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}
