// Windows only (Package.swift). Nothing here needs more than Windows 10 1809 / Windows Server 2019.
#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define _CRT_SECURE_NO_WARNINGS

#include "CXlessWindows.h"

#include <windows.h>
#include <accctrl.h>
#include <aclapi.h>
#include <combaseapi.h>
#include <errno.h>
#include <sddl.h>
#include <shlobj_core.h>
#include <stdlib.h>
#include <string.h>
#include <werapi.h>

// MARK: - This process's user

// The user of this process's token, in `buffer`; NULL: it cannot be told.
typedef struct { TOKEN_USER user; BYTE sid[SECURITY_MAX_SID_SIZE]; } user_buffer;

static PSID token_user(user_buffer *buffer) {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
    DWORD size = 0;
    BOOL ok = GetTokenInformation(token, TokenUser, buffer, sizeof *buffer, &size);
    DWORD code = GetLastError();
    CloseHandle(token);
    if (!ok) { SetLastError(code); return NULL; }
    return buffer->user.User.Sid;
}

static int sid_text(PSID sid, wchar_t *out) {
    wchar_t *text = NULL;
    if (!out || !ConvertSidToStringSidW(sid, &text)) return 0;
    size_t length = wcslen(text);
    int fits = length < XLESS_SID_LENGTH;
    if (fits) memcpy(out, text, (length + 1) * sizeof *out);
    LocalFree(text);
    return fits;
}

int xless_user_sid(wchar_t *out) {
    user_buffer buffer;
    PSID user = token_user(&buffer);
    return user && sid_text(user, out);
}

// The security descriptor of `format`, whose first %ls is the user; freed by LocalFree. NULL: GetLastError().
static PSECURITY_DESCRIPTOR descriptor(const wchar_t *before, const wchar_t *middle, const wchar_t *after) {
    wchar_t sid[XLESS_SID_LENGTH], text[3 * XLESS_SID_LENGTH + 64];
    if (!xless_user_sid(sid)) { if (!GetLastError()) SetLastError(ERROR_INVALID_SID); return NULL; }
    text[0] = 0;
    wcscat(text, before);
    wcscat(text, sid);
    wcscat(text, middle);
    wcscat(text, sid);
    wcscat(text, after);
    PSECURITY_DESCRIPTOR made = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(text, SDDL_REVISION_1, &made, NULL)) return NULL;
    return made;
}

// Owned by the user, whatever the token's default owner is (an elevated one's can be the administrators); full access for the user,
// nothing inherited. In a directory everything new gets the same.
static PSECURITY_DESCRIPTOR private_descriptor(int directory) {
    return descriptor(L"O:", directory ? L"D:P(A;OICI;FA;;;" : L"D:P(A;;FA;;;", L")");
}

// MARK: - The process

#define ERROR_MODE (SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX)

static LONG WINAPI end_at_fault(EXCEPTION_POINTERS *fault) {
    DWORD code = fault && fault->ExceptionRecord ? fault->ExceptionRecord->ExceptionCode : 0;
    TerminateProcess(GetCurrentProcess(), code ? code : 3); // never as if it had gone well
    return EXCEPTION_EXECUTE_HANDLER;
}

// What the user keeps: to see that the process is there, to wait for it and to end it. The owner gets nothing of its own (OW).
static void restrict_access(void) {
    PSECURITY_DESCRIPTOR sd = descriptor(L"O:", L"D:P(A;;0x1fffff;;;SY)(A;;RC;;;OW)(A;;0x101001;;;", L")");
    if (!sd) return;
    BOOL present = FALSE, defaulted = FALSE;
    PACL dacl = NULL;
    if (GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted) && present && dacl)
        SetSecurityInfo(GetCurrentProcess(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, NULL, NULL, dacl, NULL);
    LocalFree(sd);
}

