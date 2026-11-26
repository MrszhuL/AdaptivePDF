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
    static let welcome = color(0xF7F7F5, 0x202225)
    static let control = color(0xFFFFFF, 0x303338)
    static let border = color(0xDFE2E6, 0x3C4046)

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

final class ReaderNumberPopover: NSViewController {
    private let heading: String
    private let field: NSTextField
    private let hint: String
    private let shortcuts: [(String, Selector)]
    private let onApply: (String) -> Bool
    private let onShortcut: (Selector) -> Void
    private let feedback = NSTextField(labelWithString: "")

    init(title: String, value: String, hint: String, shortcuts: [(String, Selector)],
         onApply: @escaping (String) -> Bool, onShortcut: @escaping (Selector) -> Void) {
        heading = title
        field = NSTextField(string: value)
        self.hint = hint
        self.shortcuts = shortcuts
        self.onApply = onApply
        self.onShortcut = onShortcut
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 124))
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.target = self
        field.action = #selector(apply(_:))
        field.setAccessibilityLabel(heading)
        field.identifier = .init("readerNumberInput")
        field.setAccessibilityIdentifier("readerNumberInput")
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        feedback.stringValue = hint
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        let applyButton = NSButton(title: "确定", target: self, action: #selector(apply(_:)))
        applyButton.controlSize = .small
        let input = NSStackView(views: [field, feedback, applyButton])
        let options = NSStackView(views: shortcuts.enumerated().map { index, shortcut in
            let button = NSButton(title: shortcut.0, target: self, action: #selector(chooseShortcut(_:)))
            button.controlSize = .small
            button.tag = index
            return button
        })
        let stack = NSStackView(views: [title, input, options])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 13),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14)
        ])
    }

    func focusInput() { field.selectText(nil) }

    @objc private func apply(_ sender: Any?) {
        let value = (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        if !onApply(value) {
            feedback.textColor = .systemRed
            NSSound.beep()
            focusInput()
        }
    }

    @objc private func chooseShortcut(_ sender: NSButton) { onShortcut(shortcuts[sender.tag].1) }
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
    private let selected: NSColor
    private let custom: NSColor?
    private let onSelect: (NSColor) -> Void
    private let onEditCustom: () -> Void
    init(selected: NSColor, custom: NSColor?, onSelect: @escaping (NSColor) -> Void,
         onEditCustom: @escaping () -> Void) {
        self.selected = selected
        self.custom = custom
        self.onSelect = onSelect
        self.onEditCustom = onEditCustom
        super.init(nibName: nil,bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 228, height: 126))
        let title = NSTextField(labelWithString: "高亮颜色")
        title.font = .systemFont(ofSize: 12,weight: .semibold)
        let palette = NSStackView()
        palette.spacing = 8
        func addSwatch(_ color: NSColor, title: String, index: Int) {
            let button = ReaderColorSwatch(color: color, title: title, index: index,
                                           selected: color.usingColorSpace(.sRGB) == selected.usingColorSpace(.sRGB))
            button.target = self
            button.action = #selector(choose(_:))
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
            let column = NSStackView(views: [button,label])
            column.orientation = .vertical; column.spacing = 3
            palette.addArrangedSubview(column)
        }
        for color in HighlightColor.allCases {
            addSwatch(color.color, title: color.title, index: color.rawValue)
        }
        if let custom { addSwatch(custom, title: "自定", index: HighlightColor.allCases.count) }
        let edit = NSButton(title: "自定义颜色…", target: self, action: #selector(editCustom(_:)))
        edit.controlSize = .small
        edit.identifier = .init("editHighlightColor")
        edit.setAccessibilityIdentifier("editHighlightColor")
        for child in [title, palette, edit] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor,constant: 16),
            title.topAnchor.constraint(equalTo: view.topAnchor,constant: 12),
            palette.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            palette.topAnchor.constraint(equalTo: title.bottomAnchor,constant: 8),
            edit.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            edit.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
    }
    @objc private func choose(_ sender: ReaderColorSwatch) { onSelect(sender.swatchColor) }
    @objc private func editCustom(_ sender: NSButton) { onEditCustom() }
}

private final class ReaderColorSwatch: NSButton {
    let swatchColor: NSColor
    private let chosen: Bool
    init(color: NSColor, title: String, index: Int, selected: Bool) {
        self.swatchColor = color
        self.chosen = selected
        super.init(frame: .zero)
        isBordered = false; bezelStyle = .inline
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("highlightColor-\(index)")
        identifier = .init("highlightColor-\(index)")
        setAccessibilityValue(selected ? 1 : 0)
        toolTip = title
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 6,dy: 6))
        swatchColor.setFill(); circle.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke(); circle.lineWidth = 0.7; circle.stroke()
        if chosen || isHighlighted {
            NSColor.labelColor.withAlphaComponent(chosen ? 0.75 : 0.3).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2,dy: 2))
            ring.lineWidth = 1.5; ring.stroke()
        }
    }
}

final class ReaderActivityHUD: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var dismissal: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        identifier = .init("readerActivityHUD")
        isHidden = true
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { dismissal?.invalidate() }

    func show(_ text: String) {
        if label.stringValue != text { label.stringValue = text }
        if isHidden { isHidden = false }
        if let dismissal {
            dismissal.fireDate = Date(timeIntervalSinceNow: 1.2)
        } else {
            let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in self?.hide() }
            dismissal = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func hide() {
        dismissal?.invalidate()
        dismissal = nil
        isHidden = true
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
