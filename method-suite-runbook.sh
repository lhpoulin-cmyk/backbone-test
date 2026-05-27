#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-validate}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BACKBONE_CONFIG_DIR:-$SCRIPT_DIR/configs/method-suite}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ACTIVE_TARGET_UNITS=()
ACTIVE_SOURCE_UNITS=()
CURRENT_RUN_DIR=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_key_values() {
  local file="$1"
  [[ -r "$file" ]] || die "missing config $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || die "invalid KEY=VALUE line in $file: $line"
    local key="${line%%=*}" value="${line#*=}"
    key="$(trim "$key")"
    value="$(trim "$value")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid key $key in $file"
    printf -v "$key" '%s' "$value"
  done < "$file"
}

duration_seconds() {
  local value="$1"
  case "$value" in
    *s) printf '%s' "${value%s}" ;;
    *m) printf '%s' "$(( ${value%m} * 60 ))" ;;
    *h) printf '%s' "$(( ${value%h} * 3600 ))" ;;
    ''|*[!0-9]*) die "invalid duration: $value" ;;
    *) printf '%s' "$value" ;;
  esac
}

bytes_value() {
  local value="$1"
  case "$value" in
    *K|*k) printf '%s' "$(( ${value%?} * 1024 ))" ;;
    *M|*m) printf '%s' "$(( ${value%?} * 1024 * 1024 ))" ;;
    *G|*g) printf '%s' "$(( ${value%?} * 1024 * 1024 * 1024 ))" ;;
    *T|*t) printf '%s' "$(( ${value%?} * 1024 * 1024 * 1024 * 1024 ))" ;;
    ''|*[!0-9]*) die "invalid bytes value: $value" ;;
    *) printf '%s' "$value" ;;
  esac
}

human_bytes() {
  awk -v bytes="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ");
    value = bytes; idx = 1;
    while (value >= 1024 && idx < 5) { value /= 1024; idx++ }
    printf "%.2f %s", value, unit[idx];
  }'
}

human_bps() {
  awk -v bps="${1:-0}" 'BEGIN {
    split("B/s KiB/s MiB/s GiB/s", unit, " ");
    value = bps; idx = 1;
    while (value >= 1024 && idx < 4) { value /= 1024; idx++ }
    printf "%.2f %s", value, unit[idx];
  }'
}

score_for() {
  awk -v bps="${1:-0}" -v theoretical="${THEORETICAL_BPS:-1250000000}" -v errors="${2:-0}" 'BEGIN {
    pct = theoretical > 0 ? (bps / theoretical) * 100 : 0;
    if (pct >= 90) s = 10; else if (pct >= 80) s = 9; else if (pct >= 70) s = 8;
    else if (pct >= 60) s = 7; else if (pct >= 50) s = 6; else if (pct >= 40) s = 5;
    else if (pct >= 30) s = 4; else if (pct >= 20) s = 3; else if (pct > 0) s = 2; else s = 1;
    s -= errors * 2; if (s < 1) s = 1; if (s > 10) s = 10; print s;
  }'
}

remote_quote() {
  printf '%q' "$1"
}

unit_safe() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-'
}

ssh_exec() {
  local host="$1"
  shift
  ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=8 "$host" "$@"
}

qm_exec() {
  local command="$1"
  ssh_exec "$SOURCE_JUMP_HOST" "sudo -n qm guest exec $SOURCE_QMID -- bash -lc $(remote_quote "$command")"
}

qm_out() {
  jq -r '.["out-data"] // empty' 2>/dev/null || true
}

load_config() {
  load_key_values "$CONFIG_DIR/settings.cfg"
  REPORT_BASE="${REPORT_BASE:-/tmp/backbone-test-reports/backbone-test/method-suite}"
  NOTIFY_HELPER="${NOTIFY_HELPER:-/usr/local/bin/notify_ntfy.sh}"
  PASS_COUNT="${PASS_COUNT:-1}"
  RUN_SECONDS="$(duration_seconds "${RUN_DURATION:-0}")"
  TEST_DELAY_SECONDS="${TEST_DELAY_SECONDS:-5}"
  THEORETICAL_BPS="${THEORETICAL_BPS:-1250000000}"
  LOCK_FILE="${LOCK_FILE:-/tmp/backbone-method-suite.lock}"
  STOP_FILE="$REPORT_BASE/STOP_REQUESTED"
}

