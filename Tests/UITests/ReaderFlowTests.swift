import XCTest
import PDFKit

/// Black-box interaction tests. These drive the real app's menus, open panel,
/// search list and editor; the app exposes no test-only document mutation API.
final class ReaderFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSearchAnnotateSaveReopenAndUnsavedCancel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptivePDF-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("ReaderFlow.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Tests/Fixtures/Academic.pdf"), to: pdf)
        let originalText = PDFDocument(url: pdf)?.string
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: folder) }

        open(pdf, in: app)
        let window = app.windows.matching(NSPredicate(format: "label CONTAINS %@", "ReaderFlow")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Open panel must load the requested PDF")
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["fullTextSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("First selected line")
        let rows = app.tables["reviewList"].tableRows
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        rows.firstMatch.click()
        app.typeKey("h", modifierFlags: [.command, .shift])
        app.typeKey("k", modifierFlags: [.command, .shift])
        let editor = app.textViews["批注内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("UI verified highlight comment")
        app.buttons["完成"].click()

        app.typeKey("n", modifierFlags: [.command, .shift])
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.50)).click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("UI verified sticky note")
        app.buttons["完成"].click()
        app.typeKey("s", modifierFlags: .command)
        let saved = NSPredicate { _, _ in
            guard let document = PDFDocument(url: pdf) else { return false }
            let annotations = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
            return annotations.contains { $0.type == "Highlight" && $0.contents == "UI verified highlight comment" } &&
                annotations.contains { $0.type == "Text" && $0.contents == "UI verified sticky note" }
        }
        expectation(for: saved, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(PDFDocument(url: pdf)?.string, originalText, "Annotations must not replace page text")
        app.typeKey("w", modifierFlags: .command)
        open(pdf, in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Saved PDF must reopen")

        // Add an unsaved note, attempt close, then cancel through the real sheet.
        app.typeKey("n", modifierFlags: [.command, .shift])
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)).click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); editor.typeText("Unsaved UI draft")
        app.buttons["完成"].click()
        app.typeKey("w", modifierFlags: .command)
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(window.exists)
        app.typeKey("s", modifierFlags: .command)
        let finalSaved = NSPredicate { _, _ in
            PDFDocument(url: pdf)?.page(at: 0)?.annotations.contains { $0.contents == "Unsaved UI draft" } == true
        }
        expectation(for: finalSaved, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Reader after native interaction flow"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSaveAsThroughNativeFilePanel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptivePDF-SaveAs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("SaveAsSource.pdf")
        let target = folder.appendingPathComponent("SaveAsResult.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Tests/Fixtures/Academic.pdf"), to: source)
        let sourceBytes = try Data(contentsOf: source)
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: folder) }
        open(source, in: app)
        let window = app.windows.matching(NSPredicate(format: "label CONTAINS %@", "SaveAsSource")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.typeKey("n", modifierFlags: [.command, .shift])
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.50)).click()
        let editor = app.textViews["批注内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); editor.typeText("Save As panel verified note")
        app.buttons["完成"].click()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let filename = app.sheets.textFields.firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 5), "Native Save As filename field must exist")
        filename.click(); app.typeKey("a", modifierFlags: .command); filename.typeText(target.lastPathComponent)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path); app.typeKey(.return, modifierFlags: [])
        let saveButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "存储", "保存"])).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5)); saveButton.click()
        let written = NSPredicate { _, _ in
            PDFDocument(url: target)?.page(at: 0)?.annotations.contains { $0.contents == "Save As panel verified note" } == true
        }
        expectation(for: written, evaluatedWith: nil); waitForExpectations(timeout: 10)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "Save As must leave the original PDF intact")
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "label CONTAINS %@", "SaveAsResult")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func open(_ url: URL, in app: XCUIApplication) {
        app.typeKey("o", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields.matching(NSPredicate(format: "value CONTAINS '/' OR placeholderValue CONTAINS '/' ")).firstMatch
        if path.waitForExistence(timeout: 3) { path.click() }
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        // The first Return resolves Go to Folder. The second confirms the file.
        let openButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if openButton.waitForExistence(timeout: 5) { openButton.click() }
    }
}
