#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit

@MainActor enum ThumbnailChecks {
    static func run(root: URL, output: URL) async throws {
        let oldMode = AppearancePreferences.mode, oldStrategy = AppearancePreferences.strategy
        let document = PDFReaderDocument()
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
            AppearancePreferences.mode = oldMode
            AppearancePreferences.strategy = oldStrategy
        }
        let source = root.appendingPathComponent("Tests/Fixtures/ImagePreservation.pdf")
        let original = try Data(contentsOf: source)
        AppearancePreferences.selectReadingTheme(.light)
        try document.read(from: source, ofType: "com.adobe.pdf")
        document.fileURL = source; document.fileType = "com.adobe.pdf"
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        let controller = document.windowControllers[0] as! ReaderWindowController
        let sidebar = controller.thumbnails
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func image(_ page: Int) async throws -> NSBitmapImageRep {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let value = sidebar.image(forPage: page), let data = value.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: data) { return rep }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw IntegrationChecks.Failure(description: "Thumbnail \(page + 1) did not finish rendering")
        }
        func paper(_ rep: NSBitmapImageRep) -> CGFloat {
            rep.colorAt(x: 1, y: 1)!.usingColorSpace(.sRGB)!.redComponent
        }
        func write(_ rep: NSBitmapImageRep, _ name: String) throws {
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        }
        func captureSidebar(_ name: String) async throws {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let bitmap = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) else {
                throw IntegrationChecks.Failure(description: "Sidebar has no native drawing surface")
            }
            sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
            try write(bitmap, name)
        }
        var light: [NSBitmapImageRep] = []
        for page in 0..<5 { light.append(try await image(page)) }
        try IntegrationChecks.require(sidebar.table.numberOfRows == 5 && paper(light[0]) > 0.98,
                                      "Light thumbnails show original white pages")
        try await captureSidebar("thumbnail-sidebar-light.png")
        AppearancePreferences.selectReadingTheme(.dark)
        let deadline = Date().addingTimeInterval(20)
        while controller.pdfView.imagePreservingRenderer?.isPreparing == true && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        var dark: [NSBitmapImageRep] = []
        for page in 0..<5 { dark.append(try await image(page)) }
        try IntegrationChecks.require(paper(dark[0]) > 0.05 && paper(dark[0]) < 0.25,
                                      "Dark thumbnail paper follows the reader's dark display document")
        try IntegrationChecks.require(paper(dark[4]) > 0.98,
                                      "Unsupported transparency retains original thumbnail appearance")
        try IntegrationChecks.require(dark[3].pixelsWide > dark[3].pixelsHigh && light[3].pixelsWide == dark[3].pixelsWide,
                                      "Cropped rotated thumbnails preserve landscape geometry")
        // Sample the same nine image interiors as the independent full-page test.
        let regions: [Int: [CGRect]] = [
            0: [CGRect(x: 60,y: 480,width: 240,height: 160), CGRect(x: 320,y: 480,width: 240,height: 160),
                CGRect(x: 60,y: 260,width: 240,height: 160), CGRect(x: 320,y: 260,width: 240,height: 160)],
            1: [CGRect(x: 60,y: 480,width: 240,height: 160), CGRect(x: 320,y: 260,width: 240,height: 160)],
            2: [CGRect(x: 60,y: 480,width: 240,height: 160), CGRect(x: 400,y: 300,width: 80,height: 80)],
            3: [CGRect(x: 450,y: 290,width: 160,height: 240)]
        ]
        var comparisons: [[String: Any]] = []
        for page in 0..<5 {
            try write(light[page], "thumbnail-light-\(page + 1).png")
            try write(dark[page], "thumbnail-dark-\(page + 1).png")
            for region in regions[page] ?? [] {
                let a = light[page], b = dark[page]
                let size = page == 3 ? CGSize(width: 730, height: 570) : CGSize(width: 612, height: 792)
                let sx = CGFloat(a.pixelsWide) / size.width, sy = CGFloat(a.pixelsHigh) / size.height
                let rect = region.insetBy(dx: 8, dy: 8)
                let xs = Int(ceil(rect.minX * sx))..<Int(floor(rect.maxX * sx))
                let ys = Int(ceil((size.height - rect.maxY) * sy))..<Int(floor((size.height - rect.minY) * sy))
                var difference: CGFloat = 0
                for y in ys { for x in xs {
                    let ca = a.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!, cb = b.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    difference += abs(ca.redComponent-cb.redComponent) + abs(ca.greenComponent-cb.greenComponent) + abs(ca.blueComponent-cb.blueComponent)
                } }
                let mean = difference * 255 / CGFloat(xs.count * ys.count * 3)
                try IntegrationChecks.require(mean < 0.5, "Thumbnail page \(page + 1): embedded image retains original colors")
                comparisons.append(["page": page + 1, "mean_absolute_channel_difference": mean])
            }
        }
        sidebar.selectCurrentPage()
        try await captureSidebar("thumbnail-sidebar-dark.png")
        if let cell = sidebar.table.view(atColumn: 0, row: 0, makeIfNecessary: true),
           let preview = cell.subviews.compactMap({ $0 as? NSImageView }).first, let value = preview.image {
            try IntegrationChecks.require(value === sidebar.image(forPage: 0), "Visible native thumbnail cell uses the themed bitmap")
        } else { throw IntegrationChecks.Failure(description: "Visible thumbnail image is missing") }
        controller.pdfView.go(to: document.pdf!.page(at: 3)!)
        try await Task.sleep(nanoseconds: 100_000_000)
        try IntegrationChecks.require(sidebar.table.selectedRow == 3, "Reader navigation selects the matching thumbnail")
        sidebar.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        try IntegrationChecks.require(controller.pdfView.currentPage === document.pdf!.page(at: 1), "Selecting a thumbnail navigates to its page")
        let page = document.pdf!.page(at: 0)!
        let mark = PDFAnnotation(bounds: CGRect(x: 20,y: 690,width: 100,height: 60), forType: .square, withProperties: nil)
        mark.color = .red; mark.interiorColor = .red
        page.addAnnotation(mark); document.contentChanged(on: page)
        let annotated = try await image(0)
        let color = annotated.colorAt(x: Int(CGFloat(annotated.pixelsWide) * 70 / 612), y: Int(CGFloat(annotated.pixelsHigh) * 72 / 792))!.usingColorSpace(.sRGB)!
        try IntegrationChecks.require(color.redComponent > 0.85 && color.greenComponent < 0.2, "Annotation edits refresh the thumbnail overlay")
        page.removeAnnotation(mark); document.contentChanged(on: page)
        AppearancePreferences.strategy = .original
        let originalThumbnail = try await image(0)
        try IntegrationChecks.require(paper(originalThumbnail) > 0.98, "Original strategy restores white thumbnails while chrome remains dark")
        AppearancePreferences.strategy = .basic
        let basicThumbnail = try await image(0)
        try IntegrationChecks.require(abs(paper(basicThumbnail) - paper(dark[0])) < 0.02, "Explicit Basic Dark also applies to thumbnails")
        // An old worker must not repaint a newly selected light theme or document.
        AppearancePreferences.selectReadingTheme(.dark)
        AppearancePreferences.selectReadingTheme(.light)
        let latest = try await image(0)
        try IntegrationChecks.require(paper(latest) > 0.98, "Rapid theme changes discard stale dark thumbnail results")
        let saved = try document.data(ofType: "com.adobe.pdf")
        try IntegrationChecks.require(saved == original,
                                      "Thumbnail drawing and annotation removal preserve source PDF bytes")
        let replacement = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
        try document.read(from: replacement, ofType: "com.adobe.pdf")
        let replacedThumbnail = try await image(0)
        try IntegrationChecks.require(sidebar.table.numberOfRows == 3 && paper(replacedThumbnail) > 0.98,
                                      "Replacing the document discards old thumbnail rows and cached images")
        let encrypted = PDFReaderDocument()
        try encrypted.read(from: root.appendingPathComponent("Tests/Fixtures/Encrypted.pdf"), ofType: "com.adobe.pdf")
        let unlocked = encrypted.pdf!.unlock(withPassword: "reader")
        try IntegrationChecks.require(unlocked, "Encrypted thumbnail fixture unlocks without retaining its password")
        encrypted.makeWindowControllers(); encrypted.showWindows()
        let encryptedSidebar = (encrypted.windowControllers[0] as! ReaderWindowController).thumbnails
        let encryptedDeadline = Date().addingTimeInterval(10)
        while encryptedSidebar.image(forPage: 0) == nil && Date() < encryptedDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try IntegrationChecks.require(encryptedSidebar.image(forPage: 0) != nil, "Unlocked encrypted pages retain native original thumbnails")
        encrypted.close()
        try JSONSerialization.data(withJSONObject: ["status": "passed", "image_pixel_checks": comparisons], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("thumbnails.json"))
    }
}
#endif
