#!/usr/bin/env bash
# export-openclaw-state.sh
# Exports OpenClaw state to JSON files for the Grafana dashboard
# Runs via openclaw cron every 5 minutes

set -euo pipefail

LIVE_DIR="$HOME/.openclaw/workspace/dashboard-ui/live"
OPENCLAW="/opt/homebrew/bin/openclaw"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOCAL_TS=$(date +"%Y-%m-%d %H:%M %Z")

mkdir -p "$LIVE_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ─── CRON JOBS ──────────────────────────────────────────────────────────────
log "Exporting cron jobs..."
CRON_RAW=$("$OPENCLAW" cron list --json 2>/dev/null || echo '{"jobs":[]}')

python3 - "$CRON_RAW" "$TIMESTAMP" "$LOCAL_TS" <<'PYEOF'
import json, sys, datetime

raw, ts, local_ts = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.loads(raw)
except Exception:
    data = {"jobs": []}

def ms_to_relative(ms):
    if not ms:
        return None
    try:
        import time
        now = time.time() * 1000  # actual UTC ms
        diff = (ms - now) / 1000  # seconds
        if diff > 0:
            mins = int(diff / 60)
            if mins < 60: return f"in {mins}m"
            hrs = mins // 60
            if hrs < 24: return f"in {hrs}h"
            return f"in {hrs//24}d"
        else:
            diff = abs(diff)
            mins = int(diff / 60)
            if mins < 60: return f"{mins}m ago"
            hrs = mins // 60
            if hrs < 24: return f"{hrs}h ago"
            return f"{hrs//24}d ago"
    except:
        return None

