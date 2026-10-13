#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include "doomgeneric.h"
void STORIO_MixAudio(int16_t* out, int frames);
static uint64_t now_us(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000000ull+t.tv_nsec/1000;}
static uint64_t t0;
static FILE* wav; static int g_rate;
static void* athr(void* a){ int16_t b[512]; uint64_t blocks=0;
  for(;;){ uint64_t due=t0+blocks*256ull*1000000/g_rate; uint64_t n=now_us(); if(n<due) usleep(due-n);
    STORIO_MixAudio(b,256); fwrite(b,4,256,wav); blocks++; } return 0;}
int STORIO_AudioStart(int rate){ g_rate=rate; wav=fopen("/tmp/host/out.raw","wb"); pthread_t t; t0=now_us(); pthread_create(&t,0,athr,0); return 1;}
void STORIO_AudioPause(int p){} void STORIO_AudioStop(void){}
void DG_Init(){} void DG_DrawFrame(){} void DG_SleepMs(uint32_t ms){usleep(ms*1000);}
uint32_t DG_GetTicksMs(){return (now_us()-t0)/1000;}
int DG_GetKey(int*p,unsigned char*k){return 0;} void DG_SetWindowTitle(const char*t){}
int main(int argc,char**argv){ doomgeneric_Create(argc,argv); uint64_t s=now_us(); while(now_us()-s < 8000000) doomgeneric_Tick(); fflush(wav); return 0;}
