/*
 * DOOM for Storio TV / InnoTV (Android 4.2, ARMv7) - platform layer.
 * NativeActivity with no Java code: video via ANativeWindow, controller via AInputQueue.
 * Based on doomgeneric (GPLv2).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include "doomgeneric.h"
#include "doomkeys.h"

/* ---------------------------------------------------------------- minimal NDK API */
typedef struct ANativeActivity ANativeActivity;
typedef struct ANativeWindow ANativeWindow;
typedef struct AInputQueue AInputQueue;
typedef struct AInputEvent AInputEvent;
typedef struct ALooper ALooper;
typedef struct AAssetManager AAssetManager;
typedef struct AAsset AAsset;
typedef struct ARect { int32_t left, top, right, bottom; } ARect;

typedef struct ANativeActivityCallbacks {
    void (*onStart)(ANativeActivity*);
    void (*onResume)(ANativeActivity*);
    void* (*onSaveInstanceState)(ANativeActivity*, size_t*);
    void (*onPause)(ANativeActivity*);
    void (*onStop)(ANativeActivity*);
    void (*onDestroy)(ANativeActivity*);
    void (*onWindowFocusChanged)(ANativeActivity*, int);
    void (*onNativeWindowCreated)(ANativeActivity*, ANativeWindow*);
    void (*onNativeWindowResized)(ANativeActivity*, ANativeWindow*);
    void (*onNativeWindowRedrawNeeded)(ANativeActivity*, ANativeWindow*);
    void (*onNativeWindowDestroyed)(ANativeActivity*, ANativeWindow*);
    void (*onInputQueueCreated)(ANativeActivity*, AInputQueue*);
    void (*onInputQueueDestroyed)(ANativeActivity*, AInputQueue*);
    void (*onContentRectChanged)(ANativeActivity*, const ARect*);
    void (*onConfigurationChanged)(ANativeActivity*);
    void (*onLowMemory)(ANativeActivity*);
} ANativeActivityCallbacks;

struct ANativeActivity {
    ANativeActivityCallbacks* callbacks;
    void* vm; void* env; void* clazz;
    const char* internalDataPath;
    const char* externalDataPath;
    int32_t sdkVersion;
    void* instance;
    AAssetManager* assetManager;
    const char* obbPath;
};

typedef struct ANativeWindow_Buffer {
    int32_t width, height, stride, format;
    void* bits;
    uint32_t reserved[6];
} ANativeWindow_Buffer;

typedef int (*ALooper_callbackFunc)(int fd, int events, void* data);

int32_t ANativeWindow_getWidth(ANativeWindow*);
int32_t ANativeWindow_getHeight(ANativeWindow*);
int32_t ANativeWindow_setBuffersGeometry(ANativeWindow*, int32_t, int32_t, int32_t);
int32_t ANativeWindow_lock(ANativeWindow*, ANativeWindow_Buffer*, ARect*);
int32_t ANativeWindow_unlockAndPost(ANativeWindow*);
void ANativeWindow_acquire(ANativeWindow*);
void ANativeWindow_release(ANativeWindow*);
ALooper* ALooper_forThread(void);
void AInputQueue_attachLooper(AInputQueue*, ALooper*, int, ALooper_callbackFunc, void*);
void AInputQueue_detachLooper(AInputQueue*);
int32_t AInputQueue_getEvent(AInputQueue*, AInputEvent**);
int32_t AInputQueue_preDispatchEvent(AInputQueue*, AInputEvent*);
void AInputQueue_finishEvent(AInputQueue*, AInputEvent*, int);
int32_t AInputEvent_getType(const AInputEvent*);
int32_t AInputEvent_getSource(const AInputEvent*);
int32_t AKeyEvent_getAction(const AInputEvent*);
int32_t AKeyEvent_getKeyCode(const AInputEvent*);
int32_t AKeyEvent_getRepeatCount(const AInputEvent*);
int32_t AMotionEvent_getAction(const AInputEvent*);
float AMotionEvent_getAxisValue(const AInputEvent*, int32_t axis, size_t pointer);
AAsset* AAssetManager_open(AAssetManager*, const char*, int);
int AAsset_read(AAsset*, void*, size_t);
void AAsset_close(AAsset*);
void ANativeActivity_finish(ANativeActivity*);
int __android_log_print(int prio, const char* tag, const char* fmt, ...);
int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list);

typedef long pthread_t;
int pthread_create(pthread_t*, const void*, void* (*)(void*), void*);

