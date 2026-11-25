#ifndef CXLESS_WINDOWS_H
#define CXLESS_WINDOWS_H

#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

// What xless asks Windows for, behind C functions of its own, so that nothing depends on Swift's map of the Windows headers.
// The first part has the names and the meaning of CXlessProcess's, which other systems have.

#ifdef __cplusplus
extern "C" {
#endif

/// No error dialog and no error report (SetErrorMode), no heap in one that is made all the same (WerSetFlags), and a fault that
/// nothing handles, or abort(), ends the process there and then. 0 when that is so, else which of it is not (a small number).
/// What else there is, as far as Windows lets it: the process's own access list leaves its user no reading of its memory and no
/// copying of its handles, and nobody but the system more; no DLL of an extension point, from a share or with a low integrity
/// label is loaded; System32's is preferred; a bad handle is a fault. There is no way back.
int xless_disable_core_dumps(void);

/// What is in force, for tests and `xless_disable_core_dumps` itself: bits of XLESS_HARDENED_*.
#define XLESS_HARDENED_ERROR_MODE 1u
#define XLESS_HARDENED_NO_HEAP_REPORT 2u
#define XLESS_HARDENED_EXTENSION_POINTS 4u
#define XLESS_HARDENED_REMOTE_IMAGES 8u
#define XLESS_HARDENED_LOW_LABEL_IMAGES 16u
#define XLESS_HARDENED_SYSTEM32_FIRST 32u
#define XLESS_HARDENED_STRICT_HANDLES 64u
#define XLESS_HARDENED_PROCESS_ACCESS 128u
unsigned int xless_hardening(void);

/// Whether a process of this user that asks the system for it may read this process's memory (asked of the system, with a new
/// handle): 1, 0, or -1 when it cannot be told.
int xless_memory_may_be_read(void);

void xless_secure_zero(void *bytes, size_t length);

/// There is no kernel keyring: -1 with errno ENOSYS, every one of them.
#define XLESS_KEY_SPEC_SESSION_KEYRING (-3)
#define XLESS_KEY_SPEC_USER_SESSION_KEYRING (-5)
intptr_t xless_key_add(const char *description, const void *payload, size_t length, int32_t keyring);
intptr_t xless_key_search(int32_t keyring, const char *description);
intptr_t xless_key_read(int32_t key, void *buffer, size_t length);
intptr_t xless_key_revoke(int32_t key);
intptr_t xless_key_set_timeout(int32_t key, unsigned int seconds);
intptr_t xless_key_setperm(int32_t key, uint32_t permissions);
intptr_t xless_key_describe(int32_t key, char *buffer, size_t length);
intptr_t xless_key_keyring_id(int32_t keyring);
intptr_t xless_key_join_new_session(void);

/// Milliseconds since the system started, with the time it slept / without.
int64_t xless_clock_continuous_ms(void);
int64_t xless_clock_awake_ms(void);

// --- Files that only this user can read ---

/// Why a file or directory is not used.
enum xless_private_problem {
    XLESS_PRIVATE_NONE = 0,
    XLESS_PRIVATE_ERROR,          // a Windows error (`code`)
    XLESS_PRIVATE_MISSING,        // there is none of that name
    XLESS_PRIVATE_EXISTS,         // there is one of that name
    XLESS_PRIVATE_BAD_PATH,       // not a path on a drive: a device, a stream, ...
    XLESS_PRIVATE_LINK,           // a reparse point: a symbolic link, a junction, a cloud placeholder
    XLESS_PRIVATE_NOT_FILE,       // not a regular file
    XLESS_PRIVATE_NOT_DIRECTORY,
    XLESS_PRIVATE_HARD_LINKS,     // a file with more than one name
    XLESS_PRIVATE_OWNER,          // another's (`sid`)
    XLESS_PRIVATE_NO_DACL,        // open to everyone
    XLESS_PRIVATE_INHERITED,      // its access list, or an entry of it, is its directory's
    XLESS_PRIVATE_SHARED,         // an entry gives somebody else access (`sid`)
    XLESS_PRIVATE_UNKNOWN_ACE,    // an entry of a kind that cannot be judged
    XLESS_PRIVATE_NOT_LOCAL,      // on a share, or on a drive that is not built in
    XLESS_PRIVATE_NO_ACLS,        // on a file system without access lists
};

struct xless_private {
    int problem;
    unsigned long code;
};

/// `sid` below: whom the problem is about, as text ("S-1-1-0"). NULL, or XLESS_SID_LENGTH long.
#define XLESS_SID_LENGTH 192

/// Every path below is a path on a drive (C:/..., or what becomes one); anything else is XLESS_PRIVATE_BAD_PATH or, for a share,
/// XLESS_PRIVATE_NOT_LOCAL; so is, where `local` is asked for, one that does not name its drive. Every handle is closed by `xless_private_close`.
/// A handle is checked when it is opened, and the check is of the file it stands for: not a link, of the kind asked for, owned by
/// the user of this process's token, its access list its own (protected, nothing inherited) and letting in nobody but that user,
/// the system and the administrators; on a built-in drive when `local`.

/// Makes a directory that only the user has access to; one that is there is left as it is. 0, or -1.
int xless_private_make_directory(const wchar_t *path, struct xless_private *why);
/// An open directory, which nobody can rename or remove before it is closed. NULL: `why`.
void *xless_private_open_directory(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid);
/// A file to read. NULL: `why`.
void *xless_private_open(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid);
/// A file to lock, made when it is missing. NULL: `why`.
void *xless_private_open_lock(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid);
/// A new, empty file to write; when it is not as asked (a file system without access lists) it is removed again. NULL: `why`.
void *xless_private_create(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid);

/// Waits until this handle has the file locked; closing it unlocks. 0, or the Windows error.
unsigned long xless_private_lock(void *file);
/// The size, or -1 (`*code`).
int64_t xless_private_size(void *file, unsigned long *code);
/// What was read (0: the end) or written, or -1 (`*code`).
int64_t xless_private_read(void *file, void *bytes, size_t length, unsigned long *code);
int64_t xless_private_write(void *file, const void *bytes, size_t length, unsigned long *code);
/// On the disk. 0, or the Windows error.
unsigned long xless_private_flush(void *file);
/// The file gets the name `path`, which another one may have had, in one step. 0, or the Windows error.
unsigned long xless_private_replace(void *file, const wchar_t *path);
/// The file is removed when it is closed. 0, or the Windows error.
unsigned long xless_private_remove(void *file);
void xless_private_close(void *file);

/// Whether something has the name `path` (no link is followed): 1, 0, or -1 when it cannot be told.
int xless_path_exists(const wchar_t *path);

/// A regular file, to read: whoever it belongs to, through links unless `nolink`; never a device or a pipe. NULL: `why`.
void *xless_input_open(const wchar_t *path, int nolink, struct xless_private *why);
/// A new file with its directory's access list, to write. NULL: `why`.
void *xless_output_create(const wchar_t *path, struct xless_private *why);
/// `from` gets the name `to` (on the same drive), which no other may have unless `replace`. 0, or the Windows error.
unsigned long xless_move(const wchar_t *from, const wchar_t *to, int replace);

/// The path Windows has for what `path` names, links followed (\\\\?\\C:\\...), into `out`: its length, or 0 (nothing there, or not
/// to be told).
size_t xless_final_path(const wchar_t *path, wchar_t *out, size_t length);

/// %LOCALAPPDATA% as Windows has it for the user, whatever the variable says, into `out`: its length, or 0.
size_t xless_local_app_data(wchar_t *out, size_t length);

/// Windows' own words for an error code, without a line break, into `out`: their length, or 0.
size_t xless_error_text(unsigned long code, wchar_t *out, size_t length);

/// The user of this process's token as text, into `out` (XLESS_SID_LENGTH): 1, or 0.
int xless_user_sid(wchar_t *out);

#ifdef __cplusplus
}
#endif

#endif
