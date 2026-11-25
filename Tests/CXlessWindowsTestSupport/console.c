// Windows only (Package.swift): programs on a pseudo console.
#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "CXlessWindowsTestSupport.h"

#include <windows.h>
#include <stdlib.h>
#include <string.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

struct xless_test_console {
    HPCON console;
    HANDLE type, show;       // our ends
    PROCESS_INFORMATION process;
    HANDLE reader, arrived;
    CRITICAL_SECTION lock;
    char *shown;             // read and not yet asked for
    size_t length, room;
    int ended;
};

// The console's output is read all the time: a console that nobody reads stands still.
static DWORD WINAPI read_all(void *context) {
    struct xless_test_console *c = context;
    char piece[4096];
    DWORD got;
    while (ReadFile(c->show, piece, sizeof piece, &got, NULL) && got) {
        EnterCriticalSection(&c->lock);
        if (c->length + got > c->room) {
            c->room = (c->length + got) * 2;
            c->shown = realloc(c->shown, c->room);
        }
        memcpy(c->shown + c->length, piece, got);
        c->length += got;
        SetEvent(c->arrived);
        LeaveCriticalSection(&c->lock);
    }
    EnterCriticalSection(&c->lock);
    c->ended = 1;
    SetEvent(c->arrived);
    LeaveCriticalSection(&c->lock);
    return 0;
}

unsigned long xless_test_set_standard(int which, const wchar_t *name) {
    static const DWORD standard[3] = { STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE };
    if (wcsncmp(name, L"\\\\.\\pipe\\", 9) == 0) { // its other end stays open as long as this process
        HANDLE other = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0, NULL);
        if (other == INVALID_HANDLE_VALUE) return GetLastError();
    }
    HANDLE handle = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (handle == INVALID_HANDLE_VALUE || !SetStdHandle(standard[which], handle)) return GetLastError();
    return 0;
}

struct xless_test_console *xless_test_console_start(const wchar_t *command, const wchar_t *directory, int bare, unsigned long *code) {
    struct xless_test_console *c = calloc(1, sizeof *c);
    HANDLE in = NULL, out = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST list = NULL;
    wchar_t *line = NULL;
    SIZE_T size = 0;
    if (!c) { *code = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    InitializeCriticalSection(&c->lock);
    c->arrived = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!CreatePipe(&in, &c->type, NULL, 0) || !CreatePipe(&c->show, &out, NULL, 0)) goto failed;
    COORD cells = { 120, 40 };
    HRESULT made = CreatePseudoConsole(cells, in, out, 0, &c->console);
    if (FAILED(made)) { c->console = NULL; SetLastError((DWORD)made); goto failed; }
    CloseHandle(in);
    CloseHandle(out);
    in = out = NULL;

    STARTUPINFOEXW start;
    memset(&start, 0, sizeof start);
    start.StartupInfo.cb = sizeof start;
    // Not the handles that this process has (a pipe of the test runner's).
    start.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    // The console's are put there, unless it is to inherit these (which are none).
    start.StartupInfo.hStdInput = start.StartupInfo.hStdOutput = start.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    list = malloc(size);
    if (!list || !InitializeProcThreadAttributeList(list, 1, 0, &size)) { free(list); list = NULL; goto failed; }
    if (!UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, c->console, sizeof c->console, NULL, NULL)) goto failed;
    start.lpAttributeList = list;
    line = _wcsdup(command);
    if (!CreateProcessW(NULL, line, NULL, NULL, bare, EXTENDED_STARTUPINFO_PRESENT, NULL, directory, &start.StartupInfo, &c->process)) goto failed;
    free(line);
    DeleteProcThreadAttributeList(list);
    free(list);
    c->reader = CreateThread(NULL, 0, read_all, c, 0, NULL);
    return c;
failed:
    *code = GetLastError();
    free(line);
    if (list) { DeleteProcThreadAttributeList(list); free(list); }
    if (in) CloseHandle(in);
    if (out) CloseHandle(out);
    xless_test_console_end(c);
    return NULL;
}

unsigned long xless_test_console_process(struct xless_test_console *c) { return c->process.dwProcessId; }

unsigned long xless_test_console_type(struct xless_test_console *c, const char *bytes, size_t length) {
    DWORD put = 0;
    return WriteFile(c->type, bytes, (DWORD)length, &put, NULL) && put == length ? 0 : GetLastError();
}

int64_t xless_test_console_read(struct xless_test_console *c, char *out, size_t length, unsigned int milliseconds) {
    ULONGLONG until = GetTickCount64() + milliseconds;
    for (;;) {
        EnterCriticalSection(&c->lock);
        size_t got = c->length < length ? c->length : length;
        memcpy(out, c->shown, got);
        memmove(c->shown, c->shown + got, c->length - got);
        c->length -= got;
        int ended = c->ended;
        LeaveCriticalSection(&c->lock);
        if (got) return (int64_t)got;
        if (ended) return -1;
        ULONGLONG now = GetTickCount64();
        if (now >= until) return 0;
        WaitForSingleObject(c->arrived, (DWORD)(until - now));
    }
}

void xless_test_console_hang_up(struct xless_test_console *c) {
    if (c->console) ClosePseudoConsole(c->console);
    c->console = NULL;
}

int64_t xless_test_console_wait(struct xless_test_console *c, unsigned int milliseconds) {
    DWORD code;
    if (WaitForSingleObject(c->process.hProcess, milliseconds) != WAIT_OBJECT_0 || !GetExitCodeProcess(c->process.hProcess, &code)) return -1;
    return code;
}

void xless_test_console_end(struct xless_test_console *c) {
    if (!c) return;
    // The program that this started, by the handle it was started with.
    if (c->process.hProcess) {
        if (WaitForSingleObject(c->process.hProcess, 0) == WAIT_TIMEOUT) TerminateProcess(c->process.hProcess, 1);
        WaitForSingleObject(c->process.hProcess, 5000);
        CloseHandle(c->process.hProcess);
        CloseHandle(c->process.hThread);
    }
    xless_test_console_hang_up(c);
    if (c->type) CloseHandle(c->type);
    if (c->reader) {
        WaitForSingleObject(c->reader, 10000); // the console's end is the pipe's
        CloseHandle(c->reader);
    }
    if (c->show) CloseHandle(c->show);
    if (c->arrived) CloseHandle(c->arrived);
    DeleteCriticalSection(&c->lock);
    free(c->shown);
    free(c);
}

#endif
