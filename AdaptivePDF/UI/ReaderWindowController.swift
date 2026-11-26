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
    private let documentTitle = NSTextField(labelWithString: "")
    private let navigationPopover = NSPopover()
    private let navigationAnchor = NSView()
    private let activityHUD = ReaderActivityHUD()
    private let themePopup = NSPopUpButton()
    private let colorButton = ReaderToolbarButton()
    private let colorPopover = NSPopover()
    private var highlightColor = HighlightColor.yellow.color
    private let displayPopup = NSPopUpButton()
    private var notes: [AnnotationEntry] = []
    private var notesByPage: [Int: [AnnotationEntry]] = [:]
    private var notesIndexed = false
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
        let window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.minSize = NSSize(width: 820, height: 540)
        if let saved = AppearancePreferences.readerWindowSize {
            let available = (NSScreen.main ?? window.screen)?.visibleFrame.size ?? saved
            window.setContentSize(NSSize(width: max(window.minSize.width, min(saved.width, available.width)),
                                        height: max(window.minSize.height, min(saved.height, available.height))))
        }
        window.isRestorable = false
        window.title = readerDocument.displayName
        window.titleVisibility = .hidden
        window.pdfView = pdfView
        window.onZoom = { [weak self] in self?.showZoomFeedback() }
        window.tabbingMode = .disallowed
        window.center()
        buildContent()
        buildToolbar()
        pdfView.document = pdf
        pdfView.onManualZoom = { [weak self] in self?.fitWidthEnabled = false }
        pdfView.imagePreservingRenderer = readerDocument.imagePreservingRenderer
        pdfView.onRenderingChanged = { [weak self] pages in
            guard let self else { return }
            for index in pages { self.thumbnails.invalidatePage(index) }
            self.updateReaderControls()
        }
        thumbnails.pdfView = pdfView
        pdfView.onAppearanceChanged = { [weak self] in self?.updateReadingAppearance() }
        pdfView.onAnnotationClicked = { [weak self] annotation, edit in
            self?.selectAnnotation(annotation)
            if edit { self?.editAnnotation(nil) }
        }
        pdfView.onPlaceNote = { [weak self] page, point in self?.composeNote(on: page, at: point) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appearanceChanged), name: AppearancePreferences.changed, object: nil)
        center.addObserver(self, selector: #selector(annotationsChanged(_:)), name: .readerAnnotationsChanged, object: readerDocument)
        center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        center.addObserver(self, selector: #selector(readerScrolled(_:)), name: NSScrollView.didLiveScrollNotification, object: nil)
        center.addObserver(self, selector: #selector(textSelectionChanged), name: .PDFViewSelectionChanged, object: pdfView)
        center.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: pdf)
        center.addObserver(self, selector: #selector(searchEnded), name: .PDFDocumentDidEndFind, object: pdf)
        center.addObserver(self, selector: #selector(windowResized), name: NSSplitView.didResizeSubviewsNotification, object: split)
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        appearanceChanged()
        pageChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { NotificationCenter.default.removeObserver(self); searchTask?.cancel() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { readerDocument.undoManager }

    func windowDidResize(_ notification: Notification) {
        windowResized()
        guard window?.inLiveResize == false else { return }
        rememberWindowSize()
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberWindowSize() }

    private func rememberWindowSize() {
        guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        AppearancePreferences.readerWindowSize = window.contentRect(forFrameRect: window.frame).size
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        documentTitle.stringValue = window?.title ?? readerDocument.displayName
        documentTitle.toolTip = documentTitle.stringValue
    }

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
        if fitWidthEnabled { applyFitWidth() }
        if loaded.isLocked { requestPassword() }
        else if !searchField.stringValue.isEmpty { searchNow(nil) }
    }

    private func buildContent() {
        guard let window, let content = window.contentView,
              let layout = window.contentLayoutGuide as? NSLayoutGuide else { return }
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        for overlay in [navigationAnchor, activityHUD] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(overlay)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: layout.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            navigationAnchor.widthAnchor.constraint(equalToConstant: 1),
            navigationAnchor.heightAnchor.constraint(equalToConstant: 1),
            navigationAnchor.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            navigationAnchor.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            activityHUD.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            activityHUD.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        sidebar.frame.size.width = 212
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pdfView)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        sidebarHeading.font = .systemFont(ofSize: 14,weight: .semibold)
        sidebarDetail.font = .systemFont(ofSize: 11)
        sidebarDetail.textColor = .secondaryLabelColor
        for label in [sidebarHeading,sidebarDetail] { label.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(label) }
        sidebarTabs.target = self
        sidebarTabs.action = #selector(sidebarTabChanged)
        sidebarTabs.selectedSegment = 0
        sidebarTabs.font = .systemFont(ofSize: 11,weight: .medium)
        sidebarTabs.segmentStyle = .rounded
        sidebarTabs.segmentDistribution = .fillEqually
        for (index,symbol) in ["square.grid.2x2","highlighter","magnifyingglass"].enumerated() {
            sidebarTabs.setImage(ReaderStyle.symbol(symbol,size: 11),forSegment: index)
        }
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
        list.rowHeight = 96
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
                view.topAnchor.constraint(equalTo: sidebarTabs.bottomAnchor, constant: 14),
                view.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            sidebarHeading.topAnchor.constraint(equalTo: sidebar.topAnchor,constant: 20),
            sidebarHeading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor,constant: 20),
            sidebarDetail.topAnchor.constraint(equalTo: sidebarHeading.bottomAnchor,constant: 6),
            sidebarDetail.leadingAnchor.constraint(equalTo: sidebarHeading.leadingAnchor),
            sidebarTabs.topAnchor.constraint(equalTo: sidebarDetail.bottomAnchor, constant: 14),
            sidebarTabs.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarTabs.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            sidebarTabs.heightAnchor.constraint(equalToConstant: 30)
        ])
        sidebarTabChanged()
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbarV4")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        if !toolbar.items.contains(where: { $0.itemIdentifier.rawValue == "search" }) {
            toolbar.insertItem(withItemIdentifier: .init("search"), at: toolbar.items.count)
        }
        window?.toolbarStyle = .unifiedCompact
    }
    private let toolbarNames = ["sidebar", "documentTitle", "open", "previous", "next", "page", "zoom", "zoomOut", "zoomIn", "fit", "display", "highlight", "color", "comment", "note", "theme", "search"]
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarNames.map { .init($0) } + [.flexibleSpace, .space]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["sidebar", "documentTitle", NSToolbarItem.Identifier.flexibleSpace.rawValue, "highlight", "color", "note", "theme", "search"].map { .init($0) }
    }
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.init("search")]
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
            let button = ReaderToolbarButton()
            button.image = ReaderStyle.symbol(symbol,size: 14,weight: .medium)
            button.target = item.target; button.action = action
            button.toolTip = title; button.setAccessibilityLabel(title)
            item.view = button
            if identifier.rawValue == "sidebar" { item.visibilityPriority = .high }
            if ["comment","note"].contains(identifier.rawValue) { item.visibilityPriority = .low }
        } else {
            switch identifier.rawValue {
            case "documentTitle":
                item.label = "文件名"
                guard flag else { item.image = ReaderStyle.symbol("doc.text"); return item }
                documentTitle.stringValue = window?.title ?? readerDocument.displayName
                documentTitle.toolTip = documentTitle.stringValue
                documentTitle.font = .systemFont(ofSize: 13.5, weight: .semibold)
                documentTitle.lineBreakMode = .byTruncatingMiddle
                documentTitle.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
                item.view = documentTitle
            case "page":
                item.label = "跳转页码"
                item.image = ReaderStyle.symbol("doc.text")
                item.target = self
                item.action = #selector(focusPage(_:))
            case "zoom":
                item.label = "缩放比例"
                item.image = ReaderStyle.symbol("magnifyingglass")
                item.target = self
                item.action = #selector(focusZoom(_:))
            case "search":
                item.label = "搜索"
                guard flag else { item.image = ReaderStyle.symbol("magnifyingglass"); return item }
                searchField.placeholderString = "搜索文档"
                searchField.setAccessibilityLabel("全文搜索")
                searchField.setAccessibilityIdentifier("fullTextSearch")
                searchField.delegate = self
                searchField.target = self
                searchField.action = #selector(searchNow(_:))
                searchField.controlSize = .regular
                searchField.font = .systemFont(ofSize: 11.5)
                let size = NSSize(width: 118, height: 24)
                let holder = NSView(frame: NSRect(origin: .zero, size: size))
                holder.widthAnchor.constraint(equalToConstant: size.width).isActive = true
                holder.heightAnchor.constraint(equalToConstant: size.height).isActive = true
                searchField.frame = holder.bounds
                searchField.autoresizingMask = [.width, .height]
                holder.addSubview(searchField)
                item.view = holder
                item.visibilityPriority = .user
            case "theme":
                item.label = "阅读外观"
                guard flag else { item.image = ReaderStyle.symbol("circle.lefthalf.filled"); return item }
                themePopup.removeAllItems()
                for (title,symbol) in [("跟随系统","circle.lefthalf.filled"),("浅色","sun.max"),("深色","moon")] {
                    themePopup.addItem(withTitle: title)
                    themePopup.lastItem?.image = ReaderStyle.symbol(symbol,size: 12)
                }
                themePopup.target = self
                themePopup.action = #selector(themeChanged(_:))
                themePopup.bezelStyle = .texturedRounded
                themePopup.isBordered = false
                themePopup.imagePosition = .imageOnly
                (themePopup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
                themePopup.font = .systemFont(ofSize: 12,weight: .medium)
                themePopup.widthAnchor.constraint(equalToConstant: 28).isActive = true
                themePopup.toolTip = "深色阅读会同时改变 PDF 页面；保持原色见「显示」菜单"
                themePopup.setAccessibilityLabel("阅读外观")
                themePopup.setAccessibilityIdentifier("readingTheme")
                item.view = themePopup
                item.visibilityPriority = .high
            case "color":
                item.label = "高亮颜色"
                guard flag else { item.image = ReaderStyle.colorDot(highlightColor); return item }
                colorButton.image = ReaderStyle.colorDot(highlightColor)
                colorButton.target = self; colorButton.action = #selector(showColorPalette(_:))
                colorButton.toolTip = "高亮颜色"
                colorButton.setAccessibilityLabel("高亮颜色")
                colorButton.setAccessibilityIdentifier("highlightColor")
                item.view = colorButton
            case "display":
                item.label = "阅读布局"
                guard flag else { item.image = ReaderStyle.symbol("rectangle.split.1x2"); return item }
                displayPopup.removeAllItems()
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
            default: return nil
            }
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let enabled: Bool
        switch item.itemIdentifier.rawValue {
        case "highlight", "comment": enabled = readerDocument.canAnnotate && pdfView.currentSelection != nil
        case "note", "color": enabled = readerDocument.canAnnotate
        case "page", "zoom": enabled = !pdf.isLocked && pdf.pageCount > 0
        case "previous": enabled = pdfView.canGoToPreviousPage
        case "next": enabled = pdfView.canGoToNextPage
        default: enabled = true
        }
        (item.view as? NSControl)?.isEnabled = enabled
        return enabled
    }
    private func validateReadingToolbar() {
        for item in window?.toolbar?.items ?? [] { item.isEnabled = validateToolbarItem(item) }
    }

    @objc private func windowWillClose() {
        colorPopover.close()
        navigationPopover.close()
        activityHUD.hide()
        searchTask?.cancel()
        pdf.cancelFindString()
        pdfView.onAppearanceChanged = nil
        pdfView.onAnnotationClicked = nil
        pdfView.onPlaceNote = nil
        thumbnails.pdfView = nil
        pdfView.imagePreservingRenderer = nil
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
        updateReaderControls()
    }
    @objc private func themeChanged(_ sender: NSPopUpButton) {
        AppearancePreferences.selectReadingTheme(ThemeMode.allCases[sender.indexOfSelectedItem])
    }
    @objc func setTheme(_ sender: NSMenuItem) { AppearancePreferences.selectReadingTheme(ThemeMode.allCases[sender.tag]) }
    @objc func setStrategy(_ sender: NSMenuItem) { AppearancePreferences.strategy = DarkStrategy.allCases[sender.tag] }

    private func updateReaderControls() {
        let defaultHint = "切换阅读外观"
        if pdfView.preservingDarkActive, let page = pdfView.currentPage,
           let reason = pdfView.imagePreservingRenderer?.reason(for: pdf.index(for: page)) {
            themePopup.toolTip = "此页保持原色 · \(reason)"
        } else {
            themePopup.toolTip = defaultHint
        }
        validateReadingToolbar()
        updateSidebarSummary()
    }

    @objc private func readerScrolled(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView,
              scrollView === pdfView.documentView?.enclosingScrollView,
              let page = pdfView.currentPage else { return }
        activityHUD.show("\(pdf.index(for: page) + 1) / \(pdf.pageCount) 页")
    }

    private func showZoomFeedback() {
        guard !pdf.isLocked, pdf.pageCount > 0 else { return }
        activityHUD.show(zoomPercent + "%")
    }

    private func updateSidebarSummary() {
        let tab = sidebarTabs.selectedSegment
        sidebarHeading.stringValue = tab == 0 ? "页面概览" : tab == 1 ? "我的批注" : "文档搜索"
        sidebarDetail.stringValue = tab == 0 ? "共 \(pdf.pageCount) 页" : tab == 1 ? "\(notes.count) 条批注" : isSearching ? "正在搜索文档…" : "\(searchResults.count) 个搜索结果\(searchTruncated ? "（前 2000 个）" : "")"
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
        pdfView.prepareDarkPages()
        thumbnails.selectCurrentPage()
        updateReaderControls()
    }
    @objc private func textSelectionChanged() {
        validateReadingToolbar()
        guard !(pdfView.currentSelection?.string ?? "").isEmpty else { return }
        // A new text selection is a new editing context. Do not recolor the
        // previously selected annotation when choosing the next highlight color.
        selectedAnnotation = nil
        suppressListSelection = true
        list.deselectAll(nil)
        suppressListSelection = false
    }
    private var zoomPercent: String {
        let percent = (pdfView.scaleFactor * 10_000).rounded() / 100
        return Double(percent).formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    @objc func focusPage(_ sender: Any?) {
        let current = pdfView.currentPage.map { pdf.index(for: $0) + 1 } ?? 1
        showNavigationInput(title: "跳转页码", value: String(current), hint: "1–\(pdf.pageCount) 页",
                            shortcuts: [("上一页", #selector(previousPage(_:))), ("下一页", #selector(nextPage(_:)))]) { [weak self] value in
            guard let self, let number = Int(value), (1...self.pdf.pageCount).contains(number),
                  let page = self.pdf.page(at: number - 1) else { return false }
            self.pdfView.go(to: page)
            return true
        }
    }

    @objc func focusZoom(_ sender: Any?) {
        showNavigationInput(title: "缩放比例", value: zoomPercent, hint: "10%–800%",
                            shortcuts: [("适合宽度", #selector(fitWidth(_:))), ("适合页面", #selector(fitPage(_:))),
                                        ("100%", #selector(actualSize(_:)))]) { [weak self] value in
            guard let self else { return false }
            let digits = value.hasSuffix("%") ? value.dropLast().trimmingCharacters(in: .whitespaces) : value
            let separator = Locale.current.decimalSeparator ?? "."
            guard let percent = Double(digits.replacingOccurrences(of: separator, with: ".")),
                  percent.isFinite, (10...800).contains(percent) else { return false }
            self.pdfView.setManualScale(percent / 100)
            self.showZoomFeedback()
            return true
        }
    }

    private func showNavigationInput(title: String, value: String, hint: String,
                                     shortcuts: [(String, Selector)],
                                     apply: @escaping (String) -> Bool) {
        guard !pdf.isLocked, pdf.pageCount > 0, window?.attachedSheet == nil else { return }
        navigationPopover.close()
        activityHUD.hide()
        let controller = ReaderNumberPopover(title: title, value: value, hint: hint, shortcuts: shortcuts) { [weak self] value in
            guard apply(value) else { return false }
            self?.navigationPopover.close()
            self?.window?.makeFirstResponder(self?.pdfView)
            return true
        } onShortcut: { [weak self] action in
            guard let self else { return }
            self.navigationPopover.close()
            self.perform(action, with: nil)
            self.window?.makeFirstResponder(self.pdfView)
        }
        navigationPopover.behavior = .transient
        navigationPopover.contentViewController = controller
        navigationPopover.show(relativeTo: navigationAnchor.bounds, of: navigationAnchor, preferredEdge: .maxY)
        controller.focusInput()
    }

    @objc func nextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func previousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func zoomIn(_ sender: Any?) {
        fitWidthEnabled = false
        pdfView.autoScales = false
        pdfView.zoomIn(sender)
        showZoomFeedback()
    }
    @objc func zoomOut(_ sender: Any?) {
        fitWidthEnabled = false
        pdfView.autoScales = false
        pdfView.zoomOut(sender)
        showZoomFeedback()
    }
    @objc func actualSize(_ sender: Any?) {
        pdfView.setManualScale(1)
        showZoomFeedback()
    }
    @objc func fitPage(_ sender: Any?) {
        fitWidthEnabled = false
        pdfView.autoScales = true
        showZoomFeedback()
    }
    @objc func fitWidth(_ sender: Any?) {
        fitWidthEnabled = true
        applyFitWidth()
        showZoomFeedback()
    }
    private func applyFitWidth() {
        guard let page = pdfView.currentPage else { return }
        let width = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page).width / pdfView.scaleFactor
        guard width > 0 else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, (pdfView.bounds.width - 30) / width))
    }
    @objc private func windowResized() { if fitWidthEnabled { applyFitWidth() } }
    @objc private func displayChanged(_ sender: NSPopUpButton) {
        pdfView.displayMode = sender.indexOfSelectedItem == 0 ? .singlePageContinuous : .singlePage
        if fitWidthEnabled { applyFitWidth() }
    }
    @objc func toggleSidebar(_ sender: Any?) {
        sidebar.isHidden.toggle()
        split.adjustSubviews()
        thumbnails.scheduleViewportUpdate()
        if fitWidthEnabled { applyFitWidth() }
    }
    @objc private func sidebarTabChanged() {
        thumbnails.isHidden = sidebarTabs.selectedSegment != 0
        thumbnails.scheduleViewportUpdate()
        if sidebarTabs.selectedSegment == 1 { indexNotesIfNeeded() }
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
        window?.toolbar?.isVisible = true
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
        updateReaderControls()
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
        updateReaderControls()
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
            if readerDocument.hasDigitalSignatures {
                alert.informativeText = ReaderError.signedSave.localizedDescription
            } else if pdf.isEncrypted {
                alert.informativeText = ReaderError.protectedSave.localizedDescription
            } else {
                alert.informativeText = annotation?.allowsReviewEditing == false ?
                    "此批注已被原作者锁定，可查看内容，但不能修改或删除。" : "文档未解锁或禁止添加批注。"
            }
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
    private var currentColor: NSColor { highlightColor }

    @objc private func showColorPalette(_ sender: NSButton) {
        if colorPopover.isShown { colorPopover.close(); return }
        let palette = ReaderColorPaletteController(selected: highlightColor,
                                                   custom: AppearancePreferences.customHighlightColor) { [weak self] color in
            self?.applyHighlightColor(color)
        } onEditCustom: { [weak self] in
            self?.editCustomHighlightColor()
        }
        colorPopover.contentViewController = palette
        colorPopover.behavior = .transient
        colorPopover.contentSize = palette.view.frame.size
        colorPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func applyHighlightColor(_ color: NSColor) {
        highlightColor = color
        colorButton.image = ReaderStyle.colorDot(color)
        colorChanged(nil)
        colorPopover.close()
    }

    private func editCustomHighlightColor() {
        guard readerDocument.canAnnotate, let window, window.attachedSheet == nil else { return }
        colorPopover.close()
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 92, height: 28))
        well.colorWellStyle = .expanded
        well.color = AppearancePreferences.customHighlightColor ?? highlightColor
        well.setAccessibilityLabel("自定义高亮颜色")
        well.setAccessibilityIdentifier("customHighlightColor")
        let alert = NSAlert()
        alert.messageText = "自定义高亮颜色"
        alert.accessoryView = well
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            well.deactivate()
            guard response == .alertFirstButtonReturn,
                  let rgb = well.color.usingColorSpace(.sRGB) else { return }
            guard let self else { return }
            let color = rgb.withAlphaComponent(1)
            AppearancePreferences.customHighlightColor = color
            self.applyHighlightColor(color)
        }
    }

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
        updateReaderControls()
    }
    private func composeNote(on page: PDFPage, at point: NSPoint) {
        updateReaderControls()
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
        if let page = notification?.userInfo?["page"] as? PDFPage {
            let index = pdf.index(for: page)
            guard index != NSNotFound else { return }
            thumbnails.invalidatePage(index)
            pdfView.needsDisplay = true
            guard notification?.userInfo?["formOnly"] as? Bool != true, notesIndexed else { return }
            let previous = notesByPage[index] ?? []
            let current = AnnotationStore.entries(on: page, pageIndex: index)
            for entry in previous { excerptCache.removeValue(forKey: ObjectIdentifier(entry.annotation)) }
            notesByPage[index] = current.isEmpty ? nil : current
            if let selectedAnnotation, previous.contains(where: { $0.annotation === selectedAnnotation }),
               !current.contains(where: { $0.annotation === selectedAnnotation }) {
                self.selectedAnnotation = nil
            }
            notes = notesByPage.keys.sorted().flatMap { notesByPage[$0] ?? [] }
        } else {
            thumbnails.reloadDocument()
            notesIndexed = false
            notesByPage.removeAll()
            notes.removeAll()
            excerptCache.removeAll()
            if sidebarTabs.selectedSegment == 1 { indexNotesIfNeeded() }
        }
        if sidebarTabs.selectedSegment == 1 { list.reloadData() }
        updateReaderControls()
    }

    private func indexNotesIfNeeded() {
        guard !notesIndexed, !pdf.isLocked else { return }
        notesIndexed = true
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let entries = AnnotationStore.entries(on: page, pageIndex: index)
            if !entries.isEmpty {
                notesByPage[index] = entries
                notes.append(contentsOf: entries)
            }
        }
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
        case #selector(focusPage(_:)), #selector(focusZoom(_:)): return !pdf.isLocked && pdf.pageCount > 0
        case #selector(nextMatch(_:)), #selector(previousMatch(_:)): return !searchResults.isEmpty
        default: break
        }
        return true
    }
}

private final class ReaderWindow: NSWindow {
    weak var pdfView: ReaderPDFView?
    var onZoom: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard (event.type == .scrollWheel || event.type == .magnify),
              let pdfView, attachedSheet == nil else { super.sendEvent(event); return }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        let oldScale = pdfView.scaleFactor
        if event.type == .scrollWheel,
           pdfView.handleZoomScroll(delta: event.scrollingDeltaY, modifiers: event.modifierFlags,
                                    momentum: event.momentumPhase, at: point) {
            if pdfView.scaleFactor != oldScale { onZoom?() }
            return
        }
        let magnifyingPDF = event.type == .magnify && pdfView.visibleRect.contains(point) && event.magnification != 0
        if magnifyingPDF {
            pdfView.onManualZoom?()
            pdfView.autoScales = false
        }
        super.sendEvent(event)
        if magnifyingPDF, pdfView.scaleFactor != oldScale { onZoom?() }
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
