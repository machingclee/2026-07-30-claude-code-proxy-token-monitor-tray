# Claude-Code-Proxy Token Monitor Tray

<img width="500" alt="image" src="https://github.com/user-attachments/assets/18ac0392-4fa2-4eeb-9d8e-18f9ab7319f7" />


macOS menu bar tray for Grok / DeepSeek token usage, Claude provider activate, and local `claude-code-proxy` control.

**Companion to CC Switch** — this tray **reads provider data from CC Switch** (`~/.cc-switch/cc-switch.db` and related settings). It does not re-enter API keys in the tray UI: providers, DeepSeek keys, and Activate targets come from what you already configured in CC Switch / `ccs`.

| At a glance | |
| --- | --- |
| Menu bar (Grok) | Icon + `weekly% / monthly%` (e.g. `88% / 59%`) |
| Menu bar (DeepSeek) | Whale icon + prepaid balance (e.g. `$28`) |
| Panel | Expand Grok / DeepSeek rows for detail and actions |
| Poll | Every **20s** in background; every **5s** while the panel is open |
| Config source | **CC Switch** providers + keys; Grok CLI auth from **`grok login`** |

No separate secret store in this app: DeepSeek keys and Claude provider definitions are **read from CC Switch**; Grok usage uses **`grok login`** (`~/.grok/auth.json`).

---

## How to use

### Launch

```bash
open "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
# or (after build installs the helper)
gm-tray
# or system-wide install
open "/Applications/Claude-Code-Proxy Token Monitor Tray.app"
```

Look in the **menu bar** (top-right). There is **no Dock icon**. Click the icon to open the panel (fades in/out).

If macOS says the app can’t be opened (local/ad-hoc build):

```bash
xattr -cr "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
open "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
```

| Action | How |
| --- | --- |
| Refresh usage | Panel **Refresh**, or click the tray icon (refetch on open) |
| Quit | Panel **Quit** (`⌘Q`) |
| Start at login | Toggle **Launch at login** at the bottom of the panel |

### Menu bar label

| Active Claude provider (CC Switch) | Tray shows |
| --- | --- |
| Grok | Grok mark + `weekly% / monthly%` |
| DeepSeek | DeepSeek mark + balance |

“Active provider” means the one currently written into `~/.claude/settings.json` (same as CC Switch / `ccs`).

### Grok section (expand the Grok row)

Order inside the expanded panel:

1. **Grok accounts** — **Activate** per email (that CLI login + CC Switch Grok provider, like DeepSeek Pro/Flash)  
2. **Save current login as profile** — only if this login is not already saved  
3. **Launch / Stop claude-code-proxy** (port `18765`)  
4. **Weekly** / **Monthly** usage + subscription renew

#### Multiple Grok accounts

`grok login` only keeps **one** active file: `~/.grok/auth.json`. Profiles live in `~/.grok/profiles/`.

**First time setup (order matters):**

1. With account A logged in: open tray → Grok → **Save current login as profile**  
2. In Terminal: `grok login` as account B  
3. Tray → **Save current login as profile** again  
4. Use **Activate** next to a profile to use that CLI login and set Grok as Claude’s provider  

Accounts are listed **A→Z by email**. Activating only moves the checkmark; order stays alphabetical.

After activating another account, usage refetches. If Claude still uses the old Grok identity, **Stop** then **Launch** `claude-code-proxy`, and restart Claude Code.

#### Weekly vs monthly numbers

| Metric | Meaning |
| --- | --- |
| Weekly % | Shared SuperGrok weekly pool (what usually blocks you) |
| Monthly % | Calendar-month usage window from the CLI billing API (e.g. 1st → 1st) |
| Period ends | End of that API monthly window — **not** SuperGrok card renew day |

#### SuperGrok subscription renew (manual)

The real renew date (e.g. 19 Aug if you subscribed on 19 Jul) is on **grok.com → Billing**, not in the CLI API.

1. Expand Grok → monthly area → **Next renew** row  
2. Click **Update** (right side)  
3. Enter `yyyy-MM-dd` (e.g. `2026-08-19`) → **Save**  
4. **Clear** removes the date for the **current** account only  

Dates are stored **per Grok email**. After the day passes, the next renew is computed by adding one month at a time.

#### Claude Code on Grok (proxy)

| Button | Action |
| --- | --- |
| **Activate** (per Grok account) | That CLI login → `~/.grok/auth.json` **and** proxy auth → `~/.config/claude-code-proxy/grok/auth.json`, plus CC Switch Grok provider |
| **Grok login (browser)** | Opens Terminal for `claude-code-proxy grok auth login` (and optional `grok login`) — use on **402** / expired tokens |
| **Launch claude-code-proxy** | Syncs tray Grok auth into the proxy auth file, then `claude-code-proxy serve --no-monitor` |
| **Stop claude-code-proxy** | Shown when something is listening on **:18765**; stops those PIDs |

