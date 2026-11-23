#ifndef CXLESS_PROCESS_H
#define CXLESS_PROCESS_H

#include <stddef.h>
#include <stdint.h>

/// Sets RLIMIT_CORE to 0 and, on Linux, marks the process non-dumpable (PR_SET_DUMPABLE 0: no core file, no same-user
/// ptrace or /proc/<pid>/mem). Returns 0 when both took effect. prctl is variadic, so Swift cannot call it directly.
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

/// Starts `path` with `argv` and `envp` (NULL-terminated) in a process group of its own (its pid), with every signal at
/// its default disposition and none blocked. Its stdin and stdout are pipes whose other ends come back in `*in_fd` and
/// `*out_fd` (close-on-exec, non-blocking); its stderr is this process's. Returns 0, or an errno value (nothing started).
int xless_spawn_piped(const char *path, char *const argv[], char *const envp[], int *pid, int *in_fd, int *out_fd);

/// write(2) that never raises SIGPIPE in this process: a reader that went away gives -1 with errno EPIPE.
long xless_write_nosigpipe(int fd, const void *bytes, size_t length);

/// waitpid(2) for `pid` (WNOHANG when `nohang`): 1 when it ended (`*code`: its exit status, or 128 + the signal that
/// killed it), 0 while it runs, -1 on error.
int xless_reap(int pid, int nohang, int *code);

#endif
