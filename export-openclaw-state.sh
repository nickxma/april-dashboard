#!/usr/bin/env bash
# export-openclaw-state.sh
# Exports OpenClaw state to JSON files for the Grafana dashboard
# Runs via openclaw cron every 5 minutes

# Cron-safe PATH: ensure common tool locations are available
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_DIR="$HOME/.openclaw/workspace/dashboard-ui/live"
LOG_FILE="$SCRIPT_DIR/export.log"
OPENCLAW="/opt/homebrew/bin/openclaw"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOCAL_TS=$(date +"%Y-%m-%d %H:%M %Z")

# Rotate log if > 1MB
if [[ -f "$LOG_FILE" ]] && [[ $(wc -c < "$LOG_FILE") -gt 1048576 ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.1"
fi
exec >> "$LOG_FILE" 2>&1

# Trap errors and log them with line number
trap 'log "ERROR: Script failed at line $LINENO (exit code $?)"' ERR

mkdir -p "$LIVE_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "--- Export started at $LOCAL_TS ---"

# ─── CRON JOBS ──────────────────────────────────────────────────────────────
log "Exporting cron jobs..."
CRON_TMPFILE=$(mktemp /tmp/openclaw-cron-XXXXXX.json)
"$OPENCLAW" cron list --json 2>/dev/null > "$CRON_TMPFILE" || echo '{"jobs":[]}' > "$CRON_TMPFILE"

python3 - "$CRON_TMPFILE" "$TIMESTAMP" "$LOCAL_TS" <<'PYEOF'
import json, sys, datetime

cron_file, ts, local_ts = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(cron_file) as f:
        data = json.load(f)
except Exception:
    data = {"jobs": []}
import os; os.unlink(cron_file)

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

DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]

def fmt_hour(h):
    """Convert 0-23 hour to 12h string like '9am', '5pm'."""
    h = int(h)
    if h == 0: return "12am"
    if h == 12: return "12pm"
    return f"{h}am" if h < 12 else f"{h-12}pm"

def cron_to_human(expr, tz=""):
    """Convert simple cron expressions to human-readable strings."""
    parts = expr.strip().split()
    if len(parts) != 5:
        return expr
    m, h, dom, mon, dow = parts
    tz_short = tz.split("/")[-1] if tz else ""
    suffix = f" ({tz_short})" if tz_short else ""

    # Hour is a number, minute is 0
    if not h.isdigit():
        return expr + suffix
    time_str = fmt_hour(h) if m == "0" else f"{h}:{m.zfill(2)}"

    # daily: dom=* mon=* dow=*
    if dom == "*" and mon == "*" and dow == "*":
        return f"{time_str} daily{suffix}"

    # specific weekdays (e.g. "1,3,5" or "0")
    if dom == "*" and mon == "*" and dow != "*":
        days = dow.split(",")
        day_names = [DAYS[int(d)] for d in days if d.isdigit() and int(d) < 7]
        if len(day_names) == 7:
            return f"{time_str} daily{suffix}"
        if len(day_names) == 1:
            full = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
            return f"{full[int(days[0])]+'s'} {time_str}{suffix}"
        return f"{'/'.join(day_names)} {time_str}{suffix}"

    return expr + suffix

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
        expr = sched.get("expr") or sched.get("cronExpr", "")
        tz = sched.get("tz", "")
        return cron_to_human(expr, tz) if expr else "cron"
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

# Compute next 5 upcoming runs sorted by nextRunAt ISO string
next_runs = sorted(
    [j for j in jobs_out if j.get("nextRunAt")],
    key=lambda x: x["nextRunAt"]
)[:5]

out = {
    "updatedAt": local_ts,
    "updatedAtIso": ts,
    "total": len(jobs_out),
    "jobs": jobs_out,
    "nextRuns": next_runs
}
import os
live_dir = os.path.expanduser("~/.openclaw/workspace/dashboard-ui/live")
cron_path = os.path.join(live_dir, "cron-jobs.json")
if jobs_out:
    with open(cron_path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"Wrote {len(jobs_out)} cron jobs")
else:
    # openclaw returned empty list (service momentarily busy) — keep last good file
    print(f"Wrote 0 cron jobs (skipped: kept previous cron-jobs.json)")
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

# Build cron job UUID suffix → name lookup
# openclaw sessions truncates keys as "agent:main:cron:...SUFFIX" (last 6 hex chars)
cron_lookup = {}
try:
    import json as _json
    cj_path = os.path.join(os.path.expanduser("~/.openclaw/workspace/dashboard-ui/live"), "cron-jobs.json")
    cj_data = _json.load(open(cj_path))
    for j in cj_data.get("jobs", []):
        uuid_clean = j["id"].replace("-", "")
        cron_lookup[uuid_clean[-6:]] = j["name"]  # last 6 hex chars of UUID
except Exception:
    pass

sessions = []
for line in raw.splitlines():
    # Lines look like: "group  agent:main:slack...2jbktm  just now  claude-opus-4-6 119k/1000k (12%)     system id:..."
    parts = line.split()
    if len(parts) >= 3 and parts[0] in ("group", "direct") and "agent:main:" in parts[1]:
        kind = parts[0]
        key = parts[1]
        # age can be 1 or 2 tokens
        # Formats: "just now", "in 13m", "12m ago", "2h ago"
        if len(parts) > 3 and parts[2] in ("just", "in"):
            age = parts[2] + " " + parts[3]
            rest = parts[4:]
        elif len(parts) > 3 and parts[3] == "ago":
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

        # resolve job name from cron UUID suffix in key
        label = key
        if stype == "cron":
            # key format: agent:main:cron:...SUFFIX (last 6 hex chars of UUID)
            raw_suffix = key.split(":")[-1].replace("...", "").replace("\u2026", "").replace("…", "").strip()
            suffix6 = raw_suffix[-6:] if len(raw_suffix) >= 6 else raw_suffix
            label = cron_lookup.get(suffix6, key)

        sessions.append({
            "kind": kind,
            "type": stype,
            "key": key,
            "label": label,
            "age": age,
            "model": model,
            "tokensK": tokens_in,
            "maxK": tokens_max,
            "pct": round(tokens_in / tokens_max * 100, 1) if tokens_max > 0 else 0
        })

# Dedup: for each age bucket, if a resolved cron session exists,
# drop unresolved cron sessions with the same age (they are spawned sub-agents)
from collections import defaultdict
resolved_ages = set()
for s in sessions:
    if s["type"] == "cron" and s["label"] != s["key"]:
        resolved_ages.add(s["age"])
deduped = []
for s in sessions:
    if s["type"] == "cron" and s["label"] == s["key"] and s["age"] in resolved_ages:
        continue  # skip unresolved duplicate at same age as a resolved cron session
    deduped.append(s)

out = {
    "updatedAt": local_ts,
    "updatedAtIso": ts,
    "total": len(deduped),
    "sessions": deduped[:30]
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

log "--- Export complete at $LOCAL_TS ---"

# ─── RESEARCH SUMMARY (array wrapper for Infinity compatibility) ──────────
python3 - "$LIVE_DIR" <<'PYEOF_RESEARCH'
import json, sys, os
live = sys.argv[1]
rt_path = os.path.join(live, "research-tasks.json")
out_path = os.path.join(live, "research-summary.json")
try:
    rt = json.load(open(rt_path))
    row = {
        "probabilityPct": rt.get("paypalAcquisitionProbabilityPct", 0),
        "thesis": rt.get("thesis", ""),
        "method": rt.get("method", ""),
        "updatedAt": rt.get("updatedAt", ""),
    }
    with open(out_path, "w") as f:
        json.dump({"summary": [row]}, f, indent=2)
    print(f"Wrote research-summary.json (probability={row['probabilityPct']}%)")
except Exception as e:
    print(f"research-summary: skipped ({e})")
PYEOF_RESEARCH

# ─── OPEN LOOPS ENRICHMENT (add daysUntilDeadline, sort by urgency) ──────────
# NOTE: Must run before SYSTEM SUMMARY so urgentLoops/totalLoops are current
python3 - "$LIVE_DIR" <<'PYEOF_LOOPS_EARLY'
import json, sys, os, datetime, re
live = sys.argv[1]
src = os.path.join(live, "open-loops.json")
out = os.path.join(live, "open-loops-enriched.json")
try:
    data = json.load(open(src))
    today = datetime.date.today()
    loops = []
    def parse_deadline_date(dl):
        """Parse deadline string to date object, handling both date-only and ISO datetime formats."""
        if not dl:
            return None
        for fmt in (
            lambda s: datetime.date.fromisoformat(s),                        # "2026-03-25"
            lambda s: datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).date(),  # "2026-03-25T14:00:00.000Z"
        ):
            try:
                return fmt(dl)
            except Exception:
                pass
        return None
    for l in data.get("loops", []):
        dl = l.get("deadline")
        d_obj = parse_deadline_date(dl)
        days_until = (d_obj - today).days if d_obj else None
        deadline_short = d_obj.strftime("%-m/%-d") if d_obj else ""
        item_text = l.get("item", "")
        olu_match = re.search(r'OLU-(\d+)', item_text)
        olu_link = f"http://127.0.0.1:3000/OLU/issues/OLU-{olu_match.group(1)}" if olu_match else ""
        next_action = l.get("nextAction", "")
        next_action = re.sub(r'^(?:Nick|Claw|[A-Z][a-z]+):\s*', '', next_action)
        loops.append({**{k: v for k, v in l.items() if k != "nextAction"},
                      "nextAction": next_action,
                      "daysUntilDeadline": days_until if days_until is not None else 999,
                      "deadlineShort": deadline_short, "oluLink": olu_link})
    loops.sort(key=lambda x: x["daysUntilDeadline"])
    with open(out, "w") as f:
        json.dump({"loops": loops, "updatedAt": data.get("updatedAt", "")}, f, indent=2)
    print(f"Wrote open-loops-enriched.json ({len(loops)} items, early pass)")
except Exception as e:
    print(f"open-loops-enriched (early): skipped ({e})")
PYEOF_LOOPS_EARLY

# ─── SYSTEM SUMMARY (flat for stat panels) ────────────────────────────────
log "Building system summary..."
python3 - "$LIVE_DIR" "$LOCAL_TS" <<'PYEOF2'
import json, sys, os, datetime
live, local_ts = sys.argv[1], sys.argv[2]
gw = {}; sh = {}; cj = {}
try: gw = json.load(open(os.path.join(live, "gateway-status.json")))
except: pass
try: sh = json.load(open(os.path.join(live, "system-health.json")))
except: pass
try: cj = json.load(open(os.path.join(live, "cron-jobs.json")))
except: pass
sa = {}
try: sa = json.load(open(os.path.join(live, "session-activity.json")))
except: pass
ol = {}
try: ol = json.load(open(os.path.join(live, "open-loops-enriched.json")))
except: pass
gw_state = gw.get("gateway",{}).get("state","unknown")
slack_state = gw.get("channels",{}).get("slack","unknown")
model_val = gw.get("model","unknown")
sh_summary = sh.get("summary", {})
open_errors = sh_summary.get("openErrors", 0)
stale_jobs = sh_summary.get("staleJobs", 0)
# Compute live job counts directly from cron-jobs.json (fresher than system-health.json)
cj_jobs = cj.get("jobs", [])
failing_jobs = len([j for j in cj_jobs if j.get("status") == "error"])
enabled_jobs = len([j for j in cj_jobs if j.get("enabled", True)])
ok_jobs = len([j for j in cj_jobs if j.get("status") == "ok"])
cron_success_pct = round(ok_jobs / enabled_jobs * 100) if enabled_jobs > 0 else 100
# Compute overall freshly: error state if any subsystem is down, degraded if jobs failing
gw_ok = gw_state == "running"
slack_ok = slack_state == "ok"
if not gw_ok or not slack_ok:
    overall_val = "error"
elif failing_jobs > 0 or stale_jobs > 0:
    overall_val = "degraded"
else:
    overall_val = "ok"
flat = [{
    "gateway": gw_state,
    "gatewayOk": 1 if gw_ok else 0,
    "model": model_val,
    "modelOk": 1 if model_val not in ("unknown", "") else 0,
    "sessions": gw.get("sessions",{}).get("total",0),
    "slack": slack_state,
    "slackOk": 1 if slack_ok else 0,
    "overall": overall_val,
    "statusLevel": 1 if overall_val == "ok" else (0 if overall_val == "degraded" else -1),
    "failingJobs": failing_jobs,
    "enabledJobs": enabled_jobs,
    "openErrors": open_errors,
    "staleJobs": stale_jobs,
    "totalTokensK": sum(s.get("tokensK", 0) for s in sa.get("sessions", [])),
    "sonnetTokensK": sum(s.get("tokensK", 0) for s in sa.get("sessions", []) if "sonnet" in s.get("model", "").lower()),
    "opusTokensK": sum(s.get("tokensK", 0) for s in sa.get("sessions", []) if "opus" in s.get("model", "").lower()),
    "activeSessions": len([s for s in sa.get("sessions", []) if s.get("tokensK", 0) > 0]),
    "cronSuccessPct": cron_success_pct,
    "urgentLoops": len([l for l in ol.get("loops", []) if 0 <= l.get("daysUntilDeadline", 999) <= 7]),
    "totalLoops": len(ol.get("loops", [])),
    "updatedAt": cj.get("updatedAt", local_ts),
    "dataAgeMinutes": round((datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(cj["updatedAtIso"].replace("Z","+00:00"))).total_seconds() / 60) if cj.get("updatedAtIso") else 0,
}]
with open(os.path.join(live, "system-summary.json"), "w") as f:
    json.dump({"summary": flat}, f, indent=2)
print(f"Wrote system-summary.json")
PYEOF2

# ─── RESEARCH EVIDENCE (array wrapper for Infinity panel) ────────────────────
python3 - "$LIVE_DIR" <<'PYEOF_EVIDENCE'
import json, sys, os
live = sys.argv[1]
rt_path = os.path.join(live, "research-tasks.json")
out_path = os.path.join(live, "research-evidence.json")
try:
    rt = json.load(open(rt_path))
    evidence = rt.get("evidence", [])
    rows = []
    for e in sorted(evidence, key=lambda x: x.get("date",""), reverse=True):
        rows.append({
            "date":      e.get("date", ""),
            "direction": e.get("direction", ""),
            "strength":  e.get("strength", ""),
            "signal":    e.get("signal", ""),
            "url":       e.get("url", ""),
        })
    with open(out_path, "w") as f:
        json.dump({"evidence": rows}, f, indent=2)
    print(f"Wrote research-evidence.json ({len(rows)} items)")
except Exception as e:
    print(f"research-evidence: skipped ({e})")
PYEOF_EVIDENCE

# ─── OBJECTIVES ENRICHMENT (add statusOrder for sort) ──────────────────────
python3 - "$LIVE_DIR" <<'PYEOF_OBJ'
import json, sys, os
live = sys.argv[1]
src = os.path.join(live, "objectives.json")
out = os.path.join(live, "objectives-enriched.json")
try:
    data = json.load(open(src))
    objs = []
    for o in data.get("objectives", []):
        status = o.get("status", "")
        status_order = {"Active": 1, "Paused": 2, "Done": 3, "Dropped": 4}.get(status, 5)
        objs.append({**o, "statusOrder": status_order})
    objs.sort(key=lambda x: x["statusOrder"])
    with open(out, "w") as f:
        json.dump({"objectives": objs, "updatedAt": data.get("updatedAt", ""),
                   "sources": data.get("sources", [])}, f, indent=2)
    print(f"Wrote objectives-enriched.json ({len(objs)} objectives)")
except Exception as e:
    print(f"objectives-enriched: skipped ({e})")
PYEOF_OBJ

# ─── INTEGRATIONS ENRICHMENT (add relative lastVerifiedAge) ──────────────────
python3 - "$LIVE_DIR" <<'PYEOF_INTEG'
import json, sys, os, datetime
live = sys.argv[1]
src = os.path.join(live, "integrations.json")
out = os.path.join(live, "integrations-enriched.json")
try:
    data = json.load(open(src))
    now = datetime.datetime.now(datetime.timezone.utc)
    enriched = []
    for item in data.get("connected", []):
        lv = item.get("lastVerified", "")
        age_str = ""
        if lv:
            try:
                dt = datetime.datetime.fromisoformat(lv.replace("Z", "+00:00"))
                secs = (now - dt).total_seconds()
                if secs < 3600:
                    age_str = f"{int(secs/60)}m ago"
                elif secs < 86400:
                    age_str = f"{int(secs/3600)}h ago"
                else:
                    age_str = f"{int(secs/86400)}d ago"
            except Exception:
                age_str = lv[:10]
        enriched.append({**item, "lastVerifiedAge": age_str})
    with open(out, "w") as f:
        json.dump({"connected": enriched, "updatedAt": data.get("updatedAt", "")}, f, indent=2)
    print(f"Wrote integrations-enriched.json ({len(enriched)} integrations)")
except Exception as e:
    print(f"integrations-enriched: skipped ({e})")
PYEOF_INTEG

# ─── CONTROL TOWER ENRICHMENT (add agentSortOrder for error-first sort) ───────
python3 - "$LIVE_DIR" <<'PYEOF_CT'
import json, sys, os
live = sys.argv[1]
src = os.path.join(live, "control-tower.json")
out = os.path.join(live, "control-tower-enriched.json")
STATUS_ORDER = {"error": 1, "running": 2, "ok": 3, "On-demand": 4, "Scheduled": 5}
try:
    data = json.load(open(src))
    agents = []
    for a in data.get("agents", []):
        status = a.get("status", "")
        sort_key = STATUS_ORDER.get(status, 6)
        agents.append({**a, "agentSortOrder": sort_key})
    agents.sort(key=lambda x: x["agentSortOrder"])
    enriched = {**data, "agents": agents}
    with open(out, "w") as f:
        json.dump(enriched, f, indent=2)
    print(f"Wrote control-tower-enriched.json ({len(agents)} agents)")
except Exception as e:
    print(f"control-tower-enriched: skipped ({e})")
PYEOF_CT

# ─── CRON SCHEDULE BY HOUR (for schedule distribution bargauge) ──────────────
python3 - "$LIVE_DIR" <<'PYEOF_SCHED'
import json, sys, os
from collections import defaultdict

live = sys.argv[1]
try:
    cj = json.load(open(os.path.join(live, "cron-jobs.json")))
    jobs = cj.get("jobs", [])

    # Raw schedule data from source jobs.json for cron expressions
    import re
    time_jobs = defaultdict(list)
    interval_count = 0
    for j in jobs:
        sched = j.get("schedule", "")
        if not sched or not j.get("name"):
            continue
        # interval jobs: "every Xm/h"
        if sched.startswith("every "):
            interval_count += 1
            continue
        # time-specific: extract hour from schedule string like "1am daily (Chicago)"
        # or "Sundays 9am (Chicago)"
        m = re.search(r'(\d+)(am|pm)', sched)
        if m:
            h = int(m.group(1))
            suffix = m.group(2)
            if suffix == "pm" and h != 12:
                h += 12
            elif suffix == "am" and h == 12:
                h = 0
            time_jobs[h].append(j["name"])

    hours = []
    for h in range(24):
        timed = time_jobs.get(h, [])
        if not timed:
            continue  # only include hours with scheduled jobs
        label = f"{h % 12 or 12}{'am' if h < 12 else 'pm'}"
        hours.append({
            "hour": label,
            "hourNum": h,
            "timedJobs": len(timed),
            "jobNames": ", ".join(n[:22] for n in timed[:3]),
        })

    out = {
        "hours": hours,
        "intervalJobs": interval_count,
        "updatedAt": cj.get("updatedAt", ""),
    }
    with open(os.path.join(live, "cron-schedule-hours.json"), "w") as f:
        json.dump(out, f, indent=2)
    non_zero = [h for h in hours if h["timedJobs"] > 0]
    print(f"Wrote cron-schedule-hours.json ({len(non_zero)} active hours, {interval_count} interval jobs)")
except Exception as e:
    print(f"cron-schedule-hours: skipped ({e})")
PYEOF_SCHED