notify() {
  local title="$1" body="$2"
  if [[ "${BACKBONE_NOTIFY:-true}" == "false" ]]; then
    return 0
  fi
  if [[ -x "$NOTIFY_HELPER" ]]; then
    "$NOTIFY_HELPER" "$title" "$body" || true
  fi
}

read_targets() {
  TARGETS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind id title mode host target_ip base_port nc_flavor enabled <<< "$line"
    [[ "$kind" == "target" ]] || die "invalid target line: $line"
    [[ "${enabled:-false}" == "true" ]] || continue
    TARGETS+=("$id|$title|$mode|$host|$target_ip|$base_port|${nc_flavor:-auto}")
  done < "$CONFIG_DIR/targets.cfg"
}

read_tests() {
  TESTS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind id title engine target_csv streams payload duration enabled <<< "$line"
    [[ "$kind" == "test" ]] || die "invalid test line: $line"
    [[ "${enabled:-false}" == "true" ]] || continue
    TESTS+=("$id|$title|$engine|$target_csv|$streams|$(bytes_value "$payload")|$(duration_seconds "$duration")")
  done < "$CONFIG_DIR/tests.cfg"
}

target_by_id() {
  local wanted="$1" target
  for target in "${TARGETS[@]}"; do
    IFS='|' read -r id title mode host target_ip base_port nc_flavor <<< "$target"
    if [[ "$id" == "$wanted" ]]; then
      printf '%s' "$target"
      return 0
    fi
  done
  return 1
}

target_rx() {
  local mode="$1" host="$2"
  case "$mode" in
    local)
      local dev
      dev="$(ip route get "$SOURCE_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
      [[ -n "$dev" && -r "/sys/class/net/$dev/statistics/rx_bytes" ]] && cat "/sys/class/net/$dev/statistics/rx_bytes" || printf '0'
      ;;
    ssh)
      ssh_exec "$host" "dev=\$(ip route get $(remote_quote "$SOURCE_IP") | awk '{for(i=1;i<=NF;i++) if(\$i==\"dev\") {print \$(i+1); exit}}'); cat /sys/class/net/\$dev/statistics/rx_bytes" 2>/dev/null || printf '0'
      ;;
    *) printf '0' ;;
  esac
}

target_command_ok() {
  local mode="$1" host="$2" command="$3"
  case "$mode" in
    local) command -v "$command" >/dev/null ;;
    ssh) ssh_exec "$host" "command -v $(remote_quote "$command") >/dev/null" >/dev/null ;;
  esac
}

source_command_ok() {
  local command="$1"
  qm_exec "command -v $(remote_quote "$command") >/dev/null" | jq -e '.exitcode == 0' >/dev/null
}

start_target_unit() {
  local mode="$1" host="$2" unit="$3" command="$4"
  case "$mode" in
    local)
      sudo systemctl stop "$unit.service" 2>/dev/null || true
      sudo systemctl reset-failed "$unit.service" 2>/dev/null || true
      sudo systemd-run --unit="$unit" --property=WorkingDirectory=/tmp /usr/bin/bash -lc "$command" >/dev/null
      ;;
    ssh)
      ssh_exec "$host" "sudo -n systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true; sudo -n systemctl reset-failed $(remote_quote "$unit.service") 2>/dev/null || true; sudo -n systemd-run --unit=$(remote_quote "$unit") --property=WorkingDirectory=/tmp /usr/bin/bash -lc $(remote_quote "$command")" >/dev/null
      ;;
  esac
  ACTIVE_TARGET_UNITS+=("$mode|$host|$unit")
}

start_source_unit() {
  local unit="$1" command="$2"
  qm_exec "systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true; systemctl reset-failed $(remote_quote "$unit.service") 2>/dev/null || true; systemd-run --unit=$(remote_quote "$unit") --property=WorkingDirectory=/tmp /usr/bin/bash -lc $(remote_quote "$command")" >/dev/null
  ACTIVE_SOURCE_UNITS+=("$unit")
}

target_unit_state() {
  local mode="$1" host="$2" unit="$3"
  case "$mode" in
    local) systemctl is-active "$unit.service" 2>/dev/null || true ;;
    ssh) ssh_exec "$host" "sudo -n systemctl is-active $(remote_quote "$unit.service") 2>/dev/null || true" | tr -d '\r\n' ;;
  esac
}

source_unit_state() {
  local unit="$1"
  qm_exec "systemctl is-active $(remote_quote "$unit.service") 2>/dev/null || true" | qm_out | tr -d '\r\n'
}

