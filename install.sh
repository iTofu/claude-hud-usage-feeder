#!/usr/bin/env bash
#
# Install the claude-hud usage feeder: copy the script, point claude-hud at the
# snapshot it writes, and schedule it. Re-running is safe and idempotent.
#
set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
PLUGIN_DIR=$CONFIG_DIR/plugins/claude-hud
SCRIPT_DIR=$CONFIG_DIR/scripts
SCRIPT=$SCRIPT_DIR/claude-hud-usage-feeder.py
HUD_CONFIG=$PLUGIN_DIR/config.json
SNAPSHOT=$PLUGIN_DIR/usage-snapshot.json
AGENT_LABEL=io.github.itofu.claude-hud-usage-feeder
PLIST=$HOME/Library/LaunchAgents/$AGENT_LABEL.plist

INTERVAL=600
FRESHNESS_MS=1800000
INTERVAL_SET=0
FRESHNESS_SET=0
INSTALL_TIMER=1
INSTALL_HOOKS=0
LABEL_PAIRS=()

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\033[1m%s\033[0m\n' "$*"; }

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --interval SECONDS   How often to refresh (default: $INTERVAL)
  --freshness MS       How long claude-hud treats the snapshot as usable
                       (default: $FRESHNESS_MS, i.e. 30 minutes). Keep this
                       comfortably above the interval so one failed run does
                       not blank the segment.
  --label FROM=TO      Rename a statusline label; repeatable.
                       e.g. --label 'Fable=f'
  --hooks              Also refresh on Claude Code's Stop and SessionStart
                       events, so the number updates seconds after each turn
                       instead of on the timer. Costs no extra API requests:
                       the cheap source absorbs the calls and the expensive
                       ones stay throttled. Edits settings.json; --no-timer
                       is still not implied, because the timer is what catches
                       quota you spend elsewhere (web, phone, another machine).
                       Implies a slower timer and longer freshness unless you
                       set them explicitly.
  --no-timer           Install the script and config only, no scheduler.
  -h, --help           This text.

Environment:
  CLAUDE_CONFIG_DIR    Claude Code config dir (default: ~/.claude)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL=${2:?--interval needs a value}; INTERVAL_SET=1; shift 2 ;;
    --freshness) FRESHNESS_MS=${2:?--freshness needs a value}; FRESHNESS_SET=1; shift 2 ;;
    --label) LABEL_PAIRS+=("${2:?--label needs FROM=TO}"); shift 2 ;;
    --hooks) INSTALL_HOOKS=1; shift ;;
    --no-timer) INSTALL_TIMER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$INTERVAL" in ''|*[!0-9]*) die "--interval must be a whole number of seconds" ;; esac
case "$FRESHNESS_MS" in ''|*[!0-9]*) die "--freshness must be a whole number of milliseconds" ;; esac

# With event hooks doing the work, the timer only has to catch quota spent
# outside this machine, and the snapshot only has to survive an idle stretch --
# during which the number is not moving anyway. Both can relax a lot.
if [ "$INSTALL_HOOKS" -eq 1 ]; then
  [ "$INTERVAL_SET" -eq 1 ] || INTERVAL=1800
  [ "$FRESHNESS_SET" -eq 1 ] || FRESHNESS_MS=3600000
fi

# --- preflight -------------------------------------------------------------

step "Checking prerequisites"

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
[ -d "$PLUGIN_DIR" ] || die "claude-hud does not look installed ($PLUGIN_DIR missing).
       Install it first: /plugin marketplace add jarrodwatts/claude-hud"

