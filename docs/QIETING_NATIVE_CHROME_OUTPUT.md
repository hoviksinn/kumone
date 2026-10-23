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

原 2 项 NativeScrollPreferences 测试保留，新增 2 项覆盖生产 Shelf、父 `.automatic` 环境、Legacy/Overlay、实际水平输入、纵向 Legacy 常驻及原生视图重建，另新增一项标准原生滚动视图输入对照，当前专项共 5 项。自动淡出时序和实际 Sidebar 材质仍需真实 Mac 检查。

## C. 音频与打包门槛

音频生产实现尚未包含在 UI 提交中，D002 仍开放。`work/` 中参数扫描只是独立实验，不是处理了真实设备输出的证据。不能将 Tap 副本或静态数学实验当作 App 已修复。

CI 通过 `QIETING_VALIDATION_STAGE` 明示 `ui` / `audio` / `complete`。前两种阶段保留编译、窗口、歌词、滚动、媒体时钟/严格 PCM 和 EOF 专项，但不打包 App，也不宣称完整回归通过。最后 `complete` 必须执行原完整 Swift Testing（基线 996 项 + 新增 3 项滚动测试，最低 999；音频候选另 12 项尚未应用）、MLX GPU、原生专项及全部原有架构/测试身份/签名/资源检查。未通过前不上传最终 App。

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

标准 `.toggleSidebar` 按 Apple 约定向 First Responder 发送 `toggleSidebar:`。旧代码仅在不属于响应链的 Toolbar adapter 上实现动作，没有在已经安装的窗口 delegate 提供入口。8463fcc 曾尝试在窗口 delegate 接收并验证这一动作，保留系统创建的标准项。CI #46 进一步否定了“独立宿主能取得 Key Window 且默认动作一定解析到该 delegate”的前提，后续修正见下。

旧测试要求 item.target 必须非 nil，不适用于合法的 First Responder 路由。改为检查真实窗口的可解析响应目标，并继续用真实鼠标点击断言展开/收起，保留 PlayerBar、导航和搜索身份检查。原证据没有分别记录 action/target，不能断言具体哪项被系统重设；新增诊断区分字段及原生控件可用性、窗口 delegate/Key/Main/响应链。测试宿主还用公开激活策略建立真实 Key Window，再验证默认动作路由，不能用直接 sendAction 模拟状态来代替点击。

### 搜索工具栏尺寸

真实数据：关闭时中列 1200pt，Search 右边缘 1140pt，尾距 60pt；内展 341pt 后中列 859pt，Search 右边缘 835pt，尾距 24pt，差 36pt。窗口 frame 始终 1200×680，Return 提交后几何也不再变化。原生树中空白项本体 0×1pt，而系统包装项占 44×40pt；日志报告宽高 ambiguous/zero frame。这说明独立空项的原生测量占位与声明的零宽不等价，不是应放宽 0.5pt 的坐标误差。

移除独立空白 Toolbar item，把留白合入同一个持久搜索容器；容器的明确 intrinsic 宽度为真实搜索宽度加实际右面板宽度，最小时仍是完整搜索宽度。真实 TextField/Glass 宿主保持同一实例；留白不绘制、不命中，不硬加/减 36pt。关闭、重开、队列/歌词切换、侧栏和复杂导航继续验证同一尾距。

先独立运行原失败 3 项，再运行完整 19 项窗口、3 项歌词、4 项滚动及既有时钟/PCM/EOF。生产修正尚须新的 macOS 结果，不以静态检查宣称成功。

## CI #46：搜索修复的证据与侧栏显式绑定

本次编译成功。搜索在 1200pt 窗口下关闭、内展 341pt、Return 提交、队列切换、关闭重开后的真实尾距都为 **16pt**，容器分别测得 220/561pt，无 ambiguous layout。原 0.5pt 断言通过，不再重改此布局。

三个专项随后均停在新增的 Key Window 准备条件，尚未执行对应 Sidebar 点击。公开激活请求返回 regular policy 成功，但独立 XCTest 的 applicationActive/applicationRunning/key/main 仍全为 false。新增诊断表明系统项和原生 NSButton 的 action 都是 `toggleSidebar:`、target 都为 nil，默认目标解析为 NSWindow；自动验证还会使非活动宿主按钮禁用。不能把这个错误测试前提说成新音频失败，也不能声称此前 delegate 尝试已经验证了真实点击。

最新修正继续保留系统创建的 `.toggleSidebar` item、原生 NSButton、图标、布局及交互，仅通过公开 target/action 接到原 HSplitView 的 owner 适配器；`autovalidates=false` 后由真实侧栏可用状态管理 enabled，并差值同步公开 NSControl 属性。没有替换按钮、隐藏工具栏、模拟红黄绿或增加另一行 Header。

测试改为检查真实 item/control 的目标、canonical action、enabled、autovalidates，随后仍投递原真实鼠标 down/up 并要求展开/收起和所有身份、导航、窗口、搜索几何断言。移除的只是 CI #46 新增且未成立的激活/Key/delegate 先决条件，不删除行为测试、不延长四秒预算、不放宽阈值。

