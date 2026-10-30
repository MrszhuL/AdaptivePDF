import AppKit
import PDFKit
import UniformTypeIdentifiers

final class ReaderPDFView: PDFView {
    var onAppearanceChanged: (() -> Void)?
    var onAnnotationClicked: ((PDFAnnotation, Bool) -> Void)?
    var onPlaceNote: ((PDFPage, NSPoint) -> Void)?
    var onNoteModeChanged: (() -> Void)?
    var placingNote = false {
        didSet { window?.invalidateCursorRects(for: self); onNoteModeChanged?() }
    }
    private(set) var basicDarkActive = false
    var onRenderingChanged: (() -> Void)?
    private let renderingLock = NSLock()
    private var renderer: ImagePreservingRenderer?
    private var preserveImages = false
    var imagePreservingRenderer: ImagePreservingRenderer? {
        get { renderingLock.lock(); defer { renderingLock.unlock() }; return renderer }
        set { renderingLock.lock(); renderer = newValue; renderingLock.unlock() }
    }
    var preservingDarkActive: Bool {
        renderingLock.lock(); defer { renderingLock.unlock() }; return preserveImages
    }

    override var undoManager: UndoManager? {
        (window?.windowController?.document as? PDFReaderDocument)?.undoManager ?? super.undoManager
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoScales = true
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 20,left: 24,bottom: 20,right: 24)
        minScaleFactor = 0.10
        maxScaleFactor = 8
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    func applyReadingAppearance(dark: Bool, strategy: DarkStrategy) {
        let active = dark && strategy == .basic
        let preserving = dark && strategy == .preserveImages
        renderingLock.lock(); preserveImages = preserving; renderingLock.unlock()
        (document as? ImagePreservingPDFDocument)?.imagePreservingDark = preserving
        basicDarkActive = active
        pageShadowsEnabled = !(active || preserving)
        // A compositor filter changes neither PDF objects nor the geometry of
        // selections / hit targets, and needs no full-page bitmap cache.
        layer?.filters = active ? AppearancePreferences.basicDarkFilter().map { [$0] } : nil
        // The outside canvas is transformed too, so choose its preimage.
        backgroundColor = active ? NSColor(white: 0.99, alpha: 1) : ReaderStyle.canvas
        if preserving {
            imagePreservingRenderer?.prepare { [weak self] in
                self?.invalidatePageDrawing()
                self?.onRenderingChanged?()
            }
        }
        invalidatePageDrawing()
        // PDFKit creates tiled page layers after the first window layout. Mark
        // those newly installed layers too, rather than retaining a blank tile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.invalidatePageDrawing() }
    }

    private func invalidatePageDrawing() {
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            for child in view.subviews { invalidate(child) }
        }
        func invalidateLayer(_ layer: CALayer) {
            layer.setNeedsDisplay()
            for child in layer.sublayers ?? [] { invalidateLayer(child) }
        }
        invalidate(self)
        if let layer { invalidateLayer(layer) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if placingNote { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, placingNote { placingNote = false; return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false) {
            let location = convert(point, to: page)
            if placingNote {
                placingNote = false
                onPlaceNote?(page, location)
                return
            }
            if let annotation = page.annotations.reversed().first(where: {
                Self.annotation($0, contains: location)
            }) {
                onAnnotationClicked?(annotation, event.clickCount == 2 || annotation.type == "Text")
                // Highlight single-click still starts native text selection.
                if annotation.type == "Text" || event.clickCount == 2 { return }
            }
        }
        super.mouseDown(with: event)
    }

    private static func annotation(_ annotation: PDFAnnotation, contains point: NSPoint) -> Bool {
        guard annotation.isReviewAnnotation else { return false }
        guard annotation.bounds.contains(point) else { return false }
        guard annotation.type == "Highlight", let quads = annotation.quadrilateralPoints, quads.count >= 4 else { return true }
        let local = NSPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
        for offset in stride(from: 0, to: quads.count - quads.count % 4, by: 4) {
            let points = quads[offset..<offset + 4].map { $0.pointValue }
            let path = NSBezierPath()
            path.move(to: points[0]); path.line(to: points[1])
            path.line(to: points[3]); path.line(to: points[2]); path.close()
            if path.contains(local) { return true }
        }
        return false
    }

    private func draggedPDFs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.pdf.identifier]
        ]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedPDFs(sender).isEmpty ? [] : .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggedPDFs(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedPDFs(sender)
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        return !urls.isEmpty
    }
}
