# claude-hud-usage-feeder

Show your **per-model weekly quota** — the one the Claude apps label `Fable` — in the [claude-hud](https://github.com/jarrodwatts/claude-hud) statusline.

<!-- The pointer is aligned by character count: ƒ sits at column 63. Recompute it
     if the sample line changes, or it will drift a column and look wrong. -->
```
Usage █░░░░░░░░░ 6% (3h 2m) | Weekly █████░░░░░ 50% (2d 15h) | ƒ ████████░░ 84%
                                                               └── this part
```

Everything before it is claude-hud as it ships. `ƒ` here is a renamed `Fable` — see [Renaming the label](#renaming-the-label).

## Why this is needed

Claude Code's statusline hands plugins a JSON payload on stdin, and that payload only carries `rate_limits.five_hour` and `rate_limits.seven_day`. It does **not** carry `model_scoped`, the per-model weekly window. claude-hud 0.7.0+ can render those windows, but only if something hands it a local snapshot file via `display.externalUsagePath` — and nothing writes that file.

This is that something. It polls your quota on a timer and writes the snapshot; claude-hud reads it. claude-hud itself never touches the network.

If Claude Code ever forwards `model_scoped` over stdin, this becomes redundant — uninstall it and the statusline keeps working, because stdin always wins over the snapshot.

## Requirements

- claude-hud **0.7.0+** (`display.externalUsagePath` landed there)
- Python 3 (the system one on macOS is fine — no third-party packages)
- A Claude subscription that actually has a per-model weekly window
- macOS for the bundled scheduler; everything else works anywhere, see [Linux](#linux)

## Install

```bash
git clone https://github.com/iTofu/claude-hud-usage-feeder.git
cd claude-hud-usage-feeder
./install.sh
```

That copies the feeder to `~/.claude/scripts/`, points claude-hud's config at the snapshot, registers a launchd agent that runs every 10 minutes, and does one run to prove it works. Re-running is safe.

```
./install.sh --hooks                     # refresh after every turn, not on a timer
./install.sh --interval 300              # refresh every 5 minutes
./install.sh --label 'Fable=ƒ'           # rename the statusline label
./install.sh --no-timer                  # install only; schedule it yourself
```

Uninstall removes all of it, including the two config keys it added:

```bash
./uninstall.sh
```

## Where the numbers come from

Three sources, tried in order, first one that yields scoped windows wins. Each is exercised by knocking out the one above it.

| # | Source | Cost | Notes |
|---|---|---|---|
| 1 | [`cswap status --json`](https://github.com/realiti4/claude-swap) | ~0.3s | Preferred. Ships its own credentials, spawns nothing, fires no hooks, and TTL-gates its own upstream calls (180–600s) so frequent polling doesn't become API traffic. Needs the active account to be managed by cswap. |
| 2 | `GET /api/oauth/usage` | ~0.9s | No local dependencies. Reads Claude Code's OAuth token — **keychain first**, credentials file only as a fallback (that file goes stale; tokens 8h past expiry have been seen there while the keychain copy was live). Never refreshes the token, because refreshing writes back to the keychain and would race Claude Code. |
| 3 | `claude` `get_usage` control request | ~2.5s | Last resort. Invokes no model and costs no tokens, but starts a `claude` subprocess and therefore fires SessionStart/SessionEnd hooks. |

All three hit the same endpoint against the same per-identity budget (~28–30 requests/hour for non-first-party user agents), so this is a fallback chain, not a fan-out.

Pin the order yourself with `HUD_FEEDER_SOURCES=oauth,cswap`, or drop one entirely by omitting it.

### Two traps worth knowing about

**The CLI's own `model_scoped` is empty.** `rate_limits.model_scoped` gets filtered server-side by the `tengu_usage_overage_included_models` gate. Reading it the obvious way returns `[]`. This maps `limits[]` itself instead, picking `kind == "weekly_scoped"`.

**`is_active` lies.** An enforceable scoped limit can report `is_active: false`. Filtering on it drops the very window you're trying to display. This never filters on it.

**`CLAUDE_CONFIG_DIR` mutes cswap.** With that variable set — even to its own default, `~/.claude` — cswap 0.24.1 reports `managed: null` and an empty `usage` object. Inherit it into the subprocess and source 1 silently stops working while everything limps along on the slower fallbacks. It is stripped from cswap's environment here, and `install.sh` only exports it at all when it is genuinely non-default.

## Refresh cadence

By default a timer runs every 10 minutes. That works, but it is polling: it spends requests while you are idle and lags by up to 10 minutes while you are not.

`--hooks` makes it event-driven instead. Claude Code's `Stop` and `SessionStart` events fire the feeder, so the number updates seconds after each turn — which is exactly when quota moves.

```bash
./install.sh --hooks
```

It costs no extra API requests, because each source carries its own minimum interval:

| Source | Min interval | Why |
|---|---|---|
| cswap | 10s (debounce) | cswap enforces a **180s freshness floor internally, shared across every surface that reads it**. Calling it more often cannot produce upstream traffic: you either read its store for free or trigger the fetch it was going to make anyway. |
| oauth | 300s | A real request each time, against a budget of ~28–30 per rolling hour per token. That budget is not a leaky bucket — a burst saturates it for a full hour — and cswap already reserves most of it. |
| claude-cli | 600s | Same cost, plus a subprocess and a round of hooks. |

A throttled source **stops the run** rather than falling through to a pricier one. Being throttled means the snapshot is already as fresh as this trigger can make it, so spending a request to learn the same number would defeat the purpose. Only a genuine failure falls through — which makes the throttle a circuit breaker too: if the cheap source starts failing silently, a per-turn trigger still cannot burn the budget.

**Keep the timer even with hooks** (it relaxes to 30 minutes automatically). Quota is per identity, so anything you spend on claude.ai, the phone app, or another machine never fires your local `Stop` hook.

Under an event trigger, successful runs that change nothing are not logged — otherwise the log fills with identical lines. Failures always are. `HUD_FEEDER_VERBOSE=1` logs every decision, throttles included.

## Renaming the label

The snapshot's `display_name` is entirely yours — claude-hud only strips ANSI/control characters and truncates at 64 chars, so plain characters and emoji both pass through, and its renderer measures grapheme widths correctly so nothing misaligns.

```bash
./install.sh --label 'Fable=ƒ'
```

The map is stored in `~/.claude/plugins/claude-hud/usage-feeder.json`, not in the scheduler's environment — so running the feeder by hand produces exactly what the scheduled run produces. Re-running `install.sh` without `--label` leaves it alone.

To see the options first:

```bash
./tools/preview-labels.sh          # a curated set
./tools/preview-labels.sh ƒ 🦊 📜  # just these
```

It renders each candidate through your real statusline and restores the snapshot on exit.

Two things the preview shows that a list of characters cannot:

- **Plain characters inherit claude-hud's label colour**; emoji carry their own and ignore the ANSI styling around them. So `ƒ` blends in with `Usage` / `Weekly`, while `🦊` is a splash of colour in an otherwise uniform line.
- **Width is not obvious.** Prefer characters whose East Asian Width is `N`/`Na`. Something like `✦` is `A` (ambiguous) and silently becomes double-width in CJK terminals configured that way, shifting your layout depending on which machine you're on. `ƒ` (U+0192) is `N`, so it's one cell everywhere.

A rename that no longer matches falls back to whatever the upstream name is, so an upstream rename degrades to showing the real name rather than silently losing the label.

## Configuration

Everything is optional; `install.sh` writes the ones you need into the launchd agent.

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code config dir |
| `HUD_FEEDER_PLUGIN_DIR` | `$CLAUDE_CONFIG_DIR/plugins/claude-hud` | Where the snapshot and log live |
| `HUD_FEEDER_LABELS` | from `usage-feeder.json` | JSON rename map, keys matched case-insensitively. Overrides the file. |
| `HUD_FEEDER_SOURCES` | all three | Comma-separated subset/order |
| `CSWAP_BIN` / `CLAUDE_BIN` | auto-discovered | Absolute paths |

Binaries are located via `$PATH` and then the usual install locations, because launchd and cron hand you a minimal `PATH` containing neither `~/.local/bin` nor `/opt/homebrew/bin` — the most common reason a scheduled run fails while the same command works in a terminal.

## Privacy

If you've set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, be aware it also disables the usage endpoint, so sources 2 and 3 need it lifted. Source 3 clears it **for its own short-lived subprocess only**, while setting `DISABLE_TELEMETRY=1` and `DO_NOT_TRACK=1` — the CLI's decision chain is `nonessential → telemetry → do_not_track`, so the quota endpoint is allowed while analytics stay off. Your global setting is never modified.

The OAuth token stays in process memory. It is never written to the snapshot or the log. The snapshot is written `0600` via an atomic temp-file rename.

## Troubleshooting

**The segment is missing.** The feeder died. claude-hud hides a stale snapshot rather than showing a wrong number, and it does not warn you — the log is the only signal:

```bash
tail ~/.claude/plugins/claude-hud/usage-feeder.log
```

A successful line records skipped sources too, so a source that has been failing for months is visible rather than silent:

```
2026-08-13T12:46:59+0800 OK via oauth -- Fable 84.0% [skipped: cswap: FileNotFoundError ...]
```

**Nothing at all in the log.** The scheduler isn't running:

```bash
launchctl print gui/$UID/io.github.itofu.claude-hud-usage-feeder | grep -E 'state|runs|last exit'
```

**`no scoped windows`.** Every source reached the API but none reported a per-model weekly window. Usually that means your account doesn't currently have one.

## Linux

The feeder is portable (source 2 falls back to the credentials file where there's no keychain). Only the scheduler is macOS-specific — use `--no-timer` and add a cron entry:

```
*/10 * * * * $HOME/.claude/scripts/claude-hud-usage-feeder.py
```

Untested there; reports welcome.

## License

MIT
