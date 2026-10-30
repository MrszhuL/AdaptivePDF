import AppKit

enum MenuBuilder {
    static func build() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
        }
        let app = submenu("AdaptivePDF")
        add(app, "关于 AdaptivePDF", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(app, "第三方许可…", #selector(AppDelegate.showThirdPartyNotices(_:)))
        app.addItem(.separator())
        add(app, "隐藏 AdaptivePDF", #selector(NSApplication.hide(_:)), "h")
        add(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "全部显示", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "退出 AdaptivePDF", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("文件")
        add(file, "打开…", #selector(NSDocumentController.openDocument(_:)), "o", target: NSDocumentController.shared)
        file.addItem(.separator())
        add(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        add(file, "保存", #selector(NSDocument.save(_:)), "s")
        add(file, "另存为…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])

        let edit = submenu("编辑")
        add(edit, "撤销", Selector(("undo:")), "z")
        add(edit, "重做", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), "x")
        add(edit, "复制", #selector(NSText.copy(_:)), "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "搜索全文", #selector(ReaderWindowController.focusSearch(_:)), "f")
        add(edit, "下一个匹配", #selector(ReaderWindowController.nextMatch(_:)), "g")
        add(edit, "上一个匹配", #selector(ReaderWindowController.previousMatch(_:)), "g", [.command, .shift])

        let view = submenu("显示")
        add(view, "放大", #selector(ReaderWindowController.zoomIn(_:)), "=")
        add(view, "缩小", #selector(ReaderWindowController.zoomOut(_:)), "-")
        add(view, "实际大小", #selector(ReaderWindowController.actualSize(_:)), "0")
        add(view, "适合页面", #selector(ReaderWindowController.fitPage(_:)), "9")
        add(view, "适合宽度", #selector(ReaderWindowController.fitWidth(_:)), "8")
        view.addItem(.separator())
        add(view, "上一页", #selector(ReaderWindowController.previousPage(_:)), "\u{f702}", [.command])
        add(view, "下一页", #selector(ReaderWindowController.nextPage(_:)), "\u{f703}", [.command])
        add(view, "跳转页码", #selector(ReaderWindowController.focusPage(_:)), "l")
        add(view, "显示 / 隐藏侧边栏", #selector(ReaderWindowController.toggleSidebar(_:)), "d", [.command, .option])
        view.addItem(.separator())
        for (index, mode) in ThemeMode.allCases.enumerated() {
            let item = view.addItem(withTitle: mode.title, action: #selector(ReaderWindowController.setTheme(_:)), keyEquivalent: "")
            item.tag = index
        }
        view.addItem(.separator())
        for (index, strategy) in DarkStrategy.allCases.enumerated() {
            let item = view.addItem(withTitle: strategy.title, action: #selector(ReaderWindowController.setStrategy(_:)), keyEquivalent: "")
            item.tag = index
        }

        let annotate = submenu("批注")
        add(annotate, "高亮选中文字", #selector(ReaderWindowController.highlightSelection(_:)), "h", [.command, .shift])
        add(annotate, "为选中文字添加评论…", #selector(ReaderWindowController.commentSelection(_:)), "k", [.command, .shift])
        add(annotate, "插入便签…", #selector(ReaderWindowController.placeNote(_:)), "n", [.command, .shift])
        add(annotate, "编辑所选批注…", #selector(ReaderWindowController.editAnnotation(_:)), "e", [.command, .shift])
        add(annotate, "删除所选批注", #selector(ReaderWindowController.deleteAnnotation(_:)), "\u{8}", [.command])

        let window = submenu("窗口")
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "缩放", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "全部前置", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
        return main
    }
}