def ms_to_iso(ms):
    if not ms:
        return None
    try:
        import datetime
        return datetime.datetime.fromtimestamp(ms/1000, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except:
        return None

def schedule_str(sched):
    if not sched:
        return "unknown"
    kind = sched.get("kind", "")
    if kind == "every":
        ms = sched.get("everyMs", 0)
        mins = ms // 60000
        if mins < 60: return f"every {mins}m"
        hrs = mins // 60
        if hrs < 24: return f"every {hrs}h"
        return f"every {hrs//24}d"
    elif kind == "cron":
        return sched.get("cronExpr", "cron")
    return kind

jobs_out = []
for j in data.get("jobs", []):
    state = j.get("state", {})
    sched = j.get("schedule", {})
    last_status = state.get("lastStatus") or state.get("lastRunStatus") or "idle"
    consecutive_errors = state.get("consecutiveErrors", 0)
    jobs_out.append({
        "id": j.get("id", ""),
        "name": j.get("name", ""),
        "enabled": j.get("enabled", True),
        "schedule": schedule_str(sched),
        "lastRun": ms_to_relative(state.get("lastRunAtMs")),
        "lastRunAt": ms_to_iso(state.get("lastRunAtMs")),
        "nextRun": ms_to_relative(state.get("nextRunAtMs")),
        "nextRunAt": ms_to_iso(state.get("nextRunAtMs")),
        "status": last_status,
        "consecutiveErrors": consecutive_errors,
        "lastDurationMs": state.get("lastDurationMs"),
        "lastError": state.get("lastError") or ("consecutive errors: " + str(consecutive_errors) if consecutive_errors > 0 else ""),
    })

out = {
    "updatedAt": local_ts,
    "updatedAtIso": ts,
    "total": len(jobs_out),
    "jobs": jobs_out
}
import os
live_dir = os.path.expanduser("~/.openclaw/workspace/dashboard-ui/live")
with open(os.path.join(live_dir, "cron-jobs.json"), "w") as f:
    json.dump(out, f, indent=2)
print(f"Wrote {len(jobs_out)} cron jobs")
PYEOF

# ─── GATEWAY STATUS ─────────────────────────────────────────────────────────
log "Exporting gateway status..."
STATUS_RAW=$("$OPENCLAW" status 2>/dev/null || echo "")

python3 - "$STATUS_RAW" "$TIMESTAMP" "$LOCAL_TS" <<'PYEOF'
import json, sys, re, os

raw, ts, local_ts = sys.argv[1], sys.argv[2], sys.argv[3]

def extract(pattern, text, group=1, default="unknown"):
    m = re.search(pattern, text)
    return m.group(group) if m else default

# Parse sessions count
sessions_match = re.search(r'sessions (\d+)', raw)
sessions_count = int(sessions_match.group(1)) if sessions_match else 0

# Parse active sessions from table
active_sessions = []
for line in raw.splitlines():
    if "agent:main:" in line and "|" not in line:
        parts = line.split()
        if len(parts) >= 4:
            kind = parts[0] if parts[0] in ("group","direct") else "direct"
            key = parts[1] if len(parts) > 1 else ""
            age = parts[2] if len(parts) > 2 else ""
            model = parts[3] if len(parts) > 3 else ""
            tokens = parts[4] if len(parts) > 4 else ""
            active_sessions.append({"kind": kind, "key": key, "age": age, "model": model, "tokens": tokens})

# Gateway state
gw_state = "unknown"
if "running" in raw:
    gw_state = "running"
elif "stopped" in raw or "not running" in raw:
    gw_state = "stopped"

# PID
pid_m = re.search(r'pid (\d+)', raw)
pid = int(pid_m.group(1)) if pid_m else None

# Channel status
slack_ok = "OK" in raw and "Slack" in raw

# Memory info
mem_m = re.search(r'(\d+) files · (\d+) chunks', raw)
mem_files = int(mem_m.group(1)) if mem_m else 0
mem_chunks = int(mem_m.group(2)) if mem_m else 0

out = {
    "updatedAt": local_ts,
    "updatedAtIso": ts,
    "gateway": {
        "state": gw_state,
        "pid": pid,
        "type": "local",
    },
    "sessions": {
        "total": sessions_count,
        "active": len([s for s in active_sessions if "just now" in s.get("age","") or "m ago" in s.get("age","") or "1h" in s.get("age","")]),
        "recent": active_sessions[:10],
    },
    "channels": {
        "slack": "ok" if slack_ok else "unknown"
    },
    "memory": {
        "files": mem_files,
        "chunks": mem_chunks
    },
    "model": extract(r'default (\S+)', raw),
    "rawStatus": raw[:2000] if raw else ""
}

live_dir = os.path.expanduser("~/.openclaw/workspace/dashboard-ui/live")
with open(os.path.join(live_dir, "gateway-status.json"), "w") as f:
    json.dump(out, f, indent=2)
print("Wrote gateway-status.json")
PYEOF

# ─── SESSION ACTIVITY ────────────────────────────────────────────────────────
log "Exporting session activity..."
SESSIONS_RAW=$("$OPENCLAW" sessions 2>/dev/null || echo "")

python3 - "$SESSIONS_RAW" "$TIMESTAMP" "$LOCAL_TS" <<'PYEOF'
import json, sys, re, os

raw, ts, local_ts = sys.argv[1], sys.argv[2], sys.argv[3]

sessions = []
for line in raw.splitlines():
    # Lines look like: "group  agent:main:slack...2jbktm  just now  claude-opus-4-6 119k/1000k (12%)     system id:..."
    parts = line.split()
    if len(parts) >= 3 and parts[0] in ("group", "direct") and "agent:main:" in parts[1]:
        kind = parts[0]
        key = parts[1]
        # age can be 1 or 2 tokens
        if len(parts) > 3 and parts[2] in ("just", "in"):
            age = parts[2] + " " + parts[3]
            rest = parts[4:]
        elif len(parts) > 2:
            age = parts[2]
            rest = parts[3:]
        else:
            age = "unknown"
            rest = []
        
        model = rest[0] if rest else "unknown"
        tokens_str = rest[1] if len(rest) > 1 else ""
        
        # parse token count from "119k/1000k"
        tok_m = re.match(r'(\d+)k?/(\d+)k?', tokens_str)
        tokens_in = int(tok_m.group(1)) if tok_m else 0
        tokens_max = int(tok_m.group(2)) if tok_m else 0
        
        # determine session type
        if "cron" in key:
            stype = "cron"
        elif "slack" in key or "discord" in key:
            stype = "channel"
        elif "subagent" in key:
            stype = "subagent"
        else:
            stype = "direct"
        
        sessions.append({
            "kind": kind,
            "type": stype,
            "key": key,
            "age": age,
            "model": model,
            "tokensK": tokens_in,
            "maxK": tokens_max,
            "pct": round(tokens_in / tokens_max * 100, 1) if tokens_max > 0 else 0
        })

out = {
    "updatedAt": local_ts,
    "updatedAtIso": ts,
    "total": len(sessions),
    "sessions": sessions[:30]
}

live_dir = os.path.expanduser("~/.openclaw/workspace/dashboard-ui/live")
with open(os.path.join(live_dir, "session-activity.json"), "w") as f:
    json.dump(out, f, indent=2)
print(f"Wrote {len(sessions)} sessions")
PYEOF

# ─── ERRORS LOG ─────────────────────────────────────────────────────────────
log "Building errors log..."
python3 - "$TIMESTAMP" "$LOCAL_TS" <<'PYEOF'
import json, sys, os

ts, local_ts = sys.argv[1], sys.argv[2]
live_dir = os.path.expanduser("~/.openclaw/workspace/dashboard-ui/live")

errors = []

# Pull from system-health.json if it exists
sh_path = os.path.join(live_dir, "system-health.json")
if os.path.exists(sh_path):
    try:
        sh = json.load(open(sh_path))
        for e in sh.get("errors", []):
            errors.append({
                "time": e.get("time", ""),
                "component": e.get("component", ""),
                "severity": e.get("severity", "warn"),
                "status": e.get("status", "open"),
                "error": e.get("error", ""),
                "meaning": e.get("meaning", ""),
                "suggestedFix": e.get("suggestedFix", "")
            })
    except:
        pass

# Pull from cron-jobs.json: jobs with errors
cj_path = os.path.join(live_dir, "cron-jobs.json")
if os.path.exists(cj_path):
    try:
        cj = json.load(open(cj_path))
        for j in cj.get("jobs", []):
            if j.get("status") == "error" or (j.get("consecutiveErrors", 0) > 0):
                errors.append({
                    "time": j.get("lastRunAt", ""),
                    "component": j.get("name", ""),
                    "severity": "error" if j.get("status") == "error" else "warn",
                    "status": "open",
                    "error": j.get("lastError") or f"Status: {j.get('status')}",
                    "meaning": f"Cron job failed with {j.get('consecutiveErrors',0)} consecutive errors",
                    "suggestedFix": "Check cron job logs for details"
                })
    except:
        pass

# Deduplicate by component
seen = set()
deduped = []
for e in errors:
    key = (e.get("component",""), e.get("error",""))
    if key not in seen:
        seen.add(key)
        deduped.append(e)

out = {
    "updatedAt": local_ts,
    "updatedAtIso": ts,
    "total": len(deduped),
    "errors": deduped
}

with open(os.path.join(live_dir, "errors-log.json"), "w") as f:
    json.dump(out, f, indent=2)
print(f"Wrote {len(deduped)} errors")
PYEOF

log "Export complete at $LOCAL_TS"

# ─── SYSTEM SUMMARY (flat for stat panels) ────────────────────────────────
log "Building system summary..."
python3 - "$LIVE_DIR" <<'PYEOF2'
import json, sys, os
live = sys.argv[1]
gw = {}; sh = {}
try: gw = json.load(open(os.path.join(live, "gateway-status.json")))
except: pass
try: sh = json.load(open(os.path.join(live, "system-health.json")))
except: pass
flat = [{"gateway": gw.get("gateway",{}).get("state","unknown"), "model": gw.get("model","unknown"), "sessions": gw.get("sessions",{}).get("total",0), "slack": gw.get("channels",{}).get("slack","unknown"), "overall": sh.get("summary",{}).get("overall","unknown"), "failingJobs": sh.get("summary",{}).get("failingJobs",0), "enabledJobs": sh.get("summary",{}).get("enabledJobs",0)}]
with open(os.path.join(live, "system-summary.json"), "w") as f:
    json.dump({"summary": flat}, f, indent=2)
print(f"Wrote system-summary.json")
PYEOF2
