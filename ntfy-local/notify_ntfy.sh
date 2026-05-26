#!/usr/bin/env bash
set -euo pipefail

SERVER="${NTFY_SERVER:-http://127.0.0.1:8099}"
TOPIC="${NTFY_TOPIC:-backbone-alerts}"
TITLE="${1:-AI-LORE Alert}"
MESSAGE="${2:-Something needs attention on backbone-test.}"

curl -fsS \
  -H "Title: $TITLE" \
  -H "Priority: default" \
  -H "Tags: warning,computer" \
  -d "$MESSAGE" \
  "$SERVER/$TOPIC" >/dev/null

