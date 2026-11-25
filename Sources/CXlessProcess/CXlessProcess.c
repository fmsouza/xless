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
#include <stdatomic.h>
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
#include <spawn.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <bsm/libbsm.h>
#include <membership.h>
#include <sys/acl.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/attr.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
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
#ifdef __linux__
    struct rlimit no_handler = { 1, 1 };
    int result = setrlimit(RLIMIT_CORE, &no_handler);
    if (result != 0) result = setrlimit(RLIMIT_CORE, &none); // the hard limit is 0 already, and raising it is not allowed
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) result = -1;
#else
    int result = setrlimit(RLIMIT_CORE, &none);
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

// --- On the kernel of WSL ---

// The kernel's numbers (linux/filter.h, linux/seccomp.h, linux/audit.h, the system call tables: not every sysroot has them).
enum {
    LOAD = 0x20 /* BPF_LD | BPF_W | BPF_ABS */, IF_EQUAL = 0x15 /* BPF_JMP | BPF_JEQ | BPF_K */,
    IF_NOT_BELOW = 0x35 /* BPF_JMP | BPF_JGE | BPF_K, unsigned */, RETURN = 0x06 /* BPF_RET | BPF_K */,
    NUMBER = 0, ARCHITECTURE = 4, FIRST_ARGUMENT = 16, // in struct seccomp_data; of an argument its low half (both are little-endian)
    AF_OF_VSOCK = 40,
    IO_URING_SETUP = 425, // the same on every architecture
};
#define RET_KILL_PROCESS 0x80000000u
#define RET_ALLOW 0x7fff0000u
#define RET_EACCES (0x00050000u | 13u)
#define X32 0x40000000u
#define NO_CALL 0xffffffffu // what a tracer makes of a call that it skips: no system call

// The two numbers after a jump are how many instructions it skips, when it holds and when it does not. The kernel takes socket's
// family as an int, so the high half of the register means nothing, here as there.
static const struct xless_instruction windows_x86_64[] = {
    { LOAD, 0, 0, ARCHITECTURE },
    { IF_EQUAL, 0, 8, 0xc000003eu },        // AUDIT_ARCH_X86_64, else killed
    { LOAD, 0, 0, NUMBER },
    { IF_EQUAL, 7, 0, NO_CALL },            // allowed
    { IF_NOT_BELOW, 5, 0, X32 },            // killed
    { IF_EQUAL, 3, 0, IO_URING_SETUP },     // refused
    { IF_EQUAL, 0, 4, 41 },                 // socket, else allowed
    { LOAD, 0, 0, FIRST_ARGUMENT },
    { IF_EQUAL, 0, 2, AF_OF_VSOCK },        // refused, else allowed
    { RETURN, 0, 0, RET_EACCES },
    { RETURN, 0, 0, RET_KILL_PROCESS },
    { RETURN, 0, 0, RET_ALLOW },
};
static const struct xless_instruction windows_arm64[] = {
    { LOAD, 0, 0, ARCHITECTURE },
    { IF_EQUAL, 0, 6, 0xc00000b7u },        // AUDIT_ARCH_AARCH64, else killed
    { LOAD, 0, 0, NUMBER },
    { IF_EQUAL, 3, 0, IO_URING_SETUP },     // refused
    { IF_EQUAL, 0, 4, 198 },                // socket, else allowed
    { LOAD, 0, 0, FIRST_ARGUMENT },
    { IF_EQUAL, 0, 2, AF_OF_VSOCK },        // refused, else allowed
    { RETURN, 0, 0, RET_EACCES },
    { RETURN, 0, 0, RET_KILL_PROCESS },
    { RETURN, 0, 0, RET_ALLOW },
};
static const struct xless_filter filter_x86_64 = { windows_x86_64, sizeof windows_x86_64 / sizeof *windows_x86_64 };
static const struct xless_filter filter_arm64 = { windows_arm64, sizeof windows_arm64 / sizeof *windows_arm64 };

const struct xless_filter *xless_windows_filter_x86_64(void) { return &filter_x86_64; }
const struct xless_filter *xless_windows_filter_arm64(void) { return &filter_arm64; }
const struct xless_filter *xless_windows_filter(void) {
#if defined(__linux__) && defined(__x86_64__) && defined(__LP64__)
    return &filter_x86_64;
#elif defined(__linux__) && defined(__aarch64__) && defined(__LP64__) && defined(__AARCH64EL__)
    return &filter_arm64;
#else
    static const struct xless_filter none = { NULL, 0 };
    return &none;
#endif
}

