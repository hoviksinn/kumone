# 且听：窗口、Seek 展示与 UI Preview

本轮继续 PR #3 的开发分支，保留 CI #13 `a57693c` 的媒体时钟和 CI #26 `30d4d17` 的稳定窗口结构。本文记录实现与验证边界；**实际运行结果、测试数量和下载入口以 PR #3 最新 CI 为准**。不合并、不发布 Release，不改变测试 Bundle ID、签名、登录、用户文件、缓存或模型。

## 窗口约束更新

用户提供的 macOS 27 崩溃堆栈显示，异常从 `NSWindow._postWindowNeedsUpdateConstraints` 抛出，经过 `NSHostingView.updateConstraints` 和正常显示循环。报告没有具体异常 reason，也没有指向播放器业务方法的应用堆栈。它支持约束更新重入的调查方向，不能唯一证明某个方法就是实体闪退原因。私人原始报告不进入仓库。

源码中存在两条可验证的反馈风险：

- 原生移动/缩放通知同步发布 `baseContentWidth`，包括 frame 没变的通知。若通知来自约束更新，会重新使 SwiftUI 布局失效。
- 动画完成后先清除程序控制标记，再设置原生 minimum；minimum 引发的窗口通知可能被当成用户移动，重写恢复 frame。

`WindowPanelCoordinator` 现在将几何通知合并到下一主队列轮次，校验窗口身份与会话代次；程序动画及无变化 frame 不再发布状态。窗口动画启动、完成和 imperative minimum 写入退出当前 SwiftUI 调用栈，提交 minimum 和稳定 frame 后再解除保护。保留全屏对原生 frame 的所有权、用户拖动后的恢复基准和销毁期间不发布状态的规则。

新增宿主用例覆盖右缘需要左移时的 12 轮完整开合、约束回调不产生同步几何发布、关闭 action 不同步写 minimum、旧窗口排队任务不能进入新会话。原有 frame 精确比较和观察期限保留。这些测试不等于复现了 macOS 27 的全部私有布局行为。

## Seek：区分媒体时间与展示状态

服务已有 timeline revision、歌曲/Deck 身份和请求序号防护；旧读取不能覆盖 Seek 后的新位置。没有证据要求推翻已验收的音频时钟。

本轮修复明确存在的展示路径：

1. 普通逐行播放与大幅 Seek 原来使用同一段 Spring 滚动。
2. 手动滚词后，外部进度条 Seek 不清除最长三秒的跟随暂停。
3. 播放中在同一 YRC 行 Seek，旧逐字绘制请求与已显示 alpha 没有立即退休。

`LyricsCursor.seekRevision` 仅在显式 Seek 提交给引擎后变化，不代表时间，也不按帧发布。歌词同时观察行索引与该标记：普通播放继续 Spring，显式 Seek 取消手动跟随等待，在真实下一次布局提交无动画定位。YRC 退休旧绘制代次，立即使用已发布的 Seek 目标，再继续读取实际引擎时间。没有增加 offset、重播、额外 Seek、延长等待或修改引擎 flush。

测试将实际引擎、服务 progress/live time、歌词 cursor 与原生视口分开比较。独立 XCTest 宿主使用生产 LyricsPanel、真实 NSScrollView 滚轮及生产行的公开 bounds anchor，覆盖普通播放 Seek，以及标准/沉浸歌词在手动滚词后 Seek。必须先确认原生滚动实际发生，不能只生成事件就算覆盖。新增服务用例覆盖播放/暂停时同一 YRC 行前后 Seek、旧读取拒绝和低频标记；另外在播放/暂停两种状态连续提交 30 次 Seek，与相同前史的单次最终 Seek 对照，严格比较 48 个量子、每声道 49,152 帧最终混音 PCM（误差 < 1e-5）、非静音峰值和两帧内时钟精度。原严格 PCM、长暂停和快速切换测试保留。新增对照只有实际 macOS 运行通过后才算验证结果。

用户描述的完整“一两秒”偏差及 progress 是否同时滞后，不能仅凭上述源码路径认定已全部复现。AutoMix 重新挂接可能阻塞主线程的假设也尚未测量。`QieTing / PlaybackInteraction` 的两个公开 `OSSignposter` 区间可供 Instruments 检查 Seek 提交与重新挂接耗时，不记录歌曲、账号、媒体位置或 PCM。

### CI #34 Attempt 5：修正视口测试的观察条件