int xless_disable_core_dumps(void) {
    SetErrorMode(GetErrorMode() | ERROR_MODE);
    if ((GetErrorMode() & ERROR_MODE) != ERROR_MODE) return 1;
    DWORD flags = 0;
    if (FAILED(WerGetFlags(GetCurrentProcess(), &flags))) flags = 0;
    if (FAILED(WerSetFlags(flags | WER_FAULT_REPORTING_FLAG_NOHEAP))) return 2;
    flags = 0;
    if (FAILED(WerGetFlags(GetCurrentProcess(), &flags)) || !(flags & WER_FAULT_REPORTING_FLAG_NOHEAP)) return 3;
    SetUnhandledExceptionFilter(end_at_fault);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);

    restrict_access();
    PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY points = {0};
    points.DisableExtensionPoints = 1;
    SetProcessMitigationPolicy(ProcessExtensionPointDisablePolicy, &points, sizeof points);
    PROCESS_MITIGATION_IMAGE_LOAD_POLICY images = {0};
    images.NoRemoteImages = 1;
    images.NoLowMandatoryLabelImages = 1;
    images.PreferSystem32Images = 1;
    SetProcessMitigationPolicy(ProcessImageLoadPolicy, &images, sizeof images);
    PROCESS_MITIGATION_STRICT_HANDLE_CHECK_POLICY handles = {0};
    handles.RaiseExceptionOnInvalidHandleReference = 1;
    handles.HandleExceptionsPermanentlyEnabled = 1;
    SetProcessMitigationPolicy(ProcessStrictHandleCheckPolicy, &handles, sizeof handles);
    return 0;
}

unsigned int xless_hardening(void) {
    unsigned int found = 0;
    if ((GetErrorMode() & ERROR_MODE) == ERROR_MODE) found |= XLESS_HARDENED_ERROR_MODE;
    DWORD flags = 0;
    if (SUCCEEDED(WerGetFlags(GetCurrentProcess(), &flags)) && (flags & WER_FAULT_REPORTING_FLAG_NOHEAP)) found |= XLESS_HARDENED_NO_HEAP_REPORT;
    PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY points = {0};
    if (GetProcessMitigationPolicy(GetCurrentProcess(), ProcessExtensionPointDisablePolicy, &points, sizeof points) && points.DisableExtensionPoints)
        found |= XLESS_HARDENED_EXTENSION_POINTS;
    PROCESS_MITIGATION_IMAGE_LOAD_POLICY images = {0};
    if (GetProcessMitigationPolicy(GetCurrentProcess(), ProcessImageLoadPolicy, &images, sizeof images)) {
        if (images.NoRemoteImages) found |= XLESS_HARDENED_REMOTE_IMAGES;
        if (images.NoLowMandatoryLabelImages) found |= XLESS_HARDENED_LOW_LABEL_IMAGES;
        if (images.PreferSystem32Images) found |= XLESS_HARDENED_SYSTEM32_FIRST;
    }
    PROCESS_MITIGATION_STRICT_HANDLE_CHECK_POLICY handles = {0};
    if (GetProcessMitigationPolicy(GetCurrentProcess(), ProcessStrictHandleCheckPolicy, &handles, sizeof handles)
        && handles.RaiseExceptionOnInvalidHandleReference && handles.HandleExceptionsPermanentlyEnabled) found |= XLESS_HARDENED_STRICT_HANDLES;
    if (xless_memory_may_be_read() == 0) found |= XLESS_HARDENED_PROCESS_ACCESS;
    return found;
}

int xless_memory_may_be_read(void) {
    HANDLE opened = OpenProcess(PROCESS_VM_READ, FALSE, GetCurrentProcessId());
    if (opened) { CloseHandle(opened); return 1; }
    return GetLastError() == ERROR_ACCESS_DENIED ? 0 : -1;
}

void xless_secure_zero(void *bytes, size_t length) {
    if (bytes && length) SecureZeroMemory(bytes, length);
}

static intptr_t no_keyring(void) { errno = ENOSYS; return -1; }
intptr_t xless_key_add(const char *description, const void *payload, size_t length, int32_t keyring) { (void)description; (void)payload; (void)length; (void)keyring; return no_keyring(); }
intptr_t xless_key_search(int32_t keyring, const char *description) { (void)keyring; (void)description; return no_keyring(); }
intptr_t xless_key_read(int32_t key, void *buffer, size_t length) { (void)key; (void)buffer; (void)length; return no_keyring(); }
intptr_t xless_key_revoke(int32_t key) { (void)key; return no_keyring(); }
intptr_t xless_key_set_timeout(int32_t key, unsigned int seconds) { (void)key; (void)seconds; return no_keyring(); }
intptr_t xless_key_setperm(int32_t key, uint32_t permissions) { (void)key; (void)permissions; return no_keyring(); }
intptr_t xless_key_describe(int32_t key, char *buffer, size_t length) { (void)key; (void)buffer; (void)length; return no_keyring(); }
intptr_t xless_key_keyring_id(int32_t keyring) { (void)keyring; return no_keyring(); }
intptr_t xless_key_join_new_session(void) { return no_keyring(); }

