#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-validate}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BACKBONE_CONFIG_DIR:-$SCRIPT_DIR/configs/source-blast-hour}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ACTIVE_RECEIVERS=()
ACTIVE_SENDERS=()
CURRENT_RUN_DIR=""
RUN_STATUS="starting"

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

pct_value() {
  awk -v got="${1:-0}" -v want="${2:-0}" 'BEGIN {
    if (want <= 0) printf "0.0"; else printf "%.1f", (got / want) * 100;
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
  local jump="$1" vmid="$2" command="$3"
  ssh_exec "$jump" "sudo -n qm guest exec $vmid -- bash -lc $(remote_quote "$command")"
}

qm_out() {
  jq -r '.["out-data"] // empty' 2>/dev/null || true
}

load_config() {
  load_key_values "$CONFIG_DIR/settings.cfg"
  REPORT_BASE="${REPORT_BASE:-/tmp/backbone-test-reports/backbone-test/source-blast}"
  NOTIFY_HELPER="${NOTIFY_HELPER:-/usr/local/bin/notify_ntfy.sh}"
  RUN_SECONDS="$(duration_seconds "${RUN_DURATION:-1h}")"
  CHUNK_BYTES="$(bytes_value "${CHUNK_BYTES:-1T}")"
  CHUNK_MIB=$((CHUNK_BYTES / 1024 / 1024))
  PORT_BASE="${PORT_BASE:-53100}"
  PROGRESS_SECONDS="${PROGRESS_SECONDS:-60}"
  NTFY_PROGRESS_INTERVAL_SECONDS="${NTFY_PROGRESS_INTERVAL_SECONDS:-600}"
  NOTIFY_PROFILE="${NOTIFY_PROFILE:-default}"
  NOTIFY_SCHEDULE_FILE="${NOTIFY_SCHEDULE_FILE:-$CONFIG_DIR/notifications.cfg}"
  ESTIMATED_TARGET_BPS="${ESTIMATED_TARGET_BPS:-750000000}"
  PARTIAL_THROUGHPUT_FACTOR="${PARTIAL_THROUGHPUT_FACTOR:-0.70}"
  STEP_MAX_GRACE_SECONDS="${STEP_MAX_GRACE_SECONDS:-120}"
  ENFORCE_RUN_DURATION="${ENFORCE_RUN_DURATION:-true}"
  LOCK_FILE="${LOCK_FILE:-/tmp/backbone-source-blast.lock}"
  STOP_FILE="$REPORT_BASE/STOP_REQUESTED"
}

append_summary_once() {
  local key="$1" value="$2"
  [[ -n "$CURRENT_RUN_DIR" && -d "$CURRENT_RUN_DIR" ]] || return 0
  grep -q "^${key}=" "$CURRENT_RUN_DIR/summary.env" 2>/dev/null && return 0
  printf '%s=%s\n' "$key" "$value" >> "$CURRENT_RUN_DIR/summary.env"
}

mark_run_status() {
  local status="$1" detail="${2:-}"
  [[ -n "$CURRENT_RUN_DIR" && -d "$CURRENT_RUN_DIR" ]] || return 0
  append_summary_once "finished" "$(date --iso-8601=seconds)"
  append_summary_once "status" "$status"
  if [[ -n "$detail" ]]; then
    append_summary_once "detail" "$detail"
  fi
  append_summary_once "run_dir" "$CURRENT_RUN_DIR"
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
    IFS='|' read -r kind id mode host target_ip port nc_flavor enabled <<< "$line"
    [[ "$kind" == "target" ]] || die "invalid target line: $line"
    [[ "${enabled:-false}" == "true" ]] || continue
    TARGETS+=("$id|$mode|$host|$target_ip|${port:-}|${nc_flavor:-auto}")
  done < "$CONFIG_DIR/targets.cfg"
}

target_by_id() {
  local wanted="$1" target
  for target in "${TARGETS[@]}"; do
    IFS='|' read -r id mode host target_ip port nc_flavor <<< "$target"
    if [[ "$id" == "$wanted" ]]; then
      printf '%s' "$target"
      return 0
    fi
  done
  return 1
}

read_sequence() {
  STEPS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind name target_list bytes <<< "$line"
    [[ "$kind" == "step" ]] || die "invalid sequence line: $line"
    STEPS+=("$name|$target_list|$(bytes_value "${bytes:-$CHUNK_BYTES}")")
  done < "$CONFIG_DIR/sequence.cfg"
}

