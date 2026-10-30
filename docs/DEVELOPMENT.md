# AdaptivePDF

面向论文阅读的原生 macOS PDF 阅读器。Swift、AppKit、PDFKit、Core Image，包内附带 qpdf 保真写入组件，无需用户额外安装运行依赖。最低 macOS 15；Release 为包含 Intel x86_64 和 arm64 的 Universal 应用，已在 Intel 上运行验证。

## 构建与启动

当前候选版本为 **1.0.0（build 8）**。可发布性检查、DMG 安装验证与签名公证流程见 [RELEASE.md](../RELEASE.md)；当前仍有发布验收门槛，不能把本地构建包视为已公证的正式发行版。

用 Xcode 16.2 或更高版本打开 `AdaptivePDF.xcodeproj`，选择 **AdaptivePDF → My Mac → Run**。无需手工创建 Target、复制源码或安装 XcodeGen。

也可在项目目录执行：

```sh
./scripts/build.sh Release
open "$(cat build/latest-app-path.txt)"
open -a "$(cat build/latest-app-path.txt)" "$PWD/Tests/Fixtures/Academic.pdf"
```

独立应用通常生成于 `build/AdaptivePDF.app`；若该副本正在使用，构建脚本会保留它，将新版本写入独立路径。每次构建使用隔离的 DerivedData，实际应用路径记录于 `build/latest-app-path.txt`，替换前的未运行副本保留在该次构建目录中。可以将新应用复制到 Applications，并通过 Finder 的「打开方式」选择它。应用注册为 PDF 的可选编辑器，不会主动修改默认 PDF 应用。本地构建使用 ad-hoc 签名；对外分发版本尚未做 Developer ID 签名或公证，不需要关闭任何系统安全功能。

## 使用

- **打开与阅读**：⌘O；支持多个独立文档窗口、拖 PDF 到已打开的阅读窗口、连续滚动和单页模式。文本选择、⌘C 复制、滚动和基本键盘导航使用 PDFKit。
- **导航**：工具栏输入页码；⌘L 聚焦页码；⌘← / ⌘→ 前后翻页。左栏「页面」显示随正文主题变化的缩略图，图片保留原色。缩略图复用同一份矢量显示文档，后台串行渲染小图，缓存最多 48 张、16 MiB；主题或内容变化会丢弃过期结果。
- **缩放**：⌘= / ⌘-；⌘0 实际大小；⌘9 适合页面；⌘8 适合宽度。
- **搜索**：⌘F，输入文字后自动搜索；点击左栏结果定位；⌘G / ⌘⇧G 在匹配项之间移动。大文档异步搜索，列表最多显示 2000 个匹配。
- **高亮**：选中文字，选黄色、绿色、蓝色或粉色，按工具栏高亮按钮或 ⌘⇧H。支持跨行、跨页；跨页生成每页一个标准高亮。
- **文字评论**：选中文字后按 ⌘⇧K，生成带评论的标准高亮。已有高亮可在左栏双击、页面双击或按 ⌘⇧E 编辑评论。
- **便签**：⌘⇧N，然后点击页面位置并输入文字。Esc 取消放置；点击便签编辑。
- **管理批注**：左栏「批注」按页码排序，包含文字摘录与评论；点击跳转，右键编辑或删除。选中高亮后工具栏颜色菜单可修改颜色。⌘⌫ 删除所选批注。
- **导入批注**：侧栏也列出下划线、删除线、文本框、墨迹和其他标准审阅批注；链接、表单控件和弹窗子对象不重复列出。带只读或锁定标记的批注可查看，不能修改或删除。
- **撤销**：⌘Z / ⌘⇧Z，覆盖添加、删除、评论和颜色修改。
- **编辑评论草稿**：编辑框有独立撤销/重做历史，点取消不会把草稿写入 PDF。开始选择新文字时，会退出旧批注的改色状态。
- **保存**：⌘S；⌘⇧S 另存为。修改后窗口有系统未保存标记；关闭时系统提示保存、放弃或取消。
- **基础表单**：原生 PDFKit 文本框、选项和复选框的值随 PDF 保存；原生输入与批注使用文档的同一撤销管理器。只读字段及加密 PDF 的字段不能填写。XFA、JavaScript、复杂联动表单和数字签名未验证。
- **阅读外观**：工具栏选择 Follow System / Light / Dark；选择深色阅读或跟随系统时会启用页面深色，避免之前的 Original 设置造成“深色界面、白色页面”。需要图表原色时，在「显示」菜单明确选择 Original。偏好保存在 UserDefaults，重启后保留，所有打开的窗口同时响应。
- **欢迎窗口外观**：遵循同一个主题偏好，包括重启后的强制浅色/深色；已有欢迎窗口也会随偏好更新。

