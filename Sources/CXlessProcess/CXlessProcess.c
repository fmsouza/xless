#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE // explicit_bzero, syscall
#endif
#if defined(__APPLE__)
#define __STDC_WANT_LIB_EXT1__ 1 // memset_s
#endif
#include "CXlessProcess.h"
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <bsm/libbsm.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <spawn.h>
#include <sys/ptrace.h>
#include <sys/sysctl.h>
#include <sys/ucred.h>
#endif
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
#ifdef __linux__
    // In one step: a fork on another thread never inherits these.
    return pipe2(fds, O_CLOEXEC) == 0 ? 0 : errno;
#else
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
#endif
}

/// tcsetpgrp without being stopped by SIGTTOU when this process is not (or no longer) in the foreground.
static void set_foreground(int tty, pid_t group) {
    sigset_t ttou, old;
    sigemptyset(&ttou);
    sigaddset(&ttou, SIGTTOU);
    pthread_sigmask(SIG_BLOCK, &ttou, &old);
    tcsetpgrp(tty, group);
    pthread_sigmask(SIG_SETMASK, &old, NULL);
}

void xless_terminal_restore(int tty) {
    if (tty >= 0) set_foreground(tty, getpgrp());
}

int xless_spawn_piped(const char *path, char *const argv[], char *const envp[], int tty, int *pid, int *in_fd, int *out_fd) {
    int in[2], out[2], status[2], e;
    if ((e = cloexec_pipe(in)) != 0) return e;
    if ((e = cloexec_pipe(out)) != 0) { close(in[0]); close(in[1]); return e; }
    if ((e = cloexec_pipe(status)) != 0) { close(in[0]); close(in[1]); close(out[0]); close(out[1]); return e; }
    long max_fd = sysconf(_SC_OPEN_MAX);
    if (max_fd < 0 || max_fd > 65536) max_fd = 65536;
    pid_t child = fork();
    if (child < 0) {
        e = errno;
        close(in[0]); close(in[1]); close(out[0]); close(out[1]); close(status[0]); close(status[1]);
        return e;
    }
    if (child == 0) {
        // Only async-signal-safe calls from here to execve.
        if (tty == -2) { if (setsid() < 0) { e = errno; goto failed; } } else setpgid(0, 0);
        if (tty >= 0) {
            // The terminal's foreground before exec, so a helper that prompts on /dev/tty is not stopped (SIGTTIN).
            signal(SIGTTOU, SIG_IGN);
            tcsetpgrp(tty, getpid());
        }
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            signal(sig, SIG_DFL);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        int child_out = out[1];
        if (child_out == 0 && (child_out = fcntl(out[1], F_DUPFD, 3)) < 0) { e = errno; goto failed; } // stdin's slot
        if (dup2(in[0], 0) < 0 || dup2(child_out, 1) < 0) { e = errno; goto failed; }
        // dup2 onto itself (xless started with fd 0 or 1 closed) keeps close-on-exec: clear it.
        fcntl(0, F_SETFD, 0);
        fcntl(1, F_SETFD, 0);
        // Nothing else of xless's reaches the helper: no store file, lock or socket left open without close-on-exec.
        {
            int report = status[1];
            for (long fd = 3; fd < max_fd; fd++) if (fd != report) close((int)fd);
        }
        execve(path, argv, envp);
        e = errno;
    failed:
        while (write(status[1], &e, sizeof e) < 0 && errno == EINTR) {}
        _exit(127);
    }
    // Also in the parent, so the group exists before any kill. Not for a session of its own: setsid would fail in a group's leader.
    if (tty != -2) setpgid(child, child);
    if (tty >= 0) set_foreground(tty, child);
    close(in[0]);
    close(out[1]);
    close(status[1]);
    int child_errno = 0;
    ssize_t n;
    do { n = read(status[0], &child_errno, sizeof child_errno); } while (n < 0 && errno == EINTR);
    close(status[0]);
    if (n > 0) {
        int ignored;
        xless_reap(child, 0, &ignored);
        xless_terminal_restore(tty);
        close(in[1]);
        close(out[0]);
        return child_errno ? child_errno : EIO;
    }
    fcntl(in[1], F_SETFL, fcntl(in[1], F_GETFL) | O_NONBLOCK);
    fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL) | O_NONBLOCK);
    *pid = child;
    *in_fd = in[1];
    *out_fd = out[0];
    return 0;
}

