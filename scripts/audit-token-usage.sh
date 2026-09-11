#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
  echo 'Usage: audit-token-usage.sh /absolute/path/to/COPY.db /absolute/path/to/report.json' >&2
  exit 1
fi
audit_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
audit_build=$(mktemp -d "${TMPDIR:-/tmp}/agent-monitor-audit.XXXXXX")
trap 'rm -rf "$audit_build"' EXIT
xcrun swiftc -parse-as-library -O \
  "$audit_root/AgentMonitor/Core/Usage/TokenModelCatalog.swift" \
  "$audit_root/AgentMonitor/Core/Usage/SessionUsageScanner.swift" \
  "$audit_root/AgentMonitor/Core/Usage/CCTokenUsageReader.swift" \
  "$audit_root/scripts/audit-token-usage.swift" \
  -o "$audit_build/audit-token-usage"
"$audit_build/audit-token-usage" "$1" "$2"