#define WINDOW_FORMAT_RGBX_8888 2
#define AINPUT_EVENT_TYPE_KEY 1
#define AINPUT_EVENT_TYPE_MOTION 2
#define AKEY_EVENT_ACTION_DOWN 0
#define AKEY_EVENT_ACTION_UP 1
#define AASSET_MODE_STREAMING 2
#define LOG_I 4
#define LOG_E 6
#define TAG "DOOM"

/* ---------------------------------------------------------------- stdout/stderr -> logcat */
int real_vfprintf(FILE*, const char*, va_list) __asm__("vfprintf");
int real_fputs(const char*, FILE*) __asm__("fputs");
int real_fputc(int, FILE*) __asm__("fputc");
int real_fflush(FILE*) __asm__("fflush");
size_t real_fwrite(const void*, size_t, size_t, FILE*) __asm__("fwrite");

static int is_console(FILE* f) { return f == (FILE*)1 || f == (FILE*)2 || f == (FILE*)3; }
static char logline[1024]; static int loglen = 0;
static void log_chars(const char* s, int n) {
    for (int i = 0; i < n; i++) {
        if (s[i] == '\n' || loglen >= (int)sizeof(logline) - 1) {
            logline[loglen] = 0;
            if (loglen) __android_log_print(LOG_I, TAG, "%s", logline);
            loglen = 0;
            if (s[i] == '\n') continue;
        }
        logline[loglen++] = s[i];
    }
}
int dg_vfprintf(FILE* f, const char* fmt, va_list ap) {
    if (!is_console(f)) return real_vfprintf(f, fmt, ap);
    char buf[1024];
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    log_chars(buf, n < (int)sizeof buf ? n : (int)sizeof buf - 1);
    return n;
}
int dg_fprintf(FILE* f, const char* fmt, ...) { va_list ap; va_start(ap, fmt); int r = dg_vfprintf(f, fmt, ap); va_end(ap); return r; }
int dg_vprintf(const char* fmt, va_list ap) { return dg_vfprintf(stdout, fmt, ap); }
int dg_printf(const char* fmt, ...) { va_list ap; va_start(ap, fmt); int r = dg_vfprintf(stdout, fmt, ap); va_end(ap); return r; }
int dg_puts(const char* s) { log_chars(s, strlen(s)); log_chars("\n", 1); return 1; }
int dg_putchar(int c) { char ch = (char)c; log_chars(&ch, 1); return c; }
int dg_fputs(const char* s, FILE* f) { if (!is_console(f)) return real_fputs(s, f); log_chars(s, strlen(s)); return 1; }
int dg_fputc(int c, FILE* f) { if (!is_console(f)) return real_fputc(c, f); char ch = (char)c; log_chars(&ch, 1); return c; }
int dg_fflush(FILE* f) { if (f == NULL || is_console(f)) return 0; return real_fflush(f); }
size_t dg_fwrite(const void* p, size_t s, size_t n, FILE* f) { if (!is_console(f)) return real_fwrite(p, s, n, f); log_chars(p, (int)(s * n)); return n; }

/* ---------------------------------------------------------------- shared state */
static volatile int win_lock = 0;
static ANativeWindow* volatile window = NULL;
static volatile int paused = 0;
static ANativeActivity* g_activity = NULL;
static char g_datadir[512];
static char g_wadpath[512];

static void lock(volatile int* l) { while (__sync_lock_test_and_set(l, 1)) usleep(100); }
static void unlock(volatile int* l) { __sync_lock_release(l); }

/* key queue (main thread -> game thread) */
#define KQ 256
static volatile unsigned short keyq[KQ];
static volatile int kq_head = 0, kq_tail = 0, kq_lock = 0;
static void push_key(int pressed, unsigned char key) {
    lock(&kq_lock);
    int next = (kq_head + 1) % KQ;
    if (next != kq_tail) { keyq[kq_head] = (unsigned short)((pressed << 8) | key); kq_head = next; }
    unlock(&kq_lock);
}
/* ---------------------------------------------------------------- wheel -> strafe */
/* Each "click" of the wheel holds strafe down for a short time (wheel_ms); turning it
   continuously keeps it held. Clockwise = right (can be flipped with "wheel=invert"). */