read_notification_schedule() {
  NOTIFY_WINDOWS=()
  if [[ ! -r "$NOTIFY_SCHEDULE_FILE" ]]; then
    NOTIFY_WINDOWS+=("default|0|100|$NTFY_PROGRESS_INTERVAL_SECONDS")
    return
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind profile start_pct end_pct interval <<< "$line"
    [[ "$kind" == "window" ]] || die "invalid notification schedule line: $line"
    [[ "$profile" == "$NOTIFY_PROFILE" ]] || continue
    NOTIFY_WINDOWS+=("$profile|$start_pct|$end_pct|$(duration_seconds "$interval")")
  done < "$NOTIFY_SCHEDULE_FILE"
  if ((${#NOTIFY_WINDOWS[@]} == 0)); then
    die "notification profile $NOTIFY_PROFILE not found in $NOTIFY_SCHEDULE_FILE"
  fi
}

notify_interval_for_elapsed() {
  local elapsed="$1" run_seconds="$2" window profile start_pct end_pct interval start_s end_s
  for window in "${NOTIFY_WINDOWS[@]}"; do
    IFS='|' read -r profile start_pct end_pct interval <<< "$window"
    start_s="$(awk -v pct="$start_pct" -v total="$run_seconds" 'BEGIN { printf "%d", (pct / 100) * total }')"
    end_s="$(awk -v pct="$end_pct" -v total="$run_seconds" 'BEGIN { printf "%d", (pct / 100) * total }')"
    if (( elapsed >= start_s && elapsed < end_s )); then
      printf '%s' "$interval"
      return 0
    fi
  done
  printf '%s' "$NTFY_PROGRESS_INTERVAL_SECONDS"
}

local_route_dev() {
  ip route get "$1" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

local_rx() {
  local dev="$1"
  [[ -n "$dev" && -r "/sys/class/net/$dev/statistics/rx_bytes" ]] || {
    printf '0'
    return
  }
  cat "/sys/class/net/$dev/statistics/rx_bytes"
}

remote_rx() {
  local mode="$1" host="$2" target_ip="$3"
  case "$mode" in
    local)
      local_rx "$(local_route_dev "$SOURCE_IP")"
      ;;
    ssh)
      ssh_exec "$host" "dev=\$(ip route get $(remote_quote "$SOURCE_IP") | awk '{for(i=1;i<=NF;i++) if(\$i==\"dev\") {print \$(i+1); exit}}'); cat /sys/class/net/\$dev/statistics/rx_bytes" 2>/dev/null || printf '0'
      ;;
    *)
      printf '0'
      ;;
  esac
}

receiver_state() {
  local mode="$1" host="$2" unit="$3"
  case "$mode" in
    local)
      systemctl is-active "$unit.service" 2>/dev/null || true
      ;;
    ssh)
      ssh_exec "$host" "sudo -n systemctl is-active $(remote_quote "$unit.service") 2>/dev/null || true" | tr -d '\r\n'
      ;;
  esac
}

validate_target() {
  local id="$1" mode="$2" host="$3" target_ip="$4" port="$5" nc_flavor="$6"
  case "$mode" in
    local)
      command -v nc >/dev/null || return 1
      ip route get "$SOURCE_IP" >/dev/null 2>&1 || return 1
      ;;
    ssh)
      ssh_exec "$host" "command -v nc >/dev/null && command -v systemd-run >/dev/null && sudo -n true && ip route get $(remote_quote "$SOURCE_IP") >/dev/null" >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

validate_source() {
  command -v jq >/dev/null || die "jq is required for qm guest exec parsing"
  qm_exec "$SOURCE_JUMP_HOST" "$SOURCE_QMID" "command -v bash >/dev/null && command -v dd >/dev/null && command -v nc >/dev/null && command -v systemd-run >/dev/null && ip route get $(remote_quote "$SOURCE_ROUTE_PROBE") >/dev/null" >/dev/null
}

