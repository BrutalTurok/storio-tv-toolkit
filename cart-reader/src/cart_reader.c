/*
 * cart_reader: raw reader for the NAND flash of an InnoTV / InnoTab MAX / Storio MAX cartridge,
 * run on the console itself (as root), including the spare area (OOB) of every page.
 * Freestanding program (no libc): ARM Linux system calls only.
 *
 * Writes to the output directory:
 *   cart_raw.bin   -> page (2048) + spare area (128) per page: the MAME layout
 *   cart_data.bin  -> data pages only (what the file system sees)
 *   report.txt     -> chip info, bad blocks, errors
 */
typedef unsigned int u32; typedef unsigned char u8; typedef unsigned long long u64; typedef long long s64;

/* ---------------- system calls (ARM EABI) */
static long sc(long n, long a, long b, long c, long d) {
    register long r0 __asm__("r0") = a; register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c; register long r3 __asm__("r3") = d;
    register long r7 __asm__("r7") = n;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r7) : "memory");
    return r0;
}
static long sc5(long n, long a, long b, long c, long d, long e) {
    register long r0 __asm__("r0") = a; register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c; register long r3 __asm__("r3") = d;
    register long r4 __asm__("r4") = e; register long r7 __asm__("r7") = n;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r7) : "memory");
    return r0;
}
#define SYS_exit_group 248
#define SYS_read 3
#define SYS_write 4
#define SYS_open 5
#define SYS_close 6
#define SYS_mknod 14
#define SYS_lseek 19
#define SYS_mkdir 39
#define SYS_ioctl 54
#define SYS_llseek 140
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0100
#define O_TRUNC 01000
#define O_LARGEFILE 0400000

void* memset(void* d, int c, unsigned n) { u8* p = d; while (n--) *p++ = (u8)c; return d; }
void* memcpy(void* d, const void* s, unsigned n) { u8* p = d; const u8* q = s; while (n--) *p++ = *q++; return d; }
static int slen(const char* s) { int n = 0; while (s[n]) n++; return n; }
static int sncmp(const char* a, const char* b, int n) { for (int i = 0; i < n; i++) { if (a[i] != b[i]) return 1; if (!a[i]) return 0; } return 0; }
static void pjoin(char* d, const char* dir, const char* name) { int l = slen(dir); memcpy(d, dir, l); memcpy(d + l, name, slen(name) + 1); }
static const char* sstr(const char* h, const char* n) { int l = slen(n); for (; *h; h++) if (!sncmp(h, n, l)) return h; return 0; }

/* ---------------- text output (screen + report) */
static int rep_fd = -1;
static void out(const char* s) { int n = slen(s); sc(SYS_write, 1, (long)s, n, 0); if (rep_fd >= 0) sc(SYS_write, rep_fd, (long)s, n, 0); }
static char* utoa(u64 v, char* b, int base) {
    char t[24]; int i = 0;
    do { int d = (int)(v % base); t[i++] = d < 10 ? '0' + d : 'a' + d - 10; v /= base; } while (v);
    char* p = b; while (i) *p++ = t[--i]; *p = 0; return b;
}
static void outn(u64 v) { char b[24]; out(utoa(v, b, 10)); }
static void outx(u64 v) { char b[24]; out("0x"); out(utoa(v, b, 16)); }

/* ---------------- MTD */
struct mtd_info_user { u8 type; u32 flags; u32 size; u32 erasesize; u32 writesize; u32 oobsize; u64 padding; };
struct mtd_oob_buf { u32 start; u32 length; u8* ptr; };
#define MEMGETINFO      0x80204d01
#define MEMREADOOB      0xc00c4d04
#define MEMGETBADBLOCK  0x40084d0b
#define MTDFILEMODE     0x4d13