static volatile int wheel_lock = 0;
static int wheel_dir = 0;               /* -1 left, 0 none, +1 right */
static long long wheel_until = 0;
static int wheel_ms = 180, wheel_inv = 0, wheel_off = 0, wheel_logs = 0;
static long long mono_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000LL + t.tv_nsec / 1000000; }
static void wheel_step(int delta, const char* source) {
    if (delta == 0 || wheel_off) return;
    int dir = (delta > 0) ? 1 : -1;
    if (wheel_inv) dir = -dir;
    if (wheel_logs < 40) { wheel_logs++; __android_log_print(LOG_I, TAG, "Wheel (%s): %+d -> %s", source, delta, dir > 0 ? "right" : "left"); }
    lock(&wheel_lock);
    long long now = mono_ms();
    if (wheel_dir != dir) {
        if (wheel_dir) push_key(0, wheel_dir > 0 ? KEY_STRAFE_R : KEY_STRAFE_L);
        push_key(1, dir > 0 ? KEY_STRAFE_R : KEY_STRAFE_L);
        wheel_dir = dir;
        wheel_until = now;
    }
    int steps = delta < 0 ? -delta : delta; if (steps > 4) steps = 4;
    if (wheel_until < now) wheel_until = now;
    wheel_until += (long long)wheel_ms * steps;
    if (wheel_until > now + 3 * wheel_ms) wheel_until = now + 3 * wheel_ms;
    unlock(&wheel_lock);
}
static void wheel_poll(void) {
    if (!wheel_dir) return;
    lock(&wheel_lock);
    if (wheel_dir && mono_ms() >= wheel_until) { push_key(0, wheel_dir > 0 ? KEY_STRAFE_R : KEY_STRAFE_L); wheel_dir = 0; }
    unlock(&wheel_lock);
}

int DG_GetKey(int* pressed, unsigned char* key) {
    int r = 0;
    wheel_poll();
    lock(&kq_lock);
    if (kq_tail != kq_head) {
        unsigned short v = keyq[kq_tail]; kq_tail = (kq_tail + 1) % KQ;
        *pressed = v >> 8; *key = v & 0xff; r = 1;
    }
    unlock(&kq_lock);
    return r;
}

/* ---------------------------------------------------------------- button map */
/* Each Android button can generate up to 2 Doom keys. Can be changed with
   /sdcard/doom_buttons.txt (lines "code=action[,action]"); the old name
   /sdcard/doom_botones.txt is still accepted. */
enum { A_NONE = 0 };
#define MAXCODE 320
static unsigned char map1[MAXCODE], map2[MAXCODE];
static void bindkey(int code, int k1, int k2) { if (code >= 0 && code < MAXCODE) { map1[code] = k1; map2[code] = k2; } }
/* buttons read directly from /dev/input (Linux codes): lines "rCODE=action" in doom_buttons.txt */
#define MAXRAW 768
static unsigned char raw1[MAXRAW], raw2[MAXRAW];
static void bindraw(int code, int k1, int k2) { if (code >= 0 && code < MAXRAW) { raw1[code] = k1; raw2[code] = k2; } }

static int action_from_name(const char* n) {
    /* English names, then the original Spanish names (still accepted) */
    struct { const char* n; int k; } t[] = {
        {"up", KEY_UPARROW}, {"down", KEY_DOWNARROW}, {"left", KEY_LEFTARROW}, {"right", KEY_RIGHTARROW},
        {"fire", KEY_FIRE}, {"use", KEY_USE}, {"run", KEY_RSHIFT}, {"strafe", KEY_RALT},
        {"strafe_left", KEY_STRAFE_L}, {"strafe_right", KEY_STRAFE_R}, {"menu", KEY_ESCAPE}, {"enter", KEY_ENTER},
        {"map", KEY_TAB}, {"yes", 'y'}, {"no", 'n'}, {"next_weapon", ']'}, {"prev_weapon", '['},
        {"pause", KEY_PAUSE}, {"backspace", KEY_BACKSPACE},
        {"arriba", KEY_UPARROW}, {"abajo", KEY_DOWNARROW}, {"izquierda", KEY_LEFTARROW}, {"derecha", KEY_RIGHTARROW},
        {"disparar", KEY_FIRE}, {"usar", KEY_USE}, {"correr", KEY_RSHIFT}, {"lateral", KEY_RALT},
        {"lateral_izq", KEY_STRAFE_L}, {"lateral_der", KEY_STRAFE_R},
        {"mapa", KEY_TAB}, {"si", 'y'}, {"arma_sig", ']'}, {"arma_ant", '['},
        {"1", '1'}, {"2", '2'}, {"3", '3'}, {"4", '4'}, {"5", '5'}, {"6", '6'}, {"7", '7'},
        {"pausa", KEY_PAUSE}, {"borrar", KEY_BACKSPACE},
    };
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) if (!strcmp(t[i].n, n)) return t[i].k;
    return 0;
}

