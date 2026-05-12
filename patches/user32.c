#include <pthread.h>
#include "internal.h"

/* Minimal USER32 stubs for UMDF driver message pump.
 * The driver creates a hidden window and runs a message loop on a
 * background thread for internal state management. Since actual USB I/O
 * is handled by libusb, we only need to provide enough of the Win32
 * message infrastructure to keep the driver running without crashing.
 */

typedef uintptr_t WPARAM;
typedef intptr_t  LPARAM;
typedef intptr_t  LRESULT;
typedef HANDLE    HWND;
typedef HANDLE    HMENU;
typedef HANDLE    HICON;
typedef HANDLE    HCURSOR;
typedef HANDLE    HBRUSH;
typedef DWORD     ATOM;

typedef LRESULT __winfnc (*WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct {
    UINT      cbSize;
    UINT      style;
    WNDPROC   lpfnWndProc;
    INT       cbClsExtra;
    INT       cbWndExtra;
    HANDLE    hInstance;
    HICON     hIcon;
    HCURSOR   hCursor;
    HBRUSH    hbrBackground;
    const char16_t *lpszMenuName;
    const char16_t *lpszClassName;
    HICON     hIconSm;
} WNDCLASSEXW;

typedef struct {
    HWND   hwnd;
    UINT   message;
    WPARAM wParam;
    LPARAM lParam;
    DWORD  time;
    struct { LONG x, y; } pt;
    DWORD  lPrivate;
} MSG;

/* Per-thread message queue: a simple condition-variable-based queue
 * carrying at most one pending message at a time (sufficient for UMDF). */
static pthread_mutex_t msg_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  msg_cond  = PTHREAD_COND_INITIALIZER;
static MSG   pending_msg;
static bool  has_pending = false;
static bool  quit_posted = false;

static ATOM next_atom = 1;

static struct _HANDLE fake_hwnd_data = { .data = NULL, .destr = NULL };
#define FAKE_HWND ((HWND)&fake_hwnd_data)

__winfnc ATOM RegisterClassExW(const WNDCLASSEXW *lpwcx) {
    (void)lpwcx;
    return next_atom++;
}
WINAPI(RegisterClassExW)

__winfnc BOOL UnregisterClassW(const char16_t *lpClassName, HANDLE hInstance) {
    (void)lpClassName; (void)hInstance;
    return TRUE;
}
WINAPI(UnregisterClassW)

__winfnc HWND CreateWindowExW(DWORD exStyle, const char16_t *className,
                               const char16_t *windowName, DWORD style,
                               INT x, INT y, INT w, INT h,
                               HWND parent, HMENU menu, HANDLE instance,
                               void *param) {
    (void)exStyle; (void)className; (void)windowName; (void)style;
    (void)x; (void)y; (void)w; (void)h;
    (void)parent; (void)menu; (void)instance; (void)param;
    return FAKE_HWND;
}
WINAPI(CreateWindowExW)

__winfnc BOOL DestroyWindow(HWND hwnd) {
    (void)hwnd;
    return TRUE;
}
WINAPI(DestroyWindow)

__winfnc BOOL ShowWindow(HWND hwnd, INT nCmdShow) {
    (void)hwnd; (void)nCmdShow;
    return FALSE;
}
WINAPI(ShowWindow)

__winfnc BOOL SetWindowPos(HWND hwnd, HWND hwndInsertAfter, INT x, INT y,
                            INT cx, INT cy, UINT flags) {
    (void)hwnd; (void)hwndInsertAfter; (void)x; (void)y;
    (void)cx; (void)cy; (void)flags;
    return TRUE;
}
WINAPI(SetWindowPos)

/* Message pump */

__winfnc void PostQuitMessage(INT nExitCode) {
    (void)nExitCode;
    pthread_mutex_lock(&msg_mutex);
    quit_posted = true;
    pthread_cond_broadcast(&msg_cond);
    pthread_mutex_unlock(&msg_mutex);
}
WINAPI(PostQuitMessage)

__winfnc BOOL PostMessageW(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    (void)hwnd;
    pthread_mutex_lock(&msg_mutex);
    pending_msg = (MSG){ .hwnd = hwnd, .message = msg, .wParam = wParam, .lParam = lParam };
    has_pending = true;
    pthread_cond_broadcast(&msg_cond);
    pthread_mutex_unlock(&msg_mutex);
    return TRUE;
}
WINAPI(PostMessageW)

__winfnc BOOL PostThreadMessageW(DWORD idThread, UINT msg, WPARAM wParam, LPARAM lParam) {
    (void)idThread;
    return PostMessageW(NULL, msg, wParam, lParam);
}
WINAPI(PostThreadMessageW)

__winfnc BOOL GetMessageW(MSG *lpMsg, HWND hwnd, UINT wMsgFilterMin, UINT wMsgFilterMax) {
    (void)hwnd; (void)wMsgFilterMin; (void)wMsgFilterMax;
    pthread_mutex_lock(&msg_mutex);
    while (!has_pending && !quit_posted)
        pthread_cond_wait(&msg_cond, &msg_mutex);
    if (quit_posted && !has_pending) {
        pthread_mutex_unlock(&msg_mutex);
        if (lpMsg) lpMsg->message = 0x0012; /* WM_QUIT */
        return 0;
    }
    *lpMsg = pending_msg;
    has_pending = false;
    pthread_mutex_unlock(&msg_mutex);
    return TRUE;
}
WINAPI(GetMessageW)

__winfnc BOOL PeekMessageW(MSG *lpMsg, HWND hwnd, UINT wMsgFilterMin,
                            UINT wMsgFilterMax, UINT wRemoveMsg) {
    (void)hwnd; (void)wMsgFilterMin; (void)wMsgFilterMax; (void)wRemoveMsg;
    pthread_mutex_lock(&msg_mutex);
    bool got = has_pending;
    if (got) {
        *lpMsg = pending_msg;
        if (wRemoveMsg & 1) has_pending = false;
    }
    pthread_mutex_unlock(&msg_mutex);
    return got;
}
WINAPI(PeekMessageW)

__winfnc BOOL TranslateMessage(const MSG *lpMsg) {
    (void)lpMsg;
    return FALSE;
}
WINAPI(TranslateMessage)

__winfnc LRESULT DispatchMessageW(const MSG *lpMsg) {
    (void)lpMsg;
    return 0;
}
WINAPI(DispatchMessageW)

__winfnc LRESULT DefWindowProcW(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    (void)hwnd; (void)msg; (void)wParam; (void)lParam;
    return 0;
}
WINAPI(DefWindowProcW)

__winfnc BOOL SendMessageW(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    (void)hwnd; (void)msg; (void)wParam; (void)lParam;
    return 0;
}
WINAPI(SendMessageW)

__winfnc BOOL SetWindowLongPtrW(HWND hwnd, INT nIndex, LONG_PTR dwNewLong) {
    (void)hwnd; (void)nIndex; (void)dwNewLong;
    return 0;
}
WINAPI(SetWindowLongPtrW)

__winfnc LONG_PTR GetWindowLongPtrW(HWND hwnd, INT nIndex) {
    (void)hwnd; (void)nIndex;
    return 0;
}
WINAPI(GetWindowLongPtrW)

static HANDLE __winfnc RegisterPowerSettingNotification(HANDLE hRecipient, GUID *PowerSettingGuid, DWORD Flags) {
    WIN_CLOBBER_NONVOL_REGS
    (void)hRecipient; (void)PowerSettingGuid; (void)Flags;
    return winhandle_create(NULL, NULL);
}
WINAPI(RegisterPowerSettingNotification)

static BOOL __winfnc WTSRegisterSessionNotification(HANDLE hWnd, DWORD dwFlags) {
    WIN_CLOBBER_NONVOL_REGS
    (void)hWnd; (void)dwFlags;
    return 1;
}
WINAPI(WTSRegisterSessionNotification)