static int s64_seek(int fd, u64 off) {
    s64 res; return (int)sc5(SYS_llseek, fd, (long)(off >> 32), (long)(off & 0xffffffffu), (long)&res, 0 /* SEEK_SET */) == 0 ? 0 : -1;
}
static int readall(int fd, u8* b, int n) { int got = 0; while (got < n) { long r = sc(SYS_read, fd, (long)(b + got), n - got, 0); if (r <= 0) return r < 0 ? (int)r : got; got += r; } return got; }

/* write buffers */
#define WB (256 * 1024)
static u8 wbuf_raw[WB], wbuf_dat[WB]; static int wraw = 0, wdat = 0;
static int fd_raw = -1, fd_dat = -1;
static int wflush(int fd, u8* b, int* n) { if (*n) { if (sc(SYS_write, fd, (long)b, *n, 0) != *n) return -1; *n = 0; } return 0; }
static int wput(int fd, u8* b, int* n, const u8* s, int len) {
    while (len) { int c = WB - *n; if (c > len) c = len; memcpy(b + *n, s, c); *n += c; s += c; len -= c; if (*n == WB && wflush(fd, b, n)) return -1; }
    return 0;
}

static char procmtd[4096];
#ifdef TEST
static long xioctl(int fd, u32 cmd, long arg) {
    if (cmd == MEMGETINFO) { struct mtd_info_user* m = (void*)arg; m->type = 4; m->size = 4u << 20; m->erasesize = 131072; m->writesize = 2048; m->oobsize = 64; return 0; }
    if (cmd == MEMREADOOB) { struct mtd_oob_buf* b = (void*)arg; if (b->length > 64) return -22; for (u32 i = 0; i < b->length; i++) b->ptr[i] = (u8)(b->start / 2048 + i); return 0; }
    if (cmd == MEMGETBADBLOCK) { return (*(s64*)arg == 3 * 131072) ? 1 : 0; }
    return -25;
}
#define IOCTL(fd, c, a) xioctl(fd, c, (long)(a))
#define PROCMTD "/tmp/cart_reader_test/fake_procmtd"
#else
#define IOCTL(fd, c, a) sc(SYS_ioctl, fd, c, (long)(a), 0)
#define PROCMTD "/proc/mtd"
#endif
static u8 page[16384], oob[1024];

