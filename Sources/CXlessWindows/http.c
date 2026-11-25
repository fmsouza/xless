// Windows only (Package.swift): HTTP over WinHTTP, which has the system's TLS and the system's proxy.
#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "CXlessWindows.h"

#include <windows.h>
#include <wincrypt.h>
#include <winhttp.h>
#include <stdlib.h>
#include <string.h>

#ifndef WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3
#define WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3 0x00002000
#endif

#define PIECE (64u << 10)

struct xless_http_session { HINTERNET session; };

// One request and its answer. WinHTTP works for it on threads of its own and reads and writes `buffer` only, which is freed when
// WinHTTP has said that it is done with the request (HANDLE_CLOSING).
struct xless_http_exchange {
    HINTERNET connection, request;
    HANDLE done, cancelled, closed;
    DWORD timeout;       // milliseconds that nothing may happen for
    DWORD status;        // the last thing that happened (WINHTTP_CALLBACK_STATUS_*)
    DWORD error;         // its error, or 0
    DWORD value;         // its number: what there is, was read or was written
    DWORD secure;        // what is wrong with the server's certificate (WINHTTP_CALLBACK_STATUS_FLAG_*)
    int https;
    BYTE *buffer;        // PIECE long
};

static void CALLBACK happened(HINTERNET handle, DWORD_PTR context, DWORD status, LPVOID information, DWORD length) {
    struct xless_http_exchange *x = (struct xless_http_exchange *)context;
    if (!x || handle != x->request) return;
    switch (status) {
    case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
        SetEvent(x->closed); // `x` may be gone from here on
        return;
    case WINHTTP_CALLBACK_STATUS_SECURE_FAILURE:
        if (information && length >= sizeof(DWORD)) x->secure |= *(DWORD *)information;
        return;
    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
        x->error = information ? ((WINHTTP_ASYNC_RESULT *)information)->dwError : ERROR_INVALID_DATA;
        if (!x->error) x->error = ERROR_INVALID_DATA;
        break;
    case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
    case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
        x->error = 0;
        x->value = information && length >= sizeof(DWORD) ? *(DWORD *)information : 0;
        break;
    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        x->error = 0;
        x->value = length;
        break;
    case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
    case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
        x->error = 0;
        break;
    default:
        return;
    }
    x->status = status;
    SetEvent(x->done);
}

// Waits for what was begun. 0, or a Windows error.
static DWORD finished(struct xless_http_exchange *x, BOOL begun, DWORD expected) {
    if (!begun) {
        DWORD code = GetLastError();
        return code ? code : ERROR_INVALID_FUNCTION;
    }
    HANDLE either[2] = { x->cancelled, x->done };
    switch (WaitForMultipleObjects(2, either, FALSE, x->timeout)) {
    case WAIT_OBJECT_0: return ERROR_WINHTTP_OPERATION_CANCELLED;
    case WAIT_OBJECT_0 + 1: break;
    case WAIT_TIMEOUT: return ERROR_WINHTTP_TIMEOUT;
    default: return GetLastError();
    }
    if (x->error) return x->error;
    return x->status == expected ? 0 : ERROR_INVALID_DATA;
}

static BOOL set_number(HINTERNET handle, DWORD option, DWORD value) { return WinHttpSetOption(handle, option, &value, sizeof value); }

