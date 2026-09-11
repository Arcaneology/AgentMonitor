#!/bin/sh
set -eu

APP="${1:-}"
DEST="/Applications/AgentMonitor.app"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: $0 path/to/AgentMonitor.app" >&2
  exit 1
fi
if [ "${CONFIGURATION:-}" != "Release" ]; then
  echo "Skipping Applications install for ${CONFIGURATION:-unknown} build"
  exit 0
fi
if [ -e "$APP/Contents/MacOS/AgentMonitor.debug.dylib" ] || [ -e "$APP/Contents/MacOS/__preview.dylib" ]; then
  echo "Skipping Applications install for preview/debug stub"
  exit 0
fi

# Stage the complete bundle before stopping or moving the existing app.
STAGING="$(mktemp -d /Applications/.AgentMonitor-install.XXXXXX)"
ditto "$APP" "$STAGING/AgentMonitor.app"
test -x "$STAGING/AgentMonitor.app/Contents/MacOS/AgentMonitor"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGING/AgentMonitor.app/Contents/Info.plist"

pids="$(/usr/bin/pgrep -f '^/Applications/AgentMonitor.app/Contents/MacOS/AgentMonitor$' || true)"
if [ -n "$pids" ]; then
  /bin/kill -TERM $pids
  attempts=0
  while /usr/bin/pgrep -f '^/Applications/AgentMonitor.app/Contents/MacOS/AgentMonitor$' >/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
      echo "Existing app has not exited; leaving installed bundle unchanged." >&2
      exit 1
    fi
    sleep 0.25
  done
fi

BACKUP=""
if [ -e "$DEST" ]; then
  BACKUP="$STAGING/AgentMonitor.previous.app"
  mv "$DEST" "$BACKUP"
fi
if ! mv "$STAGING/AgentMonitor.app" "$DEST"; then
  if [ -n "$BACKUP" ]; then mv "$BACKUP" "$DEST"; fi
  echo "Installation failed; previous bundle restored." >&2
  exit 1
fi
echo "Installed AgentMonitor to $DEST"
echo "Previous app retained at $BACKUP"
echo "Reopen AgentMonitor to load the new version."
