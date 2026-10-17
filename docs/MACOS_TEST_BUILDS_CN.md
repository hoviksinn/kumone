# macOS 测试版下载与测试

本流程仅供测试：不发布 Release、不公证，不使用原作者的签名证书、发布密钥或 Sparkle 私钥。

## 在 GitHub 运行

1. 打开 https://github.com/hoviksinn/kumone/actions ，如提示 Actions 尚未启用，先启用。
2. Pull Request（包括 Draft）创建或更新后，CI 会自动运行；在 PR 页面点击 CI 检查的 Details 可查看进度。
3. 手动运行：Actions → CI → Run workflow → 选择 `codex/macos-test-builds`（或后续修改所在分支）→ Run workflow。
   GitHub 要求默认分支存在 workflow_dispatch 才显示手动运行入口；若入口暂不可见，可先通过本 PR 的自动检查构建，无需合并此 Draft PR。
4. 等待 Build、Test、Build app、Zip、Upload 全部成功。失败时查看对应步骤日志；失败的构建不会上传测试包。
5. 打开成功运行的 Summary，向下滚动到 Artifacts，点击 `Kumone-Test-macOS-universal-运行编号-尝试编号`。产物保留 14 天，过期后重新运行。

## 在 Mac 打开

1. 登录 GitHub 下载产物 ZIP，解压后找到 `Kumone-Test-macOS-universal.zip`，再解压得到 `Kumone.app`。
2. 支持 macOS 15 或更高版本，包内含 Apple Silicon 和 Intel 两种架构。
3. **首次测试请使用单独的 macOS 用户账户**（系统设置 → 用户与群组 → 添加用户），将 App 放在该用户的 `~/Applications/Kumone Test.app`，不要覆盖原版 App。
4. 这是只有临时 ad-hoc 签名、未经 Apple 公证的测试包。macOS 可能拦截；确认下载来自自己的 Actions 后，可按系统提示到“系统设置 → 隐私与安全性 → 仍要打开”。不要关闭系统的全局安全保护。若仍不能运行，记录系统提示与 Actions 日志以便排查。

## 隔离范围与限制

CI 设置 `KUMONE_TEST_BUILD=1`：测试版 Bundle ID 为 `com.hoviksinn.kumone.test`，显示名称为 `Kumone Test`；磁盘构建路径仍为 `.build/app/Kumone.app`。偏好设置和按 Bundle ID 存储的缓存与原版隔离。

测试包不包含原作者的更新地址和更新公钥，且设置 `KumoneDisableUpdates`。UpdaterManager 读取此标记后不创建 Sparkle 控制器，自动检查、设置中的开关和手动检查均无法启动更新。仅将 SUEnableAutomaticChecks 设为 false 不足以做到这一点，因为应用设置原本会再次开启检查。

**不同 Bundle ID 并不等于全部数据隔离。** 项目仍有写死的 `~/Library/Application Support/Kumone`、`~/Library/Caches/Kumone` 和 `~/Library/Caches/im.missuo.Kumone` 等路径。同一 macOS 用户下运行会共享部分数据；同时运行也有写入冲突风险。独立系统用户可隔离这些用户目录。本阶段不改存储实现；以后如需在同一用户下并存，应先统一改造并核查所有存储路径、登录信息和后台任务标识。

原有 `release.yml` 仍仅由 `v*` 标签触发，本流程不会创建标签、调用发布流程或自动合并 PR。不要为测试推送发布标签。

## 验证边界

Linux 只能进行脚本语法、配置和差异检查，无法验证 SwiftUI 编译、macOS 自动测试、ditto、codesign 或 App 实际启动。以 macos-26 Actions 的实际结果及 Mac 上的手动测试为准。
