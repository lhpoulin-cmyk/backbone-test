#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-run}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${BACKBONE_CONFIG_DIR:-$SCRIPT_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REMOTE_ROOT="${BACKBONE_REMOTE_ROOT:-/tmp/backbone-test}"
GLOBAL_STOP_FILE="$REMOTE_ROOT/STOP_REQUESTED"

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
    local key="${line%%=*}"
    local value="${line#*=}"
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

size_bytes() {
  local value="$1"
  case "$value" in
    *K|*k) printf '%s' "$(( ${value%?} * 1024 ))" ;;
    *M|*m) printf '%s' "$(( ${value%?} * 1024 * 1024 ))" ;;
    *G|*g) printf '%s' "$(( ${value%?} * 1024 * 1024 * 1024 ))" ;;
    ''|*[!0-9]*) die "invalid byte size: $value" ;;
    *) printf '%s' "$value" ;;
  esac
}

score_for() {
  awk -v bps="${1:-0}" -v theoretical="${THEORETICAL_BPS:-1250000000}" -v errors="${2:-0}" 'BEGIN {
    pct = theoretical > 0 ? (bps / theoretical) * 100 : 0;
    if (pct >= 80) s = 10; else if (pct >= 65) s = 9; else if (pct >= 50) s = 8;
    else if (pct >= 35) s = 7; else if (pct >= 25) s = 6; else if (pct >= 15) s = 5;
    else if (pct >= 8) s = 4; else if (pct >= 3) s = 3; else if (pct > 0) s = 2; else s = 1;
    s -= errors * 2; if (s < 1) s = 1; if (s > 10) s = 10; print s;
  }'
}

notify() {
  local title="$1" body="$2"
  if [[ "${BACKBONE_NOTIFY:-true}" == "false" ]]; then
    return 0
  fi
  if [[ -x "${NOTIFY_HELPER:-}" ]]; then
    "$NOTIFY_HELPER" "$title" "$body" || true
  fi
}

load_config() {
  load_key_values "$CONFIG_DIR/settings.cfg"
  load_key_values "$CONFIG_DIR/paths.cfg"
  REPORT_BASE="${REPORT_BASE:-/tmp/backbone-test-reports/backbone-test}"
  REPORT_INTERVAL_SECONDS="${REPORT_INTERVAL_SECONDS:-600}"
  THEORETICAL_BPS="${THEORETICAL_BPS:-1250000000}"
  STOP_FILE="$REPORT_BASE/STOP_REQUESTED"
}

read_sources() {
  SOURCES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind id type server_ip export label read_only <<< "$line"
    [[ "$kind" == "source" ]] || die "invalid source line: $line"
    SOURCES+=("$id|$type|$server_ip|$export|$label|$read_only")
  done < "$CONFIG_DIR/sources.cfg"
}

read_workers() {
  WORKERS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind id mode host path expected_ip weight enabled route_target transport_arg <<< "$line"
    [[ "$kind" == "worker" ]] || die "invalid worker line: $line"
    [[ "${enabled:-false}" == "true" ]] || continue
    WORKERS+=("$id|$mode|$host|$path|$expected_ip|${weight:-1}|$route_target|${transport_arg:-}")
  done < "$CONFIG_DIR/workers.cfg"
}

read_profiles() {
  PROFILES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind name engine rw bs small_pct medium_pct large_pct small_mb medium_min medium_max large_min large_max sample_seconds <<< "$line"
    [[ "$kind" == "profile" ]] || die "invalid profile line: $line"
    PROFILES+=("$name|$engine|$rw|$bs|$small_pct|$medium_pct|$large_pct|$small_mb|$medium_min|$medium_max|$large_min|$large_max|$sample_seconds")
  done < "$CONFIG_DIR/behavior.cfg"
}

read_schedule() {
  PHASES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    IFS='|' read -r kind name duration workers profile intensity <<< "$line"
    [[ "$kind" == "phase" ]] || die "invalid phase line: $line"
    PHASES+=("$name|$(duration_seconds "$duration")|$workers|$profile|$intensity")
  done < "$CONFIG_DIR/schedule.cfg"
}

