# Kumone development

- Support only macOS 26.0+ on Apple Silicon (`arm64`). Do not add iOS, iPadOS, CarPlay, Intel, Universal Binary, or other platform applications.
- Use Swift, SwiftUI, AppKit, and modern Apple native APIs. Remove obsolete compatibility branches when their macOS behavior is clear; avoid rewrites that do not improve maintainability.
- Preserve all existing macOS features: NetEase login/session, search, playback/queue/library/recommendations, audio quality/lossless, lyrics/translations/desktop/immersive view, AutoMix/stems, media controls, caches, persistence, and settings.
- Check callers and dependency chains before deleting code. Keep uncertain shared code and explain it. Never remove tests, disable features, or add empty implementations to conceal failures. Preserve licenses, copyrights, and third-party notices.
- Keep module boundaries clear. `KumoneCore` owns app behavior; `KumoneLauncher` wires `StemKit` into it. Retain pinned MLX dependencies and matching verified Metal kernels unless changing and validating them intentionally.
- Use Xcode on Apple Silicon for local development. SwiftPM commands use `--triple arm64-apple-macosx26.0`. Linux is for static/ref checks only; never claim a macOS build/test passed there.
- Package only test apps with Bundle ID `com.hoviksinn.kumone.test` and updates disabled. Do not restore upstream certificates, keys, feeds, or release automation. Some data paths still share upstream names: use a separate macOS user for safe testing until an explicit storage migration is implemented.
- Start each task from current `main` on a separate branch. Use logical commits. Finish local static/script checks before pushing changes together when practical, to avoid unnecessary Actions runs.
- Verify every completed task through the macOS GitHub Actions CI: Swift Build, Swift Test (including MLX GPU smoke test), arm64 App packaging, binary/deployment checks, ZIP and artifact upload. Inspect the actual result and report limitations honestly. Download artifacts from the completed run's Summary.
- Open a Draft PR in `hoviksinn/kumone`. Never automatically merge a PR or publish a formal release. Do not trigger workflows in upstream repositories.
