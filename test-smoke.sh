#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/data/small" "$TMP/data/medium" "$TMP/data/large" "$TMP/reports"
dd if=/dev/zero of="$TMP/data/small/small.bin" bs=1K count=64 status=none
dd if=/dev/zero of="$TMP/data/medium/medium.bin" bs=1M count=8 status=none
dd if=/dev/zero of="$TMP/data/large/large.bin" bs=1M count=16 status=none

cat > "$TMP/settings.cfg" <<EOF
TEST_NAME=smoke
ENGINE=pattern-dd
REPORT_INTERVAL_SECONDS=2
THEORETICAL_BPS=1250000000
REPORT_BASE=$TMP/reports
NOTIFY_HELPER=/no/such/helper
ALLOW_DESTRUCTIVE_WRITES=false
ALLOW_MOUNT_CHANGES=false
FAIL_ON_WRONG_ROUTE=false
REQUIRE_EXPECTED_SUBNET=false
EXPECTED_DATA_SUBNET_PREFIX=127.
EOF

cat > "$TMP/sources.cfg" <<'EOF'
source|local-smoke|posix|127.0.0.1|local|smoke|true
EOF

cat > "$TMP/workers.cfg" <<EOF
worker|local-smoke|local|localhost|$TMP/data|127.0.0.1|1|true|127.0.0.1
EOF

cat > "$TMP/paths.cfg" <<'EOF'
SMALL_DIR=small
MEDIUM_DIR=medium
LARGE_DIR=large
EOF

cat > "$TMP/schedule.cfg" <<'EOF'
phase|observe|3s|1|media-read|low
EOF

cat > "$TMP/behavior.cfg" <<'EOF'
profile|media-read|pattern-dd|read|1M|55|35|10|1|1|2|1|3|1
EOF

BACKBONE_CONFIG_DIR="$TMP" BACKBONE_NOTIFY=false "$ROOT/runbook.sh" validate
run_dir="$(BACKBONE_CONFIG_DIR="$TMP" BACKBONE_NOTIFY=false "$ROOT/runbook.sh" run | tail -n 1)"
test -d "$run_dir"
test -s "$run_dir/local-smoke.observe.metrics.tsv"
grep -q 'phase=observe' "$run_dir/run.log"
printf 'smoke ok: %s\n' "$run_dir"