int xless_keep_orphans(int on) {
#ifdef __linux__
    return prctl(36 /* PR_SET_CHILD_SUBREAPER */, (unsigned long)(on != 0), 0ul, 0ul, 0ul);
#else
    (void)on;
    return -1;
#endif
}

#ifdef __linux__
enum { ANY_CHILD = 0x40000000 /* __WALL */ };
#endif

int xless_has_children(void) {
#ifdef __linux__
    siginfo_t info;
    int r;
    do { r = waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT | ANY_CHILD); } while (r < 0 && errno == EINTR);
    return r == 0 ? 1 : errno == ECHILD ? 0 : -1;
#else
    return -1;
#endif
}

int xless_reap_orphan(int pid) {
#ifdef __linux__
    int status;
    return pid > 0 && waitpid((pid_t)pid, &status, WNOHANG | ANY_CHILD) == (pid_t)pid;
#else
    (void)pid;
    return 0;
#endif
}

int xless_is_wsl_release(const char *release) { return strcasestr(release, "microsoft") != NULL; }

int xless_is_wsl_kernel(void) {
#ifdef __linux__
    struct utsname system;
    return uname(&system) == 0 && xless_is_wsl_release(system.release);
#else
    return 0;
#endif
}

/// Puts this process, a child between fork and exec, under `filter`: 0, or an errno value. Async-signal-safe: two system calls,
/// of a thread that is the only one.
static int confine(const struct xless_filter *filter) {
#ifdef __linux__
    struct { unsigned short length; const struct xless_instruction *program; } program = { filter->length, filter->program }; // struct sock_fprog
    // Without it only root may set a filter, and a setuid program would run with more rights than whoever filtered it.
    if (prctl(38 /* PR_SET_NO_NEW_PRIVS */, 1ul, 0ul, 0ul, 0ul) != 0) return errno ? errno : EINVAL;
    if (prctl(22 /* PR_SET_SECCOMP */, 2ul /* SECCOMP_MODE_FILTER */, &program, 0ul, 0ul) != 0) return errno ? errno : EINVAL;
    return 0;
#else
    (void)filter;
    return ENOSYS;
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

// The tools that run are told the signals that end this process: in sessions of their own, they get none from a terminal.

enum { STAYS, ENDS, FAULT };

/// What `sig` does to a process by default: nothing that ends it, ends it, or ends it as a fault of its own does.
static int what_is(int sig) {
    switch (sig) {
    case SIGKILL: case SIGSTOP: // which nobody can catch
    case SIGTSTP: case SIGTTIN: case SIGTTOU: case SIGCONT: case SIGCHLD: case SIGURG: case SIGWINCH:
#ifdef __APPLE__
    case SIGIO: case SIGINFO:
#endif
        return STAYS;
    case SIGSEGV: case SIGBUS: case SIGILL: case SIGFPE: case SIGABRT: case SIGTRAP: case SIGSYS:
#ifdef SIGEMT
    case SIGEMT:
#endif
        return FAULT;
    default: return ENDS; // on Linux the real-time ones too
    }
}

static atomic_int is_forwarded[NSIG];
static atomic_int tools[256]; // their pids, which are their process groups; 0: none
static atomic_int owner;      // the process they are tools of (a forked child has their numbers too)
static atomic_int starting;   // how many are being started
static atomic_int deferred;   // the signal that came meanwhile
static atomic_int ending;     // a signal ends this process: no tool is being started, and none will be

/// SIGINT, SIGTERM and SIGHUP as they are; any other says the same as SIGTERM to them.
static void tell_tools(int sig) {
    if (sig != SIGINT && sig != SIGHUP) sig = SIGTERM;
    for (size_t i = 0; i < sizeof tools / sizeof *tools; i++) {
        int tool = atomic_load(&tools[i]);
        if (tool > 0) kill(-tool, sig);
    }
}

// What must not outlive this process: files, and directories of them, the last one first. An entry is never freed: a handler
// may read it.
struct private_path { struct private_path *next; atomic_int kept; int is_directory; char path[]; };
static _Atomic(struct private_path *) private_paths;

// Async-signal-safe. The files, then the directories they leave empty, the last ones made first.
static void remove_private(void) {
    for (int directories = 0; directories < 2; directories++) {
        for (struct private_path *it = atomic_load(&private_paths); it != NULL; it = it->next) {
            if (atomic_load(&it->kept) || it->is_directory != directories) continue;
            if (directories) rmdir(it->path); else unlink(it->path);
        }
    }
}

static void take_default(int sig) {
    signal(sig, SIG_DFL);
    sigset_t only;
    sigemptyset(&only);
    sigaddset(&only, sig);
    pthread_sigmask(SIG_UNBLOCK, &only, NULL);
    raise(sig);
#ifdef __APPLE__
    // A thread of a dispatch queue cannot send itself a signal (ENOTSUP). One to the process ends it, on whichever thread.
    kill(getpid(), sig);
    poll(NULL, 0, 1000);
#endif
    _exit(128 + sig); // process 1 of a container: what a signal does by default is nothing
}

// Async-signal-safe.
static void forward(int sig) {
    int e = errno;
    if (getpid() == atomic_load(&owner)) {
        tell_tools(sig);
        // While one is being started nobody knows its number: whoever starts it goes on from here (`tool_started`). In
        // this order, so that either it or this sees the other. Nothing is put off once it is the end: what is counted then
        // starts no tool, but may have put this handler back as `take_default` was about to send the signal again.
        atomic_store(&deferred, sig);
        if (!atomic_load(&ending) && atomic_load(&starting) > 0) {
            errno = e;
            return;
        }
        atomic_store(&ending, 1);
        remove_private();
    }
    take_default(sig);
}

static void forward_on(int sig) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = forward;
    action.sa_flags = SA_RESTART;
    sigemptyset(&action.sa_mask);
    for (int i = 1; i < NSIG; i++) if (what_is(i) == ENDS) sigaddset(&action.sa_mask, i);
    sigaction(sig, &action, NULL);
}

