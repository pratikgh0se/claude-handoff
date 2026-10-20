#!/usr/bin/env bash
# Smoke test: install, run the three hooks on synthetic data, uninstall. Uses a temporary HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude"
export HANDOFF_HAIKU_FALLBACK=0
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW HANDOFF_STATE_DIR HANDOFF_HOOK_CHILD || true
H="$HOME/.claude/hooks"; ST="$HOME/.local/state/claude-handoffs"; S="$HOME/.claude/settings.json"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

cat > "$S" <<'JSON'
{
  "model": "opus",
  "note": "café ☃",
  "env": {"FOO": "1"},
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hi"}]}]}
}
JSON
cp "$S" "$T/original.json"

"$ROOT/install.sh" --dry-run >/dev/null
cmp -s "$S" "$T/original.json" || fail "dry-run changed settings"
ok "dry-run changes nothing"

"$ROOT/install.sh" >"$T/install1.out"
cp "$S" "$T/after1.json"
"$ROOT/install.sh" >"$T/install2.out"
cmp -s "$S" "$T/after1.json" || fail "second install changed settings"
ls "$S".bak-* >/dev/null 2>&1 || fail "no settings backup"
ok "install is idempotent"

python3 - "$S" "$H" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); h = sys.argv[2]
assert d["env"]["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "400000" and d["env"]["FOO"] == "1"
assert d["note"] == "café ☃"
assert d["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "echo hi"
assert [x["command"] for x in d["hooks"]["PreCompact"][0]["hooks"]] == ["python3 %s/precompact-handoff.py" % h]
ss = d["hooks"]["SessionStart"]; assert len(ss) == 1 and ss[0]["matcher"] == "compact" and len(ss[0]["hooks"]) == 3
assert d["hooks"]["PostToolUse"][0]["hooks"][0]["timeout"] == 5
assert "Edit(~/.local/state/claude-handoffs/**)" in d["permissions"]["allow"]
PY
ok "settings content"

# PreCompact hook on a tiny transcript
TR="$T/t.jsonl"
python3 - "$TR" <<'PY'
import json, sys
rows = [
 {"type": "user", "message": {"content": "Please refactor the parser"}},
 {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on it."},
   {"type": "tool_use", "name": "Edit", "input": {"file_path": "/tmp/x.py"}}],
   "usage": {"input_tokens": 1000, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}},
]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
printf '{"session_id":"smoke1","cwd":"%s","transcript_path":"%s","trigger":"manual"}' "$T" "$TR" \
  | python3 "$H/precompact-handoff.py" >"$T/pre.out" 2>"$T/pre.err"
[ ! -s "$T/pre.out" ] && [ ! -s "$T/pre.err" ] || fail "precompact printed output"
[ -s "$ST/smoke1-latest.md" ] || fail "no latest handoff"
grep -q "Please refactor the parser" "$ST/smoke1-latest.md" || fail "user message missing from handoff"
[ "$(wc -l < "$ST/health.jsonl")" -eq 1 ] || fail "expected one health line"
python3 -c "import json,sys; json.loads(open(sys.argv[1]).readline())" "$ST/health.jsonl" || fail "bad health line"
ok "PreCompact wrote handoff and health line"

# Inject
printf '{"session_id":"smoke1"}' | python3 "$H/postcompact-inject.py" --part 1 >"$T/inj.out"
python3 - "$T/inj.out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["hookSpecificOutput"]
assert d["hookEventName"] == "SessionStart" and "Please refactor the parser" in d["additionalContext"]
PY
ok "inject --part 1 JSON"

# Nudge: 310k nudges once, 320k not, 355k once more
mk() { python3 - "$TR" "$1" <<'PY'
import json, sys
row = {"type": "assistant", "message": {"content": [{"type": "text", "text": "x"}],
       "usage": {"input_tokens": 10, "cache_read_input_tokens": int(sys.argv[2]) - 10, "cache_creation_input_tokens": 0}}}
open(sys.argv[1], "a").write(json.dumps(row) + "\n")
PY
}
nudge() { printf '{"session_id":"nsess","transcript_path":"%s","tool_name":"Bash","tool_input":{}}' "$TR" | python3 "$H/handoff-nudge.py"; }
mk 310000; o1="$(nudge)"
mk 320000; o2="$(nudge)"
mk 355000; o3="$(nudge)"
[ -n "$o1" ] && [ -z "$o2" ] && [ -n "$o3" ] || fail "nudge pattern wrong (got: ${#o1} ${#o2} ${#o3} chars)"
echo "$o1" | grep -q "nsess-agent.md" || fail "nudge lacks agent path"
echo "$o1" | python3 -c "import json,sys; assert json.load(sys.stdin)['hookSpecificOutput']['hookEventName']=='PostToolUse'"
ok "nudge fires at 310k, not at 320k, again at 355k"

# Agent write is recorded in meta
printf '{"session_id":"nsess","transcript_path":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$TR" "$ST/nsess-agent.md" | python3 "$H/handoff-nudge.py" >/dev/null
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); assert m['agentWrittenAt'] and m['nudgeCount']==2" "$ST/nsess-agent.meta.json"
ok "agent write recorded in meta"

"$ROOT/uninstall.sh" >"$T/un.out"
python3 - "$S" "$T/original.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8")); b = json.load(open(sys.argv[2], encoding="utf-8"))
assert a == b, (a, b)
PY
for f in precompact-handoff.py postcompact-inject.py handoff-nudge.py; do [ ! -e "$H/$f" ] || fail "$f left behind"; done
[ -d "$ST" ] || fail "state dir should be kept"
"$ROOT/uninstall.sh" >/dev/null
ok "uninstall restores settings; second uninstall is a no-op"
echo "ALL PASSED"