int64_t xless_clock_continuous_ms(void) { return (int64_t)GetTickCount64(); }

int64_t xless_clock_awake_ms(void) {
    ULONGLONG hundredNanoseconds = 0;
    QueryUnbiasedInterruptTime(&hundredNanoseconds);
    return (int64_t)(hundredNanoseconds / 10000);
}

// MARK: - Files

static void *refused(struct xless_private *why, int problem, DWORD code) {
    why->problem = problem;
    why->code = code;
    return NULL;
}

static void *failed(struct xless_private *why, DWORD code) {
    switch (code) {
    case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: return refused(why, XLESS_PRIVATE_MISSING, code);
    case ERROR_FILE_EXISTS: case ERROR_ALREADY_EXISTS: return refused(why, XLESS_PRIVATE_EXISTS, code);
    default: return refused(why, XLESS_PRIVATE_ERROR, code);
    }
}

static int on_drive(const wchar_t *path) {
    return (path[0] | 0x20) >= L'a' && (path[0] | 0x20) <= L'z' && path[1] == L':' && (path[2] == L'\\' || path[2] == L'/');
}

// `path` as "\\?\C:\...", which no limit of length and no device name applies to; `must_name_drive`: only one that does not
// depend on the current directory. Freed by the caller; NULL: `why`.
static wchar_t *drive_path(const wchar_t *path, int must_name_drive, struct xless_private *why) {
    int slashes = (path[0] == L'\\' || path[0] == L'/') && (path[1] == L'\\' || path[1] == L'/');   // a share or a device: below
    if (must_name_drive && !slashes && !on_drive(path)) return refused(why, XLESS_PRIVATE_BAD_PATH, 0);
    DWORD size = GetFullPathNameW(path, 0, NULL, NULL);
    if (!size) return failed(why, GetLastError());
    wchar_t *whole = malloc(((size_t)size + 4) * sizeof *whole);
    if (!whole) return failed(why, ERROR_NOT_ENOUGH_MEMORY);
    wmemcpy(whole, L"\\\\?\\", 4);
    wchar_t *full = whole + 4;
    DWORD length = GetFullPathNameW(path, size, full, NULL);
    if (!length || length >= size) {
        DWORD code = length ? ERROR_FILENAME_EXCED_RANGE : GetLastError();
        free(whole);
        return failed(why, code);
    }
    int problem = XLESS_PRIVATE_NONE;
    if (full[0] == L'\\' && full[1] == L'\\') problem = full[2] == L'.' || full[2] == L'?' ? XLESS_PRIVATE_BAD_PATH : XLESS_PRIVATE_NOT_LOCAL;
    else if (!on_drive(full)) problem = XLESS_PRIVATE_BAD_PATH;
    else if (wcschr(full + 2, L':')) problem = XLESS_PRIVATE_BAD_PATH;   // a stream of a file
    if (problem != XLESS_PRIVATE_NONE) {
        free(whole);
        return refused(why, problem, 0);
    }
    return whole;
}

// Whether the file is on a drive that is built in. Not the drive letter's word for it: the volume's that the handle is on.
static int is_local(HANDLE file) {
    wchar_t path[MAX_PATH + 64];
    DWORD length = GetFinalPathNameByHandleW(file, path, ARRAYSIZE(path), FILE_NAME_OPENED | VOLUME_NAME_GUID);
    if (length == 0) return 0;
    wchar_t *longer = NULL, *name = path;
    if (length >= ARRAYSIZE(path)) {
        longer = malloc(((size_t)length + 1) * sizeof *longer);
        if (!longer || GetFinalPathNameByHandleW(file, longer, length + 1, FILE_NAME_OPENED | VOLUME_NAME_GUID) > length) { free(longer); return 0; }
        name = longer;
    }
    int local = 0;
    // \\?\Volume{...}\ is the root, with its last backslash.
    if (wcsncmp(name, L"\\\\?\\Volume{", 11) == 0) {
        wchar_t *end = wcschr(name + 11, L'\\');
        if (end) {
            end[1] = 0;
            local = GetDriveTypeW(name) == DRIVE_FIXED;
        }
    }
    free(longer);
    FILE_REMOTE_PROTOCOL_INFO remote;
    if (GetFileInformationByHandleEx(file, FileRemoteProtocolInfo, &remote, sizeof remote)) local = 0;
    return local;
}

