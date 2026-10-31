import AppKit
import UniformTypeIdentifiers

final class WelcomeView: NSView {
    private let dropTarget = ReaderSurface(fill: ReaderStyle.control,radius: 18,stroke: ReaderStyle.border)
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? ReaderStyle.symbol("doc.richtext",size: 56)!)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "AdaptivePDF")
        title.font = .systemFont(ofSize: 30,weight: .semibold)
        let subtitle = NSTextField(labelWithString: "深色阅读，插图保留原色。")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [icon,title,subtitle])
        heading.orientation = .vertical; heading.spacing = 10
        heading.setCustomSpacing(15,after: icon)
        let button = NSButton(title: "打开 PDF…",target: NSDocumentController.shared,action: #selector(NSDocumentController.openDocument(_:)))
        button.bezelStyle = .rounded; button.controlSize = .large
        button.font = .systemFont(ofSize: 13,weight: .medium)
        button.keyEquivalent = "\r"
        let hint = NSTextField(labelWithString: "或将 PDF 拖到这里  ·  ⌘O")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [button,hint])
        actions.orientation = .vertical; actions.spacing = 15
        actions.translatesAutoresizingMaskIntoConstraints = false
        dropTarget.dashed = true
        dropTarget.addSubview(actions)
        let features = NSStackView()
        features.spacing = 30
        for (symbol,text) in [("circle.lefthalf.filled","插图保色"),("highlighter","标准批注"),("lock.shield","本机处理")] {
            let image = NSImageView(image: ReaderStyle.symbol(symbol,size: 12)!)
            image.contentTintColor = .secondaryLabelColor
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            let item = NSStackView(views: [image,label]); item.spacing = 5
            features.addArrangedSubview(item)
        }
        for view in [heading,dropTarget,features] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heading.centerXAnchor.constraint(equalTo: centerXAnchor),
            heading.topAnchor.constraint(equalTo: topAnchor,constant: 52),
            icon.widthAnchor.constraint(equalToConstant: 68), icon.heightAnchor.constraint(equalToConstant: 68),
            dropTarget.centerXAnchor.constraint(equalTo: centerXAnchor),
            dropTarget.topAnchor.constraint(equalTo: heading.bottomAnchor,constant: 32),
            dropTarget.widthAnchor.constraint(equalToConstant: 440), dropTarget.heightAnchor.constraint(equalToConstant: 134),
            actions.centerXAnchor.constraint(equalTo: dropTarget.centerXAnchor),
            actions.centerYAnchor.constraint(equalTo: dropTarget.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 176), button.heightAnchor.constraint(equalToConstant: 36),
            features.centerXAnchor.constraint(equalTo: centerXAnchor),
            features.topAnchor.constraint(equalTo: dropTarget.bottomAnchor,constant: 27)
        ])
        setAccessibilityLabel("AdaptivePDF 欢迎页，可打开或拖入 PDF")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) { ReaderStyle.welcome.setFill(); bounds.fill() }

    private func draggedPDFs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],options: [
            .urlReadingFileURLsOnly: true,.urlReadingContentsConformToTypes: [UTType.pdf.identifier]
        ]) as? [URL]) ?? []
    }
    private func showDropTarget(_ active: Bool) {
        dropTarget.fill = active ? NSColor.controlAccentColor.withAlphaComponent(0.1) : ReaderStyle.control
        dropTarget.stroke = active ? .controlAccentColor : ReaderStyle.border
        dropTarget.needsDisplay = true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !draggedPDFs(sender).isEmpty
        showDropTarget(accepted)
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { showDropTarget(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggedPDFs(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropTarget(false)
        let urls = draggedPDFs(sender)
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url,display: true) { _,_,error in
                if let error { NSApp.presentError(error) }
            }
        }
        return !urls.isEmpty
    }
}
