# VirtualMemory

โปรเจกต์วิชา CPE333 Operating Systems สำหรับสร้าง Linux kernel module
เพื่อติดตามข้อมูลหน่วยความจำเสมือนของ process ที่ระบุ PID

โมดูลแสดงข้อมูล:

- จำนวน memory regions
- ขนาด virtual address space รวม หน่วยเป็น bytes
- จำนวน minor page faults ของ process
- จำนวน major page faults ของ process

ข้อมูลจะแสดงใน kernel log เมื่อโหลดโมดูล

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

## สคริปต์ทดสอบ

- `tests/thread_test.py` — สร้าง process ที่มี worker threads ทำงานอยู่
- `tests/thread_exit_test.py` — ตรวจกรณี worker threads ทำงานจบแล้ว

## โครงสร้างโปรเจกต์

- `kernel/vm_monitor.c` — โค้ด kernel module
- `kernel/Makefile` — คำสั่ง build ด้วย kernel build system
- `docs/environment.md` — รายละเอียดสภาพแวดล้อม
- `docs/kernel-safety-review.md` — ผลตรวจความปลอดภัยและแผนทดสอบของ kernel module
- `tests/` — สคริปต์สำหรับทดสอบ
- `scripts/` — พื้นที่สำหรับสคริปต์เพิ่มเติม

## CLI Usage

Run this on Linux. You need Bash, `insmod`, `rmmod`, `dmesg` with `--follow-new` support, `flock`, GCC, GNU Make, and headers for the running kernel. The wrapper needs root because it loads the kernel module and reads the kernel log. It is not intended to run directly on Windows.

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

The wrapper validates the PID, resolves the module relative to its own location, rejects a module that is already loaded, and reports useful errors for invalid input, missing module files, insertion failures, incomplete logs, and cleanup failures. It captures only new kernel-log records; it never clears the system log. A lock serializes wrapper instances, but does not coordinate with manual `insmod` or `rmmod` commands. The wrapper unloads only a module it successfully loaded and uses traps for best-effort cleanup after interruption or later errors. It does not use forced removal.

All reported values come from the kernel module. The address size is shown in bytes and binary KiB/MiB. Page-fault counters are cumulative process totals at the module initialization snapshot, not faults caused only by the CLI. A process can change while it is being inspected; use a stable target for comparisons. See [tests/README.md](tests/README.md) for workload and `/proc` verification instructions.
