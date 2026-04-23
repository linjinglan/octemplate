# openclaw-wps-xiezuo-bundle

金山 WPS AI 写作助手 OpenClaw 插件安装包。

## 目录结构

```
openclaw-wps-xiezuo-bundle/
├── README.md
├── plugin/
│   └── openclaw-wps-xiezuo-1.5.3.tgz
├── config/
│   ├── plugin.env.example
│   └── plugin.env
└── scripts/
    ├── install.sh
    └── uninstall.sh
```

## 快速开始

1. 编辑 `config/plugin.env`，至少填写 `APP_ID` 和 `APP_SECRET`
2. 按需设置 `ACCOUNT_ID`、`AGENT_ID`、`DM_POLICY`（默认 `pairing`）
3. 如需多账号/多 Agent 一次性写入，可使用 `WPS_ACCOUNTS_JSON` 与 `WPS_BINDINGS_JSON`
4. 执行 `bash scripts/install.sh`
5. 安装完成后，手动重启 OpenClaw gateway（脚本不会自动重启）
6. 如需卸载，执行 `bash scripts/uninstall.sh`

## 配置说明

- `config/plugin.env.example`：配置模板（保留完整注释）
- `config/plugin.env`：实际生效配置（默认由模板复制，保留同样注释）
- 关键字段：
  - `DM_POLICY`: `disabled/open/pairing/allowlist`
  - `SESSION_DM_SCOPE`: 写入 `session.dmScope`，用于多账号会话隔离
  - `WPS_ACCOUNTS_JSON` / `WPS_BINDINGS_JSON`: 高级多账号多 Agent 覆盖

## 目录与清理

- 安装后插件目录：`~/.openclaw/extensions/wps-xiezuo`
- 默认写入 channel：`channels.wps-xiezuo`
- 默认写入会话隔离：`session.dmScope`
- 卸载会同时清理：
  - `channels.wps-xiezuo` / 兼容历史残留 channel
  - `bindings` 中 `channel=wps-xiezuo` 的路由项
  - `~/.openclaw/extensions/wps-xiezuo` 与历史目录 `~/.openclaw/extensions/wps`
