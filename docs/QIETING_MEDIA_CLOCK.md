# 媒体时间线与暂停回归

此记录针对 PR #3 的真实 Mac 反馈：长暂停或连续切换后，实际音频、进度条与歌词逐渐分离。物理输出设备和听感仍须本机复测。

## 已取得的诊断证据

修改算法前的诊断提交为 `b8561e1`，运行 [39083399437](https://github.com/hoviksinn/kumone/actions/runs/39083399437)。使用左右声道比值编码源媒体秒数的合成 PCM，经过现有生产 DSP 图，在最终混音 tap 读取，不依赖引擎报告的位置。

- 10 秒暂停之后，一次最终混音观测的源位置约为 5.528 秒，引擎报告约为 2.452 秒；30 次快速暂停恢复之后，分别约为 8.182 与 4.754 秒。异步取样存在缓冲延迟，不能把差值直接当作扬声器的精确延迟；它揭示了时间映射分离。
- 完整、仅 sample-time 和仅 host-time 三种 `playerTime(forNodeTime:)` 转换结果相同。仅换一种 AVAudioTime 构造方式不足以修复。
- 原时间映射在读取媒体位置时减去累计 `pauseSkew`，而 AutoMix 从媒体时间反推节点调度时间时没有相同补偿。正向与反向映射不一致。
- 图暂停并不等于显式暂停源节点的播放器时间线。用墙上暂停时长补偿无法可靠代表实际渲染了多少源帧。
- 自然结束后仍查询原始节点时钟，可能覆盖已确认的歌曲终点。

诊断运行的完整测试没有通过：旧 AutoMix segment 测试出现三项失败。新增实时测试已与既有音频测试放入同一个串行组，避免它们同时重配置实时音频图；仍须以之后的完整运行结果为准。

**测量限制：** AVAudioNode tap 会聚合多个渲染块，图重启时尚未交付的 tap 缓冲可能不再交付。因此该运行的 tap 缺口不能直接证明 DAC 或源音频真正丢帧。后续逐渲染块观测与离线逐样本对照分别检查这些问题。

## 追加实验：显式暂停节点的尝试未通过

原生节点暂停方案的运行 [39092343079](https://github.com/hoviksinn/kumone/actions/runs/39092343079) 已完成编译，但 967 项测试中出现 276 项断言问题。严格对照表明：每次在图冻结后再暂停/恢复 PlayerNode，会造成恰好 3072 个源帧的偏移；下游前三个 1024 帧缓冲仍相同，随后 PCM 分离。该尝试不能交付，也不能靠容差放宽保留。

离线结束测试的另一个失败原因已由 Apple 文档确认：[dataPlayedBack](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback) 只适用于音频设备渲染；离线应使用真实节点的 [dataRendered](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/datarendered) 完成回调。后者不包含下游 DSP 或设备延迟。真实 App 继续使用 dataPlayedBack，离线测试走相同的引擎结束事件链，不人工注入 EOF。

## 追加实验：源帧计数也不能替代音频内容时钟

运行 [39093867285](https://github.com/hoviksinn/kumone/actions/runs/39093867285) 编译通过，但完整 968 项测试报告 29 项断言问题。离线连续性和 Service 时间线用例通过，实时生产图的独立 PCM 标签仍失败：源计数约 3.17 秒、引擎约 3.13 秒，而下游 PCM 标签约 8.66 秒。固定管线延迟不能解释暂停后的增长差值。该候选不能交付；源渲染计数不等于文件内容位置。

## 追加实验：仅暂停源节点仍未通过

运行 [39116972774](https://github.com/hoviksinn/kumone/actions/runs/39116972774) 编译通过，971 项测试、103 个 suite 报告 252 项断言问题。严格离线 PCM 每次原生恢复仍有 3072 帧偏移，实时 PCM 最多重复约 6229 帧；原生位置每次恢复立即回退约 940–942 帧，快速 10/30 次分别回退约 9408/28224 帧。这不能归为 Service 更新慢或固定 DSP 延迟，故该候选未解决 P0。

离线 unity 图报告 AU latency 为零，仍能观察到 3072 帧的预读尾部，不能把该数值认定为 TimePitch 效果延迟，更不能硬编码补偿。实际预读边界与 AU 声明延迟需要分别测量。真实 AutoMix 排队中点保留暂停、过期读拒绝、自然结束与循环事件回归已通过，但 PCM 连续性尚未通过。

## 待验证候选：按同源渲染边界恢复，保持音频图运行

此前失败的“节点与整图一起暂停”不等同于本次方案。本次普通暂停只调用原生 PlayerNode.pause，保留运行中的 AVAudioEngine、既有计划及 DSP 缓冲；恢复只恢复存活节点，不重启正常运行的图、不重新调度、不 Seek，也不追加等待或淡入淡出。停止、显式 Seek、重新加载保留独立语义。

Apple 对 [pause](https://developer.apple.com/documentation/avfaudio/avaudioplayernode/pause()) 的说明明确区分了节点媒体时钟和硬件：节点暂停期间播放器 sample time 不前进，但暂停所有节点并不会停止音频引擎和硬件。普通源暂停本身仍不足以解决问题。待验证改动只对存活暂停节点使用实际源 AU 渲染末端的节点时间调用 play(at:)，避免未指定时间的“现在”落在另一调度边界；不固定增加 3072 帧或人工等待。AutoMix 正反向映射仍共用原生坐标。AU 渲染请求总数不作为歌曲位置；同源时间戳只用于选择原生恢复调度边界。完整 PCM 和命令记录仅在测试时启用。

音频图在暂停后会自然排出原有缓冲尾部，之后输出静音；恢复需经过原有管线。测试分别记录尾音、静音及实际节点延迟，不丢弃非静音 PCM，也不把暂停静音变成媒体时间。与不中断参考图比较时，每个非静音样本必须对应下一帧参考 PCM，不能搜索偏移重新对齐。真实设备上的边界听感、效果器尾音和暂停期间功耗仍须验证。

多 Deck、segment、未来 host 调度、暂停中 Seek 与自然结束保留各自状态；过渡源的已排空事件在暂停中延后到恢复处理，避免自动切换破坏暂停意图。Service 消费先前排队的 AutoMix 中点事件时也必须保留用户后来发出的暂停状态。

PlayerService 统一异步采样入口，进度、歌词行和逐字高亮使用同一时间线。读取携带播放 revision、歌曲/Deck 身份及顺序号，取消或过期的异步结果不能覆盖新 Seek、新歌曲或较新的结果。进度定时器最多一个读取在途，不在主线程同步等待音频队列。实际自然结束事件直接发布已确认的终点，不人为补加秒数。

## 成熟播放器参考（只研究，不复制）

- [mpv 的 audio.c](https://github.com/mpv-player/mpv/blob/master/player/audio.c) 区分已写入输出队列的媒体时间与扣除实际输出延迟后的播放时间。这支持分别记录源消费、下游 PCM 和设备呈现边界，而不是按墙上暂停时长猜测。
- [SwiftAudioPlayer 的 AudioEngine.swift](https://github.com/tanhakabir/SwiftAudioPlayer/blob/master/Source/Engine/AudioEngine.swift) 分别调用节点与引擎暂停；不能据此假定该组合适用于本项目的多 Deck/TimePitch 图。本项目已有严格 PCM 失败证据，故未直接采用或复制其实现。
- 本轮没有引入这些项目的源码或依赖。原生源时钟与下游 PCM 的固定管线差值明确记录；尚未证明任何实体输出设备上的绝对呈现时间或听感同步。

## 自动化覆盖与边界

- `PlaybackTransportContinuityTests`：实际生产图离线渲染，与不中断参考图逐样本比较；双 Deck、快速/重复命令、暂停中主动 Seek、存活节点和停止节点；增加持续拉取暂停图的真实 DSP 尾音与严格 FIFO 参考对照。
- `PlaybackMediaClockTests`：0.1、1、5、10 秒真实等待，10/30 次快速切换；源 PCM 标签、原生时间转换、暂停/恢复发出与执行时间及固定管线差值。最终混音 tap 只作观测，逐渲染块源数据另行验证连续性。
- `PlayerServiceClockTests`：真实离线引擎与生产采样/进度/歌词入口联动，暂停时长、30 次切换、异步旧结果拒绝、自然结束、单曲循环和结束/暂停交错、真实 AutoMix 中点排队后用户暂停的事件顺序。
- Artifacts 中的 `transport-validation.json`、`media-clock-diagnostic.json` 与 `service-clock-validation.json` 记录实际测量。没有可用实时输出时必须明确标记未执行，不能将离线结果代替物理设备结果。

`PausedClockSkew` 的历史纯数学测试继续保留，但不属于新原生暂停方案的运行证据。最终 CI 测试数量和结果以 PR 的最新运行链接为准。

请在 Mac 的内置扬声器、有线耳机及常用输出设备上复测短/长暂停、快速连续切换、暂停后 Seek、播放到结尾，以及 AutoMix/音轨分离期间的暂停。确认声音、进度与歌词一致，并记录设备类型和操作序列。云端不能证明所有设备无爆音、无延迟或听感已达到 Apple Music。
