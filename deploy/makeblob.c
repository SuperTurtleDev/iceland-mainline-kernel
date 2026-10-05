// makeblob -- pack the deploy transfer blob.
//
//     makeblob [-o deploy.blob] <sparse-rootfs.img> [<deb> ...]
//
// Layout (little-endian), consumed directly by deployd on the device:
//     [u64 size][data ...][u32 crc32]   first blob  = SPARSE rootfs image
//     [u64 size][data ...][u32 crc32]   next blobs  = provision debs
//     [u64 0]                            terminator
//
// CRC32 (IEEE/zlib) is computed over each blob's bytes as stored.  The
// output is a plain byte stream: deployclient sends it verbatim.
//
// SPDX-License-Identifier: MIT

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WINDOW (256 * 1024)

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

static uint32_t crc_file(FILE *f, uint64_t *out_size)
{
    static unsigned char buf[WINDOW];
    uint32_t crc = 0;
    rewind(f);
    for (;;) {
        size_t r = fread(buf, 1, sizeof(buf), f);
        if (r == 0) break;
        const unsigned char *p = buf;
        crc = ~crc;
        while (r--) crc = crc_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
        crc = ~crc;
    }
    rewind(f);
    fseeko(f, 0, SEEK_END);
    *out_size = (uint64_t)ftello(f);
    rewind(f);
    return crc;
}

static void put_u64(FILE *o, uint64_t v)
{
    unsigned char b[8];
    for (int i = 0; i < 8; i++) b[i] = (unsigned char)(v >> (8 * i));
    fwrite(b, 1, 8, o);
}

static void put_u32(FILE *o, uint32_t v)
{
    unsigned char b[4];
    for (int i = 0; i < 4; i++) b[i] = (unsigned char)(v >> (8 * i));
    fwrite(b, 1, 4, o);
}

int main(int argc, char **argv)
{
    const char *out = "deploy.blob";
    int first = 1;
    int no_rootfs = 0;

    if (argc >= 3 && strcmp(argv[1], "-o") == 0) {
        out = argv[2];
        first = 3;
    }
    if (first < argc && strcmp(argv[first], "--no-rootfs") == 0) {
        // emit a size-0 first frame: deployd skips the rootfs write and
        // the stream becomes a packages-only update
        no_rootfs = 1;
        first++;
    }
    if (argc - first < 1) {
        fprintf(stderr, "usage: %s [-o deploy.blob] [--no-rootfs] <sparse-rootfs.img> [<deb> ...]\n", argv[0]);
        return 2;
    }

    crc_init();
    FILE *o = fopen(out, "wb");
    if (!o) { perror(out); return 1; }

    static unsigned char buf[WINDOW];

    if (no_rootfs) {
        put_u64(o, 0);
        fprintf(stderr, "makeblob: [0] <no rootfs -- packages-only update>\n");
    }

    for (int i = first; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { perror(argv[i]); return 1; }
        uint64_t size;
        uint32_t crc = crc_file(f, &size);
        fprintf(stderr, "makeblob: [%d] %s (%" PRIu64 " bytes, crc %08" PRIx32 ")\n",
                i - first, argv[i], size, crc);
        put_u64(o, size);
        uint32_t running = 0;
        uint64_t sent = 0;
        for (;;) {
            size_t r = fread(buf, 1, sizeof(buf), f);
            if (r == 0) break;
            fwrite(buf, 1, r, o);
            const unsigned char *p = buf;
            running = ~running;
            while (r--) running = crc_table[(running ^ *p++) & 0xFF] ^ (running >> 8);
            running = ~running;
            sent += (uint64_t)(p - buf);
        }
        if (sent != size || running != crc) {
            fprintf(stderr, "makeblob: internal mismatch on %s\n", argv[i]);
            return 1;
        }
        put_u32(o, crc);
        fclose(f);
    }

    put_u64(o, 0);  // terminator
    fclose(o);
    fprintf(stderr, "makeblob: wrote %s\n", out);
    return 0;
}
