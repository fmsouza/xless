#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE // explicit_bzero, syscall
#endif
#if defined(__APPLE__)
#define __STDC_WANT_LIB_EXT1__ 1 // memset_s
#endif
#include "CXlessProcess.h"
#include <errno.h>
#include <string.h>
#include <sys/resource.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>
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

void xless_secure_zero(void *bytes, size_t length) {
    if (bytes == NULL || length == 0) return;
#if defined(__APPLE__)
    memset_s(bytes, length, 0, length);
#elif defined(__linux__)
    explicit_bzero(bytes, length);
#else
    volatile unsigned char *p = bytes;
    while (length--) *p++ = 0;
#endif
}

// keyctl(2) operations (linux/keyctl.h, not every sysroot ships it).
#define XLESS_KEYCTL_GET_KEYRING_ID 0
#define XLESS_KEYCTL_REVOKE 3
#define XLESS_KEYCTL_SETPERM 5
#define XLESS_KEYCTL_DESCRIBE 6
#define XLESS_KEYCTL_SEARCH 10
#define XLESS_KEYCTL_READ 11
#define XLESS_KEYCTL_SET_TIMEOUT 15

#if defined(__linux__) && defined(SYS_add_key) && defined(SYS_keyctl)
long xless_key_add(const char *description, const void *payload, size_t length, int32_t keyring) {
    return syscall(SYS_add_key, "user", description, payload, length, keyring);
}
long xless_key_search(int32_t keyring, const char *description) {
    return syscall(SYS_keyctl, XLESS_KEYCTL_SEARCH, keyring, "user", description, 0);
}
long xless_key_read(int32_t key, void *buffer, size_t length) {
    return syscall(SYS_keyctl, XLESS_KEYCTL_READ, key, buffer, length);
}
long xless_key_revoke(int32_t key) {
    return syscall(SYS_keyctl, XLESS_KEYCTL_REVOKE, key);
}
long xless_key_set_timeout(int32_t key, unsigned int seconds) {
    return syscall(SYS_keyctl, XLESS_KEYCTL_SET_TIMEOUT, key, seconds);
}
long xless_key_setperm(int32_t key, uint32_t permissions) {
    return syscall(SYS_keyctl, XLESS_KEYCTL_SETPERM, key, permissions);
}
long xless_key_describe(int32_t key, char *buffer, size_t length) {
    return syscall(SYS_keyctl, XLESS_KEYCTL_DESCRIBE, key, buffer, length);
}
long xless_key_keyring_id(int32_t keyring) {
    return syscall(SYS_keyctl, XLESS_KEYCTL_GET_KEYRING_ID, keyring, 0);
}
#else
static long xless_no_keyring(void) { errno = ENOSYS; return -1; }
long xless_key_add(const char *d, const void *p, size_t l, int32_t k) { (void)d; (void)p; (void)l; (void)k; return xless_no_keyring(); }
long xless_key_search(int32_t k, const char *d) { (void)k; (void)d; return xless_no_keyring(); }
long xless_key_read(int32_t k, void *b, size_t l) { (void)k; (void)b; (void)l; return xless_no_keyring(); }
long xless_key_revoke(int32_t k) { (void)k; return xless_no_keyring(); }
long xless_key_set_timeout(int32_t k, unsigned int s) { (void)k; (void)s; return xless_no_keyring(); }
long xless_key_setperm(int32_t k, uint32_t p) { (void)k; (void)p; return xless_no_keyring(); }
long xless_key_describe(int32_t k, char *b, size_t l) { (void)k; (void)b; (void)l; return xless_no_keyring(); }
long xless_key_keyring_id(int32_t k) { (void)k; return xless_no_keyring(); }
#endif
