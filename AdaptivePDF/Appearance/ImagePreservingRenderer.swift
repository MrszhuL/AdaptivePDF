import AppKit
import PDFKit

/// A bounded vector display copy. Original PDFKit pages still own selection,
/// search, annotations and saving. No full-page raster cache is constructed.
final class ImagePreservingRenderer {
    private let source: Data
    private let original: CGPDFDocument?
    private let lock = NSRecursiveLock()
    private var preparing = false
    private var attempted = false
    private var rendered: CGPDFDocument?
    private var supported: [Bool] = []
    private var reasons: [String] = []
    private var failure: String?
    private var completions: [() -> Void] = []
    init(source: Data) {
        self.source = source
        original = CGDataProvider(data: source as CFData).flatMap { CGPDFDocument($0) }
    }

    var isPreparing: Bool { lock.lock(); defer { lock.unlock() }; return preparing }
    func reason(for index: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let failure { return failure }
        guard supported.indices.contains(index) else { return nil }
        return supported[index] ? nil : reasons[index]
    }
    func prepare(completion: @escaping () -> Void) {
        lock.lock()
        if attempted {
            if preparing { completions.append(completion); lock.unlock() }
            else { lock.unlock(); DispatchQueue.main.async(execute: completion) }
            return
        }
        attempted = true; preparing = true
        completions.append(completion)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var error: NSError?
            let result = APDFCreateImagePreservingDisplay(source, &error)
            let bytes = result?["data"] as? Data
            let provider = bytes.flatMap { CGDataProvider(data: $0 as CFData) }
            let document = provider.flatMap { CGPDFDocument($0) }
            lock.lock()
            rendered = document
            supported = result?["supported"] as? [Bool] ?? []
            reasons = result?["reasons"] as? [String] ?? []
            if document == nil { failure = error?.localizedDescription ?? "无法准备此文档的保色深色页面" }
            preparing = false
            let callbacks = completions
            completions.removeAll()
            lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0() } }
        }
    }
    /// Serializes access to the immutable Core Graphics display document across
    /// PDFKit's tiled drawing threads. Unsupported pages use original rendering.
    func draw(index: Int, box: PDFDisplayBox, in context: CGContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard supported.indices.contains(index), supported[index], let page = rendered?.page(at: index+1) else { return false }
        Self.drawPage(page, box: box, in: context)
        return true
    }
    func drawOriginal(index: Int, box: PDFDisplayBox, in context: CGContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let page = original?.page(at: index+1) else { return false }
        Self.drawPage(page, box: box, in: context, whiteBackground: true)
        return true
    }
    /// The sidebar uses the same original/display vector documents as the page.
    /// Render small images off the main thread; annotations are overlaid on main.
    func thumbnail(index: Int, box: PDFDisplayBox, maxSize: CGSize, scale: CGFloat, dark: Bool) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let page = original?.page(at: index + 1) else { return nil }
        let rect = page.getBoxRect(box.cgBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width: rect.height, height: rect.width) : rect.size
        guard size.width > 0, size.height > 0 else { return nil }
        let factor = min(maxSize.width / size.width, maxSize.height / size.height) * scale
        let width = max(1, Int((size.width * factor).rounded())), height = max(1, Int((size.height * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        if !dark || !draw(index: index, box: box, in: context) { _ = drawOriginal(index: index, box: box, in: context) }
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