static void default_bindings(void) {
    bindkey(19, KEY_UPARROW, 0);   bindkey(20, KEY_DOWNARROW, 0);           /* DPAD up/down */
    bindkey(21, KEY_LEFTARROW, 0); bindkey(22, KEY_RIGHTARROW, 0);          /* DPAD left/right */
    bindkey(23, KEY_FIRE, KEY_ENTER); bindkey(66, KEY_FIRE, KEY_ENTER);     /* centro / ENTER */
    bindkey(96, KEY_FIRE, KEY_ENTER);                                    /* A */
    bindkey(97, KEY_USE, 'y');                                           /* B */
    bindkey(99, KEY_RSHIFT, 0);                                          /* X: run */
    bindkey(100, ']', 0);                                                /* Y: next weapon */
    bindkey(102, KEY_STRAFE_L, 0); bindkey(103, KEY_STRAFE_R, 0);           /* L1 / R1 */
    bindkey(104, '[', 0); bindkey(105, KEY_TAB, 0);                         /* L2 / R2 */
    bindkey(108, KEY_ESCAPE, 0); bindkey(82, KEY_ESCAPE, 0);                /* START / MENU */
    bindkey(109, KEY_TAB, 0);                                            /* SELECT */
    bindkey(4, KEY_ESCAPE, 0);                                           /* BACK */
    bindkey(62, KEY_USE, 'y');                                           /* space */
    bindkey(188, KEY_FIRE, KEY_ENTER); bindkey(189, KEY_USE, 'y');          /* BUTTON_1 / BUTTON_2 (generic controllers) */
    bindkey(190, KEY_RSHIFT, 0); bindkey(191, ']', 0);
    /* VTech controller (Linux codes from /dev/input/eventvj*) */
    bindraw(0x12f, KEY_FIRE, KEY_ENTER);   /* BTN_DEAD: main button -> fire */
    bindraw(0x18f, KEY_USE, 'y');          /* KEY_GREEN: green button -> open doors / yes */
    bindraw(0x18e, ']', 0);                /* KEY_RED: red button -> next weapon */
    bindraw(138, KEY_ESCAPE, 0);           /* KEY_HELP: help -> menu */
    bindraw(0x229, KEY_TAB, 0);            /* 0x229 -> map */
    bindraw(0x220, KEY_RSHIFT, 0);         /* 0x220 -> run */
    bindraw(0x222, '[', 0);                /* 0x222 -> previous weapon */
}

static void load_bindings(void) {
    /* English file name first, then the old Spanish one */
    const char* paths[] = { "/sdcard/doom_buttons.txt", "/mnt/sdcard/doom_buttons.txt",
                            "/sdcard/doom_botones.txt", "/mnt/sdcard/doom_botones.txt" };
    for (int p = 0; p < (int)(sizeof paths / sizeof paths[0]); p++) {
        FILE* f = fopen(paths[p], "r");
        if (!f) continue;
        __android_log_print(LOG_I, TAG, "Button map: %s", paths[p]);
        char line[128];
        while (fgets(line, sizeof line, f)) {
            char* eq = strchr(line, '=');
            if (!eq || line[0] == '#') continue;
            *eq = 0;
            if (!strcmp(line, "wheel") || !strcmp(line, "ruleta")) {   /* "ruleta" = old Spanish name */
                char* v = eq + 1; char* e = strchr(v, '\n'); if (e) *e = 0; e = strchr(v, '\r'); if (e) *e = 0;
                if (!strncmp(v, "invert", 6)) wheel_inv = 1;   /* also matches "invertir" */
                else if (!strncmp(v, "off", 3) || !strncmp(v, "no", 2)) wheel_off = 1;
                else if (atoi(v) >= 30 && atoi(v) <= 1000) wheel_ms = atoi(v);
                __android_log_print(LOG_I, TAG, "Wheel: %s (time %d ms, inverted %d, disabled %d)", v, wheel_ms, wheel_inv, wheel_off);
                continue;
            }
            int israw = (line[0] == 'r' || line[0] == 'R');
            int code = (int)strtol(israw ? line + 1 : line, NULL, 0);
            char* a = eq + 1; char* nl = strchr(a, '\n'); if (nl) *nl = 0; nl = strchr(a, '\r'); if (nl) *nl = 0;
            char* comma = strchr(a, ',');
            int k2 = 0;
            if (comma) { *comma = 0; k2 = action_from_name(comma + 1); }
            if (israw) bindraw(code, action_from_name(a), k2); else bindkey(code, action_from_name(a), k2);
            __android_log_print(LOG_I, TAG, "Button %s%d -> %s", israw ? "r" : "", code, a);
        }
        fclose(f);
        return;
    }
}