stop_target_unit() {
  local mode="$1" host="$2" unit="$3"
  case "$mode" in
    local) sudo systemctl stop "$unit.service" 2>/dev/null || true ;;
    ssh) ssh_exec "$host" "sudo -n systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true" >/dev/null || true ;;
  esac
}

stop_source_unit() {
  local unit="$1"
  qm_exec "systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true" >/dev/null || true
}

cleanup_active_units() {
  local entry mode host unit
  for entry in "${ACTIVE_TARGET_UNITS[@]:-}"; do
    IFS='|' read -r mode host unit <<< "$entry"
    stop_target_unit "$mode" "$host" "$unit"
  done
  for unit in "${ACTIVE_SOURCE_UNITS[@]:-}"; do
    stop_source_unit "$unit"
  done
  ACTIVE_TARGET_UNITS=()
  ACTIVE_SOURCE_UNITS=()
}

cleanup_known_units() {
  sudo systemctl stop 'method-suite-*' 2>/dev/null || true
  local target id title mode host target_ip base_port nc_flavor
  read_targets 2>/dev/null || true
  for target in "${TARGETS[@]:-}"; do
    IFS='|' read -r id title mode host target_ip base_port nc_flavor <<< "$target"
    [[ "$mode" == "ssh" ]] && ssh_exec "$host" "sudo -n systemctl stop 'method-suite-*' 2>/dev/null || true" >/dev/null || true
  done
  qm_exec "systemctl stop 'method-suite-*' 2>/dev/null || true" >/dev/null || true
}

nc_listen_command() {
  local port="$1" flavor="$2"
  case "$flavor" in
    ncat) printf 'nc -l --recv-only %s > /dev/null' "$port" ;;
    busybox) printf 'nc -l -p %s > /dev/null' "$port" ;;
    *) printf 'nc -l -p %s > /dev/null' "$port" ;;
  esac
}

nc_send_command() {
  local engine="$1" target_ip="$2" port="$3" bytes="$4"
  local mib=$((bytes / 1024 / 1024))
  if [[ "$engine" == "mbuffer-nc-zero" ]]; then
    printf 'dd if=/dev/zero bs=1M count=%s status=none | mbuffer -q -m 1G | nc -N -s %q %q %q' "$mib" "$SOURCE_IP" "$target_ip" "$port"
  else
    printf 'dd if=/dev/zero bs=1M count=%s status=none | nc -N -s %q %q %q' "$mib" "$SOURCE_IP" "$target_ip" "$port"
  fi
}