static int problem_of(HANDLE file, int directory, int local, DWORD *code, wchar_t *sid) {
    if (sid) sid[0] = 0;
    *code = 0;
    if (GetFileType(file) != FILE_TYPE_DISK) return directory ? XLESS_PRIVATE_NOT_DIRECTORY : XLESS_PRIVATE_NOT_FILE;
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(file, &info)) { *code = GetLastError(); return XLESS_PRIVATE_ERROR; }
    if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) return XLESS_PRIVATE_LINK;
    int isDirectory = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    if (directory && !isDirectory) return XLESS_PRIVATE_NOT_DIRECTORY;
    if (!directory && (isDirectory || (info.dwFileAttributes & FILE_ATTRIBUTE_DEVICE))) return XLESS_PRIVATE_NOT_FILE;
    if (!directory && info.nNumberOfLinks > 1) return XLESS_PRIVATE_HARD_LINKS;

    if (local && !is_local(file)) return XLESS_PRIVATE_NOT_LOCAL;
    DWORD system = 0;
    if (!GetVolumeInformationByHandleW(file, NULL, 0, NULL, NULL, &system, NULL, 0)) { *code = GetLastError(); return XLESS_PRIVATE_ERROR; }
    if (!(system & FILE_PERSISTENT_ACLS)) return XLESS_PRIVATE_NO_ACLS;

    user_buffer buffer;
    PSID user = token_user(&buffer);
    if (!user) { *code = GetLastError(); return XLESS_PRIVATE_ERROR; }
    PSECURITY_DESCRIPTOR sd = NULL;
    PSID owner = NULL;
    PACL dacl = NULL;
    *code = GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &owner, NULL, &dacl, NULL, &sd);
    if (*code != ERROR_SUCCESS) return XLESS_PRIVATE_ERROR;
    int problem = XLESS_PRIVATE_NONE;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    if (!owner || !IsValidSid(owner)) problem = XLESS_PRIVATE_UNKNOWN_ACE;
    else if (!EqualSid(owner, user)) { problem = XLESS_PRIVATE_OWNER; sid_text(owner, sid); }
    else if (!GetSecurityDescriptorControl(sd, &control, &revision)) { problem = XLESS_PRIVATE_ERROR; *code = GetLastError(); }
    else if (!(control & SE_DACL_PRESENT) || !dacl) problem = XLESS_PRIVATE_NO_DACL;
    else {
        ACL_SIZE_INFORMATION size;
        if (!IsValidAcl(dacl) || !GetAclInformation(dacl, &size, sizeof size, AclSizeInformation)) problem = XLESS_PRIVATE_UNKNOWN_ACE;
        else for (DWORD i = 0; i < size.AceCount && problem == XLESS_PRIVATE_NONE; i++) {
            void *entry = NULL;
            if (!GetAce(dacl, i, &entry) || !entry) { problem = XLESS_PRIVATE_UNKNOWN_ACE; break; }
            switch (((ACE_HEADER *)entry)->AceType) {
            case ACCESS_DENIED_ACE_TYPE: break;   // it lets nobody in
            case ACCESS_ALLOWED_ACE_TYPE: {
                ACCESS_ALLOWED_ACE *allowed = entry;
                PSID who = &allowed->SidStart;
                // The SID ends where the entry does: a share's server may say what it likes.
                DWORD room = allowed->Header.AceSize, before = offsetof(ACCESS_ALLOWED_ACE, SidStart);
                if (room < before + 8 || room < before + GetSidLengthRequired(*GetSidSubAuthorityCount(who)) || !IsValidSid(who)) problem = XLESS_PRIVATE_UNKNOWN_ACE;
                else if (allowed->Mask && !EqualSid(who, user) && !IsWellKnownSid(who, WinLocalSystemSid) && !IsWellKnownSid(who, WinBuiltinAdministratorsSid)) {
                    problem = XLESS_PRIVATE_SHARED;
                    sid_text(who, sid);
                }
                break;
            }
            default: problem = XLESS_PRIVATE_UNKNOWN_ACE;
            }
            if (problem == XLESS_PRIVATE_NONE && (((ACE_HEADER *)entry)->AceFlags & INHERITED_ACE)) problem = XLESS_PRIVATE_INHERITED;
        }
        if (problem == XLESS_PRIVATE_NONE && !(control & SE_DACL_PROTECTED)) problem = XLESS_PRIVATE_INHERITED;
    }
    LocalFree(sd);
    return problem;
}

