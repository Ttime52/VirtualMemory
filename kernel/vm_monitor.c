#include <linux/init.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/pid.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/sched/signal.h>
#include <linux/sched/task.h>
#include <linux/mm.h>
#include <linux/rcupdate.h>
#include <linux/seqlock.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/mutex.h>
#include <linux/kernel.h>

#define PROC_NAME "vm_monitor"

/*
 * pid ตอนโหลดโมดูลเป็นตัวเลือก (ไม่บังคับ)
 * - ถ้าระบุ: ต้องเป็น PID ที่ถูกต้อง (ถ้าผิดจะไม่โหลดโมดูล เหมือนเดิม)
 *   แสดงสรุปใน kernel log ทันที และตั้งเป็น PID ที่ monitor
 * - ถ้าไม่ระบุเลย: โหลดได้ แล้วเขียน PID ทีหลังผ่าน /proc/vm_monitor
 * pid_given แยกกรณี "ไม่ระบุ" ออกจาก "ระบุ pid=-1" ซึ่งยังต้องถูกปฏิเสธ
 */
static int pid = -1;
static bool pid_given;

static int pid_param_set(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_int(val, kp);

    if (!ret)
        pid_given = true;
    return ret;
}

static const struct kernel_param_ops pid_param_ops = {
    .set = pid_param_set,
    .get = param_get_int,
};

module_param_cb(pid, &pid_param_ops, &pid, 0444);
MODULE_PARM_DESC(pid, "PID to report at load time (optional, see /proc/vm_monitor)");

struct vm_stats {
    char comm[TASK_COMM_LEN];
    u64 start_time;               /* ใช้ตรวจว่า PID ถูกนำไปใช้ซ้ำหรือไม่ */
    unsigned long region_count;
    unsigned long long total_bytes;
    unsigned long minor_faults;
    unsigned long major_faults;
};

/* สถานะของ /proc/vm_monitor ป้องกันด้วย monitor_lock */
static DEFINE_MUTEX(monitor_lock);
static int target_pid = -1;
static u64 target_start_time;
static unsigned long base_minor;
static unsigned long base_major;

static struct proc_dir_entry *proc_entry;

/*
 * รวม page faults ของทั้ง process:
 * - signal->min_flt / maj_flt คือค่าที่สะสมไว้จาก threads ที่จบไปแล้ว
 * - บวกค่าของ threads ที่ยังอยู่ใน thread group
 * stats_lock กันไม่ให้ thread ที่กำลังจบถูกนับซ้ำหรือนับตก
 * เพราะตอน thread จบ kernel ย้ายค่าไปที่ signal ภายใต้ lock เดียวกัน
 */
static void read_fault_counts(struct task_struct *task,
                              unsigned long *minor, unsigned long *major)
{
    struct signal_struct *sig = task->signal;
    struct task_struct *thread;
    unsigned long min_flt = 0;
    unsigned long maj_flt = 0;

    rcu_read_lock();

#ifdef scoped_seqlock_read
    scoped_seqlock_read (&sig->stats_lock, ss_lock_irqsave) {
        min_flt = READ_ONCE(sig->min_flt);
        maj_flt = READ_ONCE(sig->maj_flt);

        /* ถ้า task ถูกถอดออกจากระบบแล้ว รายชื่อ threads ใช้ไม่ได้ */
        if (pid_alive(task)) {
            for_each_thread(task, thread) {
                min_flt += READ_ONCE(thread->min_flt);
                maj_flt += READ_ONCE(thread->maj_flt);
            }
        }
    }
#else
    /* สำหรับ kernel รุ่นเก่าที่ยังไม่มี scoped_seqlock_read */
    {
        unsigned long flags;
        int seq = 0;

retry:
        flags = read_seqbegin_or_lock_irqsave(&sig->stats_lock, &seq);
        min_flt = READ_ONCE(sig->min_flt);
        maj_flt = READ_ONCE(sig->maj_flt);

        if (pid_alive(task)) {
            for_each_thread(task, thread) {
                min_flt += READ_ONCE(thread->min_flt);
                maj_flt += READ_ONCE(thread->maj_flt);
            }
        }

        if (need_seqretry(&sig->stats_lock, seq)) {
            seq = 1;
            goto retry;
        }
        done_seqretry_irqrestore(&sig->stats_lock, seq, flags);
    }
#endif

    rcu_read_unlock();

    *minor = min_flt;
    *major = maj_flt;
}

/* เก็บข้อมูลทั้ง 4 ค่าของ process ที่ระบุ คืนค่า 0 ถ้าสำเร็จ */
static int collect_stats(int nr, struct vm_stats *st)
{
    struct pid *pid_struct;
    struct task_struct *task;
    struct mm_struct *mm;
    struct vm_area_struct *vma;

    if (nr <= 0)
        return -EINVAL;

    pid_struct = find_get_pid(nr);
    if (!pid_struct)
        return -ESRCH;

    task = get_pid_task(pid_struct, PIDTYPE_PID);
    put_pid(pid_struct);
    if (!task)
        return -ESRCH;

    get_task_comm(st->comm, task);
    st->start_time = task->start_time;

    /* อ่าน page faults ก่อน ไม่ต้องถือ mmap lock ระหว่างนี้ */
    read_fault_counts(task, &st->minor_faults, &st->major_faults);

    mm = get_task_mm(task);
    if (!mm) {
        put_task_struct(task);
        return -EINVAL;
    }

    st->region_count = 0;
    st->total_bytes = 0;

    /* ล็อก address space ระหว่างนับ VMA เพื่อไม่ให้ข้อมูลเปลี่ยนกลางทาง */
    mmap_read_lock(mm);
    {
        VMA_ITERATOR(vmi, mm, 0);

        for_each_vma(vmi, vma) {
            st->region_count++;
            st->total_bytes += vma->vm_end - vma->vm_start;
        }
    }
    mmap_read_unlock(mm);

    mmput(mm);
    put_task_struct(task);
    return 0;
}

