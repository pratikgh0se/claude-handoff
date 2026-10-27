# Security

## What the scripts touch

`install.sh` and `uninstall.sh` read and write only these paths:

- `~/.claude/hooks/`: the three hook files, a backup folder `.claude-handoff-backup-<timestamp>/` for any file they replace, and `.claude-handoff-install.json` (records what install added so uninstall removes exactly that).
- `~/.claude/settings.json`: merged JSON (hooks, one `permissions.allow` entry, and `env.CLAUDE_CODE_AUTO_COMPACT_WINDOW`), with a `settings.json.bak-<timestamp>` backup before each write. Invalid JSON is never overwritten.
- `~/.local/state/claude-handoffs/`: created by install, written by the hooks, kept by uninstall. Project decision lists live in `projects/<project>-<hash>/` inside it (`decisions.md`, timestamped backups, `decisions.state.json`, `decisions.lock`); uninstall keeps them too.

The hooks read the session transcript Claude Code passes them and write handoff files and a health log into the state directory. The only permission added is `Edit(~/.local/state/claude-handoffs/**)`, so the model can write its handoff file there.

## Network

None of the scripts or hooks open network connections. The one exception to "no model call" is the fresh summary, which runs your local `claude -p --model sonnet` once per compaction; that is Claude Code talking to Anthropic as usual, not this project. The call uses isolated flags (no settings, no MCP servers, no slash commands, no tools) and runs in a temporary directory with the conversation excerpt on stdin. Disable it with `HANDOFF_SUMMARY=0` (the legacy `HANDOFF_HAIKU_FALLBACK=0` also works).

Since 0.3.0 there is a second call per compaction, the decisions merge, with the same isolated flags (`claude -p --model sonnet` by default, or `HANDOFF_LEDGER_MODEL`). It sends the current decisions list and your messages, your answers to questions, and the assistant's reply before each message, since the last update (at most about 40,000 characters, oldest first; a larger backlog is caught up over several compactions). The reply is validated in code before anything is written. Disable it, and the session-start injection of the list, with `HANDOFF_LEDGER=0`.

Handoff files contain excerpts of your conversation (your recent messages, file names, git status, recent commands). The decision lists contain your project decisions in plain text, including anything you decided in chat, so do not put secrets in chat expecting them to be dropped. Keep `~/.local/state/claude-handoffs/` private and do not commit or share it. Files older than 14 days are removed automatically.

## Reporting a vulnerability

Open a GitHub issue on this repository. If the report includes sensitive details, describe the impact in the issue without the details and ask for a private channel.