/* joystick axes -> arrow keys */
static int axis_state[4]; /* left, right, up, down */
static void axis_to_keys(float x, float y) {
    int want[4] = { x < -0.5f, x > 0.5f, y < -0.5f, y > 0.5f };
    unsigned char keys[4] = { KEY_LEFTARROW, KEY_RIGHTARROW, KEY_UPARROW, KEY_DOWNARROW };
    for (int i = 0; i < 4; i++)
        if (want[i] != axis_state[i]) { axis_state[i] = want[i]; push_key(want[i], keys[i]); }
}

static int handle_event(AInputEvent* ev) {
    int type = AInputEvent_getType(ev);
    if (type == AINPUT_EVENT_TYPE_KEY) {
        int code = AKeyEvent_getKeyCode(ev);
        int action = AKeyEvent_getAction(ev);
        if (code == 24 || code == 25 || code == 164) return 0;   /* volume: handled by the system */
        if (code == 3) return 0;                                  /* HOME */
        if (action != AKEY_EVENT_ACTION_DOWN && action != AKEY_EVENT_ACTION_UP) return 1;
        if (action == AKEY_EVENT_ACTION_DOWN && AKeyEvent_getRepeatCount(ev) > 0) return 1;
        int down = action == AKEY_EVENT_ACTION_DOWN;
        __android_log_print(LOG_I, TAG, "Android key %d %s", code, down ? "pressed" : "released");
        if (code >= 0 && code < MAXCODE && map1[code]) {
            push_key(down, map1[code]);
            if (map2[code]) push_key(down, map2[code]);
        }
        return 1;
    }
    if (type == AINPUT_EVENT_TYPE_MOTION) {
        float x = AMotionEvent_getAxisValue(ev, 0, 0);    /* AXIS_X */
        float y = AMotionEvent_getAxisValue(ev, 1, 0);    /* AXIS_Y */
        float hx = AMotionEvent_getAxisValue(ev, 15, 0);  /* AXIS_HAT_X */
        float hy = AMotionEvent_getAxisValue(ev, 16, 0);  /* AXIS_HAT_Y */
        if (hx < -0.5f || hx > 0.5f) x = hx;
        if (hy < -0.5f || hy > 0.5f) y = hy;
        axis_to_keys(x, y);
        /* wheel as seen by Android: AXIS_WHEEL (absolute) or AXIS_VSCROLL/HSCROLL (relative) */
        {
            static float last_w = -100.0f;
            float w = AMotionEvent_getAxisValue(ev, 21, 0);
            float vs = AMotionEvent_getAxisValue(ev, 9, 0), hs = AMotionEvent_getAxisValue(ev, 10, 0);
            if (last_w > -50.0f && w != last_w) {
                float d = w - last_w;
                if (d > 1.0f) d -= 2.0f; else if (d < -1.0f) d += 2.0f;   /* wrap-around of the -1..1 range */
                if (d > 0.001f || d < -0.001f) wheel_step(d > 0 ? 1 : -1, "android axis");
            }
            last_w = w;
            if (vs > 0.1f || vs < -0.1f) wheel_step(vs > 0 ? 1 : -1, "android scroll");
            if (hs > 0.1f || hs < -0.1f) wheel_step(hs > 0 ? 1 : -1, "android hscroll");
        }
        return 1;
    }
    return 0;
}

static int input_cb(int fd, int events, void* data) {
    AInputQueue* q = (AInputQueue*)data;
    AInputEvent* ev = NULL;
    while (AInputQueue_getEvent(q, &ev) >= 0) {
        if (AInputQueue_preDispatchEvent(q, ev)) continue;
        AInputQueue_finishEvent(q, ev, handle_event(ev));
    }
    return 1;
}