validate() {
  read_targets
  read_sequence
  read_notification_schedule
  validate_source || die "source source-node is not ready through $SOURCE_JUMP_HOST VMID $SOURCE_QMID"
  local failures=0 target id mode host target_ip port nc_flavor
  for target in "${TARGETS[@]}"; do
    IFS='|' read -r id mode host target_ip port nc_flavor <<< "$target"
    if validate_target "$id" "$mode" "$host" "$target_ip" "$port" "$nc_flavor"; then
      printf 'TARGET OK: %s mode=%s host=%s target_ip=%s port=%s\n' "$id" "$mode" "$host" "$target_ip" "$port"
    else
      printf 'TARGET FAIL: %s mode=%s host=%s target_ip=%s port=%s\n' "$id" "$mode" "$host" "$target_ip" "$port"
      failures=$((failures + 1))
    fi
  done
  (( failures == 0 )) || die "validation found $failures target issue(s)"
  printf 'validation ok: source=source-node targets=%s steps=%s duration=%ss chunk=%s\n' "${#TARGETS[@]}" "${#STEPS[@]}" "$RUN_SECONDS" "$(human_bytes "$CHUNK_BYTES")"
}

receiver_command() {
  local port="$1" flavor="$2" bytes="$3"
  case "$flavor" in
    ncat) printf 'nc -l --recv-only %s > /dev/null' "$port" ;;
    busybox) printf 'nc -l -p %s > /dev/null' "$port" ;;
    *) printf 'nc -l -p %s > /dev/null' "$port" ;;
  esac
}

start_receiver() {
  local id="$1" mode="$2" host="$3" target_ip="$4" port="$5" flavor="$6" run_id="$7" bytes="$8"
  local unit command
  unit="backbone-recv-$(unit_safe "$run_id-$id")"
  command="$(receiver_command "$port" "$flavor" "$bytes")"
  case "$mode" in
    local)
      sudo systemd-run --unit="$unit" --property=WorkingDirectory=/tmp /usr/bin/bash -lc "$command" >/dev/null
      ;;
    ssh)
      ssh_exec "$host" "sudo -n systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true; sudo -n systemctl reset-failed $(remote_quote "$unit.service") 2>/dev/null || true; sudo -n systemd-run --unit=$(remote_quote "$unit") --property=WorkingDirectory=/tmp /usr/bin/bash -lc $(remote_quote "$command")" >/dev/null
      ;;
  esac
  printf '%s' "$unit"
}

wait_receiver_done() {
  local mode="$1" host="$2" unit="$3" max_wait="${4:-$RECEIVER_WAIT_SECONDS}" waited=0
  while (( waited < max_wait )); do
    case "$mode" in
      local)
        state="$(systemctl is-active "$unit.service" 2>/dev/null || true)"
        ;;
      ssh)
        state="$(ssh_exec "$host" "sudo -n systemctl is-active $(remote_quote "$unit.service") 2>/dev/null || true" | tr -d '\r\n')"
        ;;
    esac
    [[ "$state" != "active" && "$state" != "activating" ]] && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

stop_receiver() {
  local mode="$1" host="$2" unit="$3"
  case "$mode" in
    local) sudo systemctl stop "$unit.service" 2>/dev/null || true ;;
    ssh) ssh_exec "$host" "sudo -n systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true" >/dev/null || true ;;
  esac
}

stop_sender() {
  local unit="$1"
  qm_exec "$SOURCE_JUMP_HOST" "$SOURCE_QMID" "systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true" >/dev/null || true
}

cleanup_active_units() {
  local entry mode host unit sender
  for entry in "${ACTIVE_RECEIVERS[@]:-}"; do
    IFS='|' read -r mode host unit <<< "$entry"
    stop_receiver "$mode" "$host" "$unit"
  done
  for sender in "${ACTIVE_SENDERS[@]:-}"; do
    stop_sender "$sender"
  done
}

cleanup_known_units() {
  sudo systemctl stop 'backbone-recv-*' 2>/dev/null || true
  read_targets 2>/dev/null || true
  local target id mode host target_ip port flavor
  for target in "${TARGETS[@]:-}"; do
    IFS='|' read -r id mode host target_ip port flavor <<< "$target"
    if [[ "$mode" == "ssh" ]]; then
      ssh_exec "$host" "sudo -n systemctl stop 'backbone-recv-*' 2>/dev/null || true" >/dev/null || true
    fi
  done
  qm_exec "$SOURCE_JUMP_HOST" "$SOURCE_QMID" "systemctl stop 'backbone-send-*' 2>/dev/null || true" >/dev/null || true
}

on_error() {
  local rc="$?" line="${BASH_LINENO[0]:-unknown}" command="${BASH_COMMAND:-unknown}"
  RUN_STATUS="failed"
  if [[ -n "$CURRENT_RUN_DIR" && -d "$CURRENT_RUN_DIR" ]]; then
    printf '[%s] run-error rc=%s line=%s command=%q\n' "$(date --iso-8601=seconds)" "$rc" "$line" "$command" >> "$CURRENT_RUN_DIR/run.log"
  fi
  mark_run_status "failed" "rc_${rc}_line_${line}"
  notify "Source blast failed" "Run failed with rc=$rc at line $line. Report: $CURRENT_RUN_DIR"
  cleanup_active_units
  exit "$rc"
}

