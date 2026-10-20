# claude-handoff

Auto-compaction plus a handoff for Claude Code. Extracted from [Bento (machine-setup)](https://github.com/pratikgh0se/machine-setup) v1.0.0. Three small hooks, no dependencies beyond Python 3, one command to install and one to remove.

## The problem

Long Claude Code sessions lose context when they compact. The summary Claude Code writes is generic. It drops the exact next step, the dead ends you already ruled out, and your latest instructions. After a compaction the model often re-does work or asks what you wanted.

## What it does

![Handoff timeline](docs/handoff-timeline.svg)

1. **Nudge** (`handoff-nudge.py`, PostToolUse). When context reaches 75% of the auto-compact window, and again every 50,000 tokens, one short note is appended to a tool result asking the working model to write its own handoff to `~/.local/state/claude-handoffs/<session_id>-agent.md` with six fixed headings: Goal, Decisions and why, Done, In progress, Dead ends, Exact next step. It costs no extra turn. The hook also records in `<session_id>-agent.meta.json` when the model wrote the file.
2. **Handoff** (`precompact-handoff.py`, PreCompact). Just before compaction it writes `<session_id>-latest.md` (capped at 20,000 chars):
   - the model's own handoff, if it is fresh;
   - otherwise a short summary written by a Haiku call (`claude -p --model haiku`), clearly labelled "verify against facts";
   - always a facts section extracted from the transcript without any model: your last 8 messages, files touched, task state, git branch and status, last Bash commands, last assistant message.
   It always exits 0 and never blocks compaction. If anything fails inside it, a minimal handoff is still written.
3. **Inject** (`postcompact-inject.py`, SessionStart with matcher `compact`). After compaction it feeds the handoff back into the new context. Claude Code caps each hook's injected text at 10,000 characters, so it runs three times (`--part 1/2/3`); long handoffs are split on section boundaries and the full file path is always named.

What works without the model's cooperation: if the model never writes the agent file, you still get the Haiku summary plus the facts section (spec section 4 and F35.B; status `reduced`). If Haiku is disabled or fails too, you get the facts section only, and the injected text starts with a `HANDOFF DEGRADED` warning line (spec F36.D). The Haiku fallback needs the `claude` binary on `PATH`.

Why a 400k window: the default window is 1M tokens, so sessions rarely compact and pay for their whole context on every turn. A shorter window lowers per-turn cost and avoids the quality loss of very long contexts. The price is more compactions, which the handoff makes safe. See [ADR 0001](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0001-compact-window-400k-with-handoff.md). Use `--window N` to pick another value (Claude Code ignores values below 40000) or `--no-window` to keep the default.

## Install

```
git clone <this repo> claude-handoff && cd claude-handoff
./install.sh --dry-run   # show the plan
./install.sh
```

Requires bash, python3, and macOS or Linux. Options: `--window N`, `--no-window`, `--dry-run`. It is idempotent.

It changes:

- copies `precompact-handoff.py`, `postcompact-inject.py`, `handoff-nudge.py` to `~/.claude/hooks/` (an existing file with a different content is first saved to `~/.claude/hooks/.claude-handoff-backup-<timestamp>/`);
- merges into `~/.claude/settings.json` (backup `settings.json.bak-<timestamp>`): a PreCompact hook (timeout 90), a PostToolUse hook (matcher `*`, timeout 5), a SessionStart `compact` group with the three inject commands (timeout 10), `permissions.allow` entry `Edit(~/.local/state/claude-handoffs/**)` so the model can write its handoff without a prompt, and `env.CLAUDE_CODE_AUTO_COMPACT_WINDOW` = `"400000"` unless already set;
- creates `~/.local/state/claude-handoffs/`.

Your other hooks and settings are left alone. Restart Claude Code afterwards.

## Uninstall

```
./uninstall.sh
```

Removes exactly those hook entries (matched by command path), the allow rule and the window value if install added them, and the three hook files, after backing up settings. Handoff files stay in `~/.local/state/claude-handoffs/`; delete that folder yourself if you want them gone. Backups are kept.

## What gets written where

| Path | Content |
|---|---|
| `~/.local/state/claude-handoffs/<sid>-latest.md` | The handoff that is injected after compaction. `<sid>-<timestamp>.md` is a copy. |
| `<sid>-agent.md` | The model's own handoff (written by the model). |
| `<sid>-agent.meta.json` | Nudge state and timestamps (numbers only, no text). |
| `health.jsonl` | One JSON line per compaction: time, trigger, agent file fresh/stale/absent, fallback result, duration, size, status `ok` / `reduced` / `degraded`. No message text or paths. Rotates at 5,000 lines. |
| `<sid>-last-health.json`, `<sid>-degraded.json` | Per-session status and degraded reasons. |

Files older than 14 days are cleaned up automatically. The directory is outside `~/.claude/` because Claude Code refuses model writes under that path ([ADR 0008](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0008-handoffs-directory-under-local-state.md)).

## Verify

After install, check that the hook runs on a manual compaction:

```
claude -p --model haiku "say hi" --output-format json   # note the session_id
claude -p --model haiku --resume <session_id> "/compact"
tail -n 3 ~/.local/state/claude-handoffs/health.jsonl
```

A new line with `"trigger": "manual"` means the PreCompact hook fired. In a normal interactive session, run `/compact` and look at the same file. `status` is `ok` (model handoff used), `reduced` (Haiku fallback used) or `degraded` (see the table above and spec F36). You can also run `tests/smoke.sh`; it uses a temporary HOME and does not touch your real settings.

## Configuration

Environment variables the hooks honour:

| Variable | Effect |
|---|---|
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Window size in tokens. The nudge thresholds are 75% of it, then every 50,000. Default 400000 if unset. |
| `HANDOFF_HAIKU_FALLBACK=0` | Disable the Haiku fallback (no model call at compaction; facts only). |
| `HANDOFF_STATE_DIR` | Use another directory instead of `~/.local/state/claude-handoffs`. |
| `HANDOFF_HOOK_CHILD` | Set by the hook for its own Haiku call so it never recurses. Do not set it yourself. |

## Limitations

- The nudge only works if the model obeys it. If it does not, you get the Haiku fallback, which is lossier.
- The Haiku fallback runs `claude -p` and uses a little of your quota (one short Haiku call per compaction, 75 s timeout).
- The nudge reads context size from the transcript's last usage entry, so it lags by one assistant message.
- The order in which the three injected parts appear in context is not guaranteed; each part names its number.
- Windows is not supported.
- Not included: the Bento nightly canary (macOS launchd) and the desktop-app UI plugin.

## More

- Full Bento setup: https://github.com/pratikgh0se/machine-setup
- Behaviour contract for these hooks: `specs/handoff-hooks-spec.md` there (sections 1 to 6, F35, F36, F37).
- Decisions: [ADR 0007](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0007-handoff-degraded-vs-reduced.md) (degraded vs reduced), [ADR 0011](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0011-handoff-nudge-bounded-channel.md) (the nudge).
- The Bento `compact` plugin offers the same nudge plus a status chip and `/handoff` command for the desktop app's plugin UI. You do not need it; this repo's `handoff-nudge.py` replaces it for the CLI. Do not run both nudges.

MIT license. See `LICENSE`.
