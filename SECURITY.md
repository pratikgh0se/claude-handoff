# Security

## What the scripts touch

`install.sh` and `uninstall.sh` read and write only these paths:

- `~/.claude/hooks/`: the three hook files, a backup folder `.claude-handoff-backup-<timestamp>/` for any file they replace, and `.claude-handoff-install.json` (records what install added so uninstall removes exactly that).
- `~/.claude/settings.json`: merged JSON (hooks, one `permissions.allow` entry, and `env.CLAUDE_CODE_AUTO_COMPACT_WINDOW`), with a `settings.json.bak-<timestamp>` backup before each write. Invalid JSON is never overwritten.
- `~/.local/state/claude-handoffs/`: created by install, written by the hooks, kept by uninstall.

The hooks read the session transcript Claude Code passes them and write handoff files and a health log into the state directory. The only permission added is `Edit(~/.local/state/claude-handoffs/**)`, so the model can write its handoff file there.

## Network

None of the scripts or hooks open network connections. The one exception to "no model call" is the optional Haiku fallback, which runs your local `claude -p --model haiku` at compaction; that is Claude Code talking to Anthropic as usual, not this project. Disable it with `HANDOFF_HAIKU_FALLBACK=0`.

Handoff files contain excerpts of your conversation (your recent messages, file names, git status, recent commands). Keep `~/.local/state/claude-handoffs/` private and do not commit or share it. Files older than 14 days are removed automatically.

## Reporting a vulnerability

Open a GitHub issue on this repository. If the report includes sensitive details, describe the impact in the issue without the details and ask for a private channel.
