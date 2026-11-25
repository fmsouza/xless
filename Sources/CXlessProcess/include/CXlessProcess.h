#ifndef CXLESS_PROCESS_H
#define CXLESS_PROCESS_H

#include <stddef.h>
#include <stdint.h>

/// No core dump of this process nor of what it starts: RLIMIT_CORE 0, and on Linux 1, which makes no file either (the kernel
/// wants room for a page at least) and is the one value with which a core_pattern that is a program (`|…`) is not started: the
/// kernel gives such a program the dump whatever other limit there is, 0 too. A hard limit of 0 that this process may not raise
/// stays 0. On Linux this process is not dumpable either (PR_SET_DUMPABLE 0: no core dump at all, no same-user ptrace or
/// /proc/<pid>/mem), which what it starts does not inherit. Returns 0 when both took effect. prctl is variadic, so Swift cannot
/// call it directly.
int xless_disable_core_dumps(void);

/// The soft RLIMIT_CORE, or -1 for unlimited or on error.
long long xless_core_file_limit(void);

/// PR_GET_DUMPABLE on Linux (0 or 1); -1 elsewhere.
int xless_dumpable(void);

/// Overwrites `length` bytes at `bytes` with zeros in a way the compiler may not drop as a dead store
/// (explicit_bzero on Linux, memset_s on Apple platforms).
void xless_secure_zero(void *bytes, size_t length);

/// The Linux kernel keyring through raw syscalls (add_key(2), keyctl(2)), so the static musl build needs no libkeyutils.
/// Each returns what the syscall returns (-1 with errno set on failure); elsewhere than Linux, -1 with errno ENOSYS.
/// `keyring` is a serial or a special ID such as XLESS_KEY_SPEC_SESSION_KEYRING.
#define XLESS_KEY_SPEC_SESSION_KEYRING (-3)
/// The user's default session keyring, which every process of the user can reach (possessed) by this ID.
#define XLESS_KEY_SPEC_USER_SESSION_KEYRING (-5)

/// add_key("user", description, payload, length, keyring): the new key's serial.
long xless_key_add(const char *description, const void *payload, size_t length, int32_t keyring);
/// KEYCTL_SEARCH for a "user" key named `description` in `keyring` (and the keyrings it links): its serial.
long xless_key_search(int32_t keyring, const char *description);
/// KEYCTL_READ: copies at most `length` bytes of the payload into `buffer` (NULL/0 asks for the size); the full size.
long xless_key_read(int32_t key, void *buffer, size_t length);
/// KEYCTL_REVOKE: the key can no longer be read; the kernel drops it.
long xless_key_revoke(int32_t key);
/// KEYCTL_SET_TIMEOUT: the kernel expires the key `seconds` from now (0 clears the timeout).
long xless_key_set_timeout(int32_t key, unsigned int seconds);
/// KEYCTL_SETPERM: the key's permission mask (see KernelKeyring.possessorOnly).
long xless_key_setperm(int32_t key, uint32_t permissions);
/// KEYCTL_DESCRIBE: "type;uid;gid;perm;description" (perm in hex) into `buffer`; the full size including the NUL.
long xless_key_describe(int32_t key, char *buffer, size_t length);
/// KEYCTL_GET_KEYRING_ID for `keyring` without creating it: its serial (a probe for whether keyrings work at all).
long xless_key_keyring_id(int32_t keyring);
/// KEYCTL_JOIN_SESSION_KEYRING(NULL): this process (and the children it starts from now on) gets a new, empty anonymous
/// session keyring, and no longer possesses the one it had: keys kept there (possessor-only) are out of its reach.
long xless_key_join_new_session(void);

/// Whether `path` is on a memory file system (Linux statfs: tmpfs or ramfs): 1 yes, 0 no, -1 on error or elsewhere
/// than Linux. Where a run's materialised secrets may go without touching a disk.
int xless_is_memory_fs(const char *path);

// --- On the kernel of WSL ---

/// A seccomp filter, as the kernel takes it.
struct xless_instruction { uint16_t code; uint8_t if_true, if_false; uint32_t value; };
struct xless_filter { const struct xless_instruction *program; unsigned short length; };

