# LLM Pulse v2.0.0

LLM Pulse v2.0.0 is a focused update to the native macOS monitor for local Codex Desktop tasks, with a unified product identity, clearer task observation, and a weekly-only usage experience.

## 中文

### 本次更新

- 当前产品范围明确收口为本机 Codex Desktop 根任务，移除未发布的数据源入口与相关资产。
- 菜单栏继续显示活跃任务和最近任务两行计数；等待用户操作显示橙色，失败显示红色。
- 右侧边栏清晰区分正在运行、等待授权、等待回答与最近任务，并保留项目筛选、分组折叠和任务详情。
- 每个根任务显示项目、持续时间、最后状态、累计 token 和活跃 Agent 总数；子 Agent 聚合显示，不单独成行。
- 用量卡与额度通知现在只展示 Codex weekly 窗口，包括剩余百分比、数据新鲜度，以及按 Mac 当前系统时区格式化的准确重置日期和时间。
- 5 小时窗口仅保留在底层 parser 和迁移兼容结构中，不进入界面、菜单栏、通知或稍后提醒。
- 点击任务通过 `codex://threads/<thread-id>` 打开；只有成功定位具体任务后才自动标记已查看，失败时保留未查看状态并给出提示。
- 最近任务统一保留 24 小时、最多 20 条；未查看的成功任务优先保留，批量确认可在六秒内撤销。
- 通知支持任务操作、稍后 15 分钟或 1 小时提醒、完成摘要、项目静音和 weekly 阈值去重。
- 完善多显示器触边、全屏开关、自动收起、Reduce Motion、键盘焦点、VoiceOver 和中英文即时切换。
- App、Xcode project、scheme、module、Bundle ID、Application Support、Codex plugin 与仓库技术身份统一为 LLM Pulse / `LLMPulse` / `llm-pulse`。
- 升级兼容层安全迁移偏好、未查看回执、项目静音和 plugin journal；遇到双 App、冲突数据根、符号链接或不安全权限时停止并明确报错，不覆盖不确定数据。

### 升级与安装

1. 需要 macOS 14 或更高版本，同时支持 Apple Silicon 与 Intel Mac。
2. v1.1–v1.3 用户请先更新并启动 v1.4，再次选择“检查更新…”安装 v2；v1.4 用户可直接检查更新。
3. 手动安装时，先退出已安装版本并移除旧 wrapper，再将 `LLM Pulse.app` 拖入 `Applications`；不要保留两个副本。
4. v2 使用新的 macOS 应用身份，系统可能重新请求通知权限；升级后请在设置中检查“登录时启动”。
5. 可选 Codex 插件请使用当前身份安装：

   ```bash
   codex plugin marketplace add zuuzii-org/llm-pulse
   codex plugin add llm-pulse@llm-pulse
   ```

### 数据与隐私边界

- LLM Pulse 只读取本机 Codex 任务与用量证据，不写入 Codex 数据库、rollout、任务记录或 App Server state。
- 应用不提取、保存或上传 prompt、tool input、tool output 或 transcript 正文。
- 可选 Codex plugin journal 只保存 `session_id`、`turn_id`、事件名和时间戳。
- 已查看回执、偏好、项目静音和 weekly 通知去重数据只保存在 LLM Pulse 自有本机目录。
- 正常监控不访问互联网；可选更新检查只读取公开 GitHub Release feed，不附加任务数据或系统画像。

---

## English

### What changed

- Focused the current product scope on local root tasks created by Codex Desktop and removed unpublished data-source entry points and assets.
- Kept the two-line menu bar count for active and recent tasks, with orange for user attention and red for failures.
- Clarified running, approval-waiting, answer-waiting, and recent groups in the right-edge sidebar while preserving project filters, disclosures, and task details.
- Added project, duration, latest state, cumulative tokens, and active agent totals to each root task. Descendant agents are aggregated instead of shown as separate rows.
- Limited the usage card and quota notifications to the Codex weekly window, including remaining percentage, freshness, and an exact reset date and time in the Mac’s current system time zone.
- Retained 5-hour parsing and migration compatibility internally without exposing that window in the interface, menu bar, notifications, or snoozes.
- Opened tasks through `codex://threads/<thread-id>` and marked them viewed only after a successful exact navigation. Failures keep the unread state and show an error.
- Retained recent tasks for 24 hours, up to 20 items, with priority for unviewed successful tasks and a six-second undo for batch acknowledgement.
- Added notification actions, 15-minute and 1-hour snoozes, quiet completion summaries, project muting, and weekly-threshold deduplication.
- Improved edge triggering across displays, the full-screen setting, automatic dismissal, Reduce Motion, keyboard focus, VoiceOver, and live English/Simplified Chinese switching.
- Unified the app, Xcode project, scheme, module, Bundle ID, Application Support folder, Codex plugin, and repository under the LLM Pulse / `LLMPulse` / `llm-pulse` identity.
- Added fail-closed migration for preferences, viewed receipts, project mutes, and the plugin journal. Duplicate apps, conflicting data roots, symbolic links, and unsafe permissions are reported without overwriting uncertain data.

### Upgrade and install

1. Requires macOS 14 or later and supports Apple Silicon and Intel Macs.
2. Users on v1.1–v1.3 must install and launch v1.4 first, then choose **Check for Updates** again to install v2. Users already on v1.4 can check directly.
3. For a manual installation, quit the installed version and remove its previous wrapper before dragging `LLM Pulse.app` into `Applications`; do not keep both copies.
4. v2 uses a new macOS application identity, so macOS may request notification permission again. Check Launch at Login in LLM Pulse Settings after upgrading.
5. Install the optional Codex plugin under the current identity:

   ```bash
   codex plugin marketplace add zuuzii-org/llm-pulse
   codex plugin add llm-pulse@llm-pulse
   ```

### Data and privacy boundaries

- LLM Pulse reads local Codex task and usage evidence without writing Codex databases, rollouts, task records, or App Server state.
- It does not extract, retain, or upload prompts, tool input, tool output, or transcript bodies.
- The optional Codex plugin journal stores only `session_id`, `turn_id`, the event name, and a timestamp.
- Viewed receipts, preferences, project mutes, and weekly-notification deduplication data remain in LLM Pulse’s local application directory.
- Normal monitoring does not access the internet. Optional update checks read only the public GitHub Release feed and attach no task data or generated system profile.

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI.
