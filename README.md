# GM Tray

macOS **menu bar** companion for [CC Switch](https://github.com/) + Grok / DeepSeek usage.

| Feature | Detail |
| --- | --- |
| Menu bar | Icon follows **active** Claude provider (Grok mark or DeepSeek whale) + usage label |
| Panel | Activate a CC Switch provider → writes `~/.claude/settings.json` |
| Grok | Weekly / monthly quota (same APIs as `gm`) |
| DeepSeek | Prepaid balance (same API as `ds`) |
| Poll | Every **20s** in the background (menu bar); every **5s** while the panel is open; click refetches immediately |

No separate key store. Providers and DeepSeek keys come from **CC Switch**; Grok auth from **`grok login`**.

---

## How people install it

### Option A — Prebuilt `.app` (easiest)

Someone who already built the app can send you a zip:

1. Unzip **GM-Tray.zip**
2. Drag **GM Tray.app** into **Applications** (or **~/Applications**)
3. Open it (first time on macOS Gatekeeper):

   - **Right-click → Open → Open**, or  
   - Terminal:

     ```bash
     xattr -dr com.apple.quarantine "/Applications/GM Tray.app"
     open "/Applications/GM Tray.app"
     ```

4. Look in the **menu bar** (top-right). There is **no Dock icon**.

> Prebuilt builds from Apple Silicon are **arm64**. On Intel Macs, use **Option B** and build on that machine.

**Packaging a zip (for the person sharing):**

```bash
cd /path/to/gm-tray
./Scripts/build-app.sh
cd ~/Applications
ditto -c -k --sequesterRsrc --keepParent "GM Tray.app" ~/Desktop/GM-Tray.zip
```

### Option B — Build from source (any Mac with Xcode tools)

```bash
# 1) Xcode Command Line Tools (once)
xcode-select -p || xcode-select --install

# 2) Get the project (clone or copy the folder)
cd /path/to/gm-tray

# 3) Build + install
./Scripts/build-app.sh
# → ~/Applications/GM Tray.app
#
# system-wide instead:
# ./Scripts/build-app.sh "/Applications"

# 4) Launch
open ~/Applications/GM\ Tray.app
```

### Option C — Dev run (no `.app` bundle)

```bash
cd /path/to/gm-tray
swift run GMTray
```

### Requirements

| Item | Notes |
| --- | --- |
| macOS 13+ | MenuBarExtra |
| Network | `cli-chat-proxy.grok.com`, `api.deepseek.com` |
| Grok usage | `grok login` → `~/.grok/auth.json` |
| Provider switch / DeepSeek key | [CC Switch](https://github.com/) installed and used at least once (see below) |
| Build from source | Xcode or Command Line Tools |

### Launch later

| Method | Action |
| --- | --- |
| Finder | Double-click **GM Tray.app** |
| Terminal | `open ~/Applications/GM\ Tray.app` |
| Spotlight | `⌘Space` → **GM Tray** |
| Login item | System Settings → General → Login Items → add **GM Tray.app** |

Quit from the panel (**Quit** / `⌘Q`), or:

```bash
pkill -f "GM Tray.app/Contents/MacOS/GMTray"
```

---

## Where CC Switch data lives (important)

The tray does **not** search the disk for CC Switch. It uses the **same fixed layout** as the official CC Switch app and the `ccs` CLI.

### Paths (always under the **current user’s** home)

| Path | Role |
| --- | --- |
| `~/.cc-switch/cc-switch.db` | Claude providers, keys in provider `settings_config`, `is_current` |
| `~/.cc-switch/settings.json` | `currentProviderClaude` id |
| `~/.cc-switch/backups/` | Pre-activate backups of Claude settings |
| `~/.claude/settings.json` | Live Claude Code settings (**written on Activate**) |
| `~/.grok/auth.json` | Grok usage token from `grok login` (not from CC Switch) |

`~` means **`$HOME` for whoever is logged in**. Different people on different Macs (or accounts) each get their own data automatically:

| User | Home | CC Switch DB the tray opens |
| --- | --- | --- |
| Alice | `/Users/alice` | `/Users/alice/.cc-switch/cc-switch.db` |
| Bob | `/Users/bob` | `/Users/bob/.cc-switch/cc-switch.db` |

### What this means

- Installing **CC Switch.app** under `/Applications` vs elsewhere does **not** change the data path — config is always under `~/.cc-switch`, not inside the `.app`.
- The tray does **not** store its own copy of providers or API keys.
- **Activate** = same merge as `ccs` / CC Switch:  
  `common_config_claude` + provider config → `~/.claude/settings.json`, then mark provider current in the DB.
- Custom / relocated CC Switch data directories are **not** supported (same limitation as `ccs` today).
- If `~/.cc-switch/cc-switch.db` is missing, provider list / Activate / DeepSeek key discovery from CC Switch will fail until that user has run CC Switch (or equivalent).

### Menu bar icon vs active provider

| Active Claude provider (CC Switch) | Tray icon | Label example |
| --- | --- | --- |
| Grok | Grok mark | `62%` (weekly) |
| DeepSeek | DeepSeek whale | `$28` (balance) |

---

## Behavior (quick reference)

| Action | What happens |
| --- | --- |
| App launches | Prefetch Grok + DeepSeek; icon = active provider; background poll every 20s |
| Click icon | Open panel + refetch |
| Panel open | Poll every 5s (background 20s tick skips while open) |
| **Activate** | Write `~/.claude/settings.json` from that CC Switch provider; update tray icon |
| After Activate | **Restart Claude Code** so it picks up the new env |
| Refresh / `⌘R` | Manual refetch |
| **Launch at login** | Toggle in the panel (macOS Login Items via SMAppService) |
| Quit / `⌘Q` | Exit |

---

## Related CLI tools (optional)

These are separate scripts under `~/.local/bin` on machines that have them; the tray does not require them:

```bash
gm              # Grok weekly + monthly
ds              # DeepSeek balance
ccs             # switch providers from the terminal
ccs gm / ccs ds
```

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| “App is damaged” / blocked | Right-click → Open, or `xattr -dr com.apple.quarantine "/path/to/GM Tray.app"` |
| No icon in menu bar | `pgrep -lf GMTray`; check menu bar overflow `»` |
| Grok shows `!` | Run `grok login`, then Refresh |
| No providers / DeepSeek error | Install & open **CC Switch**, add a DeepSeek provider; confirm `~/.cc-switch/cc-switch.db` exists |
| Activate did nothing in Claude | Restart Claude Code / start a new session |
| Intel Mac + prebuilt zip fails | Build from source on that Mac (`./Scripts/build-app.sh`) |
| After code update | `./Scripts/build-app.sh` then reopen the app |

---

## Project layout

```
Sources/GMTray/
  GMTrayApp.swift         MenuBarExtra (icon = active provider)
  ContentView.swift       panel: Activate + usage
  UsageViewModel.swift    refresh + 20s background / 5s panel poll + activate
  CCSwitchService.swift   read/write ~/.cc-switch + settings.json
  UsageService.swift      Grok billing (gm-compatible)
  DeepSeekService.swift   DeepSeek balance (ds-compatible)
  GrokIcon.swift / DeepSeekIcon.swift
  Resources/              vector icons (PDF/PNG/SVG)
Scripts/build-app.sh      release → .app (LSUIElement)
```
