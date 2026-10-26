#!/usr/bin/env python3
"""Label a gated UI Preview without implying that full regression has finished."""
import argparse
import json
import os
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.output
    gates = {}
    for name, minimum in (
        ("native-toolbar-test-summary.json", 3),
        ("native-scroll-test-summary.json", 5),
        ("window-test-summary.json", 19),
        ("control-boundary-bridge-test-summary.json", 1),
        ("control-boundary-output-test-summary.json", 14),
        ("lyrics-seek-test-summary.json", 3),
        ("seek-clock-test-summary.json", 18),
        ("segment-eof-test-summary.json", 1),
    ):
        summary = json.loads((root / name).read_text())
        if summary.get("tests_passed", 0) < minimum:
            raise SystemExit(f"Preview blocked: {name} has fewer than {minimum} passed tests")
        gates[name] = summary
    app = json.loads((root / "app-verification.json").read_text())
    if (app.get("bundle_id") != "com.hoviksinn.kumone.test"
            or app.get("updates_disabled") is not True
            or app.get("app_bundle") != "且听.app"
            or app.get("executable_minos") != "26.0"
            or not app.get("mach_o_binaries")
            or any(b.get("architectures") != ["arm64"] for b in app["mach_o_binaries"])):
        raise SystemExit("Preview blocked: app identity, deployment or architecture was not verified")
    source = os.environ["QIETING_SOURCE_HEAD"]
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise SystemExit("Preview blocked: missing or invalid source commit")
    run_url = (f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
               f"/actions/runs/{os.environ['GITHUB_RUN_ID']}")
    status = {
        "channel": "Preview", "source_head": source,
        "validation_commit": os.environ["GITHUB_SHA"], "run_url": run_url,
        "passed_targeted_gates": gates,
        "full_regression_at_upload": "pending; inspect the completed run separately",
        "physical_visual_and_120hz_acceptance": "pending",
        "control_boundary_click_pop": "inline production output gates passed; physical listening pending; no universal direct-replacement or wet-tail claim",
    }
    (root / "preview-status.json").write_text(
        json.dumps(status, indent=2, ensure_ascii=False) + "\n")
    (root / "PREVIEW.md").write_text(
        "# 且听 QieTing · UI / Audio Preview\n\n"
        "此包通过基础编译、原生工具栏和滚动、真实窗口/歌词 Seek、媒体时钟与严格 PCM、AutoMix EOF 及生产输出 De-click 专项，"
        "以及 macOS 26 arm64 App 打包校验。**上传 Preview 时，完整回归尚未完成。**\n\n"
        f"源码：`{source}`\n\n[查看本次 CI 的最终结果]({run_url})。"
        "只有完整回归成功后才会上传同一次构建的 QieTing-Test 包。\n\n"
        "请实机检查导航、玻璃搜索、侧栏半透明材质、系统滚动条偏好、Seek 歌词定位、"
        "屏幕右缘反复开合、ProMotion/60Hz 与减少动态效果。云端不证明所有界面达到 120fps，"
        "也未唯一复现 macOS 27 的偶发窗口异常。暂停/恢复 De-click 已接入真实生产输出并通过上述专项，仍须用耳机和扬声器确认听感；不承诺所有直接切歌或湿延迟尾音均已消除电流音。\n\n"
        "解压外层 Artifact ZIP 后再解压 QieTing-Preview ZIP，运行其中的 且听.app。"
        "沿用独立测试 Bundle ID、原有数据身份和签名方式；自动更新禁用。"
        "不清理缓存、用户歌曲、登录信息或 AI 模型。\n"
    )


if __name__ == "__main__":
    main()