## 功能范围

| 功能 | 实现 |
| --- | --- |
| 本地打开、多窗口、拖拽打开 | 已实现 |
| 连续/单页、缩放、适合页面/宽度、页码 | 已实现 |
| 原生选择、复制、异步全文搜索与定位 | 已实现 |
| 自动系统外观、强制浅色/深色、持久偏好 | 已实现 |
| 标准跨行/跨页高亮、四种颜色与颜色编辑 | 已实现 |
| 高亮评论、页面便签、编辑与删除 | 已实现 |
| 页面缩略图、批注列表、搜索结果栏 | 已实现 |
| 撤销/重做、修改标记、安全保存、另存为 | 已实现 |
| 密码解锁与加密文档只读保护 | 已实现 |
| 基础 AcroForm 值保存、只读字段保护 | 已实现；验证范围见 TESTING.md |
| 重新载入后同步窗口、搜索与保存模型 | 已实现 |
| 保留嵌入图片颜色的深色模式 | 已实现；复杂混合/特殊绘制页明确回退原色，扫描图片本身保持原色 |

实际验证范围与未验证项目见 [TESTING.md](../TESTING.md)。实现状态不代表所有真实世界 PDF 均已通过测试。

## 主要模块

```text
AdaptivePDF.xcodeproj/             Xcode 工程和共享 Scheme
AdaptivePDF/
  main.swift                      AppKit 入口
  Application/                    生命周期、欢迎窗口、主菜单
  Document/                       PDF 快照、权限、保真批注合并、NSDocument 保存
  Native/QPDFBridge.mm             原始对象图保留与逐页资源校验
  Reader/ReaderPDFView.swift       PDFView、显示滤镜、拖拽、页面坐标与点击
  Appearance/                     外观偏好和 Basic Dark 色彩映射
  Annotation/AnnotationStore.swift 标准高亮、QuadPoints、便签、摘录
  UI/ReaderWindowController.swift  工具栏、侧栏、搜索、编辑器与撤销事务
  Info.plist                      PDF 文件类型和最低系统版本
Tests/                            原生集成检查、独立结构验证、测试 PDF
scripts/                          构建、测试、工程生成脚本
```

## 深色显示的设计与边界

默认深色阅读采用 **保留图片颜色**。qpdf 以词法单元读取内容流，在后台生成只用于显示的矢量副本：调整页面背景和中性灰色绘制指令，彩色绘制保持颜色，图片流、遮罩、ICC 配置、内联图片及其变换/剪裁保留。嵌套 Form XObject 按原有图形状态生成显示副本，保留原字体和文字位置。PDFKit 原文档继续负责选择、搜索、批注与保存；不会把显示副本写回原文件。

原生 PDFPage 绘制入口使用 Core Graphics 显示该副本，原生批注及选择覆盖层仍由原文档提供。显示副本不构造全页位图缓存。主题切换保留页码、缩放和选择；首次准备在后台完成，状态栏显示准备进度。

图片中的白底和文字也属于图片，保持原色；因此整页扫描图片仍可能是白底。中性灰色的矢量线条会随页面调整；这不是对所有插图区域的语义识别。复杂透明混合、特殊颜色空间或模板蒙版等未支持绘制会让该页明确保持原色，状态栏给出提示，不自动改用整页反色。透明图片在普通白纸背景下用白色衬底保持边缘颜色。彩色纸张、复杂叠印、特殊混合或透明叠图不在任意 PDF 的无损保色承诺范围。

「显示」菜单仍有 **Original**（PDF 全部保持原色）和明确的 **Basic Dark 整页反色** 备选；后者会改变图片与高亮颜色，需显式选择。默认深色阅读不会启用整页反色。

保存时，PDFKit 只在临时空白页上生成批注的标准外观，由 qpdf 将变更的批注合并进原始 PDF 对象图；显示副本和滤镜均不进入保存路径。输出后逐页校验原始内容流与完整资源图，包括字体、ToUnicode、图片、页面边界与旋转。

## 批注与数据安全

