#!/bin/zsh
# Compila NXNativeMac en release y monta build/NXNativeMac.app, firmada ad hoc.
# Uso: scripts/build_app.sh [identidad de codesign]
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/NXNativeMac"

app=build/NXNativeMac.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/NXNativeMac"

version="$(git describe --tags --always 2>/dev/null || echo 0.1)"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>NXNativeMac</string>
  <key>CFBundleIdentifier</key><string>com.mathiaskowoll.NXNativeMac</string>
  <key>CFBundleName</key><string>NXNative</string>
  <key>CFBundleDisplayName</key><string>NXNative</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sin sandbox: la app lanza python3, git y xcrun, y lee carpetas de juego en
# discos externos. No hace falta hardened runtime para eso, pero tampoco estorba.
codesign --force --sign "${1:--}" "$app"
echo "$app"
