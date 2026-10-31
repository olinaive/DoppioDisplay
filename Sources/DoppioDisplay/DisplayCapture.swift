import CoreMedia
import CoreVideo
@preconcurrency import IOSurface
import QuartzCore
@preconcurrency import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotShareable(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .displayNotShareable(let id):
            return "ScreenCaptureKit does not list display \(id). Check Screen Recording permission."
        }
    }
}

/// What to stream: a whole display, or a filter picked in the system content picker (a window).
enum CaptureTarget {
    case display(CGDirectDisplayID)
    case filter(SCContentFilter)
}

/// Lets an IOSurface cross from the capture queue to the main queue.
/// The surface is only handed over, never touched concurrently.
private struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurfaceRef
}

/// Streams a display or window into a CALayer through ScreenCaptureKit.
/// Crop and frame rate can change while streaming.
/// State lives on the main actor; ScreenCaptureKit callbacks arrive on other
/// queues and hop to the main actor before touching it.
@MainActor
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let layer: CALayer
    private nonisolated let queue = DispatchQueue(label: "doppio.capture", qos: .userInteractive)
    private var stream: SCStream?
    /// Bumped by `stop()`; a `start()` that was still awaiting sees the change and tears its stream down.
    private var generation = 0
    private var configuration = SCStreamConfiguration()
    /// Content size in points and its point-to-pixel scale, known after `start`.
    private(set) var contentSize = CGSize.zero
    private var pixelScale: CGFloat = 1
    /// Output width cap in pixels; follows the preview window so frames are not larger than shown.
    private var maxWidth = 2560

    /// Normalized (0...1, top-left origin) part of the content to show; nil = everything.
    private(set) var crop: CGRect?
    private(set) var framesPerSecond = 60

    var onStop: ((Error?) -> Void)?
    /// Called on the main queue with every new frame.
    var onFrame: ((IOSurface) -> Void)?

    init(layer: CALayer) {
        self.layer = layer
    }

    func start(_ target: CaptureTarget) async throws {
        guard stream == nil else { return }
        let startedGeneration = generation
        let filter: SCContentFilter
        switch target {
        case .display(let displayID):
            let display = try await Self.shareableDisplay(id: displayID)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            // Leave our own windows out so the preview never captures itself.
            let ownApps = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        case .filter(let picked):
            filter = picked
        }
        contentSize = filter.contentRect.size
        pixelScale = CGFloat(filter.pointPixelScale)

        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false
        applyGeometry()

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        // Closed (or restarted) while starting: do not keep a stream nobody owns.
        guard generation == startedGeneration, self.stream == nil else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
    }

    func stop() async {
        generation += 1
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    var isRunning: Bool { stream != nil }

    func setCrop(_ crop: CGRect?) async {
        self.crop = crop
        await reconfigure()
    }

    /// Matches the captured frame size to the pixels actually on screen.
    func setMaxWidth(_ pixels: Int) async {
        let clamped = min(max(pixels, 640), 3840)
        guard abs(clamped - maxWidth) > 32 else { return }
        maxWidth = clamped
        await reconfigure()
    }

    func setFramesPerSecond(_ fps: Int) async {
        framesPerSecond = fps
        await reconfigure()
    }

    private func reconfigure() async {
        applyGeometry()
        try? await stream?.updateConfiguration(configuration)
    }

    private func applyGeometry() {
        let visible = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let source = CGRect(
            x: visible.minX * contentSize.width, y: visible.minY * contentSize.height,
            width: visible.width * contentSize.width, height: visible.height * contentSize.height
        )
        configuration.sourceRect = crop == nil ? .null : source
        let pixels = CGSize(width: source.width * pixelScale, height: source.height * pixelScale)
        let scale = min(1, CGFloat(maxWidth) / max(pixels.width, 1))
        configuration.width = max(Int(pixels.width * scale), 2)
        configuration.height = max(Int(pixels.height * scale), 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
    }

    /// A fresh virtual display can take a moment to appear in ScreenCaptureKit.
    private static func shareableDisplay(id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == id }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CaptureError.displayNotShareable(id)
    }

    // MARK: SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        let box = SurfaceBox(surface: surface)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.present(box.surface) }
        }
    }

    private func present(_ surface: IOSurfaceRef) {
        guard stream != nil else { return }
        layer.contents = surface
        onFrame?(surface)
    }

    // MARK: SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stopped = ObjectIdentifier(stream)
        let message = error as NSError
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.stream, ObjectIdentifier(current) == stopped else { return }
                self.stream = nil
                self.onStop?(message)
            }
        }
    }
}
