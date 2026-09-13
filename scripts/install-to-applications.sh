#!/bin/sh
set -eu

APP="${1:-}"
DEST="/Applications/AgentMonitor.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: $0 path/to/AgentMonitor.app" >&2
  exit 1
fi
if [ "${AGENT_MONITOR_EXPLICIT_INSTALL:-}" != "1" ]; then
  echo "Refusing implicit install. Use scripts/build-and-install-release.sh." >&2
  exit 2
fi
if [ -e "$APP/Contents/MacOS/AgentMonitor.debug.dylib" ] || [ -e "$APP/Contents/MacOS/__preview.dylib" ]; then
  echo "Skipping Applications install for preview/debug stub"
  exit 0
fi

# Stage the complete bundle before stopping or moving the existing app.
STAGING="$(mktemp -d /Applications/.AgentMonitor-install.XXXXXX)"
STAGED_APP="$STAGING/AgentMonitor.app"
ditto "$APP" "$STAGED_APP"
test -x "$STAGED_APP/Contents/MacOS/AgentMonitor"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")"

# The caller passes a completed Release product after Xcode's final signing.
# Installation validates that product and never repairs or invents a signature.
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
VERIFIED_ID="$(/usr/bin/codesign -dv --verbose=4 "$STAGED_APP" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -n 1)"
if [ "$VERIFIED_ID" != "$BUNDLE_ID" ]; then
  echo "Refusing to install bundle with signature identifier '$VERIFIED_ID'; expected '$BUNDLE_ID'." >&2
  exit 1
fi

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
  "$LSREGISTER" -u "$DEST" >/dev/null 2>&1 || true
  BACKUP="$STAGING/AgentMonitor.previous.backup"
  mv "$DEST" "$BACKUP"
fi
if ! mv "$STAGED_APP" "$DEST"; then
  if [ -n "$BACKUP" ]; then mv "$BACKUP" "$DEST"; fi
  echo "Installation failed; previous bundle restored." >&2
  exit 1
fi

# Keep rollback copies without an app extension. Otherwise LaunchServices can
# register the backup under the same bundle identifier and System Settings may
# display "AgentMonitor.previous" instead of the installed application's name.
RETAINED_BACKUP=""
if [ -n "$BACKUP" ]; then
  "$LSREGISTER" -u "$BACKUP" >/dev/null 2>&1 || true
  RETAINED_BACKUP="$BACKUP"
fi
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

echo "Installed AgentMonitor to $DEST"
echo "Previous app retained at $RETAINED_BACKUP"
echo "Reopen AgentMonitor to load the new version."
