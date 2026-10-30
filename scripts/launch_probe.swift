import AppKit
import CoreGraphics
import CryptoKit

// Launch the uninstrumented, packaged app through LaunchServices, just as Finder
// opens a document. Inspect only the newly launched instance's own window data.
guard CommandLine.arguments.count == 4 else {
    fputs("Usage: launch_probe APP PDF REPORT\n", stderr); exit(64)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pdfURL = URL(fileURLWithPath: CommandLine.arguments[2])
let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = false
configuration.addsToRecentItems = false
configuration.promptsUserIfNeeded = false
var instance: NSRunningApplication?
var launchError: Error?
var launched = false
NSWorkspace.shared.open([pdfURL], withApplicationAt: appURL, configuration: configuration) { app, error in
    DispatchQueue.main.async { instance = app; launchError = error; launched = true }
}
func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
let deadline = Date().addingTimeInterval(20)
while !launched && Date() < deadline { pump() }
guard let instance, launchError == nil else {
    fputs("Production launch failed: \(String(describing: launchError))\n", stderr); exit(1)
}
defer {
    if !instance.isTerminated { instance.terminate() }
}
var windowEvidence: [String: Any]?
var stableBounds: [Double]?
var stableSince: Date?
while Date() < deadline && !instance.isTerminated {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let candidate = windows.first {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == instance.processIdentifier &&
        ($0[kCGWindowName as String] as? String) == pdfURL.lastPathComponent
    }
    if let candidate,
       let alpha = candidate[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue >= 0.99,
       let bounds = candidate[kCGWindowBounds as String] as? [String: NSNumber],
       let width = bounds["Width"]?.doubleValue, let height = bounds["Height"]?.doubleValue,
       width >= 820, height >= 540 {
        let value: [Double] = [bounds["X"]?.doubleValue ?? 0.0, bounds["Y"]?.doubleValue ?? 0.0, width, height]
        if stableBounds == value {
            if let stableSince, Date().timeIntervalSince(stableSince) >= 0.3 {
                windowEvidence = candidate
                break
            }
        } else { stableBounds = value; stableSince = Date() }
    } else { stableBounds = nil; stableSince = nil }
    pump()
}
guard let evidence = windowEvidence else {
    instance.terminate()
    fputs("Production app did not show a fully visible, stable reader window within 20 seconds.\n", stderr)
    exit(1)
}
instance.terminate()
let quitDeadline = Date().addingTimeInterval(10)
while !instance.isTerminated && Date() < quitDeadline { pump() }
guard instance.isTerminated else {
    fputs("Fresh unmodified production instance did not quit cleanly.\n", stderr); exit(1)
}
let result: [String: Any] = [
    "schema_version": 1, "status": "passed", "pid": instance.processIdentifier,
    "document": pdfURL.lastPathComponent, "window": evidence,
    "clean_quit": true, "app_name": appURL.lastPathComponent,
    "stable_reader_window": true, "minimum_reader_size": [820, 540], "stable_window_duration_s": 0.3,
    "binary_sha256": SHA256.hash(data: try Data(contentsOf: appURL.appendingPathComponent("Contents/MacOS/AdaptivePDF"))).map { String(format: "%02x", $0) }.joined(),
    "readonly_volume": try appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true,
    "completed_at": ISO8601DateFormatter().string(from: Date())
]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    .write(to: reportURL, options: .atomic)
print("PASS: packaged production app opens PDF through LaunchServices and quits cleanly")
