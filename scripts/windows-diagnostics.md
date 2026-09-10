# Windows Rust slowdown investigation

Run **Diagnose Windows Rust CI** manually in GitHub Actions:

1. Select `seed` once and wait for both jobs to succeed.
2. Select `measure` three times, waiting for each workflow to finish before starting the next.
3. Download each job's diagnostic artifact from the run page.

This runs only RunsOn on-demand Windows 2 CPU / 8 GB and 4 CPU / 16 GB,
one job at a time. It uses the benchmark's image, Rust version, Cargo commands
and S3 cache paths. It has its own cache keys. `measure` requires a cache hit
and never updates the cache. `seed` creates missing caches; it does not replace
existing ones. To start a fresh experiment, bump `windows-diagnostic-v1` in the
workflow and seed again. Keep the source revision unchanged across measurements.

## What we're trying to understand

In benchmark run 20, the on-demand Windows 2-CPU job took 329 seconds versus
101 seconds for 4 CPU. Cache restore took almost the same time (24 vs 25 seconds),
but Cargo test took 212 vs 37 seconds. So downloading the cache does not explain
the gap. Average CPU usage was low and the smaller machine's peak memory usage
was much higher. Those clues suggest waiting, but don't establish the cause.

We collect:

- **CPU and processes:** is Rust doing work, or is another process using the machine?
- **Available memory and paging:** is Windows moving memory to/from disk because RAM is tight?
- **Disk latency and queue:** are programs waiting for file reads or writes?
- **Cargo timing reports and rebuild reasons:** what actually recompiles after a cache hit?

A cache hit means the archive was restored; Cargo can still decide that some
files need rebuilding. Disk capacity used is not a measure of how busy a disk is.
Paging counters can also include file-backed reads, so no single counter proves
memory pressure. Correlate several signals during the same slow phase.

The two sizes differ in RAM as well as CPU. This first experiment identifies where
time goes; it does not isolate the effect of CPU count alone. Once the evidence
points to a cause, change one relevant setting and repeat the comparison.

## Artifacts

- `<phase>/machine.json`: CPU, RAM, initial pagefile usage, antivirus status and revision.
- `phases.jsonl`, `durations.jsonl`: UTC phase boundaries and command elapsed times/exit codes.
- `<phase>/counters.jsonl`: system counters sampled roughly once a second; disk latency is in seconds.
- `<phase>/processes.jsonl`: process CPU, I/O rates and private working set roughly every five seconds.
- `*.log`: Cargo output, including fingerprint messages explaining rebuilds.
- `*-timings/`: Cargo HTML reports for test and both Clippy commands.
- Collector/error logs: check these if samples are missing or incomplete.

Collection now starts and stops inside each Cargo step, keeping its parent process
alive. Each step requires a counter sample after Cargo finishes and fails if
collection ended early. Cache restore timing remains in the Actions step log.
Process snapshots can miss short-lived processes. Instrumentation itself adds overhead,
so use these runs for diagnosis, not blog timing averages. Security settings are
only read, never changed. Logs expire after seven days.

References: [original slow run](https://github.com/sjysngh/spotify-player/actions/runs/34259035640),
[Windows performance counters](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-counter),
[Cargo timings](https://doc.rust-lang.org/cargo/commands/cargo-test.html),
[Cargo rebuild diagnostics](https://doc.rust-lang.org/cargo/faq.html).

The first diagnostic revision produced only 5–6 counter samples per job, all
before Cargo started. Its Cargo timings are usable, but its system/process
counters cannot explain the slow phases. After updating, run `measure` once
using the existing seed caches to verify full counter coverage before repeating.
