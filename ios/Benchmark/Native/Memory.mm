#import "OWSession.h"
#include <mach/mach.h>
#include <os/proc.h>

uint64_t OWFootprintBytes(void) {
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}
uint64_t OWAvailableMemoryBytes(void) { return os_proc_available_memory(); }

