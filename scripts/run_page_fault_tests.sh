#!/usr/bin/env bash
#
# run_page_fault_tests.sh
#
# รันโปรแกรมทดสอบใน tests/ (test_vma, test_minor, test_major) คู่กับ
# kernel module vm_monitor แล้วเทียบค่าทั้ง 4 กับ /proc แบบอัตโนมัติ
#
# วิธีใช้ (รันจาก root ของ repo VirtualMemory):
#   chmod +x scripts/run_page_fault_tests.sh
#   ./scripts/run_page_fault_tests.sh
#
# ผลลัพธ์: แสดงบนจอ และบันทึกเป็น tests/results-<วันเวลา>.md
#
# ตัวเลือก:
#   VM_DRY=1 ./scripts/run_page_fault_tests.sh   ทดลองโดยไม่โหลด module (อ่านแค่ /proc)

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$ROOT/kernel/vm_monitor.ko"
OUT="$ROOT/tests/results-$(date +%Y%m%d-%H%M%S).md"
WORK="$(mktemp -d)"
DRY="${VM_DRY:-0}"
PROG_PID=""
LOG=""

cleanup() {
    exec 3>&- 2>/dev/null
    if [ -n "$PROG_PID" ]; then
        kill "$PROG_PID" 2>/dev/null
    fi
    if [ "$DRY" != "1" ]; then
        sudo rmmod vm_monitor 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

say() {
    # แสดงบนจอและเขียนลงไฟล์ผล
    echo "$*" | tee -a "$OUT"
}

tidy() {
    # ตัดข้อความ "Press Enter to continue... " และช่องว่างหน้าบรรทัด แล้วทำเป็น bullet
    sed 's/^Press Enter to continue\.\.\. //; s/^ *//; s/^/  - /'
}

mark() {
    if [ "$1" = "$2" ]; then echo "✅"; else echo "❌"; fi
}

# ---------- ควบคุมโปรแกรมทดสอบ (กด Enter แทนคน) ----------

start_prog() {
    rm -f "$WORK/in"
    mkfifo "$WORK/in"
    LOG="$WORK/$(basename "$1").log"
    : > "$LOG"
    "$1" < "$WORK/in" > "$LOG" 2>&1 &
    PROG_PID=$!
    exec 3> "$WORK/in"
}

wait_for() {
    local i
    for i in $(seq 1 600); do
        if grep -qF "$1" "$LOG"; then
            return 0
        fi
        if ! kill -0 "$PROG_PID" 2>/dev/null; then
            echo "โปรแกรมจบก่อนเจอข้อความ: $1"
            cat "$LOG"
            return 1
        fi
        sleep 0.2
    done
    echo "รอนานเกินไป: $1"
    return 1
}

press_enter() {
    echo >&3
}

finish_prog() {
    exec 3>&-
    wait "$PROG_PID" 2>/dev/null
    PROG_PID=""
}

# ---------- อ่านค่าจาก module และ /proc ----------

proc_values() {
    # พิมพ์: regions bytes minflt majflt (ไม่นับ [vsyscall] ซึ่งไม่ใช่ VMA ปกติ)
    python3 -c '
import sys
pid = sys.argv[1]
n = 0
s = 0
for line in open(f"/proc/{pid}/maps"):
    if "[vsyscall]" in line:
        continue
    a, b = line.split()[0].split("-")
    n += 1
    s += int(b, 16) - int(a, 16)
st = open(f"/proc/{pid}/stat").read()
f = st[st.rfind(")") + 2:].split()
print(n, s, f[7], f[9])
' "$1"
}

module_values() {
    # โหลด module กับ PID แล้วดึงค่าจาก dmesg พิมพ์: regions bytes minflt majflt
    local pid=$1 tag lines
    tag="vmtest-$(date +%s%N)"
    sudo rmmod vm_monitor 2>/dev/null
    echo "$tag" | sudo tee /dev/kmsg > /dev/null
    if ! sudo insmod "$MODULE" pid="$pid"; then
        echo "insmod ล้มเหลว" >&2
        return 1
    fi
    lines=$(sudo dmesg | sed -n "/$tag/,\$p" | grep 'vm_monitor:')
    sudo rmmod vm_monitor
    echo "$lines" >> "$WORK/dmesg.txt"
    echo "$(echo "$lines" | sed -n 's/.*memory regions = \([0-9]*\).*/\1/p')" \
         "$(echo "$lines" | sed -n 's/.*address space = \([0-9]*\) bytes.*/\1/p')" \
         "$(echo "$lines" | sed -n 's/.*minor page faults = \([0-9]*\).*/\1/p')" \
         "$(echo "$lines" | sed -n 's/.*major page faults = \([0-9]*\).*/\1/p')"
}

snapshot() {
    # $1 = ชื่อจังหวะ  ผลเก็บไว้ใน S_MIN / S_MAJ สำหรับคำนวณส่วนต่าง
    local label=$1 mr mb mmin mmaj pr pb pmin pmaj
    read -r pr pb pmin pmaj < <(proc_values "$PROG_PID")
    if [ "$DRY" = "1" ]; then
        mr=$pr; mb=$pb; mmin=$pmin; mmaj=$pmaj
    else
        read -r mr mb mmin mmaj < <(module_values "$PROG_PID") || return 1
        # อ่าน /proc ซ้ำหลัง module เพื่อให้เป็นจังหวะเดียวกัน (process หยุดรอ Enter อยู่)
        read -r pr pb pmin pmaj < <(proc_values "$PROG_PID")
    fi
    say "| $label | $mr / $pr $(mark "$mr" "$pr") | $mb / $pb $(mark "$mb" "$pb") | $mmin / $pmin $(mark "$mmin" "$pmin") | $mmaj / $pmaj $(mark "$mmaj" "$pmaj") |"
    S_MIN=$mmin
    S_MAJ=$mmaj
}

table_header() {
    say ""
    say "| จังหวะ | Regions (module / maps) | Virtual bytes (module / maps) | Minor (module / stat) | Major (module / stat) |"
    say "|---|---|---|---|---|"
}

# ---------- เริ่มทดสอบ ----------

if [ "$DRY" != "1" ]; then
    echo "ต้องใช้ sudo สำหรับโหลด module และอ่าน dmesg"
    sudo -v || exit 1
fi

echo "== Build"
make -C "$ROOT/tests" > /dev/null || { echo "build tests ไม่ผ่าน"; exit 1; }
if [ "$DRY" != "1" ]; then
    make -C "$ROOT/kernel" > /dev/null || { echo "build module ไม่ผ่าน"; exit 1; }
fi

: > "$OUT"
say "# ผลทดสอบ vm_monitor กับโปรแกรมทดสอบ"
say ""
say "- วันที่: $(date '+%Y-%m-%d %H:%M:%S')"
say "- Kernel: $(uname -r) ($(uname -m))"
say "- Page size: $(getconf PAGESIZE) bytes"
if [ "$DRY" = "1" ]; then
    say "- โหมด: DRY RUN (ไม่ได้โหลด module ค่า module = ค่า /proc)"
fi
if sudo test -d /sys/kernel/tracing/events/exceptions 2>/dev/null; then
    say "- Tracepoint exceptions: มี ($(sudo ls /sys/kernel/tracing/events/exceptions | tr '\n' ' '))"
else
    say "- Tracepoint exceptions: ไม่มีบนเครื่องนี้"
fi
say ""
say "รูปแบบในตาราง: ค่าจาก module / ค่าจาก /proc  (✅ = ตรงกัน)"
say "หมายเหตุ: จำนวน regions จาก maps ไม่นับ [vsyscall]"

# 1) test_vma
say ""
say "## 1. test_vma (VMA และ virtual address space)"
start_prog "$ROOT/tests/test_vma"
table_header
wait_for "Before mmap()" && snapshot "ก่อน mmap 16 MiB"
press_enter
wait_for "After mmap()" && snapshot "หลัง mmap 16 MiB"
press_enter
wait_for "After munmap()" && snapshot "หลัง munmap"
press_enter
finish_prog

# 2) test_minor
say ""
say "## 2. test_minor (minor page faults)"
start_prog "$ROOT/tests/test_minor"
table_header
wait_for "Before touching pages" && snapshot "ก่อนแตะ page"
B_MIN=$S_MIN
press_enter
wait_for "After page accesses" && snapshot "หลังแตะทุก page"
say ""
say "- Minor faults ที่เพิ่มขึ้นตาม module: $((S_MIN - B_MIN))"
say "- ผลจากโปรแกรม (getrusage):"
grep -E 'Touched|minor faults:|major faults:' "$LOG" | tidy | tee -a "$OUT"
press_enter
finish_prog

# 3) test_major
say ""
say "## 3. test_major (major page faults)"
start_prog "$ROOT/tests/test_major"
table_header
wait_for "Before scanning the mapping" || exit 1
# ไม่ใช้ drop_caches: test_major ไล่ไฟล์ออกจาก page cache เองด้วย
# posix_fadvise(DONTNEED) บนไฟล์ในโฟลเดอร์ปัจจุบัน (ext4) ตาม PR #6
snapshot "ก่อนอ่านไฟล์"
B_MAJ=$S_MAJ
press_enter
wait_for "After scanning" && snapshot "หลังอ่านไฟล์ทุก page"
say ""
say "- Major faults ที่เพิ่มขึ้นตาม module: $((S_MAJ - B_MAJ))"
say "- ผลจากโปรแกรม (getrusage):"
grep -E 'Read [0-9]+ pages|minor faults:|major faults:|Major page faults were|No major page fault' "$LOG" \
    | tidy | tee -a "$OUT"
press_enter
finish_prog

# เก็บข้อความ dmesg ดิบไว้ท้ายไฟล์
if [ -s "$WORK/dmesg.txt" ]; then
    say ""
    say "## dmesg จาก module"
    say '```'
    cat "$WORK/dmesg.txt" | tee -a "$OUT"
    say '```'
fi

echo ""
echo "เสร็จแล้ว บันทึกผลไว้ที่: $OUT"
