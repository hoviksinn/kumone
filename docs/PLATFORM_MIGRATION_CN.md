# macOS 26 / arm64 平台精简记录

这次只清理平台架构，沿用既有 macOS UI 与播放行为，没有开发新的歌词效果。最终构建及测试结果以本次 Draft PR 的 CI 检查为准。

## 构建与安全

- 根 Swift Package、SwiftPM triple、部署环境变量、actool 和 App Info.plist 均设为 macOS 26.0。
- macos-26 CI 开头核查实际 CPU 为 arm64；构建不再编译 Intel 或合并 Universal Binary。
- 保留 Swift Build、完整 Swift Test、release App 打包、ditto ZIP 和 Artifacts。新增不下载模型的 MLX GPU 测试。
- 固定 MLX 0.30.6、原 Metal 核摘要与模型文件摘要；同份已核验核缓存供 debug 测试和 release 打包复用。第三方核最低兼容 macOS 15，但主 App 的最低系统仍为 26.0。
- Sparkle 暂保留为既有模块依赖，App 不创建更新控制器、不写上游更新地址或公钥。第三方框架/辅助程序剔除 Intel 切片后重新 ad-hoc 签名，签名失败会使构建失败。
- `verify-app.py` 检查主程序实际 minos=26.0、全部打包 Mach-O 仅含 arm64、独立 Bundle ID、禁更新标记和非空 Metal 核，并输出 `app-verification.json`。
- 删除标签触发的正式 release.yml，以及指向其他仓库的维护者模型上传脚本，避免误发布。

## 删除内容与引用依据

- `ios/` 整个目录：36 个 tracked 文件，包含 App Shell、Xcode 工程/工作区、iOS Package、配置/Entitlements、图标、iOS 与 CarPlay 单测、UI 测试、专用文档和编辑器规则。其包只反向依赖根 KumoneCore，macOS 目标不依赖该目录。
- `Core/CarPlay/`：CarPlayConnector、CarPlayContentStore、CarPlayTemplateFactory；调用者为已删除的 iOS App Shell。
- iOS 播放与界面文件：PlayerServiceIOS、IOSMainWindow、GlassTabBar、NowPlayingPresentation、IOSUpdater。
- iOS 辅助文件：PlaylistSearchField、PlaylistSearchScrollGesture、DownloadPreparationActivity；它们只在已删除的移动平台分支使用。
- ReleaseChecker：仅 IOSUpdater 调用，macOS 更新原本使用另一套 Sparkle 模块。
- 脚本：configure-ios.sh、altstore-source.sh、release-notes.sh、publish-stem-models.sh；只服务已移除的移动平台或正式发布流程，运行时不依赖。
- Makefile 删除 iOS 测试、XcodeGen、CarPlay 配置入口。共享 Swift 文件保留 macOS 路径，移除其他平台分支、macOS 26 以下 API fallback、macOS 永不进入的移动紧凑布局。

完整逐文件差异见 PR 的 Files changed。历史 CHANGELOG 保留；AutoMix 研究资料仍有 macOS 与第三方来源价值，保留并标注历史范围，不再作为当前平台承诺。

## 保留内容

网易云 API/加密、账号与 Cookie、搜索与推荐、音乐库/收藏/歌单、macOS PlayerService 与 AVAudioEngine、无损和音质、播放队列/状态恢复、歌词解析与同步/逐字/翻译/桌面歌词、沉浸页面、AutoMix 分析/过渡/试听/MLX 音轨分离、系统媒体键与控制中心、下载/缓存/持久化/设置均保留。

根 `Tests/` 原有 macOS 测试保留；仅删除独立 `ios/` 内的移动平台测试。现有测试不是完整的账号/设备/界面端到端测试，因此仍需要按测试指南在 Mac 回归核心功能。

## 经审查继续保留的共享代码

- CachingAudioResourceLoader 仍被 QueuePrefetcher 使用；不能因为历史 iOS 注释而删除。
- PlaylistContent / PlaylistTrackSort 仍有持久化和现有 macOS 测试语义，避免在平台清理中改变排序与用户设置。
- PlatformImage 等类型别名保留为已有模块的统一入口，其实现已固定为 AppKit；全面重命名收益有限。
- 共享本地化资源可能包含历史平台文字，但不能凭文字内容确认所有动态引用，未批量删除，以免破坏现有 macOS 文案。
- 既有缓存与模型目录名仍沿用 Kumone，没有擅自迁移用户数据；独立 Bundle ID 不足以实现完整数据隔离，仍建议使用独立 macOS 用户测试。
- 开源 LICENSE、COPYING、原作者版权、Credits、StemKit 文件内第三方许可及模型来源说明保留。

## 验证与比较口径

Linux 只做脚本语法、生成 plist、workflow 配置、引用、差异和 macOS 活跃代码检查，不编译 SwiftUI，也不声称 macOS 测试通过。

对比基线为 PR #1 的成功 CI（run 39042839842）：完整 job 21 分 10 秒，GitHub 下载产物 55,786,552 字节。单次新旧运行可能受机器与缓存影响，耗时变化不代表稳定加速比例。旧 App 解压体积未取得，因此不猜测 App 目录体积的变化；新 App 的实际文件字节量由 JSON 报告提供。