- 使用标准 `/Highlight` + `/QuadPoints` 和 `/Text` + `/Contents`，没有私有批注数据库。
- 高亮从 `PDFSelection` 的每页文本范围取得逐行区域，QuadPoints 按 Apple 指定的 Z 顺序、相对于批注原点保存。旋转与 CropBox 由 PDFKit 的页面坐标转换处理。竖排、斜排、复杂双栏选区仍需更多真实文档验证。
- 每次批注命令显式维护撤销事务，由 NSDocument 跟踪修改和保存状态。
- 源 PDF 以 Data 快照加载，避免安全替换原文件后仍引用旧文件的懒加载流。qpdf 保留原始对象图，仅替换批注；无修改时返回原始字节。合并后重新解析并核对每一页的内容和资源，校验失败就中止写入。实际临时文件、协调写入、替换、错误和关闭提示由 NSDocument 处理。
- 不启用自动保存。保存失败保留内存中的修改，用户可以重试或另存为。系统文件锁和写入权限仍由 AppKit/文件系统处理。
- 密码 PDF 可解锁阅读，但所有加密文档均禁止修改、保存和另存为，以避免当前版本意外剥离加密。允许批注权限也会被检查。
- 重新载入成功后，现有窗口切换至新的 PDF 对象、重新搜索并保留阅读页和缩放；旧评论草稿随恢复操作丢弃。读取失败则保留原文档和未保存内容。
- **build 3 修复了真实论文上 PDFKit 整篇保存导致公式 Unicode 映射改变的问题。** 新的写入路径保留页面内容和字体/图像流；PDF 容器的对象编号、字典顺序和文件字节仍可能重排，并非增量保存。数字签名、特殊制作软件的私有数据和 PDF/A 尚未全面验证。结构无法安全匹配的非标准 PDF 会拒绝保存，不会回退到破坏性重写。

## 性能与后续改进

复用 PDFKit 的页面平铺渲染、缩略图和搜索；不维护另一份整篇光栅缓存。搜索输入做 250ms 防抖，结果列表分批刷新并限制结果数。PDFKit 对象的显示与修改保持在主线程，避免保存期间并发变更对象。

内存随源文件快照及 PDFKit 缓存增长；已执行三篇真实论文、400 页生成文档和约 49 MB 扫描件的保存、搜索与重开回归，共 490 页。测试包含额外渲染开销，不能把记录的 RSS 当作纯阅读内存或滚动帧率。后续扩大真实文档、辅助功能和交互性能覆盖，再研究可靠的内容感知保色；复杂透明度、混合色彩空间和印刷文档仍需逐类验证。

文件数据读取和 PDF 初始解析已由 NSDocument 放到后台；创建窗口、初次建立批注索引和显式保存仍可能阻塞界面。批注变更后只刷新受影响页面的索引，文本摘录按需缓存，避免每次修改都重新扫描整份 PDF。保存仍在主线程对共享 PDFKit 对象执行，确保文档不会在序列化时被并发修改。

批注侧栏管理标准审阅批注及其评论，不提供墨迹笔画、形状几何和遮盖应用等内容编辑功能。窗口暂不自动恢复上一会话，以保持明确的文件打开和保存流程。

## 已核对的 Apple 公开 API

实际使用 Xcode 16.2 的 macOS **15.2 SDK** 头文件构建，部署目标为 **15.0**；不使用 macOS 26 API。关键 API 均早于 macOS 15 可用：

- [PDFAnnotation 与标准批注](https://developer.apple.com/documentation/pdfkit/pdfannotation)
- [quadrilateralPoints 的坐标与顺序](https://developer.apple.com/documentation/pdfkit/pdfannotation/quadrilateralpoints)
- [PDF 页与批注的公开绘图扩展机制](https://developer.apple.com/documentation/pdfkit/adding-custom-graphics-to-a-pdf)
- [NSView 有效外观变更回调](https://developer.apple.com/documentation/appkit/nsview/viewdidchangeeffectiveappearance())
- [NSDocument 文档与安全保存流程](https://developer.apple.com/documentation/appkit/nsdocument)
- [Core Image 与 macOS 图层滤镜](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_tasks/ci_tasks.html)

## 保真写入依赖

qpdf 12.4.2 的 Universal 动态库、73 个原版公开头文件和许可证随源码提供，普通 Xcode 构建完全离线。`python3 scripts/verify_vendor.py` 验证上游 Git blob、锁定库哈希和架构；可用 `scripts/restore_qpdf.py` 从固定的官方发行包恢复头文件/二进制。菜单「第三方许可」可查看完整说明。

引入该依赖是为了解决实际观察到的字体映射破坏，不自行实现 PDF 解析器。依据：[qpdf 对象保留接口](https://qpdf.readthedocs.io/en/stable/library.html)。This software is based in part on the work of the Independent JPEG Group.

## 界面组件

`ReaderStyle.swift` 集中管理随窗口主题变化的表面配色、选中行、空状态和批注卡片。阅读窗口使用原生 `NSToolbar` / `NSSearchToolbarItem`，在窄窗口中自动把次要标注操作移入溢出菜单，并保留核心入口。缩略图按页的旋转和裁切比例安排高度。`WelcomeView.swift` 支持原生打开面板及 PDF 文件拖入，文件仍通过 NSDocumentController 打开。
