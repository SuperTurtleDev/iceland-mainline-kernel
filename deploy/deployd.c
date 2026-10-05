// deployd -- streaming deploy server for the iceland initrd.
//
// Listens on the NCM gadget network; a single host client streams:
//
//     [u64 size][data ...][u32 crc32]   first blob  = SPARSE rootfs image
//     [u64 size][data ...][u32 crc32]   next blobs  = provision .debs
//     ...                                (saved as /debs/blob-N.deb)
//     [u64 0]                            terminator, no more files
//
// The rootfs blob may be huge: it is decoded and written to the target
// block device WHILE IT ARRIVES -- a fixed 256 KiB window, never more.
// DONTCARE chunks seek forward (ext4 does not look at those regions),
// FILL chunks expand a 4-byte pattern through the same window.  Every
// blob is crc32-verified over the bytes as transmitted and acknowledged
// with a u32 status (0 = OK) so the client can retry/abort deterministically.
//
// Build: aarch64-linux-gnu-gcc -static -O2 -o deployd deployd.c
// SPDX-License-Identifier: MIT

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define WINDOW (256 * 1024)
#define SPARSE_MAGIC 0xED26FF3AUL
#define CH_RAW 0xCAC1
#define CH_FILL 0xCAC2
#define CH_DONTCARE 0xCAC3
#define CH_CRC 0xCAC4

#define OK 0
#define E_CRC 1
#define E_IO 2
#define E_PROTO 3

// ---- crc32 (IEEE, zlib-compatible), table computed on the fly --------
static uint32_t crc_table[256];

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? 0xEDB88320UL ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
}

static uint32_t crc_update(uint32_t crc, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    crc = ~crc;
    while (len--)
        crc = crc_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

// ---- stream helpers ---------------------------------------------------
static uint8_t win[WINDOW];

static int readn(int fd, void *buf, size_t n)   // 0=ok, -1=eof, -2=err
{
    uint8_t *p = buf;
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r == 0) return -1;
        if (r < 0) { if (errno == EINTR) continue; return -2; }
        p += r; n -= r;
    }
    return 0;
}

static int send_u32(int fd, uint32_t v)
{
    uint32_t be = htonl(v);
    ssize_t r = send(fd, &be, 4, 0);
    return r == 4 ? 0 : -1;
}

// consume n bytes from the socket, running them through crc and fn
// fn(offset_delta, data, len) for every WINDOW-sized piece
typedef int (*sink_fn)(uint64_t off, const void *buf, size_t len, void *ctx);

static int pump(int sock, uint64_t n, uint32_t *crc, sink_fn fn, void *ctx)
{
    uint64_t off = 0;
    while (n) {
        size_t want = n > WINDOW ? WINDOW : (size_t)n;
        int r = readn(sock, win, want);
        if (r) return E_IO;
        *crc = crc_update(*crc, win, want);
        if (fn && fn(off, win, want, ctx)) return E_IO;
        off += want; n -= want;
    }
    return OK;
}

// ---- sinks ------------------------------------------------------------
typedef struct { int fd; uint64_t off; } devctx_t;

static int dev_sink2(uint64_t doff, const void *buf, size_t len, void *ctx)
{
    devctx_t *d = ctx;
    const uint8_t *p = buf;
    uint64_t off = d->off + doff;
    while (len) {
        ssize_t w = pwrite(d->fd, p, len, (off_t)off);
        if (w <= 0) { perror("deployd: pwrite"); return -1; }
        p += w; len -= w; off += w;
    }
    return 0;
}

static int file_sink(uint64_t off, const void *buf, size_t len, void *ctx)
{
    int fd = *(int *)ctx;
    const uint8_t *p = buf;
    while (len) {
        ssize_t w = write(fd, p, len);
        if (w <= 0) { perror("deployd: write deb"); return -1; }
        p += w; len -= w;
    }
    return 0;
}

static int null_sink(uint64_t off, const void *buf, size_t len, void *ctx)
{
    (void)off; (void)buf; (void)len; (void)ctx;
    return 0;
}

// ---- sparse streaming decoder -----------------------------------------
// Consumes exactly imgsize bytes from the socket, decoding into out_fd.
typedef struct { int sock; int out; uint32_t blk; uint64_t cur; } spx_t;

