import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?
    private let backgroundPinch = BackgroundPinchMonitor()
    private var pinchSetupItem: NSMenuItem?
    private var hasFinishedPinchSetup = false

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
        hasFinishedPinchSetup = true
        refreshBackgroundPinch()
        DispatchQueue.main.async { [weak self] in
            if NSDocumentController.shared.documents.isEmpty { self?.showWelcome() }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if hasFinishedPinchSetup { refreshBackgroundPinch() }
    }

    private func refreshBackgroundPinch() {
        if backgroundPinch.start() {
            if let item = pinchSetupItem { item.menu?.removeItem(item) }
            pinchSetupItem = nil
        } else if pinchSetupItem == nil, let menu = NSApp.mainMenu?.item(withTitle: "显示")?.submenu {
            let item = NSMenuItem(title: "启用后台捏合缩放…", action: #selector(enableBackgroundPinch(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            pinchSetupItem = item
        }
    }

    @objc private func enableBackgroundPinch(_ sender: Any?) {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        refreshBackgroundPinch()
        guard pinchSetupItem != nil else { return }
        let alert = NSAlert()
        alert.messageText = "后台捏合缩放尚未启用"
        alert.informativeText = CGPreflightListenEventAccess()
            ? "macOS 尚未启用手势监听。请退出并重新打开 AdaptivePDF。"
            : "请在系统设置的「隐私与安全性 → 输入监控」中允许 AdaptivePDF。如果旧版已在列表中，请重新添加「应用程序」里的 AdaptivePDF，然后退出并重新打开应用。"
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        backgroundPinch.stop()
        #if DEBUG || INTEGRATION_TESTS
        CloseFlowChecks.applicationWillTerminate()
        AppearanceRestartChecks.applicationWillTerminate()
        #endif
    }
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
