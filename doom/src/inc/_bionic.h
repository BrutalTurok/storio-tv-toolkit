#ifndef _BIONIC_SHIM_H
#define _BIONIC_SHIM_H
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
typedef long off_t; typedef long ssize_t; typedef long time_t; typedef int pid_t;
typedef unsigned int mode_t; typedef long suseconds_t; typedef int clockid_t;
typedef struct __sFILE FILE;
#endif
