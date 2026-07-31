# Claude-Code-Proxy Token Monitor Tray

<img width="700" alt="image" src="https://github.com/user-attachments/assets/4ffdb5f4-9aad-40e2-a164-b3bc9d56244a" />

macOS **menu bar** app for SuperGrok usage, multi-account Grok login, DeepSeek balance + Activate, and optional local `claude-code-proxy` control.

| At a glance | |
| --- | --- |
| **Product name** | Claude-Code-Proxy Token Monitor Tray (`.app`) |
| **Repo / binary codename** | `gm-tray` / `GMTray` (legacy; not used for user data paths) |
| Menu bar (Grok active) | Grok mark + `weekly% / monthly%` (e.g. `88% / 59%`) |
| Menu bar (DeepSeek active) | Whale mark + prepaid balance (e.g. `$28`) |
| Panel | **Accordion**: expand Grok **or** DeepSeek (not both) |
| Poll | Every **20s** in background; every **5s** while the panel is open |
| Dock | **None** (`LSUIElement`) |

---

## Features (current)

### UI

- Fade in/out menu bar panel
- **Exclusive expand**: opening Grok collapses DeepSeek and vice versa
- **Single active method**: activating Grok inactivates DeepSeek Pro/Flash (and reverse); Pro ↔ Flash are exclusive
- Menu bar icon follows **live** `~/.claude/settings.json` (DeepSeek vs Grok proxy), not only CC Switch

### Grok

- Multi-account profiles under `~/.grok/profiles/`
- **Grok login** in Terminal (standard CLI; one browser Approve)
- **Activate** runs a **live billing API** check — re-login only on 401/403
- After a successful Activate, usage is **force-refreshed** (weekly + monthly)
- Optional SuperGrok **subscription renew** date (manual, per email)
- **Launch / Stop claude-code-proxy** only if the binary is installed (or port 18765 is already in use)

### DeepSeek

- **Self-contained config** (no CC Switch required for key or Activate)
- Enter API key, base URL, Pro/Flash model ids in the panel
- Stored under **Application Support** for this product name
- **Activate Pro / Flash** writes `~/.claude/settings.json` directly
- Defaults: `deepseek-v4-pro[1m]` / `deepseek-v4-flash[1m]` (consistent lowercase `[1m]`), base `https://api.deepseek.com/anthropic`

### Optional integration

- Still **reads** CC Switch for legacy Grok provider merge when present
- Does **not** require `ccs` for proxy launch/stop
- Does **not** require `claude-code-proxy` for Grok usage or Grok login

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

Look in the **menu bar** (top-right). Click the icon to open the panel.

If macOS blocks a local/ad-hoc build:

```bash
xattr -cr "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
open "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
```

| Action | How |
| --- | --- |
| Refresh usage | Panel **Refresh**, or open the tray (force refetch) |
| Quit | Panel **Quit** (`⌘Q`) |
| Start at login | Toggle **Launch at login** at the bottom of the panel |

### Menu bar label

| Live Claude method (`~/.claude/settings.json`) | Tray shows |
| --- | --- |
| Grok (e.g. base `http://127.0.0.1:18765`) | Grok mark + `weekly% / monthly%` |
| DeepSeek (base/model contains deepseek) | DeepSeek mark + balance |

---

## Grok section

Expand **Grok** (DeepSeek collapses automatically).

Typical order in the panel:

1. **Grok accounts** — list of saved emails + **Activate**
2. **Save current login as profile** (if the active login is not saved yet)
3. **Grok login**
4. **Launch / Stop claude-code-proxy** (only if installed / running)
5. **Weekly** / **Monthly** usage + subscription renew

### Multiple SuperGrok accounts

`grok login` keeps **one** active file: `~/.grok/auth.json`.  
Saved copies for switching: `~/.grok/profiles/<email>.json`.

**First-time multi-account setup**

1. **Grok login** as account A → Approve once in the browser  
2. Tray → **Save current login as profile** (if offered)  
3. **Grok login** as account B → Save again  
4. **Activate** the email you want  

Accounts are listed **A→Z by email**. Activating only moves the checkmark.

### Grok Activate

| Step | Behavior |
| --- | --- |
| Switch profile | Copies that profile onto `~/.grok/auth.json` and syncs proxy auth file if needed |
| Live check | `GET` SuperGrok billing/usage API with the active CLI token |
| **OK (2xx)** | Sync proxy auth, clear DeepSeek “active”, point Claude at Grok proxy, **restart proxy** if it was running (or start it if installed), **force-refresh** weekly/monthly |
| **401 / 403** | Tokens dead → stop proxy, prompt **Grok login** (no silent re-auth) |
| Network error | Switch files may still apply; message notes the check failed |