static struct sigaction before_fault[NSIG];
static atomic_int has_cleaner;
static void let_stop_clean_up(int sig);
static void note_stop(int sig);
static void pass_on(int sig, siginfo_t *info, void *context);

static int from_another(const siginfo_t *info) {
#ifdef __linux__
    return info->si_code <= 0 && info->si_pid != getpid(); // si_pid is there for these alone
#else
    return info->si_pid > 0 && info->si_pid != getpid();
#endif
}

// Async-signal-safe. Something in this process is broken (or somebody says so): the tools are told, what is private goes, and
// then comes what would have come first (Swift's backtrace) and the end: that handler comes back when nothing is broken after
// all, and leaves every one of these signals to the default. Nothing that needs a lock: it may be held. Sent by another process
// nothing is broken: in a run that is a stop as any other is.
static void fault(int sig, siginfo_t *info, void *context) {
    if (getpid() == atomic_load(&owner)) {
        if (atomic_load(&has_cleaner) && from_another(info)) {
            note_stop(sig);
            return;
        }
        tell_tools(SIGTERM);
        remove_private();
        let_stop_clean_up(sig);
    }
    const struct sigaction *before = &before_fault[sig];
    if (before->sa_flags & SA_SIGINFO) before->sa_sigaction(sig, info, context);
    else if (before->sa_handler != SIG_DFL) before->sa_handler(sig);
    take_default(sig);
}

static void fault_on(int sig, const struct sigaction *now) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = fault;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    before_fault[sig] = *now;
    sigaction(sig, &action, NULL);
}

// Where a thread's handler runs: the fault may be that its own stack is full. A thread that has one already keeps that.
enum { HANDLER_STACK = 65536 };
static pthread_key_t handler_stack;
static void no_handler_stack(void *stack) {
    stack_t off;
    memset(&off, 0, sizeof off);
    off.ss_flags = SS_DISABLE;
    off.ss_size = HANDLER_STACK; // macOS looks at it
    sigaltstack(&off, NULL);
    munmap(stack, HANDLER_STACK);
}
static void make_handler_stack_key(void) { pthread_key_create(&handler_stack, no_handler_stack); }
static void handler_stack_on(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    stack_t now;
    if (sigaltstack(NULL, &now) != 0 || !(now.ss_flags & SS_DISABLE)) return;
    pthread_once(&once, make_handler_stack_key);
    void *stack = mmap(NULL, HANDLER_STACK, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stack == MAP_FAILED) return;
    stack_t own;
    memset(&own, 0, sizeof own);
    own.ss_sp = stack;
    own.ss_size = HANDLER_STACK;
    if (sigaltstack(&own, NULL) != 0 || pthread_setspecific(handler_stack, stack) != 0) no_handler_stack(stack);
}

