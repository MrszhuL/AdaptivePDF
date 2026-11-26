import AppKit
import Darwin
import PDFKit

enum ReaderError: LocalizedError {
    case invalidPDF, locked, protectedSave, signedSave, serialization
    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "文件不是有效的 PDF，或文件已损坏。"
        case .locked: return "PDF 尚未解锁，无法保存。"
        case .protectedSave: return "此 PDF 已加密。为避免意外移除密码保护，当前版本仅允许阅读，不允许修改或重新保存。"
        case .signedSave: return "此 PDF 含有数字签名。为保留签名，AdaptivePDF 以只读方式打开。"
        case .serialization: return "PDF 序列化失败。原文件未被覆盖，请尝试另存为。"
        }
    }
}

@objc(PDFReaderDocument)
final class PDFReaderDocument: NSDocument {
    // During initial loading, each document and its PDFKit objects belong to one
    // loader thread. AppKit hands the finished document to the main thread before
    // creating windows. Live objects are never edited by a background writer.
    nonisolated(unsafe) var pdf: PDFDocument?
    nonisolated(unsafe) private(set) var imagePreservingRenderer: ImagePreservingRenderer?
    nonisolated(unsafe) private var preservingWriter: PreservingPDFWriter?
    nonisolated(unsafe) private var loadedFormWidgets: [PDFAnnotation] = []
    nonisolated(unsafe) private(set) var hasDigitalSignatures = false
    private var formTracker: FormValueTracker?
    #if DEBUG || INTEGRATION_TESTS
    nonisolated(unsafe) private(set) var loadedOnMainThread: Bool?
    #endif
    override init() {
        super.init()
        hasUndoManager = true
        undoManager = UndoManager()
        // Native PDFKit text widgets rely on AppKit's automatic event grouping.
        // Annotation commands form their own complete explicit boundary.
        NotificationCenter.default.addObserver(self, selector: #selector(pdfDidUnlock(_:)),
                                               name: .PDFDocumentDidUnlock, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                        for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    var canAnnotate: Bool {
        guard let pdf else { return false }
        return !pdf.isLocked && !pdf.isEncrypted && !hasDigitalSignatures && pdf.allowsCommenting
    }

    override func read(from url: URL, ofType typeName: String) throws {
        #if DEBUG || INTEGRATION_TESTS
        loadedOnMainThread = Thread.isMainThread
        #endif
        // Snapshot the source, so safe replacement never leaves lazy page streams
        // referring to an overwritten source file. No transformed raster is stored.
        let data = try Self.sourceSnapshot(at: url)
        guard let loaded = ImagePreservingPDFDocument(data: data), loaded.isLocked || loaded.pageCount > 0 else {
            throw ReaderError.invalidPDF
        }
        let documentRef = loaded.documentRef
        let signed = !loaded.isEncrypted && APDFHasPDFSignatures(data, documentRef)
        let formPages = loaded.isLocked ? [] : Self.formPageIndices(in: loaded)
        let protectedWidgets = loaded.isEncrypted || signed ? Self.disableFormEditing(in: loaded, pages: formPages) : []
        hasDigitalSignatures = signed
        pdf = loaded
        imagePreservingRenderer = ImagePreservingRenderer(source: data, pageCount: loaded.pageCount, encrypted: loaded.isEncrypted)
        loaded.displayRenderer = imagePreservingRenderer
        // Native widgets can be edited directly by PDFKit and need their
        // original state before the form editor is enabled.
        preservingWriter = loaded.isEncrypted || loaded.isLocked || signed ? nil :
            PreservingPDFWriter(source: data, pdf: loaded, formPages: formPages)
        loaded.annotationWriter = preservingWriter
        let formWidgets = preservingWriter?.formWidgets ?? protectedWidgets
        loadedFormWidgets = formWidgets
        // Initial reads may finish on a loader thread. Existing AppKit views are
        // rebound on the main thread only, after the complete read has succeeded.
        let install = { [weak self] in
            guard let self, self.pdf === loaded else { return }
            if self.formTracker?.tracks(loaded) != true {
                self.formTracker = FormValueTracker(document: self, pdf: loaded, widgets: formWidgets)
            }
            for controller in self.windowControllers.compactMap({ $0 as? ReaderWindowController }) {
                controller.replacePDF(with: loaded)
            }
        }
        if Thread.isMainThread { install() }
        else { DispatchQueue.main.async(execute: install) }
    }

    nonisolated private static func sourceSnapshot(at url: URL) throws -> Data {
        if url.isFileURL {
            let files = FileManager.default
            let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            if (try? files.createDirectory(at: scratch, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])) != nil {
                defer { try? files.removeItem(at: scratch) }
                let snapshot = scratch.appendingPathComponent("document.pdf")
                // Map a copy-on-write clone so replacement or in-place writes
                // to the user's file cannot invalidate our lazy page streams.
                if clonefile(url.path, snapshot.path, 0) == 0,
                   let mapped = try? Data(contentsOf: snapshot, options: .mappedIfSafe) {
                    return mapped
                }
            }
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func formPageIndices(in pdf: PDFDocument) -> [Int] {
        let allPages = 0..<pdf.pageCount
        guard let document = pdf.documentRef, let catalog = document.catalog else { return Array(allPages) }
        var form: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &fields), let fields,
              CGPDFArrayGetCount(fields) > 0 else { return [] }
        return allPages.filter { index in
            guard let page = document.page(at: index + 1)?.dictionary else { return true }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { return false }
            for slot in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                if CGPDFArrayGetDictionary(annotations, slot, &annotation), let annotation,
                   CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype,
                   strcmp(subtype, "Widget") == 0 { return true }
            }
            return false
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let pdf else { throw ReaderError.invalidPDF }
        guard !pdf.isLocked else { throw ReaderError.locked }
        guard !pdf.isEncrypted else { throw ReaderError.protectedSave }
        guard !hasDigitalSignatures else { throw ReaderError.signedSave }
        guard let preservingWriter else { throw ReaderError.serialization }
        let data = try preservingWriter.data(for: pdf)
        guard let check = PDFDocument(data: data),
              check.pageCount == pdf.pageCount else { throw ReaderError.serialization }
        return data
    }

    override func makeWindowControllers() {
        guard let pdf else { return }
        if formTracker == nil {
            formTracker = FormValueTracker(document: self, pdf: pdf, widgets: loadedFormWidgets)
        }
        let controller = ReaderWindowController(readerDocument: self, pdf: pdf)
        addWindowController(controller)
    }

    override func save(_ sender: Any?) {
        guard pdf?.isEncrypted != true else { presentError(ReaderError.protectedSave); return }
        guard !hasDigitalSignatures else { presentError(ReaderError.signedSave); return }
        finishFormEditing()
        super.save(sender)
    }

    override func saveAs(_ sender: Any?) {
        guard pdf?.isEncrypted != true else { presentError(ReaderError.protectedSave); return }
        guard !hasDigitalSignatures else { presentError(ReaderError.signedSave); return }
        finishFormEditing()
        super.saveAs(sender)
    }

    func finishFormEditing() {
        for controller in windowControllers {
            guard let window = controller.window, window.attachedSheet == nil else { continue }
            window.makeFirstResponder((controller as? ReaderWindowController)?.pdfView)
        }
        formTracker?.synchronize()
    }

    func synchronizeFormValues() { formTracker?.synchronize() }

    @objc private func pdfDidUnlock(_ notification: Notification) {
        guard let unlocked = notification.object as? PDFDocument, unlocked === pdf, unlocked.isEncrypted else { return }
        // This product deliberately keeps encrypted documents read-only. Set
        // the live field flags before PDFView creates any interactive editors;
        // encrypted source data can never enter the writer.
        let widgets = Self.disableFormEditing(in: unlocked, pages: Self.formPageIndices(in: unlocked))
        loadedFormWidgets = widgets
        formTracker = FormValueTracker(document: self, pdf: unlocked, widgets: widgets)
    }

    nonisolated private static func disableFormEditing(in pdf: PDFDocument, pages: [Int]) -> [PDFAnnotation] {
        var widgets: [PDFAnnotation] = []
        for index in pages {
            for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                annotation.isReadOnly = true
                widgets.append(annotation)
            }
        }
        return widgets
    }

    var nativeFormEditorHandlesUndo: Bool {
        windowControllers.contains { controller in
            guard let reader = controller as? ReaderWindowController,
                  let editor = reader.window?.firstResponder as? NSTextView else { return false }
            // PDFKit registers semantic field edits with PDFView's manager;
            // its private text editor deliberately has allowsUndo == false.
            return editor.isDescendant(of: reader.pdfView)
        }
    }

    func withUndoGroup(named name: String, _ edit: () -> Void) {
        guard let manager = undoManager else { edit(); return }
        let automatic = manager.groupsByEvent && manager.groupingLevel == 0
        if automatic { manager.groupsByEvent = false }
        defer { if automatic { manager.groupsByEvent = true } }
        manager.beginUndoGrouping()
        edit()
        manager.setActionName(name)
        manager.endUndoGrouping()
    }

    func contentChanged(on page: PDFPage, formOnly: Bool = false) {
        // NSDocument tracks undo registrations and automatically updates dirty state.
        NotificationCenter.default.post(name: .readerAnnotationsChanged, object: self,
                                        userInfo: ["page": page, "formOnly": formOnly])
    }
}

extension Notification.Name {
    static let readerWindowOpened = Notification.Name("AdaptivePDFReaderWindowOpened")
    static let readerAnnotationsChanged = Notification.Name("AdaptivePDFAnnotationsChanged")
}
