#!/usr/bin/env bash
# claude-handoff installer: copies three hooks and merges them into ~/.claude/settings.json.
set -euo pipefail

VERSION="0.1.0"
usage() {
  cat <<EOF
claude-handoff $VERSION
Copies three hooks into ~/.claude/hooks and merges them into ~/.claude/settings.json.

Usage: ./install.sh [--dry-run] [--force] [--window N] [--no-window] [--version] [-h|--help]

  --dry-run     show what would change, change nothing
  --window N    set CLAUDE_CODE_AUTO_COMPACT_WINDOW to N tokens (default 400000;
                left alone if already set)
  --no-window   do not touch CLAUDE_CODE_AUTO_COMPACT_WINDOW
  --force       install even if the same hooks are already registered from another
                path (they would then run twice); default is to stop with exit 2
  --version     print the version and exit
  -h, --help    show this help

Requires bash and python3 (macOS or Linux).
EOF
}

DRY=0; FORCE=0; WINDOW=400000; SETWINDOW=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --window) shift; WINDOW="${1:-}"; case "$WINDOW" in ''|*[!0-9]*) echo "--window needs a number" >&2; exit 2 ;; esac ;;
    --no-window) SETWINDOW=0 ;;
    --force) FORCE=1 ;;
    --version) echo "claude-handoff $VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.local/state/claude-handoffs"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$HOOKS_DIR/.claude-handoff-backup-$TS"
FILES="precompact-handoff.py postcompact-inject.py handoff-nudge.py"

say() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else echo "$*"; fi; }

# 3. settings merge
HC_DRY="$DRY" HC_FORCE="$FORCE" HC_WINDOW="$WINDOW" HC_SETWINDOW="$SETWINDOW" HC_SETTINGS="$SETTINGS" \
HC_HOOKS="$HOOKS_DIR" HC_TS="$TS" python3 - <<'PY'
import json, os, shutil, sys
dry = os.environ["HC_DRY"] == "1"
path = os.environ["HC_SETTINGS"]
hooks_dir = os.environ["HC_HOOKS"]
ts = os.environ["HC_TS"]
pre = "python3 %s/precompact-handoff.py" % hooks_dir
nudge = "python3 %s/handoff-nudge.py" % hooks_dir
post = ["python3 %s/postcompact-inject.py --part %d" % (hooks_dir, n) for n in (1, 2, 3)]
allow_rule = "Edit(~/.local/state/claude-handoffs/**)"
marker_path = os.path.join(hooks_dir, ".claude-handoff-install.json")
tag = "[dry-run] " if dry else ""

existed = os.path.exists(path)
if existed:
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError as e:
        sys.exit("settings.json is not valid JSON, not touching it: %s" % e)
    if not isinstance(data, dict):
        sys.exit("settings.json is not a JSON object, not touching it")
else:
    data = {}
before = json.dumps(data, sort_keys=True)
changes = []

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit("settings.json: hooks is not an object")

# conflict check: the same hook scripts registered from a different path would run twice
own_cmds = set([pre, nudge] + post)
names = ("precompact-handoff.py", "postcompact-inject.py", "handoff-nudge.py")
conflicts = []
for ev, groups_ in hooks.items():
    if not isinstance(groups_, list):
        continue
    for g in groups_:
        if not isinstance(g, dict) or not isinstance(g.get("hooks"), list):
            continue
        for h in g["hooks"]:
            c = h.get("command") if isinstance(h, dict) else None
            if isinstance(c, str) and any(n in c for n in names) and c not in own_cmds:
                conflicts.append((ev, c))
if conflicts and os.environ["HC_FORCE"] != "1":
    sys.stderr.write("claude-handoff hooks are already registered from another path; installing would run every hook twice:\n")
    for ev, c in conflicts:
        sys.stderr.write("  %s: %s\n" % (ev, c))
    sys.stderr.write("Already installed from another path (not %s): remove those entries from %s, or rerun with --force.\n" % (hooks_dir, path))
    sys.exit(2)
if conflicts:
    print("%sWARNING: --force given; %d conflicting hook entr%s left in place, hooks will run twice" % (tag, len(conflicts), "y" if len(conflicts) == 1 else "ies"))

def has_cmd(groups, cmd):
    return any(isinstance(g, dict) and any(isinstance(h, dict) and h.get("command") == cmd
               for h in g.get("hooks", [])) for g in groups)

groups = hooks.setdefault("PreCompact", [])
if has_cmd(groups, pre):
    changes.append("PreCompact hook already present")
