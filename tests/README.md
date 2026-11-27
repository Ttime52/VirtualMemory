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

When a module version that supports process snapshots is available, capture its snapshot while the target program is stopped at each pause, using that version's documented PID input and trigger. Compare its reported VMA count and address-space size with `/proc/<pid>/maps` and the `VmSize` value in `/proc/<pid>/status`. Compare its minor/major counters with fields 10 and 12 of `/proc/<pid>/stat` and with the test program's `getrusage(RUSAGE_SELF)` deltas. Keep in mind that `getrusage()` deltas cover only the interval around the deliberate accesses, while `/proc/<pid>/stat` and a module snapshot generally show cumulative process counters.

**Checkout limitation:** the `kernel/vm_monitor.c` currently in this repository only logs module load and unload messages. It contains no PID input, process lookup, snapshot trigger, or statistics output format. Therefore, this checkout cannot perform a direct module-to-`/proc` comparison until that interface exists; the programs and `/proc` verification can still be used independently. No kernel module source is changed by these tests.

On x86_64, `/proc/<pid>/maps` commonly includes a special `[vsyscall]` line at a fixed high address. It is a legacy special mapping and should be treated separately from ordinary VMAs when comparing counts or address-space totals. In particular, do not assume that a line count from `maps`, an `mm` VMA count, and a module's chosen virtual-size definition include this special region in the same way.

## Limitations

- The module and `/proc` snapshots are point-in-time observations. A process can change between a snapshot and the later read of procfs; use the pauses to keep the test workload stable.
- `test_vma` reserves a mapping without touching its pages, so it demonstrates VMA/address-space behavior, not resident-memory growth.
- Fault counts are cumulative process counters outside the measured interval. Background runtime activity can add faults; use before/after differences and compare against `getrusage()` deltas.
- Major faults depend on actual storage I/O, which user space cannot guarantee without disruptive cache controls. The test reports observations and does not claim success when the major counter does not increase.
