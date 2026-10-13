/*
 * DOOM sound for Storio TV: sound effect mixer (8-bit DMX) -> 16-bit stereo PCM output.
 * The actual output (OpenSL ES) is in sl_out.c; this file only mixes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "doomtype.h"
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"

int storio_rate = 44100;   /* /sdcard/doom_audio.txt: "rate=22050" (or "frecuencia=") */
static int music_gain = 4;  /* /sdcard/doom_audio.txt: "music=N" (or "musica="; 0 = no music, 1 = original OPL volume) */
static int sfx_gain = 2;    /* /sdcard/doom_audio.txt: "sfx=N" (or "efectos="; in halves: 2 = normal) */
#define MIX_RATE storio_rate
#define NCHAN 16

/* variables that m_config.c expects when FEATURE_SOUND is defined */
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;
void I_InitTimidityConfig(void) {}

typedef struct {
    const uint8_t* data;  /* unsigned 8-bit PCM */
    uint32_t len;         /* samples */
    uint32_t pos;         /* 16.16 */
    uint32_t step;        /* 16.16 */
    int lvol, rvol;       /* 0..255 */
    volatile int active;
    long long t_start;    /* to measure the latency of the first sound effects */
} chan_t;
#include <time.h>
static long long now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000LL + t.tv_nsec / 1000; }
static int lat_logged = 0;

static chan_t chans[NCHAN];
static volatile int mix_lock = 0;
static boolean sfx_prefix;
static boolean sound_ok = false;

static void lk(void) { while (__sync_lock_test_and_set(&mix_lock, 1)) { } }
static void ulk(void) { __sync_lock_release(&mix_lock); }

/* Already decoded data, per lump */
typedef struct { const uint8_t* data; uint32_t len; uint32_t rate; } sfxdata_t;
static sfxdata_t* cache = NULL;
static int cache_n = 0;

static int load_sfx(int lump, sfxdata_t* out) {
    if (lump < 0) return 0;
    if (cache == NULL) {
        cache_n = numlumps;
        cache = calloc(cache_n, sizeof(sfxdata_t));
        if (!cache) return 0;
    }
    if (lump >= cache_n) return 0;
    if (cache[lump].data) { *out = cache[lump]; return 1; }
    int lumplen = W_LumpLength(lump);
    const uint8_t* d = W_CacheLumpNum(lump, PU_STATIC);
    if (lumplen < 8 || d[0] != 3 || d[1] != 0) return 0;
    uint32_t rate = d[2] | (d[3] << 8);
    uint32_t length = d[4] | (d[5] << 8) | (d[6] << 16) | ((uint32_t)d[7] << 24);
    if (length > (uint32_t)lumplen - 8 || length <= 48) return 0;
    /* DMX skips the first and last 16 bytes */
    cache[lump].data = d + 8 + 16;
    cache[lump].len = length - 32;
    cache[lump].rate = rate ? rate : 11025;
    *out = cache[lump];
    return 1;
}

/* Mixes 'frames' 16-bit stereo samples into 'out' (called by the audio thread). */
void STORIO_MixMusic(int16_t* buf, int frames);   /* opl_storio.c */
void STORIO_MixAudio(int16_t* out, int frames) {
    static int32_t acc[2048 * 2];
    static int16_t mus[2048 * 2];
    static int32_t hp_x[2], hp_y[2];   /* high-pass filter: removes the DC offset of the OPL output */
    if (frames > 2048) frames = 2048;
    if (music_gain > 0) {
        STORIO_MixMusic(mus, frames);
        for (int i = 0; i < frames * 2; i++) {
            int k = i & 1;
            int32_t x = mus[i];
            int32_t y = x - hp_x[k] + (int32_t)(((int64_t)hp_y[k] * 32604) >> 15);   /* R = 0.995 */
            hp_x[k] = x; hp_y[k] = y;
            acc[i] = y * music_gain;
        }
    } else memset(acc, 0, frames * 2 * sizeof(int32_t));
    lk();
    for (int c = 0; c < NCHAN; c++) {
        chan_t* ch = &chans[c];
        if (!ch->active) continue;
        if (ch->t_start) {
            if (lat_logged < 5) { lat_logged++; printf("Sound effect: latency until mixed %lld us\n", now_us() - ch->t_start); }
            ch->t_start = 0;
        }
        int32_t* a = acc;
        for (int i = 0; i < frames; i++) {
            uint32_t idx = ch->pos >> 16;
            if (idx >= ch->len) { ch->active = 0; break; }
            int s = ((int)ch->data[idx] - 128) << 8;
            a[0] += (s * ch->lvol * sfx_gain) >> 9;
            a[1] += (s * ch->rvol * sfx_gain) >> 9;
            a += 2;
            ch->pos += ch->step;
        }
    }
    ulk();
    for (int i = 0; i < frames * 2; i++) {
        int32_t v = acc[i];
        /* soft limiter above 24000 so loud music does not "crackle" */
        if (v > 24000) { v = 24000 + (v - 24000) / 4; if (v > 32767) v = 32767; }
        else if (v < -24000) { v = -24000 + (v + 24000) / 4; if (v < -32768) v = -32768; }
        out[i] = (int16_t)v;
    }
}

