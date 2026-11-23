#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE // explicit_bzero, syscall
#endif
#if defined(__APPLE__)
#define __STDC_WANT_LIB_EXT1__ 1 // memset_s
#endif
#include "CXlessProcess.h"
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/vfs.h>
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

long xless_key_join_new_session(void) {
    return syscall(SYS_keyctl, 1 /* KEYCTL_JOIN_SESSION_KEYRING */, (const char *)0);
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
long xless_key_join_new_session(void) { return xless_no_keyring(); }
#endif

int xless_is_memory_fs(const char *path) {
#ifdef __linux__
    struct statfs st;
    if (statfs(path, &st) != 0) return -1;
    unsigned long type = (unsigned long)st.f_type;
    return (type == 0x01021994UL /* TMPFS_MAGIC */ || type == 0x858458f6UL /* RAMFS_MAGIC */) ? 1 : 0;
#else
    (void)path;
    errno = ENOSYS;
    return -1;
#endif
}

static int cloexec_pipe(int fds[2]) {
    if (pipe(fds) != 0) return errno;
    for (int i = 0; i < 2; i++) {
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) != 0) {
            int e = errno;
            close(fds[0]);
            close(fds[1]);
            return e;
        }
    }
    return 0;
}

int xless_spawn_piped(const char *path, char *const argv[], char *const envp[], int *pid, int *in_fd, int *out_fd) {
    int in[2], out[2], e;
    if ((e = cloexec_pipe(in)) != 0) return e;
    if ((e = cloexec_pipe(out)) != 0) { close(in[0]); close(in[1]); return e; }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_adddup2(&actions, in[0], 0);
    posix_spawn_file_actions_adddup2(&actions, out[1], 1);
    sigset_t all, none;
    sigfillset(&all);
    sigdelset(&all, SIGKILL);
    sigdelset(&all, SIGSTOP);
    sigemptyset(&none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    pid_t child = 0;
    e = posix_spawn(&child, path, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(in[0]);
    close(out[1]);
    if (e != 0) { close(in[1]); close(out[0]); return e; }
    fcntl(in[1], F_SETFL, fcntl(in[1], F_GETFL) | O_NONBLOCK);
    fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL) | O_NONBLOCK);
    *pid = child;
    *in_fd = in[1];
    *out_fd = out[0];
    return 0;
}

long xless_write_nosigpipe(int fd, const void *bytes, size_t length) {
    sigset_t pipe_only, old;
    sigemptyset(&pipe_only);
    sigaddset(&pipe_only, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipe_only, &old);
    sigset_t pending;
    sigpending(&pending);
    int was_pending = sigismember(&pending, SIGPIPE);
    long n = (long)write(fd, bytes, length);
    int e = errno;
    if (n < 0 && e == EPIPE && !was_pending) {
        // Consume the SIGPIPE this write raised (it is pending on this thread, blocked) before unblocking.
        struct timespec zero = { 0, 0 };
#if defined(__APPLE__)
        int sig;
        sigpending(&pending);
        if (sigismember(&pending, SIGPIPE)) sigwait(&pipe_only, &sig);
#else
        while (sigtimedwait(&pipe_only, NULL, &zero) < 0 && errno == EINTR) {}
#endif
        (void)zero;
    }
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    errno = e;
    return n;
}

int xless_reap(int pid, int nohang, int *code) {
    int status = 0;
    pid_t r;
    do { r = waitpid((pid_t)pid, &status, nohang ? WNOHANG : 0); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    if (r == 0) return 0;
    if (WIFEXITED(status)) *code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) *code = 128 + WTERMSIG(status);
    else *code = -1;
    return 1;
}
