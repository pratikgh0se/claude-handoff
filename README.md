# Lossless Handoff

*Formerly claude-handoff.*

[![CI](https://github.com/pratikgh0se/lossless-handoff/actions/workflows/ci.yml/badge.svg)](https://github.com/pratikgh0se/lossless-handoff/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![Release](https://img.shields.io/github/v/release/pratikgh0se/lossless-handoff)](https://github.com/pratikgh0se/lossless-handoff/releases/latest)

**Claude Code hooks for lossless context.** Before every auto-compaction a handoff is written and fed back in, each project keeps a decisions list that survives compactions, and `recall` finds the exact words of earlier chats (keyword + local semantic search). Python 3 only. Based on the LCM paper (arXiv:2605.04050).

![How a handoff flows through a compaction](docs/handoff-timeline.svg)
<!-- TODO: short GIF of recall finding an old instruction after compaction -->

## Install

```bash
git clone https://github.com/pratikgh0se/lossless-handoff.git && cd lossless-handoff && ./install.sh
```

Optional, for search by meaning: `ollama pull bge-m3`, then `python3 ~/.claude/hooks/recall.py index` once per project.

## Quick start

1. Work as usual. When Claude Code compacts, the handoff and decisions list are injected automatically.
2. After a compaction, ask "what exactly did I say about X?" and Claude runs recall and quotes you.
3. Try it yourself: `python3 ~/.claude/hooks/recall.py user --last 5`

## Built on the LCM paper

Lossless Handoff is based on, and inspired by, **"LCM: Lossless Context Management"** by Clint Ehrlich and Theodore Blackman ([arXiv:2605.04050](https://arxiv.org/abs/2605.04050)). The paper's idea: when a context window fills up, keep every message verbatim in a store and give the model tools to look things up again, so compaction summarises without destroying anything.

This is an independent project. It is not written by, affiliated with or endorsed by the paper's authors, and the paper's benchmark results are theirs: nothing here repeats them as ours. The only numbers in this README are our own, from the author's machine (see "What to expect").

| From the paper | What we took | What we did differently, and why |
|---|---|---|
| Immutable store of every message | Claude Code already keeps each message verbatim in `~/.claude/projects/<slug>/<session>.jsonl`; we use those files as the store and never write to them. | No new database for messages. Nothing to migrate, nothing to keep in sync. |
| Search and expand tools over the store | `recall.py search` finds words, `recall.py open` expands a hit with the messages around it. | A plain command line tool, not an MCP server: it costs about 0 tokens until used. One line in the injected context tells the model it exists. |
| Summaries of older context | A fresh summary at each compaction, plus the model's own handoff. | No summary tree. Hooks cannot change how Claude Code builds its context, so we add a handoff and a decisions list next to Claude Code's own summary instead of replacing it. |
| (not in the paper) | | A per-project decisions list that survives many compactions, and optional search by meaning with a local embedding model, merged with word search. |

```bibtex
@misc{ehrlich2026lcm,
  title         = {LCM: Lossless Context Management},
  author        = {Ehrlich, Clint and Blackman, Theodore},
  year          = {2026},
  eprint        = {2605.04050},
  archivePrefix = {arXiv},
  primaryClass  = {cs.AI},
  url           = {https://arxiv.org/abs/2605.04050}
}
```

## Proof it works

Measured on the author's machine on 2026-11-13/14, on the author's own projects. These are measurements, not promises.

| Test | Result |
|---|---|
| Lossless retrieval: 497 random messages from before a compaction | 497 of 497 found and returned byte-identical |
| Meaning search, easy paraphrase test, 118 queries | 98% in the top 10, 89% first |
| Alignment after compaction, blind quiz of 33 questions | 41/66 with the v0.4 injection, 50/66 with the full decisions list, 65/66 with the decisions list plus recall |

**Lossless retrieval.** 497 randomly sampled messages (297 of your messages and 200 of Claude's; fixed seed) from before a compaction, across 4 projects with up to 196 compactions each, were found by `recall.py search` and returned byte-identical by `recall.py open --full`. Mean search time 0.7 s, worst 3.1 s on a loaded machine. Limits: it is a sample, not every message. Messages containing secrets are redacted by design. Subagent transcripts are excluded. Messages over 40,000 characters need `--from` paging; that was added in 0.6.1 after the test found one 14,300-character message cut at the old 12,000-character output cap.

**Alignment after compaction.** 33 questions over 3 projects: 24 about old decisions and 9 about exact details found only in the chats. Sonnet answered from what a new chat receives, and a separate blind grader scored each answer 0 to 2. The one miss with recall was recall surfacing an older statement over a current rule, which led to the "decisions list wins" rule in 0.6.1. Limits: one run, questions written by a model, the author's own projects.

## The problem

Long Claude Code sessions lose context when they compact. The summary Claude Code writes is generic. It drops the exact next step, the dead ends you already ruled out, and your latest instructions. After a compaction the model often re-does work or asks what you wanted.

## What it does

1. **Nudge** (`handoff-nudge.py`, PostToolUse). When context reaches 75% of the auto-compact window, and again every 25,000 tokens, one short note is appended to a tool result asking the working model to write its own handoff to `~/.local/state/claude-handoffs/<session_id>-agent.md` with seven fixed headings: Goal, Parallel work running, Decisions and why, Done, In progress, Dead ends, Exact next step. With a 400k window the reminders come at 300k, 325k and 350k, plus one final note worded "Compaction is imminent" at 355k. The last reminder is kept about 12,000 tokens below the real compaction point (window minus 33,000), so the model still has room to write the file. Under "Parallel work running" the model lists every background agent or long job that is running or queued. If the three living sections (Parallel work running, In progress, Exact next step) are byte-identical to the previous reminder, the next note says the handoff is stale and asks for a rewrite. It costs no extra turn. The hook also records in `<session_id>-agent.meta.json` when the model wrote the file.
2. **Handoff** (`precompact-handoff.py`, PreCompact). Just before compaction it writes `<session_id>-latest.md` (capped at 14,000 chars). It starts with a short authority line that tells the model whom to believe when sources disagree (see below). Contents:
   - the model's own handoff, if there is one (labelled stale when it is out of date);
   - on every compaction, a fresh summary written by Sonnet (`claude -p --model sonnet`) of the conversation since the last compaction, placed after the model's own note and clearly labelled "verify against facts". It replaces the old Haiku fallback. It runs in parallel with the decisions-list update (below), so a compaction takes about 20-40 s in total;
   - always a facts section extracted from the transcript without any model: your last 8 messages, files touched, task state, git branch and status, last Bash commands, last assistant message (each tool call is one line ending `-> ok`, `-> error` or `-> no result`).
   It always exits 0 and never blocks compaction. If anything fails inside it, a minimal handoff is still written.
3. **Inject** (`postcompact-inject.py`, SessionStart with matcher `compact`). After compaction it feeds the handoff back into the new context. Claude Code caps each hook's injected text at 10,000 characters, so it runs three times (`--part 1/2/3`); long handoffs are split on section boundaries and the full file path is always named. Three more runs (`--ledger --part 1/2/3`) inject the decisions list, see below. If the model's own handoff is out of date, or its living sections did not change since the last reminder, it is still included but preceded by an `Agent handoff may be stale` warning with the reason.

## The project decisions list

A handoff is per session, but decisions belong to the project. Version 0.3.0 keeps one plain-text list of decisions per project (a git repo, or the folder you started in when there is no repo). It lives at `~/.local/state/claude-handoffs/projects/<project>-<hash>/decisions.md`, one line per decision: an id (`D12`), the date, a kind, what was decided, and why.

- **Kinds.** Every new entry is tagged `[rule]` (a standing rule or working preference, such as "never push without asking"), `[decision]` (a choice) or `[task]` (a follow-up you asked for). Older untagged lines count as decisions.
- **RESOLVE.** When a task is finished or a one-off has been acted on, the merge call answers `RESOLVE D<n>: <reason>`. The line is marked `RESOLVED` and keeps its old text; it is no longer injected. Rules are never resolved by the model.

- **What goes in.** Only things you decided or explicitly approved: a choice, a rule, a constraint, a permission, a rejected option. Not plans, not progress, not the assistant's own unapproved ideas.
- **How it is kept up to date.** At every compaction a second Sonnet call reads the conversation since the last update and the current list, and returns the updated list. It runs in parallel with the summary.
- **Carried across compactions.** After a compaction the list is injected again into the new context in three parts (`--ledger --part 1/2/3`), next to the handoff. Rules come first and always in full, then decisions, then tasks, newest first within each kind. When everything does not fit in 3 x 10,000 characters, the entries that do not fit in full are shown as one-line index entries, so nothing is silently dropped; the index says to read the full line in `decisions.md` before acting on one.
- **Shown in new and resumed chats.** When you start a new chat or resume one in the same repo, the same three parts are injected at `startup` and `resume`, so a fresh session does not re-ask what you already settled.
- **Tidying an old list.** `python3 ~/.claude/hooks/precompact-handoff.py --ledger-maintain <repo>` runs one maintenance pass over the whole list of that repo: it tags untagged entries, resolves finished tasks and supersedes contradictions. It adds no entries and edits no text, and prints one summary line. A path that is not an existing directory is an error (exit 2, nothing created); a repo with no list prints `no ledger for <repo>`.
- **Never deleted.** When you change your mind, the old decision is only marked `SUPERSEDED by D<n>` with the reason; it stays in the file. Before each update the previous list is saved as `decisions.<timestamp>.md` (the newest 20 are kept).
- **Code checks the model.** Sonnet proposes, plain code decides: an entry the model drops is put back, a superseded entry is never revived, existing ids never change, over-long lines are shortened rather than dropped, and a result with no valid line is thrown away. A project lock keeps two compactions in the same repo from overwriting each other.

**Who wins when sources disagree** (the authority line at the top of every handoff): the user's latest words, then the project decisions, then the agent handoff, then the fresh summary, then Claude Code's own summary, then the extracted facts. If two disagree, the newer statement from the user wins; if unsure, ask.

Turn it off with `HANDOFF_LEDGER=0` (no merge call, no file written, nothing injected at session start). Choose its model with `HANDOFF_LEDGER_MODEL` (default: the summary model, `sonnet`). Existing lists are never deleted by turning it off or by uninstalling.

**Cost.** Two Sonnet calls per compaction (summary plus decisions), about $0.10-0.20 of API-equivalent usage and 20-40 s, because they run in parallel.

**Does it help?** On 96 questions about decisions made one or more compactions earlier (four real projects), scores out of 100 went from 13.5 with the 0.2.0 handoff to 56 with the decisions list (by age: 1 compaction 21 -> 66, 2 compactions 10 -> 56, 3+ 8 -> 44); recent memory was unchanged (62.5). AI-written and AI-graded, one user's sessions.

What works without the model's cooperation: if the model never writes the agent file, you still get the fresh Sonnet summary plus the facts section (spec F38; status `reduced`). If the summary is disabled or fails too, you get the facts section only, and the injected text starts with a `HANDOFF DEGRADED` warning line (spec F36.D). The fresh summary needs the `claude` binary on `PATH`.

Why a 400k window: the default window is 1M tokens, so sessions rarely compact and pay for their whole context on every turn. A shorter window lowers per-turn cost and avoids the quality loss of very long contexts. The price is more compactions, which the handoff makes safe. See [ADR 0001](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0001-compact-window-400k-with-handoff.md). Use `--window N` to pick another value or `--no-window` to leave the setting alone.

## Recall: find the exact words of earlier chats

A summary keeps decisions but loses exact commands, numbers, paths and your own wording. `recall.py` searches every earlier chat in the same project (all sessions whose folder is inside the project's git root), read-only, over the transcripts Claude Code already keeps. The handoff and the new-chat context carry one line telling the model it can use it.

```
python3 ~/.claude/hooks/recall.py search "zebra-mode"          # words, regex or meaning (hybrid)
python3 ~/.claude/hooks/recall.py search "why we dropped the cache" --meaning
python3 ~/.claude/hooks/recall.py search "deploy.sh" --keyword --fixed --role user
python3 ~/.claude/hooks/recall.py open abcd1234:57             # a hit plus 2 messages each side (--around K, --full)
python3 ~/.claude/hooks/recall.py open abcd1234:57 --full      # the whole message, up to 40,000 chars
python3 ~/.claude/hooks/recall.py open abcd1234:57 --full --from 40000   # next page of a longer message
python3 ~/.claude/hooks/recall.py user --last 20               # your own typed messages, newest first
python3 ~/.claude/hooks/recall.py handoffs                     # this project's handoff files
python3 ~/.claude/hooks/recall.py index                        # build or refresh the meaning index
```

Every command accepts `--cwd DIR` (default: the current folder). `search` also takes `--session SID8|all`, `--limit N` and `--subagents`. Output is capped at 12,000 characters, and obvious secrets (API keys, tokens, `password=...`) are replaced by `[redacted]` before printing or embedding.

- **Long messages.** `open <id> --full` returns up to 40,000 characters of a message. A longer one ends with a line giving the exact `--from <N>` to continue with, so any message can be read whole in pages.
- **Recall does not outrank the decisions list.** If recall and the decisions list disagree, or recall disagrees with your latest words, the decisions list and your latest words win. Recall can surface an older statement.
- **Default is hybrid.** Word hits and meaning hits are merged; each line is tagged `[word]`, `[meaning]` or `[both]`, and the first line says which mode ran. `--keyword` is words only, `--meaning` is the embedding index only.
- **Words work without any setup.** It uses `rg` if installed, else plain Python.
- **Meaning search is optional.** It needs a local embedding model: [Ollama](https://ollama.com) with `ollama pull bge-m3`. Build the first index once with `python3 ~/.claude/hooks/recall.py index` from your project folder. After that, each compaction refreshes it in a detached background process that never delays compaction. If the model is not reachable, search says `keyword only` and carries on.
- **Environment variables.** `RECALL_EMBED_URL` (default `http://localhost:11434`), `RECALL_EMBED_MODEL` (default `bge-m3`), `RECALL_EMBED_BACKEND` (`ollama`, or `openai` for any `/v1/embeddings` server), `RECALL_EMBED_KEY` (optional Bearer token for the `openai` backend).

## What to expect

Measured on the author's machine over the first 4.7 days with the 400k window (2026-10-15 to 10-20; Opus and Sonnet with a 1M context window, heavy multi-hour sessions):

- **About 20% lower cost.** Average context per turn fell from about 474k (estimated, without the cap) to 223k. That is about 25% fewer tokens processed and about 19% lower API-equivalent cost (roughly $230/week here), after subtracting the cost of the extra compactions. On a subscription this shows up as usage-limit headroom rather than cash.
- **Continuity across many compactions.** 13 of 13 real compactions had a fresh model-written handoff, with no degraded cases. One working session went through 9 compactions in two days and kept going on the same task, each time resuming from its own "Exact next step".

Your numbers will differ. Savings come from long sessions on 1M-context models; if your sessions rarely pass 300k tokens, the window never triggers and you mainly get the handoff. The figures come from a small sample (one user, four sessions, one of which accounts for most of the saving) and a counterfactual model, and they are API-equivalent estimates rather than a bill. Whether shorter context also improves answer quality was not measured.

**Handoff quality.** In a blind test on 18 real compactions, a fresh Claude was quizzed on what it needed to carry on (latest request, next step, decisions, dead ends, rules, files). Scores out of 100: Claude Code's summary alone 62; plus the model's own handoff 68; plus a fresh Sonnet summary written at compaction 75-76; a Claude given the actual recent conversation scored 85. Version 0.2.0 adds that fresh summary. The test was AI-written and AI-graded on one user's sessions, so treat it as a strong hint rather than proof.

## Prerequisites

- A Claude Code version that supports the `PreCompact` and `SessionStart` hook events, `PostToolUse` hooks, and `additionalContext` in hook output. Recent releases do; if a hook never fires, update Claude Code first.
- `python3` (standard library only, no packages to install).
- `bash`, on macOS or Linux. Windows is not supported.
- Optional: the `claude` binary on `PATH`, used only for the fresh summary at compaction.

## Install

```
git clone https://github.com/pratikgh0se/lossless-handoff.git
cd lossless-handoff
./install.sh --dry-run   # show the plan, change nothing
./install.sh
```

One-liner:

```
git clone https://github.com/pratikgh0se/lossless-handoff.git && cd lossless-handoff && ./install.sh
```

Options: `--window N`, `--no-window`, `--dry-run`, `--force`, `--version`, `--help`. If the same hook scripts are already registered in `settings.json` from another path (for example `~/.claude/hooks/` from another setup), install prints those commands and exits 2, because every hook would run twice (duplicate health lines, double injection, two fresh-summary calls). Remove those entries, or pass `--force` to install anyway. Install is idempotent and fails with a clear message if `python3` is missing or `settings.json` is not valid JSON.

It changes:

- copies `precompact-handoff.py`, `postcompact-inject.py`, `handoff-nudge.py` and `recall.py` to `~/.claude/hooks/` (an existing file with a different content is first saved to `~/.claude/hooks/.claude-handoff-backup-<timestamp>/`);
- merges into `~/.claude/settings.json` (backup `settings.json.bak-<timestamp>`): a PreCompact hook (timeout 150), a PostToolUse hook (matcher `*`, timeout 5), a SessionStart `compact` group with the three inject commands and the three `--ledger --part 1/2/3` commands (timeout 10), SessionStart `startup` and `resume` groups with the three `--ledger --part 1/2/3` commands (timeout 10; an older single `--ledger` entry is replaced), `permissions.allow` entry `Edit(~/.local/state/claude-handoffs/**)` so the model can write its handoff without a prompt, `permissions.allow` entry `Bash(python3 ~/.claude/hooks/recall.py:*)` so the model can run recall without a prompt, and `env.CLAUDE_CODE_AUTO_COMPACT_WINDOW` = `"400000"` unless already set;
- creates `~/.local/state/claude-handoffs/`.

Your other hooks and settings are left alone: new entries are appended next to existing ones. Restart Claude Code afterwards.

## Uninstall

```
./uninstall.sh
```

Removes exactly those hook entries (matched by command path, including the `startup` and `resume` ones; other hooks in those groups stay), the allow rules and the window value if install added them, and the hook files including `recall.py`, after backing up settings. Handoff files stay in `~/.local/state/claude-handoffs/`, and so do the project decision lists under `~/.local/state/claude-handoffs/projects/`; delete that folder yourself if you want them gone. Backups are kept.

## What gets written where

| Path | Content |
|---|---|
| `~/.local/state/claude-handoffs/<sid>-latest.md` | The handoff that is injected after compaction. `<sid>-<timestamp>.md` is a copy. |
| `<sid>-agent.md` | The model's own handoff (written by the model). |
| `<sid>-agent.meta.json` | Nudge state and timestamps (numbers only, no text). |
| `recall-index.json`, `recall/` | Recall caches: which transcripts belong to which project, and the optional meaning index (`<project>.sqlite`, `index.log`). Safe to delete. |
| `health.jsonl` | One JSON line per compaction: time, trigger, agent file fresh/stale/absent, fallback result, ledger result (`ok`, `unchanged`, `failed`, `locked`, `disabled`) and counts, duration, size, status `ok` / `reduced` / `degraded`. No message text or paths. Rotates at 5,000 lines. |
| `<sid>-last-health.json`, `<sid>-degraded.json` | Per-session status and degraded reasons. |
| `projects/<project>-<hash>/decisions.md` | The project's decisions list (kept by uninstall). Beside it: `decisions.<timestamp>.md` (newest 20 previous versions), `decisions.state.json` (what was merged so far), `decisions.lock`. |

Files older than 14 days are cleaned up automatically. The directory is outside `~/.claude/` because Claude Code refuses model writes under that path ([ADR 0008](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0008-handoffs-directory-under-local-state.md)).

## Verify

After install, check that the hook runs on a manual compaction:

```
claude -p --model haiku "say hi" --output-format json   # note the session_id
claude -p --model haiku --resume <session_id> "/compact"
tail -n 3 ~/.local/state/claude-handoffs/health.jsonl
```

A new line with `"trigger": "manual"` means the PreCompact hook fired. In a normal interactive session, run `/compact` and look at the same file. `status` is `ok` (model handoff used), `reduced` (fresh summary used instead of the model's handoff) or `degraded` (see the table above and spec F36). You can also run `tests/smoke.sh`; it uses a temporary HOME and does not touch your real settings.

## Configuration

Environment variables the hooks honour:

| Variable | Effect |
|---|---|
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Window size in tokens. The nudge thresholds are 75% of it, then every 25,000, then a final note (window minus 45,000). Default 400000 if unset. |
| `HANDOFF_SUMMARY=0` | Disable the fresh summary at compaction (no model call; facts only). |
| `HANDOFF_SUMMARY_MODEL` | Model for the fresh summary. Default `sonnet`. |
| `HANDOFF_SUMMARY_TIMEOUT` | Seconds to wait for the summary (1-300). Default 75. |
| `HANDOFF_LEDGER=0` | Disable the project decisions list: no merge call, nothing written, nothing injected (compaction or session start). |
| `HANDOFF_LEDGER_MODEL` | Model for the decisions update. Default: the summary model (`sonnet`). |
| `HANDOFF_LEDGER_TIMEOUT` | Seconds to wait for the decisions update (1-300). Default 100, independent of the summary timeout. The PreCompact hook timeout is 150. |
| `HANDOFF_HAIKU_FALLBACK=0` | Legacy switch from 0.1.x; still honoured and also disables the fresh summary. |
| `RECALL_EMBED_URL`, `RECALL_EMBED_MODEL`, `RECALL_EMBED_BACKEND`, `RECALL_EMBED_KEY` | Meaning search backend for `recall.py` (see Recall). Defaults: Ollama at `http://localhost:11434`, model `bge-m3`. |
| `HANDOFF_STATE_DIR` | Use another directory instead of `~/.local/state/claude-handoffs`. |
| `HANDOFF_HOOK_CHILD` | Set by the hook for its own summary call so it never recurses. Do not set it yourself. |

## FAQ

**Does it cost tokens?** About one short note per nudge (at 75% of the window, then every 25,000 tokens, then a final one), plus up to about 14,000 characters injected once per compaction and up to about 20,000 characters of decisions. Each compaction adds two `claude -p` Sonnet calls, the fresh summary and the decisions update (about 20-40 s in parallel, roughly $0.10-0.20 of API-equivalent usage). Set `HANDOFF_SUMMARY=0` and `HANDOFF_LEDGER=0` to avoid them.

**Does it work in the desktop app?** Yes. The desktop app runs the same hooks from `~/.claude/settings.json`.

**Does it work with my existing hooks?** Yes. Install merges its entries into your existing `hooks` groups and never removes or reorders yours; uninstall removes only its own commands.

**Where must `CLAUDE_CODE_AUTO_COMPACT_WINDOW` be set?** In your user `~/.claude/settings.json` under `env` (install does this) or exported in the shell that starts Claude Code. A live test showed that `env` in a project's `.claude/settings.json` did not override it.

**What window size should I use?** One that comfortably exceeds your baseline context. Very small windows (below roughly 150k) compact before the 75% nudge is reached; the PreCompact hook then covers it.

**Can the nudge be skipped?** Yes. It reads the previous turn's token count, so one very large tool result can jump past the threshold without a nudge. The PreCompact hook still writes a handoff.

**Does it send anything over the network?** The scripts do not, except meaning search, which sends message text to the embedding server you configure (by default Ollama on your own machine). The two per-compaction calls run your local `claude -p`. See `SECURITY.md`.

## Troubleshooting

- Logs and health live in `~/.local/state/claude-handoffs/` (or `$HANDOFF_STATE_DIR`). Start with `tail -n 5 ~/.local/state/claude-handoffs/health.jsonl`: one line per compaction with `status` `ok`, `reduced` or `degraded`.
- `<sid>-degraded.json` and `<sid>-last-health.json` in the same folder say why a compaction was degraded.
- No health line after `/compact`: restart Claude Code (hooks load at startup), then check `~/.claude/settings.json` has the `PreCompact` entry and that `python3 ~/.claude/hooks/precompact-handoff.py` exists.
- No nudge appears: it only fires above 75% of the window (300k for a 400k window) and needs the transcript to contain a usage entry; check `CLAUDE_CODE_AUTO_COMPACT_WINDOW` in `settings.json`.
- Settings or hooks got into a bad state: install and uninstall leave timestamped backups (`settings.json.bak-*`, `~/.claude/hooks/.claude-handoff-backup-*`).
- Something else: run `bash tests/smoke.sh`, then open an issue using the bug report template.

## Limitations

- The nudge only works if the model obeys it. If it does not, you still get the fresh summary, which is lossier than the model's own note.
- The fresh summary and the decisions update each run `claude -p --model sonnet` and use some of your quota (one call each per compaction; 75 s summary timeout and 100 s decisions timeout by default).
- The decisions list needs `fcntl` (macOS and Linux) and only records what you said in chat; a decision you never wrote or approved is not captured.
- The nudge reads context size from the transcript's last usage entry, so it lags by one assistant message.
- The order in which the three injected parts appear in context is not guaranteed; each part names its number.
- Windows is not supported.
- Not included: the Bento nightly canary (macOS launchd) and the desktop-app UI plugin.

## More

- Full Bento setup: https://github.com/pratikgh0se/machine-setup
- Behaviour contract for these hooks: `specs/handoff-hooks-spec.md` there (sections 1 to 6, F35 to F39).
- Decisions: [ADR 0007](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0007-handoff-degraded-vs-reduced.md) (degraded vs reduced), [ADR 0011](https://github.com/pratikgh0se/machine-setup/blob/main/docs/adr/0011-handoff-nudge-bounded-channel.md) (the nudge).
- The Bento `compact` plugin offers the same nudge plus a status chip and `/handoff` command for the desktop app's plugin UI. You do not need it; this repo's `handoff-nudge.py` replaces it for the CLI. Do not run both nudges.

MIT license. See `LICENSE`. Security notes: `SECURITY.md`. Changes: `CHANGELOG.md`.