on_exit() {
  local rc="$?"
  if [[ "$RUN_STATUS" != "completed" && "$RUN_STATUS" != "failed" && "$RUN_STATUS" != "interrupted" ]]; then
    if (( rc == 0 )); then
      mark_run_status "completed"
    else
      mark_run_status "failed" "rc_${rc}"
    fi
  fi
  cleanup_active_units
}

on_signal() {
  RUN_STATUS="interrupted"
  mark_run_status "interrupted" "signal"
  if [[ -n "$CURRENT_RUN_DIR" && -d "$CURRENT_RUN_DIR" ]]; then
    printf '[%s] run-interrupted signal\n' "$(date --iso-8601=seconds)" >> "$CURRENT_RUN_DIR/run.log"
  fi
  cleanup_active_units
  exit 130
}

start_sender() {
  local id="$1" target_ip="$2" port="$3" bytes="$4" run_id="$5"
  local unit count_mib command
  unit="backbone-send-$(unit_safe "$run_id-$id")"
  count_mib=$((bytes / 1024 / 1024))
  command="dd if=/dev/zero bs=1M count=$count_mib status=none | nc -N -s $(remote_quote "$SOURCE_IP") $(remote_quote "$target_ip") $(remote_quote "$port")"
  qm_exec "$SOURCE_JUMP_HOST" "$SOURCE_QMID" "systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true; systemctl reset-failed $(remote_quote "$unit.service") 2>/dev/null || true; systemd-run --unit=$(remote_quote "$unit") --property=WorkingDirectory=/tmp /usr/bin/bash -lc $(remote_quote "$command")" >/dev/null
  printf '%s' "$unit"
}

wait_sender_done() {
  local unit="$1" waited=0 max_wait="$2" state result
  while (( waited < max_wait )); do
    state="$(qm_exec "$SOURCE_JUMP_HOST" "$SOURCE_QMID" "systemctl is-active $(remote_quote "$unit.service") 2>/dev/null || true" | qm_out | tr -d '\r\n')"
    case "$state" in
      active|activating)
        sleep 5
        waited=$((waited + 5))
        ;;
      *)
        result="$(qm_exec "$SOURCE_JUMP_HOST" "$SOURCE_QMID" "systemctl show $(remote_quote "$unit.service") -p Result -p ExecMainStatus --no-pager 2>/dev/null || true" | qm_out)"
        printf '%s\n' "$result" | grep -q 'Result=success'
        return
        ;;
    esac
  done
  return 1
}