static void print_error(int nr, int err)
{
    if (err == -ESRCH)
        pr_err("vm_monitor: PID %d was not found\n", nr);
    else if (nr <= 0)
        pr_err("vm_monitor: please provide a valid PID\n");
    else
        pr_err("vm_monitor: PID %d has no accessible user address space\n",
               nr);
}

static void set_target(int nr, const struct vm_stats *st)
{
    mutex_lock(&monitor_lock);
    target_pid = nr;
    target_start_time = st->start_time;
    base_minor = st->minor_faults;
    base_major = st->major_faults;
    mutex_unlock(&monitor_lock);
}

/* ---------- /proc/vm_monitor ---------- */

static int vm_proc_show(struct seq_file *m, void *v)
{
    struct vm_stats st;
    int nr;
    u64 start_time;
    unsigned long bmin;
    unsigned long bmaj;
    int ret;

    mutex_lock(&monitor_lock);
    nr = target_pid;
    start_time = target_start_time;
    bmin = base_minor;
    bmaj = base_major;
    mutex_unlock(&monitor_lock);

    if (nr <= 0) {
        seq_puts(m, "No PID is being monitored.\n");
        seq_puts(m, "Usage: echo <PID> | sudo tee /proc/" PROC_NAME "\n");
        return 0;
    }

    ret = collect_stats(nr, &st);
    if (ret) {
        seq_printf(m, "PID %d is no longer available (error %d).\n", nr, ret);
        return 0;
    }

    if (st.start_time != start_time) {
        seq_printf(m, "PID %d now belongs to a different process; "
                   "write the PID again.\n", nr);
        return 0;
    }

    seq_puts(m, "===== Virtual Memory Summary =====\n");
    seq_printf(m, "PID                         : %d (%s)\n", nr, st.comm);
    seq_printf(m, "Number of memory regions    : %lu\n", st.region_count);
    seq_printf(m, "Total virtual address space : %llu bytes (%llu KiB)\n",
               st.total_bytes, st.total_bytes >> 10);
    seq_printf(m, "Minor page faults (total)   : %lu\n", st.minor_faults);
    seq_printf(m, "Major page faults (total)   : %lu\n", st.major_faults);
    seq_puts(m, "---- since PID was set ----\n");
    seq_printf(m, "Minor page faults           : %lu\n", st.minor_faults - bmin);
    seq_printf(m, "Major page faults           : %lu\n", st.major_faults - bmaj);
    return 0;
}

static int vm_proc_open(struct inode *inode, struct file *file)
{
    return single_open(file, vm_proc_show, NULL);
}

/* เขียน PID เพื่อเริ่ม monitor และเก็บค่า page faults ตั้งต้นไว้คำนวณส่วนต่าง */
static ssize_t vm_proc_write(struct file *file, const char __user *buf,
                             size_t count, loff_t *ppos)
{
    struct vm_stats st;
    int nr;
    int ret;

    ret = kstrtoint_from_user(buf, count, 10, &nr);
    if (ret)
        return ret;

    ret = collect_stats(nr, &st);
    if (ret) {
        print_error(nr, ret);
        return ret;
    }

    set_target(nr, &st);
    pr_info("vm_monitor: now monitoring PID %d (%s)\n", nr, st.comm);
    return count;
}

static const struct proc_ops vm_proc_ops = {
    .proc_open    = vm_proc_open,
    .proc_read    = seq_read,
    .proc_lseek   = seq_lseek,
    .proc_release = single_release,
    .proc_write   = vm_proc_write,
};

/* ---------- module init / exit ---------- */

static int __init vm_monitor_init(void)
{
    struct vm_stats st;
    int ret;

    /* ถ้าระบุ pid ตอนโหลด ให้ตรวจก่อน ถ้าผิดจะไม่โหลดโมดูล (เหมือนเวอร์ชันเดิม) */
    if (pid_given) {
        ret = collect_stats(pid, &st);
        if (ret) {
            print_error(pid, ret);
            return ret;
        }
    }

    /* 0644: ทุกคนอ่านได้ แต่เขียน PID ได้เฉพาะ root */
    proc_entry = proc_create(PROC_NAME, 0644, NULL, &vm_proc_ops);
    if (!proc_entry) {
        pr_err("vm_monitor: failed to create /proc/%s\n", PROC_NAME);
        return -ENOMEM;
    }

    if (pid_given) {
        set_target(pid, &st);
        pr_info("vm_monitor: target PID = %d, process name = %s\n",
                pid, st.comm);
        pr_info("vm_monitor: number of memory regions = %lu\n",
                st.region_count);
        pr_info("vm_monitor: total virtual address space = %llu bytes\n",
                st.total_bytes);
        pr_info("vm_monitor: process minor page faults = %lu\n",
                st.minor_faults);
        pr_info("vm_monitor: process major page faults = %lu\n",
                st.major_faults);
    } else {
        pr_info("vm_monitor: loaded; write a PID to /proc/%s\n", PROC_NAME);
    }

    return 0;
}

static void __exit vm_monitor_exit(void)
{
    proc_remove(proc_entry);
    pr_info("vm_monitor: module removed\n");
}

module_init(vm_monitor_init);
module_exit(vm_monitor_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Virtual memory monitoring module");
MODULE_VERSION("0.2");
