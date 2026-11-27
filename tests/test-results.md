# Virtual Memory Monitor: ผลทดสอบเบื้องต้น

## สภาพแวดล้อม

- OS: Ubuntu ใน UTM
- Kernel: 7.0.0-31-generic
- โค้ด: เวอร์ชันหลังปรับ scoped_seqlock_read
- หมายเหตุ: ผลลัพธ์เป็นค่าที่อ่านได้ ณ เวลาทดสอบ

## Build

- `make -C kernel` สำเร็จ และสร้าง `kernel/vm_monitor.ko`

## ผลทดสอบหลังปรับ scoped_seqlock_read

### กรณี process มี 4 threads

- Process: python3, PID 40736
- `/proc/40736/status`: Threads = 4
- Module และ `/proc/40736/stat` ก่อน/หลังโหลด:
  - Minor page faults: 9874
  - Major page faults: 2
  - Virtual address space: 311762944 bytes
- Module รายงาน 50 memory regions
- รอบนี้ไม่ได้เปรียบเทียบจำนวน regions กับ maps

### กรณี worker threads จบแล้ว

- Process: python3, PID 40763
- `/proc/40763/status`: Threads = 1
- Module และ `/proc/40763/stat` ก่อน/หลังโหลด:
  - Minor page faults: 15684
  - Major page faults: 0
  - Virtual address space: 181989376 bytes
- Module รายงาน 45 memory regions
- รอบนี้ไม่ได้เปรียบเทียบจำนวน regions กับ maps

## ผลทดสอบก่อนปรับ scoped_seqlock_read

- bash: จำนวน regions 25 และขนาด 12554240 bytes ตรงกับ
  `/proc/3944/maps`
- PID -1: module ปฏิเสธและแจ้ง `please provide a valid PID`
- PID หลักและ thread ย่อยใน process เดียวกัน:
  module รายงานค่าทั้ง 4 ตรงกันในรอบที่ทดลอง

## ขอบเขตและข้อจำกัด

- ผลข้างต้นเป็นการทดสอบเบื้องต้น ไม่ใช่การยืนยันทุกกรณี
- ยังไม่ได้ทดสอบอย่างเป็นระบบขณะ process กำลังจบ
- ค่า page faults และ memory mappings อาจเปลี่ยนระหว่างการอ่าน
- scoped_seqlock_read ต้องตรวจความเข้ากันได้หากใช้ kernel รุ่นอื่น

## เปรียบเทียบกับ maps หลังปรับ scoped_seqlock_read

- Process: python3, PID 40813, Threads = 4
- จำนวน memory regions: module 45, `/proc/40813/maps` 45
- ขนาด virtual address space: module และผลรวมจาก
  `/proc/40813/maps` เท่ากับ 311189504 bytes
- รอบนี้ไม่ได้เทียบ page faults กับ `/proc/40813/stat`
