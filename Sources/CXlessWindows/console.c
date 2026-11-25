// Windows only (Package.swift): the process's start, its console, and Ctrl-C.
#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "CXlessWindows.h"

#include <windows.h>
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <werapi.h>

// MARK: - The process

static UINT output_page;

static void give_page_back(void) { SetConsoleOutputCP(output_page); }

// A program may be started without one of these: what it says then goes nowhere, and is no fault.
static void open_standard(FILE *stream, int descriptor, DWORD which) {
    HANDLE handle = GetStdHandle(which);
    if (handle && handle != INVALID_HANDLE_VALUE && GetFileType(handle) != FILE_TYPE_UNKNOWN) return;
    FILE *again; // of its own descriptor, which is what Foundation asks for
    if (freopen_s(&again, "NUL", descriptor ? "wb" : "rb", stream) == 0) _dup2(_fileno(again), descriptor);
}

unsigned long xless_process_start(void) {
    DWORD code = 0;
    if (!SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32)) code = GetLastError();
    if (!SetDllDirectoryW(L"") && !code) code = GetLastError(); // for a child process that searches the old way
    if (!HeapSetInformation(NULL, HeapEnableTerminationOnCorruption, NULL, 0) && !code) code = GetLastError();
    open_standard(stdin, 0, STD_INPUT_HANDLE);
    open_standard(stdout, 1, STD_OUTPUT_HANDLE);
    open_standard(stderr, 2, STD_ERROR_HANDLE);
    // Text is UTF-8 with the line ends it has; a file and a pipe get it as another system's would.
    fflush(stdout);
    if (_fileno(stdout) >= 0) _setmode(_fileno(stdout), _O_BINARY);
    if (_fileno(stderr) >= 0) _setmode(_fileno(stderr), _O_BINARY);
    DWORD mode;
    if (GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) || GetConsoleMode(GetStdHandle(STD_ERROR_HANDLE), &mode)) {
        output_page = GetConsoleOutputCP();
        if (output_page && output_page != CP_UTF8 && SetConsoleOutputCP(CP_UTF8)) atexit(give_page_back);
    }
    return code;
}

int xless_set_environment(const wchar_t *name, const wchar_t *value) { return _wputenv_s(name, value); } // sets both

void *xless_secret_map(size_t length, int *locked) {
    *locked = 0;
    void *pages = VirtualAlloc(NULL, length, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!pages) return NULL;
    if (VirtualLock(pages, length)) {
        *locked = 1;
    } else {
        // What a process may lock is what its working set may not go below.
        SIZE_T least, most;
        if (GetProcessWorkingSetSize(GetCurrentProcess(), &least, &most)
            && SetProcessWorkingSetSize(GetCurrentProcess(), least + length + (64u << 10), most + length + (64u << 10)))
            *locked = VirtualLock(pages, length) != 0;
    }
    if (length <= MAXDWORD) WerRegisterExcludedMemoryBlock(pages, (DWORD)length); // reports have no heap either way (xless_disable_core_dumps)
    return pages;
}

void xless_secret_unmap(void *pages, size_t length) {
    if (!pages) return;
    SecureZeroMemory(pages, length);
    WerUnregisterExcludedMemoryBlock(pages);
    VirtualUnlock(pages, length);
    VirtualFree(pages, 0, MEM_RELEASE);
}

// MARK: - The console

struct xless_console { HANDLE in, out; };

int xless_is_pseudo_terminal(const wchar_t *pipe, size_t length) {
    // \msys-dd50a72ab4668b33-pty0-from-master, \cygwin-...-pty1-to-master
    static const wchar_t *const prefixes[] = { L"\\msys-", L"\\cygwin-" };
    for (int i = 0; i < 2; i++) {
        size_t prefix = wcslen(prefixes[i]);
        if (length < prefix || _wcsnicmp(pipe, prefixes[i], prefix) != 0) continue;
        for (size_t at = prefix; at + 4 <= length; at++) if (_wcsnicmp(pipe + at, L"-pty", 4) == 0) return 1;
    }
    return 0;
}

static int is_pseudo_terminal(HANDLE handle) {
    if (!handle || handle == INVALID_HANDLE_VALUE || GetFileType(handle) != FILE_TYPE_PIPE) return 0;
    struct { FILE_NAME_INFO info; wchar_t more[512]; } name;
    if (!GetFileInformationByHandleEx(handle, FileNameInfo, &name, sizeof name)) return 0;
    return xless_is_pseudo_terminal(name.info.FileName, name.info.FileNameLength / sizeof(wchar_t));
}

