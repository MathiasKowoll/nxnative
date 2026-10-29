#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained FC27 Mac app from the user's own NSP/NSZ/XCI folder.
# The FC27 profile supplies its own settings launcher; the generic packer puts
# that launcher and every game resource in the resulting bundle.
# The installer carries this script and nxnative's tools, never the game dump
# or prod.keys. Missing paths are selected with native macOS dialogs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="${1:-${FC27_GAME_DIR:-}}"
KEYS="${2:-${FC27_KEYS:-}}"
OUT_DIR="${3:-${FC27_OUT_DIR:-}}"

choose_folder() {
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  POSIX path of (choose folder with prompt "Selecciona la carpeta que contiene tu juego FC 27 (NSP/NSZ/XCI):")
end tell
APPLESCRIPT
}

choose_file() {
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  POSIX path of (choose file with prompt "Selecciona tu archivo prod.keys:" of type {"keys"})
end tell
APPLESCRIPT
}

choose_output() {
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  POSIX path of (choose folder with prompt "Selecciona dónde guardar la app FC 27 terminada:")
end tell
APPLESCRIPT
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Uso:
  script/build_fc27_from_own_game.sh [CARPETA_DEL_JUEGO] [PROD.KEYS] [CARPETA_DE_SALIDA]

La carpeta del juego debe contener el NSP base y, opcionalmente, su actualización
y DLC. El script no descarga, incluye ni imprime archivos del juego o claves.
El resultado es una app Mac autocontenida, firmada ad-hoc para pruebas locales.
HELP
  exit 0
fi

if [[ -z "$GAME_DIR" ]]; then GAME_DIR="$(choose_folder)"; fi
if [[ -z "$KEYS" ]]; then KEYS="$(choose_file)"; fi
if [[ -z "$OUT_DIR" ]]; then OUT_DIR="$(choose_output)"; fi

GAME_DIR="${GAME_DIR%/}"
KEYS="${KEYS%/}"
OUT_DIR="${OUT_DIR%/}"

[[ -d "$GAME_DIR" ]] || { echo "No existe la carpeta del juego: $GAME_DIR" >&2; exit 2; }
[[ -f "$KEYS" ]] || { echo "No existe prod.keys: $KEYS" >&2; exit 2; }
[[ -x "$ROOT_DIR/scripts/build_ipa_from_nsp.py" ]] || { echo "No se encuentra el pipeline de nxnative" >&2; exit 2; }

mkdir -p "$OUT_DIR"
OUT_APP="$OUT_DIR/EA Sports FC 27.app"

echo "Preparando FC 27 desde los archivos seleccionados por el usuario."
echo "Los datos intermedios se guardarán junto a la carpeta del juego, no en el instalador."
echo "El proceso puede tardar y requiere Xcode, Python y las herramientas indicadas por nxnative."

python3 "$ROOT_DIR/scripts/build_ipa_from_nsp.py" "$GAME_DIR" \
  --platform mac-app \
  --mac-sign - \
  --out "$OUT_APP" \
  --progress lines \
  -k "$KEYS"

echo "App creada: $OUT_APP"
if command -v open >/dev/null 2>&1; then open -R "$OUT_APP"; fi
