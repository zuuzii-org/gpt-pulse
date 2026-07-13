# LLM Pulse 架构

## 目标与产品边界

LLM Pulse 面向单机、单用户的本机 Codex Desktop 根任务。核心约束是：状态尽可能及时且可解释，所有任务数据留在本机，并且绝不修改 Codex 的持久化任务数据。

当前产品只注册 Codex 数据源。领域层继续保留 runtime、provider、profile 和 source-set 等通用抽象，便于隔离数据源故障与未来演进；这些内部扩展点不代表当前版本支持其他运行工具，也不进入用户功能宣传。

## 数据流

1. `TaskMonitor` 定时请求 `PulseHubRepository` 刷新已注册的物理 source。
2. 当前唯一生产 source 是 Codex source。它组合本机 App Server、可选 Codex plugin journal、read-only SQLite、rollout JSONL 与 Agent 观察器。
3. source 先形成经过一致性验证的任务与用量快照，Hub 再应用已查看回执、保留策略和全局汇总。
4. `ReceiptStore` 只在 LLM Pulse 自有数据库中保存已查看回执，并执行 owner、文件类型、link count 与 `SQLITE_OPEN_NOFOLLOW` 校验。
5. UI、通知和导航只依赖领域快照，不直接读取 SQLite、JSONL 或 journal。

单次刷新必须原子发布：不允许把不同刷新代次的任务、Agent 或用量字段拼成一个看似完整的结果。任一 adapter 暂时失败时，按其健康状态降级或保留仍可信的最近值，不写入或修复 Codex 文件。

## Codex 数据源

### App Server

LLM Pulse 通过本机 Codex bundled App Server 的 `account/rateLimits/read` 读取 Codex 账户用量。连接、请求和解析都设有超时；调用失败不会阻塞任务列表。

### SQLite

Codex state SQLite 使用 read-only 模式，并启用 SQLite `query_only`。读取器拒绝符号链接、不安全权限、非当前用户文件和异常文件类型。SQLite 主要提供 thread 元数据与兼容 token 总量，不作为“正在运行”的单一证据。

### Rollout JSONL

rollout parser 只提取状态、时间、Agent 生命周期、token 数值和兼容用量字段。读取从文件尾部开始，证据不足时有界扩展；size/mtime 未变时复用缓存。半行、损坏行和未知事件不会清空整份任务快照。

### 可选 Codex plugin journal

Codex plugin journal 只写 `session_id`、`turn_id`、`hook_event_name` 和 `timestamp`。写入发生在 LLM Pulse 自有目录的 owner-only 互斥边界内；journal 事件必须先与已验证的 Codex Desktop thread 对齐，不能仅凭陌生 ID 创建任务。

## 状态归并

| 输入证据 | LLM Pulse 状态 |
| --- | --- |
| `PermissionRequest` | `waitingForApproval` |
| 未匹配的 `request_user_input` call/output | `waitingForAnswer` |
| `UserPromptSubmit`、`task_started`、`PostToolUse` | `running` |
| `task_complete` | `completed` |
| `error` 且没有后续恢复或完成 | `failed` |
| `turn_aborted` | `interrupted`，归入最近任务 |

新证据覆盖旧证据。SQLite 中仍为 `open` 不能单独证明任务正在运行；运行态必须由 rollout 生命周期、有效 plugin 事件或其他受支持的当前证据确认。

Codex hooks 暂无单独的 approval-resolved 事件。`PermissionRequest` 后只能等待 `PostToolUse` 确认工具已继续，因此“批准后、工具结束前”可能短暂显示 `waitingForApproval`。

## Agent 活跃观测

- 界面展示“活跃 Agent 总数”，包含非终态主 Agent 与其全部层级的非终态子 Agent；等待授权或回答仍计为活跃。
- `thread_spawn_edges` 只用于建立递归父子图。`closed` 可直接排除，`open` 仅表示关系未被显式关闭，不能等同于正在运行。
- 子 Agent 状态取 rollout 中最后一个明确生命周期：`task_started` 激活，`task_complete`、`task_failed`、`turn_failed`、`turn_aborted` 或 `shutdown_complete` 终止；后续新的 `task_started` 可再次激活。
- 通用 `error` 先等待短暂静默窗口，期间没有新活动才视为停止；后续活动可恢复运行。
- 观察器先读相关文件尾部并按 size/mtime 缓存，证据不足时最多扩到既定上限，避免冷启动扫描全部历史 rollout。
- 精确状态显示 `Agent N`；尚待验证时显示 `~N`；短暂读取失败时保留上次成功值并标记过期；没有可信证据时显示 `Agent —`，绝不把未知伪装为 `0`。
- 子 Agent 只参与聚合，不生成独立任务行，也不提供停止、重试或其他写操作。

## 最近任务与未查看语义

- Codex 回执主键由 `thread_id + turn_id` 稳定构成；同一 thread 再次运行并完成后会产生新的未查看项。
- 首次启动建立时间基线，不把历史完成任务批量标为未查看。
- 只有成功通过 Codex deep link 打开具体任务或点击手动勾选后写入回执。
- “全部已查看”在单一 SQLite 事务中批量写入；撤销只删除该批 LLM Pulse 回执，不接触 Codex 数据。
- 完成、失败和中断任务统一保留 24 小时，最多展示 20 条；未查看的成功任务优先进入保留集合。
- 标记已查看只更新 LLM Pulse 自有回执，任务仍保留到超出时间窗或数量上限。

## Token 与每周额度语义

### Token

