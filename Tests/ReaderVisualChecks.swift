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
            let highlight = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "highlight" })?.view as? NSButton
            try IntegrationChecks.require(highlight?.isEnabled == false, "Reader \(name): highlight button waits for a text selection")
            let toolbarHeight = window.frame.height - (window.contentView?.frame.height ?? 0)
            try IntegrationChecks.require(toolbarHeight <= 44, "Reader \(name): title and toolbar occupy at most 44 points")
            cases.append(["name": name, "screen_capture_exit": result,
                          "visible_toolbar": visible,
                          "title_and_toolbar_height": toolbarHeight,
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
        let highlight = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "highlight" })?.view as? NSButton
        try IntegrationChecks.require(highlight?.isEnabled == true, "Selected text enables the native highlight button")
        highlight?.performClick(nil)
        try IntegrationChecks.require(page.annotations.contains(where: { $0.type == "Highlight" }), "Native toolbar button creates a standard PDF highlight")
        if let mark = page.annotations.first(where: { $0.type == "Highlight" }) {
            controller.changeContents(mark,text: "记录这一段的关键思路。")
            controller.selectAnnotation(mark)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try capture("notes")
        let colorButton = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "color" })?.view as? NSButton
        colorButton?.performClick(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        func findButton(in view: NSView, identifier: String) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
            return view.subviews.lazy.compactMap { findButton(in: $0,identifier: identifier) }.first
        }
        let green = NSApp.windows.compactMap { $0.contentView.flatMap { findButton(in: $0,identifier: "highlightColor-1") } }.first
        try IntegrationChecks.require(green?.window?.isVisible == true, "Color button opens the native four-color palette")
        if let paletteWindow = green?.window {
            _ = try WindowCaptureChecks.capture(paletteWindow,to: output.appendingPathComponent("highlight-palette-window.png"))
        }
        let mark = page.annotations.first(where: { $0.type == "Highlight" })!
        green?.performClick(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        let chosen = mark.color.usingColorSpace(.sRGB)!
        try IntegrationChecks.require(chosen.greenComponent > 0.85 && chosen.redComponent < 0.5,
                                      "Palette selection recolors the selected standard PDF highlight")
        document.undoManager?.undo()
        try IntegrationChecks.require(mark.color.usingColorSpace(.sRGB)!.redComponent > 0.95,
                                      "Palette color changes remain undoable")
        document.undoManager?.redo()
        try IntegrationChecks.require(mark.color.usingColorSpace(.sRGB)!.greenComponent > 0.85 && mark.color.usingColorSpace(.sRGB)!.redComponent < 0.5,
                                      "Palette color changes remain redoable")
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
        try JSONSerialization.data(withJSONObject: ["status": "passed","cases": cases,"color_palette_checks": "passed","app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"], options: [.prettyPrinted,.sortedKeys])
            .write(to: output.appendingPathComponent("reader-visual.json"))
    }
}
#endif
