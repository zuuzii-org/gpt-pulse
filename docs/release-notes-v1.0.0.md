# GPT Pulse v1.0.0

GPT Pulse by **Zuuzii** 的首个正式版本。它把 Codex Desktop 的运行任务、最近完成、活跃 Agent 与本地用量整合到一个克制的原生 macOS 菜单栏侧边栏中。

## 中文

### 亮点

- 全新通用 AI 菜单栏图标，使用 macOS Template Image 适配浅色、深色与高亮状态；双行计数保持紧凑，上方为正在运行、下方为最近完成。
- 左键点击菜单栏后提供 5 秒移入保护；鼠标进入侧栏后持续显示，离开后按 0.3 秒防抖关闭；右侧触边仍使用独立的即时悬停逻辑。
- 重新设计 400px 全高右栏，只保留“正在运行”和“最近完成”两组，并优先显示项目名称与 session 名称。
- 每个 session 显示累计 token，可展开查看输入、缓存命中、输出与推理明细。
- 每个任务显示主 Agent 与全部层级子 Agent 的活跃总数；等待授权和等待回答仍计入，数据不可靠时显示未知或可能过期，不把 stale `open` 关系误算为活跃。
- 5h 与 weekly 额度优先读取 Codex Desktop bundled App Server 的官方整组数据，显示剩余百分比、重置时间和数据新鲜度；rollout JSONL 仅作原子整组兜底，不跨任务拼接窗口。
- 原生通知提供“仅需我处理 / 重要状态 / 全部”三个档位；支持稍后提醒、完成摘要、额度阈值提醒，以及按 Git 项目临时静音。
- 最近完成保留 24 小时、最多 20 条；支持批量标记已查看并在 6 秒内撤销。
- 支持点击任务通过 `codex://threads/<thread-id>` 打开 Codex Desktop、开机启动、多显示器与全屏应用触边控制。

### 数据与隐私

- GPT Pulse 仅以只读方式访问 Codex state SQLite，不写入这些数据库、rollout 或任务记录；SQLite 始终以 read-only + `query_only` 打开。
- 与 Codex Desktop bundled App Server 的交互仅发送 `account/rateLimits/read` 查询，不发送创建、更新、归档或其他任务变更 RPC，也不修改 App Server state。
- rollout JSONL 只提取状态、时间、Agent 生命周期、token 汇总与数值额度，不提取、保存或上传 prompt、tool input、tool output 或 transcript 内容。
- hooks 仅写入最小 lifecycle 事件；已查看回执、通知偏好、额度提醒去重键和项目静音标识只保存在本机。
- 不需要 OpenAI API Key，也不上传任务数据。

### 兼容性

- macOS 14 或更高版本。
- Universal App：Apple Silicon (`arm64`) 与 Intel (`x86_64`)。
- 当前版本仅支持 Codex Desktop。通用 AI 图标不代表已经接入 Claude Code、DeepSeek、GLM、Codex CLI、IDE、automation 或 cloud task。

### 安装

