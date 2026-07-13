# LLM Pulse v1.4.0

LLM Pulse v1.4.0 introduces the new product name and repository while preserving the local Codex task-monitoring experience and existing user state.

## 中文

### 本次更新

- 产品正式完成 **LLM Pulse** 品牌迁移。
- App、菜单栏、侧边栏、设置、通知、DMG 和 Codex 配套插件均已使用新名称。
- GitHub 仓库迁移到 `zuuzii-org/llm-pulse`；旧仓库和旧更新链接会继续重定向。
- 保留现有偏好、未查看回执、通知权限与本机兼容数据，升级后无需重新设置。
- v1.4.0 作为兼容过渡版本，DMG 内暂时保留旧版磁盘文件名，让 Sparkle 更新和手动拖拽安装都能原位替换旧版，避免产生两个相同 Bundle ID 的 App；启动后显示的产品名称仍为 **LLM Pulse**。
- 更新 GitHub 社交图、产品截图、中英文 README 和发布文档。

v1.4.0 继续稳定支持本机 Codex Desktop 根任务；v2.0.0 延续这一 Codex-only 产品范围。

### 安装

1. 下载 `LLM-Pulse-1.4.0.dmg` 与 `LLM-Pulse-1.4.0.dmg.sha256`。
2. 在同一目录执行：

   ```bash
   shasum -a 256 -c LLM-Pulse-1.4.0.dmg.sha256
   ```

3. 退出正在运行的旧版，打开 DMG，将其中的应用拖入 `Applications`；出现提示时选择“替换”。启动后显示的产品名称为 **LLM Pulse**。
4. 已安装 v1.1.0 或更高版本的用户可以从菜单栏右键选择“检查更新…”升级。

### 兼容性

- macOS 14 或更高版本。
- Universal App：Apple Silicon (`arm64`) 与 Intel (`x86_64`)。

---

## English

### What changed

- Completed the product migration to **LLM Pulse**.
- Updated the app, menu bar, sidebar, settings, notifications, DMG, and Codex plugin with the new name.
- Moved the GitHub repository to `zuuzii-org/llm-pulse`; legacy repository and update links continue to redirect.
- Preserved existing preferences, viewed receipts, notification permissions, and compatibility data so no setup is required after updating.
- v1.4.0 is a compatibility bridge: the DMG temporarily keeps the previous on-disk filename, allowing both Sparkle and manual drag installation to replace the existing app in place without creating a second app with the same Bundle ID. The launched product is still shown as **LLM Pulse**.
- Refreshed the GitHub social image, product screenshot, bilingual README, and release documentation.

v1.4.0 continues to support local Codex Desktop root tasks; v2.0.0 keeps this Codex-only product scope.

### Install

1. Download `LLM-Pulse-1.4.0.dmg` and `LLM-Pulse-1.4.0.dmg.sha256`.
2. In the same directory, run:

   ```bash
   shasum -a 256 -c LLM-Pulse-1.4.0.dmg.sha256
   ```

3. Quit the installed version, open the DMG, and drag the enclosed app to `Applications`; choose **Replace** when prompted. The product is shown as **LLM Pulse** after launch.
4. Users on v1.1.0 or later can choose `检查更新…` (“Check for Updates…”) from the menu bar.

### Compatibility

- macOS 14 or later.
- Universal App for Apple Silicon (`arm64`) and Intel (`x86_64`).

LLM Pulse is an independent open-source project by **Zuuzii**. It is not affiliated with, endorsed by, or maintained by OpenAI.
