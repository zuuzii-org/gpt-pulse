# GPT Pulse V1 架构

## 目标

V1 面向单机、单用户的 Codex Desktop。核心约束是：实时状态尽可能准确，且绝不修改 Codex 持久化数据。

## 数据流

1. `AppServerCapabilityProbe` 首先检查 Codex managed control socket。只有现有 socket 可连接时才允许进入协议适配；GPT Pulse 不负责启动 daemon。
2. `PluginEventJournal` 读取插件 hooks 产生的最小化 lifecycle 事件，用于补充运行中与等待授权状态。
3. `CodexSQLiteTaskAdapter` 以 read-only 模式读取 thread 元数据与可选的 `tokens_used` 总量。
4. `RolloutTaskAdapter` 解析 rollout 的状态、累计 token 汇总与 rate-limit 快照，并以 `session_meta.originator == "Codex Desktop"` 做最终桌面来源校验。
5. `ReceiptStore` 只在 GPT Pulse 自有数据库中保存完成 turn 的已查看回执。
6. `TaskRepository` 合并上述数据并生成 UI 所需的 `TaskSnapshot`。

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

## 最近完成与未查看语义

- 回执主键为 `thread_id + turn_id`，同一任务再次运行并完成后会产生新的未查看项。
- 首次启动建立时间基线，不把历史完成任务批量标为未查看。
- 从 GPT Pulse 成功打开任务或点击手动勾选后写入回执。
- 已完成、失败和中断任务统一保留 24 小时，最多展示 20 条；未查看的成功任务优先进入保留集合。
- 标记已查看只更新 GPT Pulse 自有回执，任务仍会留在“最近完成”中直至超出保留窗口。

## Token 与配额语义

- session 累计总量优先取 rollout 最后一个非空 `total_token_usage`，SQLite `threads.tokens_used` 仅作为缺少明细时的只读降级来源。
- `total_tokens = input_tokens + output_tokens`；`cached_input_tokens` 是 input 子集，`reasoning_output_tokens` 是 output 子集，界面不得重复相加。
- 5h 与 weekly 分别按 `window_minutes == 300` 和 `window_minutes == 10080` 识别，不依赖 `primary` / `secondary` 的固定顺序。
- 多个根任务可能同时写入不同限额池；Repository 会忽略已过期窗口，并对每个窗口选择 `used_percent` 最高的当前快照，即展示保守的最低余额，避免数值随最后写入者抖动。
- 配额只展示 `100 - used_percent` 的剩余百分比和 `resets_at`；缺失或过期快照必须降级为“待刷新”。
- 解析器只提取 `token_count` 的数值字段，不缓存同一 rollout 中的 prompt、tool input、tool output 或 transcript。

## macOS 宿主

- `NSStatusItem` 承载菜单栏计数。
- 自定义 `NSPanel` 承载 400px 侧边栏，并通过 SwiftUI 构建内容。
- 轻量轮询 `NSEvent.mouseLocation`，仅在右侧中间 60% 连续停留 200ms 后触发。
- 触边计算使用显示器全局几何；相邻显示器覆盖的右边缘不视为可触发边缘。
- 全屏检测只在指针已进入触发带时执行，避免持续扫描窗口列表。
- 动画遵守 `accessibilityDisplayShouldReduceMotion`。

## 兼容策略

所有 Codex 输入均通过 adapter 隔离。SQLite 表、JSONL 事件或深链发生变化时，对应 adapter 应进入 degraded/unavailable 状态，其他 adapter 继续工作；不允许通过写入、migration 或修复 Codex 文件来恢复兼容。
