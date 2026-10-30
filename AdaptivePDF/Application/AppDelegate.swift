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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AdaptivePDF"
        window.appearance = AppearancePreferences.mode.appearance
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "PDF 阅读器")!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        let title = NSTextField(labelWithString: "AdaptivePDF")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "阅读论文，标记想法。外观随系统切换。")
        subtitle.textColor = .secondaryLabelColor
        let button = NSButton(title: "打开 PDF…", target: NSDocumentController.shared,
                              action: #selector(NSDocumentController.openDocument(_:)))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        let hint = NSTextField(labelWithString: "⌘O 打开文件 · 支持多文档 · 标准 PDF 批注")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, title, subtitle, button, hint])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
        ])
        welcome = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