1. 下载 `GPT-Pulse-1.0.0.dmg` 和 `GPT-Pulse-1.0.0.dmg.sha256`。
2. 在同一目录执行 `shasum -a 256 -c GPT-Pulse-1.0.0.dmg.sha256`。
3. 打开 DMG，将 `GPT Pulse.app` 拖入 `Applications`。
4. 可选：按 [README](https://github.com/zuuzii-org/gpt-pulse/tree/v1.0.0#安装-codex-插件) 安装配套 hooks，以提高运行中和等待授权状态的时效性。不安装插件也可使用应用。

### 已知限制

- 5h 与 weekly 只提供已用百分比和重置时间，没有可可靠换算的绝对 token 配额；界面显示剩余百分比，不是剩余 token 个数。
- Agent 数量依赖 Codex 本地父子关系与 rollout 生命周期。私有格式漂移、文件尚未落盘或暂时不可读时，会显示未知或保留标记为可能过期的可靠快照。
- Codex hooks 没有独立的“授权已批准”事件；相应工具产生 `PostToolUse` 前，任务可能短暂继续显示等待授权。
- `codex://threads/<thread-id>` 已在当前 Codex Desktop 构建中验证，但尚不是公开稳定契约。
- 直接在 Codex Desktop 内打开任务无法被稳定感知；请从 GPT Pulse 打开或手动标记已查看。

GPT Pulse 以 [MIT License](https://github.com/zuuzii-org/gpt-pulse/blob/v1.0.0/LICENSE) 开源。

---

## English

GPT Pulse by **Zuuzii** is a native macOS menu bar companion that brings Codex Desktop tasks, recently completed work, active agents, and local usage into one focused sidebar.

### Highlights

- A new universal AI menu bar mark uses macOS Template Image rendering across light, dark, and highlighted states. Compact two-line counts keep Running above Recently Completed.
- A left click gives you five seconds to move into the sidebar. Once hovered, the panel stays open and closes after a 0.3-second leave debounce. Right-edge hover keeps its independent immediate behavior.
- A redesigned 400px full-height sidebar focuses on Running and Recently Completed, with project names and session names clearly separated.
- Per-session cumulative token usage expands into input, cache-hit, output, and reasoning details.
- Each task shows the active total for the main agent and all descendant agents. Approval and user-input waits still count; unreliable data is shown as unknown or stale instead of treating stale `open` relations as active.
- 5h and weekly limits prefer the official grouped values from the Codex Desktop bundled App Server, including remaining percentage, reset time, and freshness. Rollout JSONL is an atomic grouped fallback and never mixes windows across tasks.
- Native notifications support Only Needs Me, Important States, and Everything modes, plus snooze actions, quiet completion summaries, quota thresholds, and temporary per-project mute.
- Recently Completed keeps up to 20 tasks for 24 hours. Batch acknowledgement includes a six-second undo.
- Open tasks through `codex://threads/<thread-id>`, launch at login, use multiple displays, and control edge triggering in full-screen apps.

### Data and privacy

- GPT Pulse opens Codex state SQLite read-only and never writes those databases, rollouts, or task records. SQLite is always opened with read-only mode and `query_only` enabled.
- Its only interaction with the Codex Desktop bundled App Server is the `account/rateLimits/read` query. It sends no create, update, archive, or other task-mutation RPC and does not modify App Server state.
- Rollout JSONL extraction is limited to status, timestamps, agent lifecycle, token summaries, and numeric rate-limit values. Prompts, tool input, tool output, and transcript content are not extracted, retained, or uploaded.
- Hooks write only minimized lifecycle events. Viewed receipts, notification preferences, quota deduplication keys, and hashed project-mute identifiers stay on the Mac.
- No OpenAI API key is required, and task data is never uploaded.

### Compatibility

- macOS 14 or later.
- Universal App for Apple Silicon (`arm64`) and Intel (`x86_64`).
- This release supports Codex Desktop only. The universal AI mark does not imply current support for Claude Code, DeepSeek, GLM, Codex CLI, IDE integrations, automations, or cloud tasks.

### Installation

1. Download `GPT-Pulse-1.0.0.dmg` and `GPT-Pulse-1.0.0.dmg.sha256`.
2. In the same directory, run `shasum -a 256 -c GPT-Pulse-1.0.0.dmg.sha256`.
3. Open the DMG and drag `GPT Pulse.app` to `Applications`.
4. Optional: follow the [README](https://github.com/zuuzii-org/gpt-pulse/tree/v1.0.0#安装-codex-插件) to install the companion hooks for more timely running and approval-waiting updates. The app remains usable without the plugin.

### Known limitations

- The 5h and weekly limits expose used percentages and reset times, not a reliable absolute token quota. GPT Pulse displays remaining percentages rather than token balances.
- Agent totals depend on local Codex lineage and rollout lifecycle evidence. Private-format changes, files not yet flushed, or temporary read failures can produce an unknown or stale-marked value.
- Codex hooks expose no dedicated approval-resolved event. A task can briefly remain Waiting for Approval until the corresponding tool emits `PostToolUse`.
- `codex://threads/<thread-id>` has been verified with the current Codex Desktop build but is not a documented stable contract.
- Opening a task directly inside Codex Desktop cannot be detected reliably. Open it from GPT Pulse or acknowledge it manually.

GPT Pulse is open source under the [MIT License](https://github.com/zuuzii-org/gpt-pulse/blob/v1.0.0/LICENSE).
