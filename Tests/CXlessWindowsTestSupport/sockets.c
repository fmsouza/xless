// Windows only (Package.swift): the servers of the tests.
#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "CXlessWindowsTestSupport.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <string.h>

static int started(void) {
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data) == 0; // counted: once too often is no matter
}

intptr_t xless_test_listen(uint16_t *port) {
    if (!started()) return -1;
    SOCKET s = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    if (s == INVALID_SOCKET) return -1;
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int length = sizeof address;
    if (bind(s, (struct sockaddr *)&address, sizeof address) || listen(s, 16) || getsockname(s, (struct sockaddr *)&address, &length)) {
        closesocket(s);
        return -1;
    }
    *port = ntohs(address.sin_port);
    return (intptr_t)s;
}

// A process that read a secret ends at the use of a handle that is closed (ProcessStrictHandleCheckPolicy), so a listener is closed by
// nobody but the one who accepts there: what is stopped meanwhile is remembered here.
static SRWLOCK stopping = SRWLOCK_INIT;
static SOCKET stopped[1024];
static size_t stopped_count;

static int take_stopped(SOCKET listener) {
    int found = 0;
    AcquireSRWLockExclusive(&stopping);
    for (size_t i = 0; i < stopped_count && !found; i++)
        if (stopped[i] == listener) { stopped[i] = stopped[--stopped_count]; found = 1; }
    ReleaseSRWLockExclusive(&stopping);
    return found;
}

intptr_t xless_test_accept(intptr_t listener) {
    SOCKET s = accept((SOCKET)listener, NULL, NULL);
    if (take_stopped((SOCKET)listener)) {
        if (s != INVALID_SOCKET) closesocket(s);
        closesocket((SOCKET)listener);
        return -1;
    }
    return s == INVALID_SOCKET ? -1 : (intptr_t)s;
}

void xless_test_stop(intptr_t listener) {
    struct sockaddr_in address;
    int length = sizeof address;
    if (getsockname((SOCKET)listener, (struct sockaddr *)&address, &length)) return;
    AcquireSRWLockExclusive(&stopping);
    if (stopped_count < sizeof stopped / sizeof *stopped) stopped[stopped_count++] = (SOCKET)listener;
    ReleaseSRWLockExclusive(&stopping);
    intptr_t waker = xless_test_connect(ntohs(address.sin_port));
    if (waker >= 0) closesocket((SOCKET)waker);
}

intptr_t xless_test_connect(uint16_t port) {
    if (!started()) return -1;
    SOCKET s = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    if (s == INVALID_SOCKET) return -1;
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    if (connect(s, (struct sockaddr *)&address, sizeof address)) { closesocket(s); return -1; }
    return (intptr_t)s;
}

int64_t xless_test_receive(intptr_t connection, void *bytes, size_t length) {
    return recv((SOCKET)connection, bytes, length > 1 << 20 ? 1 << 20 : (int)length, 0);
}

int64_t xless_test_send(intptr_t connection, const void *bytes, size_t length) {
    const char *from = bytes;
    size_t left = length;
    while (left) {
        int put = send((SOCKET)connection, from, left > 1 << 20 ? 1 << 20 : (int)left, 0);
        if (put <= 0) return -1;
        from += put;
        left -= (size_t)put;
    }
    return (int64_t)length;
}

void xless_test_finish(intptr_t connection) {
    SOCKET s = (SOCKET)connection;
    struct linger lingers = { 0, 0 };
    int length = sizeof lingers;
    if (getsockopt(s, SOL_SOCKET, SO_LINGER, (char *)&lingers, &length) == 0 && lingers.l_onoff && !lingers.l_linger) { closesocket(s); return; }
    shutdown(s, SD_SEND);
    DWORD wait = 500;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&wait, sizeof wait);
    char rest[4096];
    while (recv(s, rest, sizeof rest, 0) > 0) {}
    closesocket(s);
}

void xless_test_reset(intptr_t connection) {
    struct linger at_once = { 1, 0 };
    setsockopt((SOCKET)connection, SOL_SOCKET, SO_LINGER, (const char *)&at_once, sizeof at_once);
}

void xless_test_close(intptr_t socket) { closesocket((SOCKET)socket); }

#endif
