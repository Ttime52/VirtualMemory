# Page Fault และ Kernel Tracepoints (Issue #5)

เอกสารนี้สรุปความรู้ที่ใช้ออกแบบส่วนนับ page fault ของ `vm_monitor`
และเหตุผลที่เลือกอ่าน counter ของ kernel แทนการใช้ tracepoint

## 1. Page fault คืออะไร

Linux ใช้ **demand paging** คือเมื่อ process จองหน่วยความจำ (เช่น `mmap` หรือ `malloc`)
kernel จะสร้างแค่ VMA (ช่วง address ที่ใช้ได้) แต่ยังไม่จัดสรร physical page ให้จริง
page จะถูกจัดสรรตอนที่ process แตะ address นั้นครั้งแรก ตอนนั้น CPU จะหา mapping
ใน page table ไม่เจอ แล้วเกิด **page fault** ให้ kernel เข้ามาจัดการ

| ประเภท | ความหมาย | ตัวอย่าง | ต้องอ่าน disk |
|---|---|---|---|
| **Minor fault** | page ที่ต้องการมีอยู่ในหน่วยความจำแล้ว หรือสร้างได้ทันที kernel แค่ต้องเพิ่ม mapping ใน page table | แตะหน่วยความจำ anonymous ครั้งแรก (ได้ page ศูนย์ใหม่), อ่านไฟล์ที่อยู่ใน page cache อยู่แล้ว, copy-on-write หลัง `fork()` | ไม่ต้อง |
| **Major fault** | page ไม่อยู่ในหน่วยความจำ ต้องอ่านจาก storage ก่อน | อ่านไฟล์ผ่าน `mmap` ที่ไม่อยู่ใน page cache, อ่าน page ที่ถูก swap ออกไป | ต้อง (ช้ากว่ามาก) |

## 2. Kernel นับ page fault ไว้ที่ไหน

ทุกครั้งที่จัดการ page fault เสร็จ kernel เรียก `mm_account_fault()` ใน `mm/memory.c`
ซึ่งเพิ่มค่าให้ thread ที่เกิด fault:

- `task_struct->min_flt` สำหรับ minor fault
- `task_struct->maj_flt` สำหรับ major fault

ค่าเหล่านี้เป็นของ **แต่ละ thread** เมื่อ thread จบ kernel จะย้ายค่าไปสะสมไว้ที่
`signal_struct->min_flt` และ `signal_struct->maj_flt` ซึ่งใช้ร่วมกันทั้ง process
(ทำใน `__exit_signal()` ภายใต้ `signal->stats_lock`)

ดังนั้นค่ารวมของทั้ง process คือ:

```
ค่าใน signal_struct (threads ที่จบไปแล้ว) + ผลรวมของ threads ที่ยังทำงานอยู่
```

ซึ่งเป็นวิธีเดียวกับที่ kernel ใช้คำนวณ field 10 (minflt) และ field 12 (majflt)
ของ `/proc/<pid>/stat` ค่าจาก module จึงต้องตรงกับ `/proc` พอดี

## 3. วิธีที่ module ใช้

`read_fault_counts()` ใน `kernel/vm_monitor.c`:

1. `rcu_read_lock()` เพื่อให้วนรายชื่อ threads (`for_each_thread`) ได้ปลอดภัย
2. ถือ `signal->stats_lock` เพื่อไม่ให้ thread ที่กำลังจบถูกนับซ้ำหรือนับตก
   (ตอน thread จบ kernel ย้ายค่าไปที่ signal ภายใต้ lock เดียวกัน)
3. เช็ก `pid_alive(task)` ก่อนวน threads ถ้า task ถูกถอดออกจากระบบแล้ว ใช้แค่ค่าใน signal
4. ใช้ `scoped_seqlock_read()` บน kernel รุ่นใหม่ และ `read_seqbegin_or_lock_irqsave()` บน kernel รุ่นเก่าที่ยังไม่มี API นี้

ค่าที่ได้เป็น **ยอดสะสมตั้งแต่ process เริ่มทำงาน** และ `/proc/vm_monitor`
แสดงเพิ่มว่า **เพิ่มขึ้นเท่าไรตั้งแต่เขียน PID** (เก็บค่าตั้งต้นไว้ตอนเขียน PID)

## 4. Tracepoint ตาม hint ของโจทย์

`include/trace/events/exceptions.h` ประกาศ tracepoint 2 ตัว:

- `page_fault_user` สำหรับ fault ที่เกิดจาก user space
- `page_fault_kernel` สำหรับ fault ที่เกิดใน kernel

