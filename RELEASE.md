# 发布状态与操作

当前版本为 **1.0.0，build 10**。这是待验收的候选版本；生成本地 ZIP 不等于通过公网分发验收。

build 10 整理原生阅读界面：分组工具栏、自适应搜索入口、主题侧栏、批注卡片与空状态、精简阅读信息栏和支持拖入 PDF 的欢迎页。实际窗口截图随仓库提供，保色与保存回归继续运行。

build 9 补齐随主题变化的保色缩略图，含双向页码同步、批注刷新、旧渲染结果丢弃与有限缓存。

build 8 默认保留嵌入图片的颜色，只调整背景及中性绘制颜色；复杂绘制页明确保留原色。图片中的纸张与文字不反色，扫描图片因此可能保持白底。详见 README 的范围说明。独立图片数据、颜色配置和像素比较随 Debug/优化回归运行；截图检查验证真实窗口中的页面及图片。

build 7 修复深色阅读选项没有重新启用 PDF 页面深色的问题；工具栏和菜单都以页面变暗为直接结果。显式选择 Original 仍能恢复页面原色。设置 `ADAPTIVEPDF_CAPTURE=1` 时，候选脚本还保存实际浅/深色窗口截图并验证 PDF 页面像素（Python 额外需要 Pillow）。

## 可复现的候选包

```sh
ADAPTIVEPDF_PYTHON=/path/to/python3 scripts/release.sh --candidate
```

Python 解释器需要 `pypdf`，运行应用本身不需要 Python。脚本顺序执行并记录：

1. 验证随包 qpdf 的上游头文件、Universal 库和许可证，再执行 Debug 原生集成检查与独立 PDF 解析检查。
2. 优化编译配置下的同一组集成检查与独立 PDF 解析检查。Debug/优化配置还分别运行 10 个独立进程，验证关闭、保存失败和实际退出的保存/放弃/取消分支；另以独立偏好域执行六种主题/策略组合的正常退出、重启恢复与清理。
3. 若本地已准备好回归集，用优化编译执行三篇真实论文、400 页及扫描件的完整回归。随后全新构建不含自测入口的 Universal Release；校验签名、版本、Intel/arm64 架构、应用图标、PDF 注册和调试权限。
4. 生成 ZIP 与带 Applications 快捷方式的只读 DMG，并验证镜像。
5. 从 DMG 通过 LaunchServices 打开测试 PDF，等待独立进程的文档窗口完全可见、达到最小尺寸并稳定至少 0.3 秒，再检查干净退出和被启动二进制的 SHA256。
6. 生成源码 ZIP、两套测试 JSON、生产包与启动报告、SHA256SUMS 和 release-manifest.json。

输出目录为 `dist/AdaptivePDF-<版本>-build<构建号>-<时间>/`，最新成功目录记录于 `build/latest-release-path.txt`。构建或任意校验失败时立即停止；新的校验在独立目录执行，不覆盖正在运行的应用。正式分发包不编译 IntegrationChecks；优化回归使用单独的 INTEGRATION_TESTS 配置，不随应用发布。

所有检查通过后，根部 `dist/AdaptivePDF.dmg`、`AdaptivePDF-macOS.zip` 与 `AdaptivePDF-source.zip` 自动同步到最新候选，旧目录标记为已替代。下载文件先完整暂存并核对哈希，再以原子重命名替换稳定路径。

`release-manifest.json` 的 `ready_for_public_distribution` 当前保持 false，列明仍未完成的门槛，不会根据「构建成功」推断人工验收或公证通过。

## Developer ID 签名与 Apple 公证

本机首次检查结果为 **0 个有效代码签名身份**。尚未执行 Developer ID 签名、Apple 上传、公证或 Gatekeeper 公网分发验收。需要发布者在本机钥匙串配置 Developer ID Application 证书及私钥，并准备 notarytool 钥匙串配置。不要把私钥、证书密码或 Apple ID 密码粘贴进聊天或源码。

配置完成后，可显式运行：

```sh
ADAPTIVEPDF_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
ADAPTIVEPDF_NOTARY_PROFILE='your-existing-keychain-profile' \
ADAPTIVEPDF_PYTHON=/path/to/python3 \
scripts/release.sh --notarize
```

这会将签名后的应用 ZIP 和 DMG 上传到 Apple 公证服务。脚本启用 hardened runtime 和时间戳，只有收到 Accepted 才继续装订票据，再执行 stapler、Gatekeeper 及安装启动检查；失败时保留日志，不声称已经公证。上传签名流程已实现，但在证书配置之前未执行验证。