struct xless_console *xless_console_open(int *problem, unsigned long *code) {
    *code = 0;
    const DWORD standard[3] = { STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE };
    int connected = 0;
    for (int i = 0; i < 3; i++) {
        HANDLE handle = GetStdHandle(standard[i]);
        DWORD mode;
        // An old mintty has a hidden console behind its pipes: it would be asked where nobody sees it.
        if (is_pseudo_terminal(handle)) { *problem = XLESS_CONSOLE_PSEUDO; return NULL; }
        if (handle && handle != INVALID_HANDLE_VALUE && GetConsoleMode(handle, &mode)) connected = 1;
    }
    *problem = XLESS_CONSOLE_ABSENT;
    if (!connected) return NULL;
    struct xless_console *c = calloc(1, sizeof *c);
    if (!c) { *problem = XLESS_CONSOLE_ERROR; *code = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    c->in = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    c->out = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    DWORD mode;
    if (c->in == INVALID_HANDLE_VALUE || c->out == INVALID_HANDLE_VALUE || !GetConsoleMode(c->in, &mode) || !GetConsoleMode(c->out, &mode)) {
        *code = GetLastError();
        xless_console_close(c);
        return NULL;
    }
    *problem = XLESS_CONSOLE_NONE;
    return c;
}

void xless_console_close(struct xless_console *c) {
    if (!c) return;
    if (c->in && c->in != INVALID_HANDLE_VALUE) CloseHandle(c->in);
    if (c->out && c->out != INVALID_HANDLE_VALUE) CloseHandle(c->out);
    free(c);
}

void xless_console_write(struct xless_console *c, const wchar_t *text, size_t length) {
    while (length) {
        DWORD put = 0;
        if (!WriteConsoleW(c->out, text, length > 4096 ? 4096 : (DWORD)length, &put, NULL) || !put) return;
        text += put;
        length -= put;
    }
}

// The question that is being asked, for Ctrl-C.
static SRWLOCK asking = SRWLOCK_INIT;
static HANDLE asked_in, asked_out;
static DWORD asked_mode;

static BOOL WINAPI give_mode_back(DWORD event) {
    (void)event; // Ctrl-C, Ctrl-Break, the console closed, the user logs off, the system ends
    AcquireSRWLockExclusive(&asking);
    if (!asked_in) { ReleaseSRWLockExclusive(&asking); return FALSE; }
    FlushConsoleInputBuffer(asked_in);
    SetConsoleMode(asked_in, asked_mode);
    DWORD put;
    WriteConsoleW(asked_out, L"\r\n", 2, &put, NULL);
    TerminateProcess(GetCurrentProcess(), 130); // holding the lock: the one who reads does not come back
    return TRUE;
}

static int begin_asking(struct xless_console *c, DWORD saved) {
    AcquireSRWLockExclusive(&asking);
    asked_in = c->in;
    asked_out = c->out;
    asked_mode = saved;
    ReleaseSRWLockExclusive(&asking);
    // Ctrl-C ends a question, also where this process was started to ignore it.
    return SetConsoleCtrlHandler(NULL, FALSE) && SetConsoleCtrlHandler(give_mode_back, TRUE);
}

static void end_asking(void) {
    AcquireSRWLockExclusive(&asking);
    asked_in = NULL;
    ReleaseSRWLockExclusive(&asking);
    SetConsoleCtrlHandler(give_mode_back, FALSE);
}

// Reads what there is, one character at least: how many, or -1.
static int read_console(struct xless_console *c, wchar_t *out, DWORD room, int *problem, unsigned long *code) {
    for (;;) {
        DWORD got = 0;
        SetLastError(0);
        if (!ReadConsoleW(c->in, out, room, &got, NULL)) { *problem = XLESS_CONSOLE_ERROR; *code = GetLastError(); return -1; }
        if (got) return (int)got;
        // Ctrl-C: the handler is about to end the process, on a thread of its own.
        if (GetLastError() == ERROR_OPERATION_ABORTED) { Sleep(10000); *problem = XLESS_CONSOLE_CLOSED; return -1; }
    }
}

static int64_t utf8(const wchar_t *text, size_t count, char *out, size_t length, int *problem) {
    if (!count) return 0;
    int room = length > 0x7fffffff ? 0x7fffffff : (int)length;
    int put = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, (int)count, out, room, NULL, NULL);
    if (put > 0) return put;
    *problem = GetLastError() == ERROR_INSUFFICIENT_BUFFER ? XLESS_CONSOLE_TOO_LONG : XLESS_CONSOLE_TEXT;
    SecureZeroMemory(out, length);
    return -1;
}

#define LINE 4096

