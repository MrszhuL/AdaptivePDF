import AppKit

enum ReaderStyle {
    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = AppearancePreferences.isDark(appearance) ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let sidebar = color(0xF3F4F6, 0x222326)
    static let canvas = color(0xE9EBEE, 0x18191C)
    static let footer = color(0xF8F9FA, 0x222326)
    static let control = color(0xFFFFFF, 0x303136)
    static let border = color(0xDDE0E5, 0x3B3D43)
    static let welcome = color(0xF7F8FA, 0x222326)

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16,height: 16), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2,dy: 2), xRadius: 4,yRadius: 4)
            color.setFill(); path.fill()
            NSColor.black.withAlphaComponent(0.12).setStroke(); path.lineWidth = 0.5; path.stroke()
            return true
        }
    }
}

final class ReaderSurface: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat
    var stroke: NSColor?
    var dashed = false
    init(fill: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil) {
        self.fill = fill; self.radius = radius; self.stroke = stroke
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5,dy: 0.5), xRadius: radius,yRadius: radius)
        fill.setFill(); path.fill()
        if let stroke {
            stroke.setStroke(); path.lineWidth = 1
            if dashed { path.setLineDash([4,4], count: 2, phase: 0) }
            path.stroke()
        }
    }
}

final class ReaderSelectionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8,dy: 4)
        let path = NSBezierPath(roundedRect: rect,xRadius: 8,yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.14 : 0.09).setFill(); path.fill()
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.45 : 0.25).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}

final class ReaderEmptyState: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 13,weight: .medium)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        let stack = NSStackView(views: [icon,title,detail])
        stack.orientation = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor,constant: -30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -24),
            icon.heightAnchor.constraint(equalToConstant: 30),
            icon.widthAnchor.constraint(equalToConstant: 30)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func configure(symbol: String, title: String, detail: String) {
        icon.image = ReaderStyle.symbol(symbol,size: 28,weight: .light)
        self.title.stringValue = title; self.detail.stringValue = detail
    }
}

final class ReaderReviewCell: NSTableCellView {
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(labelWithString: "")
    private let comment = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        caption.font = .systemFont(ofSize: 10,weight: .medium)
        caption.textColor = .secondaryLabelColor
        excerpt.font = .systemFont(ofSize: 12,weight: .medium)
        comment.font = .systemFont(ofSize: 11)
        comment.textColor = .secondaryLabelColor
        for label in [caption,excerpt,comment] { label.lineBreakMode = .byTruncatingTail }
        let heading = NSStackView(views: [icon,caption]); heading.spacing = 5
        let stack = NSStackView(views: [heading,excerpt,comment])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 19),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -18),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12), icon.heightAnchor.constraint(equalToConstant: 12),
            excerpt.widthAnchor.constraint(equalTo: stack.widthAnchor),
            comment.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        textField = excerpt
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func configure(caption: String, excerpt: String, comment: String, symbol: String, color: NSColor) {
        self.caption.stringValue = caption; self.excerpt.stringValue = excerpt; self.comment.stringValue = comment
        self.comment.isHidden = comment.isEmpty
        icon.image = ReaderStyle.symbol(symbol,size: 11)
        icon.contentTintColor = color
        toolTip = [caption,excerpt,comment].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
