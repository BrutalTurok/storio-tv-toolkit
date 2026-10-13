/* Audio output via OpenSL ES (Android 2.3+). Minimal declarations from OpenSLES.h. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef uint32_t SLuint32; typedef SLuint32 SLresult; typedef SLuint32 SLboolean;
typedef const struct SLInterfaceID_* SLInterfaceID;
typedef const struct SLObjectItf_* const* SLObjectItf;
typedef const struct SLEngineItf_* const* SLEngineItf;
typedef const struct SLPlayItf_* const* SLPlayItf;
typedef const struct SLAndroidSimpleBufferQueueItf_* const* SLAndroidSimpleBufferQueueItf;
typedef void (*slBQCallback)(SLAndroidSimpleBufferQueueItf caller, void* ctx);

struct SLObjectItf_ {
    SLresult (*Realize)(SLObjectItf self, SLboolean async);
    SLresult (*Resume)(SLObjectItf self, SLboolean async);
    SLresult (*GetState)(SLObjectItf self, SLuint32* pState);
    SLresult (*GetInterface)(SLObjectItf self, const SLInterfaceID iid, void* pInterface);
    SLresult (*RegisterCallback)(SLObjectItf self, void* cb, void* ctx);
    void (*AbortAsyncOperation)(SLObjectItf self);
    void (*Destroy)(SLObjectItf self);
    SLresult (*SetPriority)(SLObjectItf self, int32_t prio, SLboolean pre);
    SLresult (*GetPriority)(SLObjectItf self, int32_t* prio, SLboolean* pre);
    SLresult (*SetLossOfControlInterfaces)(SLObjectItf self, int16_t n, SLInterfaceID* ids, SLboolean en);
};
typedef struct { void* pLocator; void* pFormat; } SLDataSource;
typedef struct { void* pLocator; void* pFormat; } SLDataSink;
struct SLEngineItf_ {
    SLresult (*CreateLEDDevice)(void);
    SLresult (*CreateVibraDevice)(void);
    SLresult (*CreateAudioPlayer)(SLEngineItf self, SLObjectItf* pPlayer, SLDataSource* src, SLDataSink* snk,
                                  SLuint32 n, const SLInterfaceID* ids, const SLboolean* req);
    SLresult (*CreateAudioRecorder)(void);
    SLresult (*CreateMidiPlayer)(void);
    SLresult (*CreateListener)(void);
    SLresult (*Create3DGroup)(void);
    SLresult (*CreateOutputMix)(SLEngineItf self, SLObjectItf* pMix, SLuint32 n, const SLInterfaceID* ids, const SLboolean* req);
};
struct SLPlayItf_ { SLresult (*SetPlayState)(SLPlayItf self, SLuint32 state); };
struct SLAndroidSimpleBufferQueueItf_ {
    SLresult (*Enqueue)(SLAndroidSimpleBufferQueueItf self, const void* buf, SLuint32 size);
    SLresult (*Clear)(SLAndroidSimpleBufferQueueItf self);
    SLresult (*GetState)(SLAndroidSimpleBufferQueueItf self, void* state);
    SLresult (*RegisterCallback)(SLAndroidSimpleBufferQueueItf self, slBQCallback cb, void* ctx);
};
typedef struct { SLuint32 locatorType; SLuint32 numBuffers; } SLDataLocator_BQ;
typedef struct { SLuint32 formatType, numChannels, samplesPerSec, bitsPerSample, containerSize, channelMask, endianness; } SLDataFormat_PCM;
typedef struct { SLuint32 locatorType; SLObjectItf outputMix; } SLDataLocator_OutputMix;

extern const SLInterfaceID SL_IID_ENGINE;
extern const SLInterfaceID SL_IID_PLAY;
extern const SLInterfaceID SL_IID_ANDROIDSIMPLEBUFFERQUEUE;
SLresult slCreateEngine(SLObjectItf* pEngine, SLuint32 numOptions, const void* opts,
                        SLuint32 numInterfaces, const SLInterfaceID* ids, const SLboolean* req);

void STORIO_MixAudio(int16_t* out, int frames);
int __android_log_print(int prio, const char* tag, const char* fmt, ...);

#define FRAMES 256
#define NBUF 2
static int16_t bufs[NBUF][FRAMES * 2];
static int cur = 0;
static SLObjectItf engineObj, mixObj, playerObj;
static SLPlayItf play;
static SLAndroidSimpleBufferQueueItf bq;

#include <time.h>
static int g_rate = 44100;
static unsigned long cb_count = 0, mix_us_total = 0, mix_us_max = 0;
static uint64_t t_start_us = 0, t_last_log = 0;
static uint64_t now_us(void) { struct timespec ts; clock_gettime(1, &ts); return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000; }
static void bq_cb(SLAndroidSimpleBufferQueueItf caller, void* ctx) {
    uint64_t t0 = now_us();
    if (!t_start_us) { t_start_us = t0; t_last_log = t0; }
    STORIO_MixAudio(bufs[cur], FRAMES);
    uint64_t dt = now_us() - t0;
    cb_count++; mix_us_total += dt; if (dt > mix_us_max) mix_us_max = dt;
    if (t0 - t_last_log > 10000000) {
        double audio_s = (double)cb_count * FRAMES / g_rate, real_s = (t0 - t_start_us) / 1e6;
        __android_log_print(4, "DOOM", "Audio: %lu blocks, mix avg %lu us (max %lu us, limit %d us), audio %.1f s / real %.1f s",
            cb_count, mix_us_total / cb_count, mix_us_max, FRAMES * 1000000 / g_rate, audio_s, real_s);
        t_last_log = t0; mix_us_max = 0;
    }
    (*bq)->Enqueue(bq, bufs[cur], sizeof bufs[cur]);
    cur = (cur + 1) % NBUF;
}

#define CHK(x, what) do { SLresult r_ = (x); if (r_ != 0) { __android_log_print(6, "DOOM", "OpenSL: %s failed (%u)", what, (unsigned)r_); return 0; } } while (0)

int STORIO_AudioStart(int rate) {
    SLEngineItf eng;
    g_rate = rate;
    CHK(slCreateEngine(&engineObj, 0, NULL, 0, NULL, NULL), "slCreateEngine");
    CHK((*engineObj)->Realize(engineObj, 0), "engine Realize");
    CHK((*engineObj)->GetInterface(engineObj, SL_IID_ENGINE, &eng), "GetInterface ENGINE");
    CHK((*eng)->CreateOutputMix(eng, &mixObj, 0, NULL, NULL), "CreateOutputMix");
    CHK((*mixObj)->Realize(mixObj, 0), "mix Realize");
    SLDataLocator_BQ loc = { 0x800007BD, NBUF };
    SLDataFormat_PCM fmt = { 2, 2, (SLuint32)rate * 1000, 16, 16, 3, 2 };
    SLDataSource src = { &loc, &fmt };
    SLDataLocator_OutputMix outloc = { 4, mixObj };
    SLDataSink snk = { &outloc, NULL };
    const SLInterfaceID ids[1] = { SL_IID_ANDROIDSIMPLEBUFFERQUEUE };
    const SLboolean req[1] = { 1 };
    CHK((*eng)->CreateAudioPlayer(eng, &playerObj, &src, &snk, 1, ids, req), "CreateAudioPlayer");
    CHK((*playerObj)->Realize(playerObj, 0), "player Realize");
    CHK((*playerObj)->GetInterface(playerObj, SL_IID_PLAY, &play), "GetInterface PLAY");
    CHK((*playerObj)->GetInterface(playerObj, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &bq), "GetInterface BQ");
    CHK((*bq)->RegisterCallback(bq, bq_cb, NULL), "RegisterCallback");
    CHK((*play)->SetPlayState(play, 3 /* PLAYING */), "SetPlayState");
    for (int i = 0; i < NBUF; i++) bq_cb(bq, NULL);
    __android_log_print(4, "DOOM", "OpenSL ES: %d Hz stereo", rate);
    return 1;
}
void STORIO_AudioPause(int p) { if (play) (*play)->SetPlayState(play, p ? 2 : 3); }
void STORIO_AudioStop(void) {
    if (playerObj) (*playerObj)->Destroy(playerObj);
    if (mixObj) (*mixObj)->Destroy(mixObj);
    if (engineObj) (*engineObj)->Destroy(engineObj);
    playerObj = mixObj = engineObj = NULL; play = NULL; bq = NULL;
}
