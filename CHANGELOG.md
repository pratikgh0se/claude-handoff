# Changelog

## [0.4.0] - 2026-10-27

Faster decisions updates (machine-setup F40).

- `precompact-handoff.py` 1.5.0 copied from machine-setup. The decisions merge now returns only the changes (new decisions and `SUPERSEDE` lines) and code applies them to the list, so the call is much shorter. Entries are still never deleted.
- Own timeout: `HANDOFF_LEDGER_TIMEOUT` (seconds, 1-300, default 100), independent of the summary timeout. The PreCompact hook timeout is now 150; `install.sh` registers 150 and raises an older 90 on re-run.
- Catch-up: the merge reads your messages oldest first, up to 40,000 characters per run, so a backlog is caught up over several compactions instead of being dropped.
- Synthetic entries (tool output, command echoes, task notifications) no longer count as your messages for freshness, the merge input or "Last user messages".
- Health lines gain `ledger_error` (`timeout`, `exit <rc>`, `parse`, `locked` or an exception name) when the update fails.

## [0.3.0] - 2026-10-25

Per-project decisions ledger (machine-setup F39 to F39.11).

- `precompact-handoff.py` 1.4.2 and `postcompact-inject.py` copied from machine-setup. At every compaction a second Sonnet call merges your decisions since the last update into `~/.local/state/claude-handoffs/projects/<project>-<hash>/decisions.md` (project = git root, else the folder). Entries are only marked `SUPERSEDED`, never deleted; code restores dropped entries, rejects invalid output, caps lines at 700 characters, keeps 20 backups and holds a lock per project.
- New injection: `postcompact-inject.py --ledger --part 1/2` after compaction (full list, newest first), and `--ledger` at session `startup` and `resume` (active decisions, about 4,000 characters).
- Handoff file layout: authority line (user's latest words > Project decisions > Agent handoff > Fresh summary > Claude Code's summary > Facts), no `## Decisions via questions` section, cap 14,000 characters, tool lines end `-> ok`, `-> error` or `-> no result`.
- New switches: `HANDOFF_LEDGER=0` disables the list entirely; `HANDOFF_LEDGER_MODEL` picks its model. Health lines gain ledger status and counts.
- `install.sh` registers the two `--ledger --part` commands in the `compact` group and new `startup` and `resume` groups (idempotent; the double-registration check covers them). `uninstall.sh` removes exactly those and keeps the ledgers, saying so.
- `tests/smoke.sh`: shim tells the merge call from the summary call; cases for ledger creation, restore on drop, all inject modes, `HANDOFF_LEDGER=0`, install/uninstall of the new groups. Git-specific check prints SKIP without git.
- Cost: two Sonnet calls per compaction, about $0.10-0.20, 20-40 s. Measured on 96 questions about earlier decisions: 13.5 -> 56 out of 100 (README).

## [0.2.0] - 2026-10-23

- `precompact-handoff.py` 1.3.0 (machine-setup F38): a fresh Sonnet summary of the conversation since the last compaction is written at every compaction (`claude -p --model sonnet`, isolated flags), placed after the model's own handoff. It replaces the Haiku fallback.
- New switches: `HANDOFF_SUMMARY=0` disables it, `HANDOFF_SUMMARY_MODEL` (default `sonnet`), `HANDOFF_SUMMARY_TIMEOUT` (seconds, default 75). `HANDOFF_HAIKU_FALLBACK=0` still disables it.
- Health lines gain `summary_model`; the section is headed `## Fresh summary at compaction (<model>; verify against facts)` and failures read `Fresh summary failed: <reason>`.
- `tests/smoke.sh`: cases with a fake `claude` shim (summary placement, disable switch, model override, timeout).
- README: blind-test quality numbers, configuration table, cost FAQ; SECURITY.md describes the per-compaction call.
- `install.sh` reports version 0.2.0; nothing else in install/uninstall changes.

## 0.1.0 - 2026-10-20

Extracted from machine-setup v1.0.0 (the Bento handoff system, spec features F35 to F37).

- PreCompact hook `precompact-handoff.py` and SessionStart hook `postcompact-inject.py` copied unchanged.
- New `handoff-nudge.py` (PostToolUse): built-in handoff nudge at 75% of the window, then every 50k tokens, with the same text and meta file as the Bento compact plugin.
- `install.sh` / `uninstall.sh`: idempotent settings merge, backups, dry-run.
- `install.sh --help` lists all flags and the version; new `--version` flag.
- `tests/smoke.sh`: install, hooks, nudge, uninstall in a temporary HOME. Runs on macOS and Linux.
- GitHub Actions CI (`.github/workflows/ci.yml`): `bash -n`, shellcheck, `py_compile` and the smoke test on ubuntu-latest and macos-latest.
- `SECURITY.md` and a bug report issue template.
- Nudge text identifies itself as coming from the user's installed claude-handoff hook (not the tool result), so models do not dismiss it as prompt injection.
- `install.sh` refuses (exit 2) when the same hooks are registered from another path, to avoid double execution; `--force` overrides.
- README FAQ: `CLAUDE_CODE_AUTO_COMPACT_WINDOW` must be set in user settings or the shell (project settings did not override it); the window must comfortably exceed baseline context (very small windows below about 150k compact before the nudge); one very large tool result can skip the nudge, the PreCompact fallback still writes a handoff.
- README: prerequisites, one-line install, exact list of changes, FAQ, troubleshooting, CI badge.
