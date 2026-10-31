#!/bin/zsh
set -euo pipefail

HERE=${0:A:h}
APP="$HOME/Applications/StageStrip.app"
IDENTITY=$(security find-identity -p codesigning | grep -o 'Local Code Signing[^"]*' | head -1 || true)
# нет сертификата (новая машина) — ad-hoc подпись
# без -v: самоподписанный сертификат не считается «доверенным», но подписывать им можно,
# и разрешения TCC переживают пересборку
[[ -n "$IDENTITY" ]] || IDENTITY="-"

mkdir -p "$APP/Contents/MacOS"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp/}stagestrip-clang-cache"
export SWIFT_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp/}stagestrip-swift-cache"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.stagestrip</string>
<key>CFBundleName</key><string>StageStrip</string>
<key>CFBundleDisplayName</key><string>StageStrip</string>
<key>CFBundleExecutable</key><string>StageStrip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Миниатюры окон в боковой панели</string>
</dict></plist>
PLIST

# цель задаём явно: по умолчанию swiftc на macOS 27.2 собирает под macosx28.0, и система не запускает приложение
swiftc -target "$(uname -m)-apple-macos15.0" -O -swift-version 5 -framework AppKit -framework ScreenCaptureKit -framework ApplicationServices \
  "$HERE"/*.swift -o "$APP/Contents/MacOS/StageStrip"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"
