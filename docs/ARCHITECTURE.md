# GPT Pulse V1 架构

## 目标

V1 面向单机、单用户的 Codex Desktop。核心约束是：实时状态尽可能准确，且绝不修改 Codex 持久化数据。

## 数据流

1. `AppServerCapabilityProbe` 首先检查 Codex managed control socket。只有现有 socket 可连接时才允许进入协议适配；GPT Pulse 不负责启动 daemon。
2. `PluginEventJournal` 读取插件 hooks 产生的最小化 lifecycle 事件，用于补充运行中与等待授权状态。
3. `CodexSQLiteTaskAdapter` 以 read-only 模式读取 thread 元数据与可选的 `tokens_used` 总量。
4. `RolloutTaskAdapter` 解析 rollout 的状态、累计 token 汇总与 rate-limit 快照，并以 `session_meta.originator == "Codex Desktop"` 做最终桌面来源校验。
5. `CodexAgentActivityObserver` 以 SQLite 父子图定位根任务的全部后代，再用各自 rollout 的生命周期重建活跃状态。
6. `ReceiptStore` 只在 GPT Pulse 自有数据库中保存完成 turn 的已查看回执。
7. `TaskRepository` 合并上述数据并生成 UI 所需的 `TaskSnapshot`。

## 状态归并

| 输入证据 | GPT Pulse 状态 |
| --- | --- |
| `PermissionRequest` | `waitingForApproval` |
| 未匹配的 `request_user_input` call/output | `waitingForAnswer` |
| `UserPromptSubmit`、`task_started`、`PostToolUse` | `running` |
| `task_complete` | `completed` |
| `error` 且没有后续恢复或完成 | `failed` |
| `turn_aborted` | `interrupted`，归入最近完成 |

新证据覆盖旧证据。插件事件必须先与已验证的 Codex Desktop thread ID 对齐，避免混入其他 Codex surface。

公开 hooks 暂无单独的 approval-resolved 事件。`PermissionRequest` 后只能等 `PostToolUse` 确认工具已完成，因此“批准后、工具结束前”仍可能短暂显示 `waitingForApproval`；未来 App Server 可连接时由协议状态消除此窗口。

插件 journal 只写 `session_id`、`turn_id`、`hook_event_name`、`timestamp` 四个字段。达到 8MB 时会在互斥锁内按 session 压缩为最近一次 start 与最近一次状态事件，避免截断时丢失仍在等待的任务。

## Agent 活跃观测

- 界面展示的是“活跃 Agent 总数”，包含非终态主 Agent 与其全部层级的非终态子 Agent；等待授权或回答仍占用一个活跃 Agent。
- `thread_spawn_edges` 只用于建立递归父子图。`closed` 可直接排除，`open` 只表示关系未被显式关闭，不能等同于正在运行。
- 子 Agent 状态取 rollout 中最后一个明确生命周期：`task_started` 激活，`task_complete`、`task_failed`、`turn_failed`、`turn_aborted` 或 `shutdown_complete` 终止，后续新的 `task_started` 可再次激活。通用 `error` 先等待 3 秒静默，期间没有新活动才视为停止；后续活动可恢复运行。
- 观测器只读取相关文件尾部并按文件大小、修改时间缓存；先读 64KB，证据不足时最多扩到 1MB，避免冷启动扫描全部历史 rollout。
- 精确状态显示 `Agent N`；刚创建但尚待 rollout 验证时显示 `~N`；短暂读取失败时保留上次成功值并标记过期；没有可信证据时显示 `Agent —`，绝不把未知伪装为 `0`。
- 终态任务的总数为 `0` 时隐藏指标；若终态根任务仍有活跃后代，保留橙色异常指标，便于发现未收敛的 Agent 树。
- 子 Agent 仅参与聚合，不会生成独立任务行，也不会提供停止、重试或其他写操作。

## 最近完成与未查看语义

- 回执主键为 `thread_id + turn_id`，同一任务再次运行并完成后会产生新的未查看项。
- 首次启动建立时间基线，不把历史完成任务批量标为未查看。
- 从 GPT Pulse 成功打开任务或点击手动勾选后写入回执。
- “全部已查看”在单一 SQLite 事务中批量写入；撤销只删除该批 GPT Pulse 回执，不接触 Codex 数据。
- 已完成、失败和中断任务统一保留 24 小时，最多展示 20 条；未查看的成功任务优先进入保留集合。
- 标记已查看只更新 GPT Pulse 自有回执，任务仍会留在“最近完成”中直至超出保留窗口。

## Token 与配额语义

