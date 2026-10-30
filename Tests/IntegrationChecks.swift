#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit
import CoreImage

/// Executed only with --self-test. Never opens or writes the user's documents.
enum IntegrationChecks {
    private static var passed: [String] = []
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
        print("PASS: \(message)")
        passed.append(message)
        fflush(stdout)
    }
    static func pump(_ seconds: TimeInterval = 0.2) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    @MainActor static func run() async {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ADAPTIVEPDF_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let output = ProcessInfo.processInfo.environment["ADAPTIVEPDF_TEST_OUTPUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? root.appendingPathComponent("tmp/test-output", isDirectory: true)
        let oldMode = AppearancePreferences.mode
        let oldStrategy = AppearancePreferences.strategy
        let oldAppAppearance = NSApp.appearance
        defer {
            AppearancePreferences.mode = oldMode
            AppearancePreferences.strategy = oldStrategy
            NSApp.appearance = oldAppAppearance
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if ProcessInfo.processInfo.environment["ADAPTIVEPDF_THUMBNAILS_ONLY"] == "1" {
                try await ThumbnailChecks.run(root: root, output: output)
                print("ALL THUMBNAIL CHECKS PASSED")
                exit(0)
            }
            if ProcessInfo.processInfo.environment["ADAPTIVEPDF_IMAGE_ONLY"] == "1" {
                try ImagePreservationChecks.run(root: root, output: output, capture: true)
                print("ALL IMAGE PRESERVATION CHECKS PASSED")
                exit(0)
            }
            if ProcessInfo.processInfo.environment["ADAPTIVEPDF_INTERACTION_ONLY"] == "1" {
                try await ReaderInteractionChecks.run(root: root, output: output)
                print("ALL POINTER INTERACTION CHECKS PASSED")
                exit(0)
            }
            if ProcessInfo.processInfo.environment["ADAPTIVEPDF_LIFECYCLE_ONLY"] == "1" {
                try await DocumentLifecycleChecks.run(root: root, output: output)
                print("ALL DOCUMENT LIFECYCLE CHECKS PASSED")
                exit(0)
            }
            let source = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
            let before = try Data(contentsOf: source)
            let unsafe = PDFDocument(data: before)!.dataRepresentation()!
            var validationError: NSError?
            try require(!APDFVerifyOriginalContent(before, unsafe, &validationError) && validationError != nil,
                        "Content guard rejects PDFKit's page-rewriting save path")
            let document = PDFReaderDocument()
            try document.read(from: source, ofType: "com.adobe.pdf")
            document.fileURL = source
            document.fileType = "com.adobe.pdf"
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            guard let controller = document.windowControllers.first as? ReaderWindowController,
                  let pdf = document.pdf, let page = pdf.page(at: 0), let rotated = pdf.page(at: 1) else {
                throw Failure(description: "Document window was not created")
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.makeMain()
            pump(0.5)
            try require(pdf.pageCount == 3 && document.canAnnotate, "Intel macOS 15 document and native window load")
            try require(!document.isDocumentEdited, "Opening a PDF does not mark it modified")
            // A shell-launched test process can remain inactive (no key window).
            // Exercise forwarding from PDFView rather than relying on app focus.
            try require(controller.pdfView.tryToPerform(#selector(ReaderWindowController.focusSearch(_:)), with: nil),
                        "Responder chain forwards reader menu actions")

            controller.fitWidth(nil)
            try require(controller.pdfView.scaleFactor > 0, "Fit width produces a valid zoom")
            controller.zoomIn(nil)
            controller.nextPage(nil)
            pump()
            try require(controller.pdfView.currentPage === rotated, "Next-page navigation")
            controller.previousPage(nil)
            controller.fitPage(nil)

            controller.searchField.stringValue = "AdaptivePDF"
            controller.searchNow(nil)
            let deadline = Date().addingTimeInterval(10)
            while pdf.isFinding && Date() < deadline { pump(0.05) }
            pump()
            try require(controller.searchResults.count == 3, "Asynchronous full-text search finds all three pages")
            controller.nextMatch(nil)
            try require(controller.pdfView.currentSelection != nil, "Search result locates native PDFSelection")

            guard let string = page.string as NSString? else { throw Failure(description: "No extracted text") }
            let start = string.range(of: "First selected line").location
            let last = string.range(of: "Second selected line.")
            guard start != NSNotFound, last.location != NSNotFound,
                  let selection = page.selection(for: NSRange(location: start, length: NSMaxRange(last) - start)) else {
                throw Failure(description: "Fixture text selection unavailable")
            }
            controller.pdfView.setCurrentSelection(selection, animate: false)
            controller.highlightSelection(nil)
            // Complete the simulated input event before checking AppKit's
            // automatic undo/modified-state boundary.
            pump(0.05)
            let marks = page.annotations.filter { $0.type == "Highlight" }
            try require(marks.count == 1 && (marks[0].quadrilateralPoints?.count ?? 0) >= 8, "Cross-line highlight uses multiple standard QuadPoints")
            try require(document.isDocumentEdited, "Annotation changes mark the NSDocument modified")
            let highlight = marks[0]
            controller.changeContents(highlight, text: "Saved highlight comment")
            controller.changeColor(highlight, color: HighlightColor.green.color)
            controller.selectAnnotation(highlight)
            controller.pdfView.setCurrentSelection(selection, animate: false)
            pump(0.1)
            if let popup = controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "color" })?.view as? NSPopUpButton,
               let action = popup.action {
                let beforeColor = highlight.color
                popup.selectItem(at: HighlightColor.blue.rawValue)
                NSApp.sendAction(action, to: popup.target, from: popup)
                try require(highlight.color == beforeColor, "Choosing a color for new text never recolors a previous annotation")
                controller.selectAnnotation(highlight)
                popup.selectItem(at: HighlightColor.pink.rawValue)
                NSApp.sendAction(action, to: popup.target, from: popup)
                try require(highlight.color == HighlightColor.pink.color, "Explicitly selected annotation can still be recolored")
                controller.changeColor(highlight, color: HighlightColor.green.color)
            } else { throw Failure(description: "Highlight color toolbar control unavailable") }

            // Exercise the actual AppKit editor, its private draft, Cancel, and
            // committing through the alert button callback.
            controller.selectAnnotation(highlight)
            controller.editAnnotation(nil)
            pump(0.15)
            guard let editSheet = controller.window?.attachedSheet,
                  let editor = descendants(editSheet.contentView).compactMap({ $0 as? NSTextView }).first else {
                throw Failure(description: "Native annotation editor did not open")
            }
            try require(editor.allowsUndo && editor.isEditable, "Native comment editor supports undo and plain text editing")
            editor.insertText("Canceled draft", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            try require(highlight.contents == "Saved highlight comment", "Editor draft never mutates the PDF before confirmation")
            try require(editor.undoManager !== document.undoManager, "Draft typing uses an independent undo history")
            editor.breakUndoCoalescing()
            editor.undoManager?.undo()
            try require(editor.string == "Saved highlight comment", "Undo in the native editor restores the draft text")
            editor.undoManager?.redo()
            try require(editor.string == "Canceled draft", "Redo in the native editor restores the typed draft")
            guard let cancel = descendants(editSheet.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "取消" }) else {
                throw Failure(description: "Editor Cancel button unavailable")
            }
            cancel.performClick(nil); pump(0.2)
            try require(highlight.contents == "Saved highlight comment" && controller.window?.attachedSheet == nil,
                        "Canceling the native editor discards the draft")
            controller.editAnnotation(nil); pump(0.15)
            guard let commitSheet = controller.window?.attachedSheet,
                  let commitEditor = descendants(commitSheet.contentView).compactMap({ $0 as? NSTextView }).first,
                  let done = descendants(commitSheet.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "完成" }) else {
                throw Failure(description: "Editor confirmation controls unavailable")
            }
            commitEditor.insertText("Edited through native sheet", replacementRange: NSRange(location: 0, length: (commitEditor.string as NSString).length))
            done.performClick(nil); pump(0.2)
            try require(highlight.contents == "Edited through native sheet", "Native editor confirmation commits the standard annotation comment")
            controller.changeContents(highlight, text: "Saved highlight comment")

            let underline = PDFAnnotation(bounds: highlight.bounds, forType: .underline, withProperties: nil)
            underline.quadrilateralPoints = highlight.quadrilateralPoints
            underline.contents = "Imported underline comment"
            let textBox = PDFAnnotation(bounds: NSRect(x: 60, y: 210, width: 240, height: 30), forType: .freeText, withProperties: nil)
            textBox.contents = "Imported free text"
            let locked = AnnotationStore.note(at: NSPoint(x: 500, y: 210), on: page, text: "Locked note")
            locked.setValue(NSNumber(value: 128 | 4), forAnnotationKey: .flags)
            let link = PDFAnnotation(bounds: NSRect(x: 60, y: 200, width: 60, height: 20), forType: .link, withProperties: nil)
            for annotation in [underline, textBox, locked, link] { page.addAnnotation(annotation) }
            document.contentChanged(on: page)
            let reviewEntries = AnnotationStore.entries(in: pdf)
            try require(reviewEntries.count == 4 && reviewEntries.contains(where: { $0.annotation === underline }) &&
                        reviewEntries.contains(where: { $0.annotation === textBox }), "Sidebar indexes imported review annotation types and excludes navigation links")
            try require(!locked.allowsReviewEditing && underline.allowsReviewEditing,
                        "Externally locked annotations stay read-only")
            controller.selectAnnotation(locked)
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(ReaderWindowController.deleteAnnotation(_:)), keyEquivalent: "")
            try require(!controller.validateMenuItem(deleteItem), "Delete action is disabled for a locked annotation")
            for annotation in [underline, textBox, locked, link] { page.removeAnnotation(annotation) }
            document.contentChanged(on: page)

            // Construct a true selection spanning page boundaries.
            if let cross = pdf.selection(from: page, atCharacterIndex: max(0, string.length - 25),
                                         to: rotated, atCharacterIndex: 45) {
                let across = AnnotationStore.highlights(for: cross, color: HighlightColor.pink.color)
                try require(across.count == 2, "Cross-page selection creates one standard highlight per page")
                for (p, a) in across { controller.setPresence(a, page: p, present: true) }
            } else { throw Failure(description: "Cross-page selection failed") }
            let rotatedText = rotated.string! as NSString
            guard let rotatedSelection = rotated.selection(for: NSRange(location: 0, length: min(70, rotatedText.length))) else {
                throw Failure(description: "Rotated page selection failed")
            }
            let rotatedMarks = AnnotationStore.highlights(for: rotatedSelection, color: HighlightColor.blue.color)
            try require(!rotatedMarks.isEmpty && rotated.rotation == 90, "Rotated, cropped page retains page-space highlight geometry")
            for (p, a) in rotatedMarks { controller.setPresence(a, page: p, present: true) }
            let unicodeComment = "中文批注：公式 α + β = 1，🙂"
            let unicodeNote = AnnotationStore.note(at: NSPoint(x: 100, y: 250), on: rotated, text: unicodeComment)
            controller.setPresence(unicodeNote, page: rotated, present: true)
            let unicodeReload = PDFDocument(data: try document.data(ofType: "com.adobe.pdf"))!
            try require(unicodeReload.page(at: 1)!.annotations.contains { $0.contents == unicodeComment },
                        "Chinese, mathematical Unicode and emoji comments round-trip on rotated/cropped pages")
            controller.setPresence(unicodeNote, page: rotated, present: false)

            let note = AnnotationStore.note(at: NSPoint(x: 300, y: 500), on: page, text: "Sticky note survives reload")
            controller.setPresence(note, page: page, present: true)
            pump(0.05)
            controller.setPresence(note, page: page, present: false)
            pump(0.05)
            try require(!page.annotations.contains(note), "Annotation deletion")
            try require(controller.pdfView.tryToPerform(Selector(("undo:")), with: nil),
                        "Reader responder chain routes native Undo to the document history")
            try require(page.annotations.contains(note), "Undo restores deleted annotation")
            try require(controller.pdfView.tryToPerform(Selector(("redo:")), with: nil),
                        "Reader responder chain routes native Redo to the document history")
            try require(!page.annotations.contains(note), "Redo removes annotation again")
            controller.setPresence(note, page: page, present: true)

            let count = AnnotationStore.entries(in: pdf).count
            let preTheme = try document.data(ofType: "com.adobe.pdf")
            let location = controller.pdfView.currentPage
            let scale = controller.pdfView.scaleFactor
            AppearancePreferences.mode = .system
            AppearancePreferences.strategy = .basic
            NSApp.appearance = NSAppearance(named: .darkAqua)
            pump(0.5)
            try require(controller.pdfView.basicDarkActive && controller.pdfView.layer?.filters?.count == 1,
                        "Follow System responds live to inherited dark appearance")
            NSApp.appearance = NSAppearance(named: .aqua)
            pump(0.5)
            try require(!controller.pdfView.basicDarkActive, "Follow System returns live to light appearance")
            AppearancePreferences.mode = .dark
            pump()
            try require(controller.pdfView.basicDarkActive, "Explicit Dark overrides light system appearance")
            AppearancePreferences.strategy = .original
            try require(!controller.pdfView.basicDarkActive, "Original strategy preserves displayed PDF colors")
            let themeControl = controller.window!.toolbar!.items.first { $0.itemIdentifier.rawValue == "theme" }!.view as! NSPopUpButton
            themeControl.selectItem(at: ThemeMode.allCases.firstIndex(of: .dark)!)
            NSApp.sendAction(themeControl.action!, to: themeControl.target, from: themeControl)
            try require(controller.pdfView.preservingDarkActive && AppearancePreferences.strategy == .preserveImages,
                        "Choosing Dark in the toolbar turns the PDF page dark after Original was selected")
            AppearancePreferences.strategy = .original
            let darkMenuItem = NSMenuItem()
            darkMenuItem.tag = ThemeMode.allCases.firstIndex(of: .dark)!
            controller.setTheme(darkMenuItem)
            try require(controller.pdfView.preservingDarkActive,
                        "Choosing Dark in the menu also restores dark PDF pages")
            AppearancePreferences.strategy = .original
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeControl.selectItem(at: ThemeMode.allCases.firstIndex(of: .system)!)
            NSApp.sendAction(themeControl.action!, to: themeControl.target, from: themeControl)
            pump()
            try require(controller.pdfView.preservingDarkActive,
                        "Choosing Follow System restores dark PDF pages when the inherited appearance is Dark")
            AppearancePreferences.mode = .light
            pump()
            try require(controller.pdfView.currentPage === location && abs(controller.pdfView.scaleFactor - scale) < 0.01,
                        "Theme changes retain page and zoom")
            try require(AnnotationStore.entries(in: pdf).count == count, "Theme changes retain annotations")
            let afterTheme = try document.data(ofType: "com.adobe.pdf")
            try preTheme.write(to: output.appendingPathComponent("before-theme.pdf"))
            try afterTheme.write(to: output.appendingPathComponent("after-theme.pdf"))
            try require(tryData(source) == before, "Viewing and theme changes never write the source file")

            let saved = output.appendingPathComponent("Annotated.pdf")
            var saveFinished = false
            var saveError: Error?
            document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
                saveError = error; saveFinished = true
            }
            let saveDeadline = Date().addingTimeInterval(15)
            while !saveFinished && Date() < saveDeadline { pump(0.02) }
            try require(saveFinished, "Safe save completion returns within 15 seconds")
            if let saveError { throw saveError }
            validationError = nil
            try require(APDFVerifyOriginalContent(before, tryData(saved)!, &validationError) && validationError == nil,
                        "Preserving save retains every page content/font/image resource graph")
            try require(!document.isDocumentEdited, "Successful NSDocument safe save clears modified state")
            let reopened = PDFDocument(url: saved)!
            let reloaded = AnnotationStore.entries(in: reopened)
            try require(reloaded.count == count, "All standard annotations survive saving and reopening")
            try require(reloaded.contains { $0.annotation.contents == "Saved highlight comment" }, "Highlight comment persists")
            try require(reloaded.contains { $0.annotation.contents == "Sticky note survives reload" }, "Text note persists")
            try require(reopened.string == pdf.string, "Original text survives annotation-only save")
            let originalCG = CGPDFDocument(source as CFURL)!
            let savedCG = CGPDFDocument(saved as CFURL)!
            for index in 1...originalCG.numberOfPages {
                let originalPixels = contentPixels(originalCG.page(at: index)!)
                let savedPixels = contentPixels(savedCG.page(at: index)!)
                let error = zip(originalPixels, savedPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
                    / Double(max(1, originalPixels.count))
                try require(error < 0.1, "Page \(index) base content renders unchanged (mean channel difference < 0.1/255)")
            }
            controller.changeContents(note, text: "Sticky note edited and saved again")
            pump(0.05)
            var currentSaveFinished = false
            var currentSaveError: Error?
            document.save(to: saved, ofType: "com.adobe.pdf", for: .saveOperation) { error in
                currentSaveError = error; currentSaveFinished = true
            }
            let currentSaveDeadline = Date().addingTimeInterval(15)
            while !currentSaveFinished && Date() < currentSaveDeadline { pump(0.02) }
            try require(currentSaveFinished && currentSaveError == nil && !document.isDocumentEdited,
                        "Save current PDF safely replaces an existing file and clears modified state")
            try require(AnnotationStore.entries(in: PDFDocument(url: saved)!).contains {
                $0.annotation.contents == "Sticky note edited and saved again"
            }, "Replacement save retains the updated standard text note")

            controller.changeContents(note, text: "Unsaved after failure")
            pump(0.05)
            var failedFinished = false
            var failedError: Error?
            // A regular file used as a parent deterministically produces ENOTDIR,
            // even under privileged test accounts; no user files are touched.
            let blocked = output.appendingPathComponent("not-a-directory")
            try Data("block".utf8).write(to: blocked)
            document.save(to: blocked.appendingPathComponent("cannot-save.pdf"), ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
                failedError = error; failedFinished = true
            }
            let failureDeadline = Date().addingTimeInterval(15)
            while !failedFinished && Date() < failureDeadline { pump(0.02) }
            try require(failedFinished, "Failed save completion returns within 15 seconds")
            try require(failedError != nil && document.isDocumentEdited, "Failed safe save returns an error and retains unsaved edits")
            try require(PDFDocument(url: saved)?.pageCount == 3, "Failed save leaves previous saved PDF readable")
            do {
                let restricted = output.appendingPathComponent("read-only-directory", isDirectory: true)
                try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restricted.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
                var permissionFinished = false
                var permissionError: Error?
                document.save(to: restricted.appendingPathComponent("denied.pdf"), ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
                    permissionError = error; permissionFinished = true
                }
                let deadline = Date().addingTimeInterval(15)
                while !permissionFinished && Date() < deadline { pump(0.02) }
                try require(permissionFinished && permissionError != nil && document.isDocumentEdited,
                            "Unwritable destination reports permission failure and retains edits")
            }

            // Exercise NSDocument's actual unsaved-close sheet and Cancel path.
            controller.window?.performClose(nil)
            pump(0.4)
            try require(controller.window?.attachedSheet != nil, "Closing a modified document presents the native save/discard/cancel sheet")
            if let sheet = controller.window?.attachedSheet,
               let cancel = descendants(sheet.contentView).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "Cancel" || $0.title == "取消" || $0.keyEquivalent == "\u{1b}" }) {
                cancel.performClick(nil)
                pump(0.3)
            } else { throw Failure(description: "Native close sheet Cancel button unavailable") }
            try require(controller.window?.isVisible == true && document.isDocumentEdited,
                        "Canceling close retains window and unsaved annotations")

            var opened: NSDocument?
            var openError: Error?
            var openFinished = false
            NSDocumentController.shared.openDocument(withContentsOf: source, display: true) { result, _, error in
                opened = result; openError = error; openFinished = true
            }
            let openDeadline = Date().addingTimeInterval(15)
            while !openFinished && Date() < openDeadline { pump(0.02) }
            if let openError { throw openError }
            try require(opened is PDFReaderDocument && NSDocumentController.shared.documents.count >= 2,
                        "Registered PDF document type opens a second independent native document")
            try require((opened as? PDFReaderDocument)?.loadedOnMainThread == false,
                        "Finder/Open document loading runs off the main thread")
            AppearancePreferences.mode = .dark
            AppearancePreferences.strategy = .basic
            pump(0.3)
            let secondController = opened?.windowControllers.first as? ReaderWindowController
            try require(controller.pdfView.basicDarkActive && secondController?.pdfView.basicDarkActive == true,
                        "Theme preference updates all open PDF windows")
            opened?.close()
            AppearancePreferences.mode = .light
            pump(0.2)

            let encrypted = PDFReaderDocument()
            try encrypted.read(from: root.appendingPathComponent("Tests/Fixtures/Encrypted.pdf"), ofType: "com.adobe.pdf")
            try require(encrypted.pdf!.isLocked, "Encrypted PDF opens locked")
            try require(!encrypted.pdf!.unlock(withPassword: "incorrect"), "Incorrect PDF password rejected")
            try require(encrypted.pdf!.unlock(withPassword: "reader") && !encrypted.canAnnotate, "Unlocked encrypted PDF stays read-only")
            do { _ = try encrypted.data(ofType: "com.adobe.pdf"); throw Failure(description: "Encrypted PDF save should fail") }
            catch ReaderError.protectedSave { try require(true, "Encrypted PDF cannot accidentally be saved without protection") }
            let invalid = output.appendingPathComponent("invalid.pdf")
            try Data("invalid".utf8).write(to: invalid)
            do { try encrypted.read(from: invalid, ofType: "com.adobe.pdf"); throw Failure(description: "Invalid PDF should fail") }
            catch ReaderError.invalidPDF { try require(true, "Invalid PDF is rejected") }

            try await DocumentLifecycleChecks.run(root: root, output: output)
            try await ReaderInteractionChecks.run(root: root, output: output)
            try ImagePreservationChecks.run(root: root, output: output)
            try await ThumbnailChecks.run(root: root, output: output)

            // Render original and annotated pages with PDFKit to inspect geometry
            // independently of the compositor-only dark mode.
            for index in 0..<reopened.pageCount {
                let image = reopened.page(at: index)!.thumbnail(of: NSSize(width: 900, height: 1100), for: .cropBox)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: output.appendingPathComponent("annotated-page-\(index + 1).png"))
                }
            }
            print("WINDOW_ID: \(controller.window!.windowNumber)")
            if ProcessInfo.processInfo.environment["ADAPTIVEPDF_CAPTURE"] == "1" {
                var displayError: NSError?
                if let display = APDFCreateImagePreservingDisplay(before, &displayError), let displayData = display["data"] as? Data {
                    try displayData.write(to: output.appendingPathComponent("image-preserving-display.pdf"))
                    print("DISPLAY_PREPARATION: \(display["supported"] ?? "?") \(display["reasons"] ?? "?")")
                } else { print("DISPLAY_PREPARATION_ERROR: \(String(describing: displayError))") }
                controller.window?.makeKeyAndOrderFront(nil)
                var screenshots: [[String: Any]] = []
                AppearancePreferences.strategy = .original
                for mode in [ThemeMode.light, .dark] {
                    themeControl.selectItem(at: ThemeMode.allCases.firstIndex(of: mode)!)
                    NSApp.sendAction(themeControl.action!, to: themeControl.target, from: themeControl)
                    let readyDeadline = Date().addingTimeInterval(15)
                    while controller.pdfView.imagePreservingRenderer?.isPreparing == true && Date() < readyDeadline { pump(0.05) }
                    pump(0.7)
                    print("DISPLAY_STATUS: \(mode.rawValue), preserve=\(controller.pdfView.preservingDarkActive), reason=\(controller.pdfView.imagePreservingRenderer?.reason(for: 0) ?? "none")")
                    let pageBounds = page.bounds(for: .cropBox)
                    let margin = NSRect(x: pageBounds.maxX - 20, y: pageBounds.midY - 10, width: 10, height: 20)
                    let sample = controller.pdfView.convert(controller.pdfView.convert(margin, from: page), to: nil)
                    let imageSample = controller.pdfView.convert(controller.pdfView.convert(NSRect(x: 353, y: 343, width: 186, height: 122), from: page), to: nil)
                    let windowSize = controller.window!.frame.size
                    let status = try WindowCaptureChecks.capture(controller.window!, to: output.appendingPathComponent("window-\(mode.rawValue).png"))
                    print("SCREENSHOT \(mode.rawValue): \(status == 0 ? "captured" : "unavailable")")
                    screenshots.append(["mode": mode.rawValue, "exit_code": status,
                                        "window_size": [windowSize.width, windowSize.height],
                                        "page_margin_sample": [sample.minX, sample.minY, sample.width, sample.height],
                                        "image_sample": [imageSample.minX, imageSample.minY, imageSample.width, imageSample.height]])
                }
                try JSONSerialization.data(withJSONObject: screenshots, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("screenshots.json"))
            }
            if ProcessInfo.processInfo.environment["ADAPTIVEPDF_VISUAL_HOLD"] == "1" {
                AppearancePreferences.mode = .dark
                AppearancePreferences.strategy = .basic
                pump(1)
                print("VISUAL_READY")
                fflush(stdout)
                pump(45)
            }
            document.updateChangeCount(.changeCleared)
            document.close()
            AppearancePreferences.mode = oldMode
            AppearancePreferences.strategy = oldStrategy
            NSApp.appearance = oldAppAppearance
            print("ALL INTEGRATION CHECKS PASSED")
            let report: [String: Any] = [
                "schema_version": 1, "status": "passed", "run_id": UUID().uuidString,
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "assertion_count": passed.count, "assertions": passed,
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "completed_at": ISO8601DateFormatter().string(from: Date())
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("integration-report.json"), options: .atomic)
            fflush(stdout)
            exit(0)
        } catch {
            AppearancePreferences.mode = oldMode
            AppearancePreferences.strategy = oldStrategy
            NSApp.appearance = oldAppAppearance
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
    private static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    private static func contentPixels(_ page: CGPDFPage) -> Data {
        let context = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()!.dataProvider!.data! as Data
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }
}
#endif
