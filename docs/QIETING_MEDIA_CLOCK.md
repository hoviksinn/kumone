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

## 当前修复约束

恢复仅冻结/恢复完整 DSP 图的策略，保留原音源节点、计划和预取缓冲。普通暂停不暂停单个 PlayerNode、不重新调度、不 Seek，也不追加等待或淡入淡出。停止、Seek、重新加载仍遵循其原有独立语义。

媒体时间依据已有源节点在 timePitch 之前实际渲染的源帧建立。使用 Apple 原生 [render observer](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/token(byaddingrenderobserver:))，不新建音频图节点；音频回调只发布原子计数和时间戳，不锁定线程、不分配缓冲或调用 UI。暂停后的最终计数包括暂停调用返回前已经实际渲染的帧，不再用墙上暂停时长猜测。Seek/加载只更换调度锚点，不从音频队列重置正在运行的实时计数器。

源媒体帧与原生节点帧的关系由同一实际渲染观测建立，AutoMix 从媒体时间反推原生调度时间时使用相同映射。双 Deck、segment、未来 host 调度及自然结束分别保留有效状态。首次音频渲染前立刻暂停也必须保留媒体零点，不能在恢复后用包含暂停间隔的原始时钟作为新起点。

源帧消费位置与下游输出 PCM 之间有原有处理延迟和预取差异。记录带符号的实际差值及节点延迟，分别检查固定差值和暂停后的累积偏差；固定处理延迟不是暂停时长，也不人为往 UI 加减几秒。物理设备延迟仍须本机验证。

PlayerService 统一异步采样入口，进度、歌词行和逐字高亮使用同一时间线。读取携带播放 revision、歌曲/Deck 身份及顺序号，取消或过期的异步结果不能覆盖新 Seek、新歌曲或较新的结果。进度定时器最多一个读取在途，不在主线程同步等待音频队列。实际自然结束事件直接发布已确认的终点，不人为补加秒数。

## 自动化覆盖与边界

- `PlaybackTransportContinuityTests`：实际生产图离线渲染，与不中断参考图逐样本比较；双 Deck、快速/重复命令、暂停中主动 Seek、存活节点和停止节点。
- `PlaybackMediaClockTests`：0.1、1、5、10 秒真实等待，10/30 次快速切换；源 PCM 标签、原生时间转换、暂停/恢复发出与执行时间及固定管线差值。最终混音 tap 只作观测，逐渲染块源数据另行验证连续性。
- `PlayerServiceClockTests`：真实离线引擎与生产采样/进度/歌词入口联动，暂停时长、30 次切换、异步旧结果拒绝、自然结束、单曲循环和结束/暂停交错。
- Artifacts 中的 `transport-validation.json`、`media-clock-diagnostic.json` 与 `service-clock-validation.json` 记录实际测量。没有可用实时输出时必须明确标记未执行，不能将离线结果代替物理设备结果。

`PausedClockSkew` 的历史纯数学测试继续保留，但不属于新原生暂停方案的运行证据。最终 CI 测试数量和结果以 PR 的最新运行链接为准。

请在 Mac 的内置扬声器、有线耳机及常用输出设备上复测短/长暂停、快速连续切换、暂停后 Seek、播放到结尾，以及 AutoMix/音轨分离期间的暂停。确认声音、进度与歌词一致，并记录设备类型和操作序列。云端不能证明所有设备无爆音、无延迟或听感已达到 Apple Music。