wait_source_units() {
  local max_wait="$1" waited=0 unit state all_done
  while (( waited < max_wait )); do
    all_done=1
    for unit in "${ACTIVE_SOURCE_UNITS[@]:-}"; do
      state="$(source_unit_state "$unit")"
      [[ "$state" == "active" || "$state" == "activating" ]] && all_done=0
    done
    (( all_done == 1 )) && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

write_metric_rows() {
  local run_dir="$1" pass="$2" test_id="$3" title="$4" engine="$5" streams="$6" bytes="$7" elapsed="$8" errors="$9"
  shift 9
  local row before after rx_delta bps score id target_title mode host target_ip base_port nc_flavor
  for row in "$@"; do
    IFS='|' read -r id target_title mode host target_ip base_port nc_flavor before after <<< "$row"
    rx_delta=$((after - before))
    (( rx_delta < 0 )) && rx_delta=0
    (( elapsed <= 0 )) && elapsed=1
    bps=$((rx_delta / elapsed))
    score="$(score_for "$bps" "$errors")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date --iso-8601=seconds)" "$pass" "$test_id" "$title" "$engine" "$id" "$target_title" "$streams" "$bytes" "$rx_delta" "$elapsed" "$bps" "$score" "$errors" "$(human_bps "$bps")" >> "$run_dir/results.tsv"
  done
}

pass_summary() {
  local run_dir="$1" pass="$2"
  awk -F'\t' -v pass="$pass" '
    NR > 1 && $2 == pass {
      count++;
      if ($14 > 0) errors += $14;
      bps += $12;
      if ($12 > best_bps) {
        best_bps = $12;
        best = $4 " -> " $7 " (" $15 ")";
      }
      if ($12 > 0 && ($12 < worst_bps || worst_bps == 0)) {
        worst_bps = $12;
        worst = $4 " -> " $7 " (" $15 ")";
      }
    }
    END {
      if (count == 0) {
        print "No completed result rows yet.";
      } else {
        printf "Rows: %d\nAggregate observed: %.2f MiB/s\nBest: %s\nSlowest nonzero: %s\nErrors: %d", count, bps / 1048576, best, worst, errors;
      }
    }
  ' "$run_dir/results.tsv"
}

write_skipped_rows() {
  local run_dir="$1" pass="$2" test_id="$3" title="$4" engine="$5" target_csv="$6" streams="$7" bytes="$8" reason="$9"
  local target_id target id target_title mode host target_ip base_port nc_flavor
  for target_id in ${target_csv//,/ }; do
    target="$(target_by_id "$target_id")" || continue
    IFS='|' read -r id target_title mode host target_ip base_port nc_flavor <<< "$target"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\t0\t0\t1\t1\tSKIPPED:%s\n' \
      "$(date --iso-8601=seconds)" "$pass" "$test_id" "$title" "$engine" "$id" "$target_title" "$streams" "$bytes" "$reason" >> "$run_dir/results.tsv"
  done
  printf '[%s] pass=%s test=%s skipped reason=%q\n' "$(date --iso-8601=seconds)" "$pass" "$test_id" "$reason" >> "$run_dir/run.log"
}

test_available() {
  local engine="$1" target_csv="$2" target target_id id target_title mode host target_ip base_port nc_flavor
  case "$engine" in
    iperf3)
      source_command_ok iperf3 || {
        printf 'source missing iperf3'
        return 1
      }
      for target_id in ${target_csv//,/ }; do
        target="$(target_by_id "$target_id")" || {
          printf 'unknown target %s' "$target_id"
          return 1
        }
        IFS='|' read -r id target_title mode host target_ip base_port nc_flavor <<< "$target"
        target_command_ok "$mode" "$host" iperf3 || {
          printf 'target %s missing iperf3' "$id"
          return 1
        }
      done
      ;;
    nc-zero)
      source_command_ok nc || {
        printf 'source missing nc'
        return 1
      }
      ;;
    mbuffer-nc-zero)
      source_command_ok nc || {
        printf 'source missing nc'
        return 1
      }
      source_command_ok mbuffer || {
        printf 'source missing mbuffer'
        return 1
      }
      ;;
    *)
      printf 'unknown engine %s' "$engine"
      return 1
      ;;
  esac
  return 0
}

