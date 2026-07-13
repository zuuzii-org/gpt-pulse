# LLM Pulse 本地发布

`release.sh` 生成 macOS 14+ 的 Universal (`arm64` + `x86_64`) Release，并执行：

1. 无签名构建，然后使用 `Developer ID Application`、hardened runtime 和 secure timestamp 手动签名。
2. 将 App 打包为 ZIP 提交公证，等待 `Accepted`，再 staple App。
3. 创建带 `LLM Pulse.app → Applications` 拖拽布局的压缩 DMG，并签名 DMG；重复 wrapper 会在启动期数据迁移前被阻断。
4. 再次提交 DMG 公证，然后 staple DMG。
5. 使用 `codesign`、`stapler`、`spctl`、`hdiutil` 和 `lipo` 验证最终 DMG 及其中的 App。
6. 生成 `.sha256`，再为最终 staple 后的 DMG 生成两跳 `appcast.xml`；v2 item 仅面向 bridge build 6 及更高版本，同时保留固定校验的 v1.4 item，并验证两项 enclosure。

脚本不会接收 Apple ID 或密码。公证仅使用 Keychain 中的 profile，默认为 `LLMPulseNotary`。

## 前置条件

- Xcode Command Line Tools、XcodeGen 和有效的 `Developer ID Application` 证书。
- 为保持既有 Sparkle 更新信任链，默认从仓库外的 `~/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key` 读取 Sparkle EdDSA 私钥；文件必须归当前用户所有、mode `0600`、只有一个 hard link，父目录必须为 mode `0700`，且公钥必须与 `Info.plist` 的 `SUPublicEDKey` 一致。
- 已发布更新链必须把现有 Sparkle 私钥原样安全迁移到上述新路径，不能重新生成 key；否则会与 App 内保留的 `SUPublicEDKey` 不匹配，脚本也会拒绝发布。
- 已执行：

  ```bash
  xcrun notarytool store-credentials "LLMPulseNotary" \
    --apple-id "<Apple ID>" \
    --team-id "<Team ID>"
  ```

- 正式发布必须从 clean Git commit 执行。中间构建、公证 ZIP 和诊断位于已忽略的 `.build/release/`；最终 `dist/` 也必须保持在 `.gitignore` 中，只作为 GitHub Release 附件上传。
- `docs/release-notes-vVERSION.md` 必须已存在，且 Codex plugin manifest 版本必须与 App 一致；脚本会在签名和公证前完成这些检查。

## 常用命令

先查看完整流程，不构建、不签名、不联网：

```bash
DRY_RUN=1 scripts/release.sh --allow-dirty
```

从 clean commit 一次完成正式发布：

```bash
scripts/release.sh --team-id "<Team ID>"
```

默认产物：

```text
dist/LLM-Pulse-VERSION.dmg
dist/LLM-Pulse-VERSION.dmg.sha256
dist/appcast.xml
```

中断后可按阶段恢复：

```bash
scripts/release.sh --stage build --team-id "<Team ID>"
scripts/release.sh --stage notarize-app
scripts/release.sh --stage package --team-id "<Team ID>"
scripts/release.sh --stage notarize-dmg
scripts/release.sh --stage verify
scripts/release.sh --stage appcast
```

`build` 会重建 `.build/release/DerivedData`、移除同版本旧 DMG/appcast，并在 `.build/release/work-vVERSION/release-manifest.plist` 原子写入当前 Git `HEAD`、版本、build 与输出目录。每个后续阶段都会在读取 App 或 DMG 前强制校验该 manifest；只要切换了 commit、版本/build 或输出目录，就必须重新执行 `--stage build`，不会复用来源不明的旧产物。`package` 还会拒绝未 staple 的 App，避免把仅签名但未公证的 App 放入 DMG。

Sparkle 通过 Swift Package Manager 精确锁定版本。发布构建会移除非沙盒宿主不需要的 Sparkle XPC Services，再对 helper、Updater、framework 和宿主 App 从内到外签名。`appcast.xml` 只从最终通过公证并 staple 的 DMG 生成，enclosure URL 固定指向同版本 GitHub Release；脚本会验证 build、short version、最低系统版本、文件长度，并使用 `SUPublicEDKey` 对更新包做 public-only Ed25519 验签。私钥不会进入仓库、`.build`、`dist`、命令参数内容或日志。

默认 `SPARKLE_KEY_SOURCE=file`。可用 `SPARKLE_PRIVATE_KEY_FILE` 指向另一个仓库外的绝对路径；脚本拒绝仓库、临时目录、CloudStorage、Mobile Documents、符号链接、弱权限和公钥不匹配。兼容旧 Keychain 流程时必须显式设置 `SPARKLE_KEY_SOURCE=keychain`，并通过 `SPARKLE_ACCOUNT` 指定 account；文件模式失败绝不会回退 Keychain。

`DRY_RUN=1` 会打印 manifest 的写入与校验步骤；单独演练后续阶段时，如果磁盘上已有 manifest，也会实际比较其来源字段并拒绝不匹配值。没有 manifest 时只打印正式运行将执行的要求，不会为了演练创建文件。

DMG 默认将 `Assets/Release/dmg-background.png` 和相邻的 `dmg-background@2x.png` 合成为 HiDPI TIFF，并从构建出的 App 复用 `AppIcon.icns` 作为卷图标。安装背景的两侧浅色标签底板专门承托 Finder 的黑色未选中文件名，中间箭头明确指向 `Applications`。背景可由源底图重复生成：

```bash
swift scripts/render_dmg_background.swift \
  --preview .build/release/dmg-background-preview.png
```

脚本读取 `Assets/Release/dmg-background-artwork.png` 与 `dmg-background-artwork@2x.png`，固定输出 640×420 和 1280×840 两档资源；`--preview` 会生成带图标和 Finder 黑色标签的本地验收图，不进入发布产物。

也可以显式覆盖背景和卷图标；自定义背景同样必须提供 640×420 PNG 和相邻的 1280×840 `@2x` PNG：

```bash
scripts/release.sh \
  --background Assets/Release/dmg-background.png \
  --team-id "<Team ID>"
```

未传 `--volume-icon` 时，发布脚本会使用已构建 App 中的 `AppIcon.icns`。

无 Finder 的临时环境可以传 `--skip-finder-layout`，但正式公开发布不应使用该参数。`--allow-dirty` 也只允许与 `DRY_RUN` 一起使用；任何真实构建、签名或公证都会要求 clean Git commit。

如果 Keychain 中只有一个有效的 `Developer ID Application` 证书，脚本可以自动选择它。存在多个证书时，传 `--team-id`，或通过 `SIGNING_IDENTITY` 提供证书 SHA-1。不要把证书持有人名称写进仓库或发布文案；系统签名详情中的证书 Authority 属于 Apple 安全元数据，无法隐藏。

## 公证稳定性

脚本显式使用 `notarytool submit --no-wait`，再通过 `notarytool info` 轮询。这避免依赖长时间运行的 `submit --wait` 进程。默认每 15 秒查询一次，最多等待 30 分钟：

```bash
NOTARY_POLL_INTERVAL=15 NOTARY_TIMEOUT=1800 scripts/release.sh
```

被拒绝时，诊断会保存在 `.build/release/work-vVERSION/notary-*-log.json`，流程立即停止。
