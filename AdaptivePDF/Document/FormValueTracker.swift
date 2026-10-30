import AppKit
import PDFKit

/// Observe public PDFKit field values, including changes performed by PDFView.
/// The tracker owns no PDF views and is replaced when the document is reverted.
final class FormValueTracker {
    private struct Value: Equatable {
        let text: String?
        let button: Int?
        init(_ annotation: PDFAnnotation) {
            if annotation.widgetFieldType == .button {
                text = nil; button = annotation.buttonWidgetState.rawValue
            } else {
                text = annotation.widgetStringValue; button = nil
            }
        }
    }
    private unowned let document: PDFReaderDocument
    private let pdf: PDFDocument
    private var annotations: [PDFAnnotation] = []
    private var values: [ObjectIdentifier: Value] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var nativeWidgets: Set<ObjectIdentifier> = []
    private var applying = false

    init(document: PDFReaderDocument, pdf: PDFDocument) {
        self.document = document; self.pdf = pdf
        for (name, key, beginning) in [(Notification.Name.PDFViewAnnotationWillHit, "PDFAnnotationWillHit", true),
                                       (.PDFViewAnnotationHit, "PDFAnnotationHit", false)] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self, let view = note.object as? PDFView, view.document === self.pdf,
                      let annotation = note.userInfo?[key] as? PDFAnnotation, annotation.type == "Widget" else { return }
                let id = ObjectIdentifier(annotation)
                if beginning { self.nativeWidgets.insert(id) }
                else { DispatchQueue.main.async { [weak self] in self?.nativeWidgets.remove(id) } }
            })
        }
        for index in 0..<pdf.pageCount {
            for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                annotations.append(annotation)
                values[ObjectIdentifier(annotation)] = Value(annotation)
                if annotation.widgetFieldType == .button {
                    observations.append(annotation.observe(\.buttonWidgetStateString, options: [.new]) { [weak self] item, _ in
                        self?.changed(item)
                    })
                    observations.append(annotation.observe(\.buttonWidgetState, options: [.new]) { [weak self] item, _ in
                        self?.changed(item)
                    })
                } else {
                    observations.append(annotation.observe(\.widgetStringValue, options: [.new]) { [weak self] item, _ in
                        self?.changed(item)
                    })
                }
            }
        }
    }
    deinit { notifications.forEach { NotificationCenter.default.removeObserver($0) } }
    func synchronize() {
        for annotation in annotations { changed(annotation) }
    }
    private func changed(_ annotation: PDFAnnotation) {
        guard !applying, document.pdf === pdf,
              let old = values[ObjectIdentifier(annotation)] else { return }
        let current = Value(annotation)
        guard current != old else { return }
        guard !pdf.isEncrypted, pdf.allowsFormFieldEntry, !annotation.isReadOnly else {
            apply(old, to: annotation)
            return
        }
        values[ObjectIdentifier(annotation)] = current
        // PDFKit registers semantic edits from its active text widget with
        // PDFView's manager. Registering a second inverse would undo twice.
        let nativeKey = NSApp.currentEvent?.type == .keyDown &&
            (NSApp.currentEvent?.window?.windowController?.document as? PDFReaderDocument) === document
        if document.nativeFormEditorHandlesUndo || nativeWidgets.contains(ObjectIdentifier(annotation)) || nativeKey ||
            document.undoManager?.isUndoing == true || document.undoManager?.isRedoing == true {
            if let page = annotation.page { document.contentChanged(on: page) }
            return
        }
        registerUndo(to: old, annotation: annotation)
    }
    private func registerUndo(to value: Value, annotation: PDFAnnotation) {
        document.withUndoGroup(named: "填写表单") {
            document.undoManager?.registerUndo(withTarget: self) { $0.restore(value, annotation: annotation) }
        }
        if let page = annotation.page { document.contentChanged(on: page) }
    }
    private func restore(_ value: Value, annotation: PDFAnnotation) {
        let inverse = Value(annotation)
        apply(value, to: annotation)
        registerUndo(to: inverse, annotation: annotation)
    }
    private func apply(_ value: Value, to annotation: PDFAnnotation) {
        applying = true
        if let button = value.button, let state = PDFWidgetCellState(rawValue: button) { annotation.buttonWidgetState = state }
        else { annotation.widgetStringValue = value.text }
        values[ObjectIdentifier(annotation)] = Value(annotation)
        applying = false
    }
}
