#!/bin/zsh
# Fix macOS 26 (Tahoe) menu bar blocking for Claude-Code-Proxy Token Monitor Tray.
# Needs Terminal with Full Disk Access if the plist is protected.
#
# Usage:
#   ./Scripts/fix-tahoe-menu-bar.sh           # patch allow-list + relaunch
#   ./Scripts/fix-tahoe-menu-bar.sh --nuke    # delete trackedApplications (GUI reset alternative)

set -euo pipefail

BUNDLE_ID="com.chingcheonglee.token-monitor-tray"
LEGACY_BUNDLE="com.local.claude-code-proxy-token-monitor-tray"
APP_NAME="Claude-Code-Proxy Token Monitor Tray"
APP_PATH="${HOME}/Applications/${APP_NAME}.app"
CC_PLIST="${HOME}/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
NUKE="${1:-}"

echo "==> Bundle: ${BUNDLE_ID}"

echo "==> Clearing app-local NSStatusItem VisibleCC flags…"
python3 - <<'PY' "${BUNDLE_ID}"
import subprocess, sys
bid = sys.argv[1]
try:
    out = subprocess.check_output(["defaults", "read", bid], text=True, stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    sys.exit(0)
for line in out.splitlines():
    line = line.strip()
    if "NSStatusItem VisibleCC Item-" in line:
        key = line.split("=")[0].strip()
        subprocess.run(["defaults", "delete", bid, key], stderr=subprocess.DEVNULL)
PY
for bid in "${LEGACY_BUNDLE}" "${BUNDLE_ID}"; do
  defaults read "${bid}" 2>/dev/null | rg -o 'NSStatusItem VisibleCC Item-[0-9]+' 2>/dev/null | while read -r key; do
    defaults delete "${bid}" "${key}" 2>/dev/null || true
  done
done

if [[ ! -f "${CC_PLIST}" ]]; then
  echo "ERROR: Cannot read Control Center plist:" >&2
  echo "  ${CC_PLIST}" >&2
  echo "Grant Terminal → Privacy & Security → Full Disk Access, then re-run." >&2
  exit 1
fi

BACKUP="/tmp/group.com.apple.controlcenter-$(date +%Y%m%d-%H%M%S).plist"
cp "${CC_PLIST}" "${BACKUP}"
echo "==> Backup: ${BACKUP}"

PATCHED="/tmp/group.com.apple.controlcenter-patched.plist"
python3 - <<'PY' "${BUNDLE_ID}" "${CC_PLIST}" "${PATCHED}" "${NUKE}"
import plistlib, shutil, sys, os

TARGET = sys.argv[1]
src = sys.argv[2]
dst = sys.argv[3]
nuke = sys.argv[4] == "--nuke"

with open(src, "rb") as f:
    data = plistlib.load(f)

if nuke:
    if "trackedApplications" in data:
        del data["trackedApplications"]
        print("Removed entire trackedApplications (Control Center will rebuild).")
    else:
        print("No trackedApplications key — nothing to nuke.")
else:
    raw = data.get("trackedApplications")
    if raw is None:
        print("No trackedApplications — skip patch")
    else:
        inner = plistlib.loads(raw) if isinstance(raw, bytes) else raw
        changed = 0

        def bundle_id(obj):
            if not isinstance(obj, dict):
                return None
            if "_0" in obj and isinstance(obj["_0"], str):
                return obj["_0"]
            b = obj.get("bundle")
            if isinstance(b, dict):
                return b.get("_0")
            return None

        def entry_bundle(entry):
            if not isinstance(entry, dict):
                return None
            for key in ("location", "bundle"):
                if key in entry:
                    return bundle_id(entry[key])
            mil = entry.get("menuItemLocations")
            if isinstance(mil, list) and mil:
                return bundle_id(mil[0])
            return None

        def walk(entries):
            global changed
            if not isinstance(entries, list):
                return
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                owner = entry_bundle(entry)
                if owner == TARGET and entry.get("isAllowed") is not True:
                    entry["isAllowed"] = True
                    changed += 1
                    print(f"Set isAllowed=true for {TARGET}")
                mil = entry.get("menuItemLocations")
                if isinstance(mil, list) and owner and owner != TARGET:
                    new_mil = [
                        x for x in mil
                        if not (isinstance(x, dict) and bundle_id(x.get("bundle", x)) == TARGET)
                    ]
                    if len(new_mil) != len(mil):
                        entry["menuItemLocations"] = new_mil
                        changed += 1
                        print(f"Removed orphan {TARGET} from {owner}'s menuItemLocations")

        walk(inner)

        if isinstance(inner, list):
            i = 0
            while i < len(inner):
                walk([inner[i]])
                i += 1

        if changed:
            data["trackedApplications"] = plistlib.dumps(inner, fmt=plistlib.FMT_BINARY)
            print(f"Patched trackedApplications ({changed} change(s)).")
        else:
            print("trackedApplications unchanged (toggle app OFF/ON in Settings, or run with --nuke).")

with open(dst, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
shutil.copy(dst, src)
os.chmod(src, 0o644)
PY

echo "==> Restarting preference daemon + Control Center…"
killall cfprefsd 2>/dev/null || true
sleep 1
killall ControlCenter 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true
sleep 2

killall TokenMonitorTray 2>/dev/null || true
sleep 1
echo "==> Relaunch: ${APP_PATH}"
open "${APP_PATH}"
sleep 2
if pid=$(pgrep -x TokenMonitorTray); then
  echo "==> Running pid=${pid}"
  echo "    Panel without icon: token-monitor-tray --panel"
else
  echo "==> App did not stay running — check launch.log"
fi
