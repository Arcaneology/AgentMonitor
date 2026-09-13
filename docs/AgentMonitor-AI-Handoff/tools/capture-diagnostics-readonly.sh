#!/bin/bash
# AgentMonitor diagnostic capture. macOS only; compatible with system Bash 3.2.
# Does not install apps, run sudo, change settings, wake the display, or stop apps.
# Writes private local evidence files; with --seconds it starts read-only helpers
# and stops only those helpers when finished. Review logs before sharing.
set -u
umask 077
APP="/Applications/AgentMonitor.app"
REPO=""
PARENT="${TMPDIR:-/tmp}"
SECONDS_TO_CAPTURE=0
CHILDREN=()
usage() {
  cat <<'EOF'
Usage: bash capture-diagnostics-readonly.sh [options]
  --app PATH       Installed application (default /Applications/AgentMonitor.app)
  --repo PATH      Optional existing local Git checkout; read-only inspection
  --out-parent DIR Existing writable parent for a new private evidence directory
  --seconds N      Capture read-only streams for 0..600 seconds (default 0)
  --help           Show usage
No sudo, application launch, installation, menu-bar reset or power-setting write.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app|--repo|--out-parent|--seconds)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in
        --app) APP="$2" ;;
        --repo) REPO="$2" ;;
        --out-parent) PARENT="$2" ;;
        --seconds) SECONDS_TO_CAPTURE="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$SECONDS_TO_CAPTURE" in
  ''|*[!0-9]*) echo '--seconds must be an integer from 0 to 600.' >&2; exit 2 ;;