官方依据：[Apple 公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[命令行公证与装订](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

## 仍需完成的发布验收

- macOS 15 Intel 上的完整鼠标/键盘流程、另存为远程文件面板确认和真实系统外观切换。原生窗口关闭与实际应用退出的保存/放弃/取消、关闭时保存失败及多文档退出分支已补入自动检查，具体范围见 TESTING.md。
- Preview 中打开、查看并编辑保存后的标准高亮与评论。
- 基础 AcroForm 已补齐原生输入的修改追踪、统一撤销和保真保存；完整键盘路径及复杂联动表单仍属于后续 UI 验收范围。
- 已通过三篇真实论文、400 页生成文档、24 页约 49 MB 扫描件的结构、保存与重开回归。持续扩大真实科学图片、特殊字体和透明度覆盖；真实滚动帧率和交互性能仍需补充。
- 发布者身份、最终 bundle identifier、支持联系地址与发行许可的确定。
- Developer ID、公证、装订、从下载隔离环境安装和 Gatekeeper 验收。
- arm64 已编译，但尚未做 Apple Silicon 运行验收；不得把编译结果宣传为已经完成该平台测试。

## 数据与隐私

应用没有账号、联网阅读服务、遥测或云同步。PDF 由用户指定的文件系统路径读取；偏好写入本机 UserDefaults。新增批注使用 Mac 账户显示名作为标准 PDF 作者字段，随 PDF 分享时他人也可以读取该字段。加密文档当前解锁后仍保持只读，避免保存时移除保护。完整数据与渲染限制见 README。

## build 3 的保存修复与回归

真实论文检查发现旧版 PDFKit 整篇序列化会改变数学字体的 ToUnicode 映射。build 3 引入保留原始对象图的 qpdf 写入路径。发布流程在本地存在 `tmp/corpus/manifest.json` 时执行完整回归，检查所有页的内容流、Unicode、字体/图像资源流、链接和页面边界；不把 PDFKit 对独立页边文字块的提取顺序变化视为字体字符替换。

原始论文只下载至忽略的 `tmp/corpus/`，不随应用或源码压缩包重新分发；版本、来源与 SHA256 记录于 `Tests/corpus-sources.json`。准备和复现：

```sh
python3 Tests/generate_corpus.py --fetch
ADAPTIVEPDF_PYTHON=/path/to/python3 scripts/corpus-test.sh
./scripts/ui-test.sh
```

UI 测试目标已构建成功，首次执行被 macOS 认证阻止，报错为 `Authentication canceled. System authentication is running.`；没有修改 Developer mode 或绕过系统认证。该项仍为未通过。

## build 4 的状态与撤销修复

修复重新载入时文档模型与现有窗口引用不同 PDF 的问题。成功恢复会丢弃旧评论草稿、清理撤销并同步搜索、阅读位置及保存模型；失败恢复保留原文档和修改。

原生文本框和复选框通过 PDFKit 自带的语义撤销记录修改；程序窗口和 PDFView 显式返回文档的撤销管理器。应用追踪字段值时避免重复注册原生交互的逆操作，程序性字段变更仍有独立撤销。加密 PDF 包括空用户密码文档在内，所有字段保持只读。

原生测试在应用进程内通过公开 AppKit 命中测试、鼠标事件和 NSTextView 输入方法驱动 PDFKit 控件，并让真正的事件循环完成撤销分组；这覆盖控件行为，但不替代受系统认证阻止的 XCUI 全流程。

## build 5 的关闭与构建安全检查

关闭/退出驱动只打开临时 PDF 副本。10 个场景除检查窗口和文档状态外，还核对保存结果的标准批注、页面内容与资源；取消和放弃不得改变磁盘文件。真实退出必须收到应用终止通知；完整报告单独保存，不混入主集成断言数量。

普通构建也采用独立 DerivedData。目标应用仍在使用时，新构建写入版本独立的路径，已有运行进程与其应用文件保持不变；最新路径见 `build/latest-app-path.txt`。候选发布流程仍独立校验未插桩的生产包。

## build 6 的主题重启与命中检查

欢迎窗口现在应用已保存的强制主题，并响应后续偏好更新。主集成的新增检查核对浅色/深色下的便签、高亮命中与复制后端；独立进程检查确认六种主题/策略组合在正常退出和重新启动后恢复，测试域最后清理。

这些检查不替代实际鼠标拖选、系统设置外观切换或 Preview 的可视验收。当前测试进程未获得活动/键窗口状态，完整键鼠交互继续保留为发布门槛；生产包明确排除偏好域覆盖和所有测试驱动。

## 原始范围验收审计

`Verification/release-audit.json` 对原始 15 项验收逐条标记证据范围，并覆盖 P0 功能组、技术约束、构建命令与交付物。通过的后端/原生组件检查与未执行的硬件输入、系统设置切换和外部阅读器验收分别记录，不根据测试总数推断整体完成。

审计发现旧启动检查可能在开窗动画期间过早取证，已收紧并用同一份 build 6 二进制从只读 DMG 重新实测：文档窗口完全不透明，1180×900，稳定后正常退出。应用二进制没有因此变化。当前仍缺开发工具授权、完整 UI/Preview 验收、发布资料与 Developer ID 公证；目标尚未达成。

## build 11 的深色兼容修复

普通透明度现在可用于图片保色深色显示。修复嵌套 Form 的不支持特性触发 qpdf 流警告、继而让整篇文档回退原色的问题；复杂混合仍只让对应页面保留原色。新增包含普通透明度、内联图片、透明遮罩、嵌套 Form 与隐藏图片的生成样本，主集成增至每种配置 149 项断言，独立图片颜色检查增至 17 个区域。

此版本继续以未公证的预览版提供；既有完整 UI、Preview 互操作、Apple 芯片真机和签名公证验收范围没有扩大。版本说明见 `docs/releases/v1.0.0-build11.md`。
