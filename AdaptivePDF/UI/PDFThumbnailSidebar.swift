import AppKit
import PDFKit
import CoreImage

/// Uses the reader's display document rather than PDFKit's original-only
/// thumbnail cache. Only visible rows are rendered, with a bounded bitmap cache.
final class PDFThumbnailSidebar: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    weak var pdfView: ReaderPDFView? { didSet { reloadDocument() } }
    private struct Request {
        let operation: BlockOperation
        var viewportOnly: Bool
    }
    private let images = NSCache<NSNumber, NSImage>()
    private let queue = OperationQueue()
    private var pending: [Int: Request] = [:]
    private var pageSizes: [Int: NSSize] = [:]
    private var viewport: NSRange?
    private var viewportUpdateScheduled = false
    private var selecting = false
    private var appearanceKey = ""
    private static let colorContext = CIContext()

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        borderType = .noBorder
        drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("page")))
        table.headerView = nil
        table.rowHeight = 244
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("页面缩略图")
        table.setAccessibilityIdentifier("pageThumbnails")
        documentView = table
        images.countLimit = 48
        images.totalCostLimit = 16 * 1024 * 1024
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleViewportUpdate),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit {
        queue.cancelAllOperations()
        NotificationCenter.default.removeObserver(self)
    }

    func reloadDocument() {
        pageSizes.removeAll()
        reload()
    }

    func updateReadingAppearance() {
        let key = "\(pdfView?.preservingDarkActive == true)-\(pdfView?.basicDarkActive == true)"
        guard key != appearanceKey else { return }
        appearanceKey = key
        reload()
    }

    func reload() {
        queue.cancelAllOperations()
        pending.removeAll()
        images.removeAllObjects()
        selecting = true
        table.reloadData()
        selecting = false
        selectCurrentPage()
        viewport = nil
        scheduleViewportUpdate()
    }

    func invalidatePage(_ index: Int) {
        pending.removeValue(forKey: index)?.operation.cancel()
        images.removeObject(forKey: NSNumber(value: index))
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThumbnailCell {
            cell.preview.image = nil
        }
        viewport = nil
        scheduleViewportUpdate()
    }

    @objc func scheduleViewportUpdate() {
        guard !viewportUpdateScheduled else { return }
        viewportUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportUpdateScheduled = false
            self.updateViewport()
        }
    }

    private func updateViewport() {
        let visible = isHiddenOrHasHiddenAncestor ? NSRange(location: 0, length: 0) : table.rows(in: table.visibleRect)
        guard viewport != visible else { return }
        viewport = visible
        let obsolete = pending.compactMap { index, request in
            request.viewportOnly && !NSLocationInRange(index, visible) ? index : nil
        }
        for index in obsolete { pending.removeValue(forKey: index)?.operation.cancel() }
        guard visible.length > 0 else { return }
        for row in visible.location..<NSMaxRange(visible) {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailCell,
               cell.preview.image == nil {
                cell.preview.image = image(forPage: row, viewportOnly: true)
            }
        }
    }

    func selectCurrentPage() {
        guard let view = pdfView, let pdf = view.document, let page = view.currentPage else { return }
        let index = pdf.index(for: page)
        guard index != NSNotFound, index < table.numberOfRows, table.selectedRow != index else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        selecting = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pdfView?.document?.pageCount ?? 0 }

    private func previewSize(_ index: Int) -> NSSize {
        if let size = pageSizes[index] { return size }
        guard let view = pdfView, let page = view.document?.page(at: index) else { return NSSize(width: 144,height: 188) }
        let bounds = page.pageRef?.getBoxRect(view.displayBox.cgBox) ?? page.bounds(for: view.displayBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? NSSize(width: bounds.height,height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0 else { return NSSize(width: 144,height: 188) }
        let factor = min(144 / size.width,188 / size.height)
        let preview = NSSize(width: size.width * factor,height: size.height * factor)
        pageSizes[index] = preview
        return preview
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ReaderSelectionRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("thumbnail"), owner: self) as? ThumbnailCell) ?? ThumbnailCell()
        cell.identifier = .init("thumbnail")
        let label = pdfView?.document?.page(at: row)?.label ?? "\(row + 1)"
        cell.pageLabel.stringValue = "第 \(label) 页"
        cell.setSelected(row == table.selectedRow)
        cell.setPreviewSize(previewSize(row))
        cell.setAccessibilityLabel("第 \(row + 1) 页")
        cell.preview.image = isHiddenOrHasHiddenAncestor ? nil : image(forPage: row, viewportOnly: true)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { _, row in
            (self.table.view(atColumn: 0,row: row,makeIfNecessary: false) as? ThumbnailCell)?.setSelected(row == self.table.selectedRow)
        }
        guard !selecting, table.selectedRow >= 0,
              let page = pdfView?.document?.page(at: table.selectedRow) else { return }
        pdfView?.go(to: page)
    }

    /// Also used when a recycled row returns to the viewport.
    func image(forPage index: Int) -> NSImage? {
        image(forPage: index, viewportOnly: false)
    }

    private func image(forPage index: Int, viewportOnly: Bool) -> NSImage? {
        if let image = images.object(forKey: NSNumber(value: index)) { return image }
        if pending[index] != nil {
            if !viewportOnly { pending[index]?.viewportOnly = false }
            return nil
        }
        guard let view = pdfView, let pdf = view.document,
              index >= 0, index < pdf.pageCount, let renderer = view.imagePreservingRenderer else { return nil }
        let dark = view.preservingDarkActive, basic = view.basicDarkActive
        if dark && !renderer.hasPrepared(index: index) {
            view.prepareDarkPages(near: index)
            return nil
        }
        let box = view.displayBox
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let operation = BlockOperation()
        pending[index] = Request(operation: operation, viewportOnly: viewportOnly)
        operation.addExecutionBlock { [weak self, weak operation, weak pdf] in
            guard let operation, !operation.isCancelled else { return }
            let bitmap = renderer.thumbnail(index: index, box: box, maxSize: NSSize(width: 144, height: 188), scale: scale, dark: dark)
            DispatchQueue.main.async { [weak self, weak pdf] in
                guard let self, self.pending[index]?.operation === operation, !operation.isCancelled,
                      self.pdfView?.document === pdf else { return }
                self.pending.removeValue(forKey: index)
                guard let page = pdf?.page(at: index) else { return }
                // Password-unlocked PDFKit pages cannot share their decrypted
                // source with Core Graphics; retain their native original preview.
                let fallback = bitmap == nil ? page.thumbnail(of: NSSize(width: 144 * scale, height: 188 * scale), for: box)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
                guard let pixels = bitmap ?? fallback else { return }
                let image = Self.addAnnotations(to: pixels, page: page, box: box, basic: basic, scale: scale, includeAnnotations: bitmap != nil)
                self.images.setObject(image, forKey: NSNumber(value: index), cost: pixels.bytesPerRow * pixels.height)
                if let cell = self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThumbnailCell {
                    cell.preview.image = image
                }
            }
        }
        queue.addOperation(operation)
        return nil
    }

    private static func addAnnotations(to bitmap: CGImage, page: PDFPage, box: PDFDisplayBox,
                                       basic: Bool, scale: CGFloat, includeAnnotations: Bool) -> NSImage {
        var result = bitmap
        if let context = CGContext(data: nil, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let target = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
            context.draw(bitmap, in: target)
            if includeAnnotations, page.displaysAnnotations, let ref = page.pageRef {
                context.concatenate(ref.getDrawingTransform(box.cgBox, rect: target, rotate: 0, preserveAspectRatio: true))
                for annotation in page.annotations where annotation.shouldDisplay {
                    annotation.draw(with: box, in: context)
                }
            }
            result = context.makeImage() ?? bitmap
        }
        if basic, let filter = AppearancePreferences.basicDarkFilter() {
            filter.setValue(CIImage(cgImage: result), forKey: kCIInputImageKey)
            if let output = filter.outputImage,
               let filtered = colorContext.createCGImage(output, from: output.extent) { result = filtered }
        }
        return NSImage(cgImage: result, size: NSSize(width: CGFloat(result.width) / scale, height: CGFloat(result.height) / scale))
    }
}

