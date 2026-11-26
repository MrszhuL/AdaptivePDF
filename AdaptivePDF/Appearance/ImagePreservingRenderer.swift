import AppKit
import PDFKit

/// A bounded vector display copy. Original PDFKit pages still own selection,
/// search, annotations and saving. No full-page raster cache is constructed.
final class ImagePreservingRenderer {
    private struct Batch {
        let pages: Range<Int>
        let document: CGPDFDocument?
        let supported: [Bool]
        let reasons: [String]
        let failure: String?
        let byteCount: Int
    }

    private let source: Data
    private let pageCount: Int
    private let pagesPerBatch: Int
    private let unavailableReason: String?
    private lazy var original = CGDataProvider(data: source as CFData).flatMap { CGPDFDocument($0) }
    private static let displayQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private let originalDrawingLock = NSLock()
    private let darkDrawingLock = NSLock()
    private var preparation: (pages: Range<Int>, operation: BlockOperation)?
    private var batches: [Batch] = []
    private var readerPages: Range<Int>?
    deinit { preparation?.operation.cancel() }
    init(source: Data, pageCount: Int, encrypted: Bool) {
        self.source = source
        self.pageCount = pageCount
        unavailableReason = encrypted ? "加密 PDF 保留原色" : nil
        let bytesPerPage = max(1, source.count / max(1, pageCount))
        pagesPerBatch = min(4, max(1, (12 * 1024 * 1024) / bytesPerPage))
    }

    var isPreparing: Bool { lock.lock(); defer { lock.unlock() }; return preparation != nil }
    func hasPrepared(index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unavailableReason != nil || batches.contains(where: { $0.pages.contains(index) })
    }
    func reason(for index: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let unavailableReason { return unavailableReason }
        guard let batch = batches.last(where: { $0.pages.contains(index) }) else { return nil }
        if let failure = batch.failure { return failure }
        let offset = index - batch.pages.lowerBound
        return batch.supported[offset] ? nil : batch.reasons[offset]
    }
    func prepare(near index: Int, forReader: Bool, completion: @escaping (Range<Int>) -> Void) {
        guard unavailableReason == nil, (0..<pageCount).contains(index) else { return }
        let start = index / pagesPerBatch * pagesPerBatch
        let pages = start..<min(pageCount, start + pagesPerBatch + (pagesPerBatch > 1 ? 1 : 0))
        lock.lock()
        if forReader { readerPages = pages }
        if let existing = batches.firstIndex(where: { forReader ? $0.pages == pages : $0.pages.contains(index) }) {
            let batch = batches.remove(at: existing)
            batches.append(batch)
            lock.unlock()
            return
        }
        if let running = preparation {
            if running.pages == pages || !forReader { lock.unlock(); return }
            running.operation.cancel()
        }
        let operation = BlockOperation()
        operation.queuePriority = forReader ? .high : .low
        preparation = (pages, operation)
        lock.unlock()
        let range = pages.count == pageCount ? NSRange(location: 0, length: 0) : NSRange(pages)
        operation.addExecutionBlock { [weak self, weak operation, source] in
            guard let operation, !operation.isCancelled else { return }
            var error: NSError?
            let result = APDFCreateCancellableDisplay(source, range, { operation.isCancelled }, &error)
            guard let self, !operation.isCancelled else { return }
            let bytes = result?["data"] as? NSData
            let provider = bytes.flatMap { CGDataProvider(data: $0 as CFData) }
            let document = provider.flatMap { CGPDFDocument($0) }
            let supported = result?["supported"] as? [Bool] ?? []
            let reasons = result?["reasons"] as? [String] ?? []
            let usable = document?.numberOfPages == pages.count && supported.count == pages.count && reasons.count == pages.count
            let batch = Batch(pages: pages, document: usable ? document : nil, supported: supported, reasons: reasons,
                              failure: usable ? nil : (error?.localizedDescription ?? "无法准备此文档的保色深色页面"),
                              byteCount: usable ? (bytes?.length ?? 0) : 0)
            self.lock.lock()
            guard self.preparation?.operation === operation else { self.lock.unlock(); return }
            self.batches.append(batch)
            while self.batches.count > 1 &&
                (self.batches.count > 3 || self.batches.reduce(0, { $0 + $1.byteCount }) > 96 * 1024 * 1024),
                let oldest = self.batches.dropLast().firstIndex(where: { $0.pages != self.readerPages }) {
                self.batches.remove(at: oldest)
            }
            self.preparation = nil
            self.lock.unlock()
            DispatchQueue.main.async { completion(pages) }
        }
        Self.displayQueue.addOperation(operation)
    }
    func cancelPreparation() {
        lock.lock(); defer { lock.unlock() }
        preparation?.operation.cancel()
        preparation = nil
        readerPages = nil
    }
    /// Serializes access to the immutable Core Graphics display document across
    /// PDFKit's tiled drawing threads. Unsupported pages use original rendering.
    func draw(index: Int, box: PDFDisplayBox, in context: CGContext) -> Bool {
        lock.lock()
        let batch = batches.last(where: { $0.pages.contains(index) })
        lock.unlock()
        guard let batch, let document = batch.document else { return false }
        let offset = index - batch.pages.lowerBound
        guard batch.supported[offset] else { return false }
        darkDrawingLock.lock(); defer { darkDrawingLock.unlock() }
        guard let page = document.page(at: offset+1) else { return false }
        Self.drawPage(page, box: box, in: context)
        return true
    }
    func drawOriginal(index: Int, box: PDFDisplayBox, in context: CGContext) -> Bool {
        originalDrawingLock.lock(); defer { originalDrawingLock.unlock() }
        guard let page = original?.page(at: index+1) else { return false }
        Self.drawPage(page, box: box, in: context, whiteBackground: true)
        return true
    }
    /// The sidebar uses the same original/display vector documents as the page.
    /// Render small images off the main thread; annotations are overlaid on main.
    func thumbnail(index: Int, box: PDFDisplayBox, maxSize: CGSize, scale: CGFloat, dark: Bool) -> CGImage? {
        originalDrawingLock.lock()
        let size = original?.page(at: index + 1).map { page in
            let rect = page.getBoxRect(box.cgBox)
            let rotated = abs(page.rotationAngle) % 180 == 90
            return rotated ? CGSize(width: rect.height, height: rect.width) : rect.size
        }
        originalDrawingLock.unlock()
        guard let size else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }
        let factor = min(maxSize.width / size.width, maxSize.height / size.height) * scale
        let width = max(1, Int((size.width * factor).rounded())), height = max(1, Int((size.height * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        if !dark || !draw(index: index, box: box, in: context) {
            guard drawOriginal(index: index, box: box, in: context) else { return nil }
        }
        return context.makeImage()
    }
    static func drawPage(_ page: CGPDFPage, box: PDFDisplayBox, in context: CGContext, whiteBackground: Bool = false) {
        let cgBox: CGPDFBox
        switch box {
        case .mediaBox: cgBox = .mediaBox
        case .bleedBox: cgBox = .bleedBox
        case .trimBox: cgBox = .trimBox
        case .artBox: cgBox = .artBox
        default: cgBox = .cropBox
        }
        let rect = page.getBoxRect(cgBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let target = CGRect(origin: .zero, size: rotated ? CGSize(width: rect.height, height: rect.width) : rect.size)
        context.saveGState()
        if whiteBackground {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(target)
        }
        context.concatenate(page.getDrawingTransform(cgBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.clip(to: rect)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