else:
    groups.append({"hooks": [{"type": "command", "command": pre, "timeout": 90}]})
    changes.append("add PreCompact hook (timeout 90)")

groups = hooks.setdefault("PostToolUse", [])
if has_cmd(groups, nudge):
    changes.append("PostToolUse nudge hook already present")
else:
    groups.append({"matcher": "*", "hooks": [{"type": "command", "command": nudge, "timeout": 5}]})
    changes.append("add PostToolUse nudge hook (matcher *, timeout 5)")

groups = hooks.setdefault("SessionStart", [])
grp = next((g for g in groups if isinstance(g, dict) and g.get("matcher") == "compact"
            and isinstance(g.get("hooks"), list)), None)
if grp is None:
    grp = {"matcher": "compact", "hooks": []}
    groups.append(grp)
for n, cmd in enumerate(post, 1):
    if any(isinstance(h, dict) and h.get("command") == cmd for h in grp["hooks"]):
        changes.append("SessionStart compact --part %d already present" % n)
    else:
        grp["hooks"].append({"type": "command", "command": cmd, "timeout": 10})
        changes.append("add SessionStart compact --part %d (timeout 10)" % n)

# permission so the model can write its handoff without a prompt
perms = data.setdefault("permissions", {})
if not isinstance(perms, dict):
    sys.exit("settings.json: permissions is not an object")
allow = perms.setdefault("allow", [])
allow_added = False
if allow_rule in allow:
    changes.append("permissions.allow already has %s" % allow_rule)
else:
    allow.append(allow_rule)
    allow_added = True
    changes.append("add permissions.allow %s" % allow_rule)

window_set = None
if os.environ["HC_SETWINDOW"] == "1":
    env = data.setdefault("env", {})
    if not isinstance(env, dict):
        sys.exit("settings.json: env is not an object")
    key = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
    if key in env:
        changes.append("%s already set to %r, left alone" % (key, env[key]))
    else:
        env[key] = os.environ["HC_WINDOW"]
        window_set = os.environ["HC_WINDOW"]
        changes.append("set env.%s = %s" % (key, window_set))
else:
    changes.append("window left alone (--no-window)")

for c in changes:
    print("%ssettings: %s" % (tag, c))

changed = json.dumps(data, sort_keys=True) != before
if not changed:
    print("%ssettings: no change needed" % tag)
if dry or not changed:
    sys.exit(0)

if existed:
    bak = "%s.bak-%s" % (path, ts)
    shutil.copy2(path, bak)
    print("settings: backup -> %s" % bak)
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp-handoff"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
print("settings: written %s" % path)

# remember what we added so uninstall removes exactly that
marker = {}
if os.path.exists(marker_path):
    try:
        with open(marker_path, encoding="utf-8") as f:
            marker = json.load(f)
    except Exception:
        marker = {}
if window_set is not None:
    marker["window_set"] = window_set
if allow_added:
    marker["allow_added"] = True
marker.setdefault("window_set", None)
marker.setdefault("allow_added", False)
os.makedirs(hooks_dir, exist_ok=True)
with open(marker_path, "w", encoding="utf-8") as f:
    json.dump(marker, f)
PY

# hook files and state dir (after the settings merge, so a conflict exit 2 changes nothing)
for f in $FILES; do
  target="$HOOKS_DIR/$f"
  if [ -f "$target" ] && cmp -s "$SRC/hooks/$f" "$target"; then
    say "hook unchanged: $target"; continue
  fi
  if [ -e "$target" ]; then say "back up existing $target -> $BACKUP/$f"; fi
  say "install hook: $target"
  if [ "$DRY" = 0 ]; then
    mkdir -p "$HOOKS_DIR"
    if [ -e "$target" ]; then mkdir -p "$BACKUP"; cp -p "$target" "$BACKUP/$f"; fi
    cp "$SRC/hooks/$f" "$target"; chmod 755 "$target"
  fi
done

# 2. state dir
if [ -d "$STATE_DIR" ]; then say "state dir exists: $STATE_DIR"; else
  say "create state dir: $STATE_DIR"; [ "$DRY" = 1 ] || mkdir -p "$STATE_DIR"; fi

echo
if [ "$DRY" = 1 ]; then echo "Dry run only: nothing was changed."; else
  echo "Installed. Restart Claude Code to load the hooks."
  echo "Verify after the first compaction: tail -n 3 $STATE_DIR/health.jsonl"
fi
