#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_STATUS="$(mktemp)"
TMP_DOCTOR="$(mktemp)"
openclaw status > "$TMP_STATUS" 2>&1 || true
openclaw doctor --non-interactive > "$TMP_DOCTOR" 2>&1 || true
jq -n \
  --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg status "$(tail -n 60 "$TMP_STATUS" | tr '\n' ' ' | sed 's/"/\\"/g')" \
  --arg doctor "$(tail -n 80 "$TMP_DOCTOR" | tr '\n' ' ' | sed 's/"/\\"/g')" \
  '{updatedAt:$updatedAt,raw:{statusTail:$status,doctorTail:$doctor}}' > "$OUT_DIR/state.json"
rm -f "$TMP_STATUS" "$TMP_DOCTOR"
echo "wrote $OUT_DIR/state.json"