/// What keeps a process on the kernel of WSL, and all that it starts, from Windows' own sockets (AF_VSOCK), over which a Windows
/// program is started and a Windows drive is mounted. EACCES for socket(AF_VSOCK) and for io_uring_setup (a ring opens sockets
/// without socket(2)); a system call of another architecture (a 32-bit program has socketcall(2)) or of the x32 ABI kills the
/// process; everything else is as it was. One for each processor xless is built for; on another one, and on another system, a
/// filter without a program, which cannot be set.
const struct xless_filter *xless_windows_filter(void);
const struct xless_filter *xless_windows_filter_x86_64(void);
const struct xless_filter *xless_windows_filter_arm64(void);

/// Whether the release of a kernel, as uname(2) has it, says that it is WSL's.
int xless_is_wsl_release(const char *release);
/// Whether this system's kernel is WSL's, as the kernel says (a container's too).
int xless_is_wsl_kernel(void);

/// Starts `path` with `argv` and `envp` (NULL-terminated) in a process group of its own (its pid), with every signal at
/// its default disposition and none blocked. Its stdin and stdout are pipes whose other ends come back in `*in_fd` and
/// `*out_fd` (close-on-exec, non-blocking); its stderr is this process's; every other descriptor is closed in it.
/// `tty`: the controlling terminal, when this process is its foreground, else -1: the child's group becomes the
/// terminal's foreground (so it can prompt on /dev/tty, and Ctrl-C reaches it) until `xless_terminal_restore`.
/// -2: the child leads a session of its own instead, with no terminal to ask anything on.
/// Returns 0, or an errno value (nothing left running: execve's own error, e.g. ETXTBSY, comes back).
int xless_spawn_piped(const char *path, char *const argv[], char *const envp[], int tty, int *pid, int *in_fd, int *out_fd);

/// Makes this process's group the foreground of `tty` again (nothing for -1).
void xless_terminal_restore(int tty);

/// write(2) that never raises SIGPIPE in this process: a reader that went away gives -1 with errno EPIPE.
long xless_write_nosigpipe(int fd, const void *bytes, size_t length);

/// waitpid(2) for `pid` (WNOHANG when `nohang`): 1 when it ended (`*code`: its exit status, or 128 + the signal that
/// killed it), 0 while it runs, -1 on error.
int xless_reap(int pid, int nohang, int *code);

/// Starts `path` with `argv` and `envp` (NULL-terminated) in a new POSIX session (setsid: its pid is its session and
/// process group, and it has no controlling terminal), with every signal at its default disposition and none blocked.
/// Its stdin is this process's, or /dev/null when that is a terminal; stdout and stderr are `out_fd` and `err_fd` (-1: this process's); every other descriptor
/// is closed in it. `cwd`: its directory, or NULL. Returns 0 (`*pid`), or an errno value (nothing left running).
/// On Linux the child gets the calling thread's credentials (its session keyring).
/// `filter`: NULL, or the seccomp filter that it, and all that it starts, runs under, for good, and with it without the
/// privileges that a file may have (setuid, file capabilities). One that cannot be set is an error, and nothing is started: the
/// errno value's negative.
/// A signal that ends this process is passed on to its process group from here to `xless_wait` (its session gets none from a
/// terminal): this process's handlers (installed where the disposition is the default, not where it is ignored) tell every
/// tool that runs, SIGINT, SIGTERM and SIGHUP as they are and SIGTERM for any other, and then take the signal's default
/// action. The same for a fault of this process's own (SIGSEGV, SIGABRT, ...), also where a handler of another's is (which
/// comes after).
int xless_spawn_session(const char *path, char *const argv[], char *const envp[], const char *cwd, int out_fd, int err_fd,
                        const struct xless_filter *filter, int *pid);

/// waitpid(2) for `pid`: 1 when it ended (`*status`: its exit status, or the signal that killed it), -1 on error.
int xless_wait(int pid, int *status);

/// A signal that ends this process (any that can be caught; those that are ignored stay ignored) removes the file at `path`
/// first (a directory: once it is empty), from a signal handler. Call it before the file is made. Returns what to give
/// `xless_keep_when_ended`, or NULL: there is no memory.
void *xless_remove_when_ended(const char *path, int is_directory);
/// Forgets it: it is gone, or not private any more.
void xless_keep_when_ended(void *entry);

/// macOS: the path of the file at `path` as its file system holds it, which is on the data volume (/System/Volumes/Data) for what
/// macOS shows in / of it, into `buffer`: its length, or -1 (it cannot be told; elsewhere: never).
long xless_physical_path(const char *path, char *buffer, size_t length);

