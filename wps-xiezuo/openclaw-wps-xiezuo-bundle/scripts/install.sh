#!/usr/bin/env bash
set -euo pipefail

# 关键路径：bundle 根目录 / 配置文件 / 插件包目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$BUNDLE_ROOT/config/plugin.env"
PLUGIN_DIR="$BUNDLE_ROOT/plugin"

# 颜色日志输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup_stale_config() {
  # 尽力删除配置，最终以 verify_cleanup_finished 的结果为准
  local keys=(
    "channels.wps"
    "channels.wps-xiezuo"
    "channels.openclaw-wps-xiezuo"
    "plugins.entries.wps"
    "plugins.entries.wps-xiezuo"
    "plugins.entries.openclaw-wps-xiezuo"
    "plugins.installs.wps"
    "plugins.installs.wps-xiezuo"
    "plugins.installs.openclaw-wps-xiezuo"
  )
  local key
  for key in "${keys[@]}"; do
    openclaw config delete "$key" >/dev/null 2>&1 || true
  done
}

has_config_residue() {
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi
  node - "$HOME/.openclaw/openclaw.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
if (!file || !fs.existsSync(file)) process.exit(1);
try {
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
  process.exit((hasChannel || hasPluginEntry || hasPluginInstall || hasPluginAllow || hasBinding) ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}

is_installed() {
  if [ -d "$TARGET_EXTENSION_DIR" ] || [ -d "$TARGET_EXTENSION_DIR_ALT" ] || [ -d "$LEGACY_EXTENSION_DIR" ]; then
    return 0
  fi
  if [ -d "$EXTENSIONS_ROOT" ] && find "$EXTENSIONS_ROOT" -maxdepth 1 -type d -name ".openclaw-install-stage-*" | grep -q .; then
    return 0
  fi
  if has_config_residue; then
    return 0
  fi
  return 1
}

verify_cleanup_finished() {
  if [ -d "$TARGET_EXTENSION_DIR" ] || [ -d "$TARGET_EXTENSION_DIR_ALT" ] || [ -d "$LEGACY_EXTENSION_DIR" ]; then
    log_error "清理失败：插件目录仍存在"
    return 1
  fi
  if [ -d "$EXTENSIONS_ROOT" ] && find "$EXTENSIONS_ROOT" -maxdepth 1 -type d -name ".openclaw-install-stage-*" | grep -q .; then
    log_error "清理失败：存在 .openclaw-install-stage-* 临时目录"
    return 1
  fi
  if has_config_residue; then
    log_error "清理失败：openclaw.json 中仍存在 wps/wps-xiezuo 残留配置"
    return 1
  fi
  return 0
}

cleanup_existing_installation() {
  log_info "执行安装前清理..."
  cleanup_stale_config
  openclaw doctor --fix >/dev/null 2>&1 || true
  prune_openclaw_json
  prune_openclaw_sessions

  if [ -d "$TARGET_EXTENSION_DIR" ]; then
    rm -rf "$TARGET_EXTENSION_DIR"
  fi
  if [ -d "$TARGET_EXTENSION_DIR_ALT" ]; then
    rm -rf "$TARGET_EXTENSION_DIR_ALT"
  fi
  if [ -d "$LEGACY_EXTENSION_DIR" ]; then
    rm -rf "$LEGACY_EXTENSION_DIR"
  fi
  if [ -d "$TARGET_HOOK_DIR_PRIMARY" ]; then
    rm -rf "$TARGET_HOOK_DIR_PRIMARY"
  fi
  if [ -d "$TARGET_HOOK_DIR_ALT" ]; then
    rm -rf "$TARGET_HOOK_DIR_ALT"
  fi
  if [ -d "$EXTENSIONS_ROOT" ]; then
    find "$EXTENSIONS_ROOT" -maxdepth 1 -type d -name ".openclaw-install-stage-*" -exec rm -rf {} +
  fi

  verify_cleanup_finished
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
  // 安装前清理旧/脏配置，交给本次安装重新写入
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
  process.exit(0);
}
NODE
}

# 1) 环境检查：必须已安装 openclaw CLI
log_info "检查 OpenClaw CLI..."
if ! command -v openclaw >/dev/null 2>&1; then
  log_error "未找到 openclaw 命令，请先安装 OpenClaw"
  exit 1
fi
log_info "OpenClaw 版本: $(openclaw --version)"

# 1.1) 官方插件管理命令检查：应使用 openclaw plugins ...
if ! openclaw plugins --help >/dev/null 2>&1; then
  log_error "当前环境未启用 openclaw plugins 命令。"
  log_error "请先按 OpenClaw 官方配置方式调整 plugins.allow 后再重试。"
  log_error "可先执行: openclaw config get plugins.allow"
  exit 1
fi

# 2) 配置加载：优先从 plugin.env 读取，缺失则交互式输入
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

OPENCLAW_CHANNEL_ID="wps-xiezuo"
OPENCLAW_PLUGIN_ID="openclaw-wps-xiezuo"
OPENCLAW_PLUGIN_ID_ALT="wps-xiezuo"
EXTENSIONS_ROOT="$HOME/.openclaw/extensions"
TARGET_EXTENSION_DIR="$EXTENSIONS_ROOT/$OPENCLAW_PLUGIN_ID"
TARGET_EXTENSION_DIR_ALT="$EXTENSIONS_ROOT/$OPENCLAW_PLUGIN_ID_ALT"
LEGACY_EXTENSION_DIR="$EXTENSIONS_ROOT/wps"
HOOKS_ROOT="$HOME/.openclaw/hooks"
TARGET_HOOK_DIR_PRIMARY="$HOOKS_ROOT/openclaw-wps-xiezuo"
TARGET_HOOK_DIR_ALT="$HOOKS_ROOT/wps-xiezuo"

# 3) 运行参数：支持通过 plugin.env 完整控制
: "${ACCOUNT_ID:=default}"
: "${AGENT_ID:=main}"
: "${DM_POLICY:=pairing}"
: "${GROUP_POLICY:=open}"
: "${BASE_URL:=https://openapi.wps.cn}"
: "${SESSION_DM_SCOPE:=per-account-channel-peer}"
: "${APP_SECRET:=}"
: "${SDK_ENABLED:=1}"
: "${SDK_LOG_LEVEL:=info}"
: "${SDK_CONNECT_TIMEOUT_MS:=120000}"
: "${SDK_ENDPOINT:=}"
: "${FORCE_REINSTALL:=0}"

if [[ ! "$DM_POLICY" =~ ^(disabled|open|pairing|allowlist)$ ]]; then
  log_error "DM_POLICY 仅支持: disabled/open/pairing/allowlist"
  exit 1
fi
if [[ ! "$SESSION_DM_SCOPE" =~ ^(main|per-peer|per-channel-peer|per-account-channel-peer)$ ]]; then
  log_error "SESSION_DM_SCOPE 仅支持: main/per-peer/per-channel-peer/per-account-channel-peer"
  exit 1
fi

# 3.1) 已安装检测：已安装时默认要求确认，避免误覆盖
if is_installed; then
  log_warn "检测到已有 wps-xiezuo 安装或残留配置"
  if [ "$FORCE_REINSTALL" = "1" ]; then
    log_warn "FORCE_REINSTALL=1，跳过交互确认并执行覆盖安装"
  else
    read -r -p "是否继续覆盖安装并清理旧版本？(y/N): " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      log_info "安装已取消"
      exit 0
    fi
  fi
fi

# 3.2) 凭据获取：已有则复用，缺失则交互式输入
if [ -z "${APP_ID:-}" ]; then
  echo ""
  read -r -p "请输入 WPS 开放平台 APP_ID: " APP_ID
  if [ -z "$APP_ID" ]; then
    log_error "APP_ID 不能为空"
    exit 1
  fi
fi

if [ -z "${APP_SECRET:-}" ] && [ "$DM_POLICY" != "disabled" ]; then
  read -r -s -p "请输入 WPS 开放平台 APP_SECRET: " APP_SECRET
  echo ""
  if [ -z "$APP_SECRET" ]; then
    log_error "APP_SECRET 不能为空"
    exit 1
  fi
fi

# 3.3) 将配置回写到 plugin.env，下次安装可自动复用
mkdir -p "$(dirname "$CONFIG_FILE")"
cat > "$CONFIG_FILE" <<ENVEOF
# openclaw-wps-xiezuo 配置文件（由 install.sh 自动生成）
APP_ID=$APP_ID
APP_SECRET=$APP_SECRET
ACCOUNT_ID=$ACCOUNT_ID
AGENT_ID=$AGENT_ID
DM_POLICY=$DM_POLICY
GROUP_POLICY=$GROUP_POLICY
BASE_URL=$BASE_URL
SESSION_DM_SCOPE=$SESSION_DM_SCOPE
SDK_ENABLED=$SDK_ENABLED
SDK_LOG_LEVEL=$SDK_LOG_LEVEL
SDK_CONNECT_TIMEOUT_MS=$SDK_CONNECT_TIMEOUT_MS
SDK_ENDPOINT=$SDK_ENDPOINT
# 当 DM_POLICY=allowlist 时生效，逗号分隔 userId 列表；空表示全部拒绝
ALLOW_FROM=${ALLOW_FROM:-}
# 高级：完整覆盖账号配置（JSON object），例如：
# WPS_ACCOUNTS_JSON={"default":{"enabled":true,"appId":"...","appSecret":"...","dmPolicy":"pairing"}}
WPS_ACCOUNTS_JSON=${WPS_ACCOUNTS_JSON:-}
# 高级：完整覆盖绑定配置（JSON array），例如：
# WPS_BINDINGS_JSON=[{"agentId":"main","match":{"channel":"wps-xiezuo","accountId":"default"}}]
WPS_BINDINGS_JSON=${WPS_BINDINGS_JSON:-}
# 高级：可选写入 agents（JSON object），例如：
# WPS_AGENTS_JSON={"list":[{"id":"main"}]}
WPS_AGENTS_JSON=${WPS_AGENTS_JSON:-}
# 非交互模式强制覆盖安装：1=是，0=否
FORCE_REINSTALL=$FORCE_REINSTALL
ENVEOF
log_info "凭据已保存到 $CONFIG_FILE"

# 4) 安装前强清理：若存在旧安装/残留，必须先清理干净
cleanup_existing_installation || {
  log_error "安装前清理失败，请先手动执行 bundle 的 uninstall.sh 后重试"
  exit 1
}

# 5) 安装插件包：从 plugin 目录找到 bundle 内 tgz
PLUGIN_TGZ="$(find "$PLUGIN_DIR" -name "openclaw-wps-xiezuo-*.tgz" | head -n 1)"
if [ -z "$PLUGIN_TGZ" ]; then
  log_error "未找到插件包 (.tgz 文件) 在 $PLUGIN_DIR"
  exit 1
fi

log_info "安装插件包: $(basename "$PLUGIN_TGZ")"

openclaw plugins install "$PLUGIN_TGZ"

# 5.2) 安装后修复
openclaw doctor --fix >/dev/null 2>&1 || true

detect_installed_plugin_id() {
  local list_output
  list_output="$(openclaw plugins list 2>/dev/null || true)"

  if echo "$list_output" | grep -Eq '(^|[^a-zA-Z0-9_-])wps-xiezuo([^a-zA-Z0-9_-]|$)'; then
    echo "wps-xiezuo"
    return 0
  fi
  if echo "$list_output" | grep -Eq '(^|[^a-zA-Z0-9_-])openclaw-wps-xiezuo([^a-zA-Z0-9_-]|$)'; then
    echo "openclaw-wps-xiezuo"
    return 0
  fi

  if command -v node >/dev/null 2>&1 && [ -f "$HOME/.openclaw/openclaw.json" ]; then
    node - "$HOME/.openclaw/openclaw.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
try {
  const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
  const installs = cfg?.plugins?.installs ?? {};
  if (installs["wps-xiezuo"]) {
    process.stdout.write("wps-xiezuo");
    process.exit(0);
  }
  if (installs["openclaw-wps-xiezuo"]) {
    process.stdout.write("openclaw-wps-xiezuo");
    process.exit(0);
  }
} catch {}
process.exit(1);
NODE
    return $?
  fi

  return 1
}

ACTIVE_PLUGIN_ID="$(detect_installed_plugin_id || true)"
if [ -z "$ACTIVE_PLUGIN_ID" ]; then
  log_error "安装后未识别到插件 ID（wps-xiezuo/openclaw-wps-xiezuo），终止写入 channels 配置以避免污染 openclaw.json。"
  log_error "请先执行: openclaw plugins list"
  exit 1
fi
log_info "检测到已安装插件 ID: $ACTIVE_PLUGIN_ID"

# 6) 直接写 openclaw.json（绕过 openclaw config set 的 channel 校验）
#    原因：openclaw config set "channels.wps-xiezuo.*" 会报 "unknown channel id"，
#    因为 channel 只有在 gateway 加载插件后才被注册，而安装阶段 gateway 未运行。
log_info "写入插件配置（直接写 JSON）..."
ALLOW_FROM_CSV="${ALLOW_FROM:-}"
WPS_ACCOUNTS_JSON="${WPS_ACCOUNTS_JSON:-}"
WPS_BINDINGS_JSON="${WPS_BINDINGS_JSON:-}"
WPS_AGENTS_JSON="${WPS_AGENTS_JSON:-}"
node - "$HOME/.openclaw/openclaw.json" "$APP_ID" "$APP_SECRET" "$ACCOUNT_ID" "$AGENT_ID" "$DM_POLICY" "$GROUP_POLICY" "$BASE_URL" "$SESSION_DM_SCOPE" "$ALLOW_FROM_CSV" "$WPS_ACCOUNTS_JSON" "$WPS_BINDINGS_JSON" "$WPS_AGENTS_JSON" "$ACTIVE_PLUGIN_ID" <<'INJECT'
const fs = require("fs");
const [, , file, appId, appSecret, accountId, agentId, dmPolicy, groupPolicy, baseUrl, sessionDmScope, allowFromCsv, accountsJson, bindingsJson, agentsJson, activePluginIdRaw] = process.argv;
if (!file) { console.error("openclaw.json path missing"); process.exit(1); }
let cfg = {};
if (fs.existsSync(file)) {
  cfg = JSON.parse(fs.readFileSync(file, "utf8"));
}

function parseJsonOrNull(raw, label) {
  if (!raw || !String(raw).trim()) return null;
  try {
    return JSON.parse(raw);
  } catch (err) {
    console.error(`invalid ${label} JSON: ${err}`);
    process.exit(2);
  }
}

const allowFrom = String(allowFromCsv || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const sdkEnabled = String(process.env.SDK_ENABLED ?? "1") !== "0";
const sdkLogLevel = String(process.env.SDK_LOG_LEVEL ?? "info") || "info";
const sdkEndpoint = String(process.env.SDK_ENDPOINT ?? "").trim();
const sdkConnectTimeoutRaw = Number.parseInt(String(process.env.SDK_CONNECT_TIMEOUT_MS ?? "120000"), 10);
const sdkConnectTimeoutMs = Number.isFinite(sdkConnectTimeoutRaw) ? sdkConnectTimeoutRaw : 120000;
const accountsOverride = parseJsonOrNull(accountsJson, "WPS_ACCOUNTS_JSON");
const bindingsOverride = parseJsonOrNull(bindingsJson, "WPS_BINDINGS_JSON");
const agentsOverride = parseJsonOrNull(agentsJson, "WPS_AGENTS_JSON");

const defaultAccount = {
  enabled: true,
  appId: appId,
  appSecret: appSecret,
  baseUrl: baseUrl || "https://openapi.wps.cn",
  sdk: {
    enabled: sdkEnabled,
    logLevel: sdkLogLevel,
    connectTimeoutMs: sdkConnectTimeoutMs,
    ...(sdkEndpoint ? { endpoint: sdkEndpoint } : {}),
  },
  dmPolicy: dmPolicy || "pairing",
  allowFrom: (dmPolicy === "open") ? ["*"] : allowFrom,
  groupPolicy: groupPolicy || "open",
  instantAck: { enabled: true, text: "内容处理中，请稍候..." }
};
if (dmPolicy === "disabled") {
  // disabled 模式无需 pairing/allowlist 列表
  defaultAccount.allowFrom = [];
}

const finalAccounts = (accountsOverride && typeof accountsOverride === "object" && !Array.isArray(accountsOverride))
  ? accountsOverride
  : { [accountId || "default"]: defaultAccount };

const finalBindings = Array.isArray(bindingsOverride)
  ? bindingsOverride
  : [{ agentId: agentId || "main", match: { channel: "wps-xiezuo", accountId: accountId || "default" } }];

if (!cfg.channels) cfg.channels = {};
cfg.channels["wps-xiezuo"] = {
  enabled: true,
  defaultAccountId: accountId || "default",
  accounts: finalAccounts
};

if (!cfg.session || typeof cfg.session !== "object") cfg.session = {};
cfg.session.dmScope = sessionDmScope || "per-account-channel-peer";

if (!cfg.plugins) cfg.plugins = {};
if (!cfg.plugins.entries) cfg.plugins.entries = {};
const knownPluginIds = ["wps-xiezuo", "openclaw-wps-xiezuo"];
const activePluginId = knownPluginIds.includes(String(activePluginIdRaw)) ? String(activePluginIdRaw) : "wps-xiezuo";
for (const id of knownPluginIds) delete cfg.plugins.entries[id];
cfg.plugins.entries[activePluginId] = { enabled: true };
if (!Array.isArray(cfg.plugins.allow)) cfg.plugins.allow = [];
cfg.plugins.allow = cfg.plugins.allow.filter((item) => !knownPluginIds.includes(String(item)));
cfg.plugins.allow.push(activePluginId);

if (!Array.isArray(cfg.bindings)) cfg.bindings = [];
cfg.bindings = cfg.bindings.filter((b) => !(b && b.match && b.match.channel === "wps-xiezuo"));
cfg.bindings.push(...finalBindings);

if (agentsOverride && typeof agentsOverride === "object" && !Array.isArray(agentsOverride)) {
  cfg.agents = agentsOverride;
}

fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n", "utf8");
console.log(`[OK] channels.wps-xiezuo/accounts + session.dmScope + plugins.allow(entries=${activePluginId}) + bindings 已写入`);
INJECT

if [ $? -ne 0 ]; then
  log_error "写入 openclaw.json 失败"
  exit 1
fi
if [ "$DM_POLICY" = "pairing" ]; then
  log_info "配置写入完成：dmPolicy=pairing（默认 allowFrom 为空，需审批配对后放行）"
  log_info "提示：请在 OpenClaw 中处理 pairing 请求后再进行私聊。"
else
  log_info "配置写入完成：dmPolicy=$DM_POLICY, groupPolicy=$GROUP_POLICY"
fi

# 7) 安装后验证：检查 JSON 中 channel 存在
node -e "const c=JSON.parse(require('fs').readFileSync('$HOME/.openclaw/openclaw.json','utf8')); if(!c.channels||!c.channels['wps-xiezuo']||!c.channels['wps-xiezuo'].enabled){process.exit(1)}"
if [ $? -ne 0 ]; then
  log_error "安装验证失败：channels.wps-xiezuo 未写入"
  exit 1
fi

# 7.1) 安装后验证：检查是否出现 duplicate plugin id
PLUGIN_LIST_OUTPUT="$(openclaw plugins list 2>&1 || true)"
if echo "$PLUGIN_LIST_OUTPUT" | grep -qi "duplicate plugin id detected"; then
  log_error "安装验证失败：检测到 duplicate plugin id，请先执行 uninstall.sh 强清理后重试"
  echo "$PLUGIN_LIST_OUTPUT" | sed -n '/duplicate plugin id/,+4p'
  exit 1
fi

log_info "✅ openclaw-wps-xiezuo 安装成功"
log_info "插件源码目录: $EXTENSIONS_ROOT/wps-xiezuo"
log_warn "安装脚本不会自动重启网关，请手动重启 OpenClaw gateway 以加载新插件。"
