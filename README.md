<p align="center">
  <img src="Assets/Brand/GPTPulse-AppIcon-Rendered-512.png" width="128" height="128" alt="LLM Pulse app icon">
</p>

# LLM Pulse — Local AI Coding Task Monitor for macOS

<p align="center"><strong>AI coding tasks, always in sight.</strong></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/zuuzii-org/llm-pulse/releases/latest">Download</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture</a> ·
  <a href="LICENSE">MIT License</a>
</p>

**LLM Pulse is an open-source native macOS menu bar monitor for local AI coding tasks.** Its current public release monitors Codex Desktop; v2.0 expands the same right-edge workflow to Claude Code with Qwen3.7. LLM Pulse keeps running tasks, work waiting for approval or input, recent completions, active agent totals, token usage, and usage-limit data visible without changing the underlying task records.

The app interface supports English and Simplified Chinese. Choose Follow System, 简体中文, or English in Settings; changes apply immediately without restarting.

<p align="center">
  <img src="Assets/Release/product-sidebar.png" width="400" alt="LLM Pulse sidebar showing running Codex tasks, approval requests, active agents, recent completions, token usage, and usage-limit reset times">
</p>

## Product facts

| | |
|---|---|
| **Product** | LLM Pulse |
| **Developer** | Zuuzii |
| **Platform** | macOS 14 or later; Apple Silicon and Intel |
| **Category** | Local AI coding task monitor and menu bar companion |
| **Current task scope** | Local root tasks created by Codex Desktop |
| **v2 target** | Claude Code with Qwen3.7, separated by model page |
| **Data model** | Local, read-only adapters; no task analytics service |
| **Network use** | GitHub Releases for optional update checks and downloads |
| **License** | MIT |
| **Affiliation** | Independent project; not an OpenAI product |

## Download