long xless_write_nosigpipe(int fd, const void *bytes, size_t length) {
#if defined(__APPLE__)
    // macOS raises SIGPIPE for the process, not for the writing thread, so blocking it on this thread does not stop it.
    (void)fcntl(fd, F_SETNOSIGPIPE, 1);
    return (long)write(fd, bytes, length);
#else
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
        while (sigtimedwait(&pipe_only, NULL, &zero) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    errno = e;
    return n;
#endif
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

/// Closes every descriptor from 3 up but `keep`, in a child between fork and exec.
static void close_from_3(int keep) {
#if defined(__linux__)
    // close_range(2), Linux 5.9; its number is the same on every architecture.
    if (keep < 3) {
        if (syscall(436, 3u, ~0u, 0u) == 0) return;
    } else if ((keep == 3 || syscall(436, 3u, (unsigned)keep - 1, 0u) == 0) && syscall(436, (unsigned)keep + 1, ~0u, 0u) == 0) {
        return;
    }
#endif
    long max_fd = sysconf(_SC_OPEN_MAX);
    if (max_fd < 0 || max_fd > 65536) max_fd = 65536;
    for (long fd = 3; fd < max_fd; fd++) if (fd != keep) close((int)fd);
}

int xless_spawn_session(const char *path, char *const argv[], char *const envp[], const char *cwd, int out_fd, int err_fd, int *pid) {
#if defined(__APPLE__)
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int e;
    if ((e = posix_spawnattr_init(&attr)) != 0) return e;
    if ((e = posix_spawn_file_actions_init(&actions)) != 0) { posix_spawnattr_destroy(&attr); return e; }
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    e = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!e) e = posix_spawnattr_setsigdefault(&attr, &all);
    if (!e) e = posix_spawnattr_setsigmask(&attr, &none);
    // Descriptors this process does not have open stay closed in the child.
    // A terminal's input is not the child's (it has no terminal, so nothing would stop it from reading what is typed).
    if (!e && isatty(0)) e = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    else if (!e && fcntl(0, F_GETFD) >= 0) e = posix_spawn_file_actions_addinherit_np(&actions, 0);
    if (!e && (out_fd >= 0 || fcntl(1, F_GETFD) >= 0)) e = posix_spawn_file_actions_adddup2(&actions, out_fd >= 0 ? out_fd : 1, 1);
    if (!e && (err_fd >= 0 || fcntl(2, F_GETFD) >= 0)) e = posix_spawn_file_actions_adddup2(&actions, err_fd >= 0 ? err_fd : 2, 2);
    if (!e && cwd != NULL) e = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    pid_t child = 0;
    if (!e) e = posix_spawn(&child, path, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (!e) *pid = child;
    return e;
#else
    int status[2], e;
    if ((e = cloexec_pipe(status)) != 0) return e;
    pid_t child = fork();
    if (child < 0) {
        e = errno;
        close(status[0]); close(status[1]);
        return e;
    }
    if (child == 0) {
        // Only async-signal-safe calls from here to execve.
        int report = status[1];
        if (setsid() < 0) { e = errno; goto failed; }
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            signal(sig, SIG_DFL);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (report < 3 && (report = fcntl(report, F_DUPFD_CLOEXEC, 3)) < 0) _exit(127); // xless started with stdio closed
        // Out of the slots they go to, then into them.
        int out = out_fd < 0 ? -1 : fcntl(out_fd, F_DUPFD_CLOEXEC, 3);
        int err = err_fd < 0 ? -1 : fcntl(err_fd, F_DUPFD_CLOEXEC, 3);
        if ((out_fd >= 0 && (out < 0 || dup2(out, 1) < 0)) || (err_fd >= 0 && (err < 0 || dup2(err, 2) < 0))) { e = errno; goto failed; }
        // A terminal's input is not the child's (it has no terminal, so nothing would stop it from reading what is typed).
        struct termios unused;
        if (tcgetattr(0, &unused) == 0) {
            int null = open("/dev/null", O_RDONLY);
            if (null < 0 || dup2(null, 0) < 0) { e = errno; goto failed; }
        }
        if (cwd != NULL && chdir(cwd) != 0) { e = errno; goto failed; }
        close_from_3(report);
        execve(path, argv, envp);
        e = errno;
    failed:
        while (write(report, &e, sizeof e) < 0 && errno == EINTR) {}
        _exit(127);
    }
    close(status[1]);
    int child_errno = 0;
    ssize_t n;
    do { n = read(status[0], &child_errno, sizeof child_errno); } while (n < 0 && errno == EINTR);
    close(status[0]);
    if (n > 0) {
        int ignored;
        xless_wait(child, &ignored);
        return child_errno ? child_errno : EIO;
    }
    *pid = child;
    return 0;
#endif
}

int xless_wait(int pid, int *status) {
    int s = 0;
    pid_t r;
    do { r = waitpid((pid_t)pid, &s, 0); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    *status = WIFEXITED(s) ? WEXITSTATUS(s) : WIFSIGNALED(s) ? WTERMSIG(s) : -1;
    return 1;
}

// --- The xless agent ---

#if defined(__APPLE__)
static int64_t mach_ms(uint64_t ticks) {
    static mach_timebase_info_data_t base; // the same value whichever thread writes it
    if (base.denom == 0) mach_timebase_info(&base);
    return (int64_t)((__uint128_t)ticks * base.numer / base.denom / 1000000u);
}
int64_t xless_clock_continuous_ms(void) { return mach_ms(mach_continuous_time()); }
int64_t xless_clock_awake_ms(void) { return mach_ms(mach_absolute_time()); }
#else
static int64_t clock_ms(clockid_t clock) {
    struct timespec t;
    if (clock_gettime(clock, &t) != 0) return 0;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
#ifdef __linux__
int64_t xless_clock_continuous_ms(void) { return clock_ms(CLOCK_BOOTTIME); }
#else
int64_t xless_clock_continuous_ms(void) { return clock_ms(CLOCK_MONOTONIC); }
#endif
int64_t xless_clock_awake_ms(void) { return clock_ms(CLOCK_MONOTONIC); }
#endif

static size_t whole_pages(size_t size) {
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    return size == 0 ? page : (size + page - 1) / page * page;
}

void *xless_secret_map(size_t size, int *locked) {
    size_t length = whole_pages(size);
    void *p = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) return NULL;
    int ok = mlock(p, length) == 0;
#ifdef __linux__
    (void)madvise(p, length, MADV_DONTDUMP);
    (void)madvise(p, length, MADV_DONTFORK);
#endif
    if (locked) *locked = ok;
    return p;
}

void xless_secret_unmap(void *bytes, size_t size) {
    if (bytes == NULL) return;
    size_t length = whole_pages(size);
    xless_secure_zero(bytes, length);
    (void)munlock(bytes, length);
    (void)munmap(bytes, length);
}

int xless_deny_attach(void) {
#if defined(__APPLE__)
    (void)ptrace(PT_DENY_ATTACH, 0, 0, 0);
#endif
    return 0;
}

#if defined(__linux__)
int xless_peer_of(int fd, struct xless_peer *out) { (void)fd; memset(out, 0, sizeof *out); return ENOTSUP; }

int xless_unix_passcred(int fd) {
    int one = 1;
    return setsockopt(fd, SOL_SOCKET, SO_PASSCRED, &one, sizeof one) == 0 ? 0 : errno;
}

long xless_unix_recv(int fd, void *bytes, size_t length, int *pid, unsigned int *uid) {
    struct iovec iov = { bytes, length };
    // Room for the credentials only: the kernel drops descriptors that do not fit.
    union { char bytes[CMSG_SPACE(sizeof(struct ucred))]; struct cmsghdr align; } control;
    struct msghdr m;
    memset(&m, 0, sizeof m);
    memset(&control, 0, sizeof control);
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    m.msg_control = control.bytes;
    m.msg_controllen = sizeof control.bytes;
    *pid = 0;
    *uid = (unsigned int)-1;
    ssize_t n;
    do { n = recvmsg(fd, &m, MSG_CMSG_CLOEXEC); } while (n < 0 && errno == EINTR);
    if (n < 0) return -errno;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c != NULL; c = CMSG_NXTHDR(&m, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS && c->cmsg_len == CMSG_LEN(sizeof(struct ucred))) {
            struct ucred cred;
            memcpy(&cred, CMSG_DATA(c), sizeof cred);
            *pid = cred.pid;
            *uid = cred.uid;
        }
    }
    return (long)n;
}

long xless_unix_peer_uid(int fd) {
    struct ucred cred;
    socklen_t length = sizeof cred;
    return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) == 0 ? (long)cred.uid : -errno;
}

int xless_pidfd_open(int pid) {
    long fd = syscall(434, pid, 0u); // pidfd_open, the same number on every architecture; close-on-exec by itself
    return fd < 0 ? -errno : (int)fd;
}

int xless_pidfd_alive(int pidfd) {
    struct pollfd p = { pidfd, POLLIN, 0 };
    int r;
    do { r = poll(&p, 1, 0); } while (r < 0 && errno == EINTR);
    return r == 0;
}

uint64_t xless_process_start(int pid) {
    char path[64], text[1024];
    if (pid <= 0) return 0;
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return 0;
    text[n] = 0;
    // The name (field 2) may hold anything, spaces and parentheses included: the fields go on after the last one.
    char *p = strrchr(text, ')');
    if (p == NULL || p[1] != ' ') return 0;
    if (p[2] == 'Z' || p[2] == 'X') return 0; // ended, not yet reaped
    unsigned long long start = 0;
    int field = 2;
    for (char *save = NULL, *t = strtok_r(p + 1, " ", &save); t != NULL; t = strtok_r(NULL, " ", &save)) {
        if (++field == 22) { start = strtoull(t, NULL, 10); break; }
    }
    return field == 22 ? (uint64_t)start + 1 : 0;
}
#elif defined(__APPLE__)
int xless_peer_of(int fd, struct xless_peer *out) {
    memset(out, 0, sizeof *out);
    uid_t euid;
    gid_t egid;
    if (getpeereid(fd, &euid, &egid) != 0) return errno;
    audit_token_t token;
    socklen_t length = sizeof token;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) != 0) return errno;
    pid_t pid = audit_token_to_pid(token);
    if (pid <= 0 || audit_token_to_euid(token) != euid) return ESRCH;
    int sid = getsid(pid);
    if (sid < 0) return errno;
    // The path by audit token, which holds the process's version: it fails when the process of that token has ended or
    // runs another program, even if another one has its pid now. Read after the session, so the session is that
    // process's too. (Whether that process is the peer is for the caller: the token is of whoever had its pid just now.)
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath_audittoken(&token, path, sizeof path) <= 0) return ESRCH;
    struct stat st;
    if (stat(path, &st) == 0) {
        out->exe_device = (uint64_t)st.st_dev;
        out->exe_inode = (uint64_t)st.st_ino;
    }
    memcpy(out->token, &token, sizeof out->token);
    out->pid = pid;
    out->uid = euid;
    out->sid = sid;
    return 0;
}

