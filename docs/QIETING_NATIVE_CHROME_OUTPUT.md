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

CI #50 的编译及 16 项脚本自测实际通过。Journal 确认测试已经在主线程进入标准原生对照，实际测试 PID/PGID 为 9591，而 SwiftPM driver PGID 为 9294；工具误以为合法子进程必须留在同一进程组，在约 4.7 秒提前拒绝。这是诊断工具的归属前提错误，不是原滚动断言结果。公开 [SwiftPM 6.3 启动源码](https://github.com/swiftlang/swift-package-manager/blob/release/6.3/Sources/Commands/SwiftTestCommand.swift) 表明 macOS Swift Testing 通过独立 helper 启动；不能用 driver PID 冒称原生宿主。下一修正保留官方 SwiftPM 启动方式，按实际父链及启动身份核对合法子进程，同时继续拒绝外部 PID。先取得完整阶段/线程证据，再决定滚动输入修复。该次媒体时钟/严格 PCM 18 项与 EOF 1 项通过；其他 UI、完整回归及 App 尚未运行。

归属修正以公开 ps 的 PID/PPID/启动时间/命令/PGID 核对本次 driver 的真实父链并固定身份；采样及每次清理前重新核对。清理仅向经核实的单个自有 PID 发信号，先子后父，不向子进程组整体发信号。新增两项实际另建进程组的子进程实验后，18 项诊断自测通过，外部 PID、失败采样、缺少 Journal 及权限探测失败仍保留严格失败检查。原五项滚动测试和输入/偏移断言没有改变。

CI #51 自动触发，独立进程组相关检查实际通过，但自测 18 项中仍有 1 项在命令退出边界失败：已认领 PID 1179 的 ps 身份改变。该次没有编译应用。正在补录公开进程状态及 expected/observed 身份，区分已经退出但尚未回收的进程与仍在运行的身份变化；后者及 PID 复用仍必须失败。不能把这次诊断脚本问题解释为生产滚动问题。

退出边界修正只把经父链/启动身份核实、公开状态为 Z 的僵尸进程标记为不可采样、不可作为进度；若命令文本改为退出标记，仍要求 PID/启动时间/进程组一致。活进程命令变化、启动时间变化及外部僵尸 PID 继续失败。加入实际未回收子进程与身份反例后，21 项 Linux 诊断自测通过；CI #51 未保存原始 ps 状态，故不把僵尸文本变化说成已唯一证实的历史调用原因。新的失败会保存完整 expected/observed 记录。

## CI #52：已取得原生线程证据，修正输入协议

