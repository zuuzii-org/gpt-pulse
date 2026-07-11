# GPT Pulse v1.1.0

GPT Pulse v1.1.0 adds a quieter way to scan long task lists and establishes a signed in-app update channel for future releases. It also fixes the two places that were easiest to misread: the menu bar counts and the DMG installation window.

## 中文

### 本次更新

- “正在运行”和“最近完成”现在可以独立折叠。选择会保存在本机，下次启动继续沿用；折叠分组不会清除任务行已经展开的 token 明细。
- 菜单栏数字改为固定的图标区与双行计数区，`0`、两位数和 `99+` 在浅色、深色菜单栏中都不会再被裁切或挤到图标上。
- 右键菜单新增“检查更新…”。更新由 Sparkle 2.9.4 处理，下载前读取公开 appcast，安装前验证 EdDSA 签名与 Developer ID 签名。
- DMG 安装窗口增加清晰的拖拽箭头、双语短提示和浅色文件名底板，未选中的 Finder 黑色标签也能直接读清。
- README 改为英文主版与完整简体中文版，重新整理安装、隐私、工作方式、常见问题和已知限制。

### 更新通道说明

`v1.1.0` 是 Sparkle 更新通道的起点。`v1.0.0` 没有内置更新器，因此现有用户需要手动下载安装本版本一次。安装 `v1.1.0` 后，后续版本可以通过菜单栏右键的“检查更新…”安装。

更新检查只访问 GitHub Release 上公开的 `appcast.xml`，不会附带 Codex 任务、项目路径、prompt、tool input、tool output 或 transcript，也不会发送 Sparkle system profile。

### 安装

1. 下载 `GPT-Pulse-1.1.0.dmg` 与 `GPT-Pulse-1.1.0.dmg.sha256`。
2. 在同一目录执行：

   ```bash
   shasum -a 256 -c GPT-Pulse-1.1.0.dmg.sha256
   ```

3. 打开 DMG，将 `GPT Pulse.app` 拖入 `Applications`。
4. 可选：按[中文 README](https://github.com/zuuzii-org/gpt-pulse/blob/v1.1.0/README.zh-CN.md#可选-codex-插件)安装配套 Codex hooks。

### 兼容性与边界

- macOS 14 或更高版本。
- Universal App：Apple Silicon (`arm64`) 与 Intel (`x86_64`)。
- 当前仅支持本机 Codex Desktop 根任务；不包含 Codex CLI、IDE、cloud task 或其他 AI 编程工具。
- App 界面仍为简体中文，项目文档提供英文和简体中文版本。

---

## English

### What changed

- Running and Recently Completed can now be collapsed independently. Both choices persist locally across launches, and collapsing a group does not discard expanded token details inside its rows.
- Menu bar metrics now use fixed icon and count regions. `0`, two-digit values, and `99+` remain aligned without clipping in light and dark menu bars.
- The right-click menu now includes `检查更新…` (“Check for Updates…”). Sparkle 2.9.4 reads the public appcast and verifies the EdDSA and Developer ID signatures before installing an update.
- The DMG installation window now has a clear drag arrow, short bilingual guidance, and light label plates so Finder's unselected black filenames remain readable.
- The project documentation now has a focused English README and a complete Simplified Chinese edition, with clearer installation, privacy, architecture, FAQ, and limitations sections.

### Update channel bootstrap

`v1.1.0` is the first GPT Pulse release with Sparkle. `v1.0.0` cannot discover this update channel, so existing users need to install this version manually once. After `v1.1.0` is installed, later releases can be installed from the menu bar's `检查更新…` command.

An update check reads the public `appcast.xml` hosted with the GitHub Release. It does not attach Codex tasks, project paths, prompts, tool input, tool output, transcripts, or a Sparkle system profile.

### Install

1. Download `GPT-Pulse-1.1.0.dmg` and `GPT-Pulse-1.1.0.dmg.sha256`.
2. In the same directory, run:

   ```bash
   shasum -a 256 -c GPT-Pulse-1.1.0.dmg.sha256
   ```

3. Open the DMG and drag `GPT Pulse.app` to `Applications`.
4. Optional: follow the [English README](https://github.com/zuuzii-org/gpt-pulse/blob/v1.1.0/README.md#optional-codex-plugin) to install the companion Codex hooks.

### Compatibility and scope

- macOS 14 or later.
- Universal App for Apple Silicon (`arm64`) and Intel (`x86_64`).
- The current scope is local root tasks created by Codex Desktop. Codex CLI, IDE tasks, cloud tasks, and other AI coding tools are not supported in this release.
- The app interface remains in Simplified Chinese; the project documentation is available in English and Simplified Chinese.

GPT Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI.
