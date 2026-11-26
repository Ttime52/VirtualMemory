#include <linux/init.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/pid.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/mm.h>
#include <linux/sched/signal.h>
#include <linux/rcupdate.h>

static int pid = -1;

module_param(pid, int, 0444);
MODULE_PARM_DESC(pid, "PID of the process to monitor");

static int __init vm_monitor_init(void)
{
    struct pid *pid_struct;
    struct task_struct *thread;
    struct task_struct *task;
    struct mm_struct *mm;
    struct vm_area_struct *vma;
    unsigned long region_count = 0;
    unsigned long long total_bytes = 0;
    unsigned long minor_faults;
    unsigned long major_faults;
    unsigned int seq;

    if (pid <= 0) {
        pr_err("vm_monitor: please provide a valid PID\n");
        return -EINVAL;
    }

    pid_struct = find_get_pid(pid);
    if (!pid_struct) {
        pr_err("vm_monitor: PID %d was not found\n", pid);
        return -ESRCH;
    }

    task = get_pid_task(pid_struct, PIDTYPE_PID);
    put_pid(pid_struct);

    if (!task) {
        pr_err("vm_monitor: process for PID %d was not found\n", pid);
        return -ESRCH;
    }

    mm = get_task_mm(task);
    if (!mm) {
        pr_err("vm_monitor: PID %d has no accessible user address space\n",
               pid);
        put_task_struct(task);
        return -EINVAL;
    }

    /*
     * ล็อก address space ระหว่างอ่านข้อมูล VMA
     * เพื่อไม่ให้ข้อมูลเปลี่ยนระหว่างที่เรานับ
     */
    mmap_read_lock(mm);
    /*
     * รวม page faults ของ process:
     * - ค่าที่เก็บไว้สำหรับ threads ที่จบแล้ว
     * - ค่าจาก threads ที่ยังอยู่ใน thread group
     */
    rcu_read_lock();

    do {
        seq = read_seqbegin(&task->signal->stats_lock);

        minor_faults = READ_ONCE(task->signal->min_flt);
        major_faults = READ_ONCE(task->signal->maj_flt);

        for_each_thread(task, thread) {
            minor_faults += READ_ONCE(thread->min_flt);
            major_faults += READ_ONCE(thread->maj_flt);
        }

    } while (read_seqretry(&task->signal->stats_lock, seq));

    rcu_read_unlock();

    {
        VMA_ITERATOR(vmi, mm, 0);

        for_each_vma(vmi, vma) {
            region_count++;
            total_bytes += vma->vm_end - vma->vm_start;
        }
    }

    mmap_read_unlock(mm);

    pr_info("vm_monitor: target PID = %d, process name = %s\n",
            pid, task->comm);
    pr_info("vm_monitor: number of memory regions = %lu\n",
            region_count);
    pr_info("vm_monitor: total virtual address space = %llu bytes\n",
            total_bytes);
    pr_info("vm_monitor: process minor page faults = %lu\n",
            minor_faults);
    pr_info("vm_monitor: process major page faults = %lu\n",
            major_faults);
    mmput(mm);
    put_task_struct(task);

    return 0;
}

static void __exit vm_monitor_exit(void)
{
    pr_info("vm_monitor: module removed\n");
}

module_init(vm_monitor_init);
module_exit(vm_monitor_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Virtual memory monitoring module");
