import AppKit
import CoreImage

enum ThemeMode: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self {
        case .system: return "跟随系统 · Follow System"
        case .light: return "浅色 · Light"
        case .dark: return "深色阅读 · Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum DarkStrategy: String, CaseIterable {
    case original, preserveImages, basic
    var title: String {
        switch self {
        case .original: return "Original · PDF 保持原色（不随主题改变）"
        case .preserveImages: return "保留图片与插图 · 深色页面"
        case .basic: return "Basic Dark · 整页反色（图片也会变色）"
        }
    }
}

/// Preferences contain no PDF state. Every window observes this notification.
enum AppearancePreferences {
    static let changed = Notification.Name("AdaptivePDFAppearanceChanged")
    private static let store: UserDefaults = {
        #if DEBUG || INTEGRATION_TESTS
        if let suite = ProcessInfo.processInfo.environment["ADAPTIVEPDF_TEST_DEFAULTS_SUITE"] {
            precondition(suite.hasPrefix("local.adaptivepdf.tests."))
            return UserDefaults(suiteName: suite)!
        }
        #endif
        return .standard
    }()
    static var mode: ThemeMode {
        get { ThemeMode(rawValue: store.string(forKey: "themeMode") ?? "") ?? .system }
        set {
            store.set(newValue.rawValue, forKey: "themeMode")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    static var strategy: DarkStrategy {
        get { DarkStrategy(rawValue: store.string(forKey: "darkStrategy") ?? "") ?? .preserveImages }
        set {
            store.set(newValue.rawValue, forKey: "darkStrategy")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    /// Choosing a reading theme must also affect the page. Original remains an
    /// explicit opt-out in the Display menu and survives application restarts.
    static func selectReadingTheme(_ selected: ThemeMode) {
        store.set(selected.rawValue, forKey: "themeMode")
        if selected != .light { store.set(DarkStrategy.preserveImages.rawValue, forKey: "darkStrategy") }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    /// Display-only mapping: white -> #242424, black -> #E6E6E6.
    /// Intentionally named Basic Dark: this transforms all rendered colors.
    static func basicDarkFilter() -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        // Core Image's working space is linear-light RGB. Convert the requested
        // sRGB endpoints, otherwise #242424 appears around #696969 on screen.
        func linear(_ srgb: CGFloat) -> CGFloat {
            srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        let white = linear(0.90)
        let slope = linear(36.0 / 255.0) - white
        filter.setValue(CIVector(x: slope, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: slope, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: slope, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: white, y: white, z: white, w: 0), forKey: "inputBiasVector")
        return filter
    }
}
