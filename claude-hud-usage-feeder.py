#!/usr/bin/env python3
"""Feed model-scoped weekly quota (e.g. Fable) to the claude-hud statusline.

Why this exists
    Claude Code's statusline stdin only carries `rate_limits.five_hour` and
    `rate_limits.seven_day`. It does not carry `model_scoped` -- the per-model
    weekly window that shows up as "Fable" in the Claude apps. claude-hud
    >= 0.7.0 can read those windows from a local snapshot file
    (`display.externalUsagePath`); this script is what writes that file.
    claude-hud itself never touches the network.

Three sources, tried in order; the first one that yields scoped windows wins
    1. cswap (claude-swap) `status --json` -- preferred, ~0.3s. It ships its own
       credentials and talks to the usage endpoint directly, so it spawns no
       `claude` subprocess, fires no hooks, and needs no privacy flag touched.
       It TTL-gates its own upstream calls (180-600s), so polling it frequently
       does not translate into API traffic. Requires the active account to be
       managed by cswap; when it is not, the JSON simply has no `usage` field
       and we fall through.
    2. Direct OAuth: GET /api/oauth/usage, ~0.9s. No local dependencies beyond
       a readable access token.
    3. Claude Code's `get_usage` control request -- last resort, ~2.5s. Invokes
       no model and costs no tokens, but it does start a `claude` subprocess and
       therefore fires SessionStart/SessionEnd hooks.

    All three hit the same endpoint against the same per-identity budget
    (roughly 28-30 requests/hour for non-first-party user agents), so this is a
    fallback chain, not a fan-out.

Field mapping
    cswap:  active.usage.{fiveHour,sevenDay,scoped[]} -> pct / resetsAt / name
    oauth:  limits[] -> kind (session|weekly_all|weekly_scoped), percent,
            resets_at, scope.model.display_name
    Percentages are already 0-100 on both sides and timestamps are ISO 8601,
    which is exactly the shape claude-hud wants.

    Note we deliberately do NOT read the CLI's own `rate_limits.model_scoped`:
    it is filtered server-side by the `tengu_usage_overage_included_models`
    gate and comes back empty. We map `limits[]` ourselves instead.

Privacy flag (affects source 3 only)
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 also disables the usage endpoint,
    and the CLI tests it for truthiness -- setting it to "0" still counts as
    enabled; only an empty string turns it off. Source 3 therefore clears it for
    that one short-lived subprocess while setting DISABLE_TELEMETRY and
    DO_NOT_TRACK: the CLI's decision chain is nonessential -> telemetry ->
    do_not_track, so the quota endpoint is allowed while analytics stay off.
    Your global setting is never modified.

Environment overrides (all optional)
    CLAUDE_CONFIG_DIR      Claude Code config dir. Default ~/.claude
    HUD_FEEDER_PLUGIN_DIR  Where the snapshot and log live.
                           Default $CLAUDE_CONFIG_DIR/plugins/claude-hud
    HUD_FEEDER_LABELS      JSON map renaming statusline labels, keys matched
                           case-insensitively, e.g. {"fable": "f"}
    HUD_FEEDER_SOURCES     Comma-separated subset/order of cswap,oauth,claude-cli
    CSWAP_BIN / CLAUDE_BIN Absolute paths to those binaries
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

CONFIG_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
PLUGIN_DIR = (os.environ.get("HUD_FEEDER_PLUGIN_DIR")
              or os.path.join(CONFIG_DIR, "plugins", "claude-hud"))
SNAPSHOT = os.path.join(PLUGIN_DIR, "usage-snapshot.json")
LOG = os.path.join(PLUGIN_DIR, "usage-feeder.log")
CONFIG_FILE = os.path.join(PLUGIN_DIR, "usage-feeder.json")

LOG_MAX_BYTES = 256 * 1024
LOG_KEEP_LINES = 200
TIMEOUT_SEC = 120

# Only used as the User-Agent for the direct OAuth call. The endpoint wants to
# see a claude-code UA; the exact version has not mattered in practice.
CLAUDE_CODE_UA_VERSION = os.environ.get("HUD_FEEDER_UA_VERSION", "2.1.226")

USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"


def find_binary(name, env_var, extra_dirs):
    """Locate a helper binary.

    Explicit env override wins, then PATH, then the usual install locations --
    launchd and cron hand us a minimal PATH that contains neither ~/.local/bin
    nor /opt/homebrew/bin, which is the single most common reason a scheduled
    run fails while the same command works fine in a terminal.
    """
    override = os.environ.get(env_var)
    if override:
        return override
    found = shutil.which(name)
    if found:
        return found
    for directory in extra_dirs:
        candidate = os.path.join(os.path.expanduser(directory), name)
        if os.access(candidate, os.X_OK):
            return candidate
    return name  # not found: let it fail with a legible OSError


CSWAP_BIN = find_binary(
    "cswap", "CSWAP_BIN",
    ("~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"))
CLAUDE_BIN = find_binary(
    "claude", "CLAUDE_BIN",
    ("/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.claude/local"))


def load_label_overrides():
    """Label renames, from HUD_FEEDER_LABELS or the on-disk config.

    The config file is the source of truth so that a hand-run produces exactly
    what the scheduled run produces. Stashing labels only in the scheduler's
    environment means running the script yourself silently writes different
    output, which is a nasty way to lose an afternoon.

    Malformed input is ignored rather than fatal: a bad label should not cost
    you the whole quota display.
    """
    parsed = None
    raw = os.environ.get("HUD_FEEDER_LABELS")
    if raw:
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
    if not isinstance(parsed, dict):
        try:
            with open(CONFIG_FILE) as handle:
                parsed = json.load(handle).get("labels")
        except Exception:
            parsed = None
    if not isinstance(parsed, dict):
        return {}
    return {str(key).strip().lower(): str(value) for key, value in parsed.items()}


LABEL_OVERRIDES = load_label_overrides()

# Applied to source 3's subprocess only. See the module docstring.
SCOPED_SETTINGS = json.dumps({
    "env": {
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "",
        "DISABLE_TELEMETRY": "1",
        "DO_NOT_TRACK": "1",
    }
})

CONTROL_REQUEST = json.dumps({
    "type": "control_request",
    "request_id": "hud_usage",
    "request": {"subtype": "get_usage"},
})


def log(message):
    line = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), message)
    try:
        with open(LOG, "a") as handle:
            handle.write(line)
        trim_log()
    except OSError:
        pass
    sys.stderr.write(line)


def trim_log():
    if os.path.getsize(LOG) < LOG_MAX_BYTES:
        return
    with open(LOG) as handle:
        tail = handle.readlines()[-LOG_KEEP_LINES:]
    with open(LOG, "w") as handle:
        handle.writelines(tail)


def same_instant(a, b):
    """Do two ISO timestamps denote the same moment (60s tolerance)?
    Anything unparseable counts as different."""
    if not a or not b:
        return False
    try:
        import datetime
        delta = (datetime.datetime.fromisoformat(a)
                 - datetime.datetime.fromisoformat(b))
        return abs(delta.total_seconds()) <= 60
    except ValueError:
        return False


def build_scoped(entries, weekly_reset):
    """[(name, percent, resets_at)] -> claude-hud's model_scoped array.

    Every source normalises into this shape, so validation and filtering live
    in exactly one place.
    """
    windows = []
    for name, percent, resets_at in entries:
        if not name or not isinstance(percent, (int, float)):
            continue
        # The server also returns the overall weekly window as a scoped entry
        # named "All models". That is already claude-hud's "Weekly" segment;
        # rendering it twice is noise.
        if name.strip().lower() == "all models":
            continue
        # Never filter on `is_active`: an enforceable scoped limit can report
        # false, and filtering on it silently drops the very window we want.
        label = LABEL_OVERRIDES.get(name.strip().lower(), name)
        window = {"display_name": label, "utilization": percent}
        # Per-model weekly windows currently reset at the same instant as the
        # overall weekly window, which claude-hud already prints next to
        # "Weekly". Printing it again is pure noise, so we omit resets_at when
        # they match -- as a condition, not a blanket rule, so display comes
        # back automatically if the server ever staggers the two.
        if not same_instant(resets_at, weekly_reset):
            window["resets_at"] = resets_at
        windows.append(window)
    return windows


def build_window(pair):
    """(percent, iso_timestamp) -> a five_hour / seven_day snapshot object.

    Missing data is written as explicit nulls. claude-hud treats that the same
    as an absent key, but writing it out makes "the source gave us nothing"
    distinguishable from "we forgot to map it".
    """
    if not pair or not isinstance(pair[0], (int, float)):
        return {"used_percentage": None, "resets_at": None}
    return {"used_percentage": pair[0], "resets_at": pair[1] or None}


def build_usage(five_hour, seven_day, scoped_entries):
    """The single point where all sources converge.

    Why the 5h and weekly windows are written too, even though Claude Code
    supplies them over stdin: a freshly started session has no `rate_limits` in
    stdin at all until its first request completes, and claude-hud then adopts
    the snapshot wholesale. A snapshot carrying only model_scoped would leave
    the statusline showing just the scoped segment, with the 5h and weekly
    segments missing entirely until you send a message. Writing all three
    closes that gap. Whenever stdin does have data it always wins, so a stale
    snapshot value can never mask a live one.
    """
    return {
        "five_hour": build_window(five_hour),
        "seven_day": build_window(seven_day),
        "model_scoped": build_scoped(
            scoped_entries, seven_day[1] if seven_day else None),
    }


def from_cswap():
    """Source 1: cswap status --json.

    CLAUDE_CONFIG_DIR is deliberately stripped from the child environment.
    cswap (0.24.1) reports `managed: null` and an empty `usage` object whenever
    that variable is set -- even when it is set to the default ~/.claude -- so
    inheriting it silently kills this source and everything limps along on the
    slower fallbacks. cswap resolves accounts on its own; what it reports here
    then matches what `cswap status` reports in your shell.
    """
    env = {key: value for key, value in os.environ.items()
           if key != "CLAUDE_CONFIG_DIR"}
    proc = subprocess.run(
        [CSWAP_BIN, "status", "--json"],
        capture_output=True, text=True, timeout=TIMEOUT_SEC, env=env,
    )
    usage = ((json.loads(proc.stdout).get("active") or {}).get("usage")) or {}
    five = usage.get("fiveHour") or {}
    seven = usage.get("sevenDay") or {}
    return build_usage(
        (five.get("pct"), five.get("resetsAt")),
        (seven.get("pct"), seven.get("resetsAt")),
        [(w.get("name"), w.get("pct"), w.get("resetsAt"))
         for w in usage.get("scoped") or []],
    )


def read_access_token():
    """Find an OAuth access token the way Claude Code stores it.

    Two locations, keychain first: the credentials file is a copy that is not
    guaranteed to keep up (tokens more than 8 hours past expiry have been
    observed there while the keychain copy was live). The token stays in
    process memory and is never written to the snapshot or the log.

    We never refresh: refreshing writes back to the keychain and would race
    Claude Code for it. An expired token just means this source is skipped
    until Claude Code refreshes it on its own.
    """
    reasons = []
    for load in (_token_from_keychain, _token_from_file):
        try:
            oauth = load() or {}
        except Exception as err:
            reasons.append(str(err) or type(err).__name__)
            continue
        token = oauth.get("accessToken")
        expires_at = oauth.get("expiresAt")
        if not token:
            reasons.append("no accessToken")
        elif (isinstance(expires_at, (int, float))
              and expires_at / 1000.0 <= time.time()):
            reasons.append("expired")
        else:
            return token
    raise RuntimeError("no usable token (%s)" % "; ".join(reasons))


def _token_from_keychain():
    if sys.platform != "darwin":
        raise RuntimeError("keychain is macOS only")
    proc = subprocess.run(
        ["/usr/bin/security", "find-generic-password",
         "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        raise RuntimeError("keychain miss")
    return json.loads(proc.stdout).get("claudeAiOauth")


def _token_from_file():
    with open(os.path.join(CONFIG_DIR, ".credentials.json")) as handle:
        return json.load(handle).get("claudeAiOauth")


def from_oauth():
    """Source 2: one GET against the usage endpoint."""
    import urllib.request

    request = urllib.request.Request(
        USAGE_ENDPOINT,
        headers={
            "Authorization": "Bearer %s" % read_access_token(),
            "Accept": "application/json",
            "Content-Type": "application/json",
            # Required today; the request is rejected without it.
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/%s" % CLAUDE_CODE_UA_VERSION,
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return from_limits(json.load(response))


def from_limits(payload):
    """Usage-endpoint response body -> normalised usage. Shared by sources 2/3."""
    limits = (payload or {}).get("limits") or []
    by_kind = {}
    for entry in limits:
        by_kind.setdefault(entry.get("kind"), entry)
    session = by_kind.get("session") or {}
    weekly = by_kind.get("weekly_all") or {}
    return build_usage(
        (session.get("percent"), session.get("resets_at")),
        (weekly.get("percent"), weekly.get("resets_at")),
        [(((e.get("scope") or {}).get("model") or {}).get("display_name"),
          e.get("percent"), e.get("resets_at"))
         for e in limits if e.get("kind") == "weekly_scoped"],
    )


def from_claude_cli():
    """Source 3: Claude Code's get_usage control request."""
    proc = subprocess.run(
        [
            CLAUDE_BIN, "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--settings", SCOPED_SETTINGS,
        ],
        input=CONTROL_REQUEST + "\n",
        capture_output=True, text=True, timeout=TIMEOUT_SEC,
        cwd=PLUGIN_DIR,
    )
    rate_limits = None
    for line in proc.stdout.splitlines():
        if '"control_response"' not in line:
            continue
        try:
            payload = json.loads(line)
        except ValueError:
            continue
        response = payload.get("response") or {}
        if response.get("subtype") == "success":
            rate_limits = (response.get("response") or {}).get("rate_limits")
            break
    return from_limits(rate_limits)