**Why no browser popup on Launch?** `ccs grok-launch` always ran `grok login` in a new Terminal (browser every time). The tray Launch only **starts the server** and **syncs** the already-selected account into the proxy auth file. Use **Grok login (browser)** when you need a fresh OAuth page. **402 Grok upstream** usually means wrong/expired proxy auth or that SuperGrok account is out of quota — Activate the right account, re-login if needed, restart proxy.

Install proxy if needed:

```bash
brew install claude-code-proxy
```

Restart Claude Code after **Activate**.

### DeepSeek section (expand the DeepSeek row)

- **DeepSeek model** — **Activate** among CC Switch DeepSeek providers (e.g. **Pro** vs **Flash**); same merge as CC Switch / `ccs`  

- Shows prepaid balance from `GET https://api.deepseek.com/user/balance`  
- Key is read from the DeepSeek provider(s) in CC Switch (or env / live Claude settings if already on DeepSeek)  


### Data locations (companion model)

This app is a **read/write companion** to CC Switch — it does not replace it.

| Path | Role |
| --- | --- |
| `~/.cc-switch/cc-switch.db` | **Read** (and update on Activate): Claude providers, which is active, DeepSeek API key |
| `~/.cc-switch/settings.json` | CC Switch app settings (if present) |
| `~/.claude/settings.json` | Live Claude Code env (**written** when you **Activate** a provider) |
| `~/.grok/auth.json` | Active Grok CLI login (usage token; not from CC Switch) |
| `~/.grok/profiles/*.json` | Saved Grok logins for multi-account switch in the tray |
| UserDefaults | Per-email SuperGrok renew anchors, launch-at-login |

Different Mac users each use their own `$HOME`; the tray always uses the standard CC Switch path under that home (no custom DB path UI).

---

## Install

### Build from source

```bash
xcode-select -p || xcode-select --install
cd /path/to/gm-tray
./Scripts/build-app.sh
# → ~/Applications/Claude-Code-Proxy Token Monitor Tray.app
#    + ~/.local/bin/gm-tray launcher
open "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
# or: gm-tray
```

System-wide:

```bash
./Scripts/build-app.sh "/Applications"
open "/Applications/Claude-Code-Proxy Token Monitor Tray.app"
```

### Share a prebuilt zip

```bash
./Scripts/build-app.sh
cd ~/Applications
ditto -c -k --sequesterRsrc --keepParent "Claude-Code-Proxy Token Monitor Tray.app" ~/Desktop/Claude-Code-Proxy-Token-Monitor-Tray.zip
```

Recipient: unzip → Applications → open (if blocked: right-click Open, or `xattr -dr com.apple.quarantine` on the app). Apple Silicon builds are arm64; Intel Macs should rebuild from source.

### Dev run (no `.app`)

```bash
cd /path/to/gm-tray
swift run GMTray
```

Login items work best from an installed `.app`, not bare `swift run`.

### Requirements

| Item | Notes |
| --- | --- |
| macOS 13+ | MenuBarExtra |
| Grok usage | `grok login` |
| DeepSeek balance | DeepSeek provider **in CC Switch** (tray reads the key from `cc-switch.db`; or key in env / Claude settings) |
| Activate Claude provider | Providers defined in CC Switch (`~/.cc-switch`) — tray reads them, then writes `~/.claude/settings.json` |
| Launch proxy | `brew install claude-code-proxy` |

---

## Related CLI tools (optional)

```bash
gm              # Grok weekly + monthly
ds              # DeepSeek balance
ccs             # switch Claude providers from the terminal
ccs gm / ccs ds
```

The tray does not require `ccs` for proxy launch/stop; it calls `claude-code-proxy` directly.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| No icon in menu bar | `pgrep -x GMTray`; check menu bar overflow `»` |
| Grok shows `!` or empty | `grok login`, then Refresh |
| Wrong Grok usage after account change | Confirm profile **Activate**; restart proxy if needed |
| DeepSeek error | Add DeepSeek provider in CC Switch with API key |
| Activate did nothing in Claude | Restart Claude Code |
| Proxy Launch fails | Install `claude-code-proxy` via Homebrew; check `~/Library/Logs/ClaudeCodeProxyTokenMonitorTray/claude-code-proxy.log` |
| App blocked / “cannot open” | `xattr -cr "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"` then `open` again; or right-click → Open |
| Still no process | `open "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"` or run the binary: `"$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app/Contents/MacOS/GMTray"` |

---

## Project layout

```text
Sources/GMTray/
  GMTrayApp.swift              Menu bar label (icon + weekly/monthly)
  ContentView.swift            Panel UI
  UsageViewModel.swift         Poll, activate, proxy, accounts
  UsageService.swift           Grok billing APIs
  DeepSeekService.swift        Balance API
  CCSwitchService.swift        Read/write CC Switch + settings.json
  GrokAccountStore.swift       ~/.grok/profiles multi-login
  SubscriptionRenewStore.swift Per-email manual renew dates
  LoginItemService.swift       Launch at login
  PanelWindowFade.swift        Panel fade in/out
  GrokIcon / DeepSeekIcon / MenuBarLabelImage
  Resources/                   Vector icons
Scripts/build-app.sh           Release → .app (LSUIElement)
```