int xless_unix_passcred(int fd) { (void)fd; return 0; }

long xless_unix_recv(int fd, void *bytes, size_t length, int *pid, unsigned int *uid) {
    uid_t euid;
    gid_t egid;
    *pid = 0;
    if (getpeereid(fd, &euid, &egid) != 0) return -errno;
    *uid = euid;
    ssize_t n;
    do { n = recv(fd, bytes, length, 0); } while (n < 0 && errno == EINTR);
    return n < 0 ? -errno : (long)n;
}

long xless_unix_peer_uid(int fd) {
    uid_t euid;
    gid_t egid;
    return getpeereid(fd, &euid, &egid) == 0 ? (long)euid : -errno;
}

int xless_pidfd_open(int pid) { (void)pid; return -ENOSYS; }
int xless_pidfd_alive(int pidfd) { (void)pidfd; return 0; }

uint64_t xless_process_start(int pid) {
    int name[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc info;
    size_t length = sizeof info;
    memset(&info, 0, sizeof info);
    if (pid <= 0 || sysctl(name, 4, &info, &length, NULL, 0) != 0 || length < sizeof info) return 0;
    if (info.kp_proc.p_stat == SZOMB) return 0;
    return (uint64_t)info.kp_proc.p_starttime.tv_sec * 1000000u + (uint64_t)info.kp_proc.p_starttime.tv_usec + 1;
}
#endif

static int unix_socket(void) {
#if defined(__linux__)
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    return fd < 0 ? -errno : fd;
#else
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    int one = 1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    return fd;
#endif
}

size_t xless_unix_path_max(void) { return sizeof(((struct sockaddr_un *)0)->sun_path) - 1; }

static int unix_address(const char *path, struct sockaddr_un *address) {
    memset(address, 0, sizeof *address);
    address->sun_family = AF_UNIX;
    if (path[0] == 0 || strlen(path) > xless_unix_path_max()) return ENAMETOOLONG;
    strcpy(address->sun_path, path);
    return 0;
}

int xless_unix_listen(const char *path, int backlog) {
    struct sockaddr_un address;
    int e = unix_address(path, &address);
    if (e) return -e;
    int fd = unix_socket();
    if (fd < 0) return fd;
    mode_t old = umask(077);
    int bound = bind(fd, (struct sockaddr *)&address, sizeof address);
    e = errno;
    umask(old);
    if (bound != 0) { close(fd); return -e; }
    if (chmod(path, 0600) != 0 || listen(fd, backlog) != 0) {
        e = errno;
        unlink(path);
        close(fd);
        return -e;
    }
    return fd;
}

int xless_unix_connect(const char *path) {
    struct sockaddr_un address;
    int e = unix_address(path, &address);
    if (e) return -e;
    int fd = unix_socket();
    if (fd < 0) return fd;
    int r;
    do { r = connect(fd, (struct sockaddr *)&address, sizeof address); } while (r != 0 && errno == EINTR);
    if (r != 0) {
        e = errno;
        close(fd);
        return -e;
    }
    return fd;
}

int xless_unix_accept(int fd) {
    int c;
#if defined(__linux__)
    do { c = accept4(fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK); } while (c < 0 && errno == EINTR);
    return c < 0 ? -errno : c;
#else
    do { c = accept(fd, NULL, NULL); } while (c < 0 && errno == EINTR);
    if (c < 0) return -errno;
    int one = 1;
    fcntl(c, F_SETFD, FD_CLOEXEC);
    fcntl(c, F_SETFL, O_NONBLOCK);
    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    return c;
#endif
}

int xless_unix_pair(int fds[2]) {
#if defined(__linux__)
    return socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, fds) == 0 ? 0 : errno;
#else
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return errno;
    for (int i = 0; i < 2; i++) {
        int one = 1;
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
        fcntl(fds[i], F_SETFL, O_NONBLOCK);
        setsockopt(fds[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    }
    return 0;
#endif
}

long xless_unix_send(int fd, const void *bytes, size_t length) {
    ssize_t n;
#ifdef MSG_NOSIGNAL
    do { n = send(fd, bytes, length, MSG_NOSIGNAL); } while (n < 0 && errno == EINTR);
#else
    do { n = send(fd, bytes, length, 0); } while (n < 0 && errno == EINTR); // SO_NOSIGPIPE is set
#endif
    return n < 0 ? -errno : (long)n;
}

int xless_spawn_detached(const char *path, char *const argv[], int channel, int same_session) {
    int status[2], e;
    if ((e = cloexec_pipe(status)) != 0) return e;
    pid_t child = fork();
    if (child < 0) {
        e = errno;
        close(status[0]); close(status[1]);
        return e;
    }
    if (child == 0) {
        // Only async-signal-safe calls from here to execve.
        int report = status[1];
        static char *const no_environment[] = { NULL };
        if (!same_session && setsid() < 0) { e = errno; goto failed; }
        pid_t second = fork(); // init's child from here, and never a session's leader
        if (second < 0) { e = errno; goto failed; }
        if (second > 0) _exit(0);
        if (same_session) {
            if (setpgid(0, 0) != 0) { e = errno; goto failed; }
            int tty = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
            if (tty >= 0) {
                // This process's terminal only: it leads no session. It stays in the session.
                if (ioctl(tty, TIOCNOTTY, 0) != 0) { e = errno; goto failed; }
                close(tty);
            }
        }
        int ignored[] = { SIGHUP, SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE };
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            signal(sig, SIG_DFL);
        }
        for (size_t i = 0; i < sizeof ignored / sizeof *ignored; i++) signal(ignored[i], SIG_IGN);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (chdir("/") != 0) { e = errno; goto failed; }
        if ((report = fcntl(report, F_DUPFD_CLOEXEC, 4)) < 0) _exit(127);
        int mine = fcntl(channel, F_DUPFD_CLOEXEC, 4);
        int null = open("/dev/null", O_RDWR | O_CLOEXEC);
        if (null >= 0 && null < 4) null = fcntl(null, F_DUPFD_CLOEXEC, 4);
        if (mine < 0 || null < 0) { e = errno; goto failed; }
        if (dup2(null, 0) < 0 || dup2(null, 1) < 0 || dup2(null, 2) < 0 || dup2(mine, 3) < 0) { e = errno; goto failed; }
        // Everything from 4 up but `report`, which closes on exec.
        {
            long max_fd = sysconf(_SC_OPEN_MAX);
            int closed = 0;
#if defined(__linux__)
            closed = (report == 4 || syscall(436, 4u, (unsigned)report - 1, 0u) == 0) && syscall(436, (unsigned)report + 1, ~0u, 0u) == 0;
#endif
            if (max_fd < 0 || max_fd > 65536) max_fd = 65536;
            for (long fd = 4; !closed && fd < max_fd; fd++) if (fd != report) close((int)fd);
        }
        execve(path, argv, no_environment);
        e = errno;
    failed:
        while (write(report, &e, sizeof e) < 0 && errno == EINTR) {}
        _exit(127);
    }
    close(status[1]);
    int ignored_status;
    xless_wait(child, &ignored_status);
    int child_errno = 0;
    ssize_t n;
    do { n = read(status[0], &child_errno, sizeof child_errno); } while (n < 0 && errno == EINTR);
    close(status[0]);
    return n > 0 ? (child_errno ? child_errno : EIO) : 0;
}
