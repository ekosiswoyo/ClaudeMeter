# ClaudeMeter

A tiny macOS menu bar app that shows your Claude plan usage limits.

- **Menu bar:** `✳︎ 42%` = current 5-hour session usage (turns orange at 75%, red at 90%)
- **Menu:** session (5h) and weekly limits with reset countdowns, plus local Claude Code token totals

## Build & run
    ./build.sh
    open ClaudeMeter.app

Start at login: System Settings → General → Login Items → add `ClaudeMeter.app`.

## Where the data comes from
1. **Plan limits:** the same usage endpoint Claude Code's `/usage` uses, authenticated with the
   Claude Code login stored in your Keychain (read via `/usr/bin/security`; never written or refreshed).
   This endpoint is undocumented and may change.
2. **Local tokens:** parsed from `~/.claude/projects/**/*.jsonl` (last 7 days, only changed files re-read).

Run with `--local-only` to skip the network/Keychain completely.

## Footprint
~150 KB on disk, ~19 MB RAM, ~0% CPU idle (refreshes every 5 min).
