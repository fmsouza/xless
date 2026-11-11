#ifndef CXLESS_PROCESS_H
#define CXLESS_PROCESS_H

/// Sets RLIMIT_CORE to 0 and, on Linux, marks the process non-dumpable (PR_SET_DUMPABLE 0: no core file, no same-user
/// ptrace or /proc/<pid>/mem). Returns 0 when both took effect. prctl is variadic, so Swift cannot call it directly.
int xless_disable_core_dumps(void);

/// The soft RLIMIT_CORE, or -1 for unlimited or on error.
long long xless_core_file_limit(void);

/// PR_GET_DUMPABLE on Linux (0 or 1); -1 elsewhere.
int xless_dumpable(void);

#endif