# The snapshot-reading hook (display.externalUsagePath) landed in claude-hud
# 0.7.0. Older versions ignore it and the scoped segment will never appear.
HUD_VERSION=$(ls -1 "$CONFIG_DIR/plugins/cache/claude-hud/claude-hud" 2>/dev/null \
  | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
if [ -n "$HUD_VERSION" ]; then
  if [ "$(printf '0.7.0\n%s\n' "$HUD_VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" != "0.7.0" ]; then
    die "claude-hud $HUD_VERSION is too old; 0.7.0+ is required for display.externalUsagePath.
       Update it: /plugin  (then re-run this installer)"
  fi
  info "claude-hud $HUD_VERSION"
fi

LABELS_JSON=$(python3 - "${LABEL_PAIRS[@]+"${LABEL_PAIRS[@]}"}" <<'PY'
import json, sys
labels = {}
for pair in sys.argv[1:]:
    if "=" not in pair:
        sys.exit("--label expects FROM=TO, got %r" % pair)
    key, _, value = pair.partition("=")
    key = key.strip()
    if not key:
        sys.exit("--label FROM must not be empty")
    labels[key] = value
print(json.dumps(labels, ensure_ascii=False))
PY
)
[ "$LABELS_JSON" = "{}" ] || info "label overrides: $LABELS_JSON"

FEEDER_CONFIG=$PLUGIN_DIR/usage-feeder.json

# --- install the script ----------------------------------------------------

step "Installing feeder"

mkdir -p "$SCRIPT_DIR"
install -m 0755 "$SRC_DIR/claude-hud-usage-feeder.py" "$SCRIPT"
info "$SCRIPT"

# Labels live on disk, not in the scheduler's environment, so that running the
# script by hand produces exactly what the scheduled run produces. No --label
# means "leave whatever is already configured alone".
if [ "$LABELS_JSON" != "{}" ]; then
  python3 - "$FEEDER_CONFIG" "$LABELS_JSON" <<'PY'
import json, sys
path, labels = sys.argv[1], json.loads(sys.argv[2])
with open(path, "w") as handle:
    json.dump({"labels": labels}, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
print("  %s" % path)
PY
fi

# --- point claude-hud at the snapshot --------------------------------------

step "Configuring claude-hud"

python3 - "$HUD_CONFIG" "$SNAPSHOT" "$FRESHNESS_MS" <<'PY'
import json, os, shutil, sys, time

config_path, snapshot, freshness = sys.argv[1], sys.argv[2], int(sys.argv[3])

config = {}
if os.path.exists(config_path):
    with open(config_path) as handle:
        try:
            config = json.load(handle)
        except ValueError:
            sys.exit("%s is not valid JSON; fix or move it, then re-run" % config_path)

display = config.setdefault("display", {})
wanted = {"externalUsagePath": snapshot, "externalUsageFreshnessMs": freshness}
changed = {key: value for key, value in wanted.items() if display.get(key) != value}

if not changed:
    print("  already configured, left untouched")
    sys.exit(0)

# Only back up when we are actually about to change something, and never
# clobber an existing backup -- the first one is the one worth keeping.
if os.path.exists(config_path):
    backup = "%s.bak.%s" % (config_path, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(config_path, backup)
    print("  backed up to %s" % backup)

display.update(wanted)
with open(config_path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
for key, value in changed.items():
    print("  display.%s = %s" % (key, value))
PY

# --- event hooks -----------------------------------------------------------

if [ "$INSTALL_HOOKS" -eq 1 ]; then
  step "Installing event hooks"
  python3 - "$CONFIG_DIR/settings.json" "$SCRIPT" install <<'PY'
import json, os, shutil, sys, time

path, script, mode = sys.argv[1], sys.argv[2], sys.argv[3]
EVENTS = ("Stop", "SessionStart")
# Detached on purpose: a hook that blocks is a hook you feel on every turn.
command = "%s >/dev/null 2>&1 &" % script

settings = {}
if os.path.exists(path):
    with open(path) as handle:
        try:
            settings = json.load(handle)
        except ValueError:
            sys.exit("  %s is not valid JSON; fix it, then re-run" % path)

before = json.dumps(settings, sort_keys=True)
hooks = settings.get("hooks") or {}

for event in EVENTS:
    # Drop any entry of ours first, so re-running never stacks duplicates,
    # then re-add. Everything else in the file is left exactly as it was.
    groups = []
    for group in hooks.get(event) or []:
        entries = [h for h in (group.get("hooks") or [])
                   if script not in (h.get("command") or "")]
        if entries:
            groups.append(dict(group, hooks=entries))
    if mode == "install":
        groups.append({"hooks": [{"type": "command", "command": command}]})
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

if json.dumps(settings, sort_keys=True) == before:
    print("  already configured, left untouched")
    raise SystemExit(0)

if os.path.exists(path):
    backup = "%s.bak.%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, backup)
    print("  backed up to %s" % backup)

with open(path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print("  %s -> %s" % (", ".join(EVENTS), path))
PY
fi

# --- schedule --------------------------------------------------------------

if [ "$INSTALL_TIMER" -eq 1 ] && [ "$(uname -s)" = "Darwin" ]; then
  step "Scheduling (launchd, every ${INTERVAL}s)"

  mkdir -p "$(dirname "$PLIST")"
  python3 - "$PLIST" "$AGENT_LABEL" "$SCRIPT" "$INTERVAL" "$CONFIG_DIR" <<'PY'
import os, plistlib, sys

path, label, script, interval, config_dir = sys.argv[1:6]
# launchd hands a process a minimal PATH; without these two directories the
# cswap and claude lookups fall back to guessing.
env = {"PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
# Only export a non-default config dir. Exporting it unconditionally makes it
# visible to every child process, and at least one of them (cswap) changes
# behaviour merely because the variable exists.
if config_dir != os.path.join(os.path.expanduser("~"), ".claude"):
    env["CLAUDE_CONFIG_DIR"] = config_dir

with open(path, "wb") as handle:
    plistlib.dump({
        "Label": label,
        # Exec the script directly rather than via `/usr/bin/env python3`.
        # macOS names background items after argv[0], so the latter shows up in
        # System Settings > Login Items as a bare "env" -- unidentifiable to
        # anyone auditing what runs on their machine. The shebang resolves
        # python3 through the PATH set below.
        "ProgramArguments": [script],
        "EnvironmentVariables": env,
        "StartInterval": int(interval),
        "RunAtLoad": True,
        "ProcessType": "Background",
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }, handle)
PY

  # bootout before bootstrap so re-running picks up a changed interval.
  launchctl bootout "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  info "$PLIST"
elif [ "$INSTALL_TIMER" -eq 1 ]; then
  step "Scheduling"
  info "Not macOS -- no launchd. Add this to your crontab instead:"
  info "  */$(( INTERVAL / 60 )) * * * * $SCRIPT"
fi

# --- verify ----------------------------------------------------------------

step "Verifying"

snapshot_is_fresh() {
  python3 - "$SNAPSHOT" <<'PY' >/dev/null 2>&1
import datetime, json, sys, time
snapshot = json.load(open(sys.argv[1]))
stamp = datetime.datetime.fromisoformat(snapshot["updated_at"].replace("Z", "+00:00"))
sys.exit(0 if time.time() - stamp.timestamp() < 90 else 1)
PY
}

# RunAtLoad has already kicked off a run. Wait for it rather than firing a
# second one: both would hit the same rate-limited endpoint seconds apart, and
# waiting also means we verify the scheduled path (plist env and all) instead
# of a hand-rolled invocation that happens to work.
if [ "$INSTALL_TIMER" -eq 1 ] && [ "$(uname -s)" = "Darwin" ]; then
  for _ in 1 2 3 4 5 6 7 8; do snapshot_is_fresh && break; sleep 1; done
fi
if ! snapshot_is_fresh; then
  "$SCRIPT" >/dev/null 2>&1 || true
fi

python3 - "$SNAPSHOT" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit("  no snapshot written -- see the log for why")
with open(path) as handle:
    snapshot = json.load(handle)
scoped = snapshot.get("model_scoped") or []
if not scoped:
    sys.exit("  snapshot has no model-scoped windows. Either your account has no\n"
             "  per-model weekly quota right now, or every source failed; check the log.")
for window in scoped:
    print("  %s  %s%%" % (window.get("display_name"), window.get("utilization")))
PY

printf '\n\033[32mDone.\033[0m The segment appears next time the statusline redraws.\n'
printf 'Log: %s\n' "$PLUGIN_DIR/usage-feeder.log"