/// Where nothing is said of the signal, or something is done at it (Swift's backtrace): that comes after.
static void faults_on(void) {
    handler_stack_on();
    for (int sig = 1; sig < NSIG; sig++) {
        struct sigaction now;
        if (what_is(sig) != FAULT || sigaction(sig, NULL, &now) != 0 || now.sa_handler == SIG_IGN || now.sa_sigaction == fault) continue;
        fault_on(sig, &now);
    }
}

static void handlers_on(void) {
    for (int sig = 1; sig < NSIG; sig++) {
        struct sigaction now;
        if (what_is(sig) != ENDS || sigaction(sig, NULL, &now) != 0 || now.sa_handler == SIG_IGN) continue; // ignored (nohup): neither
        atomic_store(&is_forwarded[sig], 1);
        if (now.sa_handler == SIG_DFL) forward_on(sig);
        // Swift's backtrace is at this one too, and would go on after it, with the end as it is by default from then on.
        else if (sig == SIGQUIT && now.sa_handler != forward && now.sa_handler != note_stop && now.sa_sigaction != pass_on && now.sa_sigaction != fault) fault_on(sig, &now);
    }
    faults_on();
}

// Counted first, then the handlers: a signal from here on waits until the tool is known (also when its start hangs), and
// one that came before it is in `deferred`.
static void tool_starts(void) {
    atomic_store(&owner, getpid());
    atomic_fetch_add(&starting, 1);
    handlers_on();
}

void *xless_remove_when_ended(const char *path, int is_directory) {
    struct private_path *it = malloc(sizeof *it + strlen(path) + 1);
    if (it == NULL) return NULL;
    it->is_directory = is_directory;
    atomic_init(&it->kept, 0);
    strcpy(it->path, path);
    it->next = atomic_load(&private_paths);
    while (!atomic_compare_exchange_weak(&private_paths, &it->next, it)) {}
    atomic_store(&owner, getpid());
    handlers_on();
    return it;
}

void xless_keep_when_ended(void *entry) {
    if (entry != NULL) atomic_store(&((struct private_path *)entry)->kept, 1);
}

static void tool_started(int tool) { // 0: it was not
    for (size_t i = 0; tool > 0 && i < sizeof tools / sizeof *tools; i++) {
        int none = 0;
        if (atomic_compare_exchange_strong(&tools[i], &none, tool)) break;
    }
    int sig;
    if (atomic_fetch_sub(&starting, 1) == 1 && (sig = atomic_load(&deferred)) != 0) {
        atomic_store(&ending, 1);
        tell_tools(sig);
        remove_private();
        take_default(sig);
    }
}

static void tool_ended(int tool) {
    for (size_t i = 0; i < sizeof tools / sizeof *tools; i++) {
        int it = tool;
        if (atomic_compare_exchange_strong(&tools[i], &it, 0)) return;
    }
}

long xless_physical_path(const char *path, char *buffer, size_t length) {
#ifdef __APPLE__
    // Asked by path, not of a descriptor (F_GETPATH_NOFIRMLINK): a directory that may be searched need not be readable.
    struct attrlist wanted = { .bitmapcount = ATTR_BIT_MAP_COUNT, .forkattr = ATTR_CMNEXT_NOFIRMLINKPATH };
    struct { uint32_t length; attrreference_t path; char text[PATH_MAX]; } __attribute__((packed)) answer;
    if (getattrlist(path, &wanted, &answer, sizeof answer, FSOPT_ATTR_CMN_EXTENDED) != 0 || answer.length > sizeof answer) return -1;
    const char *text = (const char *)&answer.path + answer.path.attr_dataoffset, *end = (const char *)&answer + answer.length;
    if (answer.path.attr_length <= 1 || text < answer.text || text + answer.path.attr_length > end || answer.path.attr_length > length) return -1;
    memcpy(buffer, text, answer.path.attr_length); // its 0 too
    return (long)answer.path.attr_length - 1;
#else
    (void)path; (void)buffer; (void)length;
    return -1;
#endif
}

char *const *xless_environment(void) {
#ifdef __APPLE__
    return *_NSGetEnviron();
#else
    extern char **environ;
    return environ;
#endif
}

int xless_tool_runs(int pid) {
    for (size_t i = 0; pid > 0 && i < sizeof tools / sizeof *tools; i++) {
        if (atomic_load(&tools[i]) == pid) return 1;
    }
    return 0;
}

void xless_signal_default(int sig) {
    if (sig > 0 && sig < NSIG && atomic_load(&is_forwarded[sig])) forward_on(sig);
    else signal(sig, SIG_DFL);
}

