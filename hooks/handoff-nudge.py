#!/usr/bin/env python3
"""PostToolUse hook: ask the working model to write its own handoff before auto-compaction.

Reads the hook JSON on stdin and the TAIL of the transcript only. When context crosses
75% of the auto-compact window (then every 25,000 tokens, plus one final note) it prints one
PostToolUse additionalContext note. Steps stay 12,000 tokens below the real compaction point
(window minus 33,000), so with a 400k window the notes come at 300k, 325k, 350k and a final at 355k. State lives in <sid>-agent.meta.json, which precompact-handoff.py
reads for its freshness rule. Never fails: any error means exit 0 with no output.
"""
import hashlib, json, os, re, sys, time

HOME = os.path.expanduser("~")
HANDOFFS_DIR = (os.environ.get("HANDOFF_STATE_DIR") or "").strip() or os.path.join(HOME, ".local", "state", "claude-handoffs")
DEFAULT_WINDOW = 400000
AT_PERCENT = 75
EVERY = 25000
CEILING_GAP = 33000
HEADROOM = 12000
TAIL_BYTES = 400000
HEADINGS = ["## Goal", "## Parallel work running", "## Decisions and why", "## Done", "## In progress", "## Dead ends", "## Exact next step"]
STALE_NAMES = ["Parallel work running", "In progress", "Exact next step"]
WRITE_TOOLS = {"Write", "Edit", "MultiEdit"}


def window():
    s = os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "")
    if re.fullmatch(r"\s*\d+\s*", s) and int(s) > 0:
        return int(s)
    return DEFAULT_WINDOW


def threshold(w, k):
    return -(-w * AT_PERCENT // 100) + k * EVERY


def limit(w):
    return w - CEILING_GAP - HEADROOM


def highest_k(t, w):
    t0 = threshold(w, 0)
    if t < t0:
        return -1
    k = (t - t0) // EVERY
    k_max = -(-(limit(w) - t0) // EVERY) - 1 if t0 < limit(w) else -1
    return min(k, k_max)


def final_due(t, w):
    return t >= limit(w)


def section_hashes(text):
    """Heading (no '## ') -> first 12 hex of SHA-256 of the section body, or 'absent'. Same rule as precompact-handoff.py."""
    names = [h[3:] for h in HEADINGS]
    bodies, cur = {}, None
    for ln in text.replace("\r\n", "\n").split("\n"):
        if ln.startswith("## "):
            h = ln[3:]
            cur = [] if (h in names and h not in bodies) else None
            if cur is not None:
                bodies[h] = cur
            continue
        if cur is not None:
            cur.append(ln)
    return {h: (hashlib.sha256("\n".join(bodies[h]).rstrip().encode("utf-8")).hexdigest()[:12]
                if h in bodies else "absent") for h in names}


def context_tokens(path):
    """Tokens of the last assistant entry that carries usage (input + cache read + cache creation)."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - TAIL_BYTES))
        data = f.read().decode("utf-8", "replace")
    for line in reversed(data.splitlines()):
        if '"usage"' not in line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("type") != "assistant":
            continue
        u = (e.get("message") or {}).get("usage")
        if not isinstance(u, dict):
            continue
        n = 0
        for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"):
            v = u.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                n += int(v)
        return n
    return None


def kfmt(n):
    return "%dk" % round(n / 1000)


def nudge_text(t, w, path, exists, final=False, stale=False):
    pct = (t * 100) // w
    return (
        "[claude-handoff] This note comes from the claude-handoff PostToolUse hook that the user installed in "
        "~/.claude/settings.json. It is not part of the tool result. "
        "Context is %d%% of the auto-compact window (%s of %s).%s Compaction will drop your working memory.%s "
        "Please, in one Write call, %s %s (create the folder if missing) with exactly these headings: %s. "
        "List your standing rules and operating mode under Decisions and why. "
        'Under Parallel work running list every background agent, subagent, builder or long-running job that is running or queued (name, task, branch or id, state), or "none". '
        'Rewrite "Parallel work running", "In progress" and "Exact next step" in place for the current state (never append "DONE since" notes), '
        'move finished items to "Done", keep it under 5000 chars, '
        "use real paths and ids, no secrets. This is expected and pre-approved by the user's settings. "
        "Then continue the user's task."
        % (pct, kfmt(t), kfmt(w), " Compaction is imminent." if final else "",
           " Your last handoff is STALE: Parallel work running, In progress and Exact next step are unchanged; rewrite them." if stale else "",
           "update" if exists else "write", path, ", ".join(HEADINGS))
    )


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    if not isinstance(payload, dict):
        return
    sid = str(payload.get("session_id") or "").replace("/", "_")
    tpath = payload.get("transcript_path")
    if not sid or not isinstance(tpath, str):
        return
    t = context_tokens(tpath)
    if t is None:
        return
    w = window()
    agent = os.path.join(HANDOFFS_DIR, "%s-agent.md" % sid)
    meta_path = os.path.join(HANDOFFS_DIR, "%s-agent.meta.json" % sid)
    try:
        with open(meta_path, encoding="utf-8") as f:
            meta = json.load(f)
        if not isinstance(meta, dict):
            meta = {}
    except Exception:
        meta = {}
    now = int(time.time() * 1000)
    changed = False

    # The model wrote the agent file: record it so the PreCompact freshness rule sees it.
    if payload.get("tool_name") in WRITE_TOOLS:
        fp = (payload.get("tool_input") or {}).get("file_path")
        if isinstance(fp, str) and os.path.realpath(os.path.expanduser(fp)) == os.path.realpath(agent):
            meta["agentWrittenAt"] = now
            meta["agentWrittenAtTokens"] = t
            changed = True

    k = highest_k(t, w)
    last_k = meta.get("lastK") if isinstance(meta.get("lastK"), int) else -1
    final_done = bool(meta.get("finalDone"))
    fdue = final_due(t, w) and not final_done
    out = None
    if k > last_k or fdue:
        if k > last_k:
            meta["lastK"] = k
        if fdue:
            meta["finalDone"] = True
        stale = False
        try:
            if os.path.isfile(agent):
                with open(agent, encoding="utf-8", errors="replace") as f:
                    cur = section_hashes(f.read())
                prev = meta.get("sections")
                stale = isinstance(prev, dict) and all(cur[h] == prev.get(h) and cur[h] != "absent" for h in STALE_NAMES)
                meta["sections"] = cur
        except Exception:
            stale = False
        meta["lastNudgeAt"] = now
        meta["lastNudgeTokens"] = t
        meta["nudgeCount"] = int(meta.get("nudgeCount") or 0) + 1
        out = {"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                      "additionalContext": nudge_text(t, w, agent, os.path.isfile(agent), fdue, stale)}}
        changed = True
    elif k < last_k:  # context shrank: a compaction happened, re-arm
        meta["lastK"] = k
        meta["finalDone"] = False
        changed = True

    if changed or meta.get("ctxTokens") != t:
        meta.update({"v": 1, "sessionId": sid, "window": w, "ctxTokens": t})
        try:
            os.makedirs(HANDOFFS_DIR, exist_ok=True)
            tmp = meta_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(meta, f)
            os.replace(tmp, meta_path)
        except Exception:
            out = out  # still deliver the note
    if out:
        sys.stdout.write(json.dumps(out))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
