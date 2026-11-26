# VirtualMemory

โปรเจกต์วิชา CPE333 Operating Systems สำหรับทดลองสร้าง Linux kernel module
ที่เกี่ยวข้องกับการติดตามหน่วยความจำเสมือน (Virtual Memory)

ปัจจุบันโมดูลยังเป็นโครงเริ่มต้น: เมื่อโหลดหรือถอดโมดูล จะแสดงข้อความใน kernel log
และยังไม่มีการเก็บหรือรายงานข้อมูลการใช้หน่วยความจำ

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

โหลดโมดูลและดูข้อความใน kernel log:

```bash
sudo insmod kernel/vm_monitor.ko
sudo dmesg | tail
```

ถอดโมดูลและลบไฟล์ที่ build:

```bash
sudo rmmod vm_monitor
make -C kernel clean
```

การโหลดและถอด kernel module ต้องใช้สิทธิ์ผู้ดูแลระบบ

## โครงสร้างโปรเจกต์

- `kernel/vm_monitor.c` — จุดเริ่มต้นและจุดสิ้นสุดของโมดูล
- `kernel/Makefile` — คำสั่ง build โมดูลด้วย kernel build system
- `docs/environment.md` — รายละเอียดสภาพแวดล้อมที่ใช้พัฒนา
- `scripts/`, `tests/` — พื้นที่สำหรับสคริปต์และการทดสอบในอนาคต