static void *checked(HANDLE file, int directory, int local, struct xless_private *why, wchar_t *sid) {
    DWORD code = 0;
    int problem = problem_of(file, directory, local, &code, sid);
    if (problem == XLESS_PRIVATE_NONE) { refused(why, XLESS_PRIVATE_NONE, 0); return file; }
    CloseHandle(file);
    return refused(why, problem, code);
}

// A file that its sharing keeps from being opened for a moment (a virus scanner's, another xless's) is tried again.
#define TRIES 40
#define TRY_AGAIN_MS 50

static HANDLE open_file(const wchar_t *whole, DWORD access, DWORD share, SECURITY_ATTRIBUTES *attributes, DWORD disposition, DWORD *code) {
    for (int i = 0;; i++) {
        // FILE_FLAG_BACKUP_SEMANTICS: a directory is opened too, to say what it is.
        HANDLE file = CreateFileW(whole, access, share, attributes, disposition, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
        if (file != INVALID_HANDLE_VALUE) return file;
        *code = GetLastError();
        if (*code != ERROR_SHARING_VIOLATION || i == TRIES) return NULL;
        Sleep(TRY_AGAIN_MS);
    }
}

int xless_private_make_directory(const wchar_t *path, struct xless_private *why) {
    refused(why, XLESS_PRIVATE_NONE, 0);
    wchar_t *whole = drive_path(path, 1, why);
    if (!whole) return -1;
    PSECURITY_DESCRIPTOR sd = private_descriptor(1);
    DWORD code = sd ? ERROR_SUCCESS : GetLastError();
    if (sd) {
        SECURITY_ATTRIBUTES attributes = {sizeof attributes, sd, FALSE};
        if (!CreateDirectoryW(whole, &attributes)) code = GetLastError();
        LocalFree(sd);
    }
    free(whole);
    if (code == ERROR_SUCCESS || code == ERROR_ALREADY_EXISTS) return 0;
    failed(why, code);
    return -1;
}

static void *open_checked(const wchar_t *path, DWORD access, DWORD share, int create, int directory, int local, struct xless_private *why, wchar_t *sid) {
    refused(why, XLESS_PRIVATE_NONE, 0);
    wchar_t *whole = drive_path(path, local, why);
    if (!whole) return NULL;
    PSECURITY_DESCRIPTOR sd = NULL;
    SECURITY_ATTRIBUTES attributes = {sizeof attributes, NULL, FALSE};
    if (create) {
        sd = private_descriptor(0);
        if (!sd) { DWORD code = GetLastError(); free(whole); return failed(why, code); }
        attributes.lpSecurityDescriptor = sd;
    }
    DWORD code = 0;
    HANDLE file = open_file(whole, access | READ_CONTROL | FILE_READ_ATTRIBUTES, share, &attributes, create ? OPEN_ALWAYS : OPEN_EXISTING, &code);
    LocalFree(sd);
    free(whole);
    return file ? checked(file, directory, local, why, sid) : failed(why, code);
}

void *xless_private_open_directory(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid) {
    return open_checked(path, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, 1, local, why, sid);
}

void *xless_private_open(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid) {
    return open_checked(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, 0, local, why, sid);
}

void *xless_private_open_lock(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid) {
    return open_checked(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 1, 0, local, why, sid);
}

void *xless_private_create(const wchar_t *path, int local, struct xless_private *why, wchar_t *sid) {
    refused(why, XLESS_PRIVATE_NONE, 0);
    wchar_t *whole = drive_path(path, local, why);
    if (!whole) return NULL;
    PSECURITY_DESCRIPTOR sd = private_descriptor(0);
    if (!sd) { DWORD code = GetLastError(); free(whole); return failed(why, code); }
    SECURITY_ATTRIBUTES attributes = {sizeof attributes, sd, FALSE};
    // Nobody else writes to it meanwhile; a reader of the name it is given may come before it is closed.
    HANDLE file = CreateFileW(whole, GENERIC_READ | GENERIC_WRITE | DELETE | READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_DELETE, &attributes,
                              CREATE_NEW, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD code = GetLastError();
    LocalFree(sd);
    free(whole);
    if (file == INVALID_HANDLE_VALUE) return failed(why, code);
    int problem = problem_of(file, 0, local, &code, sid);
    if (problem == XLESS_PRIVATE_NONE) return file;
    xless_private_remove(file);
    CloseHandle(file);
    return refused(why, problem, code);
}

unsigned long xless_private_lock(void *file) {
    OVERLAPPED at = {0};
    return LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &at) ? ERROR_SUCCESS : GetLastError();
}

int64_t xless_private_size(void *file, unsigned long *code) {
    LARGE_INTEGER size;
    if (GetFileSizeEx(file, &size)) return size.QuadPart;
    *code = GetLastError();
    return -1;
}

static DWORD piece(size_t length) { return length > (1u << 20) ? (1u << 20) : (DWORD)length; }

int64_t xless_private_read(void *file, void *bytes, size_t length, unsigned long *code) {
    DWORD got = 0;
    if (ReadFile(file, bytes, piece(length), &got, NULL)) return got;
    *code = GetLastError();
    return -1;
}

int64_t xless_private_write(void *file, const void *bytes, size_t length, unsigned long *code) {
    DWORD put = 0;
    if (WriteFile(file, bytes, piece(length), &put, NULL)) return put;
    *code = GetLastError();
    return -1;
}

unsigned long xless_private_flush(void *file) { return FlushFileBuffers(file) ? ERROR_SUCCESS : GetLastError(); }

unsigned long xless_private_replace(void *file, const wchar_t *path) {
    struct xless_private why;
    refused(&why, XLESS_PRIVATE_NONE, 0);
    wchar_t *whole = drive_path(path, 0, &why);
    if (!whole) return why.code ? why.code : ERROR_BAD_PATHNAME;
    size_t bytes = wcslen(whole) * sizeof *whole;
    size_t size = sizeof(FILE_RENAME_INFO) + bytes;
    FILE_RENAME_INFO *info = calloc(1, size);
    DWORD code = ERROR_NOT_ENOUGH_MEMORY;
    if (info) {
        info->FileNameLength = (DWORD)bytes;
        memcpy(info->FileName, whole, bytes);
        for (int i = 0;; i++) {
            // In one step, also while somebody reads the file that had the name.
            info->Flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS;
            code = SetFileInformationByHandle(file, FileRenameInfoEx, info, (DWORD)size) ? ERROR_SUCCESS : GetLastError();
            if (code == ERROR_INVALID_PARAMETER || code == ERROR_INVALID_FUNCTION || code == ERROR_NOT_SUPPORTED) {
                // A file system that does not know how: in one step too, but not while it is open elsewhere.
                info->Flags = 0;
                info->ReplaceIfExists = TRUE;
                code = SetFileInformationByHandle(file, FileRenameInfo, info, (DWORD)size) ? ERROR_SUCCESS : GetLastError();
            }
            if ((code != ERROR_SHARING_VIOLATION && code != ERROR_ACCESS_DENIED) || i == TRIES) break;
            Sleep(TRY_AGAIN_MS);
        }
        free(info);
    }
    free(whole);
    return code;
}

unsigned long xless_private_remove(void *file) {
    FILE_DISPOSITION_INFO gone = {TRUE};
    return SetFileInformationByHandle(file, FileDispositionInfo, &gone, sizeof gone) ? ERROR_SUCCESS : GetLastError();
}

void xless_private_close(void *file) { if (file) CloseHandle(file); }

int xless_path_exists(const wchar_t *path) {
    struct xless_private why;
    wchar_t *whole = drive_path(path, 0, &why);
    if (!whole) return -1;
    DWORD attributes = GetFileAttributesW(whole);
    DWORD code = GetLastError();
    free(whole);
    if (attributes != INVALID_FILE_ATTRIBUTES) return 1;
    return code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND ? 0 : -1;
}

void *xless_input_open(const wchar_t *path, int nolink, struct xless_private *why) {
    refused(why, XLESS_PRIVATE_NONE, 0);
    wchar_t *whole = drive_path(path, 0, why);
    if (!whole) return NULL;
    // SECURITY_ANONYMOUS: were it a pipe after all, whoever serves it could not act as this user.
    HANDLE file = CreateFileW(whole, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                              FILE_FLAG_BACKUP_SEMANTICS | (nolink ? FILE_FLAG_OPEN_REPARSE_POINT : 0) | SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS, NULL);
    DWORD code = GetLastError();
    free(whole);
    if (file == INVALID_HANDLE_VALUE) return failed(why, code);
    BY_HANDLE_FILE_INFORMATION info;
    int problem = XLESS_PRIVATE_NONE;
    if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info)) problem = XLESS_PRIVATE_NOT_FILE;
    else if (nolink && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) problem = XLESS_PRIVATE_LINK;
    else if (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE)) problem = XLESS_PRIVATE_NOT_FILE;
    if (problem == XLESS_PRIVATE_NONE) return file;
    CloseHandle(file);
    return refused(why, problem, 0);
}