profile_field() {
  local wanted="$1" index="$2" p
  for p in "${PROFILES[@]}"; do
    IFS='|' read -r name engine rw bs small_pct medium_pct large_pct small_mb medium_min medium_max large_min large_max sample_seconds <<< "$p"
    if [[ "$name" == "$wanted" ]]; then
      case "$index" in
        engine) printf '%s' "$engine" ;;
        rw) printf '%s' "$rw" ;;
        bs) printf '%s' "$bs" ;;
        small_pct) printf '%s' "$small_pct" ;;
        medium_pct) printf '%s' "$medium_pct" ;;
        large_pct) printf '%s' "$large_pct" ;;
        small_mb) printf '%s' "$small_mb" ;;
        medium_min) printf '%s' "$medium_min" ;;
        medium_max) printf '%s' "$medium_max" ;;
        large_min) printf '%s' "$large_min" ;;
        large_max) printf '%s' "$large_max" ;;
        sample_seconds) printf '%s' "$sample_seconds" ;;
      esac
      return 0
    fi
  done
  return 1
}

local_route_dev() {
  ip route get "$1" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

local_route_src() {
  ip route get "$1" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

remote_quote() {
  printf '%q' "$1"
}

rx_counter() {
  local dev="$1"
  [[ -n "$dev" && -r "/sys/class/net/$dev/statistics/rx_bytes" ]] || {
    printf '0'
    return
  }
  cat "/sys/class/net/$dev/statistics/rx_bytes"
}

readable_sample_count() {
  local path="$1"
  find "$path" -type f -readable -print -quit 2>/dev/null | wc -l
}

build_manifest() {
  local worker_id="$1" path="$2" manifest="$3"
  : > "$manifest"
  local tier dir label
  for tier in small medium large; do
    case "$tier" in
      small) dir="${SMALL_DIR:-small}" ;;
      medium) dir="${MEDIUM_DIR:-medium}" ;;
      large) dir="${LARGE_DIR:-large}" ;;
    esac
    if [[ -d "$path/$dir" ]]; then
      { find "$path/$dir" -type f -readable -printf "$tier\t%s\t%p\n" 2>/dev/null | head -n 64 >> "$manifest"; } || true
    fi
  done
  if [[ ! -s "$manifest" ]]; then
    { find "$path" -type f -readable -printf '%s\t%p\n' 2>/dev/null | awk '
      $1 < 10485760 {tier="small"}
      $1 >= 10485760 && $1 < 4294967296 {tier="medium"}
      $1 >= 4294967296 {tier="large"}
      {print tier "\t" $1 "\t" substr($0, index($0,$2))}
    ' | head -n 256 >> "$manifest"; } || true
  fi
  [[ -s "$manifest" ]] || die "worker $worker_id has no readable sample files under $path"
}

pick_sample() {
  local manifest="$1" tier="$2"
  awk -F'\t' -v tier="$tier" '$1 == tier {print $3}' "$manifest" | shuf -n 1
}

workers_for_phase() {
  local spec="$1" elapsed="$2" duration="$3"
  if [[ "$spec" != ramp:* ]]; then
    printf '%s' "$spec"
    return
  fi
  local csv="${spec#ramp:}"
  local count index
  count="$(awk -F, '{print NF}' <<< "$csv")"
  index=$(( elapsed * count / duration + 1 ))
  (( index < 1 )) && index=1
  (( index > count )) && index="$count"
  awk -F, -v i="$index" '{print $i}' <<< "$csv"
}

