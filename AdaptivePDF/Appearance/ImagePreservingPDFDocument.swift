import PDFKit

final class ImagePreservingPDFDocument: PDFDocument {
    override var pageClass: AnyClass { ImagePreservingPDFPage.self }
    var displayRenderer: ImagePreservingRenderer?
    weak var annotationWriter: PreservingPDFWriter?
    private let stateLock = NSLock()
    private var dark = false
    var imagePreservingDark: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return dark }
        set { stateLock.lock(); dark = newValue; stateLock.unlock() }
    }
}

final class ImagePreservingPDFPage: PDFPage {
    private var editWriter: PreservingPDFWriter? {
        // PDFView tiles draw off the main thread. Annotation identity and edit
        // baselines belong to the same main thread as the editable PDFKit objects.
        Thread.isMainThread ? (document as? ImagePreservingPDFDocument)?.annotationWriter : nil
    }

    override var annotations: [PDFAnnotation] {
        let result = super.annotations
        editWriter?.captureIfNeeded(on: self, annotations: result)
        return result
    }

    override func annotation(at point: NSPoint) -> PDFAnnotation? {
        let result = super.annotation(at: point)
        if result != nil { editWriter?.captureIfNeeded(on: self, annotations: super.annotations) }
        return result
    }

    override func addAnnotation(_ annotation: PDFAnnotation) {
        editWriter?.captureIfNeeded(on: self, annotations: super.annotations)
        super.addAnnotation(annotation)
    }

    override func removeAnnotation(_ annotation: PDFAnnotation) {
        editWriter?.captureIfNeeded(on: self, annotations: super.annotations)
        super.removeAnnotation(annotation)
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        guard let owner = document as? ImagePreservingPDFDocument, let renderer = owner.displayRenderer else {
            super.draw(with: box, to: context)
            return
        }
        let index = owner.index(for: self)
        let drawn = owner.imagePreservingDark && renderer.draw(index: index, box: box, in: context)
        if !drawn && !renderer.drawOriginal(index: index, box: box, in: context) {
            super.draw(with: box, to: context)
            return
        }
        if displaysAnnotations {
            for annotation in super.annotations where annotation.shouldDisplay {
                annotation.draw(with: box, in: context)
            }
        }
    }
}
