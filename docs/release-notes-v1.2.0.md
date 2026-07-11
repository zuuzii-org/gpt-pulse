# GPT Pulse v1.2.0

GPT Pulse v1.2.0 makes Codex usage-limit reset times precise and timezone-aware. It also keeps the update channel, installation guidance, and companion plugin version aligned with the new release.

## 中文

### 本次更新

- 用量面板的 5 小时和每周额度现在始终显示具体日期与时间：`重置 yyyy-MM-dd HH:mm`。
- 重置时间使用 macOS 当前系统时区，并在系统时区变化后自动跟随。
- 调整右侧时间列宽度并允许缩放，完整日期时间不会再被截断。
- Codex 插件版本同步升级到 `1.2.0`。

### 安装

1. 下载 `GPT-Pulse-1.2.0.dmg` 与 `GPT-Pulse-1.2.0.dmg.sha256`。
2. 在同一目录执行：

   ```bash
   shasum -a 256 -c GPT-Pulse-1.2.0.dmg.sha256
   ```

3. 打开 DMG，将 `GPT Pulse.app` 拖入 `Applications`。
4. 已安装 v1.1.0 的用户可以从菜单栏右键选择“检查更新…”升级。

### 兼容性

- macOS 14 或更高版本。
- Universal App：Apple Silicon (`arm64`) 与 Intel (`x86_64`)。

---

## English

### What changed

- The 5-hour and weekly usage cards now always show a concrete reset date and time as `reset yyyy-MM-dd HH:mm`.
- Reset times use the Mac's current system time zone and follow time-zone changes automatically.
- The reset column is wider and can tighten text so the full timestamp remains readable.
- The companion Codex plugin is now version `1.2.0`.

### Install

1. Download `GPT-Pulse-1.2.0.dmg` and `GPT-Pulse-1.2.0.dmg.sha256`.
2. In the same directory, run:

   ```bash
   shasum -a 256 -c GPT-Pulse-1.2.0.dmg.sha256
   ```

3. Open the DMG and drag `GPT Pulse.app` to `Applications`.
4. Users on v1.1.0 can choose `检查更新…` (“Check for Updates…”) from the menu bar.

### Compatibility

- macOS 14 or later.
- Universal App for Apple Silicon (`arm64`) and Intel (`x86_64`).

GPT Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI.