tracepoint ทั้งสองถูกเรียกในโค้ดจัดการ page fault ของสถาปัตยกรรม x86
(`arch/x86/mm/fault.c`) จึงมีให้ใช้บนเครื่อง x86_64 แต่สถาปัตยกรรมอื่น
เช่น arm64 (ARM64) ไม่ได้เรียก tracepoint นี้

ตรวจบนเครื่องได้ด้วย:

```bash
sudo ls /sys/kernel/tracing/events/exceptions/
```

ผลที่ทีมได้:

| เครื่อง | สถาปัตยกรรม | ผล |
|---|---|---|
| QEMU, kernel 7.0.0-44-generic | x86_64 | มี `page_fault_kernel` และ `page_fault_user` |
| UTM บน Mac, kernel 7.0.0-31-generic | aarch64 | [ใส่ผล `sudo ls /sys/kernel/tracing/events/exceptions/` จากเครื่อง UTM] |

ข้อจำกัดของ tracepoint เพิ่มเติม:

- ไม่บอกว่าเป็น minor หรือ major เพราะ tracepoint ถูกเรียกตอนเริ่มจัดการ fault ก่อนรู้ผล
- นับได้เฉพาะช่วงที่ module เปิด probe อยู่ ไม่มียอดย้อนหลัง

## 5. สรุปเหตุผลที่เลือกอ่าน counter

| | อ่าน counter (`min_flt`/`maj_flt`) | Tracepoint `page_fault_user` |
|---|---|---|
| ทำงานบน x86_64 และ arm64 | ✅ | ❌ เฉพาะ x86 |
| แยก minor / major | ✅ | ❌ |
| มียอดตั้งแต่ process เริ่ม | ✅ | ❌ |
| ตรวจสอบกับ `/proc/<pid>/stat` ได้ตรง | ✅ | ไม่ได้โดยตรง |
| ภาระต่อระบบ | อ่านครั้งเดียวตอนขอผล | ทำงานทุก page fault ทั้งระบบ |

ทีมจึงอ่าน counter ที่ kernel เก็บไว้ ซึ่งตรงกับโจทย์ที่ต้องแยก minor และ major
และใช้ได้กับทุกเครื่องของสมาชิก

## 6. ทำไมรอบแรกของ TC-05 ไม่เกิด major fault

ผลทดสอบรอบแรกบน UTM (`docs/testing/test-results-utm.md`) ได้ minor +1,024 และ major +0
ทั้งที่อ่านไฟล์ 64 MiB (16,384 pages) สาเหตุคือไฟล์ชั่วคราวอยู่ใน `/tmp`
ซึ่ง Ubuntu รุ่นใหม่ mount เป็น **tmpfs** ข้อมูลของ tmpfs อยู่ใน RAM ตลอด
kernel ทิ้งออกจาก memory ไม่ได้ (`POSIX_FADV_DONTNEED` ไม่มีผล) จึงไม่มีการอ่านจาก disk

ตัวเลข 1,024 มาจาก **fault-around**: เมื่อเกิด fault บน file-backed mapping ที่ข้อมูลอยู่ใน memory
แล้ว kernel จะ map pages ข้างเคียงให้ทีเดียว (ค่าเริ่มต้น 64 KiB = 16 pages)
จึงเกิด fault แค่ 16,384 ÷ 16 = 1,024 ครั้ง

ทีมยืนยันสาเหตุด้วยการเขียนไฟล์ แล้ว fadvise DONTNEED และ mmap อ่าน โดยไม่ใช้ `drop_caches` (kernel 7.0.0-44, QEMU):

| Filesystem | Minor | Major |
|---|---:|---:|
| ext4 | +0 | +16,384 |
| tmpfs | +1,025 | +0 |

หลังย้ายไฟล์ไปไว้ในโฟลเดอร์ปัจจุบันบน ext4 (PR #6) การทดสอบซ้ำบน UTM ได้ major +16,384 ตรงกับ `/proc` (PR #7)

## 7. วิธีตรวจสอบผลเพิ่มเติม

นอกจาก `/proc/<pid>/stat` แล้ว ใช้ `perf` เทียบได้ (ใช้ได้ทั้ง x86 และ arm64):

```bash
sudo perf stat -e minor-faults,major-faults -p <PID> -- sleep 10
```

## อ้างอิง

- Process Addresses: https://docs.kernel.org/mm/process_addrs.html
- Kernel Tracepoints: https://docs.kernel.org/trace/tracepoints.html
- `include/trace/events/exceptions.h`, `mm/memory.c` (`mm_account_fault`),
  `kernel/exit.c` (`__exit_signal`), `fs/proc/array.c` (`do_task_stat`)
