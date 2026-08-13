#!/usr/bin/env bash
#
# Try on statusline labels before committing to one. Renders each candidate
# through your real claude-hud statusline command, then restores the snapshot.
#
#   ./tools/preview-labels.sh            # a curated set of candidates
#   ./tools/preview-labels.sh f 🦊 📜    # only these
#
set -uo pipefail

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
PLUGIN_DIR=$CONFIG_DIR/plugins/claude-hud
SNAPSHOT=$PLUGIN_DIR/usage-snapshot.json
FEEDER=$CONFIG_DIR/scripts/claude-hud-usage-feeder.py
SETTINGS=$CONFIG_DIR/settings.json

[ -f "$SNAPSHOT" ] || { echo "no snapshot at $SNAPSHOT -- run install.sh first" >&2; exit 1; }

CMD=$(python3 -c "
import json, sys
try:
    with open('$SETTINGS') as handle:
        print(json.load(handle)['statusLine']['command'])
except Exception:
    sys.exit('could not read statusLine.command from $SETTINGS')
") || exit 1

BAK=$(mktemp /tmp/hud-snap-bak.XXXXXX)   # BSD mktemp wants the Xs last
cp "$SNAPSHOT" "$BAK"

restore() {
  # Prefer a genuinely fresh snapshot; fall back to the backup if the feeder
  # is unavailable or fails.
  [ -x "$FEEDER" ] && "$FEEDER" >/dev/null 2>&1 || cp "$BAK" "$SNAPSHOT"
  rm -f "$BAK"
  printf '\n\033[2m--- restored ---\033[0m\n'
}
trap restore EXIT

STDIN=$(python3 - "$(date +%s)" <<'PY'
import json, sys
now = int(sys.argv[1])
print(json.dumps({
    "hook_event_name": "Status", "session_id": "preview",
    "transcript_path": "/dev/null", "cwd": ".",
    "model": {"id": "claude-opus-5", "display_name": "Opus 5"},
    "workspace": {"current_dir": ".", "project_dir": "."},
    "version": "2.1.226", "output_style": {"name": "default"},
    "cost": {"total_cost_usd": 0.0, "total_duration_ms": 0,
             "total_lines_added": 0, "total_lines_removed": 0},
    "exceeds_200k_tokens": False,
    # NB: resets_at over stdin is epoch seconds, not an ISO string -- a string
    # parses to null and the reset time silently disappears.
    "rate_limits": {"five_hour": {"used_percentage": 6, "resets_at": now + 10920},
                    "seven_day": {"used_percentage": 50, "resets_at": now + 227700}}}))
PY
)

render() {
  python3 -c "
import json, sys, time
json.dump({'updated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
           'model_scoped': [{'display_name': sys.argv[1], 'utilization': 84.0}]},
          open('$SNAPSHOT', 'w'))" "$1"
  printf '  '
  printf '%s' "$STDIN" | eval "$CMD" | sed -n '2p' | sed 's/^.*Weekly/Weekly/'
  printf '\n'
}

echo
if [ "$#" -gt 0 ]; then
  render "Fable"
  for label in "$@"; do render "$label"; done
  exit 0
fi

echo "=== as-is ==="
render "Fable"

# Plain characters inherit claude-hud's label colour, so the line stays visually
# uniform. Prefer ones whose East Asian Width is N or Na: an "ambiguous" width
# character silently becomes double-width in CJK terminals configured that way.
echo "=== plain characters ==="
for label in "ƒ" "𝑓" "Ⓕ" "ⓕ" "✦" "✧" "❖" "◆" "▲" "★" "✳" "✷" "❯" "§"; do render "$label"; done

# Emoji carry their own colour and ignore the ANSI styling around them.
echo "=== emoji ==="
for label in "🦊" "📜" "📖" "🪶" "🎭" "🦉" "🐉" "🔱" "🏛" "⚡" "✨" "🪄" "🧠" "🔮"; do render "$label"; done

echo "=== combinations ==="
for label in "🦊 Fable" "ƒ Fable" "✦ Fable" "Fable 🦊"; do render "$label"; done
