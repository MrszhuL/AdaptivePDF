#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit

/// Captures our own AppKit views for visual review. This does not replace the
/// separate full-window PDF compositor or hardware-input acceptance checks.
@MainActor enum ReaderVisualChecks {
    static func run(root: URL, output: URL) async throws {
        let oldMode = AppearancePreferences.mode, oldStrategy = AppearancePreferences.strategy
        let oldCustomColor = AppearancePreferences.customHighlightColor
        let oldWindowSize = AppearancePreferences.readerWindowSize
        let document = PDFReaderDocument()
        defer {
            document.updateChangeCount(.changeCleared); document.close()
            AppearancePreferences.mode = oldMode; AppearancePreferences.strategy = oldStrategy
            AppearancePreferences.customHighlightColor = oldCustomColor
            AppearancePreferences.readerWindowSize = oldWindowSize
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
            controller.pdfView.setManualScale(1)
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
            try IntegrationChecks.require(visible.first == "sidebar" &&
                                          Set(["theme", "search"]).isSubset(of: Set(visible)) &&
                                          !visible.contains("page") && !visible.contains("zoom"),
                                          "Reader \(name): sidebar leads the toolbar and navigation controls stay hidden")
            try IntegrationChecks.require((115...138).contains(controller.searchField.frame.width),
                                          "Reader \(name): the search field stays compact")
            let highlight = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "highlight" })?.view as? NSButton
            try IntegrationChecks.require(highlight?.isEnabled == false, "Reader \(name): highlight button waits for a text selection")
            let toolbarHeight = window.frame.height - window.contentLayoutRect.maxY
            try IntegrationChecks.require(toolbarHeight <= 44, "Reader \(name): title and toolbar occupy at most 44 points")
            cases.append(["name": name, "screen_capture_exit": result,
                          "visible_toolbar": visible,
                          "title_and_toolbar_height": toolbarHeight,
                          "content_size": [size.width,size.height]])
        }
        window.setContentSize(NSSize(width: 1180,height: 820))
        let savedSize = NSSize(width: 880, height: 660)
        window.setContentSize(savedSize)
        try await Task.sleep(nanoseconds: 100_000_000)
        let reopenedDocument = PDFReaderDocument()
        try reopenedDocument.read(from: source, ofType: "com.adobe.pdf")
        let reopened = ReaderWindowController(readerDocument: reopenedDocument, pdf: reopenedDocument.pdf!)
        let restored = reopened.window!.contentRect(forFrameRect: reopened.window!.frame).size
        try IntegrationChecks.require(abs(restored.width - savedSize.width) < 1 && abs(restored.height - savedSize.height) < 1,
                                      "A newly opened reader restores the last resized window size")
        reopened.close()
        window.setContentSize(NSSize(width: 1180,height: 820))
        func descendants(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { descendants($0) }
        }
        guard let hud = descendants(window.contentView).first(where: { $0.identifier?.rawValue == "readerActivityHUD" }),
              let hudLabel = hud.subviews.compactMap({ $0 as? NSTextField }).first else {
            throw IntegrationChecks.Failure(description: "Reader feedback overlay is missing")
        }
        let pdfFrame = controller.pdfView.convert(controller.pdfView.bounds, to: window.contentView)
        try IntegrationChecks.require(hud.isHidden && abs(pdfFrame.minY) < 1,
                                      "An idle reader has no bottom bar or persistent feedback")
        func enterNumber(_ value: String) throws {
            guard let field = NSApp.windows.filter(\.isVisible).flatMap({ descendants($0.contentView) })
                .first(where: { $0.identifier?.rawValue == "readerNumberInput" }) as? NSTextField,
                  let action = field.action else {
                throw IntegrationChecks.Failure(description: "Reader numeric input is not visible")
            }
            if let editor = field.currentEditor() { editor.string = value }
            else { field.stringValue = value }
            NSApp.sendAction(action, to: field.target, from: field)
        }
        controller.focusZoom(nil)
        try enterNumber("900")
        try IntegrationChecks.require(abs(controller.pdfView.scaleFactor - 1) < 0.001, "Out-of-range zoom keeps the current scale")
        try enterNumber("137.5%")
        try IntegrationChecks.require(abs(controller.pdfView.scaleFactor - 1.375) < 0.001, "Zoom input applies a fractional percent")
        try IntegrationChecks.require(!hud.isHidden && hudLabel.stringValue.contains("%"),
                                      "Zooming displays percentage feedback without the page number")
        controller.focusPage(nil)
        try enterNumber("2")
        try IntegrationChecks.require(controller.pdfView.currentPage === document.pdf!.page(at: 1), "Page input jumps to the requested page")
        try await Task.sleep(nanoseconds: 300_000_000)
        try IntegrationChecks.require(hud.isHidden, "Jumping directly to a page does not display the scroll indicator")
        guard let scroll = controller.pdfView.documentView?.enclosingScrollView else {
            throw IntegrationChecks.Failure(description: "Reader scroll view is missing")
        }
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: controller.thumbnails)
        try IntegrationChecks.require(hud.isHidden, "Sidebar scrolling does not show PDF page feedback")
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        let current = controller.pdfView.currentPage.map { document.pdf!.index(for: $0) + 1 } ?? 0
        try IntegrationChecks.require(current > 0 && !hud.isHidden && hudLabel.stringValue == "\(current) / 3 页",
                                      "PDF scrolling displays the current page without the zoom percentage")
        _ = try capture("page-feedback")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        try IntegrationChecks.require(hud.isHidden, "Page feedback disappears automatically after scrolling stops")
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.makeKeyAndOrderFront(nil)
        let view = controller.pdfView
        let point = NSPoint(x: view.visibleRect.midX, y: view.visibleRect.midY)
        let beforeZoom = view.scaleFactor
        let scrolled = view.handleZoomScroll(delta: 8, modifiers: .option, momentum: [], at: point)
        try IntegrationChecks.require(scrolled && view.scaleFactor > beforeZoom && !window.isKeyWindow,
                                      "Option scroll handler scales the non-key reader window")
        let afterZoom = view.scaleFactor
        let ordinary = view.handleZoomScroll(delta: 8, modifiers: [], momentum: [], at: point)
        let momentum = view.handleZoomScroll(delta: 8, modifiers: .option, momentum: .changed, at: point)
        try IntegrationChecks.require(!ordinary && momentum && view.scaleFactor == afterZoom,
                                      "Ordinary scrolling and gesture inertia do not change scale")
        other.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        controller.pdfView.setManualScale(1)
        controller.focusSearch(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        try IntegrationChecks.require((115...138).contains(controller.searchField.frame.width) &&
                                      controller.searchField.currentEditor() != nil,
                                      "The compact search field stays visible and accepts keyboard focus")
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
        colorButton?.performClick(nil)
        let customEditor = NSApp.windows.filter(\.isVisible).compactMap {
            $0.contentView.flatMap { findButton(in: $0, identifier: "editHighlightColor") }
        }.first
        customEditor?.performClick(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let sheet = window.attachedSheet,
              let well = descendants(sheet.contentView).compactMap({ $0 as? NSColorWell }).first,
              let apply = descendants(sheet.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "应用" }) else {
            throw IntegrationChecks.Failure(description: "Custom highlight sheet did not open")
        }
        let custom = NSColor(srgbRed: 0.95, green: 0.53, blue: 0.23, alpha: 1)
        well.color = custom
        apply.performClick(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        try IntegrationChecks.require(mark.color.usingColorSpace(.sRGB) == custom &&
                                      AppearancePreferences.customHighlightColor == custom,
                                      "Custom color applies to the selected PDF highlight and is saved as a swatch")
        document.undoManager?.undo()
        try IntegrationChecks.require(mark.color.usingColorSpace(.sRGB) == HighlightColor.green.color,
                                      "Custom recoloring follows the same undo path as presets")
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