run_step() {
  local run_dir="$1" iteration="$2" step_name="$3" target_csv="$4" bytes="$5" deadline="${6:-0}" run_started="${7:-0}"
  local step_id target_id target id mode host target_ip port flavor unit sender before after start elapsed run_elapsed rx_delta bps max_wait last_progress all_done state now remaining eta interval_now
  local last_notify=0
  step_id="$iteration-$step_name"
  start="$(date +%s)"
  printf '[%s] step-start iteration=%s step=%s targets=%s bytes_each=%s\n' "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$target_csv" "$bytes" >> "$run_dir/run.log"
  IFS=',' read -r -a target_ids <<< "$target_csv"
  RECEIVER_UNITS=()
  SENDER_UNITS=()
  BEFORE_RX=()
  TARGET_ROWS=()
  ACTIVE_RECEIVERS=()
  ACTIVE_SENDERS=()
  for target_id in "${target_ids[@]}"; do
    target="$(target_by_id "$target_id")" || die "unknown target $target_id"
    IFS='|' read -r id mode host target_ip port flavor <<< "$target"
    before="$(remote_rx "$mode" "$host" "$target_ip")"
    unit="$(start_receiver "$id" "$mode" "$host" "$target_ip" "$port" "$flavor" "$step_id" "$bytes")"
    RECEIVER_UNITS+=("$mode|$host|$unit")
    ACTIVE_RECEIVERS+=("$mode|$host|$unit")
    BEFORE_RX+=("$before")
    TARGET_ROWS+=("$target")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$id" "$target_ip" "$unit" "$before" >> "$run_dir/baselines.tsv"
    sleep 1
  done
  for target in "${TARGET_ROWS[@]}"; do
    IFS='|' read -r id mode host target_ip port flavor <<< "$target"
    sender="$(start_sender "$id" "$target_ip" "$port" "$bytes" "$step_id")"
    SENDER_UNITS+=("$sender")
    ACTIVE_SENDERS+=("$sender")
  done
  max_wait=$((bytes / 125000000 + 300))
  if (( deadline > 0 )); then
    remaining=$((deadline - start + STEP_MAX_GRACE_SECONDS))
    (( remaining > 0 && remaining < max_wait )) && max_wait="$remaining"
  fi
  last_progress=0
  while :; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( run_started > 0 )); then
      run_elapsed=$((now - run_started))
    else
      run_elapsed="$elapsed"
    fi
    all_done=1
    for receiver in "${RECEIVER_UNITS[@]}"; do
      IFS='|' read -r mode host unit <<< "$receiver"
      state="$(receiver_state "$mode" "$host" "$unit")"
      if [[ "$state" == "active" || "$state" == "activating" ]]; then
        all_done=0
      fi
    done
    if (( elapsed - last_progress >= PROGRESS_SECONDS || all_done == 1 )); then
      local idx=0 progress_rx progress_bps target_pct
      for target in "${TARGET_ROWS[@]}"; do
        IFS='|' read -r id mode host target_ip port flavor <<< "$target"
        after="$(remote_rx "$mode" "$host" "$target_ip")"
        before="${BEFORE_RX[$idx]}"
        progress_rx=$((after - before))
        (( progress_rx < 0 )) && progress_rx=0
        (( elapsed <= 0 )) && elapsed=1
        progress_bps=$((progress_rx / elapsed))
        target_pct="$(awk -v got="$progress_rx" -v want="$bytes" 'BEGIN { if (want <= 0) printf "0.0"; else printf "%.1f", (got / want) * 100 }')"
        eta=0
        if (( progress_bps > 0 && progress_rx < bytes )); then
          eta=$(((bytes - progress_rx) / progress_bps))
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$id" "$target_ip" "$bytes" "$progress_rx" "$elapsed" "$progress_bps" "$target_pct" "$eta" >> "$run_dir/progress.tsv"
        interval_now="$(notify_interval_for_elapsed "$run_elapsed" "$RUN_SECONDS")"
        if (( elapsed - last_notify >= interval_now || all_done == 1 )); then
          notify "Source blast ${step_name}: ${target_pct}% to ${id}" \
            "Target ${id} (${target_ip}) has received $(human_bytes "$progress_rx") of $(human_bytes "$bytes") at $(human_bps "$progress_bps"). Step elapsed ${elapsed}s, run elapsed ${run_elapsed}s, ETA ${eta}s. Run: $run_dir"
          last_notify="$elapsed"
        fi
        idx=$((idx + 1))
      done
      printf '[%s] step-progress iteration=%s step=%s elapsed=%ss\n' "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$elapsed" >> "$run_dir/run.log"
      last_progress="$elapsed"
    fi
    (( all_done == 1 )) && break
    if (( elapsed >= max_wait )); then
      printf '[%s] step-timeout iteration=%s step=%s elapsed=%ss max_wait=%ss\n' "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$elapsed" "$max_wait" >> "$run_dir/run.log"
      cleanup_active_units
      die "step $step_name did not complete within ${max_wait}s"
    fi
    [[ ! -e "$STOP_FILE" ]] || {
      cleanup_active_units
      die "stop requested during step $step_name"
    }
    sleep 5
  done
  sleep 2
  for sender in "${SENDER_UNITS[@]}"; do
    stop_sender "$sender"
  done
  ACTIVE_SENDERS=()
  ACTIVE_RECEIVERS=()
  elapsed=$(( $(date +%s) - start ))
  (( elapsed <= 0 )) && elapsed=1
  idx=0
  for target in "${TARGET_ROWS[@]}"; do
    IFS='|' read -r id mode host target_ip port flavor <<< "$target"
    after="$(remote_rx "$mode" "$host" "$target_ip")"
    before="${BEFORE_RX[$idx]}"
    rx_delta=$((after - before))
    (( rx_delta < 0 )) && rx_delta=0
    bps=$((rx_delta / elapsed))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$id" "$target_ip" "$bytes" "$rx_delta" "$elapsed" "$bps" "0" >> "$run_dir/metrics.tsv"
    idx=$((idx + 1))
  done
  printf '[%s] step-complete iteration=%s step=%s elapsed=%ss\n' "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$elapsed" >> "$run_dir/run.log"
}

