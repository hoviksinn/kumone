<div align="right">

[English](README.md) | **简体中文**

</div>

<div align="center">

<img src="docs/qieting-icon.svg" width="140" alt="且听 QieTing" />

# 且听 · QieTing

**且听音乐，随心而行 — 原生 macOS 音乐播放器**

Swift / SwiftUI / AppKit · 直连网易云真实 API · GitHub Actions 测试构建

[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B%20arm64-blue?logo=apple)](#构建)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-LGPL--3.0--only-orange)](LICENSE)

</div>

**且听（QieTing）** 是 [hoviksinn/kumone](https://github.com/hoviksinn/kumone) 的个人 macOS 定制版，基于 [missuo/kumone](https://github.com/missuo/kumone) 开源项目。仅支持 macOS 26.0 及更新系统、Apple Silicon（arm64）。保留上游版权、协议与致谢。

## 名称与图标

应用显示名称统一为 **且听**，英文内部标识为 **QieTing**。这是基于 Kumone 的个人定制，不改变上游作品归属。Swift 模块、内部可执行文件、既有测试版 Bundle ID 和数据目录保留原名，避免丢失登录、设置与缓存。

新的原创占位图标采用靛紫底色与五条圆角声波。可维护矢量源文件位于 `AppIcon.icon`，由 Apple `actool` 编译为 macOS 原生图标。修改后运行 `python3 Scripts/generate-icon-preview.py` 可重建本页的平面预览，系统实际显示使用 Liquid Glass 渲染。

## 功能

- 🔐 **扫码登录** — 网易云 App 扫码，Cookie 本地持久化，自动续期
- 🏠 **推荐** — 每日推荐、私人漫游、心动模式、推荐歌单、雷达歌单（私人雷达系列，按账号个性化）、排行榜、新碟上架、推荐歌手
- 🧭 **精选** — 分类歌单（精品 / 官方 / 排行榜 / 场景分类）无限滚动
- 🎵 **播放** — AVAudioEngine 引擎，标准 ~ Hi-Res 音质可选（黑胶 VIP 可播无损，自动回落），随机 / 单曲循环 / 列表循环，下一首播放队列，灰色歌曲识别
- 🔓 **灰色歌曲解锁** — 原生实现 UnblockNeteaseMusic 核心音源（pyncmd / 酷我 / 酷狗），无版权或试听歌曲自动匹配第三方音源
- 🖼 **沉浸播放页** — 封面取色渐变背景 + 大封面 + 大字同步歌词（点击播放条封面进入，Esc 退出）
- 📻 **私人漫游** — 沉浸式 FM 页面，不喜欢 / 切歌
- 📝 **歌词** — 完整高度的右侧区域、同步歌词、逐字歌词与翻译，点击跳转
- 🪟 **桌面歌词** — LyricsX 风格悬浮置顶歌词（含翻译），可拖动、位置持久化，所有空间与全屏应用上可见
- 📚 **音乐库** — 我喜欢的音乐、创建 / 收藏的歌单、收藏专辑、关注歌手、最近播放、音乐云盘
- ✏️ **歌单管理** — 新建 / 删除 / 收藏歌单、添加 / 移除歌曲、红心
- 🔍 **搜索** — 综合 / 单曲 / 歌手 / 专辑 / 歌单，热搜词占位
- ⌨️ **系统集成** — 媒体键 / 控制中心（Now Playing）、听歌打卡、退出后恢复播放队列
- 🎛 **AutoMix 与音轨分离** — 保留现有音频分析、自动衔接及 MLX / Metal 音轨分离能力
- 🌐 **多语言** — 简体中文与英文界面，跟随系统语言

## 安装测试版

要求 macOS 26.0 或更高版本及 Apple Silicon Mac；Intel Mac 不再支持。

在本仓库的 [Actions → CI](https://github.com/hoviksinn/kumone/actions/workflows/ci.yml) 选择一次成功的运行，下载底部 Artifacts 中名称含 `macOS26-arm64` 的产物。解压下载文件和其中的 App ZIP，即可得到 `且听.app`。手动运行及安全测试说明见[中文测试指南](docs/MACOS_TEST_BUILDS_CN.md)。

下载包以 `QieTing-Test-macOS26-arm64` 命名，解压后为 `且听.app`，应用显示为「且听」。测试版固定使用独立 Bundle ID `com.hoviksinn.kumone.test`、始终禁用更新，不使用原作者证书或发布密钥，也没有 Apple 公证。不要覆盖原版 Kumone；按测试指南使用独立 macOS 用户账户，隔离仍沿用上游目录名的数据。此仓库不提供 Homebrew 安装、正式发布或自动更新。

## 构建

要求 Apple Silicon Mac、macOS 26.0+、Xcode 26+。Linux 只能进行静态检查，编译、测试与打包由 macOS GitHub Actions 验证。

```bash
swift build --triple arm64-apple-macosx26.0  # 编译
make test                                 # 准备 Metal 核并运行全部测试
Scripts/build-app.sh           # 打包 .app（输出 .build/app/且听.app）
Scripts/compile_and_run.sh     # 杀进程 → 重新打包 → 启动
```

## 架构

```
Sources/Kumone/
├── Core/
│   ├── API/            # NeteaseCrypto（weapi/eapi 加密）、NeteaseClient（传输 + Cookie）、NeteaseAPI（约 50 个端点）
│   ├── Models/         # 统一 Track 模型（兼容新旧两种 JSON 格式）、歌词解析器
│   ├── Player/         # PlayerService（队列 / 随机 / 循环 / FM / URL 解析）、UnblockService、NowPlayingManager
│   └── Storage/        # AccountStore、SettingsManager、两级图片缓存
├── DesignSystem/       # 设计 token、按钮样式（hover 缩放 / 行高亮 / chip）、骨架屏、卡片、跑马灯、封面取色
└── Features/           # 各页面 + 播放条 + 沉浸播放页 + 歌词/队列面板
```

不依赖任何第三方 API 服务器：weapi（AES-CBC 双层 + RSA）与 eapi（AES-ECB + MD5 摘要）加密为原生 Swift 实现，请求直达 `music.163.com` / `interface.music.163.com`。

## 相关项目

如需独立的 **tvOS** 客户端，上游推荐由 Svend 维护的 [Sonimbus](https://github.com/gee1k/sonimbus) —— 一个 Apple TV 上的网易云音乐客户端。

## Credits

本定制版基于 **missuo 的 Kumone**（[上游项目](https://github.com/missuo/kumone)，© 2026 missuo，LGPL-3.0-only）。上游 Swift 实现参考了以下项目的设计与思路，继续保留这些致谢：

- [YesPlayMusic](https://github.com/qier222/YesPlayMusic)（MIT，© qier222）— 功能设计、网易云 API 端点与行为逻辑的参考
- [kaset](https://github.com/sozercan/kaset)（MIT，© sozercan）— UI 设计系统、动效与 SwiftPM 打包方案的参考
- [UnblockNeteaseMusic/server](https://github.com/UnblockNeteaseMusic/server)（LGPL-3.0-only）— 灰色歌曲第三方音源的接口与匹配策略参考（`UnblockService.swift` 为独立的 Swift 重新实现）
- [LyricsX](https://github.com/ddddxxx/LyricsX)（MPL-2.0，© ddddxxx）— 桌面歌词窗口的设计参考（窗口配置、屏幕比例定位；`DesktopLyrics.swift` 为独立的 SwiftUI 实现）

## 协议与说明

本项目以 [LGPL-3.0-only](LICENSE) 协议开源（随附 [GPL-3.0](COPYING) 文本）。仅供学习交流，音乐数据与版权归网易云音乐及各音源平台所有。保留上游已有的下载与缓存能力，不新增社交功能。
