# Changelog

Lossless Handoff, formerly claude-handoff.

## [0.7.0] - 2026-11-14

Automatic recall indexing (machine-setup F44.13, hooks 1.8.0).

- `recall.py index --all` indexes every Claude Code project that sits in a git repo, newest first, with a time cap (`--max-seconds`), one summary line per project.
- `recall.py session-end` is a new `SessionEnd` hook: when a chat ends it starts a detached index of that project and prints nothing; it always exits 0.
- `install.sh` registers the `SessionEnd` hook (timeout 5) and records it so `uninstall.sh` removes only what was added.
- `install.sh` offers `ollama pull bge-m3` when `ollama` is on PATH (asks y/N interactively, `--yes` says yes, a non-interactive run skips with a hint). Without Ollama it prints the download link and continues; keyword search still works. Ollama is never installed for you.
- `install.sh` installs a macOS LaunchAgent `com.lossless-handoff.recall-index` (daily 03:30, `index --all`); `--no-nightly` skips it. On Linux it prints the crontab line.
- `install.sh` starts the first `index --all` in the background after install. New flags: `--yes`, `--no-nightly`.
- `uninstall.sh` removes the `SessionEnd` entry (if install added it) and boots out and deletes the LaunchAgent. Indexes, logs and state are kept.
- `precompact-handoff.py`, `postcompact-inject.py` and `recall.py` 1.8.0 copied from machine-setup.
- `tests/smoke.sh` covers the SessionEnd hook, `index --all`, the `--yes` and non-interactive model-pull paths, and uninstall.

## [0.6.1] - 2026-11-14

Long messages in full, a cold-model timeout fix, and measured results (machine-setup F44.12).

- `recall.py open <id> --full` now returns up to 40,000 characters of a message, and `--from <N>` pages through longer ones. A cut message ends with the exact command to continue. Found by a test that saw a 14,300-character message cut at the old 12,000-character output cap.
- Embedding calls wait up to 30 s for a cold model and ask Ollama to keep it loaded (`keep_alive`), so the first search after a pause no longer falls back to keyword only.
- The new-chat context and handoff now say the decisions list and your latest words win over recall when they disagree.
- `precompact-handoff.py`, `postcompact-inject.py` and `recall.py` 1.7.1 copied from machine-setup.
- LICENSE copyright line now carries the author's name.
- README: new "Proof it works" section with measured retrieval, meaning-search and alignment results, including limits.
- `tests/smoke.sh` checks that a 50,000-character message reassembles byte-exactly from `open --full` plus `open --full --from 40000`.

## [0.6.0] - 2026-11-14

Renamed to Lossless Handoff, based on the LCM paper (arXiv:2605.04050), plus recall (machine-setup F44, F44.9, F44.10, F44.11).

- Renamed from claude-handoff to Lossless Handoff (repo `lossless-handoff`; GitHub redirects the old URL). Install paths, the state folder `~/.local/state/claude-handoffs` and hook command names are unchanged, so existing installs upgrade in place. README now credits the LCM paper by Clint Ehrlich and Theodore Blackman.
- New `recall.py`: search, open, user, handoffs and index over the transcripts of all chats in the same project. Hybrid search merges word hits with optional meaning hits from a local embedding model (Ollama `bge-m3` by default; `RECALL_EMBED_URL`, `RECALL_EMBED_MODEL`, `RECALL_EMBED_BACKEND`, `RECALL_EMBED_KEY`). Words work without any setup. Secrets are redacted before output and before embedding.
- Handoffs and new-chat context now carry one line telling the model that recall exists.
- The meaning index is refreshed at each compaction by a detached background indexer that never delays or fails the hook.
- `precompact-handoff.py` and `postcompact-inject.py` 1.7.0 copied from machine-setup. RESOLVED and SUPERSEDED lines keep their full original text (the 700-character cap no longer cuts `was:` and `| why:`).
- `precompact-handoff.py --ledger-repair <dir>` restores cut RESOLVED/SUPERSEDED lines from the newest backup that still holds the full entry.
- `--ledger-maintain` rejects a missing directory (exit 2) and creates nothing when there is no ledger.
- An active ledger line without `| why:` is injected anyway and logged to `hooks-error.jsonl`, instead of being skipped.
- `install.sh` installs `recall.py`, adds the allow rule `Bash(python3 ~/.claude/hooks/recall.py:*)` (idempotent) and prints the one-time index command; `uninstall.sh` removes `recall.py` and that rule. `tests/smoke.sh` covers recall.

## [0.5.0] - 2026-11-09

Ledger kinds, lossless injection, later reminders (machine-setup F40.x, F41, F42, F43).

- `precompact-handoff.py` and `postcompact-inject.py` 1.6.0 copied from machine-setup.
- Decision kinds: every ledger entry is tagged `[rule]`, `[decision]` or `[task]` (untagged old lines count as decisions). New `RESOLVE D<n>: <reason>` marks finished tasks and one-offs `RESOLVED` (kept in the file, no longer injected). Rules are never resolved by the model.
- Lossless injection: the ledger is injected in three parts (`--ledger --part 1/2/3`) at compaction, `startup` and `resume`. Standing rules come first and always in full, then decisions, then tasks; entries that do not fit in full become one-line index entries, so nothing is dropped.
- `--ledger-maintain <repo>`: one pass over an existing list that tags entries, resolves finished tasks and supersedes contradictions, without adding entries or editing text.
- Handoff file: seventh heading `Parallel work running` (background agents and long jobs, or "none"); a stale-note warning when the model's own handoff did not change its living sections since the last reminder.
- `handoff-nudge.py`: reminders at 75% of the window, then every 25,000 tokens (was 50,000), plus one final "Compaction is imminent" note. Steps stay 12,000 tokens below the real compaction point (window minus 33,000): 300k, 325k, 350k and a final at 355k for a 400k window. Records section hashes so a stale handoff is called out. The nudge also asks the model to list standing rules under Decisions and why.
- `install.sh` registers `--ledger --part 1/2/3` for `compact`, `startup` and `resume`, and replaces the old single `--ledger` entry on re-run. `uninstall.sh` removes all of them.
- `tests/smoke.sh` updated for three parts, no-loss check over 40 entries, and the new nudge cadence.

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
