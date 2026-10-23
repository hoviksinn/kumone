# 且听 V1：实现与验收记录

进度：本轮窗口及沉浸页修改已集成源码，实际编译、宿主视图回归和下载包以 PR #3 最新 CI 为准。CI #13 仅代表此前已通过的音频基线；新的 Click/Pop 目前仍在诊断，不能视为已经修复。

且听（QieTing）沿用 Kumone 的内部 Swift 模块、可执行文件和既有账号/数据目录。只支持 macOS 26+、arm64。保留原账号、播放、音乐库、无损、AutoMix/音轨分离、全部歌词、桌面歌词、系统媒体控制、下载基础设施、缓存与设置。主动下载入口暂时隐藏，不删除用户文件。

## 8 张参考图的落实

截图只在会话中查看，不保存、提交或作为 App 资源使用，也不引用其中的账号或音乐库信息。

1. 参考图 1：主内容独立于侧边栏，播放栏设最大宽度并在主内容中居中。
2. 参考图 2：歌词占右侧完整可用高度，主内容真实缩小，右栏不覆盖歌曲列表。
3. 参考图 3：改善旧播放栏随窗口持续拉长的问题。
4. 参考图 4：移除旧歌词卡片标题、贡献者和关闭按钮，数据仍保留。
5. 参考图 5：使用原生滚动条策略与手动/自动滚动状态，避免始终显示粗滚动条；尊重系统“始终显示”的明确偏好。
6. 参考图 6：队列删除热区 36pt，独立于歌曲点击，增加鼠标和键盘反馈。
7. 参考图 7：播放栏最大 880pt，保留完整操作。
8. 参考图 8：后续真实 Mac 反馈要求始终单排；不再采用首轮的多排重排，改用明确的窗口最小尺寸。

## A：暂停/恢复与真实媒体时钟

真实 Mac 后续回归发现，首轮仅暂停完整图并扣除墙上暂停时间的方案仍会让实际音频、进度和歌词逐渐分离。该旧方案已经替换，不能用首轮 CI 全绿证明后续反馈已解决。

此前失败候选与诊断保留在媒体时间线报告。`a57693c` 的 CI #13 已完整通过 972 项测试、103 个 suite、MLX GPU 和 App 打包；用户随后在真实 Mac 完成基础及压力共 13 项使用验收，未再复现长暂停跳片、进度停滞或歌词错位。此为本阶段稳定基线，不因新发现的 Click/Pop 推翻时钟设计。用户验收不是所有硬件/格式的实验室测量。

当前保持 AVAudioEngine 图持续运行，只对存活暂停节点按实际同源渲染边界恢复同一个播放计划；媒体位置使用原生播放器时钟，AU 请求总数不作为歌曲时间，同源时间戳只用于恢复调度边界。没有额外 Seek、重播或跳秒。新发现的播放控制瞬态见 D002；在真实 PCM 证明之前，不宣称短时包络能消除爆音。

PlayerService 用同一套异步采样结果更新进度、歌词行和逐字高亮，并拒绝旧 revision、旧歌曲和乱序结果；定时器最多一个读取在途。自然结束发布真实终点，避免节点旧时间覆盖终点。

[媒体时间线诊断、实现与验证边界](QIETING_MEDIA_CLOCK.md) 记录源码证据和测试方法。严格离线 PCM 对照、实际渲染块源标签、引擎、Service、歌词与命令时间分别验证；tap 聚合交付的缺口不能冒充 DAC 丢帧证据。CI 结果以最新运行记录为准，真实音频设备与听感仍须本机复测。

## B / E：右栏和播放栏

窗口持有唯一 PlayerBar，位于整个导航分栏和中间 NavigationStack 之外；普通导航只替换中间页面。分栏使用可拖动的原生 HSplitView：侧栏可收起，中列稳定容器始终持有搜索、返回和显式 NavigationStack，右侧 LyricsPanel / QueuePanel 独立管理。页面重试按钮迁入页面自身安全区，原生窗口按钮不再被 alpha 隐藏。

CI #18 的实际原生视图记录进一步确认：旧 NavigationSplitView 在推入详情后，将目的地提升为整列内容，原中列 VStack 的搜索框和 MainColumn 测量视图消失；窗口级 PlayerBar 本身仍在。这说明仅把播放栏外移尚不足以稳定中列布局，不能把某一个 clipped modifier 当作唯一根因。改用没有隐式页面导航所有权的 HSplitView 后，中列容器与页面导航分开；后续 CI 检查其实际结果，不只验证矩形计算。

打开时以内容宽高比选择模式：小于 16:9 优先外扩并保留原导航/主内容宽度，屏幕右侧不足时左移；否则内部展开。会话保留模式、原窗口 frame，切歌词/队列不再次扩窗。屏幕空间不足以容纳完整控件时，提示放大窗口或手动折叠导航，不自动隐藏控件。全屏使用内部布局，由系统控制窗口 frame。

