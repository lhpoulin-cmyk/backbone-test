# Method Suite

Memtest-style network capability suite.

The runner executes every enabled row in `tests.cfg` as one pass, then repeats
the same ordered set until `PASS_COUNT` is reached. Set `PASS_COUNT=0` to cycle
forever until `method-suite-runbook.sh stop` is called.

Reports are written under `REPORT_BASE`:

- `summary.env`: lifecycle status and report path
- `results.tsv`: one row per pass/test/target with throughput and score
- `run.log`: ordered pass and test events

Commands:

```bash
BACKBONE_CONFIG_DIR=/path/to/backbone-test/configs/method-suite ./method-suite-runbook.sh validate
BACKBONE_CONFIG_DIR=/path/to/backbone-test/configs/method-suite ./method-suite-runbook.sh list
BACKBONE_CONFIG_DIR=/path/to/backbone-test/configs/method-suite ./method-suite-runbook.sh run
BACKBONE_CONFIG_DIR=/path/to/backbone-test/configs/method-suite ./method-suite-runbook.sh stop
```

Engines:

- `nc-zero`: `/dev/zero` through `nc` to `/dev/null`
- `mbuffer-nc-zero`: `/dev/zero` through `mbuffer` and `nc` to `/dev/null`
- `iperf3`: TCP calibration using one source unit per configured stream

Optional engines are skipped with a `SKIPPED:<reason>` result row when their
tooling is missing.
