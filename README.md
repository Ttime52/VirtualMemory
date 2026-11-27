# VirtualMemory

โปรเจกต์วิชา CPE333 Operating Systems สำหรับสร้าง Linux kernel module
เพื่อติดตามข้อมูลหน่วยความจำเสมือนของ process ที่ระบุ PID

โมดูลแสดงข้อมูล:

- จำนวน memory regions
- ขนาด virtual address space รวม หน่วยเป็น bytes
- จำนวน minor page faults ของ process
- จำนวน major page faults ของ process

ดูผลได้ 3 ทาง:

- `/proc/vm_monitor` — เขียน PID แล้ว `cat` ดูสรุปได้ซ้ำ ๆ โดยไม่ต้องโหลดโมดูลใหม่
- `scripts/vm_monitor.sh <PID>` — CLI ที่โหลดโมดูล แสดงผล และถอดโมดูลให้
- ระบุ `pid=` ตอนโหลดโมดูล แล้วดูใน kernel log

## ความต้องการ

- Linux พร้อม kernel headers ที่ตรงกับ kernel ที่กำลังใช้งาน
- GCC และ GNU Make

บน Ubuntu ติดตั้งเครื่องมือและ headers ได้ด้วย:

```bash
sudo apt install build-essential linux-headers-$(uname -r)
```

## Build และทดลองใช้งาน

สั่ง build จากโฟลเดอร์โปรเจกต์:

```bash
make -C kernel
```

โหลดโมดูลโดยระบุ PID ของ process ที่ต้องการตรวจ ตัวอย่างนี้ใช้ PID
ของ shell ปัจจุบัน:

```bash
sudo insmod kernel/vm_monitor.ko pid=$$
sudo dmesg | tail -n 10
```

ถอดโมดูลหลังตรวจข้อมูล:

```bash
sudo rmmod vm_monitor
```

ลบไฟล์ที่เกิดจากการ build:

```bash
make -C kernel clean
```

การโหลดและถอด kernel module ต้องใช้สิทธิ์ผู้ดูแลระบบ

## ใช้งานผ่าน /proc/vm_monitor

โหลดโมดูลโดยไม่ต้องระบุ PID แล้วเขียน PID ที่ต้องการตรวจลงใน `/proc/vm_monitor`:

```bash
sudo insmod kernel/vm_monitor.ko
echo $$ | sudo tee /proc/vm_monitor
cat /proc/vm_monitor
```

ตัวอย่างผล:

```text
===== Virtual Memory Summary =====
PID                         : 104 (vmtest)
Number of memory regions    : 12
Total virtual address space : 68145152 bytes (66548 KiB)
Minor page faults (total)   : 16440
Major page faults (total)   : 0
---- since PID was set ----
Minor page faults           : 16384
Major page faults           : 0
```

- **total** คือยอดสะสมตั้งแต่ process เริ่มทำงาน (เทียบได้กับ field 10 และ 12 ของ `/proc/<pid>/stat`)
- **since PID was set** คือจำนวนที่เพิ่มขึ้นตั้งแต่เขียน PID
- `cat` ซ้ำได้ ค่าจะอ่านใหม่ทุกครั้ง และเปลี่ยน PID ได้โดยเขียน PID ใหม่
- PID ที่ไม่มีอยู่หรือไม่ถูกต้องจะถูกปฏิเสธ (`No such process` หรือ `Invalid argument`)
- ถ้า process จบไปแล้ว หรือ PID ถูกนำไปใช้กับ process อื่น จะแจ้งให้ทราบแทนการแสดงค่าผิด
- ถ้าระบุ `pid=` ตอนโหลด ต้องเป็น PID ที่ถูกต้อง (`pid=-1`, `0` หรือ PID ที่ไม่มีอยู่จะทำให้โหลดไม่สำเร็จเหมือนเดิม)
- ถอดโมดูลด้วย `sudo rmmod vm_monitor` ก่อนใช้ CLI เพราะ CLI จะไม่ทำงานถ้าโมดูลโหลดค้างอยู่

## สคริปต์ทดสอบ

- `tests/thread_test.py` — สร้าง process ที่มี worker threads ทำงานอยู่
- `tests/thread_exit_test.py` — ตรวจกรณี worker threads ทำงานจบแล้ว
- `tests/test_vma.c`, `tests/test_minor.c`, `tests/test_major.c` — โปรแกรมสร้าง VMA, minor fault และ major fault (ดู `tests/README.md`)
- `scripts/run_page_fault_tests.sh` — รันโปรแกรมทดสอบทั้งสามคู่กับโมดูล เทียบกับ `/proc` และบันทึกผลเป็น `tests/results-<วันเวลา>.md`

## โครงสร้างโปรเจกต์

- `kernel/vm_monitor.c` — โค้ด kernel module
- `kernel/Makefile` — คำสั่ง build ด้วย kernel build system
- `docs/environment.md` — รายละเอียดสภาพแวดล้อม
- `docs/kernel-safety-review.md` — ผลตรวจความปลอดภัยและแผนทดสอบของ kernel module
- `docs/page-faults.md` — ความรู้เรื่อง page fault, tracepoint และเหตุผลของการออกแบบ
- `docs/testing/test-results-utm.md` — ผลทดสอบบน UTM
- `tests/` — สคริปต์สำหรับทดสอบ
- `scripts/` — พื้นที่สำหรับสคริปต์เพิ่มเติม

## CLI Usage

Run this on Linux. You need Bash, `insmod`, `rmmod`, `dmesg` with `--follow-new` support, `flock`, `setsid`, `readlink`, `wc`, GCC, GNU Make, and headers for the running kernel. The wrapper needs root because it loads the kernel module and reads the kernel log. It is not intended to run directly on Windows.

Build the module and request a snapshot:

```sh
make -C kernel
./scripts/vm_monitor.sh --help
sudo ./scripts/vm_monitor.sh 24097
```

Example output (the values vary by process and run):

```text
========================================
        Virtual Memory Monitor
========================================

Snapshot              : Kernel module initialization
Process ID            : 24097
Process Name          : test_major

Memory Regions        : 27
Virtual Address Space : 70881280 bytes
                        69220.00 KiB
                        67.60 MiB

Minor Page Faults     : 1375 (cumulative)
Major Page Faults     : 0 (cumulative)

========================================
Status: Completed successfully
========================================
```

The wrapper validates the PID, resolves the module relative to its own location, rejects a module that is already loaded, and reports useful errors for invalid input, missing module files, insertion failures, incomplete logs, and cleanup failures. It waits for `dmesg` to open the kernel log and consume a unique boundary marker written to `/dev/kmsg` before inserting the module. This adds one small marker record per run; the wrapper never clears the system log. A lock serializes wrapper instances, but does not coordinate with manual `insmod` or `rmmod` commands. The wrapper unloads only a module it successfully loaded and uses traps for best-effort cleanup after interruption or later errors. It does not use forced removal.

All reported values come from the kernel module. The address size is shown in bytes and binary KiB/MiB. Page-fault counters are cumulative process totals at the module initialization snapshot, not faults caused only by the CLI. A process can change while it is being inspected; use a stable target for comparisons. See [tests/README.md](tests/README.md) for workload and `/proc` verification instructions.
