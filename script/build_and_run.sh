#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Usagebar"
BUNDLE_ID="bullfigherstudios.JustaUsageBar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/CodexDerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  fi
fi

build_app() {
  xcodebuild -project "$ROOT_DIR/JustaUsageBar.xcodeproj" -scheme JustaUsageBar \
    -configuration Debug -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO -quiet build
}

launch_app() { /usr/bin/open -n "$APP_BUNDLE"; }

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
build_app
[[ -x "$APP_EXECUTABLE" ]] || { echo "Missing app executable: $APP_EXECUTABLE" >&2; exit 1; }

case "$MODE" in
  run) launch_app ;;
  --debug|debug) lldb -- "$APP_EXECUTABLE" ;;
  --logs|logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    launch_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null || { echo "$APP_NAME did not remain running" >&2; exit 1; }
    echo "$APP_NAME is running from $APP_BUNDLE"
    ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
