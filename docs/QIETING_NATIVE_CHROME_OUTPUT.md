# 原生窗口控件、滚动条与输出边界：分阶段验证

起点：CI #43 / `d622b622307d55b2d0ae27bb961e17385cd79914`。保留已验收的媒体时钟、HSplitView、导航隔离、唯一 PlayerBar 及右侧面板。UI 与音频独立提交；两阶段专项通过之后才运行完整回归并生成 App。本文件不把 Linux 静态检查视为 macOS 编译或实机验收。

## A. 一个透明的原生工具栏

- 删除中间列的 44pt `middleHeader`，详情 NavigationStack 使用整列可用高度。搜索及条件返回项移至同一个原生 NSToolbar，不再另设一个不可见的 Header 行。
- 始终保留系统工具栏和红黄绿按钮。使用 `.fullSizeContentView`、`titlebarAppearsTransparent`、隐藏标题、无标题栏分割线和 SwiftUI 隐藏工具栏背景；页面/侧栏背景延伸到顶部，真实标题栏安全区域仍保护内容和点击。
- 删除原环境色控制器中的标题栏遮罩及延迟重新布局任务；只在属性真正变化时修改公开窗口属性。
- 侧栏按钮为 AppKit 生成的标准 `.toggleSidebar` 项，适配器只接管动作，切换现有 HSplitView 状态。HSplitView 不会自动提供旧 NavigationSplitView 的系统导航/分栏所有权，因此不能保证与 CI #13 的位置逐像素相同。按钮绘制、尺寸和布局仍由系统负责，没有自绘 Sidebar Button。
- 返回为原生导航 NSToolbarItem，仅存在可返回路径且控件可见时插入。搜索保留同一个 NSHostingView/TextField、Liquid Glass 和全局搜索语义；实际右面板展开宽度用于工具栏末尾留白，避免搜索跨入面板。⌥⌘S / ⌘[ 菜单快捷键保留。
- 折叠导航后的顶部触发使用本窗口原生鼠标事件/真实标题栏几何；搜索和标题栏 Hover 分别保护操作。没有持续刷新或隐藏滚动条的 Timer。

新增真实窗口测试验证详情视口与整个中间列同高、只扣除系统真实安全区域、标准工具栏/搜索实例稳定。原 18 项窗口路径保留，当前专项共 19 项；其中原生全屏通知测试不等同于实体 Mac 的 Space 切换验收。

## B. 滚动指示器

此前横向使用 `.hidden`。Apple 明确允许该策略在 macOS 鼠标/系统策略下仍显示；改为 `.never`，覆盖全部 10 个横向卡片 ScrollView，保留真实水平滚动。

纵向仍读 `NSScroller.preferredScrollerStyle`，仅差值更新，保留系统原生绘制、拖动、淡出和 Legacy/Overlay 选择。`autohidesScrollers` 表示内容无需滚动时可隐藏，并不是强制让溢出的 Legacy 滚动条停止滚动后消失。系统“始终显示”产生的常驻灰色纵向条是预期行为。

原 2 项 NativeScrollPreferences 测试保留，新增 2 项覆盖生产 Shelf、父 `.automatic` 环境、Legacy/Overlay、实际水平输入、纵向 Legacy 常驻及原生视图重建，当前专项共 4 项。自动淡出时序和实际 Sidebar 材质仍需真实 Mac 检查。

## C. 音频与打包门槛

音频生产实现尚未包含在 UI 提交中，D002 仍开放。`work/` 中参数扫描只是独立实验，不是处理了真实设备输出的证据。不能将 Tap 副本或静态数学实验当作 App 已修复。

CI 通过 `QIETING_VALIDATION_STAGE` 明示 `ui` / `audio` / `complete`。前两种阶段保留编译、窗口、歌词、滚动、媒体时钟/严格 PCM 和 EOF 专项，但不打包 App，也不宣称完整回归通过。最后 `complete` 必须执行原完整 Swift Testing（基线 996 项 + 新增 2 项滚动测试，最低 998）、MLX GPU、原生专项及全部原有架构/测试身份/签名/资源检查。未通过前不上传最终 App。

## 公开 API 依据

- [NSToolbarItem 标准标识：AppKit 负责创建](https://developer.apple.com/documentation/appkit/nstoolbaritem/identifier)
- [toggleSidebar 标准动作](https://developer.apple.com/documentation/appkit/nstoolbaritem/identifier/togglesidebar)
- [透明原生标题栏](https://developer.apple.com/documentation/appkit/nswindow/titlebarappearstransparent)
- [SwiftUI hidden 指示器策略](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/hidden)
- [SwiftUI never 指示器策略](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/never)
- [NSScrollView 原生自动隐藏](https://developer.apple.com/documentation/appkit/nsscrollview/autohidesscrollers)
