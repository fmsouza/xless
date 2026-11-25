#ifndef CXLESS_WINDOWS_TEST_SUPPORT_H
#define CXLESS_WINDOWS_TEST_SUPPORT_H

#include <stddef.h>
#include <stdint.h>
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
/// Whether a fault of this process shows no dialog (what SecretScope asks for first): 1 or 0.
int xless_test_hardening(void);
/// LoadLibraryW, whatever the DLL is (none of its code is run).
unsigned long xless_test_load(const wchar_t *name);
/// Ends this process as a program error does: "fault" (a read of nothing) or "abort".
void xless_test_crash(const char *how);

/// Sockets of a server on 127.0.0.1, at a free port; -1 where something fails.
intptr_t xless_test_listen(uint16_t *port);
intptr_t xless_test_accept(intptr_t listener);
/// The one who accepts there is told -1, and the listener closed.
void xless_test_stop(intptr_t listener);
intptr_t xless_test_connect(uint16_t port);
int64_t xless_test_receive(intptr_t connection, void *bytes, size_t length);
int64_t xless_test_send(intptr_t connection, const void *bytes, size_t length);
/// Nothing more is sent; what the other end sends is thrown away for a moment, so that it reads the rest before the end.
void xless_test_finish(intptr_t connection);
/// As a program that dies: `xless_test_finish` tells the other end of it at once.
void xless_test_reset(intptr_t connection);
/// Of a socket that nobody else uses.
void xless_test_close(intptr_t socket);

/// A program on a pseudo console (ConPTY), as Windows Terminal starts one.
struct xless_test_console;
/// `bare`: without standard handles, instead of the console's. NULL: `*code`.
struct xless_test_console *xless_test_console_start(const wchar_t *command, const wchar_t *directory, int bare, unsigned long *code);
/// This process's standard handle `which` (input, output, error) becomes a pipe of that name, which is made, or a file. 0, or a Windows error.
unsigned long xless_test_set_standard(int which, const wchar_t *name);
unsigned long xless_test_console_process(struct xless_test_console *console);
/// What is typed.
unsigned long xless_test_console_type(struct xless_test_console *console, const char *bytes, size_t length);
/// What the console shows that was not read before: its length, 0 when there is nothing within the time, -1 at its end.
int64_t xless_test_console_read(struct xless_test_console *console, char *out, size_t length, unsigned int milliseconds);
/// Closes the console, as its window's cross does.
void xless_test_console_hang_up(struct xless_test_console *console);
/// The program's exit code, or -1 when it does not end within the time.
int64_t xless_test_console_wait(struct xless_test_console *console, unsigned int milliseconds);
void xless_test_console_end(struct xless_test_console *console);

#endif
