#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit

@MainActor enum ImagePreservationChecks {
    static func run(root: URL, output: URL, capture: Bool = false) throws {
        for name in ["Academic", "ImagePreservation"] {
            let source = root.appendingPathComponent("Tests/Fixtures/\(name).pdf")
            let data = try Data(contentsOf: source)
            var error: NSError?
            guard let result = APDFCreateImagePreservingDisplay(data, &error), let bytes = result["data"] as? Data,
                  let supported = result["supported"] as? [Bool] else {
                throw IntegrationChecks.Failure(description: "Image-preserving display failed: \(String(describing: error))")
            }
            let expected = name == "Academic" ? [true, true, true] : [true, true, true, true, false]
            print("IMAGE_SUPPORT \(name): \(supported) \(result["reasons"] ?? "")")
            try IntegrationChecks.require(supported == expected, "\(name): image-preserving pages and complex-transparency fallback are explicit")
            let original = PDFDocument(data: data)!, display = PDFDocument(data: bytes)!
            try IntegrationChecks.require(original.pageCount == display.pageCount && original.string == display.string,
                                          "\(name): display copy preserves searchable text")
            for index in 0..<original.pageCount {
                let a = original.page(at: index)!, b = display.page(at: index)!
                try IntegrationChecks.require(a.rotation == b.rotation && a.bounds(for: .cropBox) == b.bounds(for: .cropBox),
                                              "\(name) page \(index+1): display copy preserves rotation and crop geometry")
                if name == "ImagePreservation" {
                    for (label, page) in [("source", a), ("display", b)] {
                        let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .cropBox)
                        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("preservation-\(label)-\(index+1).png"))
                    }
                }
            }
            try bytes.write(to: output.appendingPathComponent("\(name)-image-display.pdf"))
            let after = try Data(contentsOf: source)
            try IntegrationChecks.require(after == data, "\(name): display preparation leaves source bytes untouched")
        }
        guard capture else { return }
        let oldMode = AppearancePreferences.mode, oldStrategy = AppearancePreferences.strategy
        defer { AppearancePreferences.mode = oldMode; AppearancePreferences.strategy = oldStrategy }
        let document = PDFReaderDocument()
        let source = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
        try document.read(from: source, ofType: "com.adobe.pdf")
        document.fileURL = source
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        let controller = document.windowControllers[0] as! ReaderWindowController
        try IntegrationChecks.require(document.pdf!.string == PDFDocument(url: source)!.string,
                                      "Live custom PDF pages retain original selection and search text")
        controller.window!.makeKeyAndOrderFront(nil)
        var metadata: [[String: Any]] = []
        for mode in [ThemeMode.light, .dark] {
            AppearancePreferences.selectReadingTheme(mode)
            let deadline = Date().addingTimeInterval(15)
            while controller.pdfView.imagePreservingRenderer?.isPreparing == true && Date() < deadline { IntegrationChecks.pump(0.05) }
            IntegrationChecks.pump(2)
            let page = document.pdf!.page(at: 0)!, bounds = page.bounds(for: .cropBox)
            func convert(_ rect: NSRect) -> [CGFloat] {
                let r = controller.pdfView.convert(controller.pdfView.convert(rect, from: page), to: nil)
                return [r.minX, r.minY, r.width, r.height]
            }
            let status = try WindowCaptureChecks.capture(controller.window!, to: output.appendingPathComponent("window-\(mode.rawValue).png"))
            metadata.append(["mode": mode.rawValue, "exit_code": status,
                "window_size": [controller.window!.frame.width, controller.window!.frame.height],
                "page_margin_sample": convert(NSRect(x: bounds.maxX-20, y: bounds.midY-10, width: 10, height: 20)),
                "image_sample": convert(NSRect(x: 353, y: 343, width: 186, height: 122))])
            print("IMAGE_WINDOW: \(mode.rawValue), pageClass=\(type(of: page)), reason=\(controller.pdfView.imagePreservingRenderer?.reason(for: 0) ?? "none")")
        }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("screenshots.json"))
        document.close()
    }
}
#endif
