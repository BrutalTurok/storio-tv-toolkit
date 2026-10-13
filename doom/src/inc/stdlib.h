#ifndef _STDLIB_H
#define _STDLIB_H
#include "_bionic.h"
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff
void *malloc(size_t); void *calloc(size_t, size_t); void *realloc(void*, size_t); void free(void*);
void exit(int) __attribute__((noreturn)); void abort(void) __attribute__((noreturn));
int atexit(void (*)(void));
char *getenv(const char*); int setenv(const char*, const char*, int);
int atoi(const char*); long atol(const char*); double strtod(const char*, char**); static inline double atof(const char* s){ return strtod(s, 0); }
long strtol(const char*, char**, int); unsigned long strtoul(const char*, char**, int);

static inline int abs(int x) { return x < 0 ? -x : x; }
static inline long labs(long x) { return x < 0 ? -x : x; }
void qsort(void*, size_t, size_t, int (*)(const void*, const void*));
int rand(void); void srand(unsigned);
int system(const char*);
#endif
