import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Periodically screenshots every display, skipping duplicates, and hands images to OCR.
final class ScreenCapture {
    private var timer: Timer?
    private var capturing = false
    private var lastHash: [CGDirectDisplayID: UInt64] = [:]
    private var loggedPermissionError = false
    private let ioQueue = DispatchQueue(label: "slock.shots", qos: .utility)
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func start() {
        let interval = max(2, State.shared.config.screenshotIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        let state = State.shared
        guard !capturing, !state.suspended, !state.idle, !state.frontExcluded else { return }
        // Calling ScreenCaptureKit without permission can re-trigger the system prompt; don't.
        guard Permissions.screenRecording else { return }
        capturing = true
        // Snapshot foreground context on the main thread before going async.
        let ctx = (app: state.frontApp, title: state.frontTitle, url: state.frontURL,
                   pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        Task {
            await self.captureAll(ctx)
            await MainActor.run { self.capturing = false }
        }
    }

    private func captureAll(_ ctx: (app: String?, title: String?, url: String?, pid: pid_t?)) async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !loggedPermissionError {
                log("screen capture unavailable (grant Screen Recording permission): \(error)")
                loggedPermissionError = true
            }
            return
        }
        loggedPermissionError = false

        let cfg = State.shared.config
        let excludedIds = Set(cfg.excludedBundleIds + [Bundle.main.bundleIdentifier ?? "dev.slock.agent"])
        let excludedApps = content.applications.filter { excludedIds.contains($0.bundleIdentifier) }

        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let sc = SCStreamConfiguration()
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            sc.width = mode?.pixelWidth ?? display.width * 2
            sc.height = mode?.pixelHeight ?? display.height * 2
            sc.showsCursor = false
            sc.captureResolution = .best

            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: sc) else {
                continue
            }
            guard let hash = ImageHash.dHash(image) else { continue }
            if let prev = lastHash[display.displayID],
               (prev ^ hash).nonzeroBitCount <= cfg.duplicateHashDistance {
                continue
            }
            lastHash[display.displayID] = hash
            save(image: image, displayId: display.displayID, hash: hash, ctx: ctx,
                 win: ctx.pid.flatMap { frontWindow(pid: $0, display: display.displayID) }, cfg: cfg)
        }
    }

    /// The front app's frontmost window on this display, as "x,y,w,h" fractions of the display (top-left origin).
    /// Lets the dashboard re-read just that window later, e.g. to tell which side of a chat a message is on.
    private func frontWindow(pid: pid_t, display: CGDirectDisplayID) -> String? {
        let screen = CGDisplayBounds(display)
        guard screen.width > 0, screen.height > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // The list is ordered front to back.
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b)?.intersection(screen),
                  rect.width > 100, rect.height > 100 else { continue }
            let x = (rect.minX - screen.minX) / screen.width, y = (rect.minY - screen.minY) / screen.height
            return String(format: "%.4f,%.4f,%.4f,%.4f", x, y, rect.width / screen.width, rect.height / screen.height)
        }
        return nil
    }

    private func save(image: CGImage, displayId: CGDirectDisplayID, hash: UInt64,
                      ctx: (app: String?, title: String?, url: String?, pid: pid_t?), win: String?, cfg: Config) {
        ioQueue.async {
            let now = Date()
            let day = self.dayFormatter.string(from: now)
            let dir = Paths.shots.appendingPathComponent(day)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rel = "\(day)/\(Int(now.timeIntervalSince1970 * 1000))-\(displayId).jpg"
            let url = Paths.shots.appendingPathComponent(rel)

            let scaled = ImageHash.downscale(image, maxWidth: cfg.screenshotMaxWidth) ?? image
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: cfg.jpegQuality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }

            let id = Database.shared.run(
                "INSERT INTO screenshots(ts, path, display_id, app, window_title, url, phash, win) VALUES(?,?,?,?,?,?,?,?)",
                [now.timeIntervalSince1970, rel, displayId, ctx.app, ctx.title, ctx.url, hash, win]
            )
            if cfg.ocrEnabled {
                OCR.shared.enqueue(image: image, screenshotId: id)
            }
        }
    }
}

enum ImageHash {
    /// 64-bit difference hash: robust to compression noise, changes when on-screen content changes.
    static func dHash(_ image: CGImage) -> UInt64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let w = maxWidth, h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