void *xless_output_create(const wchar_t *path, struct xless_private *why) {
    refused(why, XLESS_PRIVATE_NONE, 0);
    wchar_t *whole = drive_path(path, 0, why);
    if (!whole) return NULL;
    HANDLE file = CreateFileW(whole, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, CREATE_NEW, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD code = GetLastError();
    free(whole);
    return file == INVALID_HANDLE_VALUE ? failed(why, code) : file;
}

unsigned long xless_move(const wchar_t *from, const wchar_t *to, int replace) {
    struct xless_private why;
    refused(&why, XLESS_PRIVATE_NONE, 0);
    DWORD code = ERROR_BAD_PATHNAME;
    wchar_t *source = drive_path(from, 0, &why);
    wchar_t *target = source ? drive_path(to, 0, &why) : NULL;
    if (source && target) {
        for (int i = 0;; i++) {
            code = MoveFileExW(source, target, MOVEFILE_WRITE_THROUGH | (replace ? MOVEFILE_REPLACE_EXISTING : 0)) ? ERROR_SUCCESS : GetLastError();
            if (code != ERROR_SHARING_VIOLATION || i == TRIES) break;
            Sleep(TRY_AGAIN_MS);
        }
    } else if (why.code) code = why.code;
    free(source);
    free(target);
    return code;
}

unsigned long xless_delete(const wchar_t *path) {
    struct xless_private why;
    refused(&why, XLESS_PRIVATE_NONE, 0);
    wchar_t *whole = drive_path(path, 0, &why);
    if (!whole) return why.code ? why.code : ERROR_BAD_PATHNAME;
    DWORD code = DeleteFileW(whole) ? ERROR_SUCCESS : GetLastError();
    free(whole);
    return code;
}

int xless_same_name(const wchar_t *one, size_t one_length, const wchar_t *other, size_t other_length) {
    if (one_length > 0x7fffffff || other_length > 0x7fffffff) return 0;
    return CompareStringOrdinal(one, (int)one_length, other, (int)other_length, TRUE) == CSTR_EQUAL;
}

size_t xless_final_path(const wchar_t *path, wchar_t *out, size_t length) {
    struct xless_private why;
    wchar_t *whole = drive_path(path, 0, &why);
    if (!whole) return 0;
    HANDLE file = CreateFileW(whole, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(whole);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD got = GetFinalPathNameByHandleW(file, out, length > 0xffff ? 0xffff : (DWORD)length, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(file);
    return got < length ? got : 0;
}

size_t xless_error_text(unsigned long code, wchar_t *out, size_t length) {
    DWORD got = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, out, (DWORD)length, NULL);
    while (got && (out[got - 1] == L'\r' || out[got - 1] == L'\n' || out[got - 1] == L' ' || out[got - 1] == L'.')) out[--got] = 0;
    return got;
}

size_t xless_local_app_data(wchar_t *out, size_t length) {
    // FOLDERID_LocalAppData, written out: no library of GUIDs is linked.
    static const GUID folder = {0xF1B32785, 0x6FBA, 0x4FCF, {0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91}};
    wchar_t *path = NULL;
    size_t got = 0;
    if (SUCCEEDED(SHGetKnownFolderPath(&folder, KF_FLAG_DONT_VERIFY, NULL, &path)) && path) {
        got = wcslen(path);
        if (got < length) memcpy(out, path, (got + 1) * sizeof *out); else got = 0;
    }
    CoTaskMemFree(path);
    return got;
}

#endif