[Download the latest signed and notarized DMG](https://github.com/zuuzii-org/llm-pulse/releases/latest). The latest published build is **GPT Pulse v1.3.0**, released under the previous product name. It requires macOS 14 or later and ships as a Universal App for Apple Silicon and Intel Macs. **LLM Pulse v2.0.0 is the next planned release and has not been published yet.**

The legacy-branded v1.3.0 release assets are:

- `GPT-Pulse-1.3.0.dmg`
- `GPT-Pulse-1.3.0.dmg.sha256`

To verify the download, place both files in the same folder and run:

```bash
shasum -a 256 -c GPT-Pulse-1.3.0.dmg.sha256
```

If you are using v1.0.0, install v1.1.0 manually once. v1.0.0 did not include in-app updates, so it cannot discover the update channel. From v1.1.0 onward, right-click the menu bar item and choose `检查更新…` (“Check for Updates…”) to update in place.

## What LLM Pulse shows

- **A compact menu bar status.** The top number is the count of active tasks; the bottom number is the count of recently completed tasks. Waiting work turns the active indicator orange, while failures turn it red.
- **A full-height task sidebar.** Hold the pointer at the middle 60% of the current display’s right edge for about 200 ms. The 400 px panel opens on the display under the pointer and avoids internal seams between adjacent displays.
- **Collapsible task groups.** Running and recently completed sections can be folded independently. LLM Pulse remembers both choices between launches.
- **States that need attention.** Waiting for approval and waiting for an answer are prioritized. Failed and interrupted work remains clearly identified in the recent list.
- **Useful task context.** Each row shows the project, session, elapsed time, latest state, cumulative token use, and the active total for the main agent plus descendant agents.
- **Direct navigation.** Clicking a task opens its Codex Desktop task through `codex://threads/<thread-id>`. Opening a completed task from LLM Pulse marks it as viewed; manual and batch acknowledgement are also available.
- **Codex usage limits.** The sidebar shows the remaining percentage, reset time, and freshness for the 5-hour and weekly windows.
- **Native notifications.** Choose attention-only, important, or all recognizable states. Notifications support task actions, 15-minute or 1-hour snooze, quiet completion summaries, and usage-limit warnings.
- **Project controls.** Focus the panel on one Git project or mute that project’s notifications for an hour or until the next day. Menu bar totals remain global.
- **macOS behavior.** Launch at login, multiple displays, reduced-motion support, configurable edge triggering in full-screen apps, and an instant English/Simplified Chinese language switch are built in.

Recently completed tasks remain available for 24 hours, up to 20 items. Unviewed successful tasks receive retention priority, and a batch acknowledgement can be undone for six seconds.

## How it works

LLM Pulse combines a few narrow local adapters instead of treating any one private Codex file format as permanent:

1. The optional plugin writes minimized lifecycle events for timely running and approval-waiting updates.
2. Codex state SQLite databases are opened with read-only mode and SQLite `query_only` enabled.
3. Rollout JSONL is parsed for task state, timestamps, agent lifecycle, token summaries, and compatible usage-limit snapshots.
4. The bundled Codex App Server is queried locally with `account/rateLimits/read` for the same grouped 5-hour and weekly limits shown by Codex Desktop.
5. Viewed receipts and LLM Pulse preferences remain under the compatibility path `~/Library/Application Support/GPT Pulse/` so existing installations keep their state after the rename.

Only root tasks created by Codex Desktop appear as rows. Descendant agents are rolled into the active `Agent N` total of their root task rather than displayed as separate tasks. See [the architecture notes](docs/ARCHITECTURE.md) for state precedence, retention, quota selection, and adapter failure behavior.

## Privacy and network access

LLM Pulse is designed as a read-only observer:

- It does not write to Codex databases, rollouts, task records, or App Server state.
- It does not extract, retain, or upload prompts, tool input, tool output, or transcript content.
- The optional hook journal keeps only `session_id`, `turn_id`, the event name, and a timestamp. It does not record project paths.
- Viewed receipts, notification settings, and usage-warning deduplication keys stay on the Mac. Muted projects are stored as SHA-256 identifiers rather than plain-text paths.
- No OpenAI API key is required. LLM Pulse includes no task analytics or task-data upload service.

An optional update check reads the public release information hosted on GitHub. It does not attach Codex task data or a generated system profile. Normal task monitoring remains local.

## Install

1. Download the DMG and matching SHA-256 file from [GitHub Releases](https://github.com/zuuzii-org/llm-pulse/releases/latest).
2. Verify the checksum with the command above.
3. Open the current v1.3.0 DMG and drag the legacy-named `GPT Pulse.app` to `Applications`.
4. Launch the app from `Applications`. Notification permission is optional; local task monitoring works without it.
5. Enable launch at login in LLM Pulse settings if desired.

## In-app updates

The legacy GPT Pulse v1.1.0 release added in-app updates. Right-click the menu bar item and choose `检查更新…` to check the public GitHub Release feed and install a newer version.

v1.1.0 is the bootstrap release for this update channel. Users on v1.0.0 must download and install v1.1.0 manually once; later releases can update in place across the product and repository rename.

## Optional Codex plugin

The app works without the plugin by falling back to read-only SQLite and rollout JSONL. Installing the bundled lifecycle hooks improves the timeliness of running and approval-waiting states.

```bash
codex plugin marketplace add zuuzii-org/llm-pulse --ref v1.3.0
codex plugin add gpt-pulse@gpt-pulse
```

Review and trust the hooks when Codex asks. The plugin writes minimized events to:

```text
~/Library/Application Support/GPT Pulse/events/events.jsonl
```

The hooks depend only on `/bin/sh` and JXA included with macOS. They do not require Python, Node.js, or an external runtime.

## FAQ

### What is LLM Pulse?

LLM Pulse is a native macOS menu bar monitor for local Codex Desktop tasks. It summarizes task state and usage in a right-edge sidebar so you do not need to keep every task window open.

### How can I monitor multiple Codex Desktop tasks on macOS?

Run LLM Pulse alongside Codex Desktop. Its menu bar status summarizes active and recently completed work, while the right-edge sidebar lists each local root task with its state, project, elapsed time, token usage, and active agent total.

### Does LLM Pulse modify or control Codex tasks?

No. It reads Codex data and can open an existing task through a deep link, but it does not approve, answer, stop, retry, create, archive, or edit tasks.

### Does LLM Pulse upload prompts or task data?

No. Task monitoring stays on the Mac. LLM Pulse does not extract, retain, or upload prompts, tool input, tool output, or transcripts, and no OpenAI API key is required.

### Does it work without the Codex plugin?

Yes. The plugin is optional. Without it, LLM Pulse uses read-only SQLite and rollout JSONL; some running or approval-waiting transitions may appear later.

### Does it show subagents?

Subagents do not appear as separate rows. LLM Pulse aggregates the active main agent and all active descendants into the root task’s `Agent N` value. If local evidence is incomplete, it shows an unknown or stale value instead of inventing zero.

### What do the 5-hour and weekly numbers mean?

They are remaining percentages calculated from Codex’s reported used percentages, together with reset times. They are not absolute token balances. LLM Pulse keeps both windows from one complete snapshot rather than mixing values from different tasks.

### How does LLM Pulse read Codex usage limits?

It asks the bundled local Codex App Server for the same grouped 5-hour and weekly limits shown by Codex Desktop. Compatible local rollout data is used only as a fallback, and LLM Pulse never combines windows from unrelated snapshots.

### Can LLM Pulse open a task directly in Codex Desktop?

Yes. Clicking a row opens the matching task through a local `codex://threads/<thread-id>` link. If navigation fails, LLM Pulse keeps the task unread and reports the error instead of silently acknowledging it.

### Why is a viewed task still under recently completed?

“Viewed” clears the unread state; it does not delete the history row. Completed, failed, and interrupted tasks remain in the recent list for up to 24 hours, subject to the 20-item cap.

### Can v1.0.0 update itself?

No. Install v1.1.0 manually once to add the in-app update channel. From v1.1.0 onward, use the menu bar’s `检查更新…` command.

### Does LLM Pulse support Codex CLI, IDE tasks, cloud tasks, or other AI coding tools?

The currently published v1.3.0 release only supports root tasks created by Codex Desktop on the local Mac. Claude Code and Qwen3.7 support is planned for LLM Pulse v2.0.0; see the [v2 implementation plan](docs/LLM_PULSE_V2_PLAN.md). v2.0.0 has not been published yet.

### Is LLM Pulse an official OpenAI product?

No. LLM Pulse is an independent open-source project by Zuuzii and is not affiliated with, endorsed by, or maintained by OpenAI.

## Known limitations

- Codex local schemas, rollout events, and deep links are private compatibility surfaces and may change. Each adapter degrades independently when a source becomes unavailable.
- `codex://threads/<thread-id>` works with the Codex Desktop builds tested for this release but is not a documented stable contract.
- Opening a task directly inside Codex Desktop cannot be detected reliably. Open it from LLM Pulse or acknowledge it manually to clear its unread state.
- Codex hooks have no separate approval-resolved event. A task may remain in the approval-waiting state until the related tool emits `PostToolUse`.
- Usage-limit sources provide percentages and reset times, not a reliable absolute token allowance.
- App-generated interface text supports English and Simplified Chinese. User task titles, project paths, and raw Codex content remain unchanged.

## Build from source

Requirements: macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/zuuzii-org/llm-pulse.git
cd llm-pulse
make check
open ".build/DerivedData/Build/Products/Debug/LLM Pulse.app"
```

`make check` generates the Xcode project, runs the Swift and plugin test suites, and builds the Debug app without code signing. For Xcode development, run `make open` and use the `GPTPulse` scheme.

## License and attribution

LLM Pulse is released under the [MIT License](LICENSE). Product attribution belongs to **Zuuzii**.

LLM Pulse is an independent project. It is not affiliated with, endorsed by, or maintained by OpenAI. Product and company names are used only to describe compatibility.
