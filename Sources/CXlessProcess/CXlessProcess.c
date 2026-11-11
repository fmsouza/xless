#include "CXlessProcess.h"
#include <sys/resource.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

int xless_disable_core_dumps(void) {
    struct rlimit none = { 0, 0 };
    int result = setrlimit(RLIMIT_CORE, &none);
#ifdef __linux__
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) result = -1;
#endif
    return result;
}

long long xless_core_file_limit(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_CORE, &limit) != 0 || limit.rlim_cur == RLIM_INFINITY) return -1;
    return (long long)limit.rlim_cur;
}

int xless_dumpable(void) {
#ifdef __linux__
    return prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
#else
    return -1;
#endif
}