- session 累计总量优先取 rollout 最后一个非空 `total_token_usage`，SQLite `threads.tokens_used` 仅作为缺少明细时的只读降级来源。
- `total_tokens = input_tokens + output_tokens`；`cached_input_tokens` 是 input 子集，`reasoning_output_tokens` 是 output 子集，界面不得重复相加。
- 额度主数据源是 Codex Desktop bundled `codex app-server` 的只读 `account/rateLimits/read`。界面优先使用响应顶层 `rateLimits` 整组数据；顶层缺失时只接受 `rateLimitsByLimitId["codex"]`，不会误选模型专用池。
- 5h 与 weekly 分别按 `windowDurationMins == 300` 和 `windowDurationMins == 10080` 识别，不依赖 `primary` / `secondary` 的固定顺序，并始终来自同一份 App Server snapshot。
- App Server 首次连接期间先显示“额度待刷新”。刷新失败时继续保留尚未 reset 的最近官方 snapshot；只有没有仍有效的官方值时，rollout JSONL 才作为兼容兜底。兜底精确接受 `limit_id == "codex"`（旧数据无 ID 时仅在无其他池竞争时兼容），只选择单个事件同时带齐两窗、完整且未过期的原子 snapshot；同一或不同 rollout 出现多个有效 reset tuple 时返回“额度待刷新”，禁止拼接窗口或按最高用量猜测。
- 配额只展示 `100 - used_percent` 的剩余百分比和 `resets_at`；缺失或过期快照必须降级为“待刷新”。
- 解析器只提取 `token_count` 的数值字段，不缓存同一 rollout 中的 prompt、tool input、tool output 或 transcript。

## 注意力与通知策略

- 菜单栏仍只显示“正在运行 / 最近完成”两行计数；运行圆点按“失败红 > 等待用户橙 > 正常蓝”决定颜色。
- 右键菜单的“打开下一条需处理任务”按等待授权、等待回答、更新时间排序，并继续使用只读 deep link。
- 通知档位默认为“仅需我处理”；“重要状态”增加完成通知，“全部”再增加中断通知。
- 项目聚焦和静音统一使用最近 Git 根目录（无 Git 时使用规范化工作目录）；静音只过滤任务通知，不影响采集、右栏或菜单栏计数，`UserDefaults` 只保存项目身份的 SHA-256 与到期时间。旧版明文路径 key 会在启动时迁移为哈希。
- 相邻刷新中的完成事件先聚合 1 秒，再合并为一条无声摘要，避免通知风暴。
- 5h / weekly 分别使用各自 `observedAt` 判断 15 分钟新鲜度；剩余 20%、10%、5% 分级提醒，去重键由 `plan_type + window_minutes + resets_at + threshold` 构成并持久化。
- 通知权限请求期间或 Notification Center 临时投递失败时，只要任务状态仍有效，就按最高 5 分钟的封顶退避持续重试；adapter 部分或全部暂时不可用时保留缺失任务的上一状态，避免恢复后重复或漏发通知。
- “稍后提醒”每 30 秒与当前任务状态、通知档位、项目静音、额度 plan 和 reset window 对账；rollout 部分或全部暂时不可用时保守保留，条件失效后删除。额度同一 reset window 内的用量单调，因此不会仅因 telemetry 超过 15 分钟而提前删除 1 小时提醒。
- 通知动作只允许打开 Codex、打开 GPT Pulse、稍后提醒或写入 GPT Pulse 自有已查看回执；不批准权限、不回答问题、不停止或重试任务。

## macOS 宿主

- `NSStatusItem` 承载固定图标区与双行计数；右键菜单的“检查更新…”只调用 Sparkle 标准 updater，不改变任务状态。
- 自定义 `NSPanel` 承载 400px 侧边栏，并通过 SwiftUI 构建内容。
- “正在运行 / 最近完成”使用独立 disclosure；展开状态写入 GPT Pulse 自有 `UserDefaults`，折叠组不进入键盘焦点顺序，也不清空任务行的 token 明细展开状态。
- 面板展示来源分为 `statusItemClick`、`edgeHover` 与 `programmatic`。状态栏点击先提供 5 秒移入保护；一旦进入面板即转为 hover hold，离开后沿用 0.3 秒防抖。Timer 以递增 token 隔离，旧回调不得关闭新一轮展示。
- 轻量轮询 `NSEvent.mouseLocation`，仅在右侧中间 60% 连续停留 200ms 后触发。
- 触边计算使用显示器全局几何；相邻显示器覆盖的右边缘不视为可触发边缘。
- 全屏检测只在指针已进入触发带时执行，避免持续扫描窗口列表。
- 动画遵守 `accessibilityDisplayShouldReduceMotion`。

## 更新边界

- Sparkle 2 通过 Swift Package Manager 精确锁定。`SUFeedURL` 指向 GitHub Latest Release 的公开 `appcast.xml`；`SUPublicEDKey` 只包含可公开的 EdDSA public key，private key 只保存在发布机仓库外的受限文件中，发布脚本也保留显式 Keychain 兼容模式。
- 更新包在解压前校验 EdDSA，App 与 DMG 同时要求 Developer ID 签名、公证与 staple。appcast 必须从最终 staple 后的 DMG 生成，避免签名长度与实际公开字节不一致。
- 更新检查不会附加 Codex 任务、项目路径或 transcript，也不启用 Sparkle system profiling。只有用户接受更新后才下载 appcast 引用的发布附件。
- `v1.1.0` 是更新通道 bootstrap；没有 Sparkle 的旧版本必须手动安装一次。更新失败不得影响本地 task adapters、菜单栏计数或侧边栏。

## 兼容策略

所有 Codex 输入均通过 adapter 隔离。SQLite 表、JSONL 事件或深链发生变化时，对应 adapter 应进入 degraded/unavailable 状态，其他 adapter 继续工作；不允许通过写入、migration 或修复 Codex 文件来恢复兼容。