static int spawn_session(const char *path, char *const argv[], char *const envp[], const char *cwd, int out_fd, int err_fd,
                         const struct xless_filter *filter, int *pid);

int xless_spawn_session(const char *path, char *const argv[], char *const envp[], const char *cwd, int out_fd, int err_fd,
                        const struct xless_filter *filter, int *pid) {
    tool_starts();
    // A signal that another thread took before it could know of this start: no tool is started any more.
    int e = atomic_load(&deferred) ? EINTR : spawn_session(path, argv, envp, cwd, out_fd, err_fd, filter, pid);
    tool_started(e == 0 ? *pid : 0);
    return e;
}

static int spawn_session(const char *path, char *const argv[], char *const envp[], const char *cwd, int out_fd, int err_fd,
                         const struct xless_filter *filter, int *pid) {
#if defined(__APPLE__)
    if (filter != NULL) return -confine(filter);
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
    // A terminal is not the child's input: it has no controlling terminal, so it would not be stopped (SIGTTIN) as a
    // background job that reads is. Its output may be one, and the device can be opened by its path.
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
        // A terminal is not the child's input: it has no controlling terminal, so it would not be stopped (SIGTTIN) as a
        // background job that reads is. Its output may be one, and the device can be opened by its path.
        struct termios unused;
        if (tcgetattr(0, &unused) == 0) {
            int null = open("/dev/null", O_RDONLY);
            if (null < 0 || dup2(null, 0) < 0) { e = errno; goto failed; }
        }
        if (cwd != NULL && chdir(cwd) != 0) { e = errno; goto failed; }
        close_from_3(report);
        // The last thing: from here it and what it starts are under it.
        if (filter != NULL && (e = confine(filter)) != 0) { e = -e; goto failed; }
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
    if (xless_tool_runs(pid)) {
        // Off the list while its number is still its own.
        siginfo_t info;
        int w;
        do { w = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT); } while (w < 0 && errno == EINTR);
        tool_ended(pid);
    }
    do { r = waitpid((pid_t)pid, &s, 0); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    *status = WIFEXITED(s) ? WEXITSTATUS(s) : WIFSIGNALED(s) ? WTERMSIG(s) : -1;
    return 1;
}

// --- A script xless runs for the person (`xless session`) ---

static const int passed_on[] = { SIGTERM, SIGHUP, SIGINT, SIGQUIT };
#define PASSED_ON (sizeof passed_on / sizeof *passed_on)
static atomic_int script;                   // its pid; 0: none
static atomic_int script_waits[PASSED_ON];  // the signals that came before it had one

/// Whether the terminal itself sent `info`'s signal, and so to every process of its foreground group.
static int from_terminal(const siginfo_t *info) {
#ifdef __linux__
    return info->si_code == SI_KERNEL;
#else
    // Darwin does not say who sent it: the terminal, where this is its foreground (kill(1) of xless alone is then lost on it).
    (void)info;
    int tty = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
    if (tty < 0) return 0;
    int foreground = tcgetpgrp(tty) == getpgrp();
    close(tty);
    return foreground;
#endif
}

// Async-signal-safe.
static void pass_on(int sig, siginfo_t *info, void *context) {
    (void)context;
    int e = errno;
    if ((sig != SIGINT && sig != SIGQUIT) || !from_terminal(info)) {
        for (size_t i = 0; i < PASSED_ON; i++) if (passed_on[i] == sig) atomic_store(&script_waits[i], 1);
        int pid = atomic_load(&script);
        if (pid > 0) {
            for (size_t i = 0; i < PASSED_ON; i++) if (atomic_exchange(&script_waits[i], 0)) kill(pid, passed_on[i]);
        }
    }
    errno = e;
}

