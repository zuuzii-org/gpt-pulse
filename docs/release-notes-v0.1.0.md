# GPT Pulse v0.1.0

GPT Pulse by **Zuuzii** 的首个公开版本。它是面向 Codex Desktop 的原生 macOS 任务侧边栏，用来集中查看正在运行的 session、最近结束的 session 与本地用量数据。

## 中文

### 亮点

- 菜单栏使用固定窄宽的双行计数，分别显示“正在运行”与“最近完成”数量。
- 鼠标在当前屏幕右侧中间区域停留约 200ms，弹出 400px 全高侧边栏。
- 右栏只保留“正在运行”和“最近完成”两组：等待授权与等待回答作为运行中状态，失败与中断归入最近完成。
- 最近完成保留 24 小时，最多显示 20 条；未查看的成功 session 优先进入保留集合。
- 每项优先显示项目名与 session 名；还可查看该 session 的累计 token，并展开输入、缓存命中、输出与推理明细。
- 顶部用量区显示 5h 与 weekly 额度的剩余百分比、重置时间和数据新鲜度。
- 点击 session 可定位到 Codex Desktop；成功打开最近完成的 session 后会自动标记已读，也支持手动标记。
- 支持 macOS 原生通知、开机启动、多显示器，并默认在全屏应用中禁用触边。

### 数据与隐私

- V1 只读取 Codex Desktop 根 session，不修改 Codex 的 SQLite、rollout 或任务记录。
- 数据层优先探测可用的 Codex 本地协议能力；不可用时使用可选插件 hooks、read-only SQLite 和 rollout JSONL 作为兼容降级路径。
- rollout JSONL 按行解析事件，但只提取、保留和展示状态、时间、token 汇总与 rate-limit 数值；不会提取、持久化或上传 prompt、tool input、tool output 或 transcript 内容。
- hooks 只保存最小化的 lifecycle 事件，不记录 prompt、tool input、tool output、transcript 路径或项目目录。
- 已查看回执只存在 GPT Pulse 自有数据库中。应用不需要 OpenAI API Key，也不上传任务数据。

### 兼容性

- macOS 14 或更高版本。
- Universal App：Apple Silicon (`arm64`) 和 Intel (`x86_64`)。
- 仅支持 Codex Desktop；不包含 Codex CLI、IDE、automation、cloud task 或 subagent。

### 安装

1. 下载 `GPT-Pulse-0.1.0.dmg` 和 `GPT-Pulse-0.1.0.dmg.sha256`。
2. 在同一目录执行 `shasum -a 256 -c GPT-Pulse-0.1.0.dmg.sha256`。
3. 打开 DMG，将 `GPT Pulse.app` 拖入 `Applications`。
4. 可选：按 [README](https://github.com/zuuzii-org/gpt-pulse/tree/v0.1.0#安装-codex-插件) 安装配套 hooks，以提高运行中和等待授权状态的时效性。不安装插件也可使用应用。

### 已知限制

- Codex hooks 目前没有独立的“授权已批准”事件。批准后要到相应工具产生 `PostToolUse` 才能确认恢复，因此工具执行期间可能短暂继续显示“等待授权”。
- `codex://threads/<thread-id>` 已在当前 Codex Desktop 版本中验证，但它尚不是公开稳定契约。如跳转失败，GPT Pulse 会保留未读状态并显示错误。
- 直接在 Codex Desktop 内打开 session 时，V1 无法稳定判断其已读；请从 GPT Pulse 打开或手动标记。
- 当 Codex Desktop 的内存态本地协议不可订阅时，状态由 hooks、SQLite 和 JSONL 合并推断，可能与 Codex UI 存在短暂延迟。
- 5h 与 weekly 数据只提供已用百分比和重置时间，无法稳定换算绝对 token 额度；界面显示剩余百分比，不是剩余 token 个数。

GPT Pulse 以 [MIT License](https://github.com/zuuzii-org/gpt-pulse/blob/v0.1.0/LICENSE) 开源。

---

## English

GPT Pulse by **Zuuzii** is a native macOS task sidebar for Codex Desktop. Its first public release brings running sessions, recently finished sessions, and local usage data into one focused view.

### Highlights

- A fixed, narrow menu bar item uses two lines for Running and Recently Completed counts.
- A 400px full-height sidebar appears after hovering for about 200ms over the middle region of the current display's right edge.
- The sidebar has only two groups, Running and Recently Completed. Waiting for approval and waiting for an answer are running states; failed and interrupted sessions appear under Recently Completed.
- Recently Completed retains up to 20 sessions from the last 24 hours, prioritizing successful unread sessions when selecting the retained set.
- Each item prioritizes the project name and session name. It also shows cumulative tokens for that session, with expandable input, cache-hit, output, and reasoning details.
- The usage area shows the remaining percentage, reset time, and data freshness for the 5h and weekly limits.
- Open a session directly in Codex Desktop. Successfully opening a recently completed session from GPT Pulse marks it as read; manual acknowledgement remains available.
- Native notifications, launch at login, multi-display support, and edge triggering disabled in full-screen apps by default.

### Data and privacy

- V1 reads Codex Desktop root sessions only. It never modifies Codex SQLite databases, rollouts, or task records.
- The data layer probes for an available Codex local protocol first, then uses optional plugin hooks, read-only SQLite, and rollout JSONL as compatibility fallbacks.
- Rollout JSONL events are parsed line by line, but GPT Pulse only extracts, retains, and displays status, timestamps, token summaries, and numeric rate-limit values. It does not extract, persist, or upload prompts, tool input, tool output, or transcript content.
- Hooks retain only minimized lifecycle events. They do not record prompts, tool input, tool output, transcript paths, or project directories.
- Viewed receipts live only in GPT Pulse's own database. No OpenAI API key is required, and task data is not uploaded.

### Compatibility

- macOS 14 or later.
- Universal App for Apple Silicon (`arm64`) and Intel (`x86_64`).
- Codex Desktop only. Codex CLI, IDE integrations, automations, cloud tasks, and subagents are outside the V1 scope.

### Installation

1. Download `GPT-Pulse-0.1.0.dmg` and `GPT-Pulse-0.1.0.dmg.sha256`.
2. In the same directory, run `shasum -a 256 -c GPT-Pulse-0.1.0.dmg.sha256`.
3. Open the DMG and drag `GPT Pulse.app` to `Applications`.
4. Optional: follow the [README](https://github.com/zuuzii-org/gpt-pulse/tree/v0.1.0#安装-codex-插件) to install the companion hooks for more timely running and approval-waiting state updates. The app remains usable without the plugin.

### Known limitations

- Codex hooks currently expose no dedicated approval-resolved event. After approval, GPT Pulse can only confirm recovery when the corresponding tool emits `PostToolUse`, so the task may briefly remain in Waiting for Approval while the tool runs.
- `codex://threads/<thread-id>` has been verified with the current Codex Desktop build but is not yet a documented stable contract. If navigation fails, GPT Pulse preserves the unread state and reports the error.
- V1 cannot reliably detect when a session is opened directly inside Codex Desktop. Open it from GPT Pulse or acknowledge it manually to clear the unread state.
- When Codex Desktop's in-memory local protocol cannot be subscribed to, state is inferred by merging hooks, SQLite, and JSONL evidence and can briefly lag behind the Codex UI.
- The 5h and weekly data exposes used percentages and reset times, but not a reliable absolute token quota. GPT Pulse displays the remaining percentage, not a remaining token count.

GPT Pulse is open source under the [MIT License](https://github.com/zuuzii-org/gpt-pulse/blob/v0.1.0/LICENSE).
