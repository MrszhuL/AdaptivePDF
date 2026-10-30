#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit
import CryptoKit

/// Separate processes exercise actual NSDocument close and NSApplication quit.
/// Production does not contain this driver.
@MainActor enum CloseFlowChecks {
    private struct Item {
        let document: PDFReaderDocument
        let controller: ReaderWindowController
        let file: URL
        let comment: String
    }
    private static var items: [Item] = []
    private static var scenario = ""
    private static var output: URL!
    private static var source: URL!
    private static var original: Data!
    private static var assertions: [String] = []
    private static var timer: Timer?
    private static var actionCount = 0
    private static var clickedButtons: [NSButton] = []
    private static var terminationRequested = false
    private static var finished = false
    private static var savePrompt: NSWindow?
    private static var failureDismissed = false
    private static var deadline = Date.distantFuture

    static func run() async {
        do {
            let environment = ProcessInfo.processInfo.environment
            scenario = environment["ADAPTIVEPDF_CLOSE_SCENARIO"]!
            let root = URL(fileURLWithPath: environment["ADAPTIVEPDF_TEST_ROOT"]!)
            output = URL(fileURLWithPath: environment["ADAPTIVEPDF_TEST_OUTPUT"]!, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            source = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
            original = try Data(contentsOf: source)
            guard NSDocumentController.shared.documents.isEmpty else {
                throw IntegrationChecks.Failure(description: "Close driver must start in an empty process")
            }
            let count = scenario.hasPrefix("multi-") ? 2 : 1
            for index in 0..<count { items.append(try openCopy(index)) }
            try check(items.allSatisfy { $0.document.isDocumentEdited }, "All test documents contain tracked unsaved notes")
            if scenario == "window-save-failure" {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: output.path)
            }
            deadline = Date().addingTimeInterval(20)
            scheduleTick()
            if scenario.contains("quit") {
                terminationRequested = true
                NSApp.terminate(nil)
            } else { items[0].controller.window?.performClose(nil) }
        } catch { fail(error) }
    }