run_local_phase() {
  local worker_id="$1" path="$2" phase="$3" duration="$4" worker_spec="$5" profile="$6" run_dir="$7" route_target="$8"
  local manifest="$run_dir/$worker_id.$phase.manifest.tsv"
  local metrics="$run_dir/$worker_id.$phase.metrics.tsv"
  local bs bs_bytes sample_seconds small_pct medium_pct small_mb medium_min medium_max large_min large_max
  bs="$(profile_field "$profile" bs)"
  bs_bytes="$(size_bytes "$bs")"
  sample_seconds="$(profile_field "$profile" sample_seconds)"
  small_pct="$(profile_field "$profile" small_pct)"
  medium_pct="$(profile_field "$profile" medium_pct)"
  small_mb="$(profile_field "$profile" small_mb)"
  medium_min="$(profile_field "$profile" medium_min)"
  medium_max="$(profile_field "$profile" medium_max)"
  large_min="$(profile_field "$profile" large_min)"
  large_max="$(profile_field "$profile" large_max)"
  build_manifest "$worker_id" "$path" "$manifest"
  printf 'timestamp\tworker\tphase\telapsed_s\tworkload_bytes\tops\terrors\tactive_workers\twire_rx_bytes\n' > "$metrics"

  local route_dev start baseline_rx bytes ops errors now elapsed active pids counts roll tier mb file pid idx rc rx
  route_dev="$(local_route_dev "$route_target" || true)"
  baseline_rx="$(rx_counter "$route_dev")"
  start="$(date +%s)"
  bytes=0
  ops=0
  errors=0
  while :; do
    [[ ! -e "$STOP_FILE" && ! -e "$GLOBAL_STOP_FILE" ]] || break
    now="$(date +%s)"
    elapsed=$((now - start))
    (( elapsed >= duration )) && break
    active="$(workers_for_phase "$worker_spec" "$elapsed" "$duration")"
    pids=()
    counts=()
    for _ in $(seq 1 "$active"); do
      roll=$((RANDOM % 100))
      if (( roll < small_pct )); then
        tier=small; mb="$small_mb"
      elif (( roll < small_pct + medium_pct )); then
        tier=medium; mb=$((medium_min + RANDOM % (medium_max - medium_min + 1)))
      else
        tier=large; mb=$((large_min + RANDOM % (large_max - large_min + 1)))
      fi
      file="$(pick_sample "$manifest" "$tier")"
      if [[ -r "$file" ]]; then
        dd if="$file" of=/dev/null bs="$bs" count="$mb" iflag=fullblock status=none &
        pids+=("$!")
        counts+=("$mb")
      else
        errors=$((errors + 1))
      fi
    done
    idx=0
    for pid in "${pids[@]}"; do
      if wait "$pid"; then
        bytes=$((bytes + counts[idx] * bs_bytes))
        ops=$((ops + 1))
      else
        errors=$((errors + 1))
      fi
      idx=$((idx + 1))
    done
    rx="$(rx_counter "$route_dev")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date --iso-8601=seconds)" "$worker_id" "$phase" "$elapsed" "$bytes" "$ops" "$errors" "$active" "$((rx - baseline_rx))" >> "$metrics"
    sleep "$sample_seconds"
  done
}

write_worker_config() {
  local out_dir="$1" remote_report_base="$2" worker_id="$3" worker_mode="$4" host="$5" path="$6" expected_ip="$7" route_target="$8" phase="$9" duration="${10}" worker_spec="${11}" profile="${12}"
  mkdir -p "$out_dir"
  cp "$CONFIG_DIR/paths.cfg" "$CONFIG_DIR/behavior.cfg" "$out_dir/"
  {
    printf 'TEST_NAME=%s-%s-%s\n' "${TEST_NAME:-backbone-test}" "$worker_id" "$phase"
    printf 'ENGINE=%s\n' "${ENGINE:-pattern-dd}"
    printf 'REPORT_INTERVAL_SECONDS=%s\n' "$REPORT_INTERVAL_SECONDS"
    printf 'THEORETICAL_BPS=%s\n' "$THEORETICAL_BPS"
    printf 'REPORT_BASE=%s\n' "$remote_report_base"
    printf 'NOTIFY_HELPER=/no/such/helper\n'
    printf 'ALLOW_DESTRUCTIVE_WRITES=false\n'
    printf 'ALLOW_MOUNT_CHANGES=false\n'
    printf 'FAIL_ON_WRONG_ROUTE=false\n'
    printf 'REQUIRE_EXPECTED_SUBNET=false\n'
    printf 'EXPECTED_DATA_SUBNET_PREFIX=%s\n' "${EXPECTED_DATA_SUBNET_PREFIX:-}"
  } > "$out_dir/settings.cfg"
  printf 'source|worker-source|posix|%s|worker-local|worker-local|true\n' "$route_target" > "$out_dir/sources.cfg"
  printf 'worker|%s|local|localhost|%s|%s|1|true|%s|\n' "$worker_id" "$path" "$expected_ip" "$route_target" > "$out_dir/workers.cfg"
  printf 'phase|%s|%ss|%s|%s|remote\n' "$phase" "$duration" "$worker_spec" "$profile" > "$out_dir/schedule.cfg"
}