After success you should see something like:

```text
Active: you@gmail.com · usage refreshed · weekly 42% / monthly …
```

### Grok login

Always available (does **not** require `claude-code-proxy`).

| Behavior | Detail |
| --- | --- |
| Flow | Terminal opens → optional target email (Enter = any) → **one** `grok login --device-auth` Approve |
| Fallback | If device helpers are missing → plain `grok login` |
| First login | No local `auth.json` → **no** forced accounts.x.ai logout |
| After success | Saves `~/.grok/profiles/<email>.json`; syncs proxy auth **only if** `claude-code-proxy` is installed |
| Wrong-account check | Only if you typed a target email; exit 42 and skip save if mismatch |

**Not** two device codes anymore (proxy auth + CLI used to each need Approve).  
CLI login + profile save/sync is enough for both tray usage and the proxy.

Optional: `GROK_OAUTH_CLEAN=1` for an empty Chrome profile (rarely needed).

### Claude Code on Grok (proxy)

| Control | When shown | Action |
| --- | --- | --- |
| **Launch claude-code-proxy** | Binary installed | Sync active `~/.grok/auth.json` → `~/.config/claude-code-proxy/grok/auth.json`, then `serve --no-monitor` on **:18765** |
| **Stop claude-code-proxy** | Binary installed **or** port already open | Stop listeners on **:18765** |

Launch does **not** open a browser. Use **Grok login** when tokens expire or you need another SuperGrok identity.

```bash
brew install claude-code-proxy   # optional
```

Restart Claude Code after changing the active method (Grok ↔ DeepSeek).

### Weekly vs monthly

| Metric | Meaning |
| --- | --- |
| Weekly % | SuperGrok shared weekly pool (usually what blocks you) |
| Monthly % | Calendar-month window from the CLI billing API |
| Period ends | End of that API monthly window — **not** card renew day |

### SuperGrok subscription renew (manual)

Real renew day is on **grok.com → Billing**, not in the CLI API.

1. Expand Grok → monthly area → **Next renew**  
2. **Update** → `yyyy-MM-dd` → **Save**  
3. **Clear** removes the date for the **current** email only  

Stored **per Grok email**. After the day passes, next renew is advanced by one month at a time.

---

## DeepSeek section

Expand **DeepSeek** (Grok collapses automatically).

### Local config (no CC Switch)

| Field / action | Purpose |
| --- | --- |
| **API key** | DeepSeek `sk-…` |
| **Base URL** | Claude Code Anthropic-compatible base (default `https://api.deepseek.com/anthropic`) |
| **Pro / Flash model** | Defaults `deepseek-v4-pro[1m]` / `deepseek-v4-flash[1m]` (both lowercase `[1m]`) |
| **Save DeepSeek config** | Writes Application Support config (0600) |
| **Activate Pro / Flash** | Writes `~/.claude/settings.json`; **inactivates** the other DeepSeek variant and Grok; **stops** proxy if running |

Config path:

```text
~/Library/Application Support/Claude-Code-Proxy Token Monitor Tray/deepseek.json
```

Legacy path `~/.grok/deepseek.json` (if any) is migrated once into Application Support.

Balance: `GET https://api.deepseek.com/user/balance` using the local key (then env / Claude settings; CC Switch key only as last-resort read).

---

## Mutual exclusion (methods)

Only **one** method shows as active in the UI:

| You activate | Becomes inactive |
| --- | --- |
| Grok account | DeepSeek Pro **and** Flash; Claude pointed at Grok proxy |
| DeepSeek Pro | DeepSeek Flash + all Grok account checkmarks; proxy stopped |
| DeepSeek Flash | DeepSeek Pro + Grok; proxy stopped |

Grok “active” = that profile is the CLI login **and** Claude settings look like Grok.  
DeepSeek “active” = that variant is selected **and** Claude settings look like DeepSeek.

---

## Data locations

| Path | Role |
| --- | --- |
| `~/.grok/auth.json` | Active Grok CLI session (usage + Activate live check) |
| `~/.grok/profiles/*.json` | Saved Grok logins for multi-account Activate |
| `~/.config/claude-code-proxy/grok/auth.json` | Proxy upstream Grok tokens (synced from CLI auth when proxy is used) |
| `~/Library/Application Support/Claude-Code-Proxy Token Monitor Tray/deepseek.json` | DeepSeek API key + models + active variant |
| `~/.claude/settings.json` | Live Claude Code env (**written** on Grok/DeepSeek Activate) |
| `~/.cc-switch/*` | Optional legacy read/write for some Grok CC Switch provider merges |
| UserDefaults | Per-email SuperGrok renew anchors, launch-at-login |
| `~/Library/Logs/ClaudeCodeProxyTokenMonitorTray/` | Login helpers, proxy log |

