#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit

enum DocumentLifecycleChecks {
    @MainActor static func run(root: URL, output: URL) async throws {
        let type = "com.adobe.pdf"
        let fixture = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
        let document = PDFReaderDocument()
        try document.read(from: fixture, ofType: type)
        document.fileURL = fixture; document.fileType = type
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let controller = document.windowControllers[0] as! ReaderWindowController
        controller.showWindow(nil)
        let old = document.pdf!
        let oldPage = old.page(at: 1)!
        controller.pdfView.go(to: oldPage)
        controller.actualSize(nil)
        controller.searchField.stringValue = "AdaptivePDF"
        controller.searchNow(nil)
        let note = AnnotationStore.note(at: NSPoint(x: 100, y: 300), on: oldPage, text: "Unsaved before revert")
        controller.setPresence(note, page: oldPage, present: true)
        controller.selectAnnotation(note)
        controller.editAnnotation(nil)
        IntegrationChecks.pump(0.1)
        try IntegrationChecks.require(controller.window?.attachedSheet != nil && document.isDocumentEdited,
                                      "Revert fixture has a live draft and unsaved annotation")
        try document.revert(toContentsOf: fixture, ofType: type)
        IntegrationChecks.pump(0.3)
        try IntegrationChecks.require(document.pdf !== old && controller.pdf === document.pdf && controller.pdfView.document === document.pdf,
                                      "Revert atomically rebinds model and existing native PDFView")
        try IntegrationChecks.require(controller.window?.attachedSheet == nil && !document.isDocumentEdited && document.undoManager?.canUndo == false,
                                      "Revert discards old drafts and removes stale undo history")
        try IntegrationChecks.require(controller.pdfView.currentPage === document.pdf?.page(at: 1) && abs(controller.pdfView.scaleFactor - 1) < 0.01,
                                      "Revert preserves reading page and manual zoom")
        let searchDeadline = Date().addingTimeInterval(10)
        while document.pdf!.isFinding && Date() < searchDeadline { IntegrationChecks.pump(0.02) }
        try IntegrationChecks.require(controller.searchResults.count == 3 && controller.searchResults.allSatisfy { $0.pages.allSatisfy { $0.document === document.pdf } },
                                      "Search resumes against only the replacement PDF object graph")
        let currentPDF = document.pdf!
        let currentPage = currentPDF.page(at: 0)!
        let newNote = AnnotationStore.note(at: NSPoint(x: 100, y: 300), on: currentPage, text: "Edited after revert")
        controller.setPresence(newNote, page: currentPage, present: true)
        IntegrationChecks.pump(0.05)
        let invalid = output.appendingPathComponent("invalid-revert.pdf")
        try Data("invalid".utf8).write(to: invalid)
        do {
            try document.revert(toContentsOf: invalid, ofType: type)
            throw IntegrationChecks.Failure(description: "Invalid revert unexpectedly succeeded")
        } catch ReaderError.invalidPDF { }
        try IntegrationChecks.require(document.pdf === currentPDF && controller.pdfView.document === currentPDF && document.isDocumentEdited,
                                      "Failed revert leaves the live PDF, annotations and dirty state intact")
        let saved = try document.data(ofType: type)
        try IntegrationChecks.require(PDFDocument(data: saved)?.page(at: 0)?.annotations.contains { $0.contents == "Edited after revert" } == true,
                                      "Annotations edited after revert serialize from the visible document")
        document.updateChangeCount(.changeCleared)
        document.close()

        try await formValues(root: root, output: output)
    }

