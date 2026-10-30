import PDFKit

final class ImagePreservingPDFDocument: PDFDocument {
    override var pageClass: AnyClass { ImagePreservingPDFPage.self }
    var displayRenderer: ImagePreservingRenderer?
    private let stateLock = NSLock()
    private var dark = false
    var imagePreservingDark: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return dark }
        set { stateLock.lock(); dark = newValue; stateLock.unlock() }
    }
}

final class ImagePreservingPDFPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let owner = document as? ImagePreservingPDFDocument
        let drawn = owner?.imagePreservingDark == true &&
            owner?.displayRenderer?.draw(index: owner!.index(for: self), box: box, in: context) == true
        if !drawn {
            guard let owner, owner.displayRenderer?.drawOriginal(index: owner.index(for: self), box: box, in: context) == true else {
                super.draw(with: box, to: context); return
            }
        }
        if displaysAnnotations {
            for annotation in annotations where annotation.shouldDisplay {
                annotation.draw(with: box, in: context)
            }
        }
    }
}