int xless_run_foreground(const char *path, char *const argv[], char *const envp[], int *status, int *by_signal) {
    posix_spawnattr_t attr;
    int e;
    if ((e = posix_spawnattr_init(&attr)) != 0) return e;
    sigset_t none;
    sigemptyset(&none);
    e = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK);
    if (!e) e = posix_spawnattr_setsigmask(&attr, &none);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = pass_on;
    action.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < PASSED_ON; i++) sigaddset(&action.sa_mask, passed_on[i]);
    for (size_t i = 0; i < PASSED_ON; i++) {
        struct sigaction now;
        atomic_store(&script_waits[i], 0);
        // Ignored (nohup, a background job): the script ignores it too. What is handled here is the default's in it (exec).
        if (sigaction(passed_on[i], NULL, &now) == 0 && now.sa_handler != SIG_IGN) sigaction(passed_on[i], &action, NULL);
    }
    pid_t child = 0;
    if (!e) e = posix_spawn(&child, path, NULL, &attr, argv, envp);
    posix_spawnattr_destroy(&attr);
    if (e) {
        for (size_t i = 0; i < PASSED_ON; i++) if (atomic_exchange(&script_waits[i], 0)) xless_end_by_signal(passed_on[i]);
        return e;
    }
    atomic_store(&script, child);
    // What came while it had no number yet.
    for (size_t i = 0; i < PASSED_ON; i++) if (atomic_exchange(&script_waits[i], 0)) kill(child, passed_on[i]);
    siginfo_t info;
    int w;
    do { w = waitid(P_PID, (id_t)child, &info, WEXITED | WNOWAIT); } while (w < 0 && errno == EINTR);
    atomic_store(&script, 0); // while its number is still its own
    int s = 0;
    pid_t r;
    do { r = waitpid(child, &s, 0); } while (r < 0 && errno == EINTR);
    if (r < 0) return errno;
    *by_signal = WIFSIGNALED(s) ? 1 : 0;
    *status = WIFEXITED(s) ? WEXITSTATUS(s) : WIFSIGNALED(s) ? WTERMSIG(s) : 1;
    return 0;
}

void xless_end_by_signal(int sig) { take_default(sig); }

// --- The steps of `xless run` ---

static int stop_pipe[2] = { -1, -1 };
static atomic_int stop_noted;
static atomic_int stops;
static atomic_int faulted, cleaned_up;
static pthread_t cleaner;

// Async-signal-safe.
static void note_stop(int sig) {
    int e = errno, none = 0;
    unsigned char byte = (unsigned char)sig;
    atomic_compare_exchange_strong(&stop_noted, &none, sig);
    atomic_fetch_add(&stops, 1);
    ssize_t n = write(stop_pipe[1], &byte, 1);
    (void)n; // full: it has said so already
    errno = e;
}

int xless_stop_signal(void) { return atomic_load(&stop_noted); }
int xless_stops(void) { return atomic_load(&stops); }

// Async-signal-safe. A thread of its own cleans up (xless_cleans_up), while this one, which is at fault, waits: not for ever,
// as it may hold what that one needs.
static void let_stop_clean_up(int sig) {
    if (!atomic_load(&has_cleaner) || pthread_equal(pthread_self(), cleaner)) return;
    atomic_store(&faulted, 1);
    note_stop(sig);
    struct timespec tenth = { 0, 100000000 };
    for (int i = 0; i < 600 && !atomic_load(&cleaned_up); i++) nanosleep(&tenth, NULL);
}

void xless_cleans_up(void) {
    handler_stack_on();
    cleaner = pthread_self();
    atomic_store(&has_cleaner, 1);
}

void xless_end_run(int code) {
    atomic_store(&cleaned_up, 1);
    while (atomic_load(&faulted)) pause(); // it ends as the fault does
    _exit(code);
}

int xless_take_stop_signals(void) {
    int e;
    if (stop_pipe[0] < 0) {
        if ((e = cloexec_pipe(stop_pipe)) != 0) return -e;
        fcntl(stop_pipe[1], F_SETFL, fcntl(stop_pipe[1], F_GETFL) | O_NONBLOCK);
    }
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = note_stop;
    action.sa_flags = SA_RESTART;
    sigemptyset(&action.sa_mask);
    atomic_store(&owner, getpid());
    for (int sig = 1; sig < NSIG; sig++) {
        struct sigaction now;
        if (what_is(sig) == ENDS && sigaction(sig, NULL, &now) == 0 && now.sa_handler != SIG_IGN) sigaction(sig, &action, NULL);
    }
    faults_on();
    return stop_pipe[0];
}

