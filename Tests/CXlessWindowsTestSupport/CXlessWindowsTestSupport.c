// Windows only (Package.swift).
#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "CXlessWindowsTestSupport.h"

#include <windows.h>
#include <accctrl.h>
#include <aclapi.h>
#include <sddl.h>
#include <stdlib.h>
#include <string.h>
#include <winioctl.h>

unsigned long xless_test_security(const wchar_t *path, wchar_t *out, size_t length) {
    PSECURITY_DESCRIPTOR sd = NULL;
    SECURITY_INFORMATION what = OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION;
    DWORD code = GetNamedSecurityInfoW(path, SE_FILE_OBJECT, what, NULL, NULL, NULL, NULL, &sd);
    if (code != ERROR_SUCCESS) return code;
    wchar_t *text = NULL;
    if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, SDDL_REVISION_1, what, &text, NULL)) code = GetLastError();
    else if (wcslen(text) >= length) code = ERROR_INSUFFICIENT_BUFFER;
    else memcpy(out, text, (wcslen(text) + 1) * sizeof *out);
    LocalFree(text);
    LocalFree(sd);
    return code;
}

unsigned long xless_test_normal(const wchar_t *sddl, wchar_t *out, size_t length) {
    PSECURITY_DESCRIPTOR sd = NULL;
    wchar_t *text = NULL;
    DWORD code = ERROR_SUCCESS;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &sd, NULL)) return GetLastError();
    if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, SDDL_REVISION_1, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &text, NULL)) code = GetLastError();
    else if (wcslen(text) >= length) code = ERROR_INSUFFICIENT_BUFFER;
    else memcpy(out, text, (wcslen(text) + 1) * sizeof *out);
    LocalFree(text);
    LocalFree(sd);
    return code;
}

static int set_privilege(const wchar_t *privilege, DWORD attributes) {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) return 0;
    TOKEN_PRIVILEGES wanted = {1};
    wanted.Privileges[0].Attributes = attributes;
    int done = LookupPrivilegeValueW(NULL, privilege, &wanted.Privileges[0].Luid) && AdjustTokenPrivileges(token, FALSE, &wanted, 0, NULL, NULL)
        && GetLastError() == ERROR_SUCCESS;
    CloseHandle(token);
    return done;
}

void xless_test_drop_debug_privilege(void) { set_privilege(L"SeDebugPrivilege", 0); }

int xless_test_may_set_owner(void) { return set_privilege(L"SeRestorePrivilege", SE_PRIVILEGE_ENABLED) && set_privilege(L"SeTakeOwnershipPrivilege", SE_PRIVILEGE_ENABLED); }

unsigned long xless_test_set_security(const wchar_t *path, const wchar_t *sddl) {
    xless_test_may_set_owner();
    PSECURITY_DESCRIPTOR sd = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &sd, NULL)) return GetLastError();
    PSID owner = NULL;
    PACL dacl = NULL;
    BOOL present = FALSE, defaulted = FALSE;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    DWORD code = ERROR_SUCCESS;
    if (!GetSecurityDescriptorOwner(sd, &owner, &defaulted) || !GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted)
        || !GetSecurityDescriptorControl(sd, &control, &revision)) code = GetLastError();
    SECURITY_INFORMATION what = owner ? OWNER_SECURITY_INFORMATION : 0;
    if (present) what |= DACL_SECURITY_INFORMATION | (control & SE_DACL_PROTECTED ? PROTECTED_DACL_SECURITY_INFORMATION : UNPROTECTED_DACL_SECURITY_INFORMATION);
    if (code == ERROR_SUCCESS) code = SetNamedSecurityInfoW((wchar_t *)path, SE_FILE_OBJECT, what, owner, NULL, dacl, NULL);
    LocalFree(sd);
    return code;
}

unsigned long xless_test_hard_link(const wchar_t *link, const wchar_t *existing) {
    return CreateHardLinkW(link, existing, NULL) ? ERROR_SUCCESS : GetLastError();
}

unsigned long xless_test_junction(const wchar_t *link, const wchar_t *target) {
    wchar_t full[MAX_PATH];
    if (!GetFullPathNameW(target, MAX_PATH, full, NULL)) return GetLastError();
    if (!CreateDirectoryW(link, NULL)) return GetLastError();
    HANDLE directory = CreateFileW(link, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (directory == INVALID_HANDLE_VALUE) return GetLastError();
    // REPARSE_DATA_BUFFER of a mount point, which only the driver kit's headers have.
    struct {
        DWORD tag;
        WORD length, reserved, nameOffset, nameLength, printOffset, printLength;
        wchar_t path[2 * MAX_PATH];
    } data = {0};
    wcscpy(data.path, L"\\??\\");
    wcscat(data.path, full);
    size_t units = wcslen(data.path);
    data.tag = IO_REPARSE_TAG_MOUNT_POINT;
    data.nameLength = (WORD)(units * sizeof(wchar_t));
    data.printOffset = (WORD)((units + 1) * sizeof(wchar_t));
    data.length = (WORD)(8 + (units + 2) * sizeof(wchar_t));
    DWORD got = 0;
    BOOL made = DeviceIoControl(directory, FSCTL_SET_REPARSE_POINT, &data, 8 + data.length, NULL, 0, &got, NULL);
    DWORD code = made ? ERROR_SUCCESS : GetLastError();
    CloseHandle(directory);
    return code;
}

int xless_test_hardening(void) { return (GetErrorMode() & SEM_NOGPFAULTERRORBOX) != 0; }

unsigned long xless_test_load(const wchar_t *name) {
    // As LoadLibraryW looks for it.
    HMODULE module = LoadLibraryExW(name, NULL, LOAD_LIBRARY_AS_DATAFILE);
    if (!module) return GetLastError();
    FreeLibrary(module);
    return 0;
}

void xless_test_allow_reports(void) { SetErrorMode(0); }

void xless_test_crash(const char *how) {
    if (strcmp(how, "abort") == 0) abort();
    volatile int *nothing = NULL;
    *nothing = 1;
}

#endif
