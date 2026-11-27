# Virtual Memory Monitor — ผลการทดสอบบน UTM

## สภาพแวดล้อมของการทดสอบรอบเดิม

- ผู้ทดสอบ: Kwanchanok Thungsuk
- วันที่ทดสอบ: 27 พฤศจิกายน 2026
- ระบบ: Ubuntu บน UTM
- Kernel: `7.0.0-31-generic`
- Architecture: `aarch64`
- Page size: 4,096 bytes
- GCC: `15.2.0`
- Commit ที่ทดสอบ: `6d67aff40f37e82578080eacdde7b535607b425f`
- วิธีทดสอบ: โหลด kernel module โดยตรงด้วย `insmod` และอ่านผลจาก `dmesg`
- ผลลัพธ์เป็น snapshot ณ เวลาที่โหลด module ไม่ใช่การติดตามแบบ real-time

ผลทุกกรณีในรอบเดิมอ้างอิง commit ข้างต้น ส่วนการทดสอบซ้ำครอบคลุมเฉพาะ
TC-05 โดยระบุ commit และสภาพแวดล้อมของรอบใหม่ไว้ในหัวข้อ TC-05

## สรุปผล

| Test case | รายการ | ผลการทดสอบ |
|---|---|---|
| TC-01 | Build module และโปรแกรมทดสอบ | ผ่าน |
| TC-02 | โหลด module ด้วย PID ที่ถูกต้อง | ผ่านเบื้องต้น แสดงข้อมูลครบ 4 ค่า |
| TC-03 | เปรียบเทียบ VMA ก่อน/หลัง `mmap` และหลัง `munmap` | ผ่านในรอบที่ทดลอง |
| TC-04 | Minor page faults | ผ่านในรอบที่ทดลอง |
| TC-05 | Major page faults | ทดสอบซ้ำแล้วพบ major faults เพิ่ม 16,384 ครั้ง ค่า module ตรงกับ `/proc` ทั้งก่อนและหลัง scan |
| TC-06 | ไม่ระบุ PID และ PID ติดลบ | ผ่าน: module ปฏิเสธ input |
| TC-07 | PID ที่ไม่มี process อยู่ | ผ่าน: kernel log แจ้งไม่พบ PID |
| TC-08 | Process ที่มีหลาย threads | ผ่านเบื้องต้น: ค่าตรงกับ `/proc` ก่อนโหลด |
| TC-09 | หลัง worker threads จบ | ผ่านเบื้องต้น: ค่าตรงกับ `/proc` ก่อนโหลด |
| TC-10 | โหลด module ซ้ำ | โหลดซ้ำถูกปฏิเสธ; สั่งถอด module แล้ว |

## ผลการเปรียบเทียบที่สำคัญ

### TC-03: Memory regions และ virtual address space

ทดสอบ PID `46957` ด้วย `test_vma` โดยเทียบ module กับ
`/proc/46957/maps` ในแต่ละช่วง

| ช่วง | Memory regions | Virtual address space |
|---|---:|---:|
| ก่อน `mmap` | 17 | 2,830,336 bytes |
| หลัง `mmap` | 18 | 19,607,552 bytes |
| หลัง `munmap` | 17 | 2,830,336 bytes |

ขนาดเพิ่มขึ้น 16,777,216 bytes หรือ 16 MiB หลัง `mmap` และกลับมา
เท่าเดิมหลัง `munmap` ในรอบที่ทดสอบ ช่วง address ที่สร้างปรากฏใน
`maps` หลัง `mmap` และไม่พบหลัง `munmap`

### TC-04: Minor page faults

ทดสอบ PID `47142` ด้วย `test_minor` โดยเทียบค่าจาก module และ
`/proc/47142/stat`

| ช่วง | Minor faults | Major faults |
|---|---:|---:|
| ก่อนแตะ pages | 120 | 1 |
| หลังแตะ pages | 16,504 | 1 |
| ผลต่าง | +16,384 | 0 |

โปรแกรมรายงาน delta จาก `getrusage` เป็น minor +16,384 และ major 0
ในรอบนี้

### TC-05: Major page faults