/* ---------------------------------------------------------------- raw VTech controller */
#include <fcntl.h>
#include <errno.h>
struct input_event_32 { long sec; long usec; uint16_t type; uint16_t code; int32_t value; };
int ioctl(int, int, ...);
static void* raw_thread(void* arg) {
    int fd = (int)(long)arg;
    int absprev[64] = {0}, abshave[64] = {0}, absrange[64] = {0}, unk_logs = 0;
    struct input_event_32 ev[16];
    for (;;) {
        int n = read(fd, ev, sizeof ev);
        if (n <= 0) { usleep(100000); continue; }
        for (int i = 0; i < n / (int)sizeof ev[0]; i++) {
            if (ev[i].type == 3) {   /* EV_ABS */
                int c = ev[i].code;
                if (c == 0x02 || c == 0x1a || c == 0x1b) continue;   /* accelerometer (Z, TILT_X, TILT_Y) */
                if (c == 0x08 || c == 0x07 || c == 0x06) {            /* ABS_WHEEL / ABS_RUDDER / ABS_THROTTLE */
                    if (c < 0 || c >= 64) continue;
                    if (absrange[c] == 0) {   /* axis range, to handle wrap-around */
                        int info[6] = {0};
                        if (ioctl(fd, 0x80184540 + c, info) == 0 && info[2] > info[1]) absrange[c] = info[2] - info[1] + 1;
                        else absrange[c] = 256;
                        __android_log_print(LOG_I, TAG, "Wheel: axis 0x%x range %d..%d", c, info[1], info[2]);
                    }
                    if (abshave[c]) {
                        int d = ev[i].value - absprev[c], R = absrange[c];
                        if (d > R / 2) d -= R; else if (d < -R / 2) d += R;
                        if (d) wheel_step(d, "axis");
                    }
                    absprev[c] = ev[i].value; abshave[c] = 1;
                } else if (unk_logs < 30) { unk_logs++; __android_log_print(LOG_I, TAG, "Unknown axis 0x%x = %d", c, ev[i].value); }
                continue;
            }
            if (ev[i].type == 2) {   /* EV_REL */
                int c = ev[i].code;
                if (c == 0x08 || c == 0x06 || c == 0x07) {
                    /* The VTech controller sends the wheel centred on 128: 148 = clockwise,
                       108 = anticlockwise, 128 = idle. A normal mouse sends +1/-1. */
                    int v = ev[i].value, d = (v >= 32 && v <= 224) ? v - 128 : v;
                    if (d > 2 || d < -2) { int st = (d < 0 ? -d : d) / 20; if (st < 1) st = 1; d = d > 0 ? st : -st; }
                    if (d) wheel_step(d, "rel");
                }
                else if (unk_logs < 30) { unk_logs++; __android_log_print(LOG_I, TAG, "Unknown relative axis 0x%x = %d", c, ev[i].value); }
                continue;
            }
            if (ev[i].type != 1 || ev[i].value == 2) continue;   /* EV_KEY only, no auto-repeat */
            int code = ev[i].code, down = ev[i].value != 0;
            __android_log_print(LOG_I, TAG, "VTech button r%d (0x%x) %s", code, code, down ? "pressed" : "released");
            if (code < MAXRAW && raw1[code]) {
                push_key(down, raw1[code]);
                if (raw2[code]) push_key(down, raw2[code]);
            }
        }
    }
    return NULL;
}
static void start_raw_input(void) {
    const char* devs[] = { "/dev/input/eventvj1", "/dev/input/eventvj2", "/dev/input/eventvj3", "/dev/input/eventvj4" };
    int opened = 0;
    for (int i = 0; i < 4; i++) {
        int fd = open(devs[i], O_RDONLY);
        if (fd < 0) { __android_log_print(LOG_I, TAG, "Cannot open %s (errno %d)", devs[i], errno); continue; }
        __android_log_print(LOG_I, TAG, "Reading controller on %s", devs[i]);
        pthread_t t; pthread_create(&t, NULL, raw_thread, (void*)(long)fd); opened++;
    }
    {   /* "vtech mouse": in case the wheel arrives as a mouse wheel */
        int fd = open("/dev/input/event8", O_RDONLY);
        if (fd >= 0) { __android_log_print(LOG_I, TAG, "Reading VTech mouse on /dev/input/event8"); pthread_t t; pthread_create(&t, NULL, raw_thread, (void*)(long)fd); }
        else __android_log_print(LOG_I, TAG, "Cannot open /dev/input/event8 (errno %d)", errno);
    }
    if (!opened) {
        int fd = open("/dev/input/event2", O_RDONLY);
        if (fd >= 0) { __android_log_print(LOG_I, TAG, "Reading controller on /dev/input/event2"); pthread_t t; pthread_create(&t, NULL, raw_thread, (void*)(long)fd); }
        else __android_log_print(LOG_E, TAG, "No access to the VTech buttons (errno %d). Try: adb shell chmod 666 /dev/input/event*", errno);
    }
}


