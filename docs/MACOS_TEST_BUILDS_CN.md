# 且听 · macOS 26 / arm64 测试版

本仓库只支持 Apple Silicon Mac、macOS 26.0 及更新版本。测试包不发布 Release、不公证，不使用原作者证书或发布密钥，不提供自动更新。

## 在 GitHub 运行和下载

1. 打开 https://github.com/hoviksinn/kumone/actions/workflows/ci.yml ，如提示 Actions 未启用，先启用。
2. Pull Request（包括 Draft）创建或更新后自动运行 CI。在 PR 的检查区域点击 CI → Details 查看进度。
3. 手动运行：Actions → CI → Run workflow → 选择本次修改分支 → Run workflow。选择当前 PR 的开发分支可测试尚未合并的修改；合并后可以选择 `main`。
4. 等待编译、测试、打包、架构/系统版本检查、ZIP 和上传全部成功。失败时查看对应步骤日志，失败构建不会上传 App。
5. 打开成功运行的 Summary，向下滚动到 Artifacts，点击 `QieTing-Test-macOS26-arm64-运行编号-尝试编号`。需登录 GitHub，产物保留 14 天。
6. 解压下载的外层 ZIP，再解压其中的 `QieTing-Test-macOS26-arm64.zip`，得到 `且听.app`。旁边的 `app-verification.json` 记录实际架构、最低系统版本、文件大小、应用名称、矢量图标资源和 Metal 核校验值。

## 在 Mac 测试

- 首次请使用单独的 macOS 用户账户（系统设置 → 用户与群组 → 添加用户）。将 App 放进该用户的 `~/Applications/且听.app`，不要覆盖原版。
- App 只有 ad-hoc 临时签名，未经 Apple 公证。确认来自自己仓库的 Actions 后，可按系统提示到“系统设置 → 隐私与安全性 → 仍要打开”；不要关闭系统全局安全保护。
- 请实际检查：网易云登录与重启后保持登录、搜索、无损播放、暂停切歌/队列、歌单收藏、同步/逐字/翻译/桌面歌词、沉浸页面、AutoMix、模型下载后音轨分离、媒体键/控制中心、缓存和设置。
- CI 的 MLX GPU 小运算测试可验证 Metal 核加载和运行，不能替代下载模型后的完整音轨分离、真实账号和音频设备测试。

## 隔离范围

所有打包入口固定使用 Bundle ID `com.hoviksinn.kumone.test`，显示名称为「且听」，App 路径为 `.build/app/且听.app`。内部可执行文件与 SwiftPM 模块仍保留 Kumone 名称。此次更名不更改 Bundle ID、偏好设置键、Cookie 或数据目录，不迁移已有登录、缓存或下载。不能切回原版身份。

Info.plist 不包含上游更新地址或公钥，并固定 `KumoneDisableUpdates=true`、`SUEnableAutomaticChecks=false`、`SUAllowsAutomaticUpdates=false`。UpdaterManager 不创建 Sparkle 控制器，自动、手动检查及设置开关均无法启动更新。Sparkle 暂保留为既有模块依赖；嵌入的框架和辅助程序也仅保留 arm64。

不同 Bundle ID 仅隔离偏好设置及按 ID 存储的缓存。部分目录仍固定为 `~/Library/Application Support/Kumone`、`~/Library/Caches/Kumone`、`~/Library/Caches/im.missuo.Kumone`，同一系统用户仍会共享部分数据。独立系统用户是当前安全隔离方案；本次不进行数据迁移。

旧 release.yml、IPA/AltStore 生成及模型上传脚本已移除，不再有标签触发的正式发布工作流。应用的模型下载 URL、摘要和来源许可保留，避免影响现有音轨分离。

## 开发与验证

使用 Apple Silicon、macOS 26+、Xcode 26+，运行 `make build`、`make test` 和 `FETCH_MLX_METALLIB=1 make app CONFIG=release`。

测试准备会先编译全部测试，把固定版本、SHA-256 核验的 MLX Metal 核放入测试执行目录，再运行完整测试套件（`--skip-build` 只复用刚编译的测试，不跳过测试）。同一份核缓存在 `.build`，供 release 打包复用。MLX 0.30.6 的预编译核来自最低系统为 macOS 15 的 arm64 wheel，可用于 macOS 26；这不是 App 的部署目标，App 和自身代码仍要求 macOS 26.0。

Linux 仅执行脚本语法、配置、引用和差异检查。SwiftUI 编译、自动测试、GPU、ditto、codesign 及实际 Mach-O 检查以 macos-26 Actions 结果为准，App 真实功能以 Mac 手测为准。

## 本轮体验回归

下载「且听」后，重点比较 UI 和 F8 暂停恢复听感、连续快速切换、Seek 后歌词同步、右侧歌词/队列展开、队列单击/双击/删除，以及窄窗口播放栏。分别在内建 ProMotion 与外接 60Hz 屏幕检查滚动和动画；CI 通过无法证明真实扬声器/耳机的声音或屏幕刷新率体验。关于窗口保留 Kumone 来源和原作者版权。
