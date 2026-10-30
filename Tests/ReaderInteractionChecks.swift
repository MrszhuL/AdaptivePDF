#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit

/// In-process hit-testing and native Copy checks. Hardware drag/shortcut QA
/// remains a separate requirement and is not implied by these assertions.
@MainActor enum ReaderInteractionChecks {
    static func run(root: URL, output: URL) async throws {
        let document = PDFReaderDocument()
        let source = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
        let original = try Data(contentsOf: source)
        try document.read(from: source, ofType: "com.adobe.pdf")
        document.fileURL = source; document.fileType = "com.adobe.pdf"
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let controller = document.windowControllers[0] as! ReaderWindowController
        let view = controller.pdfView
        let oldMode = AppearancePreferences.mode
        let oldStrategy = AppearancePreferences.strategy
        defer {
            document.updateChangeCount(.changeCleared); document.close()
            AppearancePreferences.mode = oldMode; AppearancePreferences.strategy = oldStrategy
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        view.displayMode = .singlePage
        AppearancePreferences.strategy = .preserveImages
        for index in [0, 1] {
            let page = document.pdf!.page(at: index)!
            view.go(to: page)
            controller.fitPage(nil)
            for (offset, mode) in [ThemeMode.light, .dark].enumerated() {
                AppearancePreferences.mode = mode
                try await Task.sleep(nanoseconds: 100_000_000)
                view.layoutDocumentView()
                let box = page.bounds(for: .cropBox)
                let point = NSPoint(x: box.minX + 100 + CGFloat(offset) * 80, y: box.minY + 150)
                controller.placeNote(nil)
                click(at: point, on: page, in: view)
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let sheet = controller.window?.attachedSheet,
                      let editor = descendants(sheet.contentView).compactMap({ $0 as? AnnotationDraftTextView }).first else {
                    throw IntegrationChecks.Failure(description: "Native hit-tested page click did not open the note editor (page \(index + 1), \(mode.rawValue))")
                }
                try IntegrationChecks.require(!view.placingNote, "Page \(index + 1) \(mode.rawValue): native note click consumes placement mode")
                let comment = "Pointer note page \(index + 1) \(mode.rawValue)"
                editor.insertText(comment, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                descendants(sheet.contentView).compactMap { $0 as? NSButton }.first { $0.title == "完成" }!.performClick(nil)
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let note = page.annotations.first(where: { $0.contents == comment }) else {
                    throw IntegrationChecks.Failure(description: "Placed note did not commit")
                }
                try IntegrationChecks.require(abs(note.bounds.minX - point.x) < 0.5 && abs(note.bounds.minY - point.y) < 0.5,
                                              "Page \(index + 1) \(mode.rawValue): viewport click maps to the intended PDF coordinates")
                click(at: NSPoint(x: note.bounds.midX, y: note.bounds.midY), on: page, in: view)
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let reopened = controller.window?.attachedSheet,
                      let reopenedEditor = descendants(reopened.contentView).compactMap({ $0 as? AnnotationDraftTextView }).first else {
                    throw IntegrationChecks.Failure(description: "Native note click did not reopen the review editor")
                }
                try IntegrationChecks.require(reopenedEditor.string == comment,
                                              "Page \(index + 1) \(mode.rawValue): native note hit opens its saved comment")
                descendants(reopened.contentView).compactMap { $0 as? NSButton }.first { $0.title == "取消" }!.performClick(nil)
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let page = document.pdf!.page(at: 0)!
        view.go(to: page); controller.fitPage(nil)
        let text = page.string! as NSString
        let first = text.range(of: "First selected line")
        let last = text.range(of: "Second selected line.")
        for mode in [ThemeMode.light, .dark] {
            AppearancePreferences.mode = mode
            try await Task.sleep(nanoseconds: 100_000_000)
            // The shell-launched process can be inactive. Do not mistake an
            // injected drag for physical pointer QA; the latter stays pending.
            let selection = page.selection(for: NSRange(location: first.location, length: NSMaxRange(last) - first.location))!
            view.setCurrentSelection(selection, animate: false)
            try copyAndRestore(view)
            controller.highlightSelection(nil)
            let line = selection.selectionsByLine()[0].bounds(for: page)
            click(at: NSPoint(x: line.midX, y: line.midY), on: page, in: view, clickCount: 2)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let sheet = controller.window?.attachedSheet,
                  let editor = descendants(sheet.contentView).compactMap({ $0 as? AnnotationDraftTextView }).first else {
                throw IntegrationChecks.Failure(description: "Native highlight double-click did not open the review editor")
            }
            let comment = "Pointer highlight \(mode.rawValue)"
            editor.insertText(comment, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            descendants(sheet.contentView).compactMap { $0 as? NSButton }.first { $0.title == "完成" }!.performClick(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            try IntegrationChecks.require(page.annotations.contains { $0.type == "Highlight" && $0.contents == comment },
                                          "\(mode.rawValue): native highlight hit edits the intended standard comment")
        }
        let saved = try document.data(ofType: "com.adobe.pdf")
        try saved.write(to: output.appendingPathComponent("Pointer-annotated.pdf"))
        var error: NSError?
        try IntegrationChecks.require(APDFVerifyOriginalContent(original, saved, &error),
                                      "Pointer-created annotations retain original page contents and resources when saved")
        try IntegrationChecks.require(tryData(source) == original, "Pointer interaction and theme changes never modify the source PDF")
    }

    private static func click(at start: NSPoint, on page: PDFPage, in view: ReaderPDFView, clickCount: Int = 1) {
        view.layoutDocumentView()
        let local = view.convert(start, from: page)
        let windowPoint = view.convert(local, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ location: NSPoint, _ offset: TimeInterval) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time + offset,
                               windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1,
                               clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let target = view.hitTest(view.superview!.convert(local, from: view))!
        NSApp.postEvent(event(.leftMouseUp, windowPoint, 0.02), atStart: true)
        target.mouseDown(with: event(.leftMouseDown, windowPoint, 0))
    }
    private static func copyAndRestore(_ view: PDFView) throws {
        // Only the generated fixture selection is inspected. User clipboard
        // bytes stay in memory and are restored without logging or writing them.
        let board = NSPasteboard.general
        let initialChange = board.changeCount
        let snapshot = try (board.pasteboardItems ?? []).map { item -> [(NSPasteboard.PasteboardType, Data)] in
            try item.types.map { type in
                guard let data = item.data(forType: type) else {
                    throw IntegrationChecks.Failure(description: "Clipboard format cannot be restored; Copy was not executed")
                }
                return (type, data)
            }
        }
        guard board.changeCount == initialChange else { throw IntegrationChecks.Failure(description: "Clipboard changed before Copy") }
        view.copy(nil)
        let copiedChange = board.changeCount
        defer {
            if board.changeCount == copiedChange {
                board.clearContents()
                let items = snapshot.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        try IntegrationChecks.require(board.string(forType: .string) == view.currentSelection?.string,
                                      "Native PDFView Copy writes the selected fixture text to the pasteboard")
    }
    private static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }
}
#endif
