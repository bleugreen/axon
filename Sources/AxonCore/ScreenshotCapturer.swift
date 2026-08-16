import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

public struct ScreenshotCapturer {
    /// Public observations are bounded to keep the image token-comparable with the AX tree.
    public static let defaultMaxEncodedDimension = 1280

    private let timeoutSeconds: TimeInterval
    private let maxEncodedDimension: Int

    public init(
        timeoutSeconds: TimeInterval = 5.0,
        maxEncodedDimension: Int = Self.defaultMaxEncodedDimension
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.maxEncodedDimension = max(1, maxEncodedDimension)
    }

    public func capture(app: AppIdentity, axWindows: [AXNode] = []) -> EncodedScreenshot? {
        ScreenCaptureRuntime.bootstrapSynchronously()
        guard let window = matchingWindow(for: app, axWindows: axWindows) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1.0, Double(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 1
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true

        guard let image = captureImage(filter: filter, configuration: configuration) else {
            return nil
        }

        // The frame of the window that was actually photographed, not of whichever window another
        // selection would have picked. Everything downstream that converts an image coordinate to a
        // screen coordinate converts through this.
        return encode(
            scaledImage(image, maxDimension: maxEncodedDimension) ?? image,
            sourceWindowFrame: window.frame.axFrame
        )
    }

    private func matchingWindow(for app: AppIdentity, axWindows: [AXNode]) -> SCWindow? {
        guard let content = shareableContent() else {
            return nil
        }

        let appWindows = content.windows.filter { window in
            window.owningApplication?.processID == app.processIdentifier
        }

        if let matched = bestMatch(in: appWindows, axWindows: axWindows) {
            return matched
        }

        return appWindows.first { $0.isOnScreen || $0.isActive } ?? appWindows.first
    }

    private func bestMatch(in windows: [SCWindow], axWindows: [AXNode]) -> SCWindow? {
        for axWindow in axWindows {
            if let title = axWindow.title, !title.isEmpty,
               let match = windows.first(where: { $0.title == title }) {
                return match
            }

            if let frame = axWindow.frame,
               let match = windows.first(where: { $0.frame.axFrame.isClose(to: frame) }) {
                return match
            }
        }
        return nil
    }

    private func shareableContent() -> SCShareableContent? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = AsyncResult<SCShareableContent>()

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            result.set(content)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            return nil
        }
        return result.get()
    }

    private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = AsyncResult<CGImage>()

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
            result.set(image)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            return nil
        }
        return result.get()
    }

    private func encode(_ image: CGImage, sourceWindowFrame: AXFrame) -> EncodedScreenshot? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return EncodedScreenshot(
            mediaType: "image/png",
            base64Data: (data as Data).base64EncodedString(),
            width: image.width,
            height: image.height,
            sourceWindowFrame: sourceWindowFrame
        )
    }

    private func scaledImage(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let targetSize = Self.targetPixelSize(
            width: image.width,
            height: image.height,
            maxDimension: maxDimension
        )
        guard targetSize.width != image.width || targetSize.height != image.height else {
            return image
        }

        guard let context = CGContext(
            data: nil,
            width: targetSize.width,
            height: targetSize.height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height))
        return context.makeImage()
    }

    static func targetPixelSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let maxSourceDimension = max(width, height)
        guard maxSourceDimension > maxDimension else {
            return (width, height)
        }

        let scale = Double(maxDimension) / Double(maxSourceDimension)
        return (
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }
}

private final class AsyncResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public enum ScreenCaptureRuntime {
    private static let state = ScreenCaptureRuntimeState()

    public static func bootstrapSynchronously() {
        if state.isBootstrapped {
            return
        }

        // Never wait on the main queue from a daemon worker; the main thread is in accept().
        guard Thread.isMainThread else {
            return
        }

        MainActor.assumeIsolated {
            MainActorScreenCaptureRuntime.bootstrap()
        }

        state.markBootstrapped()
    }
}

@MainActor private enum MainActorScreenCaptureRuntime {
    private static let didBootstrap: Void = {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
    }()

    static func bootstrap() {
        _ = didBootstrap
    }
}

private final class ScreenCaptureRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didBootstrap = false

    var isBootstrapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBootstrap
    }

    func markBootstrapped() {
        lock.lock()
        didBootstrap = true
        lock.unlock()
    }
}

extension CGRect {
    /// The same rectangle in the vocabulary the rest of the module compares in. Capture and
    /// Accessibility report window geometry in one coordinate space, and this is where that is
    /// asserted once rather than at each comparison.
    var axFrame: AXFrame {
        AXFrame(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }
}
