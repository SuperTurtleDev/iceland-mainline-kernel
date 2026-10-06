// unsparse -- decode an Android sparse image (v1.0) onto a device or file.
//
//   unsparse <sparse-image> <output>
//
// Same on-disk format deployd streams for the rootfs: 28-byte file header,
// then RAW / FILL / DONTCARE / CRC chunks.  Used by the netdeploy initrd to
// install the bootloader FAT32 esp.img (produced sparse by the bootloader
// build, ~90 KB for a 1 GiB filesystem) onto the esp partition.
//
// SPDX-License-Identifier: MIT

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SPARSE_MAGIC 0xED26FF3AUL

#define CH_RAW      0xCAC1
#define CH_FILL     0xCAC2
#define CH_DONTCARE 0xCAC3
#define CH_CRC      0xCAC4

static void die(const char *msg) { fprintf(stderr, "unsparse: %s (%s)\n", msg, strerror(errno)); exit(1); }

#define WIN (256 * 1024)
static uint8_t win[WIN];

static void wr(int out, const void *buf, size_t n)
{
    if (write(out, buf, n) != (ssize_t)n) die("write");
}
static void rd(int in, void *buf, size_t n)
{
    if (read(in, buf, n) != (ssize_t)n) die("read");
}
static uint32_t rd_u32(int in) { uint8_t b[4]; rd(in, b, 4); return b[0] | b[1]<<8 | (uint32_t)b[2]<<16 | (uint32_t)b[3]<<24; }
static uint16_t rd_u16(int in) { uint8_t b[2]; rd(in, b, 2); return b[0] | b[1]<<8; }

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <sparse-image> <output>\n", argv[0]);
        return 1;
    }

    int in = open(argv[1], O_RDONLY);
    if (in < 0) die("open input");
    int out = open(argv[2], O_WRONLY);
    if (out < 0) die("open output");

    if (rd_u32(in) != SPARSE_MAGIC) { fprintf(stderr, "unsparse: bad sparse magic\n"); return 1; }
    uint16_t major = rd_u16(in), minor = rd_u16(in);
    uint16_t fhs = rd_u16(in), chs = rd_u16(in);
    uint32_t blk = rd_u32(in);
    uint32_t tblk = rd_u32(in);
    uint32_t nch = rd_u32(in);
    if (fhs < 28 || chs < 12 || !blk || !nch) { fprintf(stderr, "unsparse: bad sparse header\n"); return 1; }
    if (lseek(in, fhs, SEEK_SET) == (off_t)-1) die("lseek header");
    fprintf(stderr, "unsparse: v%d.%d blk=%u total=%u chunks=%u\n", major, minor, blk, tblk, nch);

    uint64_t wrote = 0;
    for (uint32_t ci = 0; ci < nch; ci++) {
        uint16_t ct = rd_u16(in);
        (void)rd_u16(in);                       /* reserved */
        uint32_t csz = rd_u32(in);              /* size in blocks */
        uint32_t tsz = rd_u32(in);              /* total chunk bytes incl. header */
        uint64_t out_bytes = (uint64_t)csz * blk;

        if (ct == CH_RAW) {
            uint64_t payload = tsz - chs;
            while (payload) {
                size_t n = payload > WIN ? WIN : (size_t)payload;
                rd(in, win, n);
                wr(out, win, n);
                payload -= n;
                wrote += n;
            }
        } else if (ct == CH_FILL) {
            uint8_t pat[4];
            rd(in, pat, 4);
            for (uint64_t done = 0; done < out_bytes; ) {
                size_t n = out_bytes - done > WIN ? WIN : (size_t)(out_bytes - done);
                for (size_t i = 0; i < n; i++) win[i] = pat[i & 3];
                wr(out, win, n);
                done += n;
            }
            wrote += out_bytes;
        } else if (ct == CH_DONTCARE) {
            if (lseek(out, (off_t)out_bytes, SEEK_CUR) == (off_t)-1) die("lseek dontcare");
        } else if (ct == CH_CRC) {
            (void)rd_u32(in);
        } else {
            fprintf(stderr, "unsparse: unknown chunk type %#x\n", ct);
            return 1;
        }
    }

    if (fsync(out)) die("fsync");
    fprintf(stderr, "unsparse: done, %llu bytes written\n", (unsigned long long)wrote);
    close(in);
    close(out);
    return 0;
}
