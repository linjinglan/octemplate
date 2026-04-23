#!/usr/bin/env python3
"""OpenClaw deployment helper: checks version, installs/reinstalls, and runs onboarding."""

import subprocess
import sys
import re
import json
import argparse
import shutil
import socket
from pathlib import Path


def run(cmd: str, check: bool = False) -> subprocess.CompletedProcess:
    """执行 shell 命令并返回结果."""
    print(f"$ {cmd}")
    return subprocess.run(cmd, shell=True, capture_output=False, text=True, check=check)


def get_installed_version() -> str | None:
    """获取当前安装的 openclaw 版本, 未安装返回 None."""
    try:
        result = subprocess.run(
            "openclaw --version",
            shell=True,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except FileNotFoundError:
        pass
    return None



def normalize_version(raw: str) -> str:
    """去除版本号前缀的 'v', 例如 'v1.2.3' -> '1.2.3'."""
    return re.sub(r"^v", "", raw.strip())


def deep_merge(a: dict, b: dict) -> dict:
    """递归合并: 用 A 的值替换 B, A 有但 B 没有的键直接添加."""
    result = dict(b)  # 保留 B 的原有内容
    for key, val in a.items():
        if key in result and isinstance(result[key], dict) and isinstance(val, dict):
            result[key] = deep_merge(val, result[key])
        else:
            result[key] = val
    return result


LOCAL_CONFIG = Path.home() / ".openclaw" / "openclaw.json"

IP_PLACEHOLDER = "------ip.address------"

# 支持的 shell profile 文件
SHELL_PROFILES = [".bashrc", ".zshrc", ".profile", ".bash_profile"]

# 依赖检查列表
DEPS = [
    ("git", "版本管理"),
    ("node", "Node.js 运行时"),
    ("npm", "Node 包管理器"),
]


def check_environment() -> bool:
    """检查必需的依赖环境是否可用."""
    print("=== 检查运行环境 ===")
    all_ok = True
    for cmd, desc in DEPS:
        try:
            result = subprocess.run(
                f"{cmd} --version",
                shell=True,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                version = result.stdout.strip().split("\n")[0]
                print(f"  ✓ {cmd:6s} - {desc}: {version}")
            else:
                print(f"  ✗ {cmd:6s} - {desc}: 未找到")
                all_ok = False
        except FileNotFoundError:
            print(f"  ✗ {cmd:6s} - {desc}: 未找到")
            all_ok = False

    if not all_ok:
        print("\n错误: 缺少必要的依赖环境, 请先安装后再运行此脚本.")
    else:
        print("====================\n")
    return all_ok


def get_local_ip() -> str:
    """获取本机 IP 地址."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 不需要真正连通, 只是用来获取本机出口 IP
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except OSError:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


def replace_ip_placeholder(config: dict, ip: str) -> None:
    """递归查找并替换配置中的 IP 占位符."""
    for key, val in config.items():
        if key == "allowedOrigins" and isinstance(val, list):
            for i, item in enumerate(val):
                if isinstance(item, str) and IP_PLACEHOLDER in item:
                    val[i] = item.replace(IP_PLACEHOLDER, ip)
        elif isinstance(val, dict):
            replace_ip_placeholder(val, ip)


def set_env_variable(key: str, value: str) -> None:
    """设置系统环境变量, 跨平台支持."""
    # 先设置当前进程的环境变量
    import os
    os.environ[key] = value

    if sys.platform == "win32":
        # Windows: 使用 setx 写入注册表 (持久化)
        print(f"正在设置 Windows 环境变量 {key} ...")
        result = subprocess.run(
            f"setx {key} \"{value}\"",
            shell=True,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print("环境变量设置成功 (重启终端后生效).")
        else:
            print(f"警告: setx 执行失败: {result.stderr.strip()}")
    else:
        # macOS/Linux: 追加到 shell profile
        print(f"正在设置环境变量 {key} 到 shell profile ...")
        export_line = f'export {key}="{value}"\n'
        profile_path = None
        home = str(Path.home())
        for profile_name in SHELL_PROFILES:
            p = Path(home) / profile_name
            if p.exists():
                profile_path = p
                break
        # 如果都没有, 默认 .bashrc
        if profile_path is None:
            profile_path = Path(home) / ".bashrc"

        # 避免重复写入
        content = ""
        if profile_path.exists():
            content = profile_path.read_text(encoding="utf-8")

        if f"export {key}" not in content:
            with open(profile_path, "a", encoding="utf-8") as f:
                f.write(export_line)
            print(f"环境变量已写入 {profile_path} (重启终端后生效).")
        else:
            # 已存在, 更新值
            lines = content.splitlines()
            new_lines = []
            for line in lines:
                if line.strip().startswith(f"export {key}="):
                    new_lines.append(export_line.rstrip())
                else:
                    new_lines.append(line)
            profile_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
            print(f"环境变量已更新 {profile_path} (重启终端后生效).")


def sync_config_from_git() -> None:
    """从 GitHub 仓库下载配置并复制到 openclaw 目录."""
    repo_url = "https://github.com/linjinglan/octemplate.git"
    download_dir = Path.home() / "Downloads"
    clone_target = download_dir / "octemplate"

    # 确保 Downloads 目录存在
    download_dir.mkdir(parents=True, exist_ok=True)

    # 克隆 / 更新仓库 (git 命令跨平台通用)
    if clone_target.exists():
        print("本地已存在 octemplate 仓库, 执行 git pull 更新 ...")
        run(f"git -C \"{clone_target}\" pull", check=True)
    else:
        print(f"正在克隆配置仓库到 {clone_target} ...")
        run(f"git clone \"{repo_url}\" \"{clone_target}\"", check=True)

    # 复制 skills 目录到 ~/.openclaw/
    openclaw_dir = Path.home() / ".openclaw"
    openclaw_dir.mkdir(parents=True, exist_ok=True)
    skills_src = clone_target / ".openclaw" / "skills"
    skills_dst = openclaw_dir / "skills"
    if skills_src.exists():
        print("正在复制 skills 目录到 ~/.openclaw/ ...")
        if skills_dst.exists():
            shutil.rmtree(skills_dst)
        shutil.copytree(str(skills_src), str(skills_dst))
    else:
        print(f"警告: 仓库中不存在 {skills_src}, 跳过.")

    # 复制 workspace 里的 .md 文件到 ~/.openclaw/workspace/
    workspace_src = clone_target / ".openclaw" / "workspace"
    workspace_dst = openclaw_dir / "workspace"
    workspace_dst.mkdir(parents=True, exist_ok=True)
    if workspace_src.exists():
        print("正在复制 workspace 中的 .md 文件到 ~/.openclaw/workspace/ ...")
        for md_file in workspace_src.glob("*.md"):
            shutil.copy2(str(md_file), str(workspace_dst / md_file.name))
    else:
        print(f"警告: 仓库中不存在 {workspace_src}, 跳过.")

    # 合并 openclaw.json 配置: 仓库配置 (A) 覆盖本地配置 (B)
    repo_config_path = clone_target / ".openclaw" / "openclaw.json"
    if repo_config_path.exists():
        print("正在合并 openclaw.json 配置 ...")
        with open(repo_config_path, "r", encoding="utf-8") as f:
            config_a = json.load(f)
        config_b = {}
        if LOCAL_CONFIG.exists():
            with open(LOCAL_CONFIG, "r", encoding="utf-8") as f:
                config_b = json.load(f)
        merged = deep_merge(config_a, config_b)

        # 替换 allowedOrigins 中的 IP 占位符
        local_ip = get_local_ip()
        print(f"本机 IP: {local_ip}")
        replace_ip_placeholder(merged, local_ip)

        LOCAL_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOCAL_CONFIG, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=4, ensure_ascii=False)
        print(f"配置已写入 {LOCAL_CONFIG}")
    else:
        print(f"警告: 仓库中不存在 {repo_config_path}, 跳过合并.")

    print("\n配置同步完成.\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="OpenClaw 部署助手")
    parser.add_argument(
        "--version",
        required=True,
        help="指定要安装的 openclaw 版本 (必填)",
    )
    parser.add_argument(
        "--skip-onboard",
        action="store_true",
        help="跳过 onboarding 引导配置",
    )
    parser.add_argument(
        "--skip-sync",
        action="store_true",
        help="跳过从 GitHub 仓库同步配置",
    )
    parser.add_argument(
        "--ksyun-api-key",
        help="设置 KSYUN_API_KEY 环境变量",
    )
    args = parser.parse_args()

    # 检查运行环境
    if not check_environment():
        sys.exit(1)

    # 设置 KSYUN_API_KEY 环境变量
    if args.ksyun_api_key:
        set_env_variable("KSYUN_API_KEY", args.ksyun_api_key)

    # 确定目标版本
    target = normalize_version(args.version)
    print(f"目标版本: {target}\n")

    # 1. 检查当前版本
    installed = get_installed_version()
    if installed is None:
        print("未检测到 openclaw, 即将开始安装.\n")
        needs_install = True
    else:
        installed = normalize_version(installed)
        print(f"当前已安装版本: {installed}")
        if installed == target:
            print("版本已满足要求, 跳过安装.\n")
            if not args.skip_onboard:
                print("正在启动 onboarding 引导配置 ...\n")
                run("openclaw onboard --install-daemon")
            if not args.skip_sync:
                sync_config_from_git()
            return
        print(f"版本不匹配, 将卸载 {installed} 并安装 {target}.\n")
        # 卸载旧版本
        print("正在卸载旧版本 ...\n")
        run("npm uninstall -g openclaw", check=True)
        needs_install = True

    # 2. 安装目标版本
    install_cmd = f"npm install -g openclaw@{target}"
    print(f"正在安装 openclaw@{target} ...\n")
    run(install_cmd, check=True)

    # 3. 验证安装
    new_version = get_installed_version()
    if new_version:
        print(f"\n安装成功, 当前版本: {normalize_version(new_version)}\n")
    else:
        print("\n安装完成, 但未能获取版本号.\n")

    # 4. 启动 onboarding
    if not args.skip_onboard:
        print("正在启动 onboarding 引导配置 ...\n")
        run("openclaw onboard --install-daemon")

    # 5. 从 GitHub 同步配置
    if not args.skip_sync:
        sync_config_from_git()


if __name__ == "__main__":
    main()
