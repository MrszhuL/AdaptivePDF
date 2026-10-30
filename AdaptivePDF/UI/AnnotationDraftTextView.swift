import AppKit

/// Draft typing must never enter the PDF document's annotation undo history.
final class AnnotationDraftTextView: NSTextView {
    private let draftHistory = UndoManager()
    override var undoManager: UndoManager? { draftHistory }
}