#### รอบเดิมบน commit `6d67aff`

ทดสอบ PID `47219` ด้วย `test_major` ที่ commit
`6d67aff40f37e82578080eacdde7b535607b425f`

| ช่วง | Minor faults | Major faults |
|---|---:|---:|
| ก่อน scan | 378 | 1 |
| หลัง scan | 1,402 | 1 |
| ผลต่าง | +1,024 | 0 |

ค่า module ตรงกับ `/proc/47219/stat` ในรอบที่อ่าน และ delta ตรงกับ
`getrusage` แต่เนื่องจาก major faults ไม่เพิ่ม รอบนี้จึง **ยังไม่ได้
สาธิตการเกิด major fault ระหว่าง scan** ไม่ถือว่าผล 0 เป็นความผิดพลาด
ของ module

#### ผลทดสอบซ้ำบน commit `558822d`

ทดสอบวันที่ 27 พฤศจิกายน 2026 บน Ubuntu ใน UTM โดยใช้ filesystem `ext4`
และ page size 4,096 bytes ที่ commit `558822db030a670c89c1593f8dff4817511b06db`
โปรแกรม `test_major` ใช้ PID `48242` และ file-backed mapping ขนาด 64 MiB

| ช่วง | Minor faults สะสม | Major faults สะสม |
|---|---:|---:|
| ก่อน scan | 379 | 0 |
| หลัง scan | 379 | 16,384 |

ค่า cumulative จาก `vm_monitor` ตรงกับ `/proc/48242/stat` ทั้งก่อนและหลัง
scan ส่วน `getrusage()` รายงาน delta เป็น minor 0 และ major +16,384
หลังโปรแกรมจบ ไฟล์ชั่วคราวถูกลบและ module ไม่ได้โหลดค้าง

การนำข้อมูลออกจาก page cache เป็น best effort จำนวน faults อาจต่างกัน
ในแต่ละรอบ และ major faults อาจไม่เพิ่มแม้รันบน `ext4`

### TC-08 และ TC-09: Threads

- TC-08: PID `47374` มี 4 threads; module และ `/proc` ก่อนโหลดแสดง
  minor 1,571 และ major 0
- TC-09: PID `47424` หลัง workers จบเหลือ 1 thread; module และ `/proc`
  ก่อนโหลดแสดง minor 10,447 และ major 0

ภาพที่เก็บไว้แสดงค่า `/proc` ก่อนโหลด ไม่ได้แสดงค่า `/proc` หลังโหลด
สำหรับสองกรณีนี้

## ขอบเขตและข้อจำกัด

- ผลรอบเดิมอ้างอิง `6d67aff` ส่วนผลบน `558822d` ครอบคลุมเฉพาะ TC-05
- ค่าใน module และ `/proc` อ่านคนละเวลา จึงอาจเปลี่ยนระหว่างการตรวจ
- ทดสอบ module โดยตรง ไม่ได้ยืนยันการทำงานของ CLI wrapper
- การ review พบปัญหาใน CLI ที่รวมอยู่ใน `6d67aff` และยังต้องยืนยันการทำงาน
  ร่วมกับ module ผลทดสอบซ้ำ TC-05 ไม่มีหลักฐานการทดสอบ CLI
- ยังไม่ได้ทดสอบอย่างเป็นระบบขณะ process หรือ thread กำลังจบ
- เครื่อง x86_64 อาจแสดง `[vsyscall]` ใน `maps` ซึ่งต้องพิจารณาแยก
  ก่อนเปรียบเทียบกับ ordinary VMA
- ควรทดสอบส่วนที่ได้รับผลกระทบซ้ำ หากโค้ดเปลี่ยนหลัง commit ที่ใช้ทดสอบกรณีนั้น

## หลักฐานภาพ

ภาพ screenshot และคำอธิบายเพิ่มเติมอยู่ในเอกสารผลทดสอบที่แชร์กับทีม : https://docs.google.com/document/d/1-nkV2W4ujUgjfuMktLRnwa6v0qOtUUA2DIKefUxi4u8/edit?tab=t.eabk1n6hvyy9
