<p align="center">
  <img src="Assets/Brand/GPTPulse-AppIcon-Rendered-512.png" width="128" height="128" alt="GPT Pulse icon">
</p>

# GPT Pulse

GPT Pulse 是面向 Codex Desktop 的原生 macOS 任务侧边栏。它在菜单栏用通用 AI 图标与双行紧凑计数显示任务状态，鼠标停留在当前屏幕右侧中间区域 200ms 后，弹出 400px 全高面板。

> 当前版本：`v1.0.0`。仅监控 `Codex Desktop` 根任务，不包含 Claude Code、DeepSeek、GLM、CLI、IDE、automation 或 cloud task；subagent 不单列为任务，但会聚合为所属根任务的活跃 Agent 数量。

[下载最新版本](https://github.com/zuuzii-org/gpt-pulse/releases/latest)

## V1 功能

- 菜单栏使用适配浅色、深色和高亮状态的 18pt Template Icon；右侧双行数字上方显示正在运行、下方显示最近完成，超过 99 时显示 `99+`
- 左键点击菜单栏后提供 5 秒移入保护；鼠标进入右栏后持续显示，离开时按 0.3 秒防抖关闭；右侧触边仍保持原有即时悬停逻辑
- 右栏按“正在运行”“最近完成”两组展示，区分等待授权、等待回答、失败和中断
- 任务优先显示项目名称与 session 名称，并提供单个 session 的累计 token 用量与明细
- 每个任务显示主 Agent 与全部层级子 Agent 的活跃总数；等待授权、等待回答仍计入，数据暂不可用时明确显示未知而不是 `0`
- 显示 5h 与 weekly 配额的剩余百分比、重置时间和数据新鲜度
- 支持按 Git 项目根目录临时聚焦；可将项目通知静音 1 小时或到次日，菜单栏计数仍保持全局
- 最近完成保留 24 小时、最多 20 条，未查看的成功任务优先进入保留集合
- 多个未查看完成项可批量标记，并在 6 秒内撤销
- 点击任务通过 `codex://threads/<thread-id>` 打开 Codex Desktop
- 从 GPT Pulse 打开完成任务后自动标记已查看，也可手动勾选
- 原生通知支持“仅需我处理 / 重要状态 / 全部”三个档位，默认仅提醒等待操作和失败且无声音
- 通知可直接打开 Codex、稍后 15 分钟或 1 小时再提醒；完成通知可直接标记已查看
- 新鲜额度快照低于 20%、10%、5% 时按 reset window 去重提醒；同批完成任务合并为安静摘要
- 鼠标所在屏幕弹出；相邻显示器内部接缝不触发
- 全屏应用默认禁用触边，可在设置中修改
- 支持开机启动

## 隐私边界

GPT Pulse 不修改 Codex 的数据库、rollout 或任务记录。

- `~/.codex/state_*.sqlite` 始终以 SQLite read-only + `query_only` 打开
- rollout JSONL 按行解析事件，但只提取、保留和展示状态、时间、Agent 生命周期、token 汇总与 rate-limit 数值；不会提取、持久化或上传 prompt、tool input、tool output 或 transcript 内容
- 插件 hook 不保存 prompt、tool input、tool output 或 transcript 路径
- hook journal 只保留 `session_id`、`turn_id`、事件名和时间戳，不记录项目路径
- GPT Pulse 自有的已查看回执保存在 `~/Library/Application Support/GPT Pulse/`；通知档位和额度提醒去重键保存在本机偏好设置，项目静音只保存规范化项目根目录的 SHA-256 标识，不保存明文路径
- 不需要 OpenAI API Key，也不上传任务数据

## 构建

要求：macOS 14+、Xcode 16+、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
make generate
make test
make build
open ".build/DerivedData/Build/Products/Debug/GPT Pulse.app"
```

开发时也可以运行 `make open`，再从 Xcode 启动 `GPTPulse` scheme。

## 安装 Codex 插件

仓库包含本地 marketplace 和只读 lifecycle hooks。插件不是 UI 宿主；它只提高实时状态识别精度。未安装插件时，应用仍会使用 SQLite 和 rollout JSONL 降级读取。

```bash
codex plugin marketplace add zuuzii-org/gpt-pulse --ref v1.0.0
codex plugin add gpt-pulse@gpt-pulse
```

安装后需要在 Codex 中检查并信任 hooks。插件将最小化事件写入：

```text
~/Library/Application Support/GPT Pulse/events/events.jsonl
```

hook 只依赖 macOS 内置的 `/bin/sh` 和 JXA，不要求 Python、Node.js 或其他外部 runtime。

## 已知边界

- GPT Pulse 通过 Codex Desktop bundled `codex app-server` 的只读 `account/rateLimits/read` 获取和 Codex 设置页一致的额度整组；首次连接时等待官方值，刷新失败时优先保留尚未重置的最近官方快照，没有有效官方值才降级到 rollout JSONL。
- Agent 数量来自只读父子关系与 rollout 生命周期重建；Codex 私有本地格式漂移、文件尚未落盘或暂时不可读时显示 `Agent —`，已有可靠快照则保留数值并标记为可能过期。
- 5h 与 weekly 只提供“已用百分比 + 重置时间”，没有可可靠换算的绝对 token 配额；界面显示的是剩余百分比，不是剩余 token 个数。
- 配额优先使用 App Server 顶层 `rateLimits`，顶层缺失时仅接受精确的 `codex` 桶，不会误选 `codex_bengalfox` 等模型专用池。rollout 仅作兼容兜底，5h 与 weekly 必须来自同一完整事件；多个重置组冲突时显示“额度待刷新”，不跨任务拼接或猜测。
- 额度预警分别检查 5h / weekly 最近 15 分钟内的新鲜度；同一 plan、reset window 和阈值最多提醒一次，不预测精确可用 token 或耗尽时间。
- “稍后提醒”会在后台重新核对任务状态、项目静音、通知档位、额度 plan 与 reset window；短暂数据源故障不会误删，条件已变化时自动取消。
- `codex://threads/<thread-id>` 已在当前 Codex Desktop 构建中验证，但尚未作为公开稳定契约；导航失败时应用会保留任务为未查看并显示错误。
- 在 Codex 内部自行打开任务无法被 V1 稳定感知；只有从 GPT Pulse 打开或手动勾选才会清除“未查看”。
- Codex hooks 没有独立的“授权已批准”事件：任务从等待授权恢复为运行，要到该工具产生 `PostToolUse` 后才能确认；工具执行期间可能继续显示为等待授权。rollout 的终态仍具有更高优先级。

更多实现细节见 [架构说明](docs/ARCHITECTURE.md)。

## License

[MIT](LICENSE)
