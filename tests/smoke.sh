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

# F38: fresh summary via a fake `claude` shim on PATH
SH="$T/shim"; mkdir -p "$SH"
cat > "$SH/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SHIM_LOG"
cat > /dev/null
[ -n "${SHIM_SLEEP:-}" ] && sleep "$SHIM_SLEEP"
printf 'SHIM-SUMMARY %.0s' 1 2 3 4 5 6
exit 0
SHIM
chmod +x "$SH/claude"
run_pre() { # $1 = session id; rest = env assignments
  local sid="$1"; shift
  printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s","trigger":"manual"}' "$sid" "$T" "$TR" \
    | env -u HANDOFF_HAIKU_FALLBACK PATH="$SH:$PATH" SHIM_LOG="$T/shim.log" "$@" python3 "$H/precompact-handoff.py" >/dev/null 2>&1
}
python3 -c "print('## Goal\nrefactor\n' + 'x' * 400)" > "$ST/sumsess-agent.md"
rm -f "$T/shim.log"
run_pre sumsess
F="$ST/sumsess-latest.md"
grep -q "^## Fresh summary at compaction (sonnet; verify against facts)" "$F" || fail "summary heading missing"
grep -q "SHIM-SUMMARY" "$F" || fail "summary text missing"
a="$(grep -n '^## Agent handoff' "$F" | head -1 | cut -d: -f1)"; b="$(grep -n '^## Fresh summary' "$F" | head -1 | cut -d: -f1)"
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "summary not after agent section"
grep -qx -- "--model" "$T/shim.log" && grep -qx "sonnet" "$T/shim.log" || fail "shim not called with --model sonnet"
tail -n 1 "$ST/health.jsonl" | grep -q '"summary_model": *"sonnet"' || fail "health lacks summary_model sonnet"
! grep -q "Haiku fallback" "$F" || fail "old Haiku wording emitted"
ok "F38 summary present after agent section (sonnet)"

rm -f "$T/shim.log"
run_pre sumsess HANDOFF_SUMMARY=0
[ ! -e "$T/shim.log" ] || fail "HANDOFF_SUMMARY=0 still ran claude"
! grep -q "Fresh summary" "$F" || fail "HANDOFF_SUMMARY=0 left a summary section"
tail -n 1 "$ST/health.jsonl" | grep -q '"fallback": *"disabled"' || fail "health fallback not disabled"
ok "HANDOFF_SUMMARY=0 disables it"

run_pre sumsess HANDOFF_SUMMARY_MODEL=haiku
grep -q "^## Fresh summary at compaction (haiku; verify against facts)" "$F" || fail "haiku heading missing"
grep -qx "haiku" "$T/shim.log" || fail "shim not called with haiku"
ok "HANDOFF_SUMMARY_MODEL=haiku is used"

s0=$SECONDS
run_pre sumsess HANDOFF_SUMMARY_TIMEOUT=2 SHIM_SLEEP=10
[ $((SECONDS - s0)) -le 7 ] || fail "timeout took too long"
grep -q "^Fresh summary failed: timeout after 2s" "$F" || fail "timeout line missing"
ok "HANDOFF_SUMMARY_TIMEOUT=2 gives 'timeout after 2s' quickly"
rm -f "$ST"/sumsess-*

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
echo "$o1" | grep -q "claude-handoff PostToolUse hook that the user installed" || fail "nudge does not identify its source"
python3 -c "import json,sys; t=json.load(sys.stdin)['hookSpecificOutput']['additionalContext']; assert len(t)<900, len(t)" <<<"$o1" || fail "nudge too long"
echo "$o1" | python3 -c "import json,sys; assert json.load(sys.stdin)['hookSpecificOutput']['hookEventName']=='PostToolUse'"
ok "nudge fires at 310k, not at 320k, again at 355k"

# Agent write is recorded in meta
printf '{"session_id":"nsess","transcript_path":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$TR" "$ST/nsess-agent.md" | python3 "$H/handoff-nudge.py" >/dev/null
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); assert m['agentWrittenAt'] and m['nudgeCount']==2" "$ST/nsess-agent.meta.json"
ok "agent write recorded in meta"

# Conflict: same hooks registered from another path -> exit 2, settings untouched; --force installs
H2="$T/home2"; mkdir -p "$H2/.claude"
cat > "$H2/.claude/settings.json" <<'JSON'
{"hooks": {"PreCompact": [{"hooks": [{"type": "command", "command": "python3 /other/place/precompact-handoff.py"}]}]}}
JSON
cp "$H2/.claude/settings.json" "$T/conflict-orig.json"
rc=0; HOME="$H2" "$ROOT/install.sh" >"$T/c.out" 2>"$T/c.err" || rc=$?
[ "$rc" -eq 2 ] || fail "conflict: expected exit 2, got $rc"
grep -q "/other/place/precompact-handoff.py" "$T/c.err" || fail "conflict: command not printed"
grep -q -- "--force" "$T/c.err" || fail "conflict: message lacks --force"
cmp -s "$H2/.claude/settings.json" "$T/conflict-orig.json" || fail "conflict: settings changed"
[ ! -e "$H2/.claude/hooks/handoff-nudge.py" ] || fail "conflict: hook files copied"
ok "conflicting registration: exit 2, nothing changed"
HOME="$H2" "$ROOT/install.sh" --force >/dev/null || fail "--force install failed"
[ -f "$H2/.claude/hooks/handoff-nudge.py" ] || fail "--force did not install"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d['hooks']['PreCompact'])==2" "$H2/.claude/settings.json" || fail "--force settings wrong"
ok "--force installs alongside the other registration"
rc=0; HOME="$T/home" "$ROOT/install.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "own re-install reported a conflict (exit $rc)"
ok "re-install of own paths is not a conflict"

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
