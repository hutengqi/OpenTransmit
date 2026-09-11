#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify|--build) ;; *) echo "usage: $0 [--build|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
if [[ "$MODE" != "--build" ]]; then pkill -x OpenTransmit >/dev/null 2>&1 || true; fi
xcodebuild -project OpenTransmit.xcodeproj -scheme OpenTransmit -configuration Debug -destination 'platform=macOS' -derivedDataPath .build CODE_SIGN_IDENTITY=- build
APP="$ROOT_DIR/.build/Build/Products/Debug/OpenTransmit.app"
case "$MODE" in
  --build) ;;
  --debug) lldb -- "$APP/Contents/MacOS/OpenTransmit" ;;
  --logs|--telemetry) open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "OpenTransmit"' ;;
  --verify) open -n "$APP"; sleep 2; pgrep -x OpenTransmit ;;
  run) open -n "$APP" ;;
esac
