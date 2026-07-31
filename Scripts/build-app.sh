#!/usr/bin/env bash
# Build TokenMonitorTray into a proper macOS .app (menu bar only, no Dock).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Claude-Code-Proxy Token Monitor Tray"
PRODUCT="TokenMonitorTray"
BUNDLE_ID="com.local.claude-code-proxy-token-monitor-tray"
BUILD_DIR="${ROOT}/.build"
APP_DIR="${1:-$HOME/Applications}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "==> Building ${PRODUCT} (release)…"
cd "$ROOT"
swift build -c release --product "${PRODUCT}"

BIN="${BUILD_DIR}/release/${PRODUCT}"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "${BUILD_DIR}/release" -maxdepth 3 -type f -name "${PRODUCT}" -perm +111 | head -1)"
fi
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found (${PRODUCT})" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}"
# Kill any running instance so we can replace the binary
killall "${PRODUCT}" 2>/dev/null || true
killall GMTray 2>/dev/null || true   # pre-rename process name
sleep 0.2

rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

# Copy binary (do NOT codesign the naked binary first — that leaves a
# linker-signed signature which breaks .app sealed resources).
cp "${BIN}" "${MACOS}/${PRODUCT}"
chmod +x "${MACOS}/${PRODUCT}"

# Flatten resource files into Contents/Resources only.
# Do NOT ship SPM's TokenMonitorTray_TokenMonitorTray.bundle as a nested .bundle:
# it has no Info.plist, is not a real bundle, and breaks codesign --deep
# ("bundle format unrecognized" / "code has no resources…").
# Runtime icon loading uses Bundle.main.url(forResource:) against Resources/.
if [[ -d "${ROOT}/Sources/TokenMonitorTray/Resources" ]]; then
  cp -f "${ROOT}/Sources/TokenMonitorTray/Resources/"GrokIcon* "${RESOURCES}/" 2>/dev/null || true
  cp -f "${ROOT}/Sources/TokenMonitorTray/Resources/"DeepSeekIcon* "${RESOURCES}/" 2>/dev/null || true
fi

# Also pull any SPM-copied resources (in case Sources path missed something)
BUNDLE_SRC=""
for cand in \
  "${BUILD_DIR}/release/TokenMonitorTray_TokenMonitorTray.bundle" \
  "${BUILD_DIR}/arm64-apple-macosx/release/TokenMonitorTray_TokenMonitorTray.bundle" \
  "${BUILD_DIR}/x86_64-apple-macosx/release/TokenMonitorTray_TokenMonitorTray.bundle"
do
  if [[ -d "$cand" ]]; then
    BUNDLE_SRC="$cand"
    break
  fi
done
if [[ -z "${BUNDLE_SRC}" ]]; then
  BUNDLE_SRC="$(find "${BUILD_DIR}" -type d -name 'TokenMonitorTray_TokenMonitorTray.bundle' 2>/dev/null | head -1 || true)"
fi
if [[ -n "${BUNDLE_SRC}" && -d "${BUNDLE_SRC}" ]]; then
  echo "==> Flattening icons from ${BUNDLE_SRC} → Contents/Resources"
  find "${BUNDLE_SRC}" -maxdepth 2 -type f \( -name 'GrokIcon*' -o -name 'DeepSeekIcon*' \) \
    -exec cp -f {} "${RESOURCES}/" \;
fi

if [[ -f "${RESOURCES}/GrokIcon@2x.png" ]] || [[ -f "${RESOURCES}/GrokIcon44.png" ]]; then
  if command -v sips >/dev/null && command -v iconutil >/dev/null; then
    ICONSET="${BUILD_DIR}/AppIcon.iconset"
    rm -rf "${ICONSET}"
    mkdir -p "${ICONSET}"
    SRC_ICON="${ROOT}/Sources/TokenMonitorTray/Resources/GrokIcon44.png"
    [[ -f "$SRC_ICON" ]] || SRC_ICON="${ROOT}/Sources/TokenMonitorTray/Resources/GrokIcon@2x.png"
    for sz in 16 32 128 256 512; do
      sips -z "$sz" "$sz" "$SRC_ICON" --out "${ICONSET}/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
      dsz=$((sz * 2))
      sips -z "$dsz" "$dsz" "$SRC_ICON" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "${ICONSET}" -o "${RESOURCES}/AppIcon.icns" 2>/dev/null || true
  fi
fi

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${PRODUCT}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.3</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
</dict>
</plist>
PLIST

# PkgInfo is optional but helps Launch Services identify APPL packages.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Clear quarantine attributes (common cause of "cannot open" for local builds)
if command -v xattr >/dev/null; then
  xattr -cr "${APP_DIR}" 2>/dev/null || true
fi

if command -v codesign >/dev/null; then
  echo "==> codesign (ad-hoc, app bundle)"
  # Strip any residual linker signature from the binary before bundle sign
  codesign --remove-signature "${MACOS}/${PRODUCT}" 2>/dev/null || true
  # Sign the whole .app once. No nested .bundles → sealed Resources works.
  codesign --force --sign - --timestamp=none "${APP_DIR}"
  echo "==> codesign verify"
  if codesign --verify --deep --strict --verbose=2 "${APP_DIR}" 2>&1; then
    echo "    codesign OK"
  else
    echo "error: codesign verify failed" >&2
    codesign -dv --verbose=4 "${APP_DIR}" 2>&1 || true
    exit 1
  fi
fi

# Refresh Launch Services so Finder / open -a pick up the bundle
if command -v /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister >/dev/null; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${APP_DIR}" 2>/dev/null || true
fi

# Convenience launchers
mkdir -p "${HOME}/.local/bin"
LAUNCHER="${HOME}/.local/bin/token-monitor-tray"
cat > "${LAUNCHER}" <<'EOF'
#!/usr/bin/env bash
APP="$HOME/Applications/Claude-Code-Proxy Token Monitor Tray.app"
if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP" >&2
  echo "Build with: ./Scripts/build-app.sh (from the project root)" >&2
  exit 1
fi
if open "$APP" 2>/dev/null; then
  exit 0
fi
exec "$APP/Contents/MacOS/TokenMonitorTray"
EOF
chmod +x "${LAUNCHER}"
echo "==> Launcher: ${LAUNCHER}"

# Compat alias for the old name
COMPAT="${HOME}/.local/bin/gm-tray"
cat > "${COMPAT}" <<'EOF'
#!/usr/bin/env bash
# Compatibility wrapper — prefer: token-monitor-tray
exec "$(dirname "$0")/token-monitor-tray" "$@"
EOF
chmod +x "${COMPAT}"
echo "==> Compat launcher: ${COMPAT} → token-monitor-tray"

echo "==> Done: ${APP_DIR}"
echo "    Open with: open \"${APP_DIR}\""
echo "    Or run:    \"${MACOS}/${PRODUCT}\""
echo "    Or:        token-monitor-tray"
echo "    (Menu bar only — no Dock icon. Look near the clock.)"
