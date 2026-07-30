#!/usr/bin/env bash
# Build GMTray into a proper macOS .app (menu bar only, no Dock).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GM Tray"
BUNDLE_ID="com.local.gm-tray"
BUILD_DIR="${ROOT}/.build"
APP_DIR="${1:-$HOME/Applications}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "==> Building GMTray (release)…"
cd "$ROOT"
swift build -c release --product GMTray

BIN="${BUILD_DIR}/release/GMTray"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "${BUILD_DIR}/release" -maxdepth 3 -type f -name GMTray -perm +111 | head -1)"
fi
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

cp "${BIN}" "${MACOS}/GMTray"
chmod +x "${MACOS}/GMTray"

# SPM resource bundle (Grok icon PDF/PNG, etc.)
# Generated path: .build/release/GMTray_GMTray.bundle  (or arch triple subdir)
BUNDLE_SRC=""
for cand in \
  "${BUILD_DIR}/release/GMTray_GMTray.bundle" \
  "${BUILD_DIR}/arm64-apple-macosx/release/GMTray_GMTray.bundle" \
  "${BUILD_DIR}/x86_64-apple-macosx/release/GMTray_GMTray.bundle"
do
  if [[ -d "$cand" ]]; then
    BUNDLE_SRC="$cand"
    break
  fi
done
if [[ -z "${BUNDLE_SRC}" ]]; then
  BUNDLE_SRC="$(find "${BUILD_DIR}" -type d -name 'GMTray_GMTray.bundle' 2>/dev/null | head -1 || true)"
fi

if [[ -n "${BUNDLE_SRC}" && -d "${BUNDLE_SRC}" ]]; then
  echo "==> Copying resource bundle from ${BUNDLE_SRC}"
  # Bundle.module looks for: Bundle.main.bundleURL/GMTray_GMTray.bundle
  # For a .app, that is:  GM Tray.app/GMTray_GMTray.bundle
  rm -rf "${APP_DIR}/GMTray_GMTray.bundle"
  cp -R "${BUNDLE_SRC}" "${APP_DIR}/GMTray_GMTray.bundle"
  # Also beside the binary (covers some launch styles)
  cp -R "${BUNDLE_SRC}" "${MACOS}/GMTray_GMTray.bundle"
  # Flatten assets into Contents/Resources
  find "${BUNDLE_SRC}" -maxdepth 2 -type f \( -name 'GrokIcon*' -o -name 'DeepSeekIcon*' \) -exec cp -f {} "${RESOURCES}/" \;
fi

# Source Resources as a reliable fallback for Contents/Resources
if [[ -d "${ROOT}/Sources/GMTray/Resources" ]]; then
  cp -f "${ROOT}/Sources/GMTray/Resources/"GrokIcon* "${RESOURCES}/" 2>/dev/null || true
  cp -f "${ROOT}/Sources/GMTray/Resources/"DeepSeekIcon* "${RESOURCES}/" 2>/dev/null || true
fi

# App icon (Dock/Finder if ever shown) — optional, from Grok mark
if [[ -f "${RESOURCES}/GrokIcon@2x.png" ]] && command -v sips >/dev/null; then
  # simple icns-less: use PNG as CFBundleIconFile alternative via iconset
  ICONSET="${BUILD_DIR}/AppIcon.iconset"
  rm -rf "${ICONSET}"
  mkdir -p "${ICONSET}"
  # Generate a few sizes from the 44px mark if present, else @2x
  SRC_ICON="${ROOT}/Sources/GMTray/Resources/GrokIcon44.png"
  [[ -f "$SRC_ICON" ]] || SRC_ICON="${ROOT}/Sources/GMTray/Resources/GrokIcon@2x.png"
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$SRC_ICON" --out "${ICONSET}/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
    dsz=$((sz * 2))
    sips -z "$dsz" "$dsz" "$SRC_ICON" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
  done
  if command -v iconutil >/dev/null; then
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
  <string>GMTray</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.1</string>
  <key>CFBundleVersion</key>
  <string>2</string>
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

# ad-hoc sign so Gatekeeper is less noisy for local use
if command -v codesign >/dev/null; then
  codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true
fi

echo "==> Done: ${APP_DIR}"
echo "    Open with: open \"${APP_DIR}\""
echo "    Or run:    \"${MACOS}/GMTray\""