播放栏固定单排，高 56pt，宽 780–880pt，在中间主内容范围居中，底距 16pt。普通与沉浸页共用最小可用内容尺寸 1021×640pt；原生 chrome 的高度另外计算。根布局直接声明面板会话所需最小宽度，避免只写 NSWindow.contentMinSize 后又被 SwiftUI 的静态 minimum 覆盖。外扩动画期间先保留关闭状态 minimum，完成后再提交完整面板 minimum，AppKit 负责窗口插值；内部展开立即提交，但要求现有窗口已可容纳。音质、音量、输出、桌面歌词、AutoMix 和媒体键保留。小于应用最低宽度的屏幕不能保证完整并排布局，此限制会提示用户。外扩恢复、多屏、动画及真实数据页面仍需本机验收。

新增真实 NSWindow / NSHostingView 导航回归使用生产 MainWindow、HSplitView、NavigationStack 和 PlayerBar，只把联网页面替换为离线标记，检查推入/返回后的唯一实例、可见性、命中与真实按钮事件。测试也检查侧栏切换期间的路径、中列、搜索框和播放栏身份，以及沉浸页切换时真实搜索输入框的焦点。`.build/window-navigation-validation.json` 保存实际观察。测试观察原生几何稳定后才记录恢复基准，不把标题栏异步布局当作用户调整窗口；它不替代真实音乐库页面和系统 Spaces/多屏操作。

## 沉浸页、顶栏及滚动条

沉浸页按可用宽高计算双栏比例。固定封面槽内播放比例为 1，暂停为 525/720，控制区和歌词不因缩放移动；信息、收藏、更多和输出选择在进度上方，固定形状的主要播放控制在下方。保留黑胶、FM、AutoMix。主界面与沉浸页共用 LyricsPanel 及显示同步逐字组件，读取环境注入的同一 PlayerService 时钟。

窗口保留原生红黄绿、全屏菜单与快捷键。沉浸顶栏根据鼠标活动、悬停、焦点和弹出操作显示；折叠导航时，中间顶栏由顶部区域触发。动效遵循 Reduce Motion。系统全屏动画、拖动与焦点交互需 Mac 复测。

移除全应用强制隐藏滚动条的设置，歌词使用 AppKit 原生偏好监听及 automatic，尊重系统 Always。自动跟随不主动 flash 滚动条；触控板淡出和拖动能力仍需实机确认。

## C：歌词视觉与时间

歌词字体/间距、景深模糊、亮度、轻缩放、位移和 Spring 参数集中在 LyricsVisualParameters。字体与 ruby 几何不随焦点改变，绘制效果不改变行布局。保留 LRC/YRC、翻译、罗马音、日语注音和点击跳转。

使用 onScrollPhaseChange 区分用户滚轮/触控板操作与程序滚动；手动操作后延迟恢复跟随，也可点击“跟随播放”。NSScrollView 原生 scroller 负责系统样式与淡出，不主动 flash 自动跟随滚动条。

右栏与沉浸式的活动 YRC 行共用 NSView.displayLink，跟随所在显示器和屏幕最高刷新率。只活动逐字行读取实际音频时间，异步经过音频队列，每行最多一个未完成请求；不以固定动画时长模拟演唱。暂停/消失停止刷新，切歌/Seek 取消过期结果。其余歌词列表不按帧刷新。没有主动锁定 60fps，也不强迫整个窗口持续 120fps 重绘。

60/120Hz 的时序单测只证明相同音频时间得到相同高亮，不能证明实体屏幕帧率。实际流畅度、日语长行和多屏迁移需本机验收；本环境未运行 Instruments。

## D：队列与文字链接

使用 AppKit clickCount：第一次点击仅选中，第二次点击播放，三击不重复播放；当前播放行的激活动作为空操作以避免重新启动。删除按钮为独立兄弟区域，36pt 命中、Hover、焦点、指针单独处理，不冒泡到歌曲。

队列项以 revision + origin 表示一次出现，支持同曲重复；队列改变后过期事件无效，避免删除到下一条相同歌曲。测试调用真实 PlayerService occurrence API 和实际 ClickView 的合成 NSEvent。原排序、跳转、AutoMix 规划和持久化保持原算法。

真实可点击的歌手/专辑/歌单和导航卡片采用统一样式，提供短时 Hover、焦点描边和原生 cursor rect。静态说明不添加虚假链接。指针和全键盘访问仍需本机确认。

## F：名称、图标与数据安全

输出 `.build/app/且听.app`，Finder/Dock/窗口/关于菜单/设置为“且听”；下载包为 `QieTing-Test-macOS26-arm64…`。内部 executable / modules 仍是 Kumone，Bundle ID 仍为 `com.hoviksinn.kumone.test`，不改账号、偏好和缓存键路径。

原创占位图标为 AppIcon.icon/Assets/ListeningWave.svg：五条圆角声波，靛紫渐变，Icon Composer 提供系统玻璃/深色呈现。`Scripts/generate-icon-preview.py` 从同份资源生成 README 预览；App 实际图标由 actool 编译，验证脚本检查 Assets.car 与包内矢量源。

原作者版权、LGPL、COPYING、Credits 和第三方许可保留；关于面板明确 Based on Kumone。测试身份、禁更新、无证书/正式发布机制保持不变。部分数据目录仍与原版同名，继续建议独立 macOS 用户测试。

