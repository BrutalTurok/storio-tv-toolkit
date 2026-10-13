#ifndef _TIME_H
#define _TIME_H
#include "_bionic.h"
struct timespec { time_t tv_sec; long tv_nsec; };
#define CLOCK_MONOTONIC 1
int clock_gettime(clockid_t, struct timespec*);
time_t time(time_t*);
#endif
