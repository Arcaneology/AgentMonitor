#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DERIVED="${AGENT_MONITOR_DERIVED_DATA:-/tmp/AgentMonitorRelease}"
PRODUCT="$DERIVED/Build/Products/Release/AgentMonitor.app"

/usr/bin/xcodebuild \
  -project "$ROOT/AgentMonitor.xcodeproj" \
  -scheme AgentMonitor \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  build

test -d "$PRODUCT"
/usr/bin/codesign --verify --deep --strict "$PRODUCT"
AGENT_MONITOR_EXPLICIT_INSTALL=1 "$ROOT/scripts/install-to-applications.sh" "$PRODUCT"