[CI #52](https://github.com/hoviksinn/kumone/actions/runs/39965270264) 的 21 项脚本自测、编译及 Metal 准备通过。滚动测试停在标准 NSScrollView、Legacy 样式的原始 began(-80) 第一次调用，30 秒后实际测试进程采样成功。全部 1453 个主线程采样均在 `NSScrollingBehaviorConcurrentVBL → trackGestureScrollWithEvent → NSScrollingConcurrentEventMonitor.startMonitoring → NSApplication.nextEvent → HIToolbox` 等待后续系统事件。测试本身却要等该同步调用返回后才产生 ended，证明“逐个直接调用带阶段事件”未建立合法原生交互生命周期。不是 GPU 负载、窗口尺寸或 `.never` 禁止滚动的证据，也不能把它说成生产 App 横向滚动已被验证失效。

新输入采用真实传统水平鼠标滚轮协议：公开 CG `.line`、isContinuous=0、phase/momentumPhase=0；[Apple NSEvent.phase](https://developer.apple.com/documentation/appkit/nsevent/phase-swift.property) 明确说明传统滚轮没有手势阶段。每个真实原生/生产 Shelf/重建场景都必须实际向右移动 `x > start.x`，再以相反原生输入向左移动 `x < forward.x`；文档/clip/knob 坐标不被测试修改，样式及指示器策略检查保留。五项测试及四项原始场景都继续执行，仍需新的 Mac 结果证明该输入能观察实际生产滚动。

事件仍直接交给实际原生 view，CG-created NSEvent 的 window=nil 及实际坐标均记录；不冒称已经验证 NSApplication/WindowServer 路由、物理触控板惯性或指示器淡出。CI #52 的原生源时钟/严格 PCM 18 项及 EOF 1 项继续通过，完整 UI、音频候选、完整回归和新 App 均尚未通过。

## CI #53：已验证真实向右位移，继续修正宿主几何与提交范围

[CI #53](https://github.com/hoviksinn/kumone/actions/runs/39967118648) 不再停滞。标准 NSScrollView 在 Legacy/Overlay 均为 `0 → 80 → 0pt`；全部六个生产 Shelf/重建场景都实际 `0 → 80pt`，原始严格向右位移及全部样式断言通过。因此隐藏水平指示器未禁用这些真实生产视图的横向滚动，CI #47 的零位移不能作为生产轴配置故障证据。

专项仍有九条错误：六条命中检查发现 SwiftUI unclipped visibleRect 高达 300pt，而卡片实际 bounds 高仅 92pt，直接取前者中点落在外层纵向区域；另三条反向检查在 SwiftUI 原生调用返回后约 1–8ms 仍读到 80pt，而其余反向场景正常返回 0pt。当前提交屏障只更新目标子视图，尚未提交外层 NSHostingView，不能预先将其断定为生产反向滚动故障。下一修正取 visibleRect 与自身 bounds 的真实交集，保留命中断言；仍使用一次原生主队列提交，但提交实际 hosting 根并记录即时/提交前/提交后偏移，不增加 sleep、重试、期限或直接设置坐标。

该次还观察到 macOS ps 在退出交界将完整路径回退为 `(swiftpm-testing-)`，即使公开状态暂为 R；与已认领 PID/启动时间/进程组完全一致。诊断修正只将精确匹配的内核短名回退标为不可采样/不可计入进度，不允许它认领新进程或发送信号；一般活路径变化、错误短名及启动身份变化仍失败。23 项脚本自测单独验证此边界。媒体时钟/严格 PCM 18 项及 EOF 1 项继续通过；工具栏、窗口、歌词、完整回归和 App 仍受前置滚动失败阻断，尚未运行本次完整验收。

## CI #54：明确父坐标契约与异步输入完成条件

[CI #54](https://github.com/hoviksinn/kumone/actions/runs/40277849339) 自动触发，编译、23 项脚本自测、时钟/严格 PCM 18 项及 EOF 1 项通过。所有生产卡片仍真实向右移动 80pt；专项剩六条命中错误和一条反向观察错误。真实记录显示卡片输入返回瞬间偏移未变，hosting 提交后才改变，故一次队列提交不是异步原生滚动的完成通知。

六条命中错误点到另一排卡片，符合已经确认的 API 契约错误：[NSView.hitTest](https://developer.apple.com/documentation/appkit/nsview/hittest(_:)) 要求接收者父视图坐标，旧测试却传入翻转 NSHostingView 的自身坐标。现在先通过 root.superview 转换真实 window point，再保留原严格目标身份断言。

滚动完成改为输入前注册 NSClipView 的原生 boundsDidChangeNotification。回调只读取实际 bounds.x 和单调时间，不布局、不显示、不设置位置；同步到达的通知也保存，避免丢失。仍保留一次 hosting 提交与原有严格向右/向左文档位移检查，另外要求通知在明确的 250ms 单次响应上限内到达；单个失败超时不轮询、不重发输入、不添加成功 sleep。观察器及通知开关显式恢复。五项测试正文及全部生产样式检查保留，尚须下一次 Mac 编译和实际通知结果，不能把静态审查写成已通过。

## CI #55：全部原行为检查通过，诊断写盘阻塞影响新增时限

[CI #55](https://github.com/hoviksinn/kumone/actions/runs/40310396835) 自动触发并编译成功。原五项场景中的命中、实际双向位移和全部样式检查已无失败；仍有一条新增的 250ms 响应检查失败。16 次实际输入中 15 次为约 0.3–17ms，最后一次重建卡片反向通知约 673ms。

阶段日志将 672ms 间隔定位到测试自己的同步记录路径：scrollWheel.enter=438.719893，scrollWheel.return 的记录时间=438.725002，下一 commit.enqueue=439.397363（均单调秒）。原生调用约 5ms 后已返回，随后主线程被含 write/synchronize/stderr 的记录路径阻塞，连失败计时任务也无法及时执行。不能据此声称产品滚动存在同等延迟，也不能忽略这一失败。

下一修正将有序诊断 I/O 放到独立串行队列，在全部输入测量之外确认写入及错误；保留全部阶段、原生通知和 250ms 严格上限，不修改生产、输入、位移或时间阈值。仍须新的 Mac 专项通过后再进入音频阶段。该次时钟/严格 PCM 18 项及 EOF 1 项继续通过，后续 UI 与完整回归/App 未执行。

## CI #56：UI 阶段通过，继续独立音频提交

[CI #56](https://github.com/hoviksinn/kumone/actions/runs/40312269780) 的 ui 阶段全部通过：滚动 5/5（3.089s）、工具栏 3/3（15.518s）、窗口导航 19/19（64.340s）、歌词视口 3/3（2.552s）、时钟/严格 PCM 18/18（19.525s）、EOF 1/1（5.240s），另有 23 项工具自测。8 个真实原生/生产/重建视图场景、16 次输入均命中正确目标并完成双向位移，真实 bounds 通知约 0.101–16.294ms，保留 250ms 上限。全部阶段及日志写入检查保留，生产滚动轴未被改动。该结果确认本轮原滚动失败来自不完整输入和测试观察前提，而不是通过改生产轴或放宽位移制造成功；物理触控板及系统淡出仍独立验收。

现引入独立保存的音频源码集成（本地候选 e95842d 的 15 个文件逐字节一致）及其 CI 门槛。真实输出路径在 masterMixer 后永久串联进程内 AU，然后接 outputNode；原始 FIFO 内容与最终包络输出分别核对。8 个受保护时钟函数及所有原测试声明保留，新增 12 项输出/实时时段测试。此前便携参数扫描、状态测试和旧波形回放不作为本次原生结果。

QIETING_VALIDATION_STAGE 先为 audio：实际 AU 桥接 1 项、输出/原边界 14 项及既有 UI/时钟/EOF 均须通过；此阶段不打包。通过后再切 complete，完整 Swift Testing 最低 1011，加独立 XCTest、MLX GPU 和原有 App 结构/测试身份/资源/签名/安装包检查。当前尚无该音频提交的 macOS 编译或最终 PCM 成功记录，D002 仍开放。

## CI #57：编译前工具夹具竞态与验证顺序

[CI #57](https://github.com/hoviksinn/kumone/actions/runs/40313964748) 已自动触发，但未进入音频编译。两个诊断自测失败：150ms 的模拟停滞期限先于 Python 夹具完成启动，外部 PID 故障尚未注入就被判启动停滞；另一个快速退出夹具在首次 ps 读取时已经只剩 `(Python)`，完整身份尚未认领。没有此次原生 AU 或 PCM 成功/失败结论。

修正将启动预算与已验证阶段后的停滞预算分开，真实 CI 两者仍为 30 秒。自测的解释器/子进程建立使用明确的 2 秒夹具启动预算，故障后的阶段预算仍为 150–300ms；刻意无日志的驱动停滞反例仍使用短启动期限。正向夹具冷启动、阶段超限和外部 PID 注入分别验证，不将准备耗时当输入响应。已核实父链的不可读路径仅标为不可用，不认领、不增加进度、不采样或发送信号；外部父链和改变的已认领身份仍失败。原 23 项保留，加 4 项后 27/27 Linux 自测通过，不能代替 Mac 结果。UI 的 250ms 和全部 PCM/音频阈值未改。

诊断自测现位于其原生滚动消费者之前，独立音频编译/输出探针可先执行；所有自测、UI、时钟、音频、GPU 和打包门槛仍保留，成功路径没有省略测试，App 仍要求全部前置检查通过。此调整避免辅助工具的准备问题遮住独立音频验证。