## 验证入口与本机清单

完整 macos-26 CI 保留 Build、全部 Test（含 MLX GPU）、App 打包、严格 ad-hoc 签名、实际 arm64/minos=26.0 检查、ZIP 与 Artifacts。10 个原生窗口用例使用 XCTest 宿主单独执行，全部其余 Swift Testing 套件随后执行，避免同步 GPU 工作耗尽 UI 主线程的观察期限。没有省略用例；窗口迁移保留原 91 个 expectation、22 个 requirement 的表达式及阈值，另增加普通导航不改变 frame、原生窗口按钮可见/挂接/命中的断言。两阶段都检查最终测试汇总，不能只因进程退出码为零就宣称测试完成；日志和机器可读汇总随诊断上传。实际运行结论、测试数量和下载链接记录在 Draft PR；Linux 仅静态检查，不编译 SwiftUI。

宿主调整依据：CI #20 的真实退出栈为 `swift_task_asyncMainDrainQueue → exit`，未触发测试 App 的终止回调，也未输出最终 Swift Testing 汇总；与 Swift 6.3.3 的 [async-main/CFRunLoop 同症问题](https://github.com/swiftlang/swift/issues/91716)相符，不能把零退出码视为通过。迁移仅改变这些原生事件用例的测试宿主，不改变 App 的音频或事件实现；CI #21 已完整执行 10 个 XCTest 用例并输出最终汇总，原先早退不再复现，但窗口布局仍有失败，不能算回归通过。

CI #23 的原生记录确认，移除生产场景与测试根的重复静态 frame 后，内部展开的计算 minimum、宿主 fitting size 与 NSWindow.contentMinSize 都为 1161pt，窗口 frame 保持不变。CI #24 的首窗逐次记录又排除了首次同步布局过慢（约 0.205s）：第一轮仍未挂载协调器，20ms 异步等待没有在四秒内获得第二轮执行。测试现在以真实主队列屏障等待 MainWindowConfigurator 已排入的异步挂载，并在准备阶段断言实际附件；交互观察仍保留四秒及 250ms 几何稳定要求，不使用额外 sleep 或重试。CI #25 随后完成全部 10 个 XCTest 用例（36.211s）；首窗实际主队列屏障耗时 4.005s，挂载断言成立。完整套件运行 994 项，仅新增的真实 EOF 探针在准备阶段失败：3 秒出曲在 outPoint=3 已结束，默认出曲人声分离却要求其后的空区间。该探针改为真实分离完整入曲窗口，新增来源、次数、2 秒及双声道各 88,200 帧断言；保持原出曲完整 EOF、时间轴、segment 与输出断言。CI 先独立运行该探针再完整回归，不省略任何原用例。后续 CI 结果以 PR 为准。

独立于宿主问题，原生记录确认详情页会把 Toolbar 从隐藏变为显示。根据 Apple 的 [windowToolbar 说明](https://developer.apple.com/documentation/swiftui/toolbarplacement/windowtoolbar)，整体隐藏也会隐藏原生窗口控制，因此保留紧凑原生标题区域，在根页面及目的地的公共包装层移除重复系统返回和标题项，搜索及返回仍由稳定中列持有，保留 ⌘[。原生工具栏是否存在不能单独证明红黄绿可用，测试直接检查三个标准按钮。使用原生 chrome 实际高度换算 640pt 可用内容下限；frame 恢复仍做精确等值检查。

下载同一成功运行的外层 ZIP，解压后再解压 App ZIP。附带 app-verification.json 和 transport-validation.json。

请在真实 Mac 上检查：

- 同曲 UI/F8 暂停恢复、短/长暂停、快速切换；比较内置扬声器、有线和常用输出设备。
- AutoMix 混合或音轨分离期间暂停，确认无错切歌、跳时或失去过渡。
- 右栏开合、歌词/队列切换、窄窗口、关闭侧边栏、沉浸页面。
- 中文/英文/日语混排、ruby、翻译、逐字、快速切歌、暂停 Seek、手动歌词滚动和恢复跟随。
- 队列单击、双击、重复同曲删除、删除边界和键盘焦点。
- ProMotion 与外接 60Hz 显示器之间移动窗口；必要时用 Instruments 的 SwiftUI/Animation Hitches 观察实际帧耗时。
- 登录/重启保持、搜索/推荐/库/歌单、无损、下载缓存、桌面歌词、F7/F8/F9 和控制中心。
- Finder/Dock/关于窗口新名称与新图标；系统图标缓存可能需要退出旧 App 后重新打开新包。

## 参考与来源

- Apple [Create custom visual effects with SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10151/) 与 [What’s new in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10144/)：绘制效果与布局分离、文本及滚动动画理念。
- Apple [NSView displayLink](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:))：随视图所在显示器同步。
- [AMLL](https://github.com/amll-dev/applemusic-like-lyrics) 和 [MelismaKit](https://github.com/kmgcc/melismakit) 均经许可审查（AGPL 系列），仅作视觉/架构参考，没有引入依赖或复制实现。