[实际运行](https://github.com/hoviksinn/kumone/actions/runs/39484448425/attempts/5) 已通过编译、18 项窗口、18 项时钟/严格 PCM 和 1 项 EOF 专项。歌词 3 项均停在初始准备，尚未发出 Seek。[原诊断](https://github.com/hoviksinn/kumone/actions/runs/39484448425/artifacts/12302992505) 中 40 行及高于 4000pt 的真实文档已布局，5～6 组原生按钮焦点视图存在，但 navigation order 为 0、unignored 仅宿主、全部实际叶节点中心的 AX hit-test 均返回宿主，没有 SwiftUI 文字语义节点。继续更换角色协议不能解决这个已观察到的空树。

同次运行成功的原生搜索也处于 applicationActive=false、applicationRunning=false、windowKey=false；因此不能认定这些状态使所有渲染或事件失效。是否影响 SwiftUI AX 语义生成仍未证实。生产普通 LRC 使用真实 Text/plain Button，没有隐藏歌词的 Accessibility 代码，当前没有证据应改动它们的语义或激活全局辅助功能。

原测试把“AX 可识别”错误地当成“布局准备完成”的必要条件。新观察方式在现有生产行提供真实 ID、文本和 `.bounds` anchor，实际条件显示的跟随按钮也提供自己的 anchor。只有测试根容器用公开 `overlayPreferenceValue`/GeometryReader 读取它们，经一个不绘制、不处理输入的原生接收器换算真实屏幕坐标；应用没有 reader，没有新增定时器、发布器、音频订阅或每行 NSView。每个已实例化行增加一个小型 preference modifier，未宣称测得零开销。

全部原有断言、4 秒准备期限、三次原生提交、真实滚轮移动、手动跟随暂停、目标初始不可见、Seek 后实际目标行可见、文档位置改变以及音频/服务/歌词两帧精度均保留。缺失的未实例化行仍失败，不补坐标。AX 继续作为诊断，同时记录实际行身份、布局 revision、原生接收器挂载与 frame。测试还通过公开 NSView 缓存渲染接口输出合成歌词 PNG，供检查字形；采集在准备结束或最终断言之后，不用于延长 Seek 等待或判定准备成功。这些证据不等于 VoiceOver 语义、实体屏幕像素或帧率验收。

### CI #35：初始观测通过，继续隔离滚轮宿主

[实际运行](https://github.com/hoviksinn/kumone/actions/runs/39511967025) 编译通过；18/18 窗口（60.589 秒）、18/18 时钟/严格 PCM（19.362 秒）、1/1 EOF（5.150 秒）通过。普通播放、不使用滚轮的真实歌词 Seek 用例通过（1.376 秒），因此已越过 #34 的初始准备并实际执行音频、进度、游标和目标行/原生文档断言。另两例初始准备通过，停在“原生滚轮移动及生产跟随按钮”条件，尚未执行它们的 Seek；不能宣称手动滚词后跟随已通过。

本次 PNG 通配路径使 upload-artifact 以隐藏的 `.build` 为搜索根，默认隐藏文件过滤造成日志明确报告未找到任何文件，故 #35 没有诊断 Artifact。修正只对原有明确列出的测试日志、JSON 和合成 PNG 允许隐藏路径，不上传整个 `.build` 或任意用户数据。准备失败快照同时输出至测试日志，补充各原生滚轮事件的窗口、坐标及同步文档位置记录，以便区分事件宿主、实际滚动和跟随状态；不调整生产滚动逻辑、测试期限或验收断言。App/Preview 与完整回归继续由失败门槛阻止。

### CI #36：确认渲染与 AX 观察缺口，隔离输入序列

[实际运行](https://github.com/hoviksinn/kumone/actions/runs/39518576799) 编译、18/18 窗口（56.717 秒）、18/18 时钟/严格 PCM（19.234 秒）、1/1 EOF（5.071 秒）通过；普通 Seek 再次通过（0.983 秒）。[诊断 Artifact](https://github.com/hoviksinn/kumone/actions/runs/39518576799/artifacts/12310511209) 已恢复，真实文档从 17pt 移至 2155pt，目标行 24 从未实例化/不可见变为实际可见，三次原生提交耗时约 32ms，engine/sample/progress/lyrics 均为 12 秒。缓存 PNG 为黑字透明底，人工查看 alpha 通道可读出初始行 0 和最终行 24；AX 同时仍无文本节点，支持当前独立宿主 AX 观察缺口，不证明正常 App 的 VoiceOver 缺陷。

手动两例的三个相位均为预期的 1/4/8，但同步派发后及四秒观察结束时文档分别停在原来的 17/25pt，布局 revision 不变、无跟随按钮。事件 windowNumber=0、未关联测试窗，位置仍在滚动视图范围；这些记录尚不能唯一说明窗口关联或相位合并哪个是原因。下一单变量实验仅在 began/changed 后各完成现有 nativeLayoutCommit，使三个输入相位不在同一同步栈内结束，同时记录提交后的实际文档/按钮与原生 delta。事件窗口、坐标、生产逻辑、四秒期限和 Seek 后三次提交均不变；这是测试宿主输入序列实验，未验证前不宣称修复。

### CI #37：标准手动滚动后 Seek 已通过，修正零时间戳输入

[实际运行](https://github.com/hoviksinn/kumone/actions/runs/39519786456) 的编译、18 项窗口（56.971 秒）、18 项时钟/PCM（20.038 秒）、EOF（5.190 秒）通过；普通播放及暂停后的标准歌词手动滚动/Seek 两项通过。后者真实文档先 17→97pt、跟随按钮实际出现，再 Seek 至 12 秒，约 30ms 内目标行可见、文档 97→2066pt、全部媒体时间一致。它仍使用 windowNumber=0 的事件，所以不能认为未绑定窗口必然导致拒收。

[诊断](https://github.com/hoviksinn/kumone/actions/runs/39519786456/artifacts/12310458043) 中沉浸式的交互已显示跟随按钮，非零精确滚动 delta 为 -80/-100，但文档没有移动；所有合成 NSEvent.timestamp 均为 0。下一单变量仅在 CGEvent→NSEvent 转换前设置真实 `DispatchTime.now().uptimeNanoseconds`，并断言转换后的时间非零且相位严格递增。CGEventTimestamp 官方单位是启动以来纳秒，不使用 Date、Mach rawValue、音乐时间或人为偏移。事件窗口、幅值、相位提交、原四秒期限、Seek 三次提交和生产歌词逻辑不变；是否解决剩余宿主输入仍待实际 CI，不能先认定唯一根因。

### CI #38：保留真实失败，修正懒布局中的装饰行

[实际运行](https://github.com/hoviksinn/kumone/actions/runs/39520694006) 的编译、18/18 窗口（54.137 秒）、18/18 时钟/PCM（19.025 秒）、EOF（5.092 秒）通过。全部三例均建立真实滚动并执行 Seek，两个标准场景通过；沉浸式唯一失败为实际目标行不可见，未降低断言。

[诊断](https://github.com/hoviksinn/kumone/actions/runs/39520694006/artifacts/12311435047) 记录全部媒体时间 12 秒、游标 24、手动跟随清除，三次提交约 28ms 后文档 105→2776pt，但实际已实现行及缓存 PNG 只有 25～32，行 28 在焦点附近。这是实际视口错误，不能再归为 AX 漏读。初始文档高度 4895pt 明显高于实测 51pt 行高、29.28pt 间距和首尾留白的总和；标准 4154pt 也高于相同算法的约 3294pt。Apple [懒布局说明](https://developer.apple.com/videos/play/wwdc2026/321/)解释了离屏高度估算及新行布局导致的位置变化。

最小生产调整把 LazyVStack 内约 243/307pt 的两条装饰 Color.clear 移到栈外 padding，避免它们参与歌词行高度估算。首尾各加回一段原 lineSpacing，保持原来的首行位置、留白和 41 段间距；不更换 ScrollViewReader、动画、字形或媒体时间轴。预计均匀 fixture 的总高约为标准 3294.4pt、沉浸 3790.9pt，仅作诊断，不以计算值代替真实行坐标。残留原生滚动是否同时参与尚未唯一排除，故在原来的三次提交内增加轻量真实几何记录，并只读记录原生 didLiveScrollNotification 以分辨用户滚动。没有增加 Seek、提交次数、超时或截图计时。

### CI #39：实际旧滚动覆盖定位，采用原生语义位置绑定

[实际运行](https://github.com/hoviksinn/kumone/actions/runs/39521991380) 编译、18/18 窗口（59.555 秒）、18/18 时钟/PCM（19.057 秒）、EOF（5.185 秒）通过，两个标准歌词场景通过，沉浸式目标仍不可见。[新 trace](https://github.com/hoviksinn/kumone/actions/runs/39521991380/artifacts/12311297010) 确认 padding 使高度变为 3294/3791pt、初始行位置不变，但这没有解决全部失败。

标准手动场景第一次提交已把真实行 24 正确放在 y=250；此后原生 didLiveScroll 又将文档从 1649 移到 1748pt，真实行变为 y=151，期间文档高度恒定。沉浸式也在 Seek 之后发生 didLiveScroll，最终行 24 离开视口。这直接证明本宿主中旧原生滚动覆盖一次性 UI 定位，不是 AX 漏读、继续行高重估或媒体时间不一致；不能据此概括用户全部一两秒延迟。

局部改为公开 [ScrollPosition](https://developer.apple.com/documentation/swiftui/scrollposition) 与 scrollTargetLayout 持有语义行 ID，替代 ScrollViewReader 的一次性 proxy。保留手动跟随/恢复、原 Spring、无动画显式 Seek 事务、歌曲/Seek 版本 guard、全部字形和真实媒体时钟；不加 snapping，不由滚动位置反写音频。歌曲切换清理新 UI 状态。仍须由原三次提交和真实几何 trace 验证协调效果，不因 API 名称宣称修复；新增 0.5pt 真实焦点对齐断言，防止像旧标准用例那样仅因“还可见”而漏掉约 99pt 的残留位移。

### CI #40：语义绑定仍有残留覆盖，增加事件驱动仲裁

[实际运行](https://github.com/hoviksinn/kumone/actions/runs/39523551764) 编译、18/18 窗口（56.440 秒）、18/18 时钟/PCM（19.452 秒）、EOF（5.277 秒）通过。三个原有的真实目标可见性断言均通过，但新增的 0.5pt 焦点断言在标准暂停场景失败，仍不能交付 Preview。[诊断](https://github.com/hoviksinn/kumone/actions/runs/39523551764/artifacts/12312243887) 中 Seek 后约 30ms 出现原生 didLiveScroll，文档高度恒定而目标行偏离约 122pt；沉浸场景绑定随后纠正至精确焦点，说明语义 API 单独使用尚不能稳定仲裁所有晚到写入。

后续局部候选只观察真实 ScrollPosition 回写：自动跟随时收到 isPositionedByUser 才合并一次主队列重定位；执行前重新核对手动模式、歌曲、Seek 版本和工作代次。新手势、歌曲变化及视图离开取消旧工作，原有延迟 adoptCursor 也遵循相同代次保护。取消 bookkeeping 使用无发布的引用对象，避免窗口销毁时回写 SwiftUI 状态。无 Timer、轮询、媒体时间偏移或额外音频 Seek。只读测试回调记录实际用户位置标记及仲裁事件，不参与位置计算。

原三次提交、4 秒准备期限、17 条原始断言、两帧音频精度及新增严格焦点断言全部保留。原断言及截图完成后，两个手动场景再发送新一轮真实原生手势，验证文档能移动、生产跟随按钮重新出现且媒体位置不变。新行为须由 macOS 实际执行确认，不能根据代码或 Linux 静态解析宣布已修复。

## 导航与搜索

CI #13 的返回和侧栏按钮由系统导航容器生成，没有可直接复制的独立旧样式。本轮按用户确认的原生风格，在现有稳定中列 header 使用公开 `.buttonStyle(.glass)` 与原生 Button；不恢复 NavigationSplitView，不移动唯一 PlayerBar。

根页面不创建返回 Button，保留固定空槽让搜索位置稳定；详情页面提供返回与 ⌘[，侧栏开关保留导航状态并提供 ⌥⌘S。实际宿主测试发送鼠标事件、编辑原生 NSTextField 并按 Return，检查导航、唯一播放器及全局搜索目的地。

搜索保留 TextField、焦点、键盘和全局搜索语义，使用 macOS 26+ 公开 `.glassEffect(.regular.interactive(), in: Capsule())`。控件位于中列右上，不跨入右栏，不替换或隐藏原生窗口控制按钮。

依据：[原生 Glass 按钮](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass)、[Liquid Glass 自定义视图](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)。材质像素、Hover 质感与系统版本差异仍需 Preview 实机验收。

## 侧边栏与滚动条

CI #13 → 当前代码的明确差异：SidebarView 仍为 `.listStyle(.sidebar)` 且隐藏自己的滚动背景，但父容器由 NavigationSplitView 变成 HSplitView，原有导航侧栏背景不再由那个容器提供。

仅给稳定侧栏列增加公开 `NSVisualEffectView`，material 为 `.sidebar`、blending 为 `.behindWindow`、state 跟随窗口活动。背景不响应鼠标或键盘，不改中列、split、minimum 或标题栏。不自绘滚动条，也不强制透明度；系统仍决定明暗、减少透明度及合成效果。见 [NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)。

NativeScrollPreferences 继续读取并监听系统 preferredScrollerStyle，不强设 overlay。竖向内容遵循自动/滚动时/始终显示；自动淡出与材质透明是独立验收项。实际 Sidebar/List 测试检查材质局限于左列、原生滚动视图与无真实横向溢出，不将 material 类型等同于像素半透明已通过。

历史上隐藏横向指示器的 10 处卡片区域恢复 `.scrollIndicators(.hidden, axes: .horizontal)`：专辑 1、歌手 3、首页 3、精选 1、共享 Shelf 与加载 Shelf 各 1。仅这些横向卡片隐藏横条（包括系统 Always 时），水平滚动手势继续保留；不全局禁用水平轴，也不隐藏真实纵向列表溢出。

## 全应用刷新率审查

未发现全应用 60fps 限制或按固定帧数推进的动画。窗口、面板、导航、滚动、Glass 和微交互继续交由 AppKit、SwiftUI、Core Animation 调度，不给整窗加 120Hz Timer。

发现并调整了两个局部 30Hz 机制：

- 加载占位 shimmer 改为原生插值的局部渐变位移，不逐帧重建 TimelineView；减少动态效果和消失时停止。
- 播放标记的四条 CALayer 由窗口关联 `NSView.displayLink` 驱动，读取实际屏幕最大刷新率并响应屏幕/设置变化。暂停、隐藏、最小化、遮挡、移出窗口、减少动态效果时暂停或销毁显示链。没有新增音频解码、磁盘读取、SwiftUI 根状态发布；无新输入时避免重复写静态 scale。

黑胶继续按真实经过时间计算角度，并补齐 Reduce Motion、唱臂偏好和离开页面清理。逐字歌词已有窗口关联显示链，保留仅活动行、最多一个异步引擎读取及相同 alpha 不重复发布的策略。

服务的 5Hz progress 发布保持不变；它不是全应用动画限帧。本轮不以墙上时间推测播放位置，也不为平滑进度改变已验收时钟。真实逐字歌词按引擎时间取样。Ruby 每帧 Core Text 布局和 AutoMix 同步重新挂接是后续需要测量的候选，尚无 Instruments 数据证明其具体耗时。

原生显示链配置测试只能证明生命周期与当前屏幕配置，数学测试只能证明相同音频时间的计算一致。**不能据此宣称全应用已稳定达到 120fps。** 实际 ProMotion、外接 60Hz、动态刷新率、低电量与耗电必须实机评估。

## Preview 与完整回归

CI 顺序：编译 → 独立窗口 XCTest → 独立歌词视口 XCTest → 媒体时钟/严格 PCM → AutoMix EOF → App 构建/校验 → Preview 上传 → 未过滤的完整 Swift Testing（含 MLX GPU）→ 最终测试包上传。

Preview 附带 `PREVIEW.md` 和机器可读状态，明确完整回归在上传时尚未完成；缺少必要安全专项或 App 身份/架构校验时不得上传。最终 Test 使用同一次构建的相同 App，只在完整套件成功后上传。现有 Mac 测试身份、ad-hoc 签名及自动更新禁用策略不变。

CI 未分配 Runner 超过 10 分钟时停止主动轮询，保存头提交、链接与待验证项供用户接管；明确容量不足可提前交接。不取消用户接管的排队任务，不创建重复并行运行。一旦开始编译、测试或打包，正常跟进整个运行，不受 10 分钟等待上限限制。

CI #27 未获取到 hosted Runner，GitHub 明确报告 arm64 容量不足；它没有执行编译。CI #28 在新增测试宿主的 actor 标记及滚轮方法名处编译失败，已针对两处修正；不是窗口或音频运行结果。后续实际结果见 PR #3，不以历史成功结果替代当前验证。

CI #33 的第二次尝试已实际通过编译、18 项原生窗口测试、18 项媒体时钟/严格 PCM 专项及 1 项 AutoMix EOF 专项。播放、暂停两种状态下连续提交 30 次 Seek，最终各比较每声道 49,152 帧，混音 PCM 最大误差均为 0，对照时钟差均为 0 帧，非静音峰值约 0.19。同一 YRC 行前后 Seek 的引擎、服务和歌词时间也一致。这是内部离线输出与时间轴的证据，不是物理 DAC 或听感验收。

该轮歌词宿主 3 项仍在初始 AX 查询准备失败，尚未发出 Seek：实际滚动文档存在且有 40 行，但宿主查询未返回文字节点。必须修正并验证观察路径，不能将这个准备失败当成生产音频故障，也不能仅以正确 cursor 替代真实视口验收。独立音频专项现会在编译成功后继续采证；任何 UI 或音频门槛失败仍阻止 App/Preview 上传与完整交付，不降低任何断言或阈值。

Click/Pop 仍为 D002；主动下载校验仍为 D001。只有已有窗口风险与歌词展示修复通过完整 CI、并经真实 Mac 复测后，才能进一步收窄 D003/D004 的状态。