int xless_spawn_step(const char *path, char *const argv[], char *const envp[], const char *cwd, int out_fd, int err_fd,
                     const struct xless_filter *filter, int *pid) {
    int status[2], e;
    if ((e = cloexec_pipe(status)) != 0) return e;
    // Blocked until the child has its own dispositions: a signal must not run this process's handlers in it.
    sigset_t all, before;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &before);
    pid_t child = fork();
    if (child < 0) {
        e = errno;
        pthread_sigmask(SIG_SETMASK, &before, NULL);
        close(status[0]); close(status[1]);
        return e;
    }
    if (child == 0) {
        // Only async-signal-safe calls from here to execve.
        int report = status[1];
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            struct sigaction now;
            if (sig == SIGHUP && sigaction(sig, NULL, &now) == 0 && now.sa_handler == SIG_IGN) continue; // nohup: for the steps too
            signal(sig, sig == SIGINT || sig == SIGQUIT ? SIG_IGN : SIG_DFL);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (report < 3 && (report = fcntl(report, F_DUPFD_CLOEXEC, 3)) < 0) _exit(127); // xless started with stdio closed
        int out = out_fd < 0 ? -1 : fcntl(out_fd, F_DUPFD_CLOEXEC, 3);
        int err = err_fd < 0 ? -1 : fcntl(err_fd, F_DUPFD_CLOEXEC, 3);
        if ((out_fd >= 0 && (out < 0 || dup2(out, 1) < 0)) || (err_fd >= 0 && (err < 0 || dup2(err, 2) < 0))) { e = errno; goto failed; }
        int null = open("/dev/null", O_RDONLY);
        if (null < 0 || (null != 0 && dup2(null, 0) < 0)) { e = errno; goto failed; }
        if (cwd != NULL && chdir(cwd) != 0) { e = errno; goto failed; }
        close_from_3(report);
        // The last thing: from here it and what it starts are under it.
        if (filter != NULL && (e = confine(filter)) != 0) { e = -e; goto failed; }
        execve(path, argv, envp);
        e = errno;
    failed:
        while (write(report, &e, sizeof e) < 0 && errno == EINTR) {}
        _exit(127);
    }
    pthread_sigmask(SIG_SETMASK, &before, NULL);
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
#elif defined(__APPLE__)
    (void)minherit(p, length, VM_INHERIT_NONE);
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
int xless_process_file(int pid, uint64_t *device, uint64_t *inode) {
    if (pid != getpid()) return ENOTSUP;
    struct stat st;
    if (stat("/proc/self/exe", &st) != 0) return errno;
    *device = (uint64_t)st.st_dev;
    *inode = (uint64_t)st.st_ino;
    return 0;
}

int xless_acl_lets_others_write(const char *path, unsigned int uid) { (void)path; (void)uid; return 0; }

int xless_peer_of(int fd, struct xless_peer *out) { (void)fd; memset(out, 0, sizeof *out); return ENOTSUP; }

int xless_own_token(struct xless_peer *out) { memset(out, 0, sizeof *out); return ENOTSUP; }

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

long xless_unix_peer_pid(int fd) {
    struct ucred cred;
    socklen_t length = sizeof cred;
    return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) == 0 ? (long)cred.pid : -errno;
}

int xless_peer_kill(const struct xless_peer *peer) { (void)peer; return ENOTSUP; }

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

long xless_process_program(int pid, char *buffer, size_t length) {
    char path[64];
    if (pid <= 0) return -1;
    snprintf(path, sizeof path, "/proc/%d/exe", pid);
    return readlink(path, buffer, length);
}
#elif defined(__APPLE__)
int xless_process_file(int pid, uint64_t *device, uint64_t *inode) {
    // The program is what a process has mapped lowest: before it are only anonymous regions.
    uint64_t at = 0;
    for (int i = 0; i < 64; i++) {
        struct proc_regionwithpathinfo region;
        memset(&region, 0, sizeof region);
        errno = 0;
        if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, at, &region, sizeof region) < (int)sizeof region) return errno ? errno : ESRCH;
        const struct vinfo_stat *file = &region.prp_vip.vip_vi.vi_stat;
        if (file->vst_ino != 0) {
            *device = (uint64_t)file->vst_dev;
            *inode = file->vst_ino;
            return 0;
        }
        if (region.prp_prinfo.pri_size == 0) break;
        at = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size;
    }
    return ENOENT;
}