static void set_params(chan_t* ch, int vol, int sep) {
    if (vol < 0) vol = 0; if (vol > 127) vol = 127;
    if (sep < 0) sep = 0; if (sep > 254) sep = 254;
    int l = ((254 - sep) * vol) / 127;
    int r = (sep * vol) / 127;
    ch->lvol = l > 255 ? 255 : l;
    ch->rvol = r > 255 ? 255 : r;
}

int STORIO_AudioStart(int rate);   /* sl_out.c */
void STORIO_AudioStop(void);

static boolean S_Init(boolean use_sfx_prefix) {
    sfx_prefix = use_sfx_prefix;
    FILE* f = fopen("/sdcard/doom_audio.txt", "r");
    if (f) {
        char line[128];
        while (fgets(line, sizeof line, f)) {
            int v;
            /* English and Spanish keys are both accepted; a bare number is the sample rate */
            if (sscanf(line, "rate=%d", &v) == 1 || sscanf(line, "frecuencia=%d", &v) == 1 || sscanf(line, "%d", &v) == 1) { if (v >= 8000 && v <= 48000) storio_rate = v; }
            else if (sscanf(line, "music=%d", &v) == 1 || sscanf(line, "musica=%d", &v) == 1) { if (v >= 0 && v <= 16) music_gain = v; }
            else if (sscanf(line, "sfx=%d", &v) == 1 || sscanf(line, "efectos=%d", &v) == 1) { if (v >= 0 && v <= 8) sfx_gain = v; }
        }
        fclose(f);
    }
    memset(chans, 0, sizeof chans);
    sound_ok = STORIO_AudioStart(MIX_RATE) != 0;
    printf("Sound: %s at %d Hz (music x%d, sfx x%d/2)\n", sound_ok ? "OpenSL ES active" : "not available", storio_rate, music_gain, sfx_gain);
    return sound_ok;
}
static void S_Shutdown(void) { if (sound_ok) STORIO_AudioStop(); sound_ok = false; }

static int S_GetSfxLumpNum(sfxinfo_t* sfx) {
    char name[16];
    if (sfx->link) sfx = sfx->link;
    if (sfx_prefix) snprintf(name, sizeof name, "ds%s", sfx->name);
    else snprintf(name, sizeof name, "%s", sfx->name);
    return W_CheckNumForName(name);
}
static void S_Update(void) {}
static void S_UpdateSoundParams(int c, int vol, int sep) {
    if (c < 0 || c >= NCHAN) return;
    lk(); set_params(&chans[c], vol, sep); ulk();
}
static int S_StartSound(sfxinfo_t* sfx, int c, int vol, int sep) {
    if (c < 0 || c >= NCHAN) return -1;
    sfxdata_t sd;
    if (!load_sfx(sfx->lumpnum, &sd)) return -1;
    lk();
    chan_t* ch = &chans[c];
    ch->data = sd.data; ch->len = sd.len; ch->pos = 0;
    ch->step = (uint32_t)(((uint64_t)sd.rate << 16) / MIX_RATE);
    set_params(ch, vol, sep);
    ch->t_start = now_us();
    ch->active = 1;
    ulk();
    return c;
}
static void S_StopSound(int c) { if (c >= 0 && c < NCHAN) { lk(); chans[c].active = 0; ulk(); } }
static boolean S_SoundIsPlaying(int c) { return (c >= 0 && c < NCHAN) ? chans[c].active : false; }
static void S_CacheSounds(sfxinfo_t* s, int n) {
    for (int i = 0; i < n; i++) { sfxdata_t sd; if (s[i].lumpnum >= 0) load_sfx(s[i].lumpnum, &sd); }
}

static snddevice_t sound_devices[] = { SNDDEVICE_SB, SNDDEVICE_PAS, SNDDEVICE_GUS, SNDDEVICE_WAVEBLASTER, SNDDEVICE_SOUNDCANVAS, SNDDEVICE_AWE32 };
sound_module_t DG_sound_module = {
    sound_devices, sizeof sound_devices / sizeof sound_devices[0],
    S_Init, S_Shutdown, S_GetSfxLumpNum, S_Update, S_UpdateSoundParams,
    S_StartSound, S_StopSound, S_SoundIsPlaying, S_CacheSounds,
};