# Order is priority. cswap first because it TTL-gates upstream calls and never
# touches credentials; direct OAuth second (fast, but reads a token); the
# `claude` subprocess last because it is the slowest and fires hooks.
ALL_SOURCES = [
    ("cswap", from_cswap),
    ("oauth", from_oauth),
    ("claude-cli", from_claude_cli),
]


def select_sources():
    wanted = os.environ.get("HUD_FEEDER_SOURCES")
    if not wanted:
        return ALL_SOURCES
    order = [name.strip() for name in wanted.split(",") if name.strip()]
    available = dict(ALL_SOURCES)
    return [(name, available[name]) for name in order if name in available]


def write_snapshot(usage):
    snapshot = {"updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    snapshot.update(usage)
    handle, tmp = tempfile.mkstemp(dir=PLUGIN_DIR, prefix=".usage-snapshot.")
    try:
        with os.fdopen(handle, "w") as out:
            json.dump(snapshot, out)
        os.chmod(tmp, 0o600)
        os.replace(tmp, SNAPSHOT)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    sources = select_sources()
    if not sources:
        log("FAIL HUD_FEEDER_SOURCES matched no known source")
        return 1

    failures = []
    for name, fetch in sources:
        try:
            usage = fetch()
        except Exception as err:
            failures.append("%s: %s %s" % (name, type(err).__name__, err))
            continue
        # Scoped windows are the whole reason this exists. A source that cannot
        # produce them is no use to us, even if it returned the other windows.
        if not usage["model_scoped"]:
            failures.append("%s: no scoped windows" % name)
            continue
        write_snapshot(usage)
        # Record skipped sources too. Otherwise an earlier source can fail
        # silently for months and the log still reads like everything is fine.
        log("OK via %s -- %s%s" % (
            name,
            ", ".join("%s %s%%" % (w["display_name"], w["utilization"])
                      for w in usage["model_scoped"]),
            " [skipped: %s]" % "; ".join(failures) if failures else "",
        ))
        return 0

    # Leave the old snapshot alone when everything fails: it expires on its own
    # and claude-hud then hides the segment, which beats showing a stale number
    # as if it were current.
    log("FAIL all sources (%s), snapshot left untouched" % "; ".join(failures))
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # never hand the scheduler a silent exit code
        log("FAIL %s: %s" % (type(err).__name__, err))
        sys.exit(1)