/* ---------------------------------------------------------------- icon server (127.0.0.1 only) */
/* The VTech manager builds the desktop icon by "downloading" it over HTTP; we serve it locally. */
#include "icon_png.h"
struct sockaddr_in_ { uint16_t family; uint16_t port; uint32_t addr; unsigned char zero[8]; };
int socket(int, int, int); int sock_bind(int, const void*, int) __asm__("bind"); int listen(int, int);
int accept(int, void*, void*); int setsockopt(int, int, int, const void*, int);
static void* icon_server(void* arg) {
    int s = socket(2 /*AF_INET*/, 1 /*SOCK_STREAM*/, 0);
    if (s < 0) { __android_log_print(LOG_I, TAG, "Icon server: socket() failed (errno %d)", errno); return NULL; }
    int one = 1; setsockopt(s, 1 /*SOL_SOCKET*/, 2 /*SO_REUSEADDR*/, &one, sizeof one);
    struct sockaddr_in_ a; memset(&a, 0, sizeof a);
    a.family = 2; a.port = (uint16_t)((8737 >> 8) | ((8737 & 0xff) << 8)); a.addr = 0x0100007f; /* 127.0.0.1 */
    if (sock_bind(s, &a, sizeof a) < 0 || listen(s, 4) < 0) { __android_log_print(LOG_I, TAG, "Icon server: port in use (errno %d)", errno); close(s); return NULL; }
    __android_log_print(LOG_I, TAG, "Icon server on http://127.0.0.1:8737/");
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) { usleep(100000); continue; }
        char req[1024]; read(c, req, sizeof req);
        char hdr[160];
        int n = snprintf(hdr, sizeof hdr, "HTTP/1.0 200 OK\r\nContent-Type: image/png\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", (int)sizeof icon_png);
        write(c, hdr, n);
        write(c, icon_png, sizeof icon_png);
        close(c);
        __android_log_print(LOG_I, TAG, "Icon served");
    }
    return NULL;
}

/* ---------------------------------------------------------------- video */
static uint32_t* fallback_fill = NULL;
static void present(const uint32_t* src, int sw, int sh, uint32_t fill) {
    lock(&win_lock);
    ANativeWindow* w = window;
    if (w) {
        int ww = ANativeWindow_getWidth(w), wh = ANativeWindow_getHeight(w);
        static ANativeWindow* geom_for = NULL;
        if (geom_for != w) {
            int bh = 240, bw = (wh > 0) ? (240 * ww / wh) : 427;
            if (bw < 320) bw = 320;
            ANativeWindow_setBuffersGeometry(w, bw, bh, WINDOW_FORMAT_RGBX_8888);
            geom_for = w;
            __android_log_print(LOG_I, TAG, "Window %dx%d, buffer %dx%d", ww, wh, bw, bh);
        }
        ANativeWindow_Buffer b;
        if (ANativeWindow_lock(w, &b, NULL) == 0) {
            uint32_t* dst = (uint32_t*)b.bits;
            int ox = (b.width - 320) / 2;
            for (int y = 0; y < b.height; y++) {
                uint32_t* row = dst + y * b.stride;
                if (!src) { for (int x = 0; x < b.width; x++) row[x] = fill; continue; }
                for (int x = 0; x < ox; x++) row[x] = 0;
                for (int x = ox + 320; x < b.width; x++) row[x] = 0;
                const uint32_t* s = src + (y * sh / b.height) * sw;   /* 200 -> 240 lines (4:3 aspect) */
                uint32_t* d = row + ox;
                for (int x = 0; x < 320; x++) {
                    uint32_t p = s[x];   /* 0x00RRGGBB -> bytes R,G,B,X */
                    d[x] = ((p >> 16) & 0xff) | (p & 0xff00) | ((p & 0xff) << 16);
                }
            }
            ANativeWindow_unlockAndPost(w);
        }
    }
    unlock(&win_lock);
}

void DG_Init(void) {}
void DG_DrawFrame(void) {
    while (paused) usleep(50000);
    present(DG_ScreenBuffer, DOOMGENERIC_RESX, DOOMGENERIC_RESY, 0);
}
void DG_SleepMs(uint32_t ms) { usleep(ms * 1000); }
uint32_t DG_GetTicksMs(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}
void DG_SetWindowTitle(const char* t) {}

/* ---------------------------------------------------------------- WAD */
static int file_exists(const char* p) { FILE* f = fopen(p, "rb"); if (f) { fclose(f); return 1; } return 0; }

static int copy_asset(const char* name, const char* dest) {
    if (!g_activity || !g_activity->assetManager) return 0;
    AAsset* a = AAssetManager_open(g_activity->assetManager, name, AASSET_MODE_STREAMING);
    if (!a) return 0;
    FILE* f = fopen(dest, "wb");
    if (!f) { AAsset_close(a); return 0; }
    char buf[65536]; int n;
    while ((n = AAsset_read(a, buf, sizeof buf)) > 0) real_fwrite(buf, 1, n, f);
    fclose(f); AAsset_close(a);
    return 1;
}

