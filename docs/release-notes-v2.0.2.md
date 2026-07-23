# LLM Pulse v2.0.2

## 中文

### 本次更新

- 修复新版 Codex Desktop 中正在运行和等待操作的任务可能从右侧栏消失、计数错误显示为 0 的问题。
- 兼容 Codex Desktop 当前使用的 `codex_work_desktop` 任务来源标识，同时继续支持旧版 `Codex Desktop` 标识。
- 保持严格的桌面任务范围：不会把 VS Code、自动化任务或子 Agent 误计为 Codex Desktop 任务。
- 保持任务跳转、本机只读数据边界和每周额度显示不变。

### 安装

需要 macOS 14 或更高版本，同时支持 Apple Silicon 和 Intel Mac。退出已安装版本后，将 `LLM Pulse.app` 拖入 `Applications`。请不要同时保留旧 wrapper 与当前 App。

## English

### What changed

- Fixed an issue where running or action-required tasks could disappear from the sidebar and the active count could incorrectly show zero after recent Codex Desktop updates.
- Added support for the current `codex_work_desktop` task origin while retaining compatibility with the legacy `Codex Desktop` origin.
- Preserved strict desktop-only filtering so VS Code, automation, and sub-agent tasks are not counted as Codex Desktop tasks.
- Kept direct task navigation, local read-only data boundaries, and weekly usage display unchanged.

### Install

Requires macOS 14 or later and supports Apple Silicon and Intel Macs. Quit the installed version, then drag `LLM Pulse.app` into `Applications`. Do not keep a legacy wrapper and the current app at the same time.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI.