static int run(int argc, char** argv) {
    const char* dir = argc > 1 ? argv[1] : "/sdcard/cart_dump";
    int spare = 128;  /* TC58NVG1S3HTA00: 2048 + 128 bytes per page */
    char path[256], dev[64];

    sc(SYS_mkdir, (long)dir, 0777, 0, 0);
    pjoin(path, dir, "/report.txt");
    rep_fd = (int)sc(SYS_open, (long)path, O_WRONLY | O_CREAT | O_TRUNC, 0644, 0);
    if (rep_fd < 0) { out("Cannot create "); out(path); out(" (errno "); outn(-rep_fd); out(")\n"); return 2; }
    out("== InnoTV / InnoTab MAX cartridge reader ==\n");

    /* 1. find the cartridge in /proc/mtd */
    int fd = (int)sc(SYS_open, (long)PROCMTD, O_RDONLY, 0, 0);
    int n = fd >= 0 ? readall(fd, (u8*)procmtd, sizeof procmtd - 1) : 0; if (fd >= 0) sc(SYS_close, fd, 0, 0, 0);
    if (n < 0) n = 0; procmtd[n] = 0;
    out("/proc/mtd:\n"); out(procmtd);
    int idx = -1;
    for (const char* l = procmtd; *l; ) {
        if (l[0] == 'm' && l[1] == 't' && l[2] == 'd' && l[3] >= '0' && l[3] <= '9') {
            int i = 0; const char* p = l + 3; while (*p >= '0' && *p <= '9') i = i * 10 + (*p++ - '0');
            const char* e = l; while (*e && *e != '\n') e++;
            char line[200]; int ll = (int)(e - l) < 199 ? (int)(e - l) : 199; memcpy(line, l, ll); line[ll] = 0;
            if (idx < 0 && (sstr(line, "Inno") || sstr(line, "VFAT") || sstr(line, "Cart"))) idx = i;
        }
        while (*l && *l != '\n') l++; if (*l) l++;
    }
    if (idx < 0) { out("\nCartridge not found in /proc/mtd. Is it inserted? (try removing and reinserting it)\n"); return 3; }
    out("\nCartridge at mtd"); outn(idx); out("\n");

    /* 2. open the character device (or create it) */
    const char* cands[3]; char c1[32], c2[32], c3[48], nb[8];
    utoa(idx, nb, 10);
    memcpy(c1, "/dev/mtd/mtd", 13); memcpy(c1 + 12, nb, slen(nb) + 1);
#ifdef TEST
    memcpy(c1, "/tmp/cart_reader_test/fake_mtd", 31);
#endif
    memcpy(c2, "/dev/mtd", 9); memcpy(c2 + 8, nb, slen(nb) + 1);
    memcpy(c3, "/data/local/tmp/mtd_reader", 27);
    cands[0] = c1; cands[1] = c2; cands[2] = c3;
    fd = -1;
    for (int i = 0; i < 3 && fd < 0; i++) {
        if (i == 2) { sc(SYS_mknod, (long)c3, 0020000 | 0600, (90 << 8) | (idx * 2), 0); }  /* S_IFCHR, major 90 */
        fd = (int)sc(SYS_open, (long)cands[i], O_RDONLY | O_LARGEFILE, 0, 0);
        if (fd >= 0) { memcpy(dev, cands[i], slen(cands[i]) + 1); }
    }
    if (fd < 0) { out("Cannot open the cartridge device (errno "); outn(-fd); out("). Is ADB running as root?\n"); return 4; }
    out("Device: "); out(dev); out("\n");

    struct mtd_info_user mi; memset(&mi, 0, sizeof mi);
    long r = IOCTL(fd, MEMGETINFO, &mi);
    if (r < 0) { out("MEMGETINFO failed (errno "); outn(-r); out(")\n"); return 5; }
    out("Type "); outn(mi.type); out(", size "); outn(mi.size); out(" bytes, block "); outn(mi.erasesize);
    out(", page "); outn(mi.writesize); out(", spare (OOB) "); outn(mi.oobsize); out("\n");
    if (mi.writesize == 0 || mi.writesize > sizeof page || mi.size == 0) { out("Invalid chip info.\n"); return 5; }
    IOCTL(fd, MTDFILEMODE, 3);   /* raw mode, if the driver supports it */

    /* how much of the spare area does the driver give us? */
    int ooblen = 0;
    /* Only ask for what the driver says it has: asking for more would make it mix in the spare
       area of the following pages. */
    { int want = (int)mi.oobsize < spare ? (int)mi.oobsize : spare;
      int tries[1] = { want };
      for (int i = 0; i < 1 && !ooblen; i++) {
          if (tries[i] <= 0 || tries[i] > (int)sizeof oob) continue;
          struct mtd_oob_buf ob = { 0, (u32)tries[i], oob };
          memset(oob, 0xff, sizeof oob);
          long rr = IOCTL(fd, MEMREADOOB, &ob);
          if (rr >= 0) ooblen = tries[i];
      } }
    if (ooblen == 0) out("WARNING: the driver does not allow reading the spare area; it is padded with 0xFF.\n");
    else if (ooblen < spare) { out("WARNING: the driver only provides "); outn(ooblen); out(" spare bytes per page; the rest is padded with 0xFF.\n"); }
    else { out("Spare area: "); outn(ooblen); out(" bytes per page.\n"); }

    pjoin(path, dir, "/cart_raw.bin");
    fd_raw = (int)sc(SYS_open, (long)path, O_WRONLY | O_CREAT | O_TRUNC | O_LARGEFILE, 0644, 0);
    pjoin(path, dir, "/cart_data.bin");
    fd_dat = (int)sc(SYS_open, (long)path, O_WRONLY | O_CREAT | O_TRUNC | O_LARGEFILE, 0644, 0);
    if (fd_raw < 0 || fd_dat < 0) { out("Cannot create the output files.\n"); return 6; }

    u32 pages = mi.size / mi.writesize, ppb = mi.erasesize / mi.writesize;
    u32 bad = 0, readerr = 0, ooberr = 0, eccfix = 0;
    out("Reading "); outn(pages); out(" pages...\n");
    for (u32 p = 0; p < pages; p++) {
        u64 off = (u64)p * mi.writesize;
        if (ppb && p % ppb == 0) {
            s64 o = (s64)off;
            long b = IOCTL(fd, MEMGETBADBLOCK, &o);
            if (b > 0) { bad++; out("  bad block "); outn(p / ppb); out(" ("); outx(off); out(")\n"); }
        }
        memset(page, 0xff, mi.writesize);
        if (s64_seek(fd, off) == 0) {
            long rr = readall(fd, page, mi.writesize);
            if (rr != (long)mi.writesize) {
                if (rr == -74 || rr == -117) eccfix++;           /* EBADMSG / EUCLEAN: the data is still copied */
                else { readerr++; if (readerr <= 20) { out("  error reading page "); outn(p); out(" (errno "); outn(rr < 0 ? -rr : 0); out(")\n"); } }
            }
        } else readerr++;
        memset(oob, 0xff, spare);
        if (ooblen) {
            struct mtd_oob_buf ob = { (u32)off, (u32)ooblen, oob };
            if (IOCTL(fd, MEMREADOOB, &ob) < 0) ooberr++;
        }
        if (wput(fd_raw, wbuf_raw, &wraw, page, mi.writesize) || wput(fd_raw, wbuf_raw, &wraw, oob, spare) ||
            wput(fd_dat, wbuf_dat, &wdat, page, mi.writesize)) { out("Write error (storage full?)\n"); return 7; }
        if ((p + 1) % 8192 == 0 || p + 1 == pages) { sc(SYS_write, 1, (long)"  ", 2, 0); char b[24]; utoa((u64)(p + 1) * 100 / pages, b, 10); sc(SYS_write, 1, (long)b, slen(b), 0); sc(SYS_write, 1, (long)"%\n", 2, 0); }
    }
    if (wflush(fd_raw, wbuf_raw, &wraw) || wflush(fd_dat, wbuf_dat, &wdat)) { out("Write error (storage full?)\n"); return 7; }
    sc(SYS_close, fd_raw, 0, 0, 0); sc(SYS_close, fd_dat, 0, 0, 0); sc(SYS_close, fd, 0, 0, 0);

    out("\nSUMMARY\n");
    out("  pages: "); outn(pages); out(" of "); outn(mi.writesize); out(" + "); outn(spare); out(" bytes\n");
    out("  cart_raw.bin: "); outn((u64)pages * (mi.writesize + spare)); out(" bytes\n");
    out("  cart_data.bin: "); outn((u64)pages * mi.writesize); out(" bytes\n");
    out("  bad blocks: "); outn(bad); out("\n");
    out("  pages with read errors: "); outn(readerr); out("\n");
    out("  pages with ECC warnings: "); outn(eccfix); out("\n");
    out("  spare area read: "); outn(ooblen); out(" bytes/page, failures: "); outn(ooberr); out("\n");
    out(readerr ? "RESULT: ERRORS\n" : "RESULT: OK\n");
    return readerr ? 1 : 0;
}

int main_c(long* sp) { int argc = (int)sp[0]; char** argv = (char**)(sp + 1); int r = run(argc, argv); if (rep_fd >= 0) sc(SYS_close, rep_fd, 0, 0, 0); return r; }

__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile("mov r0, sp\n bic sp, sp, #7\n bl main_c\n mov r7, #248\n svc 0\n");
}
void* memmove(void* d, const void* s, unsigned n) { u8* p = d; const u8* q = s; if (p < q) while (n--) *p++ = *q++; else { p += n; q += n; while (n--) *--p = *--q; } return d; }