run_test() {
  validate
  mkdir -p "$REPORT_BASE"
  exec 9>"$LOCK_FILE"
  if command -v flock >/dev/null; then
    flock -n 9 || die "another source-blast run appears to be active; lock=$LOCK_FILE"
  fi
  rm -f "$STOP_FILE"
  local run_dir="$REPORT_BASE/$STAMP-${TEST_NAME:-source-blast}"
  CURRENT_RUN_DIR="$run_dir"
  mkdir -p "$run_dir"
  printf 'timestamp\titeration\tstep\ttarget\ttarget_ip\trequested_bytes\treceiver_rx_bytes\telapsed_s\treceiver_rx_Bps\terrors\n' > "$run_dir/metrics.tsv"
  printf 'timestamp\titeration\tstep\ttarget\ttarget_ip\tunit\tbaseline_rx_bytes\n' > "$run_dir/baselines.tsv"
  printf 'timestamp\titeration\tstep\ttarget\ttarget_ip\trequested_bytes\treceiver_rx_bytes\telapsed_s\treceiver_rx_Bps\tpercent\teta_s\n' > "$run_dir/progress.tsv"
  printf 'started=%s\nconfig_dir=%s\n' "$(date --iso-8601=seconds)" "$CONFIG_DIR" > "$run_dir/summary.env"
  RUN_STATUS="running"
  trap on_signal INT TERM
  trap on_error ERR
  trap on_exit EXIT
  notify "Source blast started" "Run directory: $run_dir. Pattern repeats for $RUN_SECONDS seconds; each target blast requests $(human_bytes "$CHUNK_BYTES")."
  local started deadline now iteration step step_name targets bytes remaining step_bytes estimated_seconds
  started="$(date +%s)"
  deadline=$((started + RUN_SECONDS))
  iteration=1
  while :; do
    [[ ! -e "$STOP_FILE" ]] || break
    now="$(date +%s)"
    (( now - started >= RUN_SECONDS )) && break
    for step in "${STEPS[@]}"; do
      [[ ! -e "$STOP_FILE" ]] || break
      now="$(date +%s)"
      (( now - started >= RUN_SECONDS )) && break
      IFS='|' read -r step_name targets bytes <<< "$step"
      step_bytes="$bytes"
      if [[ "$ENFORCE_RUN_DURATION" == "true" ]]; then
        remaining=$((deadline - now))
        (( remaining <= 0 )) && break
        estimated_seconds=$((bytes / ESTIMATED_TARGET_BPS))
        if (( estimated_seconds > remaining )); then
          step_bytes="$(awk -v seconds="$remaining" -v bps="$ESTIMATED_TARGET_BPS" -v factor="$PARTIAL_THROUGHPUT_FACTOR" 'BEGIN { printf "%d", seconds * bps * factor }')"
          step_bytes=$((step_bytes / 1048576 * 1048576))
          (( step_bytes <= 0 )) && break
          printf '[%s] partial-step iteration=%s step=%s requested_bytes=%s adjusted_bytes=%s remaining_s=%s estimated_target_Bps=%s factor=%s\n' \
            "$(date --iso-8601=seconds)" "$iteration" "$step_name" "$bytes" "$step_bytes" "$remaining" "$ESTIMATED_TARGET_BPS" "$PARTIAL_THROUGHPUT_FACTOR" >> "$run_dir/run.log"
        fi
      fi
      run_step "$run_dir" "$iteration" "$step_name" "$targets" "$step_bytes" "$deadline" "$started"
    done
    iteration=$((iteration + 1))
  done
  RUN_STATUS="completed"
  printf 'completed=%s\nstatus=completed\nrun_dir=%s\n' "$(date --iso-8601=seconds)" "$run_dir" >> "$run_dir/summary.env"
  notify "Source blast complete" "Final report: $run_dir"
  printf '%s\n' "$run_dir"
}

stop_test() {
  mkdir -p "$REPORT_BASE"
  touch "$STOP_FILE"
  cleanup_known_units
  notify "Source blast stop requested" "Stop marker written at $STOP_FILE."
  printf 'stop marker written: %s\n' "$STOP_FILE"
}

load_config
case "$MODE" in
  validate) validate ;;
  run) run_test ;;
  stop) stop_test ;;
  help|-h|--help)
    printf 'usage: %s <validate|run|stop>\n' "$0"
    ;;
  *) die "unknown mode: $MODE" ;;
esac
