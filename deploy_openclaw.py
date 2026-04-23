#!/usr/bin/env python3
"""OpenClaw deployment helper: checks version, installs/reinstalls, and runs onboarding."""

import subprocess
import sys
import re
import json
import argparse
import shutil
import socket
import os
from datetime import datetime
from pathlib import Path


class DeployError(Exception):
    """部署失败异常."""
    pass


def run(cmd: str, check: bool = False, description: str = "") -> subprocess.CompletedProcess:
    """执行 shell 命令并返回结果, 支持友好错误提示."""
    label = description or cmd
    print(f"$ {cmd}")
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=False, text=True, check=check
        )
        if check and result.returncode != 0:
            raise DeployError(f"{label} 执行失败, 退出码: {result.returncode}")
        return result
    except FileNotFoundError:
        if check:
            raise DeployError(f"找不到命令: {cmd.split()[0]}")
        return subprocess.CompletedProcess(cmd, -1, "", "")
    except subprocess.CalledProcessError as e:
        raise DeployError(f"{label} 执行失败: {e}")


def backup_if_exists(path: Path) -> Path | None:
    """如果路径存在, 创建带时间戳的备份副本, 返回备份路径."""
    if not path.exists():
        return None
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = Path(f"{path}.bak.{timestamp}")
    if path.is_dir():
        shutil.copytree(str(path), str(backup_path))
    else:
        shutil.copy2(str(path), str(backup_path))
    print(f"已备份: {path} → {backup_path}")
    return backup_path


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


