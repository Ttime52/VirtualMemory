# Virtual Memory Test Programs

These small Linux programs create controlled virtual-memory workloads for inspecting process mappings and page-fault counters. They are independent of the kernel module and do not modify it.

## Test objectives

- `test_vma`: pause before and after creating a 16 MiB anonymous mapping, unmap it, and pause again so another terminal can inspect the process.
- `test_minor`: allocate 64 MiB of anonymous memory, then write to one byte on each system page. It reports the process's `getrusage()` minor and major fault deltas.
- `test_major`: write a bounded 64 MiB temporary file, map it read-only, advise the kernel to discard cached pages, and read one byte per page. It reports the observed `getrusage()` deltas and explicitly says when no major fault increase occurred.

The minor test uses volatile memory accesses so the compiler cannot remove the page touches. All programs print their PID and wait for Enter at useful inspection points. The allocations are fixed and modest; the major test does not drop the system-wide page cache.

## Build

On Linux with GCC or another C compiler and GNU Make:

```sh
make -C tests
```

This creates `tests/test_vma`, `tests/test_minor`, and `tests/test_major`. Clean them with:

```sh
make -C tests clean
```

The executable names are already excluded by the repository's root `.gitignore`.

## Run and inspect

Use two terminal windows. Start a program in terminal 1, note the PID it prints, and leave it waiting at a prompt. In terminal 2, set `PID` to that value and run the inspection commands below. Press Enter in terminal 1 to advance to the next state.

### VMA creation and removal

Terminal 1:

```sh
./tests/test_vma
```

At the first pause, record the baseline. At the second pause, inspect the mapping. At the final pause, check that it has been removed. In terminal 2:

```sh
PID=12345  # replace with the PID printed by test_vma
cat "/proc/$PID/maps"
grep -E '^(VmSize|VmRSS|VmData|VmPTE):' "/proc/$PID/status"
python3 - "$PID" <<'PY'
import sys

pid = sys.argv[1]
entries = open(f"/proc/{pid}/maps", encoding="ascii").read().splitlines()
mapped_bytes = 0
for entry in entries:
    start, end = entry.split(None, 1)[0].split("-")
    mapped_bytes += int(end, 16) - int(start, 16)
print("maps entries:", len(entries))
print("sum of displayed ranges (bytes):", mapped_bytes)
PY
```

The new range should be visible while the program is paused after `mmap()` and absent after `munmap()`. `VmSize` should increase by approximately 16 MiB and later return near its earlier value. The number of `maps` lines need not increase by exactly one: Linux can merge adjacent compatible mappings, and a mapping can split when protection or other attributes differ.

### Anonymous demand paging and minor faults

Terminal 1:

```sh
./tests/test_minor
```

At the first pause, the mapping exists but the program has not intentionally touched its pages. After continuing, the program writes one byte per system page, reports the `getrusage()` counter deltas, and pauses again. During that pause, inspect:

```sh
PID=12345  # replace with the PID printed by test_minor
grep -E '^(VmSize|VmRSS|RssAnon|VmPTE):' "/proc/$PID/status"
python3 - "$PID" <<'PY'
import sys

pid = sys.argv[1]
stat = open(f"/proc/{pid}/stat", encoding="ascii").read().strip()
fields = stat[stat.rfind(")") + 2:].split()  # starts at field 3 (state)
print("minflt (field 10):", fields[7])
print("majflt (field 12):", fields[9])
PY
```

Compare the `stat` values before and after the scan, or compare their difference with the program's `getrusage()` deltas. Anonymous first-touch faults should normally raise `minflt` substantially; `majflt` should generally remain unchanged. Exact counts can vary with kernel configuration, transparent huge pages, and unrelated activity in the process. `/proc/<pid>/status` reports memory sizes such as `VmSize` and `VmRSS`, but standard Linux status output does not provide the `minflt`/`majflt` fields; those are in `/proc/<pid>/stat`.

### File-backed access and major faults

Terminal 1:

```sh
./tests/test_major
```

The program writes and syncs its 64 MiB temporary file, maps it, and requests `POSIX_FADV_DONTNEED` plus `MADV_RANDOM` as best-effort hints. At its first pause, take a baseline. Continue to scan the file and compare the reported deltas with `/proc/<pid>/stat` at the second pause using the Python command above.

A major fault increase is evidence that file-backed reads required storage I/O during this run. If the program reports zero major faults, treat the run as not having demonstrated major faults. The file may have stayed in the page cache, the filesystem or virtualized storage may satisfy reads from cache, or the kernel may not honor the advisory eviction hint. The test intentionally does not flush global caches, use `drop_caches`, or increase the file until it consumes excessive resources. Repeated runs can produce different counts.

## Comparing with the kernel module

This checkout accepts a PID through the read-only `pid` module parameter and prints one snapshot during module initialization. While a test program is paused, load the module from another terminal:

```sh
sudo insmod kernel/vm_monitor.ko pid="$PID"
sudo dmesg | tail -n 10
sudo rmmod vm_monitor
```

The module logs the target PID and process name, VMA count, total bytes across normal VMAs, and process minor/major page-fault counters. Compare the VMA count and byte sum with `/proc/<pid>/maps`, virtual size with `VmSize` in `/proc/<pid>/status`, and fault counts with fields 10 and 12 of `/proc/<pid>/stat`. Keep the target paused during each snapshot where possible. The `getrusage()` values in the minor and major programs are deltas over their deliberate-access intervals; module and procfs values are cumulative.

