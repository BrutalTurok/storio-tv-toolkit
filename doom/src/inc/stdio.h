#ifndef _STDIO_H
#define _STDIO_H
#include "_bionic.h"
#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define BUFSIZ 1024
#define FILENAME_MAX 1024
/* stdout/stderr redirected to the Android log (see dg_android.c) */
#define stdout ((FILE*)1)
#define stderr ((FILE*)2)
#define stdin  ((FILE*)3)
FILE *fopen(const char*, const char*);
int fclose(FILE*);
size_t fread(void*, size_t, size_t, FILE*);
int fseek(FILE*, long, int);
long ftell(FILE*);
int remove(const char*);
int rename(const char*, const char*);
int sscanf(const char*, const char*, ...);
int snprintf(char*, size_t, const char*, ...);
int vsnprintf(char*, size_t, const char*, va_list);
int sprintf(char*, const char*, ...);
int vsprintf(char*, const char*, va_list);
int feof(FILE*);
int fgetc(FILE*);
char *fgets(char*, int, FILE*);
int fscanf(FILE*, const char*, ...);
int dg_fprintf(FILE*, const char*, ...);
int dg_vfprintf(FILE*, const char*, va_list);
int dg_printf(const char*, ...);
int dg_vprintf(const char*, va_list);
int dg_puts(const char*);
int dg_putchar(int);
int dg_fputs(const char*, FILE*);
int dg_fputc(int, FILE*);
int dg_fflush(FILE*);
size_t dg_fwrite(const void*, size_t, size_t, FILE*);
#define fprintf dg_fprintf
#define vfprintf dg_vfprintf
#define printf dg_printf
#define vprintf dg_vprintf
#define puts dg_puts
#define putchar dg_putchar
#define fputs dg_fputs
#define fputc dg_fputc
#define putc dg_fputc
#define fflush dg_fflush
#define fwrite dg_fwrite
#endif
