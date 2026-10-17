# 且听 V1：实现与验收记录

且听（QieTing）沿用 Kumone 的内部 Swift 模块、可执行文件和既有账号/数据目录。只支持 macOS 26+、arm64。本轮为可运行应用的源码改造，保留原账号、播放、音乐库、无损、AutoMix/音轨分离、全部歌词、桌面歌词、系统媒体控制、下载、缓存与设置。

## 8 张参考图的落实

截图只在会话中查看，不保存、提交或作为 App 资源使用，也不引用其中的账号或音乐库信息。

1. 参考图 1：主内容独立于侧边栏，播放栏设最大宽度并在主内容中居中。
2. 参考图 2：歌词占右侧完整可用高度，主内容真实缩小，右栏不覆盖歌曲列表。
3. 参考图 3：改善旧播放栏随窗口持续拉长的问题。
4. 参考图 4：移除旧歌词卡片标题、贡献者和关闭按钮，数据仍保留。
5. 参考图 5：使用原生滚动条策略与手动/自动滚动状态，避免始终显示粗滚动条；尊重系统“始终显示”的明确偏好。
6. 参考图 6：队列删除热区 36pt，独立于歌曲点击，增加鼠标和键盘反馈。
7. 参考图 7：播放栏最大 880pt，保留完整操作。
8. 参考图 8：较窄主内容重排控制项，不靠隐藏控件解决拥挤。

## A：暂停/恢复

确认的源码问题：旧实现先暂停各音源节点，再暂停整个引擎；恢复时反向执行。这给音源与包含 timePitch/EQ/delay/limiter 的完整图设置了两套输送边界。恢复还清空 pauseSkew 而没有消费 pausedAtHostTime；一段增益清理也发生在图停止之前。

改为只冻结/恢复完整图，保留发声节点、缓冲与播放计划；增益清理在停止渲染后执行。恢复沿用既有、已有上游实测依据的累计暂停时钟补偿，并在 engine.start 成功之后计算，包含引擎启动期间未发声的时间。首轮 CI 的 mono/stereo 实时测试发现恢复位置约有 0.24–0.39 秒偏差，修复与后续验证详见 PR。主动 Seek/重建写入的新锚点不扣旧计划的暂停时间。离线 manual-render 时间线不扣墙上时钟。暂停前保存第三段 segment 的时间，保证暂停中 AutoMix 的取消、重新计时和回交仍能映射位置；撤销尚未发声的 host-clock 调度并清除旧 watchdog 标记。

没有为普通暂停添加 Seek、跳过时长、重复整首歌、额外等待或淡入淡出。UI 与 F8/控制中心继续共用 PlayerService transport 入口。AutoMix 和整套 DSP 没有被关闭。

新增测试以非周期 chirp 合成数据穿过实际 production graph，与另一个不中断 engine 逐样本比较。覆盖单/双 deck 各 3 次暂停、96 条快速重复命令、暂停中主动 Seek、位置上界与下界。实际运行写出 `transport-validation.json`，包括帧数、样本误差、时钟误差；静音数据不能通过。另有 mono/stereo 实时循环测试，无真正推进的音频设备时明确打印 `Transport real-time clock regression NOT RUN: no advancing output device`。

**证据边界：** 这是可确认的源码问题及回归修复，不是旧版真实声卡爆音的实录 A/B 证明。离线样本连续不等于物理 DAC、蓝牙或驱动无爆音；整段 AutoMix/第三链听感、启动耗时产生的微小时钟差和最终听感仍需实体 Mac 验证。不能仅凭 CI 全绿宣称电流音完全消失。

## B / E：右栏和播放栏

PlayerChrome 从窗口叠层移动到 NavigationSplitView 的 detail 列，使用真实 HStack 分配主内容和右栏。歌词/队列共用 280–380pt 右栏，切换模式不重新改变栏宽；原生 Spring 负责展开/收回，并尊重 Reduce Motion。保留侧边栏、氛围背景、导航和沉浸覆盖层。

播放栏最大 880pt，位于主内容列中间；宽/中/窄分别采用单排、两排、三排（56/96/112pt）。音质、音量、输出设备、桌面歌词和播放按钮全部保留。底部留白随高度调整，避免挡住列表末行。布局测试覆盖尺寸约束；这不替代实际文字、缩放、窗口拖动与系统工具栏的视觉验收。

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

完整 macos-26 CI 保留 Build、全部 Test（含 MLX GPU）、App 打包、严格 ad-hoc 签名、实际 arm64/minos=26.0 检查、ZIP 与 Artifacts。实际运行结论、测试数量和下载链接记录在 Draft PR；Linux 仅静态检查，不编译 SwiftUI。

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