static int find_wad(void) {
    /* First any DOOM WAD you provide (shareware or full), then Freedoom (bundled in the APK). */
    const char* names[] = { "doom1.wad", "DOOM1.WAD", "doom.wad", "DOOM.WAD", "doom2.wad", "DOOM2.WAD", "freedoom1.wad", "freedoom2.wad" };
    const char* dirs[] = { "/sdcard", "/sdcard/Download", "/sdcard/doom", "/mnt/sdcard", "/storage/sdcard0", g_datadir };
    for (unsigned n = 0; n < sizeof names / sizeof names[0]; n++)
        for (unsigned d = 0; d < sizeof dirs / sizeof dirs[0]; d++) {
            snprintf(g_wadpath, sizeof g_wadpath, "%s/%s", dirs[d], names[n]);
            if (file_exists(g_wadpath)) return 1;
        }
    present(NULL, 0, 0, 0x00202020);   /* gray: copying Freedoom on first run */
    snprintf(g_wadpath, sizeof g_wadpath, "%s/%s", g_datadir, "freedoom1.wad");
    if (copy_asset("freedoom1.wad", g_wadpath)) return 1;
    return 0;
}

/* ---------------------------------------------------------------- game thread */
extern int key_nextweapon, key_prevweapon;

static void* game_thread(void* arg) {
    while (!window) usleep(20000);
    if (!find_wad()) {
        __android_log_print(LOG_E, TAG, "doom1.wad not found. Copy it with: adb push doom1.wad /sdcard/");
        for (;;) { present(NULL, 0, 0, 0x000000a0); usleep(500000); }   /* red screen = WAD missing */
    }
    __android_log_print(LOG_I, TAG, "WAD: %s", g_wadpath);
    chdir(g_datadir);
    setenv("TEMP", g_datadir, 1);   /* music converts MUS->MIDI into a temp file; /tmp does not exist on Android */
    static char* argv[] = { "doom", "-iwad", g_wadpath, NULL, NULL };
    int argc = 3;
    /* no-sound flag file: English name or the old Spanish one */
    if (file_exists("/sdcard/doom_no_sound") || file_exists("/sdcard/doom_no_sound.txt") ||
        file_exists("/sdcard/doom_sin_sonido") || file_exists("/sdcard/doom_sin_sonido.txt")) {
        argv[argc++] = "-nosound";
        __android_log_print(LOG_I, TAG, "Sound disabled (/sdcard/doom_no_sound)");
    }
    key_nextweapon = ']';
    key_prevweapon = '[';
    doomgeneric_Create(argc, argv);
    key_nextweapon = ']';
    key_prevweapon = '[';
    for (;;) doomgeneric_Tick();
    return NULL;
}

/* ---------------------------------------------------------------- activity callbacks */
static void on_window_created(ANativeActivity* a, ANativeWindow* w) {
    lock(&win_lock); ANativeWindow_acquire(w); window = w; unlock(&win_lock);
}
static void on_window_destroyed(ANativeActivity* a, ANativeWindow* w) {
    lock(&win_lock); if (window) ANativeWindow_release(window); window = NULL; unlock(&win_lock);
}
static void on_input_created(ANativeActivity* a, AInputQueue* q) {
    AInputQueue_attachLooper(q, ALooper_forThread(), 1, input_cb, q);
}
static void on_input_destroyed(ANativeActivity* a, AInputQueue* q) { AInputQueue_detachLooper(q); }
void STORIO_AudioPause(int p);
static void on_pause(ANativeActivity* a) { paused = 1; STORIO_AudioPause(1); }
static void on_resume(ANativeActivity* a) { paused = 0; STORIO_AudioPause(0); }
static void on_destroy(ANativeActivity* a) { exit(0); }

static int started = 0;
__attribute__((visibility("default"))) void ANativeActivity_onCreate(ANativeActivity* a, void* saved, size_t saved_size) {
    g_activity = a;
    a->callbacks->onNativeWindowCreated = on_window_created;
    a->callbacks->onNativeWindowDestroyed = on_window_destroyed;
    a->callbacks->onInputQueueCreated = on_input_created;
    a->callbacks->onInputQueueDestroyed = on_input_destroyed;
    a->callbacks->onPause = on_pause;
    a->callbacks->onResume = on_resume;
    a->callbacks->onDestroy = on_destroy;
    if (started) return;
    started = 1;
    snprintf(g_datadir, sizeof g_datadir, "%s", a->internalDataPath ? a->internalDataPath : "/data/data/org.storio.doom/files");
    mkdir(g_datadir, 0770);
    default_bindings();
    load_bindings();
    start_raw_input();
    { pthread_t ti; pthread_create(&ti, NULL, icon_server, NULL); }
    pthread_t t;
    pthread_create(&t, NULL, game_thread, NULL);
}