struct xless_http_session *xless_http_open(int proxy, const wchar_t *server, const wchar_t *bypass, unsigned long *code) {
    struct xless_http_session *s = calloc(1, sizeof *s);
    if (!s) { *code = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    DWORD access = proxy == XLESS_HTTP_PROXY_NAMED ? WINHTTP_ACCESS_TYPE_NAMED_PROXY
        : proxy == XLESS_HTTP_PROXY_NONE ? WINHTTP_ACCESS_TYPE_NO_PROXY : WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY;
    s->session = WinHttpOpen(NULL, access, proxy == XLESS_HTTP_PROXY_NAMED ? server : WINHTTP_NO_PROXY_NAME,
                             proxy == XLESS_HTTP_PROXY_NAMED && bypass && *bypass ? bypass : WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
    if (!s->session) goto failed;
    // 1.2 or later; 1.3 where this Windows has it
    if (!set_number(s->session, WINHTTP_OPTION_SECURE_PROTOCOLS, WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3)
        && !set_number(s->session, WINHTTP_OPTION_SECURE_PROTOCOLS, WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2)) goto failed;
    if (!set_number(s->session, WINHTTP_OPTION_REDIRECT_POLICY, WINHTTP_OPTION_REDIRECT_POLICY_NEVER)) goto failed;
    if (WinHttpSetStatusCallback(s->session, happened, WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES | WINHTTP_CALLBACK_FLAG_SECURE_FAILURE, 0)
        == WINHTTP_INVALID_STATUS_CALLBACK) goto failed;
    return s;
failed:
    *code = GetLastError();
    xless_http_close(s);
    return NULL;
}

void xless_http_close(struct xless_http_session *s) {
    if (!s) return;
    if (s->session) WinHttpCloseHandle(s->session);
    free(s);
}

static void release(struct xless_http_exchange *x) {
    if (x->buffer) { SecureZeroMemory(x->buffer, PIECE); free(x->buffer); }
    if (x->done) CloseHandle(x->done);
    if (x->cancelled) CloseHandle(x->cancelled);
    if (x->closed) CloseHandle(x->closed);
    free(x);
}

struct xless_http_exchange *xless_http_begin(struct xless_http_session *s, const struct xless_http_request *r, unsigned long *code) {
    struct xless_http_exchange *x = calloc(1, sizeof *x);
    if (!x) { *code = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    x->timeout = r->timeout_ms;
    x->https = r->https;
    x->buffer = malloc(PIECE);
    x->done = CreateEventW(NULL, FALSE, FALSE, NULL);
    x->cancelled = CreateEventW(NULL, TRUE, FALSE, NULL);
    x->closed = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!x->buffer || !x->done || !x->cancelled || !x->closed) { *code = ERROR_NOT_ENOUGH_MEMORY; release(x); return NULL; }
    x->connection = WinHttpConnect(s->session, r->host, r->port, 0);
    if (!x->connection) { *code = GetLastError(); release(x); return NULL; }
    // Path and query go as they are.
    x->request = WinHttpOpenRequest(x->connection, r->method, r->target, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                    WINHTTP_FLAG_ESCAPE_DISABLE | WINHTTP_FLAG_ESCAPE_DISABLE_QUERY | (r->https ? WINHTTP_FLAG_SECURE : 0));
    if (!x->request) { *code = GetLastError(); WinHttpCloseHandle(x->connection); release(x); return NULL; }
    DWORD_PTR context = (DWORD_PTR)x;
    if (!WinHttpSetOption(x->request, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof context)) {
        // without it nothing is ever told of this handle: closing it is enough
        *code = GetLastError();
        WinHttpCloseHandle(x->request);
        WinHttpCloseHandle(x->connection);
        release(x);
        return NULL;
    }
    int milliseconds = r->timeout_ms > 0x7fffffff ? 0x7fffffff : (int)r->timeout_ms;
    // No cookie is kept or sent, no redirect followed, and no name or password of Windows goes to any server or proxy.
    BOOL ok = set_number(x->request, WINHTTP_OPTION_DISABLE_FEATURE, WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_AUTHENTICATION)
        && set_number(x->request, WINHTTP_OPTION_AUTOLOGON_POLICY, WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH)
        && set_number(x->request, WINHTTP_OPTION_DECOMPRESSION, WINHTTP_DECOMPRESSION_FLAG_ALL)
        && set_number(x->request, WINHTTP_OPTION_CONNECT_RETRIES, 1)
        && WinHttpSetTimeouts(x->request, milliseconds, milliseconds, milliseconds, milliseconds)
        && set_number(x->request, WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT, (DWORD)milliseconds)
        && (!r->https || WinHttpSetOption(x->request, WINHTTP_OPTION_CLIENT_CERT_CONTEXT, WINHTTP_NO_CLIENT_CERT_CONTEXT, 0))
        && (!r->headers || !*r->headers || WinHttpAddRequestHeaders(x->request, r->headers, (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD));
    if (!ok) { *code = GetLastError(); xless_http_end(x); return NULL; }
    return x;
}

unsigned long xless_http_send(struct xless_http_exchange *x, uint32_t length) {
    return finished(x, WinHttpSendRequest(x->request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, length, (DWORD_PTR)x),
                    WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE);
}

unsigned long xless_http_write(struct xless_http_exchange *x, const void *bytes, size_t length) {
    const BYTE *from = bytes;
    while (length) {
        DWORD piece = length > PIECE ? PIECE : (DWORD)length;
        memcpy(x->buffer, from, piece);
        DWORD code = finished(x, WinHttpWriteData(x->request, x->buffer, piece, NULL), WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE);
        if (code) return code;
        if (x->value == 0 || x->value > piece) return ERROR_INVALID_DATA;
        from += x->value;
        length -= x->value;
    }
    return 0;
}

unsigned long xless_http_receive(struct xless_http_exchange *x, int *status) {
    DWORD code = finished(x, WinHttpReceiveResponse(x->request, NULL), WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE);
    if (code) return code;
    if (x->https) {
        // What a proxy answers by itself, to the CONNECT, is nothing the server said.
        PCCERT_CONTEXT certificate = NULL;
        DWORD size = sizeof certificate;
        if (!WinHttpQueryOption(x->request, WINHTTP_OPTION_SERVER_CERT_CONTEXT, &certificate, &size) || !certificate) return XLESS_HTTP_NOT_THE_SERVER;
        CertFreeCertificateContext(certificate);
    }
    DWORD number = 0, size = sizeof number;
    if (!WinHttpQueryHeaders(x->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &number, &size, WINHTTP_NO_HEADER_INDEX))
        return GetLastError();
    *status = (int)number;
    return 0;
}

size_t xless_http_headers(struct xless_http_exchange *x, wchar_t *out, size_t length) {
    DWORD size = length > 0x7fffffff / sizeof *out ? 0x7fffffff : (DWORD)(length * sizeof *out);
    if (WinHttpQueryHeaders(x->request, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, out, &size, WINHTTP_NO_HEADER_INDEX)) return size / sizeof *out;
    return GetLastError() == ERROR_INSUFFICIENT_BUFFER ? size / sizeof *out + 1 : 0;
}

int64_t xless_http_read(struct xless_http_exchange *x, void *out, size_t length, unsigned long *code) {
    if ((*code = finished(x, WinHttpQueryDataAvailable(x->request, NULL), WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE))) return -1;
    DWORD piece = x->value > PIECE ? PIECE : x->value;
    if (piece > length) piece = (DWORD)length;
    if (!piece) return 0;
    if ((*code = finished(x, WinHttpReadData(x->request, x->buffer, piece, NULL), WINHTTP_CALLBACK_STATUS_READ_COMPLETE))) return -1;
    if (x->value > piece) { *code = ERROR_INVALID_DATA; return -1; }
    memcpy(out, x->buffer, x->value);
    return x->value;
}

unsigned int xless_http_secure_failure(struct xless_http_exchange *x) { return x->secure; }

void xless_http_cancel(struct xless_http_exchange *x) { SetEvent(x->cancelled); }

void xless_http_end(struct xless_http_exchange *x) {
    if (!x) return;
    WinHttpCloseHandle(x->request);
    DWORD waited = WaitForSingleObject(x->closed, 60000);
    WinHttpCloseHandle(x->connection);
    // A WinHTTP that never says it is done may still write there: rather leaked than written to when it is somebody else's.
    if (waited == WAIT_OBJECT_0) release(x);
}

#endif
