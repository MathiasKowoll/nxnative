#!/bin/zsh
# Compila NXNativeMac en release, monta build/NXNativeMac.app con su icono,
# la firma ad hoc y la copia a /Applications (o a ~/Applications si no se
# puede escribir allí).
# Uso: scripts/build_app.sh [--no-install] [identidad de codesign]
set -euo pipefail
cd "${0:A:h}/.."

install=1
if [[ "${1:-}" == "--no-install" ]]; then install=0; shift; fi
identity="${1:--}"

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/NXNativeMac"

app=build/NXNativeMac.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/NXNativeMac"

# El icono se dibuja con scripts/make_icon.swift y se guarda en build/: solo
# se rehace si el script cambia.
icns=build/AppIcon.icns
if [[ ! -f "$icns" || scripts/make_icon.swift -nt "$icns" ]]; then
    work=$(mktemp -d)
    swift scripts/make_icon.swift "$work/icon_1024.png" >/dev/null
    set=$work/AppIcon.iconset; mkdir -p "$set"
    for n in 16 32 128 256 512; do
        sips -z $n $n "$work/icon_1024.png" --out "$set/icon_${n}x${n}.png" >/dev/null
        sips -z $((n * 2)) $((n * 2)) "$work/icon_1024.png" --out "$set/icon_${n}x${n}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o "$icns"
    rm -rf "$work"
fi
cp "$icns" "$app/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
codesign --force --sign "$identity" "$app"
echo "$app"

if (( install )); then
    dest=/Applications
    [[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
    if pgrep -f "$dest/NXNativeMac.app/Contents/MacOS/NXNativeMac" >/dev/null; then
        echo "Aviso: NXNative está abierta desde $dest; la copia nueva se usará al volver a abrirla."
    fi
    # Primero a un nombre temporal y luego se cambia: una copia a medias nunca
    # ocupa el sitio de la buena.
    rm -rf "$dest/NXNativeMac.app.partial"
    ditto "$app" "$dest/NXNativeMac.app.partial"
    rm -rf "$dest/NXNativeMac.app"
    mv "$dest/NXNativeMac.app.partial" "$dest/NXNativeMac.app"
    # Que Finder y el Dock vean el icono nuevo sin esperar.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest/NXNativeMac.app" 2>/dev/null || true
    echo "Instalada en $dest/NXNativeMac.app"
fi
