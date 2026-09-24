#!/usr/bin/env python3
"""Create a signed Sparkle ZIP/appcast for a GitHub release. Never publishes it."""
import argparse
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "cn.hutengqi.OpenTransmit"
REPOSITORY = "https://github.com/hutengqi/OpenTransmit"


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def validate_info(info, tag, configured):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("仅支持正式版本标签，例如 v0.1.2。")
    if info.get("CFBundleIdentifier") != ACCOUNT:
        raise ValueError("应用 Bundle ID 不匹配。")
    if info.get("CFBundleShortVersionString") != tag[1:]:
        raise ValueError("标签必须匹配应用的 MARKETING_VERSION。")
    if not re.fullmatch(r"[1-9][0-9]*", str(info.get("CFBundleVersion", ""))):
        raise ValueError("CURRENT_PROJECT_VERSION 必须是递增的正整数。")
    for name in ("SUPublicEDKey", "SUFeedURL", "SURequireSignedFeed", "SUEnableInstallerLauncherService"):
        if info.get(name) != configured.get(name):
            raise ValueError(f"应用更新配置不匹配：{name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="已签名且已导出的 OpenTransmit.app")
    parser.add_argument("tag", help="GitHub 正式版本标签，例如 v0.1.2")
    parser.add_argument("--notes", type=Path, help="UTF-8 Markdown 更新说明")
    parser.add_argument("--output", type=Path, help="新的输出目录，不允许覆盖")
    parser.add_argument("--allow-development", action="store_true", help="仅本机测试允许开发签名，禁止发布其产物")
    args = parser.parse_args()
    app = args.app.resolve()
    configured = plistlib.loads((ROOT / "Configuration/Info.plist").read_bytes())
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    validate_info(info, args.tag, configured)
    tools = ROOT / ".build/SourcePackages/artifacts/sparkle/Sparkle/bin"
    if not (tools / "generate_appcast").is_file():
        raise ValueError("请先在 Xcode 解析依赖或执行构建。")
    public_key = run(tools / "generate_keys", "--account", ACCOUNT, "-p")
    if public_key != info["SUPublicEDKey"]:
        raise ValueError("钥匙串中的更新签名密钥与应用公钥不匹配。")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if not args.allow_development:
        details = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True, check=True).stderr
        if "Authority=Developer ID Application:" not in details:
            raise ValueError("正式发布需 Developer ID Application 签名；本机测试可传 --allow-development。")
        subprocess.run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], check=True)
    if args.notes and not args.notes.is_file():
        raise ValueError("更新说明文件不存在。")
    output = (args.output or ROOT / ".build/updates" / args.tag).resolve()
    output.mkdir(parents=True, exist_ok=False)
    name = f"OpenTransmit-{args.tag}"
    archive = output / (name + ".zip")
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    if args.notes:
        shutil.copyfile(args.notes, output / (name + ".md"))
    subprocess.run([
        str(tools / "generate_appcast"), "--account", ACCOUNT,
        "--download-url-prefix", f"{REPOSITORY}/releases/download/{args.tag}/",
        "--link", f"{REPOSITORY}/releases/tag/{args.tag}",
        "--embed-release-notes", "--maximum-deltas", "0", str(output)
    ], check=True)
    subprocess.run([str(tools / "sign_update"), "--account", ACCOUNT, "--verify", str(output / "appcast.xml")], check=True)
    print(f"已生成并验证：{archive}\n{output / 'appcast.xml'}")
    print("上传 ZIP 和 appcast.xml 到同一个正式 GitHub Release，再将它设为 Latest。")
    if args.allow_development:
        print("本次是开发签名测试产物，不可作为正式更新发布。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