The kernel module source is unchanged by these user-space tests. The safety review and the module's current PID/error behavior are documented in `docs/kernel-safety-review.md`.

## Module parameter and lifecycle checks

In a disposable Ubuntu VM, first build the module for the running kernel, then run the bounded safety checks as root:

```sh
make -C kernel
sudo env VM_SAFETY_ACK=YES sh tests/safety_test.sh kernel/vm_monitor.ko
```

The script requires an explicit disposable-VM acknowledgement, verifies a valid PID load, five load/unload cycles, rejection of missing or invalid PID values, and that rejected loads do not leave the module present in `/sys/module`. It refuses to run if the module is already loaded or the module's `vermagic` does not match the running kernel. A failed `insmod` does not establish ownership; if the module is present after a failed load, the script reports the unexpected state and leaves it untouched. Review recent `vm_monitor:` messages with `sudo dmesg | tail -n 100`; do not clear the kernel log.

On x86_64, `/proc/<pid>/maps` commonly includes a special `[vsyscall]` line at a fixed high address. It is a legacy special mapping and should be treated separately from ordinary VMAs when comparing counts or address-space totals. In particular, do not assume that a line count from `maps`, an `mm` VMA count, and a module's chosen virtual-size definition include this special region in the same way.

## Limitations

- The module and `/proc` snapshots are point-in-time observations. A process can change between a snapshot and the later read of procfs; use the pauses to keep the test workload stable.
- `test_vma` reserves a mapping without touching its pages, so it demonstrates VMA/address-space behavior, not resident-memory growth.
- Fault counts are cumulative process counters outside the measured interval. Background runtime activity can add faults; use before/after differences and compare against `getrusage()` deltas.
- Major faults depend on actual storage I/O, which user space cannot guarantee without disruptive cache controls. The test reports observations and does not claim success when the major counter does not increase.

## CLI verification record

Static checks run in Windows Git Bash on 2026-11-27:

- `bash -n scripts/vm_monitor.sh`, `bash -n scripts/vm_monitor_log.sh`, and `bash -n tests/test_cli.sh` — passed.
- `bash tests/test_cli.sh` - passed help (including from another directory) and argument checks, plus a complete module-output fixture that reaches the success summary, timestamps in both prefix orders, an extra module-verification diagnostic, missing/duplicate/malformed fields, a mismatched PID, and mixed stale/current target records.
- The valid-PID privilege check was skipped because this was not a non-root Linux shell. No kernel module was loaded.

Linux module integration is **Pending** Ubuntu VMware verification. In Ubuntu, run:

```sh
make -C kernel
bash -n scripts/vm_monitor.sh
bash -n scripts/vm_monitor_log.sh
bash -n tests/test_cli.sh
chmod +x scripts/vm_monitor.sh
./scripts/vm_monitor.sh --help
bash tests/test_cli.sh

sleep 300 &
PID=$!
sudo ./scripts/vm_monitor.sh "$PID"
grep -E '^(Name|Threads|VmSize|VmRSS):' "/proc/$PID/status"
cat "/proc/$PID/maps"
python3 - "$PID" <<'PY'
import sys

pid = sys.argv[1]
fields = open(f"/proc/{pid}/stat", encoding="ascii").read().strip()
fields = fields[fields.rfind(")") + 2:].split()
print("minflt (field 10):", fields[7])
print("majflt (field 12):", fields[9])
PY

if lsmod | grep -q '^vm_monitor '; then
    echo 'ERROR: vm_monitor is still loaded'
else
    echo 'PASS: vm_monitor was unloaded'
fi
kill "$PID"
```

Compare a snapshot taken while the target is stable. `/proc/<pid>/stat` fields 10 and 12 are cumulative minor and major faults; VMA counts can differ by the x86_64 `[vsyscall]` pseudo-mapping.
Parser and formatting fixtures exercise the same functions used by the CLI, but do not run `dmesg` or load a module. Reader-startup/boundary behavior, failed-insertion log draining, signal cleanup, module insertion/removal, actual `/proc` comparisons, loaded-module preservation, and locking remain pending Ubuntu VMware verification.

## CLI wrapper

Build the module for the running kernel and take a snapshot of a target process with:

```sh
make -C kernel
sudo ./scripts/vm_monitor.sh 24097
```

The wrapper resolves `kernel/vm_monitor.ko` relative to the repository, validates the PID and module kernel version, and requires root. It waits for the `dmesg` reader to open the kernel log and echo a unique boundary marker written to `/dev/kmsg` before inserting the module; this adds one small marker record per run. After a failed insertion, it allows the reader to drain and prints both `insmod` and current kernel-log diagnostics. `setsid` keeps the insertion process running through Ctrl+C so the wrapper can record whether it succeeded, return the signal status, and clean up a module it owns. It refuses to run if `vm_monitor` is already loaded. A lock prevents two wrapper invocations from overlapping; manual `insmod` and `rmmod` commands do not use that lock. The wrapper does not clear the kernel log and does not read statistics from `/proc`.

To run the non-destructive argument and help checks without loading a kernel module:

```sh
bash tests/test_cli.sh
```

For a successful snapshot, keep the target alive during the command. Fault counts remain cumulative counters captured once during module initialization.