remote_ssh() {
  local host="$1"
  shift
  ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=8 "$host" "$@"
}

remote_qm_exec() {
  local jump_host="$1" vmid="$2" command="$3"
  remote_ssh "$jump_host" "sudo -n qm guest exec $vmid -- bash -lc $(remote_quote "$command")"
}

qm_json_out() {
  jq -r '.["out-data"] // empty' 2>/dev/null || true
}

unit_safe() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-'
}

push_remote_ssh_worker() {
  local host="$1" local_dir="$2" remote_dir="$3"
  remote_ssh "$host" "rm -rf $(remote_quote "$remote_dir") && mkdir -p $(remote_quote "$remote_dir")"
  tar -C "$local_dir" -cf - . | ssh -F /dev/null -o BatchMode=yes "$host" "tar -C $(remote_quote "$remote_dir") -xf -"
  ssh -F /dev/null -o BatchMode=yes "$host" "install -m 755 $(remote_quote "$SCRIPT_DIR/runbook.sh") $(remote_quote "$remote_dir/runbook.sh")" 2>/dev/null || \
    tar -C "$SCRIPT_DIR" -cf - runbook.sh | ssh -F /dev/null -o BatchMode=yes "$host" "tar -C $(remote_quote "$remote_dir") -xf - && chmod 755 $(remote_quote "$remote_dir/runbook.sh")"
}

pull_remote_ssh_worker() {
  local host="$1" remote_dir="$2" dest_dir="$3"
  mkdir -p "$dest_dir"
  ssh -F /dev/null -o BatchMode=yes "$host" "tar -C $(remote_quote "$remote_dir/reports") -cf - ." | tar -C "$dest_dir" -xf -
}

push_remote_qm_worker() {
  local jump_host="$1" vmid="$2" local_dir="$3" remote_dir="$4"
  local archive
  archive="$(tar -C "$local_dir" -czf - . | base64 -w0)"
  local script_archive
  script_archive="$(tar -C "$SCRIPT_DIR" -czf - runbook.sh | base64 -w0)"
  remote_qm_exec "$jump_host" "$vmid" "rm -rf $(remote_quote "$remote_dir"); mkdir -p $(remote_quote "$remote_dir"); printf %s $(remote_quote "$archive") | base64 -d | tar -C $(remote_quote "$remote_dir") -xzf -; printf %s $(remote_quote "$script_archive") | base64 -d | tar -C $(remote_quote "$remote_dir") -xzf -; chmod 755 $(remote_quote "$remote_dir/runbook.sh")" >/dev/null
}

pull_remote_qm_worker() {
  local jump_host="$1" vmid="$2" remote_dir="$3" dest_dir="$4"
  mkdir -p "$dest_dir"
  remote_qm_exec "$jump_host" "$vmid" "test -d $(remote_quote "$remote_dir/reports") && tar -C $(remote_quote "$remote_dir/reports") -czf - . | base64 -w0" | qm_json_out | base64 -d 2>/dev/null | tar -C "$dest_dir" -xzf - 2>/dev/null || true
}

run_remote_qm_worker() {
  local jump_host="$1" vmid="$2" remote_dir="$3" worker_id="$4" phase="$5" duration="$6"
  local unit active result waited max_wait
  unit="backbone-test-$(unit_safe "$STAMP-$worker_id-$phase")"
  remote_qm_exec "$jump_host" "$vmid" "systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true; systemctl reset-failed $(remote_quote "$unit.service") 2>/dev/null || true; systemd-run --unit=$(remote_quote "$unit") --property=WorkingDirectory=$(remote_quote "$remote_dir") /usr/bin/env BACKBONE_CONFIG_DIR=$(remote_quote "$remote_dir") BACKBONE_NOTIFY=false /usr/bin/bash $(remote_quote "$remote_dir/runbook.sh") run" >/dev/null
  waited=0
  max_wait=$((duration + 120))
  while (( waited < max_wait )); do
    active="$(remote_qm_exec "$jump_host" "$vmid" "systemctl is-active $(remote_quote "$unit.service") || true" | qm_json_out | tr -d '\r\n')"
    case "$active" in
      active|activating)
        sleep 5
        waited=$((waited + 5))
        ;;
      *)
        result="$(remote_qm_exec "$jump_host" "$vmid" "systemctl show $(remote_quote "$unit.service") -p Result -p ExecMainStatus --no-pager 2>/dev/null || true" | qm_json_out)"
        if printf '%s\n' "$result" | grep -q 'Result=success'; then
          return 0
        fi
        printf 'remote unit %s ended with state=%s result=%s\n' "$unit" "${active:-unknown}" "$result" >&2
        return 1
        ;;
    esac
  done
  remote_qm_exec "$jump_host" "$vmid" "systemctl stop $(remote_quote "$unit.service") 2>/dev/null || true" >/dev/null || true
  printf 'remote unit %s timed out after %ss\n' "$unit" "$max_wait" >&2
  return 1
}