Clearing Grok auth for a full retry (example):

```bash
rm -f ~/.grok/auth.json ~/.grok/auth.json.lock
rm -f ~/.grok/profiles/*.json
rm -f ~/.config/claude-code-proxy/grok/auth.json \
      ~/.config/claude-code-proxy/grok/auth.backup.json
```

---

## Install

### Build from source

```bash
xcode-select -p || xcode-select --install
cd /path/to/gm-tray
./Scripts/build-app.sh
# → ~/Applications/Claude-Code-Proxy Token Monitor Tray.app
#    + ~/.local/bin/gm-tray launcher (legacy script name)
open "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
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
ditto -c -k --sequesterRsrc --keepParent \
  "Claude-Code-Proxy Token Monitor Tray.app" \
  ~/Desktop/Claude-Code-Proxy-Token-Monitor-Tray.zip
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
| Grok usage / multi-account | `grok` CLI (`grok login`) |
| DeepSeek balance / Activate | Tray-local API key (or `DEEPSEEK_API_KEY`) |
| Claude method switch | Writes `~/.claude/settings.json` |
| Launch proxy | Optional: `brew install claude-code-proxy` |

---

## Related CLI tools (optional)

```bash
gm              # Grok weekly + monthly (terminal)
ds              # DeepSeek balance (terminal)
ccs             # CC Switch from the terminal
```

The tray does not require `ccs` for proxy launch/stop or DeepSeek Activate.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| No icon in menu bar | `pgrep -x GMTray`; check menu bar overflow `»` |
| Grok shows `!` or empty | **Grok login**, then open panel / Refresh |
| Wrong Grok usage after switch | **Activate** that email (forces usage refetch); ensure proxy restarted if you use it |
| Activate says auth failed (401/403) | **Grok login** for that SuperGrok Google account, then Activate again |
| Login Approves as the wrong SuperGrok user | Sign out of **accounts.x.ai** in Chrome (xAI session cookie ≠ Google myaccount), then Approve again |
| DeepSeek no key / balance error | Expand DeepSeek → enter key → **Save** → Refresh |
| DeepSeek Activate did nothing in Claude | Restart Claude Code |
| Launch proxy missing | Normal if `claude-code-proxy` is not installed; install via Homebrew to show the button |
| Proxy Launch fails | Install binary; check `~/Library/Logs/ClaudeCodeProxyTokenMonitorTray/claude-code-proxy.log` |
| App blocked / “cannot open” | `xattr -cr "$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"` then open again |
| Still no process | `open` the `.app` or run `…/Contents/MacOS/GMTray` |

---

## Project layout

```text
Sources/GMTray/
  GMTrayApp.swift               Menu bar entry
  ContentView.swift             Panel UI (accordion Grok / DeepSeek)
  UsageViewModel.swift          Poll, Activate, login script, proxy, DeepSeek drafts
  UsageService.swift            Grok billing APIs + live auth probe
  DeepSeekService.swift         Balance API
  DeepSeekConfigStore.swift     Local DeepSeek config + Activate (Application Support)
  GrokAccountStore.swift        ~/.grok/auth.json + profiles + proxy auth sync
  CCSwitchService.swift         Optional CC Switch read/write (legacy / Grok provider)
  SubscriptionRenewStore.swift  Per-email manual renew dates
  LoginItemService.swift        Launch at login
  PanelWindowFade.swift         Panel fade in/out
  GrokIcon / DeepSeekIcon / MenuBarLabelImage
  Resources/                    Icons
Scripts/build-app.sh            Release → .app (LSUIElement)
```

---

## Version notes (behavior summary)

Recent product behavior this README documents:

- Grok multi-account Activate with **live API** expiry detection  
- **Force usage refresh** after account switch  
- **Single** Grok device-code Approve; proxy auth synced from CLI when proxy exists  
- Grok login **without** requiring `claude-code-proxy`  
- Proxy Launch/Stop **hidden** when the binary is absent  
- DeepSeek **local** key/models + Activate (Application Support path)  
- **Mutual exclusive** active method (Grok ↔ DeepSeek, Pro ↔ Flash)  
- Panel **accordion** expand (one of Grok / DeepSeek open at a time)  
- Consistent DeepSeek model tags `[1m]` (not mixed `1M`)  
