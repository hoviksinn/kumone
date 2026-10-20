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
