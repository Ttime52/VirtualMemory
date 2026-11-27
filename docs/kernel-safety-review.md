# Kernel Safety Review

## 1. Review scope

This review covers `kernel/vm_monitor.c`, its out-of-tree module Makefile, the repository README and environment notes, and the existing VMA, page-fault, active-thread, and terminated-thread tests. It focuses on PID parsing and lookup, task and `mm_struct` lifetime, VMA synchronization, fault aggregation, error returns, logging, and module lifecycle. It does not redesign the snapshot interface or add kernel tracing.

The comparison for fault accounting is Linux v7.0's `/proc/<pid>/stat` process path in [`fs/proc/array.c`](https://github.com/torvalds/linux/blob/v7.0/fs/proc/array.c), the dead-thread accounting description in [`include/linux/sched/signal.h`](https://github.com/torvalds/linux/blob/v7.0/include/linux/sched/signal.h), and the transfer performed by [`kernel/exit.c`](https://github.com/torvalds/linux/blob/v7.0/kernel/exit.c). Task-name handling was compared with [`include/linux/sched.h`](https://github.com/torvalds/linux/blob/v7.0/include/linux/sched.h) and [`fs/exec.c`](https://github.com/torvalds/linux/blob/v7.0/fs/exec.c); the module has a GPL license for GPL-only kernel symbols. The repository's target environment is Ubuntu 26.04 on Linux 7.0.0-30-generic; the existing recorded test run used Linux 7.0.0-31-generic in UTM.

## 2. Executive summary

Source review found the PID, task, and memory reference paths balanced. VMA traversal is protected by the target `mm` read lock, and process-wide minor/major fault totals follow the same dead-counter-plus-live-thread aggregation used by Linux v7.0 for `/proc/<pid>/stat`. RCU protects traversal of the thread list, and the kernel's `stats_lock` protects the accumulated dead-thread counters.

One small API-consistency change was made: the success log now copies the task name into a fixed-size local buffer with `get_task_comm()` before formatting it. This follows the kernel's procfs task-name path and keeps logging independent of the live task field. Task names can still change while a snapshot is collected; the helper does not freeze the task. The kernel log format is unchanged. The source review did not establish an exploitable defect in the prior fixed-size `comm` read.

No high- or critical-severity defect was confirmed by source review. Runtime safety, stress, and build checks remain unverified in this Windows session.

## 3. Findings and changes