run_network_test() {
  local run_dir="$1" pass="$2" test_id="$3" title="$4" engine="$5" target_csv="$6" streams="$7" bytes="$8" seconds="$9"
  local target_ids target_id target id target_title mode host target_ip base_port nc_flavor stream port unit command start elapsed max_wait errors=0
  local before_rows=() after_rows=() metric_rows=()
  local unavailable_reason
  if ! unavailable_reason="$(test_available "$engine" "$target_csv")"; then
    write_skipped_rows "$run_dir" "$pass" "$test_id" "$title" "$engine" "$target_csv" "$streams" "$bytes" "$unavailable_reason"
    return 0
  fi
  IFS=',' read -r -a target_ids <<< "$target_csv"
  printf '[%s] pass=%s test=%s title=%q engine=%s targets=%s streams=%s bytes=%s seconds=%s start\n' "$(date --iso-8601=seconds)" "$pass" "$test_id" "$title" "$engine" "$target_csv" "$streams" "$bytes" "$seconds" >> "$run_dir/run.log"
  ACTIVE_TARGET_UNITS=()
  ACTIVE_SOURCE_UNITS=()
  for target_id in "${target_ids[@]}"; do
    target="$(target_by_id "$target_id")" || die "unknown target $target_id"
    IFS='|' read -r id target_title mode host target_ip base_port nc_flavor <<< "$target"
    before_rows+=("$(target_rx "$mode" "$host")")
    case "$engine" in
      iperf3)
        for ((stream=0; stream<streams; stream++)); do
          port=$((base_port + stream))
          unit="method-suite-$(unit_safe "$pass-$test_id-$id-iperf-$stream")"
          start_target_unit "$mode" "$host" "$unit" "iperf3 -s -1 -p $port >/tmp/$unit.log 2>&1"
        done
        ;;
      nc-zero|mbuffer-nc-zero)
        for ((stream=0; stream<streams; stream++)); do
          port=$((base_port + stream))
          unit="method-suite-$(unit_safe "$pass-$test_id-$id-recv-$stream")"
          start_target_unit "$mode" "$host" "$unit" "$(nc_listen_command "$port" "$nc_flavor")"
        done
        ;;
      *) die "unknown engine $engine" ;;
    esac
  done
  sleep 2
  start="$(date +%s)"
  for target_id in "${target_ids[@]}"; do
    target="$(target_by_id "$target_id")" || die "unknown target $target_id"
    IFS='|' read -r id target_title mode host target_ip base_port nc_flavor <<< "$target"
    case "$engine" in
      iperf3)
        for ((stream=0; stream<streams; stream++)); do
          port=$((base_port + stream))
          unit="method-suite-$(unit_safe "$pass-$test_id-$id-send-$stream")"
          start_source_unit "$unit" "iperf3 -c $(remote_quote "$target_ip") -p $port -t $seconds -O 2 >/tmp/$unit.log 2>&1"
        done
        ;;
      nc-zero|mbuffer-nc-zero)
        for ((stream=0; stream<streams; stream++)); do
          port=$((base_port + stream))
          unit="method-suite-$(unit_safe "$pass-$test_id-$id-send-$stream")"
          command="$(nc_send_command "$engine" "$target_ip" "$port" "$((bytes / streams))")"
          start_source_unit "$unit" "$command"
        done
        ;;
    esac
  done
  if [[ "$engine" == "iperf3" ]]; then
    max_wait=$((seconds + 45))
  else
    max_wait=$((bytes / 125000000 + 300))
  fi
  if ! wait_source_units "$max_wait"; then
    errors=1
    printf '[%s] pass=%s test=%s timeout max_wait=%s\n' "$(date --iso-8601=seconds)" "$pass" "$test_id" "$max_wait" >> "$run_dir/run.log"
  fi
  elapsed=$(( $(date +%s) - start ))
  (( elapsed <= 0 )) && elapsed=1
  local idx=0 before
  for target_id in "${target_ids[@]}"; do
    target="$(target_by_id "$target_id")" || die "unknown target $target_id"
    IFS='|' read -r id target_title mode host target_ip base_port nc_flavor <<< "$target"
    before="${before_rows[$idx]##*|}"
    after_rows+=("$id|$target_title|$mode|$host|$target_ip|$base_port|$nc_flavor|$before|$(target_rx "$mode" "$host")")
    idx=$((idx + 1))
  done
  write_metric_rows "$run_dir" "$pass" "$test_id" "$title" "$engine" "$streams" "$bytes" "$elapsed" "$errors" "${after_rows[@]}"
  cleanup_active_units
  printf '[%s] pass=%s test=%s elapsed=%ss errors=%s complete\n' "$(date --iso-8601=seconds)" "$pass" "$test_id" "$elapsed" "$errors" >> "$run_dir/run.log"
}

validate() {
  read_targets
  read_tests
  command -v jq >/dev/null || die "jq is required"
  source_command_ok bash || die "source guest exec is not ready"
  source_command_ok nc || die "source nc is missing"
  local target id target_title mode host target_ip base_port nc_flavor test test_id title engine target_csv streams bytes seconds failures=0 warnings=0 reason
  for target in "${TARGETS[@]}"; do
    IFS='|' read -r id target_title mode host target_ip base_port nc_flavor <<< "$target"
    if target_command_ok "$mode" "$host" nc; then
      printf 'TARGET OK: %s %s %s:%s\n' "$id" "$mode" "$target_ip" "$base_port"
    else
      printf 'TARGET FAIL: %s missing nc\n' "$id"
      failures=$((failures + 1))
    fi
  done
  for test in "${TESTS[@]}"; do
    IFS='|' read -r test_id title engine target_csv streams bytes seconds <<< "$test"
    case "$engine" in
      iperf3)
        if source_command_ok iperf3; then
          for target_id in ${target_csv//,/ }; do
            target="$(target_by_id "$target_id")" || die "unknown target $target_id"
            IFS='|' read -r id target_title mode host target_ip base_port nc_flavor <<< "$target"
            target_command_ok "$mode" "$host" iperf3 || { printf 'TEST WARN: %s target %s missing iperf3; will skip at runtime\n' "$test_id" "$id"; warnings=$((warnings + 1)); }
          done
        else
          printf 'TEST WARN: %s source missing iperf3; will skip at runtime\n' "$test_id"
          warnings=$((warnings + 1))
        fi
        ;;
      mbuffer-nc-zero)
        source_command_ok mbuffer || { printf 'TEST WARN: %s source missing mbuffer; will skip at runtime\n' "$test_id"; warnings=$((warnings + 1)); }
        ;;
      nc-zero) ;;
      *) printf 'TEST FAIL: %s unknown engine %s\n' "$test_id" "$engine"; failures=$((failures + 1)) ;;
    esac
  done
  (( failures == 0 )) || die "validation found $failures issue(s)"
  printf 'validation ok: targets=%s tests=%s passes=%s warnings=%s\n' "${#TARGETS[@]}" "${#TESTS[@]}" "$PASS_COUNT" "$warnings"
}

