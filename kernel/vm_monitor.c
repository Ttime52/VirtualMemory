#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Virtual Memory Monitor");
MODULE_VERSION("0.1");

static int __init vm_monitor_init(void)
{
    pr_info("vm_monitor: Module loaded successfully\n");
    return 0;
}

static void __exit vm_monitor_exit(void)
{
    pr_info("vm_monitor: Module unloaded successfully\n");
}

module_init(vm_monitor_init);
module_exit(vm_monitor_exit);