    private static func scheduleTick() {
        // AppKit's quit alerts can run synchronously in a modal loop. A fresh
        // timer is armed before each action, so a nested dialog can be answered
        // without waiting for that action's call stack to unwind.
        let poll = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer = poll
        for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] { RunLoop.main.add(poll, forMode: mode) }
    }

    private static func openCopy(_ index: Int) throws -> Item {
        let file = output.appendingPathComponent("Close-\(index + 1).pdf")
        try original.write(to: file)
        let document = PDFReaderDocument()
        try document.read(from: file, ofType: "com.adobe.pdf")
        document.fileURL = file; document.fileType = "com.adobe.pdf"
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let controller = document.windowControllers[0] as! ReaderWindowController
        controller.showWindow(nil)
        let comment = "\(scenario) retained note \(index + 1)"
        let page = document.pdf!.page(at: 0)!
        controller.setPresence(AnnotationStore.note(at: NSPoint(x: 120, y: 500), on: page, text: comment),
                               page: page, present: true)
        return Item(document: document, controller: controller, file: file, comment: comment)
    }

    private static func tick() {
        guard !finished else { return }
        scheduleTick()
        do {
            if Date() > deadline {
                throw IntegrationChecks.Failure(description: "Timed out in \(scenario); visible buttons: \(buttons().map(\.title))")
            }
            let cancel = scenario.hasSuffix("cancel")
            let discard = scenario.hasSuffix("discard")
            if scenario == "window-save-failure" && actionCount > 0 {
                if !failureDismissed,
                   let dismiss = buttons().first(where: { $0.window !== savePrompt && $0.isEnabled &&
                       ["OK", "好", "确定", "Cancel", "取消"].contains($0.title) && !clickedButtons.contains($0) }) {
                    failureDismissed = true
                    try check(items[0].document.isDocumentEdited, "A failed close-save retains unsaved document state")
                    perform(dismiss)
                } else if failureDismissed && items[0].controller.window?.attachedSheet == nil && NSApp.modalWindow == nil {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
                    try check(items[0].controller.window?.isVisible == true && items[0].document.isDocumentEdited,
                              "A failed close-save leaves the reader window open with its edits")
                    try check(AnnotationStore.entries(in: items[0].document.pdf!).contains { $0.annotation.contents == items[0].comment },
                              "A failed close-save keeps the unsaved standard note in memory")
                    try verifyFiles(saved: false)
                    try finish(nativeTermination: false)
                }
                return
            }
            if actionCount == 0 && scenario.hasPrefix("multi-") {
                if cancel, let cancelButton = button(titles: ["Cancel", "取消"]) {
                    perform(cancelButton)
                } else if discard, let discardButton = button(titles: ["Discard Changes", "Discard Changes…", "放弃更改", "不保存"]) {
                    perform(discardButton)
                } else if let review = button(titles: ["Review Changes…", "Review Changes", "检查更改…", "检查更改", "查看更改…", "查看更改", "复查更改…", "复查更改"]) {
                    perform(review)
                }
                return
            }
            let candidates = buttons()
            let titles = cancel ? ["Cancel", "取消"] : discard ? ["Don’t Save", "Don't Save", "不存储", "不保存"] : ["Save", "存储", "保存"]
            if let action = candidates.first(where: { titles.contains($0.title) && $0.isEnabled && !clickedButtons.contains($0) }) {
                if scenario == "window-save-failure" { savePrompt = action.window }
                perform(action)
                return
            }
            if cancel && actionCount > 0 && NSApp.modalWindow == nil && items.allSatisfy({ $0.controller.window?.attachedSheet == nil }) {
                try check(items.allSatisfy { $0.controller.window?.isVisible == true && $0.document.isDocumentEdited },
                          "Cancel retains every window and unsaved document")
                try check(NSDocumentController.shared.documents.count == items.count,
                          "Cancel retains all documents in NSDocumentController")
                try verifyFiles(saved: false)
                try finish(nativeTermination: false)
            } else if !terminationRequested && actionCount > 0 && items.allSatisfy({ $0.controller.window?.isVisible == false }) {
                try check(NSDocumentController.shared.documents.isEmpty, "Window close removes the document from its controller")
                try verifyFiles(saved: !discard)
                try finish(nativeTermination: false)
            }
        } catch { fail(error) }
    }

    static func applicationWillTerminate() {
        guard terminationRequested && !finished else { return }
        do {
            try check(!scenario.hasSuffix("cancel"), "Only Save or Discard can lead to native application termination")
            try check(actionCount > 0, "Native termination follows a real save/discard response")
            try check(NSDocumentController.shared.documents.isEmpty, "Native quit closes every managed document")
            try verifyFiles(saved: !scenario.hasSuffix("discard"))
            try finish(nativeTermination: true)
        } catch { fail(error) }
    }

    private static func verifyFiles(saved: Bool) throws {
        for item in items {
            let data = try Data(contentsOf: item.file)
            if saved {
                let pdf = PDFDocument(data: data)!
                try check(AnnotationStore.entries(in: pdf).filter { $0.annotation.contents == item.comment }.count == 1,
                          "\(item.file.lastPathComponent) retains its standard note after native saving")
                var error: NSError?
                try check(APDFVerifyOriginalContent(original, data, &error),
                          "\(item.file.lastPathComponent) retains all original page contents and resources")
            } else {
                try check(data == original, "\(item.file.lastPathComponent) is untouched when changes are discarded or canceled")
            }
        }
        try check(try Data(contentsOf: source) == original, "Repository source fixture is never changed by close/quit flows")
    }

    private static func buttons() -> [NSButton] {
        NSApp.windows.filter { $0.isVisible || $0.isSheet }.flatMap { descendants($0.contentView) }.compactMap { $0 as? NSButton }
    }
    private static func button(titles: [String]) -> NSButton? {
        buttons().first { titles.contains($0.title) && $0.isEnabled && !clickedButtons.contains($0) }
    }
    private static func perform(_ button: NSButton) {
        clickedButtons.append(button)
        actionCount += 1
        print("ACTION: \(button.title)"); fflush(stdout)
        button.performClick(nil)
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw IntegrationChecks.Failure(description: message) }
        assertions.append(message)
        print("PASS: \(message)"); fflush(stdout)
    }
    private static func finish(nativeTermination: Bool) throws {
        finished = true; timer?.invalidate()
        let saved = scenario.hasSuffix("save")
        let report: [String: Any] = [
            "schema_version": 1, "status": "passed", "scenario": scenario,
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "native_termination_notification": nativeTermination,
            "assertions": assertions, "assertion_count": assertions.count,
            "action_count": actionCount,
            "source_sha256": SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(),
            "checked_files": items.map { ["path": $0.file.path, "expected_comment": saved ? $0.comment : ""] },
            "completed_at": ISO8601DateFormatter().string(from: Date())
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("close-report.json"), options: .atomic)
        if !nativeTermination {
            for item in items { item.document.updateChangeCount(.changeCleared); item.document.close() }
            exit(0)
        }
    }
    private static func fail(_ error: Error) -> Never {
        if scenario == "window-save-failure", let output {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
        }
        fputs("FAIL: \(scenario): \(error)\n", stderr)
        exit(1)
    }
}
#endif