    @MainActor private static func formValues(root: URL, output: URL) async throws {
        let source = root.appendingPathComponent("Tests/Fixtures/Forms.pdf")
        let document = PDFReaderDocument()
        try document.read(from: source, ofType: "com.adobe.pdf")
        document.fileURL = source; document.fileType = "com.adobe.pdf"
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let controller = document.windowControllers[0] as! ReaderWindowController
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        IntegrationChecks.pump(0.2)
        let pdf = document.pdf!
        let fields = pdf.page(at: 0)!.annotations
        let text = fields.first { $0.fieldName == "reader" }!
        let choice = fields.first { $0.fieldName == "decision" }!
        let checkbox = fields.first { $0.fieldName == "reviewed" }!
        let locked = fields.first { $0.fieldName == "reference" }!
        try IntegrationChecks.require(!document.isDocumentEdited && checkbox.buttonWidgetState == .offState,
                                      "Opening native AcroForm fields does not dirty the document")
        click(text, controller: controller)
        guard let editor = controller.window?.firstResponder as? NSTextView,
              editor.isDescendant(of: controller.pdfView) else {
            throw IntegrationChecks.Failure(description: "Native PDFKit form editor did not activate")
        }
        editor.selectAll(nil)
        editor.insertText("Ada Lovelace", replacementRange: editor.selectedRange())
        try await Task.sleep(nanoseconds: 50_000_000)
        try IntegrationChecks.require(document.isDocumentEdited && document.undoManager?.canUndo == true,
                                      "Typing in the native PDFKit form editor immediately marks the document modified")
        document.undoManager?.undo()
        try await Task.sleep(nanoseconds: 50_000_000)
        try IntegrationChecks.require(text.widgetStringValue == "Original reader" && !document.isDocumentEdited,
                                      "Undo restores the original form value and saved state")
        document.undoManager?.redo()
        try await Task.sleep(nanoseconds: 50_000_000)
        document.finishFormEditing()
        try await Task.sleep(nanoseconds: 50_000_000)
        document.undoManager?.undo()
        try IntegrationChecks.require(text.widgetStringValue == "Original reader" && !document.isDocumentEdited,
                                      "Native form text undo remains correct after its editor resigns focus")
        document.undoManager?.redo()
        try await Task.sleep(nanoseconds: 50_000_000)
        choice.widgetStringValue = "accepted"
        try await Task.sleep(nanoseconds: 50_000_000)
        click(checkbox, controller: controller)
        try await Task.sleep(nanoseconds: 50_000_000)
        try IntegrationChecks.require(checkbox.buttonWidgetState == .onState,
                                      "Native PDFKit checkbox interaction updates the tracked form state")
        document.undoManager?.undo()
        try await Task.sleep(nanoseconds: 50_000_000)
        try IntegrationChecks.require(checkbox.buttonWidgetState == .offState && choice.widgetStringValue == "accepted",
                                      "One undo reverses exactly one native checkbox interaction")
        document.undoManager?.undo()
        try await Task.sleep(nanoseconds: 50_000_000)
        try IntegrationChecks.require(choice.widgetStringValue == "pending",
                                      "The next undo reverses the choice field without a duplicate checkbox action")
        document.undoManager?.redo()
        document.undoManager?.redo()
        try await Task.sleep(nanoseconds: 50_000_000)
        locked.widgetStringValue = "Must not overwrite read-only field"
        document.synchronizeFormValues()
        try IntegrationChecks.require(locked.widgetStringValue == "Read only reference",
                                      "Read-only AcroForm field changes are rejected")
        let data = try document.data(ofType: "com.adobe.pdf")
        try data.write(to: output.appendingPathComponent("Forms-annotated.pdf"))
        let reloaded = PDFDocument(data: data)!.page(at: 0)!.annotations
        try IntegrationChecks.require(reloaded.first { $0.fieldName == "reader" }?.widgetStringValue == "Ada Lovelace" &&
                                      reloaded.first { $0.fieldName == "decision" }?.widgetStringValue == "accepted" &&
                                      reloaded.first { $0.fieldName == "reviewed" }?.buttonWidgetState == .onState,
                                      "Text, choice and checkbox values survive the preserving writer")
        var error: NSError?
        let original = try Data(contentsOf: source)
        try IntegrationChecks.require(APDFVerifyOriginalContent(original, data, &error),
                                      "Saving form values preserves original page contents and complete resources")
        document.updateChangeCount(.changeCleared)
        document.close()

        let second = PDFReaderDocument()
        try second.read(from: output.appendingPathComponent("Forms-annotated.pdf"), ofType: "com.adobe.pdf")
        let secondFields = second.pdf!.page(at: 0)!.annotations
        secondFields.first { $0.fieldName == "reader" }!.widgetStringValue = ""
        secondFields.first { $0.fieldName == "reviewed" }!.buttonWidgetState = .offState
        try second.data(ofType: "com.adobe.pdf").write(to: output.appendingPathComponent("Forms-cleared.pdf"))
        let cleared = PDFDocument(url: output.appendingPathComponent("Forms-cleared.pdf"))!.page(at: 0)!.annotations
        try IntegrationChecks.require(cleared.first { $0.fieldName == "reader" }?.widgetStringValue == "" &&
                                      cleared.first { $0.fieldName == "reviewed" }?.buttonWidgetState == .offState,
                                      "Previously saved form fields can be cleared and checkboxes switched off")
        second.updateChangeCount(.changeCleared)
        second.close()

        let protected = PDFReaderDocument()
        try protected.read(from: root.appendingPathComponent("Tests/Fixtures/EncryptedForms.pdf"), ofType: "com.adobe.pdf")
        try IntegrationChecks.require(protected.pdf!.unlock(withPassword: "reader") &&
                                      protected.pdf!.page(at: 0)!.annotations.filter { $0.type == "Widget" }.allSatisfy(\.isReadOnly),
                                      "Unlocking an encrypted PDF disables all native form editors")
        let protectedText = protected.pdf!.page(at: 0)!.annotations.first { $0.fieldName == "reader" }!
        protectedText.widgetStringValue = "Must remain protected"
        try IntegrationChecks.require(protectedText.widgetStringValue == "Original reader" && !protected.isDocumentEdited,
                                      "Encrypted form values remain read-only without silently retaining unsavable edits")
        protected.close()

        let noPrompt = PDFReaderDocument()
        try noPrompt.read(from: root.appendingPathComponent("Tests/Fixtures/EncryptedFormsEmptyPassword.pdf"), ofType: "com.adobe.pdf")
        try IntegrationChecks.require(noPrompt.pdf!.isEncrypted && (noPrompt.pdf!.isLocked ||
                                      noPrompt.pdf!.page(at: 0)!.annotations.filter { $0.type == "Widget" }.allSatisfy(\.isReadOnly)),
                                      "Encrypted PDFs with an empty user password also enforce form read-only protection")
        noPrompt.close()
    }

    /// Route a mouse press through the same hit-tested native child view used
    /// by the reader, using only public AppKit APIs inside the test process.
    private static func click(_ annotation: PDFAnnotation, controller: ReaderWindowController) {
        let window = controller.window!
        let view = controller.pdfView
        view.layoutDocumentView()
        IntegrationChecks.pump(0.1)
        let point = view.convert(NSPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), from: annotation.page!)
        let location = view.convert(point, to: nil)
        let hitPoint = view.superview!.convert(point, from: view)
        let target = view.hitTest(hitPoint)!
        let time = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        target.mouseDown(with: down)
    }
}
#endif