| Severity | Finding | Impact | Resolution |
|---|---|---|---|
| Low, API consistency | Success logging formatted the live `task->comm` field directly. | The process name could change while the snapshot is collected; Linux procfs also reads task names through a kernel helper. No memory-safety defect was confirmed. | Copy into a local `TASK_COMM_LEN` buffer with `get_task_comm()` before logging. |
| Low, documented | `insmod` can print “Module has wrong symbol version” when the module initializer returns `-ESRCH`. | The userspace diagnostic can mislead operators even when the kernel log identifies a missing PID. | Keep the semantically correct `-ESRCH`; use the kernel log to identify the module's rejection reason. This mapping is visible in [kmod's `tools/insmod.c`](https://github.com/kmod-project/kmod/blob/master/tools/insmod.c). |
| Informational | The VMA and page-fault values are collected in separate protected phases. | A live process can change between the phases, so the four values are not one atomic cross-metric snapshot. | Preserve the current snapshot behavior and document the limitation. |

### Initial input and error review

`pid` is an integer module parameter with mode `0444`, defaulting to `-1`. Missing, zero, and negative values that fit in `int` reach `vm_monitor_init()` and return `-EINVAL` after a `vm_monitor:` error message. Nonnumeric and out-of-range values can be rejected by the module-parameter parser before the initializer runs, so they may have no module-specific kernel log. A nonexistent PID is rejected with `-ESRCH`. A target for which `get_task_mm()` returns `NULL` is rejected with `-EINVAL`.

The “wrong symbol version” message is a kmod userspace string mapping: kmod's `insmod` maps `ESRCH` to that text. It does not establish that symbol versions were mismatched. In the reported case, the kernel's `PID 99999999 was not found` message and the initializer's `-ESRCH` identify the actual cause. No error code change is warranted.

## 4. Reference lifecycle

| Resource | Acquisition | Release | Review |
|---|---|---|---|
| PID object | `find_get_pid(pid)` | `put_pid(pid_struct)` immediately after task lookup | Released whether task lookup succeeds or fails. |
| Task | `get_pid_task(pid_struct, PIDTYPE_PID)` | `put_task_struct(task)` on the no-`mm` error path or after successful logging | The reference keeps the task allocation valid while its fields are inspected. It does not by itself freeze task state. |
| Address space | `get_task_mm(task)` | `mmput(mm)` after logging | The reference keeps the `mm_struct` valid; `mmap_read_lock()` separately protects VMA traversal. |

If the task exits before `get_pid_task()`, lookup can fail cleanly. If it exits after a task reference is obtained, that reference keeps the `task_struct` alive. The `mm` reference and read lock keep the selected address space valid through iteration. An exiting task can already have detached its address space, in which case `get_task_mm()` returns `NULL` and the task reference is released. These references prevent use-after-free; they do not freeze the target or guarantee that all metrics represent the same instant.

Every acquired PID, task, and `mm` reference has one matching release on the current success and error paths. No dynamic module-owned allocation or persistent registration is made. A failed initializer returns its negative errno after releasing acquired references; no successful module instance remains to be removed.

## 5. VMA iteration and locking

The module acquires `mmap_read_lock(mm)`, walks the VMA tree with `VMA_ITERATOR()` and `for_each_vma()`, and releases the lock before logging. This prevents concurrent `mmap()`/`munmap()` changes from invalidating VMA nodes during the walk. There are no error returns inside the locked section, so the unlock is reached on each path through it.

The virtual-size total is the sum of `vma->vm_end - vma->vm_start`, stored in `unsigned long long` and printed in bytes. Each range is ordered and the total user address space is bounded by the architecture's address space, so the accumulator is wide enough for the supported Linux targets. The behavior intentionally counts normal VMA ranges only. The special x86_64 `[vsyscall]` display entry is not part of normal VMA iteration and is not added artificially to match `/proc/<pid>/maps` line counts.

The VMA count and byte total are stable during their own read-locked phase. Page-fault counters are sampled before that phase, so simultaneous activity can make the combined log internally non-atomic.

## 6. Fault accounting, RCU, and synchronization

The module reads `signal->min_flt` and `signal->maj_flt` and adds each thread's `min_flt` and `maj_flt` while holding `signal->stats_lock` through `scoped_seqlock_read()`. It holds an RCU read section while walking the thread list with `for_each_thread()`.

This matches the Linux v7.0 `whole` process branch used for `/proc/<pid>/stat`: the signal counters contain accumulated resource counts from dead threads, while active threads keep their own counters. `kernel/exit.c` adds a dying thread's fault counts to `signal->min_flt` and `signal->maj_flt` under `stats_lock` before unlinking it from the thread list. Thus the module does not omit a worker merely because it exited before the snapshot, and it does not intentionally add the dead-thread aggregate twice. The module reports the process's own fields 10 and 12, not the waited-for child counters in fields 11 and 13.

RCU keeps list traversal safe while threads are removed; `stats_lock` synchronizes the dead-thread transfer and provides a retrying sequence snapshot. The live tasks' own fault counters can still advance while being read. The result is the same practical process-wide snapshot model used by procfs, not a stop-the-world snapshot. The seqlock read path and RCU read-side path do not sleep. `mmap_read_lock()` is acquired before entering RCU and released after leaving it; VMA operations do not take `stats_lock`, and this review found no lock-order inversion in the examined path.

## 7. Logging and module lifecycle

All module messages retain the `vm_monitor:` prefix. Successful initialization logs the target PID/name and all four requested metrics. Error branches log a specific reason and return a negative Linux errno. The only output change is copying the name through `get_task_comm()` into a local buffer; the format is unchanged. Like procfs, the helper does not freeze the target, so the name may reflect a concurrent rename or exec.

There is no module-global allocation, work item, callback, or reference retained after initialization. A successful load can be removed through the existing `module_exit()` function. Failed initialization has already released resources before returning. Repeated load/unload and failed-init cleanup still require runtime confirmation.

## 8. Tests and recorded results

### Existing recorded results

`tests/test-results.md` records earlier successful builds and tests on Ubuntu/UTM with Linux 7.0.0-31-generic. These are historical results and were not rerun for this review:

- Four-thread process, PID 40736: `Threads=4`, 9,874 minor faults, 2 major faults, 311,762,944 virtual bytes, and 50 regions. The recorded fault and virtual-byte values matched the noted `/proc` observations; this run did not compare region count with `maps`.
- Worker threads exited, PID 40763: `Threads=1`, 15,684 minor faults, 0 major faults, 181,989,376 virtual bytes, and 45 regions. The recorded counters and virtual bytes matched the noted `/proc` observations.
- After the `scoped_seqlock_read()` change, PID 40813 with four threads had 45 module regions and 45 `/proc/40813/maps` entries; both the module and the sum of displayed map ranges reported 311,189,504 bytes.
- An earlier bash run reported 25 regions and 12,554,240 bytes, matching the noted `/proc/<pid>/maps` comparison. PID `-1` was rejected. The supplied issue report also records a nonexistent PID kernel message, but its `insmod` message was misleading as described above.

These results provide baseline coverage for valid PIDs, multiple active threads, terminated workers, and the four metrics. They do not prove race freedom.

### Safety matrix

| Test | Scenario | Review status |
|---|---|---|
| SAFE-01 | Valid PID | Prior valid-PID tests recorded; not rerun here. |
| SAFE-02 | Missing PID parameter | Source review: default `-1` is rejected. Runtime not recorded; pending. |
| SAFE-03 | PID zero | Source review: rejected with `-EINVAL`. Runtime pending. |
| SAFE-04 | Negative PID | PID `-1` rejection is recorded; other negative values pending. |
| SAFE-05 | Nonnumeric PID | Parser should reject before module init; runtime pending. |
| SAFE-06 | PID outside `int` range | Parser should reject before module init; runtime pending. |
| SAFE-07 | Nonexistent PID | Issue report records kernel rejection; not independently rerun here. |
| SAFE-08 | Target exits during inspection | Pending; short-lived target race needs repeated VM runs. |
| SAFE-09 | Thread exits during inspection | Sequential terminated-worker test is recorded; concurrent-exit race pending. |
| SAFE-10 | Concurrent `mmap()`/`munmap()` | Pending; should be exercised with bounded churn in a disposable VM. |
| SAFE-11 | Multiple active threads | Existing `thread_test.py` and a four-thread result are recorded. |
| SAFE-12 | Previously terminated workers | Existing `thread_exit_test.py` and a result with one surviving thread are recorded. |
| SAFE-13 | Repeated load/unload | Pending; covered by `tests/safety_test.sh` for five cycles. |
| SAFE-14 | Cleanup after failed initialization | Source paths reviewed; parameter test checks unloaded state. Runtime pending. |
| SAFE-15 | All four metric regressions | Prior results recorded; VMA map-count comparison exists for one run. Not rerun here. |
| SAFE-16 | Target without user `mm` | Source path returns `-EINVAL`; runtime pending. |

The added `tests/safety_test.sh` is deliberately limited to module parameter rejection, a valid-PID load, and five load/unload cycles. It refuses to run outside Linux, without root, without an explicit disposable-VM acknowledgement, against a mismatched `vermagic`, or if `vm_monitor` is already loaded. It does not replace the existing VMA, page-fault, or thread tests.

## 9. Build and manual verification

On the target Ubuntu VM:

```bash
uname -r
make -C kernel clean
make -C kernel
modinfo kernel/vm_monitor.ko
make -C tests
sudo env VM_SAFETY_ACK=YES sh tests/safety_test.sh kernel/vm_monitor.ko
```

For the existing multithreading workloads, keep each process alive while loading the module and inspect the corresponding `vm_monitor:` and `/proc` values:

```bash
python3 tests/thread_test.py > /tmp/vm-thread-test.log 2>&1 & target=$!
sleep 1
sudo insmod kernel/vm_monitor.ko pid="$target"
sudo dmesg | tail -n 10
sudo rmmod vm_monitor
kill "$target" 2>/dev/null || true
wait "$target" 2>/dev/null || true

python3 tests/thread_exit_test.py > /tmp/vm-thread-exit-test.log 2>&1 & target=$!
sleep 1
sudo insmod kernel/vm_monitor.ko pid="$target"
sudo dmesg | tail -n 10
sudo rmmod vm_monitor
kill "$target" 2>/dev/null || true
wait "$target" 2>/dev/null || true
```

For one successful snapshot, keep a target process alive, then load and unload the module:

```bash
sleep 120 &
target=$!
sudo insmod kernel/vm_monitor.ko pid="$target"
sudo dmesg | tail -n 10
lsmod | grep vm_monitor
sudo rmmod vm_monitor
wait "$target" 2>/dev/null || true
```

The parameter test script covers missing, zero, negative, nonnumeric, out-of-range, and nonexistent PIDs. For a process with no user `mm`, first confirm that PID 2 is `kthreadd` in the VM (`cat /proc/2/comm`), then try `sudo insmod kernel/vm_monitor.ko pid=2`; it should fail with the no-user-address-space kernel log and leave the module absent from `lsmod`.

For SAFE-08, repeat a short-lived target race a bounded number of times:

```bash
set -e
for i in $(seq 1 25); do
    sleep 0.02 & target=$!
    if sudo insmod kernel/vm_monitor.ko pid="$target"; then
        sudo rmmod vm_monitor
    elif [ -e /sys/module/vm_monitor ]; then
        echo "failed initialization left vm_monitor loaded" >&2
        break
    fi
    wait "$target" 2>/dev/null || true
done
```

For SAFE-09, start the existing terminated-worker test and take bounded snapshots while its workers start and finish. The process waits after joining, so it remains available for the final aggregate check:

```bash
set -e
log=$(mktemp)
python3 tests/thread_exit_test.py >"$log" 2>&1 & target=$!
for i in $(seq 1 10); do
    if sudo insmod kernel/vm_monitor.ko pid="$target"; then
        sudo rmmod vm_monitor
    elif [ -e /sys/module/vm_monitor ]; then
        echo "failed initialization left vm_monitor loaded" >&2
        break
    fi
done
kill "$target" 2>/dev/null || true
wait "$target" 2>/dev/null || true
cat "$log"
rm -f "$log"
```

For SAFE-10, use a small anonymous mapping churner and take 20 snapshots while it runs:

```bash
set -e
python3 -c 'import mmap, time
for _ in range(200):
    region = mmap.mmap(-1, 4096)
    region.close()
    time.sleep(0.01)' & target=$!
for i in $(seq 1 20); do
    if sudo insmod kernel/vm_monitor.ko pid="$target"; then
        sudo rmmod vm_monitor
    elif [ -e /sys/module/vm_monitor ]; then
        echo "failed initialization left vm_monitor loaded" >&2
        break
    fi
done
wait "$target" 2>/dev/null || true
```

These runs are bounded but cannot guarantee a particular race interleaving. Between successful insertions, run `sudo rmmod vm_monitor`. Stop immediately on a module-caused Oops, panic, warning, or system instability. Do not clear the kernel log; inspect only recent entries with `sudo dmesg | tail -n 100`.

Compare VMA counts and byte sums with `/proc/<pid>/maps`, virtual size with `/proc/<pid>/status`, and process fault fields 10 and 12 in `/proc/<pid>/stat`. For total fault comparisons, read procfs immediately around the module load because both values are cumulative and the target may continue to run.

### Execution status for this review

Runtime testing was not available in this Windows session. WSL distribution enumeration returned `E_ACCESSDENIED`; the available GCC targets MinGW, and GNU Make is unavailable. No kernel module build, load, invalid-PID run, or stress test was performed here. All such tests are pending in Ubuntu VMware. No test output has been fabricated.

## 10. Known limitations and remaining risks

- The source review covers Linux v7.0 behavior, but the module must be rebuilt against the exact running kernel headers. The target 7.0.0-30 and the previously tested 7.0.0-31 kernels are distinct build targets.
- A process or thread can change after one metric is sampled. The module does not freeze the target, and its metrics are not one atomic snapshot.
- RCU and seqlock use were checked against v7.0 procfs behavior, but stress testing and lockdep were not run in this session.
- The kmod diagnostic for `ESRCH` can look like a symbol-version failure even when the module rejected an absent PID. Always check the `vm_monitor:` kernel message and module vermagic before diagnosing a true ABI mismatch.
- `get_task_comm()` copies the task name into a local buffer, but that name can still reflect a later exec/name change than the VMA/fault observations.
- Live active-thread fault counters can advance while read; comparisons should allow small differences on busy targets.
- The special `[vsyscall]` display line is excluded from ordinary VMA iteration on x86_64.

## 11. Acceptance checklist

- [x] PID validation, error paths, lifetime references, VMA lock, fault aggregation, RCU, logging, and lifecycle reviewed.
- [x] Task name copied through the kernel helper without changing log format.
- [x] The `-ESRCH`/kmod diagnostic mapping and parameter-parser behavior documented.
- [x] Existing VMA, page-fault, and thread tests reused; a separate bounded parameter/lifecycle test added.
- [x] Safety review document created with recorded historical results and pending cases.
- [ ] Build against Linux 7.0.0-30-generic — pending.
- [ ] Safety matrix race and stress tests — pending in disposable Ubuntu VMware.
