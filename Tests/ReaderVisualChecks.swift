#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit

/// Captures our own AppKit views for visual review. This does not replace the
/// separate full-window PDF compositor or hardware-input acceptance checks.
@MainActor enum ReaderVisualChecks {
    static func run(root: URL, output: URL) async throws {
        let oldMode = AppearancePreferences.mode, oldStrategy = AppearancePreferences.strategy
        let document = PDFReaderDocument()
        defer {
            document.updateChangeCount(.changeCleared); document.close()
            AppearancePreferences.mode = oldMode; AppearancePreferences.strategy = oldStrategy
        }
        let source = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
        try document.read(from: source, ofType: "com.adobe.pdf")
        document.fileURL = source
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        let controller = document.windowControllers[0] as! ReaderWindowController
        let window = controller.window!
        var cases: [[String: Any]] = []
        func capture(_ name: String) throws -> Int32 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            if let content = window.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds,to: bitmap)
                try bitmap.representation(using: .png,properties: [:])!.write(to: output.appendingPathComponent("reader-\(name)-appkit.png"))
            }
            return try WindowCaptureChecks.capture(window,to: output.appendingPathComponent("reader-\(name)-window.png"))
        }
        for (name, mode, size) in [("light", ThemeMode.light, NSSize(width: 1180,height: 820)),
                                   ("dark", .dark, NSSize(width: 1180,height: 820)),
                                   ("compact", .dark, NSSize(width: 820,height: 650))] {
            AppearancePreferences.selectReadingTheme(mode)
            window.setContentSize(size)
            controller.actualSize(nil)
            controller.pdfView.go(to: document.pdf!.page(at: 0)!)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
            let deadline = Date().addingTimeInterval(15)
            while (controller.pdfView.imagePreservingRenderer?.isPreparing == true || controller.thumbnails.image(forPage: 0) == nil) && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            let result = try capture(name)
            let visible = window.toolbar?.visibleItems?.map { $0.itemIdentifier.rawValue } ?? []
            try IntegrationChecks.require(Set(["sidebar","page","theme","search"]).isSubset(of: Set(visible)),
                                          "Reader \(name): core toolbar controls remain visible")
            cases.append(["name": name, "screen_capture_exit": result,
                          "visible_toolbar": visible,
                          "content_size": [size.width,size.height]])
        }
        window.setContentSize(NSSize(width: 1180,height: 820))
        controller.actualSize(nil)
        controller.focusSearch(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try capture("search-empty")
        controller.searchField.stringValue = "AdaptivePDF"
        controller.searchNow(nil)
        while document.pdf!.isFinding { try await Task.sleep(nanoseconds: 50_000_000) }
        controller.nextMatch(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try capture("search")
        let page = document.pdf!.page(at: 0)!
        let range = (page.string! as NSString).range(of: "First selected line")
        controller.pdfView.setCurrentSelection(page.selection(for: range),animate: false)
        controller.highlightSelection(nil)
        if let mark = page.annotations.first(where: { $0.type == "Highlight" }) {
            controller.changeContents(mark,text: "记录这一段的关键思路。")
            controller.selectAnnotation(mark)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try capture("notes")
        document.updateChangeCount(.changeCleared); document.close()
        if let delegate = NSApp.delegate as? AppDelegate {
            _ = delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows: false)
            for mode in [ThemeMode.light,.dark] {
                AppearancePreferences.selectReadingTheme(mode)
                try await Task.sleep(nanoseconds: 200_000_000)
                if let welcome = NSApp.windows.first(where: { $0.title == "AdaptivePDF" && $0.windowController == nil }) {
                    NSApp.activate(ignoringOtherApps: true)
                    welcome.makeKeyAndOrderFront(nil)
                    _ = try WindowCaptureChecks.capture(welcome,to: output.appendingPathComponent("welcome-\(mode.rawValue)-window.png"))
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["cases": cases,"app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"], options: [.prettyPrinted,.sortedKeys])
            .write(to: output.appendingPathComponent("reader-visual.json"))
    }
}
#endif
