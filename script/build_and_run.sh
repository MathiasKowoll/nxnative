#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_ID="0100C49025D3E000"
PROFILE_DIR="$ROOT_DIR/dm/games/$GAME_ID"
WORK_DIR="${FC27_WORK:-/Volumes/CrucialX8/Emulation/Switch/_nxnative/FC27_base_work}"
APP_BUNDLE="${FC27_APP:-/Volumes/CrucialX8/Emulation/Switch/_nxnative/FC27_Full_60fps_Texturas.app}"
APP_ALIAS="/Volumes/CrucialX8/Emulation/Switch/_nxnative/EA Sports FC 27.app"
BUILD_DIR="$PROFILE_DIR/build"
MODE="${1:-run}"

# The host and the shader libraries must use the same translation chain.
# A host-only rebuild otherwise starts with audio and a completely black window.
export DM_GAME="$GAME_ID"
CHECK_CACHE="$PROFILE_DIR/tools/check_shader_cache.py"
if ! python3 "$CHECK_CACHE" "$WORK_DIR"; then
  PACKAGE_DIR="${FC27_SHADER_PACKAGE:-$WORK_DIR/pkg-fc27-verified}"
  if [[ ! -f "$PACKAGE_DIR/shader_map.tsv" ]] || ! cmp -s "$PACKAGE_DIR/shader_map.tsv" "$PROFILE_DIR/shader_map.tsv"; then
    echo "FC27 needs a verified shader package matching the profile: $PACKAGE_DIR" >&2
    exit 1
  fi
  WORK="$WORK_DIR" J="${J:-6}" python3 "$ROOT_DIR/dm/gfx/tools/dmsh_build.py" "$PACKAGE_DIR" "$WORK_DIR/shader-cache-fc27"
  python3 "$CHECK_CACHE" "$WORK_DIR"
fi

pkill -x "FC 27" >/dev/null 2>&1 || true

make -C "$ROOT_DIR/dm/host" GAME="$GAME_ID" dmhost
mkdir -p "$BUILD_DIR" "$WORK_DIR/profile" "$WORK_DIR/run-valid/font"
for name in shader_map.tsv shader_facts.tsv shader_pairs.tsv pso_pairs.tsv c1_full.tsv cb_extent.tsv pso_manifest.tsv; do
  cp "$PROFILE_DIR/$name" "$WORK_DIR/profile/$name"
done

MSL_DIR="$(find -L "$WORK_DIR/shader-cache-fc27" -mindepth 1 -maxdepth 1 -type d -name 'b-*' -print -quit)"
if [[ -z "$MSL_DIR" ]]; then
  echo "FC27 no tiene una cadena de shaders Metal b-* válida en $WORK_DIR/shader-cache-fc27" >&2
  exit 1
fi

PACK_ARGS=(
  python3 "$ROOT_DIR/dm/mac/pack_app.py" "$APP_BUNDLE"
  --host "$ROOT_DIR/dm/host/dmhost"
  --patched "$WORK_DIR/patched-v262144"
  --romfs "$WORK_DIR/extract-base-update-v262144/RomFS.img"
  --msl "$MSL_DIR"
  --tables "$WORK_DIR/profile"
  --font "$WORK_DIR/run-valid/font"
  --pso "$WORK_DIR/pipeline-cache-fc27"
  --title-id "$GAME_ID"
  --name "FC 27"
  --version "1.8c.cab1"
  --bundle-id "org.macnativegames.fc27"
  --category "public.app-category.sports-games"
  --icon "$WORK_DIR/extract-base-update-v262144/icon.jpg"
  --launcher-source "$PROFILE_DIR/app/launcher.m"
  --launcher-define "FC27_BUNDLED=1"
  --launcher-executable "FC 27"
  --sign -
)
"${PACK_ARGS[@]}"
codesign --verify --deep --strict "$APP_BUNDLE"
ln -sfn "$(basename "$APP_BUNDLE")" "$APP_ALIAS"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  pack) ;;
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/FC 27" ;;
  --logs|logs) open_app; tail -n +1 -f "$HOME/Library/Logs/MacNativeGames/fc27.log" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate 'process == "FC 27"' ;;
  --verify|verify) open_app; sleep 2; pgrep -x "FC 27" >/dev/null ;;
  *) echo "usage: $0 [pack|run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
