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
    static let sidebar = color(0xF5F5F3, 0x242629)
    static let canvas = color(0xE7E9EB, 0x15171A)
    static let footer = color(0xFAFAF9, 0x202225)
    static let control = color(0xFFFFFF, 0x303338)
    static let border = color(0xDFE2E6, 0x3C4046)
    static let welcome = color(0xF7F7F5, 0x202225)

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    static func colorDot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 18,height: 18),flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2,dy: 2))
            color.setFill(); circle.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke(); circle.lineWidth = 0.7; circle.stroke()
            return true
        }
    }
}

final class ReaderToolbarButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        bezelStyle = .inline
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1,dy: 1),xRadius: 7,yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

final class ReaderColorPaletteController: NSViewController {
    private let selected: HighlightColor
    private let onSelect: (HighlightColor) -> Void
    init(selected: HighlightColor, onSelect: @escaping (HighlightColor) -> Void) {
        self.selected = selected; self.onSelect = onSelect
        super.init(nibName: nil,bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0,y: 0,width: 184,height: 98))
        let title = NSTextField(labelWithString: "高亮颜色")
        title.font = .systemFont(ofSize: 12,weight: .semibold)
        let palette = NSStackView()
        palette.spacing = 8
        for color in HighlightColor.allCases {
            let button = ReaderColorSwatch(color: color,selected: color == selected)
            button.tag = color.rawValue; button.target = self; button.action = #selector(choose(_:))
            let label = NSTextField(labelWithString: color.title)
            label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
            let column = NSStackView(views: [button,label])
            column.orientation = .vertical; column.spacing = 3
            palette.addArrangedSubview(column)
        }
        for child in [title,palette] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor,constant: 16),
            title.topAnchor.constraint(equalTo: view.topAnchor,constant: 12),
            palette.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            palette.topAnchor.constraint(equalTo: title.bottomAnchor,constant: 8)
        ])
    }
    @objc private func choose(_ sender: NSButton) {
        if let color = HighlightColor(rawValue: sender.tag) { onSelect(color) }
    }
}

private final class ReaderColorSwatch: NSButton {
    private let color: HighlightColor
    private let chosen: Bool
    init(color: HighlightColor,selected: Bool) {
        self.color = color; self.chosen = selected
        super.init(frame: .zero)
        isBordered = false; bezelStyle = .inline
        setAccessibilityLabel(color.title)
        setAccessibilityIdentifier("highlightColor-\(color.rawValue)")
        identifier = .init("highlightColor-\(color.rawValue)")
        setAccessibilityValue(selected ? 1 : 0)
        toolTip = color.title
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 6,dy: 6))
        color.color.setFill(); circle.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke(); circle.lineWidth = 0.7; circle.stroke()
        if chosen || isHighlighted {
            NSColor.labelColor.withAlphaComponent(chosen ? 0.75 : 0.3).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2,dy: 2))
            ring.lineWidth = 1.5; ring.stroke()
        }
    }
}

final class ReaderProgressView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        ReaderStyle.border.withAlphaComponent(0.45).setFill(); bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.65).setFill()
        NSRect(x: 0,y: 0,width: bounds.width * min(1,max(0,fraction)),height: bounds.height).fill()
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
        let rect = bounds.insetBy(dx: 12,dy: 5)
        let path = NSBezierPath(roundedRect: rect,xRadius: 10,yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.12 : 0.075).setFill(); path.fill()
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
        caption.font = .systemFont(ofSize: 11,weight: .medium)
        caption.textColor = .secondaryLabelColor
        excerpt.font = .systemFont(ofSize: 13,weight: .medium)
        comment.font = .systemFont(ofSize: 12)
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