private final class ThumbnailCell: NSTableCellView {
    let preview = NSImageView()
    let pageLabel = NSTextField(labelWithString: "")
    private var previewWidth: NSLayoutConstraint!
    private var previewHeight: NSLayoutConstraint!
    private var previewTop: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        preview.imageScaling = .scaleProportionallyDown
        preview.wantsLayer = true
        preview.layer?.shadowColor = NSColor.black.cgColor
        preview.layer?.shadowOpacity = 0.20
        preview.layer?.shadowRadius = 6
        preview.layer?.shadowOffset = CGSize(width: 0,height: -2)
        preview.layer?.borderWidth = 0.7
        preview.layer?.cornerRadius = 2
        pageLabel.alignment = .center
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11,weight: .medium)
        pageLabel.textColor = .secondaryLabelColor
        for view in [preview, pageLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        previewWidth = preview.widthAnchor.constraint(equalToConstant: 144)
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 188)
        previewTop = preview.topAnchor.constraint(equalTo: topAnchor, constant: 14)
        NSLayoutConstraint.activate([
            preview.centerXAnchor.constraint(equalTo: centerXAnchor),
            previewTop,
            previewWidth, previewHeight,
            pageLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 11),
            pageLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            preview.layer?.borderColor = ReaderStyle.border.cgColor
        }
    }
    func setSelected(_ selected: Bool) {
        pageLabel.textColor = selected ? .controlAccentColor : .secondaryLabelColor
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11,weight: selected ? .semibold : .regular)
    }
    func setPreviewSize(_ size: NSSize) {
        previewWidth.constant = size.width; previewHeight.constant = size.height
        previewTop.constant = 14 + (188 - size.height) / 2
    }
}

extension PDFDisplayBox {
    var cgBox: CGPDFBox {
        switch self {
        case .mediaBox: return .mediaBox
        case .bleedBox: return .bleedBox
        case .trimBox: return .trimBox
        case .artBox: return .artBox
        default: return .cropBox
        }
    }
}
