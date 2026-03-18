#!/bin/bash
# Auto-bump dashboard version: v{year}.{week}.{patch}
# Format: 26.12.0 → year 2026, ISO week 12, patch 0
# Patch increments each deploy within a week, resets to 0 on new week.

set -e
cd "$(dirname "$0")"

YEAR=$(date +%y)
WEEK=$(date +%V | sed 's/^0//')  # strip leading zero
CURRENT=$(cat VERSION 2>/dev/null || echo "0.0.0")

CUR_YEAR=$(echo "$CURRENT" | cut -d. -f1)
CUR_WEEK=$(echo "$CURRENT" | cut -d. -f2)
CUR_PATCH=$(echo "$CURRENT" | cut -d. -f3)

if [ "$CUR_YEAR" = "$YEAR" ] && [ "$CUR_WEEK" = "$WEEK" ]; then
  PATCH=$((CUR_PATCH + 1))
else
  PATCH=0
fi

NEW_VERSION="${YEAR}.${WEEK}.${PATCH}"
echo "$NEW_VERSION" > VERSION

# Update index.html
sed -i '' "s/v[0-9]\{2\}\.[0-9]\{1,2\}\.[0-9]\{1,\}/v${NEW_VERSION}/g" index.html

echo "v${NEW_VERSION}"
