#!/usr/bin/env bash
set -euo pipefail

# 关键路径：根据 bundle 内配置决定要删除的 channel id
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$BUNDLE_ROOT/config/plugin.env"

# 颜色日志输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup_stale_config() {
  # 官方命令清理 channels 与 plugins 的历史残留
  openclaw config delete "channels.wps" >/dev/null 2>&1 || true
  openclaw config delete "channels.wps-xiezuo" >/dev/null 2>&1 || true
  openclaw config delete "channels.openclaw-wps-xiezuo" >/dev/null 2>&1 || true
  openclaw config delete "plugins.entries.wps" >/dev/null 2>&1 || true
  openclaw config delete "plugins.entries.wps-xiezuo" >/dev/null 2>&1 || true
  openclaw config delete "plugins.entries.openclaw-wps-xiezuo" >/dev/null 2>&1 || true
  openclaw config delete "plugins.installs.wps" >/dev/null 2>&1 || true
  openclaw config delete "plugins.installs.wps-xiezuo" >/dev/null 2>&1 || true
  openclaw config delete "plugins.installs.openclaw-wps-xiezuo" >/dev/null 2>&1 || true
}

prune_openclaw_sessions() {
  # 清理所有 agent 的 sessions.json 中 wps/wps-xiezuo 会话残留
  local agents_root="$HOME/.openclaw/agents"
  if [ ! -d "$agents_root" ]; then
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    log_warn "未找到 node，跳过 sessions.json 兜底清理"
    return 0
  fi
  node - "$agents_root" <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
if (!root || !fs.existsSync(root)) process.exit(0);
try {
  const agentIds = fs.readdirSync(root, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
  for (const agentId of agentIds) {
    const file = path.join(root, agentId, "sessions", "sessions.json");
    if (!fs.existsSync(file)) continue;
    const data = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!data || typeof data !== "object" || Array.isArray(data)) continue;
    const next = {};
    for (const [key, value] of Object.entries(data)) {
      const record = value && typeof value === "object" ? value : {};
      const origin = record.origin && typeof record.origin === "object" ? record.origin : {};
      const deliveryContext = record.deliveryContext && typeof record.deliveryContext === "object" ? record.deliveryContext : {};
      const hitByWpsXiezuoKey = /:wps-xiezuo:/i.test(String(key));
      const hitByLegacyWpsKey = /:wps:/i.test(String(key));
      const hitByOriginProvider = String(origin.provider || "").toLowerCase() === "wps-xiezuo";
      const hitByChannel =
        String(record.lastChannel || "").toLowerCase() === "wps-xiezuo" ||
        String(deliveryContext.channel || "").toLowerCase() === "wps-xiezuo";
      if (hitByWpsXiezuoKey || hitByOriginProvider || hitByChannel || (hitByLegacyWpsKey && (hitByOriginProvider || hitByChannel))) continue;
      next[key] = value;
    }
    fs.writeFileSync(file, JSON.stringify(next, null, 2) + "\n", "utf8");
  }
} catch {
  process.exit(0);
}
NODE
}

prune_openclaw_json() {
  # 兜底清理：当配置已损坏导致 openclaw config 命令不可用时，直接清理 JSON 残留项
  local json_path="$HOME/.openclaw/openclaw.json"
  if [ ! -f "$json_path" ]; then
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    log_warn "未找到 node，跳过 openclaw.json 兜底清理"
    return 0
  fi
  node - "$json_path" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
if (!file || !fs.existsSync(file)) process.exit(0);
try {
  let content = fs.readFileSync(file, "utf8");
  // 尝试修复常见的 JSON 格式问题
  content = content
    .replace(/,\s*([}\]])/g, '$1')  // 移除尾随逗号
    .replace(/([{,])\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*:/g, '$1"$2":');  // 为未加引号的键添加引号

  const cfg = JSON.parse(content);
  if (cfg.channels && typeof cfg.channels === "object") {
    delete cfg.channels["wps"];
    delete cfg.channels["wps-xiezuo"];
    delete cfg.channels["openclaw-wps-xiezuo"];
  }
  if (cfg.plugins && typeof cfg.plugins === "object") {
    if (cfg.plugins.entries && typeof cfg.plugins.entries === "object") {
      delete cfg.plugins.entries["wps"];
      delete cfg.plugins.entries["wps-xiezuo"];
      delete cfg.plugins.entries["openclaw-wps-xiezuo"];
      for (const [k, v] of Object.entries(cfg.plugins.entries)) {
        const key = String(k).toLowerCase();
        const val = JSON.stringify(v).toLowerCase();
        if (key.includes("xiezuo") || val.includes("xiezuo") || val.includes(".openclaw-install-stage-")) {
          delete cfg.plugins.entries[k];
        }
      }
    }
    if (cfg.plugins.installs && typeof cfg.plugins.installs === "object") {
      delete cfg.plugins.installs["wps"];
      delete cfg.plugins.installs["wps-xiezuo"];
      delete cfg.plugins.installs["openclaw-wps-xiezuo"];
      for (const [k, v] of Object.entries(cfg.plugins.installs)) {
        const key = String(k).toLowerCase();
        const val = JSON.stringify(v).toLowerCase();
        if (key.includes("xiezuo") || val.includes("xiezuo") || val.includes(".openclaw-install-stage-")) {
          delete cfg.plugins.installs[k];
        }
      }
    }
    if (Array.isArray(cfg.plugins.allow)) {
      cfg.plugins.allow = cfg.plugins.allow.filter((item) => !["wps", "wps-xiezuo", "openclaw-wps-xiezuo"].includes(String(item)));
    }
  }
  if (Array.isArray(cfg.bindings)) {
    cfg.bindings = cfg.bindings.filter((item) => !(item && item.match && item.match.channel === "wps-xiezuo"));
  }
  fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n", "utf8");
} catch (err) {
  // JSON 解析失败时静默退出，不影响卸载流程
  process.exit(0);
}
NODE
}

