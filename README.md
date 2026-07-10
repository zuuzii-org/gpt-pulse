<p align="center">
  <img src="Assets/Brand/GPTPulse-AppIcon-Rendered-512.png" width="128" height="128" alt="GPT Pulse icon">
</p>

# GPT Pulse

GPT Pulse 是面向 Codex Desktop 的原生 macOS 任务侧边栏。它在菜单栏用双行紧凑计数显示任务状态，鼠标停留在当前屏幕右侧中间区域 200ms 后，弹出 400px 全高面板。

> 当前版本：`v0.1.0`。仅监控 `Codex Desktop` 根任务，不包含 CLI、IDE、automation、cloud task 或 subagent。

[下载最新版本](https://github.com/zuuzii-org/gpt-pulse/releases/latest)

## V1 功能

- 菜单栏固定窄宽度，双行显示 `● 正在运行数量` 与 `✓ 最近完成数量`
- 右栏按“正在运行”“最近完成”两组展示，区分等待授权、等待回答、失败和中断
- 任务优先显示项目名称与 session 名称，并提供单个 session 的累计 token 用量与明细
- 显示 5h 与 weekly 配额的剩余百分比、重置时间和数据新鲜度
- 最近完成保留 24 小时、最多 20 条，未查看的成功任务优先进入保留集合
- 点击任务通过 `codex://threads/<thread-id>` 打开 Codex Desktop
- 从 GPT Pulse 打开完成任务后自动标记已查看，也可手动勾选
- 完成、失败、等待授权和等待回答的原生通知，默认无声音
- 鼠标所在屏幕弹出；相邻显示器内部接缝不触发
- 全屏应用默认禁用触边，可在设置中修改
- 支持开机启动

## 隐私边界

GPT Pulse 不修改 Codex 的数据库、rollout 或任务记录。

- `~/.codex/state_*.sqlite` 始终以 SQLite read-only + `query_only` 打开
- rollout JSONL 按行解析事件，但只提取、保留和展示状态、时间、token 汇总与 rate-limit 数值；不会提取、持久化或上传 prompt、tool input、tool output 或 transcript 内容
- 插件 hook 不保存 prompt、tool input、tool output 或 transcript 路径
- hook journal 只保留 `session_id`、`turn_id`、事件名和时间戳，不记录项目路径
- GPT Pulse 自有的已查看回执保存在 `~/Library/Application Support/GPT Pulse/`
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
codex plugin marketplace add zuuzii-org/gpt-pulse --ref v0.1.0
codex plugin add gpt-pulse@gpt-pulse
```

安装后需要在 Codex 中检查并信任 hooks。插件将最小化事件写入：

```text
~/Library/Application Support/GPT Pulse/events/events.jsonl
```

hook 只依赖 macOS 内置的 `/bin/sh` 和 JXA，不要求 Python、Node.js 或其他外部 runtime。

## 已知边界

- 当前 Codex Desktop 使用私有 `stdio` App Server，外部应用无法直接订阅其内存态；GPT Pulse 会先探测官方 control socket，当前不可用时自动使用 hooks、SQLite 和 JSONL。
- 5h 与 weekly 只提供“已用百分比 + 重置时间”，没有可可靠换算的绝对 token 配额；界面显示的是剩余百分比，不是剩余 token 个数。
- 配额由当前有效的 rollout 快照保守合并：每个窗口展示最低可用余额，避免不同限额池交错写入时夸大额度；快照过期或缺失时显示“待刷新”。
- `codex://threads/<thread-id>` 已在当前 Codex Desktop 构建中验证，但尚未作为公开稳定契约；导航失败时应用会保留任务为未查看并显示错误。
- 在 Codex 内部自行打开任务无法被 V1 稳定感知；只有从 GPT Pulse 打开或手动勾选才会清除“未查看”。
- Codex hooks 没有独立的“授权已批准”事件：任务从等待授权恢复为运行，要到该工具产生 `PostToolUse` 后才能确认；工具执行期间可能继续显示为等待授权。rollout 的终态仍具有更高优先级。

更多实现细节见 [架构说明](docs/ARCHITECTURE.md)。

## License

[MIT](LICENSE)
