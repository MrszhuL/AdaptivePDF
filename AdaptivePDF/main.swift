import AppKit

final class ReaderApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        #if DEBUG || INTEGRATION_TESTS
        if ProcessInfo.processInfo.arguments.contains("--self-test") || ProcessInfo.processInfo.arguments.contains("--corpus-test") {
            fputs("COCOA EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "")\n", stderr)
            exit(1)
        }
        #endif
        super.reportException(exception)
    }
}

let app = ReaderApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.mainMenu = MenuBuilder.build()
app.run()