/// This process's variables (environ).
char *const *xless_environment(void);

/// Whether `pid` is a tool that signals are passed on to.
int xless_tool_runs(int pid);

/// Runs `path` with `argv` and `envp` (NULL-terminated) as a shell runs a script: in this process's session and process
/// group, with its terminal, working directory and every descriptor that is not close-on-exec; and waits for it. Meanwhile
/// SIGTERM and SIGHUP are passed on to it, and SIGINT and SIGQUIT when the terminal did not send them (it sends them to
/// the whole group), and this process goes on; those that are ignored stay so, for both. Returns 0 (`*status`: its exit
/// status, or the signal that ended it and `*by_signal` 1), or an errno value (nothing was started).
int xless_run_foreground(const char *path, char *const argv[], char *const envp[], int *status, int *by_signal);

/// Ends this process as `sig` does by default.
void xless_end_by_signal(int sig);

/// Starts `path` with `argv` and `envp` (NULL-terminated) as a step of a run (`xless run`): in this process's session and
/// process group, so that it may ask on the terminal and has what is held for the session; with nothing to read
/// (/dev/null), SIGINT and SIGQUIT ignored (the run stops its steps itself), every other signal at its default disposition
/// and none blocked. stdout and stderr are `out_fd` and `err_fd` (-1: this process's); every other descriptor is closed in
/// it. `cwd`: its directory, or NULL. `filter`: as of xless_spawn_session. Returns 0 (`*pid`), or an errno value (nothing left
/// running; of the filter, its negative).
int xless_spawn_step(const char *path, char *const argv[], char *const envp[], const char *cwd, int out_fd, int err_fd,
                     const struct xless_filter *filter, int *pid);

/// From here on the signals that end a process are noted instead of ending this one (those that are ignored stay ignored): the
/// descriptor returned gives one byte, the signal's number, for each. A fault of this process's own is noted too, and ends it
/// once `xless_end_run` is called, or after a minute. -errno on failure.
int xless_take_stop_signals(void);
/// The first signal noted since; 0: none.
int xless_stop_signal(void);
/// How many were.
int xless_stops(void);
/// This thread is the one that reads that descriptor and cleans up (a fault of its own ends the process at once).
void xless_cleans_up(void);
/// It has: ends this process with `code`, without anything more of its own; by the signal, when it was a fault.
void xless_end_run(int code) __attribute__((noreturn));

/// Sets `sig` back to what it does by default: to end this process, and (where it would be passed on) the tools it runs.
/// Async-signal-safe.
void xless_signal_default(int sig);

// --- The xless agent (XlessAgent): its clocks, its memory, its sockets and who is at the other end of one ---

/// Milliseconds on a clock that counts while the system sleeps (Linux CLOCK_BOOTTIME, macOS mach_continuous_time).
int64_t xless_clock_continuous_ms(void);
/// Milliseconds on a clock that stops while the system sleeps: the difference between the two grows by the sleep.
int64_t xless_clock_awake_ms(void);

/// `size` zeroed bytes (rounded up to whole pages) of their own mapping, kept out of core dumps and forked children, and
/// locked against swap when the limits allow (`*locked`). NULL on failure.
void *xless_secret_map(size_t size, int *locked);
/// Zeroes and unmaps what `xless_secret_map(size)` returned.
void xless_secret_unmap(void *bytes, size_t size);

/// macOS: refuses a debugger for this process (PT_DENY_ATTACH; ends the process when one is attached). Elsewhere
/// nothing (Linux: see xless_disable_core_dumps). Returns 0.
int xless_deny_attach(void);

/// The file of the program the process runs, also when another one has its name since. macOS: of any process of the user;
/// Linux: of this process. 0, or an errno value.
int xless_process_file(int pid, uint64_t *device, uint64_t *inode);

/// Whether the access control list of `path` (not of what a link names) lets anybody else than root, `uid` and the administrators of
/// the Mac (the groups wheel and admin) change it. 1 or 0, or a negative errno value when it cannot be told. Linux has none: 0.
int xless_acl_lets_others_write(const char *path, unsigned int uid);