def restart_in_new_shell() -> None:
    """重启当前脚本, 在新终端窗口中执行后续命令."""
    if sys.platform == "win32":
        # Windows 11: 新打开一个 Windows Terminal 窗口
        python_exe = sys.executable
        script = os.path.abspath(sys.argv[0])
        remaining_args = [a for a in sys.argv[1:] if a != "--env-done"]
        args_str = " ".join(remaining_args)
        cmd_line = f'"{python_exe}" "{script}" {args_str} --env-done'
        subprocess.Popen(
            f'wt new-tab --title "OpenClaw部署" cmd.exe /k {cmd_line}',
            shell=True,
        )
        print("已在新终端窗口中继续执行.")
    else:
        # macOS/Linux: 直接 subprocess.run
        cmd_args = [sys.executable, script] + remaining_args + ["--env-done"]
        result = subprocess.run(cmd_args)
        sys.exit(result.returncode)


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
    # 设置当前进程的环境变量, 子进程自动继承
    os.environ[key] = value

    if sys.platform == "win32":
        # Windows: 使用 setx 写入注册表 (持久化, 下次新终端生效)
        print(f"正在设置 Windows 环境变量 {key} ...")
        result = subprocess.run(
            f"setx {key} \"{value}\"",
            shell=True,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print("环境变量已设置 (持久化到注册表).")
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
        if profile_path is None:
            profile_path = Path(home) / ".bashrc"

        # 避免重复写入
        content = ""
        if profile_path.exists():
            content = profile_path.read_text(encoding="utf-8")

        if f"export {key}" not in content:
            with open(profile_path, "a", encoding="utf-8") as f:
                f.write(export_line)
            print(f"环境变量已写入 {profile_path} (需要重启 shell 生效).")
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
            print(f"环境变量已更新 {profile_path} (下次新终端生效).")


def clone_repo() -> Path:
    """克隆或更新 GitHub 仓库, 返回克隆目录."""
    repo_url = "https://github.com/linjinglan/octemplate.git"
    download_dir = Path.home() / "Downloads"
    clone_target = download_dir / "octemplate"

    # 确保 Downloads 目录存在
    download_dir.mkdir(parents=True, exist_ok=True)

    # 检查 .git 目录是否存在, 避免空目录导致 git pull 失败
    is_valid_repo = clone_target.exists() and (clone_target / ".git").exists()
    if is_valid_repo:
        print("本地已存在 octemplate 仓库, 执行 git pull 更新 ...")
        try:
            run(f"git -C \"{clone_target}\" pull", check=True, description="git pull")
        except DeployError as e:
            print(f"警告: git pull 失败 ({e}), 将重新克隆 ...")
            shutil.rmtree(str(clone_target))
            is_valid_repo = False

    if not is_valid_repo:
        print(f"正在克隆配置仓库到 {clone_target} ...")
        try:
            run(f"git clone \"{repo_url}\" \"{clone_target}\"", check=True, description="git clone")
        except DeployError as e:
            raise DeployError(f"克隆仓库失败: {e}")

    return clone_target


def apply_config_from_repo(clone_target: Path) -> None:
    """将克隆仓库中的配置复制到 openclaw 目录."""
    # 复制 skills 目录到 ~/.openclaw/
    openclaw_dir = Path.home() / ".openclaw"
    openclaw_dir.mkdir(parents=True, exist_ok=True)
    skills_src = clone_target / ".openclaw" / "skills"
    skills_dst = openclaw_dir / "skills"
    if skills_src.exists():
        print("正在复制 skills 目录到 ~/.openclaw/ ...")
        if skills_dst.exists():
            backup_if_exists(skills_dst)
            shutil.rmtree(str(skills_dst))
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
            # 写入前备份原文件
            backup_if_exists(LOCAL_CONFIG)
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


def cleanup_repo(clone_target: Path) -> None:
    """清理临时克隆目录."""
    if clone_target.exists():
        print(f"正在清理临时目录 {clone_target} ...")
        shutil.rmtree(str(clone_target))


def sync_config_from_git(cleanup: bool = False) -> Path:
    """从 GitHub 仓库下载配置并复制到 openclaw 目录, 返回克隆目录."""
    clone_target = clone_repo()
    apply_config_from_repo(clone_target)
    if cleanup:
        cleanup_repo(clone_target)
    print("\n配置同步完成.\n")
    return clone_target


def install_channel_plugin(channel: str, clone_target: Path) -> None:
    """根据渠道安装插件."""
    if channel == "agentspace":
        print("=== 安装 AgentSpace 插件 ===")
        try:
            run("npx -y clear-npx-cache", check=True, description="清理 npx 缓存")
            run(
                "npx -y https://agentspace.wps.cn/openclaw/plugins/installer",
                check=True,
                description="安装 AgentSpace 插件",
            )
        except DeployError as e:
            raise DeployError(f"AgentSpace 插件安装失败: {e}")
        print("AgentSpace 插件安装完成.\n")

    elif channel == "wps-xiezuo":
        print("=== 安装 WPS 协作插件 ===")
        bundle_dir = clone_target / "wps-xiezuo" / "openclaw-wps-xiezuo-bundle"

        # 检查是否已安装
        print("正在检查插件安装状态 ...")
        result = subprocess.run(
            "openclaw plugins inspect wps-xiezuo",
            shell=True,
            capture_output=True,
            text=True,
        )
        is_installed = "Plugin not found" not in result.stdout

        if is_installed:
            print("插件已安装, 正在卸载旧版本 ...")
            scripts_dir = bundle_dir / "scripts"
            if scripts_dir.exists():
                if sys.platform == "win32":
                    uninstall_script = scripts_dir / "uninstall.ps1"
                    if uninstall_script.exists():
                        run(
                            f"powershell -ExecutionPolicy Bypass -File \"{uninstall_script}\"",
                            check=True,
                            description="卸载 WPS 协作插件",
                        )
                else:
                    uninstall_script = scripts_dir / "uninstall.sh"
                    if uninstall_script.exists():
                        run(f"bash \"{uninstall_script}\"", check=True, description="卸载 WPS 协作插件")
        else:
            print("插件未安装.")

        # 安装新版本
        if sys.platform == "win32":
            plugin_dir = bundle_dir / "plugin"
            if plugin_dir.exists():
                tgz_files = list(plugin_dir.glob("*.tgz"))
                if tgz_files:
                    tgz_path = tgz_files[0]
                    print(f"正在安装插件: {tgz_path}")
                    run(
                        f"cd \"{plugin_dir}\" && openclaw plugins install \"{tgz_path.name}\"",
                        check=True,
                        description="安装 WPS 协作插件",
                    )
                else:
                    raise DeployError(f"在 {plugin_dir} 未找到 .tgz 文件")
            else:
                raise DeployError(f"插件目录不存在: {plugin_dir}")
        else:
            if bundle_dir.exists():
                run(
                    f"bash \"{bundle_dir}/scripts/install.sh\"",
                    check=True,
                    description="安装 WPS 协作插件",
                )
            else:
                raise DeployError(f"插件目录不存在: {bundle_dir}")

        print("WPS 协作插件安装完成.\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="OpenClaw 部署助手")
    parser.add_argument(
        "--env-done",
        action="store_true",
        help=argparse.SUPPRESS,
    )
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
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help="同步完成后清理临时克隆的仓库目录",
    )
    parser.add_argument(
        "--channel",
        choices=["agentspace", "wps-xiezuo"],
        help="渠道参数, 用于安装渠道专属插件",
    )
    args = parser.parse_args()

    # clone_target 用于在渠道插件安装和配置同步之间共享
    clone_target = None

    # 检查运行环境
    if not check_environment():
        sys.exit(1)

    # 设置 KSYUN_API_KEY 环境变量
    if args.ksyun_api_key and not args.env_done:
        set_env_variable("KSYUN_API_KEY", args.ksyun_api_key)
        print("环境变量已设置, 正在打开新终端窗口继续部署 ...\n")
        restart_in_new_shell()
        return  # 打开新窗口后退出当前进程

    # 确定目标版本
    target = normalize_version(args.version)
    print(f"目标版本: {target}\n")

    # 1. 检查当前版本
    installed = get_installed_version()
    if installed is None:
        print("未检测到 openclaw, 即将开始安装.\n")
    else:
        installed = normalize_version(installed)
        print(f"当前已安装版本: {installed}")
        if target in installed:
            print("版本已满足要求, 跳过安装.\n")
            if not args.skip_onboard:
                print("正在启动 onboarding 引导配置 ...")
                print("请按照提示完成配置, 完成后按回车继续.\n")
                subprocess.run("openclaw onboard --install-daemon", shell=True)
                input("\n按回车键继续下一步操作 ...")
                print()
            if not args.skip_sync:
                try:
                    # 先克隆仓库
                    clone_target = clone_repo()
                    # 再安装渠道插件
                    if args.channel:
                        print("=== 停止 openclaw gateway ===")
                        run("openclaw gateway stop", description="停止 gateway")
                        install_channel_plugin(args.channel, clone_target)
                    # 最后应用配置
                    apply_config_from_repo(clone_target)
                    if args.cleanup:
                        cleanup_repo(clone_target)
                    # 启动 gateway
                    print("=== 启动 openclaw gateway ===")
                    run("openclaw gateway start", description="启动 gateway")
                except DeployError as e:
                    print(f"错误: 配置同步失败 - {e}")
                    sys.exit(1)
            return
        print(f"版本不匹配, 将卸载 {installed} 并安装 {target}.\n")
        # 卸载旧版本
        print("正在卸载旧版本 ...\n")
        try:
            run("npm uninstall -g openclaw", check=True, description="卸载旧版本")
        except DeployError as e:
            print(f"错误: {e}")
            sys.exit(1)

    # 2. 安装目标版本
    install_cmd = f"npm install -g openclaw@{target}"
    print(f"正在安装 openclaw@{target} ...\n")
    try:
        run(install_cmd, check=True, description="安装 openclaw")
    except DeployError as e:
        print(f"错误: {e}")
        sys.exit(1)

    # 3. 验证安装
    new_version = get_installed_version()
    if new_version:
        print(f"\n安装成功, 当前版本: {normalize_version(new_version)}\n")
    else:
        print("\n安装完成, 但未能获取版本号.\n")

    # 4. 启动 onboarding
    if not args.skip_onboard:
        print("正在启动 onboarding 引导配置 ...")
        print("请按照提示完成配置, 完成后按回车继续.\n")
        subprocess.run("openclaw onboard --install-daemon", shell=True)
        input("\n按回车键继续下一步操作 ...")
        print()

    # 5. 安装渠道插件
    if args.channel and not args.skip_sync:
        try:
            print("=== 停止 openclaw gateway ===")
            run("openclaw gateway stop", description="停止 gateway")
            clone_target = clone_repo()
            install_channel_plugin(args.channel, clone_target)
        except DeployError as e:
            print(f"错误: 渠道插件安装失败 - {e}")
            sys.exit(1)

    # 6. 从 GitHub 同步配置
    if not args.skip_sync:
        try:
            if clone_target is None:
                clone_target = clone_repo()
            apply_config_from_repo(clone_target)
            if args.cleanup:
                cleanup_repo(clone_target)
            # 启动 gateway
            print("=== 启动 openclaw gateway ===")
            run("openclaw gateway start", description="启动 gateway")
        except DeployError as e:
            print(f"错误: 配置同步失败 - {e}")
            sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except DeployError as e:
        print(f"错误: {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n\n用户中断, 退出部署.")
        sys.exit(130)
