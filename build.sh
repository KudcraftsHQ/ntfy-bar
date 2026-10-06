#!/usr/bin/env bash
# Build ntfy-bar, assemble the .app bundle, ad-hoc sign it and install to ~/Applications.
#   ./build.sh            build + install (restarts the app if it was running)
#   ./build.sh --no-install   build bundle into ./build only
#   ./build.sh --run      build + install + launch
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=1; RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="ntfy-bar"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"

echo "==> swift build (release)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/NtfyBar"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc signing"
codesign --force --deep -s - "$APP"
codesign --verify --strict "$APP"

if [ "$INSTALL" = 1 ]; then
  WAS_RUNNING=0
  if pgrep -x "$APP_NAME" >/dev/null; then
    WAS_RUNNING=1
    echo "==> stopping running $APP_NAME"
    osascript -e "tell application id \"com.kudcrafts.ntfy-bar\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
    pkill -x "$APP_NAME" 2>/dev/null || true
  fi
  echo "==> installing to $DEST"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  if [ "$RUN" = 1 ] || [ "$WAS_RUNNING" = 1 ]; then
    open "$DEST"
  fi
fi
echo "==> done"
