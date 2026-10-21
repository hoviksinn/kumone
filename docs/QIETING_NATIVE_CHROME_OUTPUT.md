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

## CI #45 attempt 2 的实际失败与修正

[本次运行](https://github.com/hoviksinn/kumone/actions/runs/39674442928/attempts/2) 已编译并执行：窗口 19 项中 3 个场景失败（4 条 failure 含清理派生错误）；媒体时钟/严格 PCM 18 项及 EOF 1 项通过。歌词/滚动专项、完整回归和 App 尚未执行。这不是 Runner 容量故障，也不是音频引擎失败。

### 标准 Sidebar 动作

标准 `.toggleSidebar` 按 Apple 约定向 First Responder 发送 `toggleSidebar:`。旧代码仅在不属于响应链的 Toolbar adapter 上实现动作，没有在已经安装的窗口 delegate 提供入口。现在窗口 delegate 接收并验证这一动作，再调用同一个带 owner/window 保护的 HSplitView 状态操作；保留系统创建的标准项，由 AppKit 管理其 target/action/view。

旧测试要求 item.target 必须非 nil，不适用于合法的 First Responder 路由。改为检查真实窗口的可解析响应目标，并继续用真实鼠标点击断言展开/收起，保留 PlayerBar、导航和搜索身份检查。原证据没有分别记录 action/target，不能断言具体哪项被系统重设；新增诊断区分字段及原生控件可用性、窗口 delegate/Key/Main/响应链。测试宿主还用公开激活策略建立真实 Key Window，再验证默认动作路由，不能用直接 sendAction 模拟状态来代替点击。

### 搜索工具栏尺寸

真实数据：关闭时中列 1200pt，Search 右边缘 1140pt，尾距 60pt；内展 341pt 后中列 859pt，Search 右边缘 835pt，尾距 24pt，差 36pt。窗口 frame 始终 1200×680，Return 提交后几何也不再变化。原生树中空白项本体 0×1pt，而系统包装项占 44×40pt；日志报告宽高 ambiguous/zero frame。这说明独立空项的原生测量占位与声明的零宽不等价，不是应放宽 0.5pt 的坐标误差。

移除独立空白 Toolbar item，把留白合入同一个持久搜索容器；容器的明确 intrinsic 宽度为真实搜索宽度加实际右面板宽度，最小时仍是完整搜索宽度。真实 TextField/Glass 宿主保持同一实例；留白不绘制、不命中，不硬加/减 36pt。关闭、重开、队列/歌词切换、侧栏和复杂导航继续验证同一尾距。

先独立运行原失败 3 项，再运行完整 19 项窗口、3 项歌词、4 项滚动及既有时钟/PCM/EOF。生产修正尚须新的 macOS 结果，不以静态检查宣称成功。
