#ifndef CXLESS_WINDOWS_TEST_SUPPORT_H
#define CXLESS_WINDOWS_TEST_SUPPORT_H

#include <stddef.h>
#include <wchar.h>

// What the tests on Windows do to files, and to themselves. 0, or the Windows error, where nothing else is said.

/// Owner and access list of `path` as SDDL, into `out`.
unsigned long xless_test_security(const wchar_t *path, wchar_t *out, size_t length);
/// Sets what `sddl` has of them (the list protected when it says so).
unsigned long xless_test_set_security(const wchar_t *path, const wchar_t *sddl);
/// `sddl` as Windows writes it (an account's SID may have a short name), into `out`.
unsigned long xless_test_normal(const wchar_t *sddl, wchar_t *out, size_t length);
/// Takes the privilege to open any process from this one (PowerShell gives it to what an administrator starts there).
void xless_test_drop_debug_privilege(void);
/// Whether this process may give a file to another owner: 1 or 0.
int xless_test_may_set_owner(void);
unsigned long xless_test_hard_link(const wchar_t *link, const wchar_t *existing);
/// A junction `link`, which is made, to the directory `target`.
unsigned long xless_test_junction(const wchar_t *link, const wchar_t *target);
/// Windows' error reporting sees a crash of this process, whatever the process that started it asked for.
void xless_test_allow_reports(void);
/// Ends this process as a program error does: "fault" (a read of nothing) or "abort".
void xless_test_crash(const char *how);

#endif