int64_t xless_console_line(struct xless_console *c, const wchar_t *prompt, size_t prompt_length, char *out, size_t length, int *problem, unsigned long *code) {
    *problem = XLESS_CONSOLE_ERROR;
    DWORD saved;
    if (!GetConsoleMode(c->in, &saved)) { *code = GetLastError(); return -1; }
    wchar_t *line = malloc(LINE * sizeof *line);
    if (!line) { *code = ERROR_NOT_ENOUGH_MEMORY; return -1; }
    int64_t result = -1;
    if (begin_asking(c, saved) && SetConsoleMode(c->in, saved | ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)) {
        FlushConsoleInputBuffer(c->in); // before the question: what comes after it is the answer
        xless_console_write(c, prompt, prompt_length);
        int got = read_console(c, line, LINE, problem, code);
        if (got > 0) {
            *problem = XLESS_CONSOLE_NONE;
            int count = got;
            int ended = 0;
            while (count && (line[count - 1] == L'\n' || line[count - 1] == L'\r')) { count--; ended = 1; }
            if (line[0] == 0x1A) *problem = XLESS_CONSOLE_CLOSED;
            else if (!ended) { *problem = XLESS_CONSOLE_TOO_LONG; FlushConsoleInputBuffer(c->in); }
            else result = utf8(line, count, out, length, problem);
        }
        SetConsoleMode(c->in, saved);
    } else {
        *code = GetLastError();
    }
    end_asking();
    SecureZeroMemory(line, LINE * sizeof *line);
    free(line);
    return result;
}

int64_t xless_console_secret(struct xless_console *c, const wchar_t *prompt, size_t prompt_length, char *out, size_t length, int *problem, unsigned long *code) {
    *problem = XLESS_CONSOLE_ERROR;
    *code = 0;
    DWORD saved;
    if (!GetConsoleMode(c->in, &saved)) { *code = GetLastError(); return -1; }
    const size_t room = LINE * sizeof(wchar_t);
    int locked;
    wchar_t *line = xless_secret_map(room, &locked);
    if (!line) { *code = ERROR_NOT_ENOUGH_MEMORY; return -1; }
    int64_t result = -1;
    // Neither echo nor lines: the console keeps no line to show, to edit or to remember.
    DWORD quiet = (saved & ~(DWORD)(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT))
        | ENABLE_PROCESSED_INPUT;
    DWORD now = 0;
    if (!begin_asking(c, saved)) {
        *code = GetLastError();
    } else if (!SetConsoleMode(c->in, quiet) || !GetConsoleMode(c->in, &now) || now & (ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT)) {
        *problem = XLESS_CONSOLE_ECHO;
        SetConsoleMode(c->in, saved);
    } else {
        FlushConsoleInputBuffer(c->in); // before the question: what comes after it is the answer, and is not shown
        xless_console_write(c, prompt, prompt_length);
        size_t count = 0;
        for (;;) {
            wchar_t *typed = line + LINE - 1; // the last place is never the line's
            if (read_console(c, typed, 1, problem, code) < 0) break;
            wchar_t one = *typed;
            *typed = 0;
            if (one == L'\r' || one == L'\n') {
                *problem = XLESS_CONSOLE_NONE;
                result = utf8(line, count, out, length, problem);
                break;
            }
            if (one == 0x08 || one == 0x7F) { // a whole character
                if (count) line[--count] = 0;
                if (count && IS_HIGH_SURROGATE(line[count - 1])) line[--count] = 0;
                continue;
            }
            if (one == 0x15) { while (count) line[--count] = 0; continue; } // Ctrl-U
            if (one == 0x1A && !count) { *problem = XLESS_CONSOLE_CLOSED; break; } // Ctrl-Z
            if (one < 0x20 && one != L'\t') { *problem = XLESS_CONSOLE_CONTROL; break; } // Ctrl-V where it does not paste
            if (count >= LINE - 1) { *problem = XLESS_CONSOLE_TOO_LONG; break; }
            line[count++] = one;
            one = 0;
        }
        FlushConsoleInputBuffer(c->in); // what comes after it was not asked for
        SetConsoleMode(c->in, saved);
    }
    end_asking();
    xless_console_write(c, L"\r\n", 2);
    xless_secret_unmap(line, room);
    return result;
}

// MARK: - Ctrl-C

static HANDLE interrupted, ended;

static BOOL WINAPI interrupt(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) return FALSE;
    return interrupted && SetEvent(interrupted);
}

unsigned long xless_interrupt_begin(void) {
    if (!interrupted) interrupted = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!ended) ended = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!interrupted || !ended) return GetLastError();
    ResetEvent(interrupted);
    ResetEvent(ended);
    return SetConsoleCtrlHandler(interrupt, TRUE) ? 0 : GetLastError();
}

int xless_interrupt_wait(void) {
    HANDLE either[2] = { interrupted, ended };
    return WaitForMultipleObjects(2, either, FALSE, INFINITE) == WAIT_OBJECT_0;
}

void xless_interrupt_end(void) {
    SetConsoleCtrlHandler(interrupt, FALSE);
    if (ended) SetEvent(ended);
}

void xless_interrupt_raise(void) { if (interrupted) SetEvent(interrupted); }

#endif
