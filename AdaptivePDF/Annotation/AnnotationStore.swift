import AppKit
import PDFKit

enum HighlightColor: Int, CaseIterable {
    case yellow, green, blue, pink
    var title: String { ["黄色", "绿色", "蓝色", "粉色"][rawValue] }
    var color: NSColor {
        // Opaque annotation colors: PDF's highlight blend handles transparency.
        switch self {
        case .yellow: return NSColor(srgbRed: 1, green: 0.86, blue: 0.16, alpha: 1)
        case .green: return NSColor(srgbRed: 0.35, green: 0.90, blue: 0.42, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.35, green: 0.72, blue: 1, alpha: 1)
        case .pink: return NSColor(srgbRed: 1, green: 0.48, blue: 0.72, alpha: 1)
        }
    }
}

struct AnnotationEntry {
    let annotation: PDFAnnotation
    let page: PDFPage
    let pageIndex: Int
    var excerpt: String {
        // Use standard QuadPoints to avoid extracting inter-line / column gaps.
        guard ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(annotation.type ?? "") else {
            return annotation.reviewTitle
        }
        let points = annotation.quadrilateralPoints ?? []
        var lines: [String] = []
        for offset in stride(from: 0, to: points.count - points.count % 4, by: 4) {
            let quad = points[offset..<offset + 4].map { $0.pointValue }
            let xs = quad.map(\.x), ys = quad.map(\.y)
            let origin = annotation.bounds.origin
            let rect = NSRect(x: (xs.min() ?? 0) + origin.x, y: (ys.min() ?? 0) + origin.y,
                              width: (xs.max() ?? 0) - (xs.min() ?? 0),
                              height: (ys.max() ?? 0) - (ys.min() ?? 0))
            if let text = page.selection(for: rect)?.string { lines.append(text) }
        }
        return lines.isEmpty ? (page.selection(for: annotation.bounds)?.string ?? "高亮") : lines.joined(separator: " ")
    }
}

/// All geometry stays in PDF page space. PDFView handles crop boxes and rotation.
enum AnnotationStore {
    static func entries(in pdf: PDFDocument) -> [AnnotationEntry] {
        (0..<pdf.pageCount).flatMap { index -> [AnnotationEntry] in
            guard let page = pdf.page(at: index) else { return [] }
            return entries(on: page, pageIndex: index)
        }
    }

    static func entries(on page: PDFPage, pageIndex: Int) -> [AnnotationEntry] {
        page.annotations.filter(\.isReviewAnnotation)
            .sorted {
                if abs($0.bounds.midY - $1.bounds.midY) < 1 { return $0.bounds.minX < $1.bounds.minX }
                return $0.bounds.midY > $1.bounds.midY
            }
            .map { AnnotationEntry(annotation: $0, page: page, pageIndex: pageIndex) }
    }

    static func highlights(for selection: PDFSelection, color: NSColor) -> [(PDFPage, PDFAnnotation)] {
        selection.pages.compactMap { page in
            guard let document = page.document else { return nil }
            // Ask PDFKit for page-specific character ranges first; a selection can
            // cross pages. Each line gets a quad, never one big rectangular band.
            let pageSelection = PDFSelection(document: document)
            for index in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: index, on: page)
                if let fragment = page.selection(for: range) { pageSelection.add(fragment) }
            }
            let boxes = pageSelection.selectionsByLine().map { $0.bounds(for: page) }
                .filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
            guard let first = boxes.first else { return nil }
            let bounds = boxes.dropFirst().reduce(first) { $0.union($1) }
            let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            mark.color = color
            mark.quadrilateralPoints = boxes.flatMap { rect in
                [NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
                 NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY)]
                    .map { NSValue(point: NSPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
            }
            mark.modificationDate = Date()
            mark.userName = NSFullUserName()
            return (page, mark)
        }
    }

    static func note(at point: NSPoint, on page: PDFPage, text: String) -> PDFAnnotation {
        let box = page.bounds(for: .cropBox)
        let size: CGFloat = 24
        let bounds = NSRect(x: min(max(point.x, box.minX), box.maxX - size),
                            y: min(max(point.y, box.minY), box.maxY - size), width: size, height: size)
        let note = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        note.iconType = .note
        note.color = HighlightColor.yellow.color
        note.contents = text
        note.userName = NSFullUserName()
        note.modificationDate = Date()
        return note
    }
}

extension PDFAnnotation {
    /// Links, form widgets and popup children are navigation/UI objects rather
    /// than independent review entries. All other annotation subtypes are listed.
    var isReviewAnnotation: Bool {
        guard let type else { return false }
        return !["Link", "Widget", "Popup"].contains(type)
    }
    var reviewTitle: String {
        ["Highlight": "高亮", "Text": "便签", "Underline": "下划线", "StrikeOut": "删除线",
         "Squiggly": "波浪线", "FreeText": "文本框", "Ink": "墨迹", "Square": "矩形",
         "Circle": "椭圆", "Line": "线条", "Stamp": "图章", "Caret": "插入标记",
         "Polygon": "多边形", "PolyLine": "折线", "Redact": "遮盖标记"][type ?? ""] ?? (type ?? "批注")
    }
    var allowsReviewEditing: Bool {
        let flags = (value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        // ReadOnly, Locked, LockedContents. Keep externally locked annotations
        // visible while conservatively preventing any edit or deletion.
        return isReviewAnnotation && flags & (64 | 128 | 512) == 0
    }
}
