#if DEBUG || INTEGRATION_TESTS
import AppKit
import CoreGraphics

enum WindowCaptureChecks {
    static func capture(_ window: NSWindow, to url: URL) throws -> Int32 {
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        var since: Date?
        while Date() < deadline {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let visible = windows.contains {
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber &&
                ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 >= 0.99
            }
            if visible {
                if let since, Date().timeIntervalSince(since) > 0.4 { break }
                if since == nil { since = Date() }
            } else { since = nil }
            IntegrationChecks.pump(0.05)
        }
        print("CAPTURE_WINDOW: number=\(window.windowNumber) visible=\(window.isVisible) hidden=\(NSApp.isHidden)")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try capture.run(); capture.waitUntilExit()
        return capture.terminationStatus
    }
}
#endif