公开依据：[target 与 nil-target 路由](https://developer.apple.com/documentation/appkit/nstoolbaritem/target)、[autovalidates](https://developer.apple.com/documentation/appkit/nstoolbaritem/autovalidates)、[默认验证会禁用非活动窗口项](https://developer.apple.com/documentation/appkit/nstoolbaritem/validate%28%29)。最新绑定仍需新的专项实际点击结果，不能以静态检查替代。


## CI #47：已通过项与滚动输入专项

[CI #47](https://github.com/hoviksinn/kumone/actions/runs/39916684356) 是用户手动 workflow_dispatch，HEAD `71d6f76`。编译、原生工具栏 3、完整窗口/导航 19、歌词视口 3、时钟/严格 PCM 18、EOF 1 均实际通过。滚动 4 项有 2 项失败，共 6 条断言，全部为实际横向偏移仍为 0；其他样式/指示器/文档尺寸断言没有失败。完整回归、MLX GPU 实算与新 App 尚未执行，不能把先前通过记录替代本轮完成。

当前输入只有 began(-80)、ended(0)，没有 changed。新的候选采用 Apple/WebKit 测试 helper 的公开事件序列 began(-1) → changed(-79) → ended(0)，为各阶段记录 native delta、phase、uptime、坐标、实际窗口归属以及文档/clip 尺寸和移动。标准 NSScrollView 与生产 Shelf 各有旧/新序列对照，重建及 Legacy/Overlay 继续覆盖；保留新完整输入后 `x > start.x`，没有直接改动文档坐标或放宽断言。

CG-created NSEvent 不保证绑定 NSWindow，测试据实记录，不使用私有 KVC，也不宣称经过 NSApplication/WindowServer 路由或物理触控板。是否仅为测试手势问题，必须由新的实际对照和原生偏移结果确认，现阶段不改生产横轴或 `.never`。五项专项移至其他 UI 之前，并上传 native-scroll-validation.json。

依据：[Apple/WebKit 公开 wheel helper](https://chromium.googlesource.com/external/github.com/WebKit/webkit/+/968a3d30b9eb13dccbbf4b52ad217e00095891db/Tools/TestWebKitAPI/Helpers/cocoa/WebPage%2BExtras.swift#199)。参考的是公开阶段序列，没有引入它的 WebKit 私有 API。

## 自动构建触发调查

#46 的 event 为 pull_request，#47 为 workflow_dispatch，actor/triggering_actor 都为 hoviksinn。两者间 workflow 无改动，pull_request 默认已包含 synchronize；PR 为同仓 OWNER、open/Draft、mergeable/clean，提交无 skip 指令。并发控制只能取消已创建运行，不能解释自动运行完全不存在。

现有 GitHub 读取权限无法查看历史 pusher/完整 webhook 投递或事发时的凭据类型。当前变量存在性、commit author 或 Actions actor 都不能证明历史 push 使用了 GITHUB_TOKEN，故不作此定性。现有规则不增加 push/pull_request 双重触发、pull_request_target、写权限、新密钥或空提交。下一次真实修复发布后检查对应 head 的自动运行，记录实际 event；如尝试既有 GitHub 连接发布，仅使用现有连接权限，不新增认证。

[GitHub 官方触发说明](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow) 的当前规则还区分 GITHUB_TOKEN 的 PR 审批运行与其他事件抑制，不能简单套用旧的“此 Token 一律不创建 PR CI”结论。

## CI #48：自动触发已证实，滚动执行停滞待定位

真实修复提交 `7a9e3d2` 通过现有 GitHub 连接发布后，自动创建了 [CI #48](https://github.com/hoviksinn/kumone/actions/runs/39919222690)，event 为 `pull_request`，HEAD 与该提交一致。没有手动 dispatch、新增 Token、权限、触发规则或空提交。这证明当前发布路径可自动触发；不能反推出历史 `71d6f76` 的凭据类型或缺失事件的唯一原因。

本次编译成功，滚动专项启动后仅出现 SwiftPM Planning build，直至整个 Job 的 45 分钟上限终止。诊断 Artifact 只有该启动日志，没有完成手势 JSON，因此不能把停滞定位到某个 AppKit 调用，也不能宣称完整输入已解决 CI #47。测试 stdout 经管道缓冲，缺少 Test started 本身不能证明测试函数未执行。

下一提交只增加测试诊断：在真实测试进程同步写入逐阶段 JSONL，包围创建窗口、输入各阶段、原生布局/显示、主队列提交和销毁。外部独立进程在 30 秒没有新阶段时，采样自己启动的进程组内经核对的实际测试进程，再以失败退出并保留线程与阶段记录；缺少 journal 时另行标注宿主/驱动诊断，不能冒称实际测试 PID。该预算用于尽早产生有证据的失败，不延长成功条件、不改变输入、源坐标、五项测试或任何原有断言。仍需新的 macOS 结果确认真正停滞点后再修正。

CI #49 在编译前的诊断脚本自测发现 macOS 清理兼容问题。代码中的 signal-0 存活探测没有处理 PermissionError，可将原停滞结果覆盖成工具异常；修正为明确记录“无法确认已消失”，保持有界且仅限自有进程组的清理，不把权限错误当成功。新增两项真实子进程注入实验后共 16 项自测通过，意外异常还保存完整 traceback；原生滚动验收尚未执行，不据此认定已修复横向滚动。