int xless_acl_lets_others_write(const char *path, unsigned int uid) {
    static const acl_perm_t writing[] = { ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER };
    errno = 0;
    acl_t list = acl_get_link_np(path, ACL_TYPE_EXTENDED);
    if (!list) return errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP ? 0 : -(errno ? errno : EIO); // (ENOENT: it has none)
    int result = 0, which = ACL_FIRST_ENTRY;
    acl_entry_t entry;
    while (result == 0 && acl_get_entry(list, which, &entry) == 0) {
        which = ACL_NEXT_ENTRY;
        acl_tag_t tag;
        acl_permset_t permissions;
        if (acl_get_tag_type(entry, &tag) != 0 || acl_get_permset(entry, &permissions) != 0) { result = -EIO; break; }
        if (tag != ACL_EXTENDED_ALLOW) continue;
        int writes = 0;
        for (size_t i = 0; i < sizeof writing / sizeof *writing; i++) writes |= acl_get_perm_np(permissions, writing[i]) != 0;
        if (!writes) continue;
        void *who = acl_get_qualifier(entry);
        if (!who) { result = -EIO; break; }
        uid_t id = 0;
        int kind = -1, known = mbr_uuid_to_id(who, &id, &kind) == 0;
        acl_free(who);
        if (known && kind == ID_TYPE_UID && (id == 0 || id == uid)) continue;
        if (known && kind == ID_TYPE_GID && (id == 0 || id == 80)) continue;
        result = 1;
    }
    acl_free(list);
    return result;
}

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
    errno = 0;
    int named = proc_pidpath_audittoken(&token, path, sizeof path) > 0;
    if (!named && errno != ENOENT) return ESRCH; // ENOENT: it runs, and its file was removed
    // Where a file was put in the place of the one it runs (an upgrade), the path names the new one: the program is told
    // only when the file at the path is the one the process has mapped.
    struct stat st;
    uint64_t device, inode;
    if (named && stat(path, &st) == 0 && xless_process_file(pid, &device, &inode) == 0
        && device == (uint64_t)(uint32_t)st.st_dev && inode == (uint64_t)st.st_ino) {
        out->exe_device = device;
        out->exe_inode = inode;
    }
    // It is still that process: what was asked by its pid is of it.
    audit_token_t again;
    length = sizeof again;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &again, &length) != 0 || memcmp(&again, &token, sizeof token) != 0) return ESRCH;
    memcpy(out->token, &token, sizeof out->token);
    out->pid = pid;
    out->uid = euid;
    out->sid = sid;
    return 0;
}

int xless_own_token(struct xless_peer *out) {
    memset(out, 0, sizeof *out);
    audit_token_t own;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&own, &count) != KERN_SUCCESS) return ESRCH;
    memcpy(out->token, &own, sizeof out->token);
    return 0;
}

int xless_unix_passcred(int fd) { (void)fd; return 0; }

long xless_unix_recv(int fd, void *bytes, size_t length, int *pid, unsigned int *uid) {
    uid_t euid;
    gid_t egid;
    *pid = 0;
    if (getpeereid(fd, &euid, &egid) != 0) return -errno;
    *uid = euid;
    // Descriptors sent along are opened here also when there is no room to be told of them, and what is not told of can
    // not be closed: room for more than one send carries (2048 bytes), and everything is closed.
    struct iovec iov = { bytes, length };
    union { char bytes[8192]; struct cmsghdr align; } control;
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    m.msg_control = control.bytes;
    m.msg_controllen = sizeof control.bytes;
    ssize_t n;
    do { n = recvmsg(fd, &m, 0); } while (n < 0 && errno == EINTR);
    if (n < 0) return -errno;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c != NULL; c = CMSG_NXTHDR(&m, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || c->cmsg_len < CMSG_LEN(0)) continue;
        // A header that was cut short says the length it had.
        const char *end = (const char *)c + c->cmsg_len, *room = control.bytes + m.msg_controllen;
        for (const char *at = (const char *)CMSG_DATA(c); at + sizeof(int) <= (end < room ? end : room); at += sizeof(int)) {
            int sent;
            memcpy(&sent, at, sizeof sent);
            close(sent);
        }
    }
    return (m.msg_flags & MSG_CTRUNC) ? -EBADMSG : (long)n;
}

long xless_unix_peer_uid(int fd) {
    uid_t euid;
    gid_t egid;
    return getpeereid(fd, &euid, &egid) == 0 ? (long)euid : -errno;
}

long xless_unix_peer_pid(int fd) {
    pid_t pid = 0;
    socklen_t length = sizeof pid;
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? (long)pid : -errno;
}

int xless_peer_kill(const struct xless_peer *peer) {
    // Not in every release this runs on.
    int (*signal_with_token)(audit_token_t *, int) = (int (*)(audit_token_t *, int))dlsym(RTLD_DEFAULT, "proc_signal_with_audittoken");
    if (signal_with_token == NULL) return ENOTSUP;
    audit_token_t token;
    memcpy(&token, peer->token, sizeof token);
    return signal_with_token(&token, SIGKILL);
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

long xless_process_program(int pid, char *buffer, size_t length) {
    if (pid <= 0 || length > PROC_PIDPATHINFO_MAXSIZE) return -1;
    int n = proc_pidpath(pid, buffer, (uint32_t)length);
    return n > 0 ? n : -1;
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
