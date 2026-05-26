# Backbone Test

Config-driven backbone and storage-path testing runbooks designed to be easy to
wrap with `agentctl`.

The project has two related engines:

- `runbook.sh`: reads mounted datasets with weighted small, medium, and large
  `dd` patterns, then reports workload bytes, local NIC wire bytes when
  available, quirks, errors, and a 1-10 quality score.
- `source-blast-runbook.sh`: pushes generated data from one source node to one
  or more receivers over TCP with `nc`, while receivers discard to `/dev/null`.

Configuration is plain text so scenarios can be copied, reviewed, and changed
without rebuilding anything.

## Configuration

- `settings.cfg`: global reporting, scoring, notification, and guardrail values
- `sources.cfg`: datasets or exports under test
- `workers.cfg`: participating machines and their local paths
- `paths.cfg`: tier directory hints for the pattern reader
- `schedule.cfg`: phase timing and behavior selection
- `behavior.cfg`: weighted read profile for small, medium, and large files
- `notifications.cfg`: optional notification cadence profiles
- `targets.cfg` and `sequence.cfg`: source-blast receivers and push order

Worker modes:

- `local`: run directly on the controller host
- `ssh`: stage the runbook and config over SSH, run remotely, and pull reports
  back
- `ssh-qm`: SSH to a Proxmox host and run inside a VM through `qm guest exec`

`ssh-qm` worker lines use the final `transport_arg` field as the VMID. Remote
runs use `/tmp/backbone-test` by default for staged files and a shared stop
marker.

## Usage

Validate and run the default local config:

```bash
./runbook.sh validate
./runbook.sh validate-paths
./runbook.sh run
./runbook.sh stop
```

Use a specific config directory:

```bash
BACKBONE_CONFIG_DIR=configs/media-10gbe-observe ./runbook.sh validate-paths
BACKBONE_CONFIG_DIR=configs/media-10gbe-observe ./runbook.sh run
```

Run with `agentctl`:

```bash
agentctl runbook ./runbook.sh validate
agentctl runbook ./runbook.sh run
agentctl runbook ./runbook.sh stop
```

Smoke test the local pattern engine:

```bash
./test-smoke.sh
```

## Included Examples

- `configs/media-10gbe-observe`: short observe gate for real mounted paths
- `configs/media-10gbe`: observe, redline, then workday-style sustained read
- `configs/source-blast-smoke`: tiny source-push sanity check
- `configs/source-blast-hour`: one-hour source-push profile

The source-blast hour profile repeats until the configured wall clock expires:

1. source -> receiver-a, 1 TiB
2. source -> receiver-b, 1 TiB
3. source -> both receivers concurrently, 1 TiB each

The source-blast controller writes `baselines.tsv`, `progress.tsv`, and a final
summary, uses a lock file to avoid overlapping runs, cleans up transient sender
and receiver units on stop/failure, and shortens the final step when
`ENFORCE_RUN_DURATION=true`.

## Notifications

Notifications use `NOTIFY_HELPER`, defaulting to
`/usr/local/bin/notify_ntfy.sh`. Set `BACKBONE_NOTIFY=false` to suppress sends.

Notification cadence is configured in `notifications.cfg`. The default profile
is every 10 minutes. The included personal profile scales with `RUN_DURATION`:
the first 1/60th of the run every 10 seconds, the next 5/60ths every 30
seconds, the next 10/60ths every minute, then every 10 minutes.

`ntfy-local/` contains an optional self-hosted ntfy service and publish helper.

## Requirements

- Bash, GNU coreutils, `awk`, `dd`, and `flock`
- `ssh` for remote worker modes
- `jq` for `ssh-qm` output parsing
- `nc`/`ncat` on source-blast senders and receivers
- Proxmox `qm guest exec` for `ssh-qm` scenarios

## Safety Notes

This tool is intentionally capable of generating heavy read and network load.
Start with the smoke configs, validate paths before running real scenarios, and
keep test datasets separate from production workloads where possible.
