import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(self, selector: #selector(documentWindowOpened),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(documentWindowOpened),
                                               name: .readerWindowOpened, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(welcomeAppearanceChanged),
                                               name: AppearancePreferences.changed, object: nil)
        #if DEBUG || INTEGRATION_TESTS
        if ProcessInfo.processInfo.arguments.contains("--corpus-test") {
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in CorpusChecks.run() }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                Task { @MainActor in
                    if ProcessInfo.processInfo.environment["ADAPTIVEPDF_APPEARANCE_PHASE"] != nil {
                        await AppearanceRestartChecks.run()
                    } else if ProcessInfo.processInfo.environment["ADAPTIVEPDF_CLOSE_SCENARIO"] != nil {
                        await CloseFlowChecks.run()
                    } else { await IntegrationChecks.run() }
                }
            }
            return
        }
        #endif
        DispatchQueue.main.async { [weak self] in
            if NSDocumentController.shared.documents.isEmpty { self?.showWelcome() }
        }
    }
    #if DEBUG || INTEGRATION_TESTS
    func applicationWillTerminate(_ notification: Notification) {
        CloseFlowChecks.applicationWillTerminate()
        AppearanceRestartChecks.applicationWillTerminate()
    }
    #endif
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }
    @objc private func documentWindowOpened(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window.windowController is ReaderWindowController {
            welcome?.orderOut(nil)
        }
    }
    @objc private func welcomeAppearanceChanged() { welcome?.appearance = AppearancePreferences.mode.appearance }
    @objc func showThirdPartyNotices(_ sender: Any?) {
        if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
            NSWorkspace.shared.open(url)
        }
    }
    private func showWelcome() {
        if let welcome {
            welcome.appearance = AppearancePreferences.mode.appearance
            welcome.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 620,height: 460),
                              styleMask: [.titled,.closable,.miniaturizable,.fullSizeContentView],backing: .buffered,defer: false)
        window.title = "AdaptivePDF"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = AppearancePreferences.mode.appearance
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.contentView = WelcomeView(frame: NSRect(x: 0,y: 0,width: 620,height: 460))
        welcome = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
