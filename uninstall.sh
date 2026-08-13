#!/usr/bin/env bash
#
# Remove everything install.sh put on this machine. Safe to run twice.
#
set -euo pipefail

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
PLUGIN_DIR=$CONFIG_DIR/plugins/claude-hud
SCRIPT=$CONFIG_DIR/scripts/claude-hud-usage-feeder.py
HUD_CONFIG=$PLUGIN_DIR/config.json
SNAPSHOT=$PLUGIN_DIR/usage-snapshot.json
FEEDER_CONFIG=$PLUGIN_DIR/usage-feeder.json
LOG=$PLUGIN_DIR/usage-feeder.log
AGENT_LABEL=io.github.itofu.claude-hud-usage-feeder
PLIST=$HOME/Library/LaunchAgents/$AGENT_LABEL.plist

KEEP_LOG=0

info() { printf '  %s\n' "$*"; }
step() { printf '\033[1m%s\033[0m\n' "$*"; }

usage() {
  cat <<EOF
Usage: ./uninstall.sh [options]

  --keep-log   Leave $LOG in place.
  -h, --help   This text.

Removes the scheduler, the feeder script, the snapshot, and the two
display.externalUsage* keys from claude-hud's config. Nothing else in that
config is touched.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-log) KEEP_LOG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

step "Removing scheduler"
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
  /bin/rm -f "$PLIST"
  info "$PLIST"
else
  info "no launchd agent installed"
fi

step "Removing files"
for path in "$SCRIPT" "$SNAPSHOT" "$FEEDER_CONFIG"; do
  if [ -e "$path" ]; then /bin/rm -f "$path"; info "$path"; fi
done
if [ "$KEEP_LOG" -eq 0 ] && [ -e "$LOG" ]; then
  /bin/rm -f "$LOG"
  info "$LOG"
fi

step "Reverting claude-hud config"
python3 - "$HUD_CONFIG" <<'PY'
import json, os, sys

path = sys.argv[1]
if not os.path.exists(path):
    print("  no config to revert")
    raise SystemExit(0)

with open(path) as handle:
    try:
        config = json.load(handle)
    except ValueError:
        print("  config is not valid JSON; leaving it alone")
        raise SystemExit(0)

display = config.get("display") or {}
removed = [key for key in ("externalUsagePath", "externalUsageFreshnessMs")
           if display.pop(key, None) is not None]
if not removed:
    print("  nothing to revert")
    raise SystemExit(0)

with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
for key in removed:
    print("  removed display.%s" % key)
PY

printf '\n\033[32mDone.\033[0m\n'
