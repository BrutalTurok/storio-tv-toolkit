#ifndef _ERRNO_H
#define _ERRNO_H
int *__errno(void);
#define errno (*__errno())
#define ENOENT 2
#define EEXIST 17
#define EISDIR 21
#endif
