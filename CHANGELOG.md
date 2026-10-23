# Changelog

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
