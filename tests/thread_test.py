import os
import threading
import time

def worker():
    # จองหน่วยความจำแล้วแตะข้อมูล เพื่อให้ thread ใช้งาน pages
    data = bytearray(20 * 1024 * 1024)
    for i in range(0, len(data), 4096):
        data[i] = 1

    # ให้ thread อยู่ต่อ เพื่อให้เรามีเวลาตรวจ
    time.sleep(120)

print("Process PID:", os.getpid(), flush=True)

threads = []
for _ in range(3):
    thread = threading.Thread(target=worker)
    thread.start()
    threads.append(thread)

for thread in threads:
    thread.join()