run_suite() {
  validate
  mkdir -p "$REPORT_BASE"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another method suite appears to be active; lock=$LOCK_FILE"
  rm -f "$STOP_FILE"
  local run_dir="$REPORT_BASE/$STAMP-${TEST_NAME:-method-suite}" pass test test_id title engine target_csv streams bytes seconds started deadline now status
  CURRENT_RUN_DIR="$run_dir"
  mkdir -p "$run_dir"
  started="$(date +%s)"
  if (( RUN_SECONDS > 0 )); then
    deadline=$((started + RUN_SECONDS))
  else
    deadline=0
  fi
  printf 'started=%s\nconfig_dir=%s\npasses=%s\nrun_seconds=%s\n' "$(date --iso-8601=seconds)" "$CONFIG_DIR" "$PASS_COUNT" "$RUN_SECONDS" > "$run_dir/summary.env"
  printf 'timestamp\tpass\ttest_id\ttitle\tengine\ttarget_id\ttarget_title\tstreams\trequested_bytes\treceiver_rx_bytes\telapsed_s\treceiver_rx_Bps\tscore\terrors\thuman_Bps\n' > "$run_dir/results.tsv"
  : > "$run_dir/run.log"
  trap cleanup_active_units EXIT
  notify "Method suite started" "Run: $run_dir. Passes: $PASS_COUNT. Runtime limit: ${RUN_SECONDS}s. Tests per pass: ${#TESTS[@]}."
  pass=1
  while (( PASS_COUNT == 0 || pass <= PASS_COUNT )); do
    now="$(date +%s)"
    (( deadline > 0 && now >= deadline )) && break
    printf '[%s] pass=%s start\n' "$(date --iso-8601=seconds)" "$pass" >> "$run_dir/run.log"
    for test in "${TESTS[@]}"; do
      [[ ! -e "$STOP_FILE" ]] || break 2
      now="$(date +%s)"
      (( deadline > 0 && now >= deadline )) && break 2
      IFS='|' read -r test_id title engine target_csv streams bytes seconds <<< "$test"
      run_network_test "$run_dir" "$pass" "$test_id" "$title" "$engine" "$target_csv" "$streams" "$bytes" "$seconds"
      sleep "$TEST_DELAY_SECONDS"
    done
    printf '[%s] pass=%s complete\n' "$(date --iso-8601=seconds)" "$pass" >> "$run_dir/run.log"
    notify "Method suite pass $pass complete" "$(pass_summary "$run_dir" "$pass")"$'\n'"Run: $run_dir"
    pass=$((pass + 1))
  done
  if [[ -e "$STOP_FILE" ]]; then
    status="stopped"
  else
    status="completed"
  fi
  printf 'completed=%s\nstatus=%s\nrun_dir=%s\n' "$(date --iso-8601=seconds)" "$status" "$run_dir" >> "$run_dir/summary.env"
  notify "Method suite $status" "Final report: $run_dir"
  printf '%s\n' "$run_dir"
}

stop_suite() {
  mkdir -p "$REPORT_BASE"
  touch "$STOP_FILE"
  cleanup_known_units
  notify "Method suite stop requested" "Stop marker written at $STOP_FILE."
  printf 'stop marker written: %s\n' "$STOP_FILE"
}

load_config
case "$MODE" in
  validate) validate ;;
  run) run_suite ;;
  stop) stop_suite ;;
  list)
    read_targets
    read_tests
    printf 'Configured tests:\n'
    for test in "${TESTS[@]}"; do
      IFS='|' read -r test_id title engine target_csv streams bytes seconds <<< "$test"
      printf '%s\t%s\t%s\ttargets=%s\tstreams=%s\tpayload=%s\tduration=%ss\n' "$test_id" "$title" "$engine" "$target_csv" "$streams" "$(human_bytes "$bytes")" "$seconds"
    done
    ;;
  help|-h|--help)
    printf 'usage: %s <validate|list|run|stop>\n' "$0"
    ;;
  *) die "unknown mode: $MODE" ;;
esac