/// Who is at the other end of a connected Unix socket, as the kernel says.
struct xless_peer {
    int pid;
    unsigned int uid;
    int sid;              // its POSIX session
    uint64_t exe_device;  // its executable file (macOS; 0 elsewhere, and where that file was replaced or removed since)
    uint64_t exe_inode;
    uint32_t token[8];    // its audit token (macOS): the last member is the process version, which no two processes share
};
/// macOS: fills `*out` for the process that has, at this moment, the pid of the one that last used the other end: the
/// kernel keeps that pid only (LOCAL_PEERTOKEN), so once that process has ended this fails (EINVAL) or, when the pid was
/// given out again, describes another one. The same peer has the same token: keep the first and compare. Everything in
/// `*out` is of one process. 0, or an errno value (ENOTSUP elsewhere: Linux has the sender's pid on each message, see
/// xless_unix_recv, and a pidfd to hold it by).
int xless_peer_of(int fd, struct xless_peer *out);
/// macOS: this process's own audit token, in `out->token` (the rest is 0). 0, or an errno value (ENOTSUP elsewhere).
/// The whole struct, for Swift: a pointer to the first number of an array in a tuple is one to that number only.
int xless_own_token(struct xless_peer *out);
/// Linux: asks for the sender's credentials on each message received on `fd`. Elsewhere nothing. 0, or an errno value.
int xless_unix_passcred(int fd);
/// recv(2): the bytes received (0: the other end closed), or -errno. Linux: with the pid and uid of the process that
/// sent them, which the kernel vouches for (pid 0: it is in another PID namespace, or said nothing). Elsewhere `*pid`
/// is 0 and `*uid` is the effective uid of the other end. Descriptors sent along are not kept: Linux opens none, macOS
/// does and they are closed at once.
long xless_unix_recv(int fd, void *bytes, size_t length, int *pid, unsigned int *uid);
/// The effective uid of the process that connected the other end, or listened for it; -errno on failure.
long xless_unix_peer_uid(int fd);
/// The pid of the process that listened for the other end (Linux) or used it last (macOS), which may have ended since;
/// -errno on failure.
long xless_unix_peer_pid(int fd);
/// macOS: kills (SIGKILL) the process of the peer's audit token, and no other one that has its pid by now. 0, or an errno
/// value (ENOTSUP where the system cannot do that).
int xless_peer_kill(const struct xless_peer *peer);
/// Linux: a close-on-exec descriptor that stands for the process `pid`; -errno on failure (ENOSYS before Linux 5.3, and
/// elsewhere).
int xless_pidfd_open(int pid);
/// 1 while the process of a pidfd runs, 0 once it has ended: while it runs, its pid is its own.
int xless_pidfd_alive(int pidfd);

/// When the process `pid` started, as an opaque non-zero number that a later process with the same pid does not share;
/// 0 when there is no such process (or it cannot be seen, or it has ended).
uint64_t xless_process_start(int pid);
/// The file that the process `pid` runs, into `buffer`: its length, or -1 (there is no such process, or it is not to be seen).
long xless_process_program(int pid, char *buffer, size_t length);

/// A close-on-exec, non-blocking Unix stream socket bound to `path` (mode 0600) and listening; -errno on failure.
int xless_unix_listen(const char *path, int backlog);
/// One connected to `path`; -errno on failure (EAGAIN: its queue is full).
int xless_unix_connect(const char *path);
/// The next connection of a listening socket, close-on-exec and non-blocking; -errno on failure.
int xless_unix_accept(int fd);
/// A connected pair, both close-on-exec and non-blocking. 0, or an errno value.
int xless_unix_pair(int fds[2]);
/// send(2) without SIGPIPE: the bytes sent, or -errno.
long xless_unix_send(int fd, const void *bytes, size_t length);
/// The longest `path` xless_unix_listen and xless_unix_connect take.
size_t xless_unix_path_max(void);

/// Starts `path` with `argv` and an empty environment, detached: its parent is init, its directory /, its stdio
/// /dev/null, descriptor 3 is `channel`, every other one is closed, and it has no controlling terminal; hang-up and
/// terminal signals are ignored in it. It stays in this process's POSIX session, in a process group of its own, when
/// `same_session`; else it leads a new session and then stops leading it (a second fork), so it can never get a
/// terminal. Returns 0 or an errno value.
int xless_spawn_detached(const char *path, char *const argv[], int channel, int same_session);

#endif