// read exactly n bytes into win (chunk payloads are <= WINDOW here
// because the SENDER was asked to emit small chunks; larger RAW chunks
// are handled by pumping directly)
static int spx_raw(spx_t *s, uint64_t bytes, uint32_t *crc)
{
    devctx_t d = { s->out, s->cur };
    int rc = pump(s->sock, bytes, crc, dev_sink2, &d);
    s->cur += bytes;
    return rc;
}

static int spx_fill(spx_t *s, uint64_t bytes, uint32_t pattern)
{
    // stream-consume `bytes` of... FILL has only a 4-byte payload on the
    // wire; we consume the 4 bytes and EXPAND locally (no network bytes
    // correspond to the expansion).
    uint8_t pat[4];
    pat[0] = pattern & 0xFF; pat[1] = (pattern >> 8) & 0xFF;
    pat[2] = (pattern >> 16) & 0xFF; pat[3] = (pattern >> 24) & 0xFF;
    for (uint64_t done = 0; done < bytes; ) {
        size_t n = bytes - done > WINDOW ? WINDOW : (size_t)(bytes - done);
        for (size_t i = 0; i < n; i++) win[i] = pat[i & 3];
        devctx_t d = { s->out, s->cur + done };
        if (dev_sink2(0, win, n, &d)) return E_IO;
        done += n;
    }
    s->cur += bytes;
    return OK;
}