run_remote_phase() {
  local worker_id="$1" mode="$2" host="$3" path="$4" expected_ip="$5" route_target="$6" transport_arg="$7" phase="$8" duration="$9" worker_spec="${10}" profile="${11}" run_dir="${12}"
  local stage_dir="$run_dir/remote-stage/$worker_id-$phase"
  local remote_dir="$REMOTE_ROOT/$STAMP/$worker_id-$phase"
  local pulled_dir="$run_dir/remote-pulled/$worker_id-$phase"
  write_worker_config "$stage_dir" "$remote_dir/reports" "$worker_id" "$mode" "$host" "$path" "$expected_ip" "$route_target" "$phase" "$duration" "$worker_spec" "$profile"
  printf '[%s] remote-worker-start worker=%s mode=%s host=%s phase=%s remote_dir=%s\n' "$(date --iso-8601=seconds)" "$worker_id" "$mode" "$host" "$phase" "$remote_dir" >> "$run_dir/run.log"
  case "$mode" in
    ssh)
      push_remote_ssh_worker "$host" "$stage_dir" "$remote_dir"
      remote_ssh "$host" "BACKBONE_CONFIG_DIR=$(remote_quote "$remote_dir") BACKBONE_NOTIFY=false bash $(remote_quote "$remote_dir/runbook.sh") run" >/dev/null
      pull_remote_ssh_worker "$host" "$remote_dir" "$pulled_dir"
      ;;
    ssh-qm)
      [[ -n "$transport_arg" ]] || die "worker $worker_id is ssh-qm but has no VMID transport_arg"
      push_remote_qm_worker "$host" "$transport_arg" "$stage_dir" "$remote_dir"
      run_remote_qm_worker "$host" "$transport_arg" "$remote_dir" "$worker_id" "$phase" "$duration"
      pull_remote_qm_worker "$host" "$transport_arg" "$remote_dir" "$pulled_dir"
      ;;
    *)
      die "unsupported remote mode $mode for $worker_id"
      ;;
  esac
  find "$pulled_dir" -type f -name '*.metrics.tsv' -exec cp {} "$run_dir/" ';'
  printf '[%s] remote-worker-complete worker=%s mode=%s phase=%s\n' "$(date --iso-8601=seconds)" "$worker_id" "$mode" "$phase" >> "$run_dir/run.log"
}

