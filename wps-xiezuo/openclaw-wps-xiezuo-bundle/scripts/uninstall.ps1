# 设置错误处理偏好
$ErrorActionPreference = "Continue"

# --- 1. 关键路径配置 ---
# 获取当前脚本所在目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# 获取上一级目录作为 Bundle Root
$BundleRoot = Split-Path -Parent $ScriptDir
$ConfigFile = Join-Path $BundleRoot "config\plugin.env"

# --- 2. 颜色日志函数 ---
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    switch ($Level) {
        "INFO"  { Write-Host "[INFO] $Message" -ForegroundColor Green }
        "WARN"  { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        "ERROR" { Write-Host "[ERROR] $Message" -ForegroundColor Red }
    }
}

# --- 3. 辅助函数：清理配置 ---
function Cleanup-StaleConfig {
    # 官方命令清理 channels 与 plugins 的历史残留
    $commands = @(
        "channels.wps",
        "channels.wps-xiezuo",
        "channels.openclaw-wps-xiezuo",
        "plugins.entries.wps",
        "plugins.entries.wps-xiezuo"
    )
    
    foreach ($cmd in $commands) {
        try {
            # 使用 2>$null 隐藏可能的错误输出，|| true 在 PS 中通过 try/catch 实现
            & openclaw config delete $cmd 2>$null
        } catch {
            # 忽略错误，继续执行
        }
    }
}

# --- 4. 主逻辑开始 ---

# 1) 环境检查
if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
    Write-Log "未找到 openclaw 命令" "ERROR"
    exit 1
}

# 2) 定义变量
$OPENCLAW_CHANNEL_ID = "wps-xiezuo"
$OPENCLAW_PLUGIN_ID = "wps-xiezuo"
$EXTENSIONS_ROOT = Join-Path $env:USERPROFILE ".openclaw\extensions"
$TARGET_EXTENSION_DIR = Join-Path $EXTENSIONS_ROOT $OPENCLAW_PLUGIN_ID
$LEGACY_EXTENSION_DIR = Join-Path $EXTENSIONS_ROOT "wps"

# 3) 二次确认
Write-Log "即将彻底清理插件（配置 + 源码目录）" "WARN"
Write-Log "目标 channel: $OPENCLAW_CHANNEL_ID" "WARN"
Write-Log "目标目录: $TARGET_EXTENSION_DIR" "WARN"
Write-Log "历史目录: $LEGACY_EXTENSION_DIR" "WARN"

$confirm = Read-Host "确认卸载？(y/N)"
if ($confirm -notmatch '^[Yy]$') {
    Write-Log "卸载已取消" "INFO"
    exit 0
}

# 4) 删除配置
Write-Log "清理 channel 配置..." "INFO"
# 既然 openclaw 命令可用，直接使用其自带的清理功能
# 注意：这里移除了 Node.js 的 JSON 处理，直接依赖 openclaw 命令
try {
    # 尝试修复/清理
    & openclaw doctor --fix 2>$null
} catch {}

# 执行具体的删除命令
Cleanup-StaleConfig
try { & openclaw config delete "channels.$OPENCLAW_CHANNEL_ID" 2>$null } catch {}

# 5) 卸载插件包
Write-Log "卸载插件包（可能需要几秒）..." "INFO"
$plugins = @($OPENCLAW_PLUGIN_ID, "wps")
foreach ($p in $plugins) {
    try {
        & openclaw plugins uninstall $p 2>$null
    } catch {
        # 忽略卸载不存在的插件时的报错
    }
}

# 6) 删除源码目录 (物理删除)
Write-Log "删除插件源码目录..." "INFO"
if (Test-Path $TARGET_EXTENSION_DIR) { 
    Remove-Item -Recurse -Force $TARGET_EXTENSION_DIR 
}
if (Test-Path $LEGACY_EXTENSION_DIR) { 
    Remove-Item -Recurse -Force $LEGACY_EXTENSION_DIR 
}

# 6.1) 再次执行官方修复，确保配置干净
Write-Log "执行 openclaw doctor --fix 进行最终检查..." "INFO"
try { & openclaw doctor --fix 2>$null } catch {}

# 7) 验证
$ValidationFailed = $false

# 检查目录是否存在
if ((Test-Path $TARGET_EXTENSION_DIR) -or (Test-Path $LEGACY_EXTENSION_DIR)) {
    Write-Log "卸载验证失败：插件目录仍存在" "ERROR"
    $ValidationFailed = $true
}

# 既然不使用 Node，我们通过检查 openclaw config list 或 doctor 的返回状态来验证
# 这里简单检查 openclaw doctor 是否能正常通过（通常 doctor 失败意味着配置有问题）
if (-not $ValidationFailed) {
    # 尝试运行 doctor，如果返回非0，可能意味着配置仍有问题
    # 注意：PowerShell 捕获外部程序退出码需用 $? 或 $LASTEXITCODE
    & openclaw doctor 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "卸载验证警告：openclaw doctor 检测到潜在配置问题" "WARN"
        # 这里不强制退出，因为 doctor 可能会自动修复，或者只是警告
    }
}

if ($ValidationFailed) {
    exit 1
}

Write-Log "? openclaw-wps-xiezuo 卸载成功" "INFO"