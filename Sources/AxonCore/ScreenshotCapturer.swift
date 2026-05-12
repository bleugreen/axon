import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

public struct ScreenshotCapturer {
    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 5.0) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func capture(app: AppIdentity, axWindows: [AXNode] = []) -> EncodedScreenshot? {
        MainActor.assumeIsolated {
            ScreenCaptureRuntime.bootstrap()
        }
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
        configuration.ignoreShadowsSingleWindow = false

        guard let image = captureImage(filter: filter, configuration: configuration) else {
            return nil
        }

        return encode(image)
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
               let match = windows.first(where: { $0.frame.isClose(to: frame.cgRect) }) {
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

    private func encode(_ image: CGImage) -> EncodedScreenshot? {
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
            height: image.height
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

@MainActor private enum ScreenCaptureRuntime {
    private static let didBootstrap: Void = {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
    }()

    static func bootstrap() {
        _ = didBootstrap
    }
}

private extension AXFrame {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 4.0) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }
}