esac
[ "${#SECONDS_TO_CAPTURE}" -le 3 ] || { echo '--seconds must be <= 600.' >&2; exit 2; }
SECONDS_TO_CAPTURE=$((10#$SECONDS_TO_CAPTURE))
[ "$SECONDS_TO_CAPTURE" -le 600 ] || { echo '--seconds must be <= 600.' >&2; exit 2; }
[ "$(/usr/bin/uname -s)" = Darwin ] || {
  echo 'This script requires macOS. No macOS diagnostics were executed.' >&2
  exit 2
}
[ -d "$PARENT" ] && [ -w "$PARENT" ] || {
  echo '--out-parent must be an existing writable directory.' >&2; exit 2;
}
[ -z "$REPO" ] || [ -d "$REPO" ] || { echo '--repo does not exist.' >&2; exit 2; }
OUT="$(/usr/bin/mktemp -d "${PARENT%/}/AgentMonitor-diag.XXXXXX")" || exit 1
mkdir "$OUT/streams" || exit 1
run() {
  local name="$1"; shift
  printf '%s\tSTART\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" >> "$OUT/commands.tsv"
  "$@" > "$OUT/$name.stdout.txt" 2> "$OUT/$name.stderr.txt"
  local rc=$?
  printf '%s\tEND\t%s\trc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" "$rc" >> "$OUT/commands.tsv"
  return 0
}
cleanup() {
  local pid ppid
  for pid in ${CHILDREN[@]+"${CHILDREN[@]}"}; do
    ppid="$(/bin/ps -p "$pid" -o ppid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
    if [ "$ppid" = "$$" ]; then
      /bin/kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  for pid in ${CHILDREN[@]+"${CHILDREN[@]}"}; do wait "$pid" 2>/dev/null || true; done
  CHILDREN=()
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
snapshot() {
  local tag="$1" pid
  run "$tag-time" /bin/date '+%Y-%m-%dT%H:%M:%S%z'
  run "$tag-power-source" /usr/bin/pmset -g batt
  run "$tag-power-custom" /usr/bin/pmset -g custom
  run "$tag-power-live" /usr/bin/pmset -g
  run "$tag-assertions" /usr/bin/pmset -g assertions
  run "$tag-schedules" /usr/bin/pmset -g sched
  # Filter properties instead of persisting the full IORegistry or serial numbers.
  /usr/sbin/ioreg -r -n IOPMrootDomain -d 1 -l 2> "$OUT/$tag-root-domain.stderr.txt" |
    /usr/bin/grep -E '"(SleepDisabled|AppleClamshellState|AppleClamshellCausesSleep)"' \
    > "$OUT/$tag-root-domain-selected.txt" || true
  /usr/bin/pgrep -x AgentMonitor > "$OUT/$tag-app-pids.txt" 2>/dev/null || true
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    /bin/ps -p "$pid" -o pid=,ppid=,lstart=,comm= >> "$OUT/$tag-app-processes.txt" 2>&1
  done < "$OUT/$tag-app-pids.txt"
  # Source is historical and may contain application names. Keep local and review.
  run "$tag-pmset-log" /usr/bin/pmset -g log
}
cat > "$OUT/READ-ME.txt" <<'EOF'
Evidence capture only. Missing output, absent properties, or permission errors are
UNKNOWN, not proof that no sleep/blocking event occurred. Inspect commands.tsv
and stderr files. Snapshot timestamps differ by command; they are not atomic.
This script does not record screen pixels or prove menu-bar visibility. Native
app instrumentation and physical observation are still required.
Logs may contain usernames, paths, application names and unrelated historical
power events. Review and redact a COPY before sharing; retain originals locally.
The script does not upload anything and requests no additional system permission.
EOF
run os /usr/bin/sw_vers
run arch /usr/bin/uname -m
run hardware-model /usr/sbin/sysctl -n hw.model
run xcode /usr/bin/xcodebuild -version
run toolchain-selection /usr/bin/xcode-select -p
if [ -d "$APP" ]; then
  run bundle-id /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
  run version /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
  run build-number /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
  run executable-name /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist"
  run lsui-element /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist"
  run signature-detail /usr/bin/codesign -d -r- --verbose=4 "$APP"
  run signature-verify /usr/bin/codesign --verify --deep --strict "$APP"
  EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  case "$EXECUTABLE" in
    ''|*/*) echo 'Executable name missing or invalid; no executable hash.' >> "$OUT/READ-ME.txt" ;;
    *) run executable-sha256 /usr/bin/shasum -a 256 "$APP/Contents/MacOS/$EXECUTABLE" ;;
  esac
else
  printf 'Application path not found: %s\n' "$APP" >> "$OUT/READ-ME.txt"
fi
if [ -n "$REPO" ]; then
  run git-head /usr/bin/env GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$REPO" rev-parse HEAD
  run git-status /usr/bin/env GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$REPO" status --short
fi
snapshot before
if [ "$SECONDS_TO_CAPTURE" -gt 0 ]; then
  printf 'Capturing for %s seconds. Evidence directory: %s\n' "$SECONDS_TO_CAPTURE" "$OUT"
  /usr/bin/pmset -g pslog > "$OUT/streams/power-source.txt" 2>&1 & CHILDREN+=("$!")
  /usr/bin/pmset -g assertionslog > "$OUT/streams/assertions.txt" 2>&1 & CHILDREN+=("$!")
  PREDICATE='(process == "AgentMonitor") OR (process == "ControlCenter" AND eventMessage CONTAINS[c] "AgentMonitor") OR (process == "powerd" AND (eventMessage CONTAINS[c] "sleep" OR eventMessage CONTAINS[c] "wake" OR eventMessage CONTAINS[c] "display" OR eventMessage CONTAINS[c] "clamshell" OR eventMessage CONTAINS[c] "power source"))'
  /usr/bin/log stream --style compact --level info --predicate "$PREDICATE" \
    > "$OUT/streams/unified-log.txt" 2>&1 & CHILDREN+=("$!")
  sleep "$SECONDS_TO_CAPTURE"
  cleanup
  snapshot after
fi
printf 'Saved local evidence: %s\n' "$OUT"
printf 'Inspect stderr and redact a copy of the logs before sharing.\n'
