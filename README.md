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
