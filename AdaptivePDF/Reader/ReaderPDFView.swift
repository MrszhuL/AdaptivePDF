import AppKit
import PDFKit
import UniformTypeIdentifiers

final class ReaderPDFView: PDFView {
    var onAppearanceChanged: (() -> Void)?
    var onAnnotationClicked: ((PDFAnnotation, Bool) -> Void)?
    var onPlaceNote: ((PDFPage, NSPoint) -> Void)?
    var onManualZoom: (() -> Void)?
    var placingNote = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private(set) var basicDarkActive = false
    var onRenderingChanged: ((Range<Int>) -> Void)?
    private let renderingLock = NSLock()
    private var renderer: ImagePreservingRenderer?
    private var preserveImages = false
    private weak var appearanceDocument: PDFDocument?
    var imagePreservingRenderer: ImagePreservingRenderer? {
        get { renderingLock.lock(); defer { renderingLock.unlock() }; return renderer }
        set {
            renderingLock.lock()
            let previous = renderer
            renderer = newValue
            renderingLock.unlock()
            if previous !== newValue { previous?.cancelPreparation() }
        }
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
        pageBreakMargins = NSEdgeInsets(top: 0.5,left: 24,bottom: 0.5,right: 24)
        pageShadowsEnabled = false
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
        renderingLock.lock()
        let changed = preserveImages != preserving || basicDarkActive != active || appearanceDocument !== document
        preserveImages = preserving
        renderingLock.unlock()
        appearanceDocument = document
        (document as? ImagePreservingPDFDocument)?.imagePreservingDark = preserving
        basicDarkActive = active
        pageShadowsEnabled = false
        // A compositor filter changes neither PDF objects nor the geometry of
        // selections / hit targets, and needs no full-page bitmap cache.
        if changed { layer?.filters = active ? AppearancePreferences.basicDarkFilter().map { [$0] } : nil }
        // The outside canvas is transformed too, so choose its preimage.
        backgroundColor = active ? NSColor(white: 0.99, alpha: 1) : ReaderStyle.canvas
        if preserving { prepareDarkPages() }
        else { imagePreservingRenderer?.cancelPreparation() }
        guard changed else { return }
        invalidatePageDrawing()
        // PDFKit creates tiled page layers after the first window layout. Mark
        // those newly installed layers too, rather than retaining a blank tile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.invalidatePageDrawing() }
    }

    func prepareDarkPages(near thumbnail: Int? = nil) {
        guard preservingDarkActive, let renderer = imagePreservingRenderer, let document, !document.isLocked else { return }
        let index = thumbnail ?? currentPage.map { document.index(for: $0) } ?? 0
        renderer.prepare(near: index, forReader: thumbnail == nil) { [weak self, weak renderer, weak document] pages in
            guard let self, let document, self.document === document,
                  self.imagePreservingRenderer === renderer, self.preservingDarkActive else { return }
            let visible = self.visiblePages
            if visible.isEmpty || visible.contains(where: { pages.contains(document.index(for: $0)) }) {
                self.invalidatePageDrawing()
            }
            self.onRenderingChanged?(pages)
        }
    }

    /// Window-level dispatch reaches the PDF even when its internal scroll
    /// view owns the event. Inactive windows also receive pointer scrolling.
    func handleZoomScroll(delta: CGFloat, modifiers: NSEvent.ModifierFlags,
                          momentum: NSEvent.Phase, at point: NSPoint) -> Bool {
        let shortcuts: NSEvent.ModifierFlags = [.option, .command, .control, .shift]
        guard modifiers.intersection(shortcuts) == .option, visibleRect.contains(point),
              let document, !document.isLocked, document.pageCount > 0 else { return false }
        if momentum.isEmpty, delta.isFinite, delta != 0 {
            setManualScale(scaleFactor * exp(min(1, max(-1, delta * 0.012))), anchoredAt: point)
        }
        return true
    }

    @discardableResult
    func handlePinch(magnification: CGFloat, at point: NSPoint) -> Bool {
        guard magnification.isFinite, magnification > -1, magnification != 0,
              visibleRect.contains(point), let document, !document.isLocked, document.pageCount > 0 else { return false }
        let previous = scaleFactor
        let scale = min(maxScaleFactor, max(minScaleFactor, previous * (1 + magnification)))
        guard scale != previous else { return false }
        setManualScale(scale, anchoredAt: point)
        return scaleFactor != previous
    }

    func setManualScale(_ scale: CGFloat, anchoredAt point: NSPoint? = nil) {
        guard scale.isFinite, scale > 0 else { return }
        let page = point.flatMap { self.page(for: $0, nearest: true) }
        let anchor = page.flatMap { page in point.map { convert($0, to: page) } }
        onManualZoom?()
        autoScales = false
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, scale))
        if let point, let page, let anchor, let scroll = documentView?.enclosingScrollView {
            let clip = scroll.contentView
            let target = clip.convert(convert(anchor, from: page), from: self)
            let cursor = clip.convert(point, from: self)
            var bounds = clip.bounds
            bounds.origin.x += target.x - cursor.x
            bounds.origin.y += target.y - cursor.y
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }
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
