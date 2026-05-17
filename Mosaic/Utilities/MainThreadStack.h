#ifndef MOSAIC_MAIN_THREAD_STACK_H
#define MOSAIC_MAIN_THREAD_STACK_H

#include <mach/mach.h>

/// Walks the call stack of `thread` (must be paused-able from the caller)
/// and writes up to `max_frames` return addresses into `frames`.
///
/// The caller is responsible for ensuring `thread` is *not* the calling thread —
/// suspending self deadlocks. Returns the number of frames captured, or 0 on error.
/// The thread is suspended only briefly while reading register state; backtrace
/// walking happens after resume to minimise the suspension window.
int mosaic_capture_thread_stack(thread_t thread,
                                void **frames,
                                int max_frames);

#endif
