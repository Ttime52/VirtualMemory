import os
import threading
import time

def worker():
    data = bytearray(20 * 1024 * 1024)
    for i in range(0, len(data), 4096):
        data[i] = 1

print("Process PID:", os.getpid(), flush=True)

threads = [threading.Thread(target=worker) for _ in range(3)]

for thread in threads:
    thread.start()

for thread in threads:
    thread.join()

print("Workers finished; main thread will wait for 120 seconds", flush=True)
time.sleep(120)
