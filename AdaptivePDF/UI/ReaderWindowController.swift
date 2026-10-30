import AppKit
import PDFKit

final class ReaderWindowController: NSWindowController, NSToolbarDelegate, NSTableViewDataSource,
                                    NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSWindowDelegate,
                                    NSToolbarItemValidation {
    unowned let readerDocument: PDFReaderDocument
    private(set) var pdf: PDFDocument
    let pdfView = ReaderPDFView(frame: .zero)
    private let split = NSSplitView()
    private let sidebar = ReaderSurface(fill: ReaderStyle.sidebar)
    private let sidebarHeading = NSTextField(labelWithString: "文档导航")
    private let sidebarDetail = NSTextField(labelWithString: "")
    private let emptyState = ReaderEmptyState()
    private let sidebarTabs = NSSegmentedControl(labels: ["页面", "批注", "搜索"], trackingMode: .selectOne, target: nil, action: nil)
    let thumbnails = PDFThumbnailSidebar()
    private let list = AnnotationTableView()
    private let listScroll = NSScrollView()
    let searchField = NSSearchField()
    private let pageField = NSTextField(string: "1")
    private let pageCount = NSTextField(labelWithString: "/ 0")
    private let status = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let readingInfo = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let themePopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let displayPopup = NSPopUpButton()
    private var notes: [AnnotationEntry] = []
    private var notesByPage: [Int: [AnnotationEntry]] = [:]
    private var excerptCache: [ObjectIdentifier: String] = [:]
    private(set) var searchResults: [PDFSelection] = []
    private var selectedAnnotation: PDFAnnotation?
    private var searchTask: DispatchWorkItem?
    private var isSearching = false
    private var searchTruncated = false
    private var fitWidthEnabled = false
    private var suppressListSelection = false
    private var noteEditorOpen = false

    init(readerDocument: PDFReaderDocument, pdf: PDFDocument) {
        self.readerDocument = readerDocument
        self.pdf = pdf
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.minSize = NSSize(width: 820, height: 540)
        window.isRestorable = false
        window.title = readerDocument.displayName
        window.tabbingMode = .disallowed
        window.center()
        buildContent()
        buildToolbar()
        pdfView.document = pdf
        pdfView.imagePreservingRenderer = readerDocument.imagePreservingRenderer
        pdfView.onRenderingChanged = { [weak self] in
            self?.thumbnails.reload()
            self?.updateStatus()
        }
        thumbnails.pdfView = pdfView
        pdfView.onAppearanceChanged = { [weak self] in self?.updateReadingAppearance() }
        pdfView.onAnnotationClicked = { [weak self] annotation, edit in
            self?.selectAnnotation(annotation)
            if edit { self?.editAnnotation(nil) }
        }
        pdfView.onPlaceNote = { [weak self] page, point in self?.composeNote(on: page, at: point) }
        pdfView.onNoteModeChanged = { [weak self] in self?.updateStatus() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appearanceChanged), name: AppearancePreferences.changed, object: nil)
        center.addObserver(self, selector: #selector(annotationsChanged(_:)), name: .readerAnnotationsChanged, object: readerDocument)
        center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewScaleChanged, object: pdfView)
        center.addObserver(self, selector: #selector(textSelectionChanged), name: .PDFViewSelectionChanged, object: pdfView)
        center.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: pdf)
        center.addObserver(self, selector: #selector(searchEnded), name: .PDFDocumentDidEndFind, object: pdf)
        center.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowResized), name: NSSplitView.didResizeSubviewsNotification, object: split)
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        appearanceChanged()
        annotationsChanged()
        pageChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { NotificationCenter.default.removeObserver(self); searchTask?.cancel() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { readerDocument.undoManager }

    func replacePDF(with loaded: PDFDocument) {
        guard pdf !== loaded else { return }
        let old = pdf
        let pageIndex = pdfView.currentPage.map { old.index(for: $0) } ?? 0
        let destination = pdfView.currentDestination?.point
        let scale = pdfView.scaleFactor
        let autoScales = pdfView.autoScales
        searchTask?.cancel()
        isSearching = false
        let center = NotificationCenter.default
        center.removeObserver(self, name: .PDFDocumentDidFindMatch, object: old)
        center.removeObserver(self, name: .PDFDocumentDidEndFind, object: old)
        old.cancelFindString()
        // A draft belongs to one PDF object graph. Revert discards it along with
        // the old annotations; a delayed sheet completion must never edit it.
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort) }
        window?.makeFirstResponder(pdfView)
        noteEditorOpen = false
        pdfView.placingNote = false
        pdfView.clearSelection()
        pdfView.highlightedSelections = nil
        searchResults.removeAll()
        searchTruncated = false
        selectedAnnotation = nil
        notesByPage.removeAll()
        excerptCache.removeAll()
        pdfView.document = nil
        pdf = loaded
        pdfView.imagePreservingRenderer = readerDocument.imagePreservingRenderer
        pdfView.document = loaded
        updateReadingAppearance()
        center.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: loaded)
        center.addObserver(self, selector: #selector(searchEnded), name: .PDFDocumentDidEndFind, object: loaded)
        pdfView.autoScales = autoScales
        if !autoScales { pdfView.scaleFactor = scale }
        if let page = loaded.page(at: max(0, min(pageIndex, loaded.pageCount - 1))) {
            if let destination { pdfView.go(to: PDFDestination(page: page, at: destination)) }
            else { pdfView.go(to: page) }
        }
        annotationsChanged()
        pageChanged()
        updateReadingAppearance()
        if fitWidthEnabled { fitWidth(nil) }
        if loaded.isLocked { requestPassword() }
        else if !searchField.stringValue.isEmpty { searchNow(nil) }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        let footer = ReaderSurface(fill: ReaderStyle.footer)
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(separator)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(status)
        statusIcon.image = ReaderStyle.symbol("circle.lefthalf.filled",size: 11)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusIcon)
        readingInfo.font = .monospacedDigitSystemFont(ofSize: 10,weight: .regular)
        readingInfo.textColor = .secondaryLabelColor
        readingInfo.setContentCompressionResistancePriority(.required,for: .horizontal)
        readingInfo.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(readingInfo)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            statusIcon.leadingAnchor.constraint(equalTo: footer.leadingAnchor,constant: 14),
            statusIcon.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 12), statusIcon.heightAnchor.constraint(equalToConstant: 12),
            status.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor,constant: 7),
            status.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: readingInfo.leadingAnchor,constant: -18),
            readingInfo.trailingAnchor.constraint(equalTo: footer.trailingAnchor,constant: -16),
            readingInfo.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        sidebar.frame.size.width = 224
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pdfView)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        sidebarHeading.font = .systemFont(ofSize: 13,weight: .semibold)
        sidebarDetail.font = .systemFont(ofSize: 10)
        sidebarDetail.textColor = .secondaryLabelColor
        for label in [sidebarHeading,sidebarDetail] { label.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(label) }
        sidebarTabs.target = self
        sidebarTabs.action = #selector(sidebarTabChanged)
        sidebarTabs.selectedSegment = 0
        sidebarTabs.font = .systemFont(ofSize: 11,weight: .medium)
        sidebarTabs.segmentStyle = .rounded
        sidebarTabs.segmentDistribution = .fill
        sidebarTabs.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarTabs)
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(thumbnails)
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        listScroll.drawsBackground = false
        listScroll.documentView = list
        list.headerView = nil
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        list.backgroundColor = .clear
        list.rowHeight = 88
        list.intercellSpacing = .zero
        list.focusRingType = .none
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(editAnnotation(_:))
        list.setAccessibilityLabel("批注或搜索结果")
        list.setAccessibilityIdentifier("reviewList")
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "编辑评论…", action: #selector(editAnnotation(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "删除批注", action: #selector(deleteAnnotation(_:)), keyEquivalent: "")
        list.menu = contextMenu
        sidebar.addSubview(listScroll)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(emptyState)
        for view in [thumbnails, listScroll,emptyState] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: sidebarTabs.bottomAnchor, constant: 10),
                view.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            sidebarHeading.topAnchor.constraint(equalTo: sidebar.topAnchor,constant: 19),
            sidebarHeading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor,constant: 18),
            sidebarDetail.topAnchor.constraint(equalTo: sidebarHeading.bottomAnchor,constant: 5),
            sidebarDetail.leadingAnchor.constraint(equalTo: sidebarHeading.leadingAnchor),
            sidebarTabs.topAnchor.constraint(equalTo: sidebarDetail.bottomAnchor, constant: 15),
            sidebarTabs.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarTabs.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            sidebarTabs.heightAnchor.constraint(equalToConstant: 26)
        ])
        sidebarTabChanged()
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbarV2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unifiedCompact
    }
    private let toolbarNames = ["sidebar", "open", "previous", "next", "page", "zoom", "zoomOut", "zoomIn", "fit", "display", "highlight", "color", "comment", "note", "theme", "search"]
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarNames.map { .init($0) } + [.flexibleSpace, .space]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["sidebar", "page", NSToolbarItem.Identifier.flexibleSpace.rawValue, "zoom", "display", "highlight", "color", "comment", "note", NSToolbarItem.Identifier.flexibleSpace.rawValue, "theme", "search"].map { .init($0) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let actions: [String: (String, String, Selector)] = [
            "sidebar": ("显示或隐藏侧栏 ⌘⌥D", "sidebar.left", #selector(toggleSidebar(_:))),
            "open": ("打开 PDF", "folder", #selector(NSDocumentController.openDocument(_:))),
            "previous": ("上一页", "chevron.left", #selector(previousPage(_:))),
            "next": ("下一页", "chevron.right", #selector(nextPage(_:))),
            "zoomOut": ("缩小", "minus.magnifyingglass", #selector(zoomOut(_:))),
            "zoomIn": ("放大", "plus.magnifyingglass", #selector(zoomIn(_:))),
            "fit": ("适合页面", "arrow.up.left.and.arrow.down.right", #selector(fitPage(_:))),
            "highlight": ("高亮选中文字 ⌘⇧H", "highlighter", #selector(highlightSelection(_:))),
            "comment": ("为所选文字添加评论 ⌘⇧K", "text.bubble", #selector(commentSelection(_:))),
            "note": ("插入便签：点击页面位置 ⌘⇧N", "note.text.badge.plus", #selector(placeNote(_:)))
        ]
        if let (title, symbol, action) = actions[identifier.rawValue] {
            item.label = title
            item.toolTip = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.target = identifier.rawValue == "open" ? NSDocumentController.shared : self
            item.action = action
            if identifier.rawValue == "sidebar" { item.visibilityPriority = .high }
            if ["comment","note"].contains(identifier.rawValue) { item.visibilityPriority = .low }
        } else {
            switch identifier.rawValue {
            case "page":
                pageField.alignment = .center
                pageField.isBezeled = false
                pageField.drawsBackground = false
                pageField.font = .monospacedDigitSystemFont(ofSize: 12,weight: .medium)
                pageField.target = self
                pageField.action = #selector(goToPage(_:))
                pageField.setAccessibilityLabel("页码")
                pageField.setAccessibilityIdentifier("pageNumber")
                pageField.widthAnchor.constraint(equalToConstant: 30).isActive = true
                pageCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                pageCount.textColor = .secondaryLabelColor
                for (button,symbol,title,action) in [(previousButton,"chevron.left","上一页",#selector(previousPage(_:))),
                                                     (nextButton,"chevron.right","下一页",#selector(nextPage(_:)))] {
                    button.image = ReaderStyle.symbol(symbol,size: 11,weight: .medium)
                    button.bezelStyle = .inline
                    button.isBordered = false
                    button.target = self; button.action = action
                    button.toolTip = title; button.setAccessibilityLabel(title)
                    button.widthAnchor.constraint(equalToConstant: 24).isActive = true
                }
                let stack = NSStackView(views: [previousButton,pageField,pageCount,nextButton])
                stack.spacing = 2
                let capsule = ReaderSurface(fill: ReaderStyle.control,radius: 7,stroke: ReaderStyle.border)
                stack.translatesAutoresizingMaskIntoConstraints = false; capsule.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor,constant: 3),
                    stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor,constant: -3),
                    stack.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
                    capsule.heightAnchor.constraint(equalToConstant: 28)
                ])
                item.view = capsule
                item.label = "页码"
                item.visibilityPriority = .high
            case "zoom":
                let zoom = NSSegmentedControl(images: [ReaderStyle.symbol("minus")!,ReaderStyle.symbol("arrow.up.left.and.arrow.down.right")!,ReaderStyle.symbol("plus")!], trackingMode: .momentary,target: self,action: #selector(zoomChanged(_:)))
                zoom.segmentStyle = .rounded
                zoom.controlSize = .small
                for (index,title) in ["缩小","适合页面","放大"].enumerated() { zoom.setToolTip(title,forSegment: index); zoom.setWidth(28,forSegment: index) }
                zoom.setAccessibilityLabel("缩放")
                item.view = zoom; item.label = "缩放"
            case "search":
                searchField.placeholderString = "搜索文档"
                searchField.setAccessibilityLabel("全文搜索")
                searchField.setAccessibilityIdentifier("fullTextSearch")
                searchField.delegate = self
                searchField.target = self
                searchField.action = #selector(searchNow(_:))
                let search = NSSearchToolbarItem(itemIdentifier: identifier)
                search.searchField = searchField
                search.preferredWidthForSearchField = 180
                search.visibilityPriority = .high
                search.label = "搜索"
                return search
            case "theme":
                for (title,symbol) in [("跟随系统","circle.lefthalf.filled"),("浅色","sun.max"),("深色","moon")] {
                    themePopup.addItem(withTitle: title)
                    themePopup.lastItem?.image = ReaderStyle.symbol(symbol,size: 12)
                }
                themePopup.target = self
                themePopup.action = #selector(themeChanged(_:))
                themePopup.bezelStyle = .texturedRounded
                (themePopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
                themePopup.font = .systemFont(ofSize: 11,weight: .medium)
                themePopup.widthAnchor.constraint(equalToConstant: 102).isActive = true
                themePopup.toolTip = "深色阅读会同时改变 PDF 页面；保持原色见「显示」菜单"
                themePopup.setAccessibilityLabel("阅读外观")
                themePopup.setAccessibilityIdentifier("readingTheme")
                item.view = themePopup
                item.label = "阅读外观"
                item.visibilityPriority = .high
            case "color":
                for color in HighlightColor.allCases {
                    colorPopup.addItem(withTitle: color.title)
                    colorPopup.lastItem?.image = ReaderStyle.swatch(color.color)
                }
                colorPopup.imagePosition = .imageOnly
                colorPopup.bezelStyle = .texturedRounded
                (colorPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
                colorPopup.widthAnchor.constraint(equalToConstant: 40).isActive = true
                colorPopup.target = self
                colorPopup.action = #selector(colorChanged(_:))
                colorPopup.toolTip = "设置高亮颜色；选中已有高亮时会修改它"
                colorPopup.setAccessibilityLabel("高亮颜色")
                colorPopup.setAccessibilityIdentifier("highlightColor")
                item.view = colorPopup
                item.label = "高亮颜色"
            case "display":
                displayPopup.addItems(withTitles: ["连续滚动", "单页阅读"])
                displayPopup.item(at: 0)?.image = ReaderStyle.symbol("rectangle.split.1x2",size: 13)
                displayPopup.item(at: 1)?.image = ReaderStyle.symbol("rectangle",size: 13)
                displayPopup.imagePosition = .imageOnly
                displayPopup.bezelStyle = .texturedRounded
                (displayPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
                displayPopup.widthAnchor.constraint(equalToConstant: 42).isActive = true
                displayPopup.toolTip = "连续滚动或单页阅读"
                displayPopup.setAccessibilityLabel("阅读布局")
                displayPopup.target = self
                displayPopup.action = #selector(displayChanged(_:))
                item.view = displayPopup
                item.label = "阅读布局"
            default: return nil
            }
        }
        return item
    }

    @objc private func zoomChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: zoomOut(nil)
        case 1: fitPage(nil)
        default: zoomIn(nil)
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier.rawValue {
        case "highlight", "comment": return readerDocument.canAnnotate && pdfView.currentSelection != nil
        case "note", "color": return readerDocument.canAnnotate
        case "previous": return pdfView.canGoToPreviousPage
        case "next": return pdfView.canGoToNextPage
        default: return true
        }
    }

    @objc private func windowWillClose() {
        searchTask?.cancel()
        pdf.cancelFindString()
        pdfView.onAppearanceChanged = nil
        pdfView.onAnnotationClicked = nil
        pdfView.onPlaceNote = nil
        pdfView.onNoteModeChanged = nil
        thumbnails.pdfView = nil
        pdfView.document = nil
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NotificationCenter.default.post(name: .readerWindowOpened, object: window)
        window?.makeFirstResponder(pdfView)
        if pdf.isLocked { requestPassword() }
    }

    private func requestPassword() {
        guard let window else { return }
        let editedPDF = pdf
        let alert = NSAlert()
        alert.messageText = "此 PDF 需要密码"
        alert.informativeText = "解锁后可以阅读。当前版本对加密 PDF 保持只读，以保留密码保护。"
        alert.addButton(withTitle: "解锁")
        alert.addButton(withTitle: "取消")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = password
        alert.window.initialFirstResponder = password
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.pdf === editedPDF else { return }
            if response == .alertFirstButtonReturn {
                if self.pdf.unlock(withPassword: password.stringValue) {
                    password.stringValue = ""
                    self.pdfView.document = nil
                    self.pdfView.document = self.pdf
                    self.annotationsChanged()
                    self.pageChanged()
                } else {
                    password.stringValue = ""
                    self.requestPassword()
                }
            } else { self.close() }
        }
    }

    @objc func appearanceChanged() {
        window?.appearance = AppearancePreferences.mode.appearance
        themePopup.selectItem(at: ThemeMode.allCases.firstIndex(of: AppearancePreferences.mode) ?? 0)
        updateReadingAppearance()
    }
    private func updateReadingAppearance() {
        pdfView.applyReadingAppearance(dark: AppearancePreferences.isDark(pdfView.effectiveAppearance),
                                       strategy: AppearancePreferences.strategy)
        thumbnails.updateReadingAppearance()
        updateStatus()
    }
    @objc private func themeChanged(_ sender: NSPopUpButton) {
        AppearancePreferences.selectReadingTheme(ThemeMode.allCases[sender.indexOfSelectedItem])
    }
    @objc func setTheme(_ sender: NSMenuItem) { AppearancePreferences.selectReadingTheme(ThemeMode.allCases[sender.tag]) }
    @objc func setStrategy(_ sender: NSMenuItem) { AppearancePreferences.strategy = DarkStrategy.allCases[sender.tag] }

    private func updateStatus() {
        var parts: [String] = []
        if pdf.isEncrypted { parts.append("已加密 · 只读") }
        else if !pdf.allowsCommenting { parts.append("只读") }
        if pdfView.placingNote { parts.append("点击页面插入便签，Esc 取消") }
        if isSearching { parts.append("正在搜索…") }
        else if !searchField.stringValue.isEmpty {
            parts.append("\(searchResults.count) 个结果\(searchTruncated ? "（前 2000 个）" : "")")
        }
        if pdfView.preservingDarkActive {
            if pdfView.imagePreservingRenderer?.isPreparing == true { parts.append("正在准备深色页面…") }
            else if let page = pdfView.currentPage, let reason = pdfView.imagePreservingRenderer?.reason(for: pdf.index(for: page)) {
                parts.append("此页保持原色")
                status.toolTip = reason
            } else { parts.append("深色阅读 · 图片保色"); status.toolTip = "阅读主题只影响显示，保存后的页面保持原色。" }
        } else {
            parts.append(pdfView.basicDarkActive ? "整页反色 · 图片也会变色" : "原色阅读")
            status.toolTip = "阅读主题只影响显示，保存后的页面保持原色。"
        }
        status.stringValue = parts.joined(separator: "    ·    ")
        let current = pdfView.currentPage.map { pdf.index(for: $0) + 1 } ?? 0
        readingInfo.stringValue = "\(current) / \(pdf.pageCount) 页    ·    \(Int((pdfView.scaleFactor * 100).rounded()))%"
        updateSidebarSummary()
    }

    private func updateSidebarSummary() {
        let tab = sidebarTabs.selectedSegment
        sidebarDetail.stringValue = tab == 0 ? "共 \(pdf.pageCount) 页" : tab == 1 ? "\(notes.count) 条批注" : isSearching ? "正在搜索文档…" : "\(searchResults.count) 个搜索结果"
        let empty = tab == 1 ? notes.isEmpty : tab == 2 && searchResults.isEmpty
        emptyState.isHidden = !empty || tab == 0
        listScroll.isHidden = tab == 0 || empty
        if tab == 1 {
            emptyState.configure(symbol: "highlighter",title: "还没有批注",detail: "选择文字添加高亮，\n或在页面上放置便签。")
        } else {
            let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            emptyState.configure(symbol: "magnifyingglass",title: isSearching ? "正在查找…" : query.isEmpty ? "搜索这份文档" : "未找到匹配内容",
                                 detail: query.isEmpty ? "输入关键词，快速定位正文。" : isSearching ? "搜索结果会显示在这里。" : "试试更短的关键词。")
        }
    }

    @objc func pageChanged() {
        if let page = pdfView.currentPage {
            pageField.integerValue = pdf.index(for: page) + 1
        }
        pageCount.stringValue = "/ \(pdf.pageCount)"
        previousButton.isEnabled = pdfView.canGoToPreviousPage
        nextButton.isEnabled = pdfView.canGoToNextPage
        thumbnails.selectCurrentPage()
        updateStatus()
    }
    @objc private func textSelectionChanged() {
        window?.toolbar?.validateVisibleItems()
        guard !(pdfView.currentSelection?.string ?? "").isEmpty else { return }
        // A new text selection is a new editing context. Do not recolor the
        // previously selected annotation when choosing the next highlight color.
        selectedAnnotation = nil
        suppressListSelection = true
        list.deselectAll(nil)
        suppressListSelection = false
    }
    @objc func goToPage(_ sender: Any?) {
        let number = pageField.integerValue
        guard number > 0, number <= pdf.pageCount, let page = pdf.page(at: number - 1) else {
            NSSound.beep(); pageChanged(); return
        }
        pdfView.go(to: page)
        window?.makeFirstResponder(pdfView)
    }
    @objc func focusPage(_ sender: Any?) { window?.makeFirstResponder(pageField); pageField.selectText(nil) }
    @objc func nextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func previousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func zoomIn(_ sender: Any?) { fitWidthEnabled = false; pdfView.autoScales = false; pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { fitWidthEnabled = false; pdfView.autoScales = false; pdfView.zoomOut(sender) }
    @objc func actualSize(_ sender: Any?) { fitWidthEnabled = false; pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    @objc func fitPage(_ sender: Any?) { fitWidthEnabled = false; pdfView.autoScales = true }
    @objc func fitWidth(_ sender: Any?) {
        fitWidthEnabled = true
        guard let page = pdfView.currentPage else { return }
        let width = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page).width / pdfView.scaleFactor
        guard width > 0 else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, (pdfView.bounds.width - 30) / width))
    }
    @objc private func windowResized() { if fitWidthEnabled { fitWidth(nil) } }
    @objc private func displayChanged(_ sender: NSPopUpButton) {
        pdfView.displayMode = sender.indexOfSelectedItem == 0 ? .singlePageContinuous : .singlePage
        if fitWidthEnabled { fitWidth(nil) }
    }
    @objc func toggleSidebar(_ sender: Any?) {
        sidebar.isHidden.toggle()
        split.adjustSubviews()
        if fitWidthEnabled { fitWidth(nil) }
    }
    @objc private func sidebarTabChanged() {
        thumbnails.isHidden = sidebarTabs.selectedSegment != 0
        listScroll.isHidden = sidebarTabs.selectedSegment == 0
        list.reloadData()
        updateSidebarSummary()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        searchTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.searchNow(nil) }
        searchTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    @objc func focusSearch(_ sender: Any?) {
        sidebar.isHidden = false
        sidebarTabs.selectedSegment = 2
        sidebarTabChanged()
        (window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "search" } as? NSSearchToolbarItem)?.beginSearchInteraction()
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }
    @objc func searchNow(_ sender: Any?) {
        searchTask?.cancel()
        pdf.cancelFindString()
        searchResults.removeAll()
        searchTruncated = false
        pdfView.highlightedSelections = nil
        list.reloadData()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = !query.isEmpty && !pdf.isLocked
        if isSearching {
            sidebar.isHidden = false
            sidebarTabs.selectedSegment = 2
            sidebarTabChanged()
            pdf.beginFindString(query, withOptions: [.caseInsensitive])
        }
        updateStatus()
    }
    @objc private func foundMatch(_ notification: Notification) {
        guard isSearching, let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        guard searchResults.count < 2000 else { searchTruncated = true; return }
        searchResults.append(selection)
        // Throttle table redraws; drawing every match makes large searches expensive.
        if searchResults.count <= 10 || searchResults.count % 50 == 0 { list.reloadData(); updateSidebarSummary() }
    }
    @objc private func searchEnded() {
        isSearching = false
        list.reloadData()
        updateStatus()
    }
    @objc func nextMatch(_ sender: Any?) { moveMatch(by: 1) }
    @objc func previousMatch(_ sender: Any?) { moveMatch(by: -1) }
    private func moveMatch(by delta: Int) {
        guard !searchResults.isEmpty else { return }
        sidebarTabs.selectedSegment = 2
        sidebarTabChanged()
        let current = list.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : searchResults.count - 1) : (current + delta + searchResults.count) % searchResults.count
        list.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        list.scrollRowToVisible(next)
    }

    private func requireEditing(annotation: PDFAnnotation? = nil) -> Bool {
        guard readerDocument.canAnnotate, annotation?.allowsReviewEditing != false else {
            let alert = NSAlert()
            alert.messageText = annotation?.allowsReviewEditing == false ? "此批注已锁定" : "此 PDF 当前只读"
            alert.informativeText = pdf.isEncrypted ? ReaderError.protectedSave.localizedDescription :
                (annotation?.allowsReviewEditing == false ? "此批注已被原作者锁定，可查看内容，但不能修改或删除。" : "文档未解锁或禁止添加批注。")
            if let window { alert.beginSheetModal(for: window) }
            return false
        }
        return true
    }
    @objc func highlightSelection(_ sender: Any?) {
        guard requireEditing(), let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty else { NSSound.beep(); return }
        let marks = AnnotationStore.highlights(for: selection, color: currentColor)
        guard !marks.isEmpty else { return }
        readerDocument.withUndoGroup(named: "添加高亮") {
            for (page, annotation) in marks { setPresence(annotation, page: page, present: true) }
        }
        pdfView.clearSelection()
        selectedAnnotation = marks.first?.1
        selectAnnotation(marks[0].1)
    }
    private var currentColor: NSColor { (HighlightColor(rawValue: colorPopup.indexOfSelectedItem) ?? .yellow).color }

    // Inverse operations register themselves, so undo and redo preserve standard
    // annotations and NSDocument's saved/modified state.
    func setPresence(_ annotation: PDFAnnotation, page: PDFPage, present: Bool) {
        readerDocument.withUndoGroup(named: present ? "添加批注" : "删除批注") {
            readerDocument.undoManager?.registerUndo(withTarget: self) { target in
                target.setPresence(annotation, page: page, present: !present)
            }
            if present { page.addAnnotation(annotation) } else { page.removeAnnotation(annotation) }
        }
        pdfView.annotationsChanged(on: page)
        if !present && selectedAnnotation === annotation { selectedAnnotation = nil }
        readerDocument.contentChanged(on: page)
    }
    func changeContents(_ annotation: PDFAnnotation, text: String?) {
        let old = annotation.contents
        readerDocument.withUndoGroup(named: "编辑评论") {
            readerDocument.undoManager?.registerUndo(withTarget: self) { $0.changeContents(annotation, text: old) }
            annotation.contents = text
            annotation.modificationDate = Date()
        }
        if let page = annotation.page { pdfView.annotationsChanged(on: page) }
        if let page = annotation.page { readerDocument.contentChanged(on: page) }
    }
    func changeColor(_ annotation: PDFAnnotation, color: NSColor) {
        let old = annotation.color
        readerDocument.withUndoGroup(named: "修改高亮颜色") {
            readerDocument.undoManager?.registerUndo(withTarget: self) { $0.changeColor(annotation, color: old) }
            annotation.color = color
            annotation.modificationDate = Date()
        }
        if let page = annotation.page { pdfView.annotationsChanged(on: page) }
        if let page = annotation.page { readerDocument.contentChanged(on: page) }
    }
    @objc private func colorChanged(_ sender: Any?) {
        guard readerDocument.canAnnotate, let annotation = selectedAnnotation,
              annotation.type == "Highlight", annotation.allowsReviewEditing else { return }
        changeColor(annotation, color: currentColor)
    }
    @objc func placeNote(_ sender: Any?) {
        guard requireEditing() else { return }
        pdfView.placingNote = true
        window?.makeFirstResponder(pdfView)
        updateStatus()
    }
    private func composeNote(on page: PDFPage, at point: NSPoint) {
        updateStatus()
        guard requireEditing() else { return }
        showEditor(title: "插入便签", text: "", editable: true) { [weak self] text in
            guard let self, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let note = AnnotationStore.note(at: point, on: page, text: text)
            self.setPresence(note, page: page, present: true)
            self.selectAnnotation(note)
        }
    }
    @objc func commentSelection(_ sender: Any?) {
        guard requireEditing() else { return }
        if let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            // Capture the exact selection now; opening a sheet may change focus.
            let marks = AnnotationStore.highlights(for: selection, color: currentColor)
            showEditor(title: "为选中文字添加评论", text: "", editable: true) { [weak self] text in
                guard let self, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.readerDocument.withUndoGroup(named: "添加高亮评论") {
                    for (page, mark) in marks {
                        mark.contents = text
                        self.setPresence(mark, page: page, present: true)
                    }
                }
                self.pdfView.clearSelection()
                if let mark = marks.first?.1 { self.selectAnnotation(mark) }
            }
        } else { editAnnotation(sender) }
    }
    @objc func editAnnotation(_ sender: Any?) {
        guard let annotation = actionAnnotation else { NSSound.beep(); return }
        showEditor(title: annotation.reviewTitle, text: annotation.contents ?? "",
                   editable: readerDocument.canAnnotate && annotation.allowsReviewEditing) { [weak self] text in
            guard self?.readerDocument.canAnnotate == true, annotation.allowsReviewEditing else { return }
            if annotation.contents != text { self?.changeContents(annotation, text: text) }
        }
    }
    private var actionAnnotation: PDFAnnotation? {
        return selectedAnnotation
    }
    @objc func deleteAnnotation(_ sender: Any?) {
        guard let annotation = actionAnnotation, let page = annotation.page,
              requireEditing(annotation: annotation) else { NSSound.beep(); return }
        setPresence(annotation, page: page, present: false)
    }
    private func showEditor(title: String, text: String, editable: Bool, completion: @escaping (String) -> Void) {
        guard let window, !noteEditorOpen else { return }
        let editedPDF = pdf
        noteEditorOpen = true
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = editable ? "评论将存入标准 PDF 批注。编辑完成后，请按 ⌘S 保存文档。" : "此批注当前只读。"
        alert.addButton(withTitle: editable ? "完成" : "关闭")
        if editable { alert.addButton(withTitle: "取消") }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 390, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = AnnotationDraftTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.isEditable = editable
        editor.allowsUndo = editable
        editor.setAccessibilityLabel("批注内容")
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
        editor.undoManager?.removeAllActions()
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = editor
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.pdf === editedPDF else { return }
            self.noteEditorOpen = false
            if response == .alertFirstButtonReturn, editable { completion(editor.string) }
        }
    }
    @objc func annotationsChanged(_ notification: Notification? = nil) {
        thumbnails.reload()
        if let page = notification?.userInfo?["page"] as? PDFPage {
            let index = pdf.index(for: page)
            if index != NSNotFound { notesByPage[index] = AnnotationStore.entries(on: page, pageIndex: index) }
        } else {
            notesByPage.removeAll()
            for index in 0..<pdf.pageCount {
                if let page = pdf.page(at: index) { notesByPage[index] = AnnotationStore.entries(on: page, pageIndex: index) }
            }
        }
        notes = notesByPage.keys.sorted().flatMap { notesByPage[$0] ?? [] }
        let liveIDs = Set(notes.map { ObjectIdentifier($0.annotation) })
        excerptCache = excerptCache.filter { liveIDs.contains($0.key) }
        if let selectedAnnotation, !notes.contains(where: { $0.annotation === selectedAnnotation }) {
            self.selectedAnnotation = nil
        }
        list.reloadData()
        pdfView.needsDisplay = true
        updateStatus()
    }
    func selectAnnotation(_ annotation: PDFAnnotation) {
        pdfView.clearSelection()
        selectedAnnotation = annotation
        sidebar.isHidden = false
        sidebarTabs.selectedSegment = 1
        sidebarTabChanged()
        if let index = notes.firstIndex(where: { $0.annotation === annotation }) {
            suppressListSelection = true
            list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            list.scrollRowToVisible(index)
            suppressListSelection = false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarTabs.selectedSegment == 1 ? notes.count : searchResults.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ReaderSelectionRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("review"),owner: self) as? ReaderReviewCell) ?? ReaderReviewCell()
        cell.identifier = .init("review")
        if sidebarTabs.selectedSegment == 1 {
            guard row < notes.count else { return nil }
            let entry = notes[row]
            let kind = entry.annotation.reviewTitle + (entry.annotation.allowsReviewEditing ? "" : " · 已锁定")
            let key = ObjectIdentifier(entry.annotation)
            let excerpt = excerptCache[key] ?? entry.excerpt.replacingOccurrences(of: "\n",with: " ")
            excerptCache[key] = excerpt
            cell.configure(caption: "第 \(entry.pageIndex + 1) 页 · \(kind)",excerpt: excerpt,
                           comment: entry.annotation.contents?.isEmpty == false ? entry.annotation.contents! : "双击添加评论",
                           symbol: entry.annotation.type == "Highlight" ? "highlighter" : "text.bubble",
                           color: entry.annotation.type == "Highlight" ? .controlAccentColor : .secondaryLabelColor)
        } else {
            guard row < searchResults.count, let page = searchResults[row].pages.first else { return nil }
            let match = searchResults[row]
            let line = page.selectionForLine(at: match.bounds(for: page).origin)?.string ?? match.string ?? ""
            cell.configure(caption: "第 \(pdf.index(for: page) + 1) 页",excerpt: line.replacingOccurrences(of: "\n",with: " "),
                           comment: "",symbol: "magnifyingglass",color: .secondaryLabelColor)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressListSelection else { return }
        let index = list.selectedRow
        guard index >= 0 else { return }
        if sidebarTabs.selectedSegment == 1, index < notes.count {
            let entry = notes[index]
            pdfView.clearSelection()
            selectedAnnotation = entry.annotation
            pdfView.go(to: entry.annotation.bounds.insetBy(dx: -30, dy: -30), on: entry.page)
        } else if sidebarTabs.selectedSegment == 2, index < searchResults.count {
            let selection = searchResults[index]
            selection.color = .systemOrange
            pdfView.highlightedSelections = [selection]
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setTheme(_:)):
            menuItem.state = ThemeMode.allCases[menuItem.tag] == AppearancePreferences.mode ? .on : .off
        case #selector(setStrategy(_:)):
            menuItem.state = DarkStrategy.allCases[menuItem.tag] == AppearancePreferences.strategy ? .on : .off
        case #selector(highlightSelection(_:)): return readerDocument.canAnnotate && pdfView.currentSelection != nil
        case #selector(placeNote(_:)), #selector(commentSelection(_:)): return readerDocument.canAnnotate
        case #selector(deleteAnnotation(_:)): return readerDocument.canAnnotate && actionAnnotation?.allowsReviewEditing == true && sidebarTabs.selectedSegment == 1
        case #selector(editAnnotation(_:)): return actionAnnotation != nil && sidebarTabs.selectedSegment != 2
        case #selector(nextPage(_:)): return pdfView.canGoToNextPage
        case #selector(previousPage(_:)): return pdfView.canGoToPreviousPage
        case #selector(nextMatch(_:)), #selector(previousMatch(_:)): return !searchResults.isEmpty
        default: break
        }
        return true
    }
}

private final class AnnotationTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        return super.menu(for: event)
    }
}