validate() {
  local failures=0 worker id mode host path expected_ip weight route_target transport_arg src
  read_sources; read_workers; read_profiles; read_schedule
  ((${#SOURCES[@]} > 0)) || die "no sources configured"
  ((${#WORKERS[@]} > 0)) || die "no enabled workers configured"
  ((${#PROFILES[@]} > 0)) || die "no profiles configured"
  ((${#PHASES[@]} > 0)) || die "no phases configured"
  if printf '%s\n' "${WORKERS[@]}" | awk -F'|' '$2 == "ssh-qm" {found=1} END {exit found ? 0 : 1}'; then
    command -v jq >/dev/null || {
      printf 'ERROR: ssh-qm workers require jq on the controller\n'
      failures=$((failures + 1))
    }
  fi
  for worker in "${WORKERS[@]}"; do
    IFS='|' read -r id mode host path expected_ip weight route_target transport_arg <<< "$worker"
    case "$mode" in
      local)
        [[ -d "$path" ]] || { printf 'WARN: local worker %s path missing: %s\n' "$id" "$path"; failures=$((failures + 1)); }
        src="$(local_route_src "$route_target" || true)"
        if [[ "${FAIL_ON_WRONG_ROUTE:-true}" == "true" && -n "$expected_ip" && -n "$src" && "$src" != "$expected_ip" ]]; then
          printf 'WARN: local worker %s route source %s != expected %s\n' "$id" "$src" "$expected_ip"
          failures=$((failures + 1))
        fi
        ;;
      ssh)
        printf 'INFO: remote worker %s configured via ssh host=%s path=%s\n' "$id" "$host" "$path"
        remote_ssh "$host" 'command -v bash >/dev/null && command -v dd >/dev/null && command -v tar >/dev/null' || {
          printf 'WARN: remote worker %s is unreachable or missing bash/dd/tar\n' "$id"
          failures=$((failures + 1))
        }
        ;;
      ssh-qm)
        printf 'INFO: remote worker %s configured via ssh-qm host=%s vmid=%s path=%s\n' "$id" "$host" "$transport_arg" "$path"
        [[ -n "$transport_arg" ]] || {
          printf 'ERROR: ssh-qm worker %s missing transport_arg VMID\n' "$id"
          failures=$((failures + 1))
          continue
        }
        remote_qm_exec "$host" "$transport_arg" 'command -v bash >/dev/null && command -v dd >/dev/null && command -v tar >/dev/null && command -v base64 >/dev/null' >/dev/null || {
          printf 'WARN: ssh-qm worker %s is unreachable or missing bash/dd/tar/base64\n' "$id"
          failures=$((failures + 1))
        }
        ;;
      *)
        printf 'ERROR: unknown worker mode %s for %s\n' "$mode" "$id"
        failures=$((failures + 1))
        ;;
    esac
  done
  (( failures == 0 )) || die "validation found $failures issue(s)"
  printf 'validation ok: %s source(s), %s worker(s), %s phase(s)\n' "${#SOURCES[@]}" "${#WORKERS[@]}" "${#PHASES[@]}"
}

validate_local_path() {
  local id="$1" path="$2" expected_ip="$3" route_target="$4"
  local failures=0 src mount_line source_opts sample_count
  [[ -d "$path" ]] || {
    printf 'ERROR: %s path missing: %s\n' "$id" "$path"
    return 1
  }
  sample_count="$(readable_sample_count "$path")"
  if [[ "$sample_count" == "0" ]]; then
    printf 'ERROR: %s has no readable files under %s\n' "$id" "$path"
    failures=$((failures + 1))
  fi
  src="$(local_route_src "$route_target" || true)"
  if [[ -n "$expected_ip" && "$src" != "$expected_ip" ]]; then
    printf 'ERROR: %s route source to %s is %s, expected %s\n' "$id" "$route_target" "${src:-unknown}" "$expected_ip"
    failures=$((failures + 1))
  fi
  mount_line="$(findmnt -T "$path" -o SOURCE,FSTYPE,OPTIONS --noheadings 2>/dev/null || true)"
  if [[ -z "$mount_line" ]]; then
    printf 'ERROR: %s has no mount covering %s\n' "$id" "$path"
    failures=$((failures + 1))
  elif [[ "$mount_line" != *"$route_target"* ]]; then
    printf 'ERROR: %s mount for %s does not reference %s: %s\n' "$id" "$path" "$route_target" "$mount_line"
    failures=$((failures + 1))
  fi
  if [[ "${REQUIRE_EXPECTED_SUBNET:-false}" == "true" && -n "${EXPECTED_DATA_SUBNET_PREFIX:-}" && "$route_target" != "$EXPECTED_DATA_SUBNET_PREFIX"* ]]; then
    printf 'ERROR: %s route target %s is outside expected prefix %s\n' "$id" "$route_target" "$EXPECTED_DATA_SUBNET_PREFIX"
    failures=$((failures + 1))
  fi
  if (( failures == 0 )); then
    printf 'PATH OK: %s path=%s route_src=%s target=%s readable=yes mount="%s"\n' "$id" "$path" "$src" "$route_target" "$mount_line"
  fi
  return "$failures"
}

validate_remote_path() {
  local id="$1" mode="$2" host="$3" path="$4" expected_ip="$5" route_target="$6" transport_arg="$7"
  local command output rc failures=0
  command="
    set -u
    path=$(remote_quote "$path")
    target=$(remote_quote "$route_target")
    expected=$(remote_quote "$expected_ip")
    failures=0
    if [ ! -d \"\$path\" ]; then echo \"ERROR: path missing: \$path\"; failures=\$((failures+1)); fi
    sample=\$(find \"\$path\" -type f -readable -print -quit 2>/dev/null | wc -l)
    if [ \"\$sample\" = 0 ]; then echo \"ERROR: no readable files under \$path\"; failures=\$((failures+1)); fi
    src=\$(ip route get \"\$target\" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i==\"src\") {print \$(i+1); exit}}')
    if [ -n \"\$expected\" ] && [ \"\$src\" != \"\$expected\" ]; then echo \"ERROR: route source to \$target is \${src:-unknown}, expected \$expected\"; failures=\$((failures+1)); fi
    mount_line=\$(findmnt -T \"\$path\" -o SOURCE,FSTYPE,OPTIONS --noheadings 2>/dev/null || true)
    if [ -z \"\$mount_line\" ]; then echo \"ERROR: no mount covering \$path\"; failures=\$((failures+1)); elif ! printf '%s' \"\$mount_line\" | grep -q \"\$target\"; then echo \"ERROR: mount for \$path does not reference \$target: \$mount_line\"; failures=\$((failures+1)); fi
    if [ \"\$failures\" -eq 0 ]; then echo \"PATH OK: $id path=\$path route_src=\$src target=\$target readable=yes mount=\$mount_line\"; fi
    exit \"\$failures\"
  "
  case "$mode" in
    ssh)
      output="$(remote_ssh "$host" "$command" 2>&1)" || rc=$?
      ;;
    ssh-qm)
      output="$(remote_qm_exec "$host" "$transport_arg" "$command" | qm_json_out)"
      rc="$(remote_qm_exec "$host" "$transport_arg" "true" >/dev/null 2>&1; printf '%s' "$?")"
      ;;
  esac
  printf '%s\n' "$output"
  if printf '%s\n' "$output" | grep -q '^ERROR:'; then
    return 1
  fi
  return 0
}

validate_paths() {
  local failures=0 worker id mode host path expected_ip weight route_target transport_arg
  validate
  for worker in "${WORKERS[@]}"; do
    IFS='|' read -r id mode host path expected_ip weight route_target transport_arg <<< "$worker"
    case "$mode" in
      local)
        validate_local_path "$id" "$path" "$expected_ip" "$route_target" || failures=$((failures + 1))
        ;;
      ssh|ssh-qm)
        validate_remote_path "$id" "$mode" "$host" "$path" "$expected_ip" "$route_target" "$transport_arg" || failures=$((failures + 1))
        ;;
    esac
  done
  (( failures == 0 )) || die "path validation found $failures issue(s)"
  printf 'path validation ok: %s worker(s)\n' "${#WORKERS[@]}"
}

summarize_phase() {
  local run_dir="$1" phase="$2" start="$3"
  local elapsed workload wire errors bps score quirks
  elapsed=$(( $(date +%s) - start ))
  (( elapsed <= 0 )) && elapsed=1
  workload="$(awk -F'\t' -v phase="$phase" 'NR>1 && $3 == phase {sum[$2]=$5} END {for (w in sum) total += sum[w]; print total + 0}' "$run_dir"/*.metrics.tsv 2>/dev/null || printf '0')"
  wire="$(awk -F'\t' -v phase="$phase" 'NR>1 && $3 == phase {sum[$2]=$9} END {for (w in sum) total += sum[w]; print total + 0}' "$run_dir"/*.metrics.tsv 2>/dev/null || printf '0')"
  errors="$(awk -F'\t' -v phase="$phase" 'NR>1 && $3 == phase {sum[$2]=$7} END {for (w in sum) total += sum[w]; print total + 0}' "$run_dir"/*.metrics.tsv 2>/dev/null || printf '0')"
  bps=$((wire / elapsed))
  score="$(score_for "$bps" "$errors")"
  quirks="none"
  (( errors > 0 )) && quirks="worker_errors=$errors"
  printf '[%s] phase=%s elapsed=%s workload=%s wire=%s wire_Bps=%s score=%s errors=%s quirks=%s\n' \
    "$(date --iso-8601=seconds)" "$phase" "$elapsed" "$workload" "$wire" "$bps" "$score" "$errors" "$quirks" >> "$run_dir/run.log"
  notify "Backbone test ${phase}: score ${score}/10" \
    "Workload $(human_bytes "$workload") read. Wireload $(human_bytes "$wire") at $(human_bps "$bps"). Errors ${errors}. Quirks ${quirks}. Report $run_dir."
}

run_test() {
  validate
  mkdir -p "$REPORT_BASE"
  rm -f "$STOP_FILE"
  rm -f "$GLOBAL_STOP_FILE" 2>/dev/null || true
  local run_dir="$REPORT_BASE/$STAMP-${TEST_NAME:-backbone-test}"
  mkdir -p "$run_dir"
  printf 'config_dir=%s\nstarted=%s\n' "$CONFIG_DIR" "$(date --iso-8601=seconds)" > "$run_dir/summary.env"
  notify "Backbone test started" "Run directory: $run_dir"

  local phase_line phase duration worker_spec profile intensity worker id mode host path expected_ip weight route_target transport_arg phase_start
  for phase_line in "${PHASES[@]}"; do
    IFS='|' read -r phase duration worker_spec profile intensity <<< "$phase_line"
    phase_start="$(date +%s)"
    printf '[%s] phase-start phase=%s duration=%s workers=%s profile=%s\n' "$(date --iso-8601=seconds)" "$phase" "$duration" "$worker_spec" "$profile" >> "$run_dir/run.log"
    for worker in "${WORKERS[@]}"; do
      IFS='|' read -r id mode host path expected_ip weight route_target transport_arg <<< "$worker"
      case "$mode" in
        local)
          run_local_phase "$id" "$path" "$phase" "$duration" "$worker_spec" "$profile" "$run_dir" "$route_target" &
          ;;
        ssh|ssh-qm)
          run_remote_phase "$id" "$mode" "$host" "$path" "$expected_ip" "$route_target" "$transport_arg" "$phase" "$duration" "$worker_spec" "$profile" "$run_dir" &
          ;;
        *)
          die "worker $id uses unsupported mode $mode"
          ;;
      esac
    done
    wait
    find "$run_dir" -maxdepth 1 -type f -name "*.$phase.metrics.tsv" -print -quit | grep -q . || die "phase $phase produced no metrics"
    summarize_phase "$run_dir" "$phase" "$phase_start"
    [[ ! -e "$STOP_FILE" ]] || break
  done
  printf 'completed=%s\nrun_dir=%s\n' "$(date --iso-8601=seconds)" "$run_dir" >> "$run_dir/summary.env"
  notify "Backbone test complete" "Final report: $run_dir"
  printf '%s\n' "$run_dir"
}

stop_test() {
  mkdir -p "$REPORT_BASE"
  touch "$STOP_FILE"
  read_workers || true
  local worker id mode host path expected_ip weight route_target transport_arg
  for worker in "${WORKERS[@]:-}"; do
    IFS='|' read -r id mode host path expected_ip weight route_target transport_arg <<< "$worker"
    case "$mode" in
      ssh)
        remote_ssh "$host" "mkdir -p $(remote_quote "$REMOTE_ROOT") && touch $(remote_quote "$GLOBAL_STOP_FILE")" || true
        ;;
      ssh-qm)
        [[ -n "$transport_arg" ]] && remote_qm_exec "$host" "$transport_arg" "mkdir -p $(remote_quote "$REMOTE_ROOT") && touch $(remote_quote "$GLOBAL_STOP_FILE")" >/dev/null || true
        ;;
    esac
  done
  notify "Backbone test stop requested" "Stop marker written at $STOP_FILE."
  printf 'stop marker written: %s\n' "$STOP_FILE"
}

load_config
case "$MODE" in
  validate) validate ;;
  validate-paths) validate_paths ;;
  dry-run) validate; printf 'dry-run ok: config_dir=%s\n' "$CONFIG_DIR" ;;
  run) run_test ;;
  stop) stop_test ;;
  help|-h|--help)
    printf 'usage: %s <validate|validate-paths|dry-run|run|stop>\n' "$0"
    ;;
  *) die "unknown mode: $MODE" ;;
esac