static int spx_u32(spx_t *s, uint32_t *v, uint32_t *crc)
{
    uint8_t b[4];
    if (readn(s->sock, b, 4)) return E_IO;
    *crc = crc_update(*crc, b, 4);
    *v = b[0] | (b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    return OK;
}

static int spx_u16(spx_t *s, uint16_t *v, uint32_t *crc)
{
    uint8_t b[2];
    if (readn(s->sock, b, 2)) return E_IO;
    *crc = crc_update(*crc, b, 2);
    *v = b[0] | (b[1] << 8);
    return OK;
}

static int recv_sparse_rootfs(int sock, int out_fd, uint64_t imgsize)
{
    uint32_t crc = 0;
    spx_t s = { sock, out_fd, 0, 0 };
    uint32_t magic; uint16_t major, minor, fhs, chs; uint32_t blk, tblk, nch;

    if (spx_u32(&s, &magic, &crc)) return E_PROTO;
    if (magic != SPARSE_MAGIC) { fprintf(stderr, "deployd: bad sparse magic %#x\n", magic); return E_PROTO; }
    if (spx_u16(&s, &major, &crc) || spx_u16(&s, &minor, &crc) ||
        spx_u16(&s, &fhs, &crc) || spx_u16(&s, &chs, &crc) ||
        spx_u32(&s, &blk, &crc) || spx_u32(&s, &tblk, &crc) ||
        spx_u32(&s, &nch, &crc))
        return E_IO;
    if (fhs < 28 || chs < 12 || !blk || !nch) { fprintf(stderr, "deployd: bad sparse header\n"); return E_PROTO; }
    fprintf(stderr, "deployd: sparse v%d.%d blk=%u total=%" PRIu32 " chunks=%" PRIu32 "\n",
            major, minor, blk, tblk, nch);

    // fields parsed above total 24 bytes (8 fields); the file header is
    // fhs bytes (28 = ... + trailing crc u32): skip whatever remains
    uint32_t pad = fhs - 24;
    while (pad--) {
        uint8_t b;
        if (readn(sock, &b, 1)) return E_IO;
        crc = crc_update(crc, &b, 1);
    }

    for (uint32_t ci = 0; ci < nch; ci++) {
        uint16_t ct; uint16_t res; uint32_t csz, tsz;
        if (spx_u16(&s, &ct, &crc) || spx_u16(&s, &res, &crc) ||
            spx_u32(&s, &csz, &crc) || spx_u32(&s, &tsz, &crc))
            return E_IO;
        (void)res;
        uint64_t out_bytes = (uint64_t)csz * blk;
        if (ct == CH_RAW) {
            uint64_t payload = tsz - chs;
            int rc = spx_raw(&s, payload, &crc);
            if (rc) return rc;
        } else if (ct == CH_FILL) {
            uint32_t pat;
            if (spx_u32(&s, &pat, &crc)) return E_IO;
            if (spx_fill(&s, out_bytes, pat)) return E_IO;
        } else if (ct == CH_DONTCARE) {
            if (lseek(out_fd, (off_t)out_bytes, SEEK_CUR) == (off_t)-1) {
                perror("deployd: lseek dontcare"); return E_IO;
            }
            s.cur += out_bytes;
        } else if (ct == CH_CRC) {
            uint32_t chunkcrc;
            if (spx_u32(&s, &chunkcrc, &crc)) return E_IO;
        } else {
            fprintf(stderr, "deployd: unknown chunk type %#x\n", ct);
            return E_PROTO;
        }
    }

    if (fsync(out_fd)) { perror("deployd: fsync rootfs"); return E_IO; }

    // trailing crc32 of the transmitted sparse bytes
    uint32_t want;
    {
        uint8_t b[4];
        if (readn(sock, b, 4)) return E_IO;
        want = b[0] | (b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    }
    (void)imgsize;
    if (want != crc) {
        fprintf(stderr, "deployd: rootfs crc mismatch (got %08" PRIx32 " want %08" PRIx32 ")\n", crc, want);
        return E_CRC;
    }
    fprintf(stderr, "deployd: rootfs written+fsync, crc %08" PRIx32 " OK\n", crc);
    return OK;
}

static int recv_file_blob(int sock, const char *path, uint64_t size)
{
    uint32_t crc = 0;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("deployd: open deb"); return E_IO; }
    int ctx = fd;
    int rc = pump(sock, size, &crc, file_sink, &ctx);
    fsync(fd);
    close(fd);
    if (rc) return rc;
    uint32_t want;
    uint8_t b[4];
    if (readn(sock, b, 4)) return E_IO;
    want = b[0] | (b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    if (want != crc) {
        fprintf(stderr, "deployd: %s crc mismatch\n", path);
        return E_CRC;
    }
    fprintf(stderr, "deployd: %s %" PRIu64 " bytes crc %08" PRIx32 " OK\n", path, size, crc);
    return OK;
}

static int recv_u64(int sock, uint64_t *v)
{
    uint8_t b[8];
    if (readn(sock, b, 8)) return -1;
    uint64_t r = 0;
    for (int i = 7; i >= 0; i--) r = (r << 8) | b[i];  // little endian
    *v = r;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: deployd <port> <rootfs-dev> <debs-dir>\n");
        return 2;
    }
    int port = atoi(argv[1]);
    const char *dev = argv[2];
    const char *debdir = argv[3];

    crc_init();

    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) { perror("socket"); return 2; }
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons(port);
    if (bind(ls, (struct sockaddr *)&a, sizeof(a)) || listen(ls, 1)) {
        perror("bind/listen"); return 2;
    }
    fprintf(stderr, "deployd: listening on %d, rootfs=%s debs=%s\n", port, dev, debdir);

    int c = accept(ls, NULL, NULL);
    if (c < 0) { perror("accept"); return 2; }
    fprintf(stderr, "deployd: client connected\n");
    close(ls);

    mkdir(debdir, 0755);
    int blob = 0;
    int exitcode = 0;

    for (;;) {
        uint64_t size;
        if (recv_u64(c, &size)) { fprintf(stderr, "deployd: header read failed\n"); exitcode = E_IO; break; }
        if (size == 0) {
            send_u32(c, OK);
            fprintf(stderr, "deployd: terminator received, transfer complete\n");
            break;
        }
        int rc;
        if (blob == 0) {
            int out = open(dev, O_WRONLY);
            if (out < 0) { perror("deployd: open rootfs dev"); rc = E_IO; }
            else {
                rc = recv_sparse_rootfs(c, out, size);
                close(out);
            }
        } else {
            char path[256];
            snprintf(path, sizeof(path), "%s/blob-%d.deb", debdir, blob - 1);
            rc = recv_file_blob(c, path, size);
        }
        send_u32(c, rc);
        if (rc) { fprintf(stderr, "deployd: blob %d failed (%d), aborting\n", blob, rc); exitcode = rc; break; }
        blob++;
    }

    close(c);
    fprintf(stderr, "deployd: exit %d\n", exitcode);
    return exitcode;
}
