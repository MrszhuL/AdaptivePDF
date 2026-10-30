#if DEBUG || INTEGRATION_TESTS
import AppKit
import PDFKit

/// Each phase is a distinct application process. A unique preferences suite
/// avoids changing the user's normal application preferences.
@MainActor enum AppearanceRestartChecks {
    private static var report: [String: Any]?
    private static var reportURL: URL?
    private static var assertions: [String] = []

    static func run() async {
        do {
            let environment = ProcessInfo.processInfo.environment
            let phase = environment["ADAPTIVEPDF_APPEARANCE_PHASE"]!
            let suite = environment["ADAPTIVEPDF_TEST_DEFAULTS_SUITE"]!
            guard suite.hasPrefix("local.adaptivepdf.tests."),
                  let mode = ThemeMode(rawValue: environment["ADAPTIVEPDF_EXPECTED_THEME"]!),
                  let strategy = DarkStrategy(rawValue: environment["ADAPTIVEPDF_EXPECTED_STRATEGY"]!) else {
                throw IntegrationChecks.Failure(description: "Invalid isolated appearance probe configuration")
            }
            let directory = URL(fileURLWithPath: environment["ADAPTIVEPDF_TEST_OUTPUT"]!, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            reportURL = directory.appendingPathComponent("\(phase).json")
            if phase == "write" {
                AppearancePreferences.mode = mode
                AppearancePreferences.strategy = strategy
                try check(AppearancePreferences.mode == mode && AppearancePreferences.strategy == strategy,
                          "Application setters store the selected theme and rendering strategy")
            } else if phase == "read" {
                try check(AppearancePreferences.mode == mode && AppearancePreferences.strategy == strategy,
                          "A new process restores both preference values before constructing windows")
                NSApp.appearance = NSAppearance(named: mode == .light ? .darkAqua : .aqua)
                let delegate = NSApp.delegate as! AppDelegate
                _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                let welcome = NSApp.windows.first { $0.title == "AdaptivePDF" && $0.windowController == nil }!
                let initiallyDark = mode == .dark
                try await Task.sleep(nanoseconds: 60_000_000)
                try check(isDark(welcome.effectiveAppearance) == initiallyDark,
                          "The welcome window applies the restored explicit or inherited appearance")
                let root = URL(fileURLWithPath: environment["ADAPTIVEPDF_TEST_ROOT"]!)
                let source = root.appendingPathComponent("Tests/Fixtures/Academic.pdf")
                let document = PDFReaderDocument()
                try document.read(from: source, ofType: "com.adobe.pdf")
                document.fileURL = source; document.fileType = "com.adobe.pdf"
                NSDocumentController.shared.addDocument(document)
                document.makeWindowControllers()
                let controller = document.windowControllers[0] as! ReaderWindowController
                controller.showWindow(nil)
                try await Task.sleep(nanoseconds: 80_000_000)
                try check(!welcome.isVisible, "Opening the restored reader hides the welcome window")
                try check(isDark(controller.window!.effectiveAppearance) == initiallyDark,
                          "The reader window applies the restored appearance")
                try check(controller.pdfView.basicDarkActive == (initiallyDark && strategy == .basic),
                          "The PDF view restores the chosen Original or Basic Dark strategy")
                try check(controller.pdfView.preservingDarkActive == (initiallyDark && strategy == .preserveImages),
                          "The PDF view restores image-preserving dark rendering independently of Basic Dark")
                let popup = controller.window!.toolbar!.items.first { $0.itemIdentifier.rawValue == "theme" }!.view as! NSPopUpButton
                try check(popup.indexOfSelectedItem == ThemeMode.allCases.firstIndex(of: mode),
                          "The visible theme control matches the restored preference")
                if mode == .system {
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    try await Task.sleep(nanoseconds: 80_000_000)
                    try check(isDark(controller.window!.effectiveAppearance) && isDark(welcome.effectiveAppearance),
                              "Restored Follow System updates both reader and welcome with inherited Dark")
                    try check(controller.pdfView.basicDarkActive == (strategy == .basic),
                              "Restored strategy responds to a live inherited appearance change")
                }
                let alternate: ThemeMode = mode == .dark ? .light : .dark
                AppearancePreferences.mode = alternate
                try await Task.sleep(nanoseconds: 60_000_000)
                try check(isDark(welcome.effectiveAppearance) == (alternate == .dark),
                          "The existing welcome window responds to a live explicit theme change")
                AppearancePreferences.mode = mode
                let serialized = try document.data(ofType: "com.adobe.pdf")
                let original = try Data(contentsOf: source)
                try check(serialized == original && !document.isDocumentEdited,
                          "Restarted theme preferences leave original PDF bytes and modified state intact")
            } else if phase == "cleanup" {
                let defaults = UserDefaults(suiteName: suite)!
                defaults.removePersistentDomain(forName: suite)
                try check((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty,
                          "The isolated test preference domain is removed")
            } else { throw IntegrationChecks.Failure(description: "Unknown appearance phase") }
            report = ["status": "passed", "phase": phase, "theme": mode.rawValue, "strategy": strategy.rawValue,
                      "pid": ProcessInfo.processInfo.processIdentifier,
                      "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String,
                      "assertions": assertions, "assertion_count": assertions.count]
            // Normal termination, without synchronize() or a forced process kill.
            NSApp.terminate(nil)
        } catch {
            fputs("FAIL: appearance restart: \(error)\n", stderr)
            exit(1)
        }
    }
    static func applicationWillTerminate() {
        guard var value = report, let reportURL else { return }
        do {
            value["native_termination_notification"] = true
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
            report = nil
        } catch {
            fputs("FAIL: writing appearance evidence: \(error)\n", stderr)
            exit(1)
        }
    }
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw IntegrationChecks.Failure(description: message) }
        assertions.append(message)
        print("PASS: \(message)"); fflush(stdout)
    }
}
#endif
