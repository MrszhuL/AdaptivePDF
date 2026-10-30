import AppKit
import PDFKit

/// PDFKit remains responsible for standard annotation appearance generation.
/// qpdf merges only those annotation objects into the untouched source graph.
/// The original page content/font/image objects never pass through a graphics
/// context or PDFKit's whole-document serializer.
final class PreservingPDFWriter {
    private struct State: Equatable {
        let type: String?
        let bounds: NSRect
        let contents: String?
        let author: String?
        let date: Date?
        let rgba: [CGFloat]
        let quads: [NSPoint]
        let field: String?
        let button: Int?
        init(_ annotation: PDFAnnotation) {
            type = annotation.type; bounds = annotation.bounds
            contents = annotation.contents; author = annotation.userName; date = annotation.modificationDate
            if let color = annotation.color.usingColorSpace(.sRGB) {
                rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            } else { rgba = [] }
            quads = (annotation.quadrilateralPoints ?? []).map(\.pointValue)
            field = annotation.type == "Widget" ? annotation.widgetStringValue : nil
            button = annotation.type == "Widget" && annotation.widgetFieldType == .button ? annotation.buttonWidgetState.rawValue : nil
        }
    }
    private struct Original {
        // Retain identity even after deletion, including across undo/redo.
        let annotation: PDFAnnotation
        let state: State
        let page: Int
        let index: Int
    }
    private let source: Data
    private var originals: [[Original]] = []
    private var identities: [ObjectIdentifier: Original] = [:]

    init(source: Data, pdf: PDFDocument) {
        self.source = source
        for pageIndex in 0..<pdf.pageCount {
            let annotations = pdf.page(at: pageIndex)?.annotations ?? []
            let entries = annotations.enumerated().map { index, annotation in
                Original(annotation: annotation, state: State(annotation), page: pageIndex, index: index)
            }
            originals.append(entries)
            for entry in entries { identities[ObjectIdentifier(entry.annotation)] = entry }
        }
    }
    private func descriptor(_ annotation: PDFAnnotation) -> [String: Any] {
        let box = annotation.bounds
        return ["type": annotation.type ?? "", "bounds": [box.minX, box.minY, box.maxX, box.maxY],
                "contents": annotation.contents as Any? ?? NSNull()]
    }
    func data(for pdf: PDFDocument) throws -> Data {
        guard pdf.pageCount == originals.count else { throw ReaderError.serialization }
        let shadow = PDFDocument()
        var plans: [Any] = []
        var changed = false
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { throw ReaderError.serialization }
            let current = page.annotations
            let baseline = originals[pageIndex]
            let unchanged = current.count == baseline.count && zip(current, baseline).allSatisfy {
                $0.0 === $0.1.annotation && State($0.0) == $0.1.state
            }
            if unchanged { plans.append(NSNull()); continue }
            changed = true
            var currentPlan: [[String: Any]] = []
            var shadowPage: PDFPage?
            var copies: [(Int, PDFAnnotation)] = []
            for annotation in current {
                let original = identities[ObjectIdentifier(annotation)]
                var item = descriptor(annotation)
                item["originalPage"] = original?.page ?? pageIndex
                item["originalIndex"] = original?.index ?? -1
                item["keepOriginalBounds"] = original?.state.bounds == annotation.bounds
                if original == nil || original?.page != pageIndex || State(annotation) != original?.state {
                    if shadowPage == nil {
                        let blank = PDFPage()
                        blank.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
                        blank.setBounds(page.bounds(for: .cropBox), for: .cropBox)
                        blank.rotation = page.rotation
                        shadow.insert(blank, at: shadow.pageCount)
                        shadowPage = blank
                    }
                    guard let copy = annotation.copy() as? PDFAnnotation else { throw ReaderError.serialization }
                    shadowPage!.addAnnotation(copy)
                    item["shadowPage"] = shadow.pageCount - 1
                    copies.append((currentPlan.count, copy))
                }
                currentPlan.append(item)
            }
            if let shadowPage {
                for (index, copy) in copies {
                    guard let slot = shadowPage.annotations.firstIndex(where: { $0 === copy }) else { throw ReaderError.serialization }
                    currentPlan[index]["shadowIndex"] = slot
                }
            }
            plans.append(["original": baseline.map { descriptor($0.annotation) }, "current": currentPlan])
        }
        if !changed { return source }
        // A deleted original's live object can have been edited since loading;
        // baseline validation must use the original coordinates, never its new ones.
        for index in plans.indices {
            guard var plan = plans[index] as? [String: Any] else { continue }
            plan["original"] = originals[index].map { entry in
                ["type": entry.state.type ?? "", "bounds": [entry.state.bounds.minX, entry.state.bounds.minY,
                                                             entry.state.bounds.maxX, entry.state.bounds.maxY],
                 "contents": entry.state.contents as Any? ?? NSNull()] as [String: Any]
            }
            plans[index] = plan
        }
        let annotationData: Data
        if shadow.pageCount > 0 {
            guard let data = shadow.dataRepresentation() else { throw ReaderError.serialization }
            annotationData = data
        } else { annotationData = Data() }
        var failure: NSError?
        guard let result = APDFWritePreservingContent(source, annotationData, plans, &failure) else {
            throw failure ?? NSError(domain: "AdaptivePDF.Preservation", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: ReaderError.serialization.localizedDescription])
        }
        return result
    }
}
