#include "MainThreadStack.h"

#include <execinfo.h>
#include <mach/mach.h>

#if defined(__arm64__)
#include <mach/arm/thread_status.h>
#elif defined(__x86_64__)
#include <mach/i386/thread_status.h>
#endif

int mosaic_capture_thread_stack(thread_t thread,
                                void **frames,
                                int max_frames) {
    if (max_frames <= 0 || frames == NULL) return 0;

    // Suspend the target thread, read register state, walk the frame chain
    // (all reads from the suspended thread's stack — safe), then resume.
    // backtrace_from_fp doesn't allocate, so doing it under suspension is OK
    // and avoids the race where the resumed thread pops frames out from
    // under our walker.
    if (thread_suspend(thread) != KERN_SUCCESS) return 0;

    void *fp = NULL;
    void *pc = NULL;

#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr == KERN_SUCCESS) {
        fp = (void *)__darwin_arm_thread_state64_get_fp(state);
        pc = (void *)__darwin_arm_thread_state64_get_pc(state);
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, x86_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr == KERN_SUCCESS) {
        fp = (void *)state.__rbp;
        pc = (void *)state.__rip;
    }
#endif

    int written = 0;
    if (fp != NULL) {
        if (pc != NULL && max_frames > 0) {
            frames[0] = pc;
            written = 1;
        }
        if (max_frames > written) {
            int more = backtrace_from_fp(fp, frames + written, max_frames - written);
            if (more > 0) written += more;
        }
    }

    thread_resume(thread);
    return written;
}