# 1) 环境检查：必须已安装 openclaw CLI
if ! command -v openclaw >/dev/null 2>&1; then
  log_error "未找到 openclaw 命令"
  exit 1
fi

# 2) 固定 channel id：统一为 wps-xiezuo
OPENCLAW_CHANNEL_ID="wps-xiezuo"
OPENCLAW_PLUGIN_ID="wps-xiezuo"
OPENCLAW_PLUGIN_ID_ALT="openclaw-wps-xiezuo"
EXTENSIONS_ROOT="$HOME/.openclaw/extensions"
TARGET_EXTENSION_DIR="$EXTENSIONS_ROOT/$OPENCLAW_PLUGIN_ID"
TARGET_EXTENSION_DIR_ALT="$EXTENSIONS_ROOT/$OPENCLAW_PLUGIN_ID_ALT"
LEGACY_EXTENSION_DIR="$EXTENSIONS_ROOT/wps"

# 3) 二次确认，防止误删
log_warn "即将彻底清理插件（配置 + 源码目录）"
log_warn "目标 channel: $OPENCLAW_CHANNEL_ID"
log_warn "目标目录: $TARGET_EXTENSION_DIR"
log_warn "目标目录(兼容): $TARGET_EXTENSION_DIR_ALT"
log_warn "历史目录: $LEGACY_EXTENSION_DIR"
read -r -p "确认卸载？(y/N): " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  log_info "卸载已取消"
  exit 0
fi

# 4) 删除所有相关 channel 配置，确保 openclaw.json 干净
log_info "清理 channel 配置..."
prune_openclaw_json
prune_openclaw_sessions
openclaw config delete "channels.$OPENCLAW_CHANNEL_ID" >/dev/null 2>&1 || true
cleanup_stale_config

# 5) 卸载插件包（新旧 ID 都尝试）
log_info "卸载插件包（可能需要几秒）..."
if command -v timeout >/dev/null 2>&1; then
  timeout 20s openclaw plugins uninstall "$OPENCLAW_PLUGIN_ID" >/dev/null 2>&1 || true
  timeout 20s openclaw plugins uninstall "$OPENCLAW_PLUGIN_ID_ALT" >/dev/null 2>&1 || true
  timeout 20s openclaw plugins uninstall "wps" >/dev/null 2>&1 || true
else
  openclaw plugins uninstall "$OPENCLAW_PLUGIN_ID" >/dev/null 2>&1 || true
  openclaw plugins uninstall "$OPENCLAW_PLUGIN_ID_ALT" >/dev/null 2>&1 || true
  openclaw plugins uninstall "wps" >/dev/null 2>&1 || true
fi

# 6) 删除插件源码目录（你要求的彻底清理）
log_info "删除插件源码目录..."
rm -rf "$TARGET_EXTENSION_DIR"
rm -rf "$TARGET_EXTENSION_DIR_ALT"
rm -rf "$LEGACY_EXTENSION_DIR"
if [ -d "$EXTENSIONS_ROOT" ]; then
  find "$EXTENSIONS_ROOT" -maxdepth 1 -type d -name ".openclaw-install-stage-*" -exec rm -rf {} + >/dev/null 2>&1 || true
fi

# 6.1) 官方修复：清理 schema 无法接受的陈旧配置（含 plugins.allow / plugins.entries 警告）
log_info "执行 openclaw doctor --fix..."
openclaw doctor --fix >/dev/null 2>&1 || true
prune_openclaw_json
prune_openclaw_sessions

# 7) 卸载后验证：配置和目录都应不存在
if [ -d "$TARGET_EXTENSION_DIR" ] || [ -d "$TARGET_EXTENSION_DIR_ALT" ] || [ -d "$LEGACY_EXTENSION_DIR" ]; then
  log_error "卸载验证失败：插件目录仍存在"
  exit 1
fi
if command -v node >/dev/null 2>&1; then
  node - "$HOME/.openclaw/openclaw.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
if (!file || !fs.existsSync(file)) process.exit(0);
const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
const hasChannel =
  Boolean(cfg?.channels?.["wps"]) ||
  Boolean(cfg?.channels?.["wps-xiezuo"]) ||
  Boolean(cfg?.channels?.["openclaw-wps-xiezuo"]);
const hasPluginEntry =
  Boolean(cfg?.plugins?.entries?.["wps"]) ||
  Boolean(cfg?.plugins?.entries?.["wps-xiezuo"]) ||
  Boolean(cfg?.plugins?.entries?.["openclaw-wps-xiezuo"]);
const hasPluginInstall =
  Boolean(cfg?.plugins?.installs?.["wps"]) ||
  Boolean(cfg?.plugins?.installs?.["wps-xiezuo"]) ||
  Boolean(cfg?.plugins?.installs?.["openclaw-wps-xiezuo"]);
const hasPluginAllow = Array.isArray(cfg?.plugins?.allow)
  && cfg.plugins.allow.some((x) => ["wps", "wps-xiezuo", "openclaw-wps-xiezuo"].includes(String(x)));
const hasBinding = Array.isArray(cfg?.bindings)
  && cfg.bindings.some((b) => b && b.match && b.match.channel === "wps-xiezuo");
if (hasChannel || hasPluginEntry || hasPluginInstall || hasPluginAllow || hasBinding) {
  process.exit(2);
}
NODE
  if [ $? -ne 0 ]; then
    log_error "卸载验证失败：openclaw.json 仍有 wps/wps-xiezuo 残留项"
    exit 1
  fi
fi

log_info "✅ openclaw-wps-xiezuo 卸载成功"
