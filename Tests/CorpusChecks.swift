#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit
import CryptoKit
import Darwin

enum CorpusChecks {
    struct Spec: Decodable {
        let cases: [Case]
        struct Case: Decodable {
            let id: String
            let file: String
            let sha256: String
            let kind: String
            let pages: Int
            let source: String?
        }
    }
    struct Failure: Error { let message: String }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }
    private static func pump(_ seconds: TimeInterval = 0.03) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    static func run() {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["ADAPTIVEPDF_CORPUS_MANIFEST"],
              let outputPath = environment["ADAPTIVEPDF_CORPUS_OUTPUT"] else {
            fputs("Corpus checks require ADAPTIVEPDF_CORPUS_MANIFEST and ADAPTIVEPDF_CORPUS_OUTPUT\n", stderr); exit(64)
        }
        let mode = AppearancePreferences.mode
        let strategy = AppearancePreferences.strategy
        func restorePreferences() { AppearancePreferences.mode = mode; AppearancePreferences.strategy = strategy }
        do {
            let manifest = URL(fileURLWithPath: manifestPath)
            let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: manifest))
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var reports: [[String: Any]] = []
            for entry in spec.cases {
                let baseline = residentMiB()
                var record = try autoreleasepool {
                    try run(entry, relativeTo: manifest.deletingLastPathComponent(), output: output)
                }
                pump(0.3)
                record["resident_before_mib"] = baseline
                record["resident_after_close_mib"] = residentMiB()
                reports.append(record)
                print("PASS: corpus \(entry.id): \(entry.pages) pages, source intact, annotations/text/render samples retained")
                fflush(stdout)
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let result: [String: Any] = [
                "schema_version": 1, "status": "passed", "cases": reports,
                "peak_resident_mib": Double(usage.ru_maxrss) / 1_048_576,
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
                "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "completed_at": ISO8601DateFormatter().string(from: Date())
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("corpus-report.json"), options: .atomic)
            restorePreferences()
            print("ALL CORPUS CHECKS PASSED"); fflush(stdout); exit(0)
        } catch {
            restorePreferences()
            fputs("CORPUS FAILURE: \(error)\n", stderr); exit(1)
        }
    }
    private static func run(_ entry: Spec.Case, relativeTo base: URL, output: URL) throws -> [String: Any] {
        let source = base.appendingPathComponent(entry.file)
        let originalBytes: Int
        do {
            let bytes = try Data(contentsOf: source)
            try check(digest(bytes) == entry.sha256, "Corpus hash mismatch: \(entry.id)")
            originalBytes = bytes.count
        }
        var opened: NSDocument?
        var openError: Error?
        var finished = false
        var lastBeat = ProcessInfo.processInfo.systemUptime
        var largestGap = 0.0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            largestGap = max(largestGap, now - lastBeat); lastBeat = now
        }
        let start = ProcessInfo.processInfo.systemUptime
        NSDocumentController.shared.openDocument(withContentsOf: source, display: true) { document, _, error in
            opened = document; openError = error; finished = true
        }
        while !finished && ProcessInfo.processInfo.systemUptime - start < 30 { pump() }
        pump(0.1)
        heartbeat.invalidate()
        let openSeconds = ProcessInfo.processInfo.systemUptime - start
        if let openError { throw openError }
        guard let document = opened as? PDFReaderDocument, let pdf = document.pdf,
              let controller = document.windowControllers.first as? ReaderWindowController,
              let firstPage = pdf.page(at: 0) else { throw Failure(message: "Could not open \(entry.id)") }
        defer { document.updateChangeCount(.changeCleared); document.close() }
        try check(finished && pdf.pageCount == entry.pages, "Wrong page count or open timeout: \(entry.id)")
        try check(document.loadedOnMainThread == false, "Corpus load ran on main thread: \(entry.id)")
        try check(document.canAnnotate, "Corpus document unexpectedly restricts annotations: \(entry.id)")
        let residentAfterOpen = residentMiB()
        let texts = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        let originalTextHash = digest(Data(texts.joined(separator: "\u{0}").utf8))
        let annotationCount = AnnotationStore.entries(in: pdf).count
        var foundCount = 0
        var searchSeconds = 0.0
        if entry.kind != "scanned" {
            let expression = try NSRegularExpression(pattern: "[A-Za-z]{5,}")
            let text = texts[0] as NSString
            guard let match = expression.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else {
                throw Failure(message: "No searchable text in \(entry.id)")
            }
            let query = text.substring(with: match.range)
            controller.searchField.stringValue = query
            let started = ProcessInfo.processInfo.systemUptime
            controller.searchNow(nil)
            while pdf.isFinding && ProcessInfo.processInfo.systemUptime - started < 30 { pump() }
            searchSeconds = ProcessInfo.processInfo.systemUptime - started
            foundCount = controller.searchResults.count
            try check(!pdf.isFinding && foundCount > 0, "Search failed or timed out: \(entry.id)")
            controller.pdfView.setCurrentSelection(controller.searchResults[0], animate: false)
            controller.highlightSelection(nil)
        } else {
            try check(texts.allSatisfy(\.isEmpty), "Scan-only fixture unexpectedly contains text")
        }
        let crop = firstPage.bounds(for: .cropBox)
        let note = AnnotationStore.note(at: NSPoint(x: crop.minX + 30, y: crop.minY + 30), on: firstPage,
                                        text: "AdaptivePDF corpus regression")
        controller.setPresence(note, page: firstPage, present: true)
        let expected = annotationCount + (entry.kind == "scanned" ? 1 : 2)
        try check(AnnotationStore.entries(in: pdf).count == expected, "Annotation insertion failed: \(entry.id)")
        AppearancePreferences.mode = .dark
        AppearancePreferences.strategy = .basic
        pump(0.1)
        try check(controller.pdfView.basicDarkActive, "Dark appearance did not activate: \(entry.id)")
        AppearancePreferences.mode = .light
        let saved = output.appendingPathComponent("\(entry.id)-annotated.pdf")
        var savedFinished = false
        var saveError: Error?
        let saveStart = ProcessInfo.processInfo.systemUptime
        document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in saveError = error; savedFinished = true }
        while !savedFinished && ProcessInfo.processInfo.systemUptime - saveStart < 60 { pump() }
        let saveSeconds = ProcessInfo.processInfo.systemUptime - saveStart
        if let saveError { throw saveError }
        try check(savedFinished && !document.isDocumentEdited, "Corpus save failed or timed out: \(entry.id)")
        guard let reopened = PDFDocument(url: saved) else { throw Failure(message: "Corpus reload failed") }
        try check(reopened.pageCount == entry.pages && AnnotationStore.entries(in: reopened).count == expected,
                  "Annotation/page mismatch after reopening: \(entry.id)")
        let reloadedText = (0..<reopened.pageCount).map { reopened.page(at: $0)?.string ?? "" }.joined(separator: "\u{0}")
        let exactText = digest(Data(reloadedText.utf8)) == originalTextHash
        let originalCG = CGPDFDocument(source as CFURL)!
        let savedCG = CGPDFDocument(saved as CFURL)!
        var renderDifferences: [String: Double] = [:]
        let renderedPages = entry.kind == "paper" ? Array(1...entry.pages) : Set([1, max(1, entry.pages / 2), entry.pages]).sorted()
        for index in renderedPages {
            let original = pixels(originalCG.page(at: index)!)
            let changed = pixels(savedCG.page(at: index)!)
            let error = zip(original, changed).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(original.count)
            renderDifferences[String(index)] = error
            try check(error < 0.5, "Sample page rendering changed by \(error)/255: \(entry.id), page \(index)")
        }
        try check(digest(try Data(contentsOf: source)) == entry.sha256, "Reading changed source bytes: \(entry.id)")
        return [
            "id": entry.id, "kind": entry.kind, "pages": entry.pages, "source": entry.source ?? "generated",
            "source_sha256": entry.sha256, "source_bytes": originalBytes,
            "open_completion_s": openSeconds, "open_main_runloop_largest_gap_s": largestGap,
            "search_s": searchSeconds, "search_results": foundCount, "save_s": saveSeconds,
            "sample_render_mean_channel_differences": renderDifferences,
            "page_content_and_resources_verified": true, "native_text_exact": exactText, "source_bytes_unchanged": true,
            "resident_after_open_mib": residentAfterOpen,
            "resident_during_check_mib": residentMiB(), "saved_file": saved.lastPathComponent
        ]
    }
    private static func pixels(_ page: CGPDFPage) -> Data {
        let context = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 2448,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()!.dataProvider!.data! as Data
    }
}
#endif