- session 累计总量优先取 rollout 最后一个非空 `total_token_usage`；SQLite `threads.tokens_used` 仅在缺少明细时作为只读降级来源。
- `total_tokens = input_tokens + output_tokens`；`cached_input_tokens` 是 input 子集，`reasoning_output_tokens` 是 output 子集，界面不得重复相加。
- parser 只提取 `token_count` 的数值字段，不缓存同一 rollout 中的 prompt、tool input、tool output 或正文。

### Weekly

- 当前 UI 和通知只展示 Codex weekly 窗口。weekly 通过 `windowDurationMins == 10080` 识别，不依赖 `primary` 或 `secondary` 的固定顺序。
- 用量卡显示 `100 - used_percent` 的剩余百分比、数据新鲜度，以及按 macOS 当前系统时区格式化的准确重置日期和时间。
- 通知只针对 weekly 产生阈值提醒；5 小时窗口不会渲染、不会生成通知，也不会替代 weekly。
- App Server 首次连接期间显示“额度待刷新”。刷新失败时可保留尚未 reset 的最近可信 weekly；没有仍有效的官方值时，兼容 rollout 数据才作为兜底。
- rollout 兜底只接受目标 Codex pool 中完整、未过期且来源一致的快照。存在互相冲突的有效 reset tuple 时返回“额度待刷新”，禁止按最高用量猜测。
- 底层兼容层继续识别并保留 `windowDurationMins == 300` 的旧 5 小时字段，以读取旧缓存和兼容历史数据；该字段不属于当前用户界面或通知合同。

## 注意力与通知策略

- 菜单栏显示全局“活跃 / 最近”双行计数；运行圆点按“失败红 > 等待用户橙 > 正常蓝”决定颜色。
- “打开下一条需处理任务”按等待授权、等待回答和更新时间排序，并使用只读 Codex deep link。
- 通知档位默认为“仅需我处理”；“重要状态”增加完成通知，“全部”再增加中断通知。
- 项目聚焦和静音使用最近 Git 根目录；无 Git 时使用规范化工作目录。静音只过滤任务通知，不影响采集、右栏或菜单栏计数。
- `UserDefaults` 只保存项目身份的 SHA-256 与到期时间；旧版明文路径 key 在启动时迁移为哈希。
- 相邻刷新中的完成事件先短暂聚合，再合并为无声摘要，避免通知风暴。
- weekly 使用自己的 `observedAt` 判断新鲜度；阈值提醒以 `plan + weekly window + resets_at + threshold` 去重并持久化。
- 通知权限请求期间或 Notification Center 临时投递失败时，只要任务状态仍有效，就按封顶退避重试。
- “稍后提醒”定期与任务状态、通知档位、项目静音和 weekly reset window 对账；条件失效后删除。
- 通知动作只允许打开 Codex 任务、打开 LLM Pulse、稍后提醒或写入 LLM Pulse 自有已查看回执。

## macOS 宿主

- `NSStatusItem` 承载固定图标区与双行计数；右键菜单的“检查更新…”只调用 Sparkle 标准 updater，不改变任务状态。
- 自定义 `NSPanel` 承载 400px 侧边栏，内容由 SwiftUI 构建。
- “正在运行 / 最近任务”使用独立 disclosure；展开状态写入 LLM Pulse 自有 `UserDefaults`，折叠组不进入键盘焦点顺序。
- 面板展示来源分为 `statusItemClick`、`edgeHover` 与 `programmatic`。状态栏点击提供移入保护；进入面板后转为 hover hold，离开后使用短暂防抖。
- 轻量轮询 `NSEvent.mouseLocation`，仅在右侧中间 60% 连续停留约 200ms 后触发。
- 触边计算使用显示器全局几何；相邻显示器覆盖的右边缘不视为可触发边缘。
- 全屏检测只在指针进入触发带时执行，避免持续扫描窗口列表。
- 动画遵守 `accessibilityDisplayShouldReduceMotion`；键盘焦点和 VoiceOver 标签覆盖所有可操作控件。

## 更新与兼容边界

- Sparkle 2 通过 Swift Package Manager 精确锁定。`SUFeedURL` 指向 GitHub Release 的公开 `appcast.xml`；`SUPublicEDKey` 只包含公开 EdDSA key，private key 保存在发布机仓库外。
- 更新包在解压前校验 EdDSA，App 与 DMG 同时要求 Developer ID 签名、公证与 staple。appcast 从最终 DMG 生成。
- 更新检查不附加 Codex 任务、项目路径或 transcript，也不启用 Sparkle system profiling。
- v1.1.0 是更新通道 bootstrap。v2 feed 保留 build 6 bridge；build 1–5 必须先更新并启动 build 6，再检查一次更新。
- 当前技术身份统一使用 `LLMPulse` / `llm-pulse`。旧身份只允许出现在 `LegacyCompatibility`，用于一次性迁移偏好、回执和 plugin journal。
- 重复 App、冲突数据根、符号链接、owner 或权限异常均 fail closed；迁移不得写入或修复 Codex 自身数据。

## 通用领域底座

`ModelIdentity`、`ModelTaskSnapshot`、`PulseHubSnapshot` 和 source-set 协议保持来源无关，以便测试隔离、故障边界和未来维护。当前生产配置只创建 Codex identity 和 Codex source；UI、菜单、通知与公开文档均以单一 Codex 产品合同为准。新增任何其他 source 必须重新经过明确的产品决策、隐私审查、真实数据验证和发布门禁，不能仅凭底座存在而自动启用。
