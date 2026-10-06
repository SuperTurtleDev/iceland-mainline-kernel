// mkgpt -- repartition a Qualcomm-style LUN0 for mainline Linux.
//
// Deletes the stock super/userdata partitions (matched by GPT name), then
// appends kernel/bootcfg/dtb/initrd/esp/rootfs in the freed space, rootfs
// running to the last usable LBA.  Everything is computed from the actual
// disk size, so any storage capacity works -- no hard-coded table.
//
// Rewrites the protective MBR, primary and secondary GPT headers/entries
// with fresh CRCs, then asks the kernel to re-read the table.
//
//   usage: mkgpt <disk-or-image> [name=+sizeMiB ...]   (size "0" = rest)
//   ex:    mkgpt /dev/sda kernel=+128 bootcfg=+4 dtb=+8 initrd=+256 esp=+64 rootfs=0
//
// Refuses to run if any target name already exists (idempotence guard);
// callers gate on the esp partition being absent.
//
// SPDX-License-Identifier: MIT

#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#define NENTRIES 128
#define ESIZE    128
#define NAMELEN  72

/* Linux filesystem data + EFI system partition type GUIDs */
static const uint8_t guid_lin_fs[16] = {0xA2,0xA0,0xD0,0xEB,0xE5,0xB9,0x33,0x44,0x87,0xC0,0x68,0xB6,0xB7,0x26,0x99,0xC7};
static const uint8_t guid_efi_sp[16] = {0x28,0x73,0x2A,0xC1,0x1F,0xF8,0xD2,0x11,0xBA,0x4B,0x00,0xA0,0xC9,0x3E,0xC9,0x3B};

/* stock Android partitions that make way for the linux set */
static const char *del_names[] = { "super", "userdata", NULL };

struct partspec { const char *name; unsigned long mib; };
static struct partspec defaults[] = {
    { "kernel",  128 },
    { "bootcfg",   4 },
    { "dtb",       8 },
    { "initrd",  256 },
    { "esp",    1024 },   /* 1 GiB: the bootloader build's FAT32 esp.img */
    { "rootfs",    0 },   /* 0 = to the last usable LBA */
    { NULL, 0 }
};

static void die(const char *msg) { fprintf(stderr, "mkgpt: %s (%s)\n", msg, strerror(errno)); exit(1); }

static void pread_all(int fd, void *buf, size_t n, uint64_t off)
{
    if (pread(fd, buf, n, (off_t)off) != (ssize_t)n) die("short read");
}
static void pwrite_all(int fd, const void *buf, size_t n, uint64_t off)
{
    if (pwrite(fd, buf, n, (off_t)off) != (ssize_t)n) die("short write");
}

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
static uint32_t crc32_buf(const uint8_t *p, size_t n)
{
    uint32_t c = 0xFFFFFFFF;
    while (n--)
        c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return ~c;
}

/* deterministic partition GUID: FNV-1a over name + first LBA */
static void mk_guid(uint8_t *g, const char *name, uint64_t first_lba)
{
    uint64_t h = 0xCBF29CE484222325ULL;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        h ^= *p;
        h *= 0x100000001B3ULL;
    }
    h ^= first_lba * 0x9E3779B97F4A7C15ULL;
    for (int i = 0; i < 16; i++) {
        g[i] = (uint8_t)(h >> ((i % 8) * 8));
        if (i == 7) h ^= 0xA5A5A5A5A5A5A5A5ULL, h *= 0x100000001B3ULL;
    }
    g[6] = (g[6] & 0x0F) | 0x50;   /* pretend RFC 4122 version 5 */
    g[8] = (g[8] & 0x3F) | 0x80;   /* variant */
}

static void put_u32le(uint8_t *p, uint32_t v) { p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static void put_u64le(uint8_t *p, uint64_t v) { for (int i=0;i<8;i++) p[i] = (uint8_t)(v >> (8*i)); }
static uint32_t get_u32le(const uint8_t *p) { return p[0] | p[1]<<8 | p[2]<<16 | (uint32_t)p[3]<<24; }
static uint64_t get_u64le(const uint8_t *p) { uint64_t v=0; for (int i=7;i>=0;i--) v = v<<8 | p[i]; return v; }

static void name_to_utf16(uint8_t *dst, const char *name)
{
    memset(dst, 0, NAMELEN);
    for (int i = 0; name[i] && i < NAMELEN/2 - 1; i++) {
        dst[2*i]   = (uint8_t)name[i];
        dst[2*i+1] = 0;
    }
}
static int name_from_utf16(const uint8_t *src, char *out, size_t outn)
{
    size_t j = 0;
    for (size_t i = 0; i < NAMELEN && j + 1 < outn; i += 2) {
        uint16_t c = src[i] | (src[i+1] << 8);
        if (!c) break;
        out[j++] = (c < 128) ? (char)c : '?';
    }
    out[j] = 0;
    return (int)j;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <disk-or-image> [name=+sizeMiB ...] (0 = rest)\n", argv[0]);
        return 1;
    }

    /* optional spec override: name=+MiB pairs, in order */
    for (int i = 2; i < argc; i++) {
        char *eq = strchr(argv[i], '=');
        if (!eq) { fprintf(stderr, "mkgpt: bad spec %s\n", argv[i]); return 1; }
        *eq = 0;
        struct partspec *hit = NULL;
        for (struct partspec *p = defaults; p->name; p++)
            if (!strcmp(p->name, argv[i])) hit = p;
        if (!hit) { fprintf(stderr, "mkgpt: unknown part %s\n", argv[i]); return 1; }
        hit->mib = strtoul(eq + 1, NULL, 0);
    }

    int fd = open(argv[1], O_RDWR);
    if (fd < 0) die("open");

    unsigned ssz = 512;
    uint64_t bytes = 0;
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISBLK(st.st_mode)) {
        if (ioctl(fd, BLKSSZGET, &ssz) < 0) ssz = 512;
        if (ioctl(fd, BLKGETSIZE64, &bytes) < 0) die("BLKGETSIZE64");
    } else {
        bytes = (uint64_t)st.st_size;   /* regular file (tests): 512B sectors */
    }
    uint64_t lbas = bytes / ssz;
    if (lbas < 4096) { fprintf(stderr, "mkgpt: disk too small (%llu LBAs)\n", (unsigned long long)lbas); return 1; }

    crc_init();

    /* --- read existing GPT --------------------------------------------------- */
    uint8_t hdr[ESIZE];
    pread_all(fd, hdr, ESIZE, 1 * ssz);
    if (memcmp(hdr, "EFI PART", 8) != 0) { fprintf(stderr, "mkgpt: no GPT header\n"); return 1; }
    if (get_u32le(hdr + 80) != NENTRIES || get_u32le(hdr + 84) != ESIZE) {
        fprintf(stderr, "mkgpt: unusual entry layout, refusing\n");
        return 1;
    }
    static uint8_t ent[NENTRIES * ESIZE];
    uint64_t ent_lba = get_u64le(hdr + 72);
    pread_all(fd, ent, sizeof(ent), ent_lba * ssz);

    /* --- delete stock partitions by name ------------------------------------- */
    int deleted = 0;
    char nm[40];
    for (int i = 0; i < NENTRIES; i++) {
        uint8_t *e = ent + i * ESIZE;
        if (!get_u64le(e + 32)) continue;   /* no first_lba: unused */
        name_from_utf16(e + 56, nm, sizeof(nm));
        for (const char **d = del_names; *d; d++) {
            if (!strcmp(nm, *d)) {
                printf("mkgpt: delete %s (part %d, %llu-%llu)\n", nm, i + 1,
                       (unsigned long long)get_u64le(e + 32),
                       (unsigned long long)get_u64le(e + 40));
                memset(e, 0, ESIZE);
                deleted++;
            }
        }
    }

    /* --- idempotence: refuse if any target name exists ----------------------- */
    for (int i = 0; i < NENTRIES; i++) {
        uint8_t *e = ent + i * ESIZE;
        if (!get_u64le(e + 32)) continue;
        name_from_utf16(e + 56, nm, sizeof(nm));
        for (struct partspec *p = defaults; p->name; p++)
            if (!strcmp(nm, p->name)) {
                fprintf(stderr, "mkgpt: partition %s already present, refusing\n", nm);
                return 1;
            }
    }

    /* --- geometry -------------------------------------------------------------- */
    uint64_t ent_secs = (NENTRIES * ESIZE + ssz - 1) / ssz;
    uint64_t first_usable = ent_lba + ent_secs;
    uint64_t last_usable  = lbas - 1 - ent_secs - 1;   /* alt header + alt entries */
    uint64_t align = (1024 * 1024) / ssz;

    uint64_t cursor = first_usable;
    for (int i = 0; i < NENTRIES; i++) {
        uint8_t *e = ent + i * ESIZE;
        uint64_t last = get_u64le(e + 40);
        if (last && last + 1 > cursor) cursor = last + 1;
    }
    cursor = (cursor + align - 1) / align * align;
    if (cursor <= first_usable) cursor = first_usable;

    /* --- create the linux set --------------------------------------------------- */
    for (struct partspec *p = defaults; p->name; p++) {
        int slot = -1;
        for (int i = 0; i < NENTRIES && slot < 0; i++)
            if (!get_u64le(ent + i * ESIZE + 32)) slot = i;
        if (slot < 0) { fprintf(stderr, "mkgpt: GPT full\n"); return 1; }

        uint64_t nsec = p->mib ? (uint64_t)p->mib * 1024 * 1024 / ssz
                               : (last_usable - cursor + 1);
        if (cursor + nsec - 1 > last_usable) {
            fprintf(stderr, "mkgpt: no room for %s (cursor %llu, last usable %llu)\n",
                    p->name, (unsigned long long)cursor, (unsigned long long)last_usable);
            return 1;
        }
        uint8_t *e = ent + slot * ESIZE;
        memcpy(e, !strcmp(p->name, "esp") ? guid_efi_sp : guid_lin_fs, 16);
        mk_guid(e + 16, p->name, cursor);
        put_u64le(e + 32, cursor);
        put_u64le(e + 40, cursor + nsec - 1);
        put_u64le(e + 48, 0);   /* attributes */
        name_to_utf16(e + 56, p->name);
        printf("mkgpt: create %s (part %d, %llu-%llu, %llu MiB)\n", p->name, slot + 1,
               (unsigned long long)cursor, (unsigned long long)(cursor + nsec - 1),
               (unsigned long long)(nsec * ssz >> 20));
        cursor += nsec;
        cursor = (cursor + align - 1) / align * align;
    }

    /* --- protective MBR ---------------------------------------------------------- */
    uint8_t mbr[512];
    memset(mbr, 0, sizeof(mbr));
    mbr[446] = 0; mbr[446+4] = 0xEE;
    put_u32le(mbr + 446 + 8, 1);
    put_u32le(mbr + 446 + 12, (lbas - 1) > 0xFFFFFFFF ? 0xFFFFFFFF : (uint32_t)(lbas - 1));
    mbr[510] = 0x55; mbr[511] = 0xAA;
    pwrite_all(fd, mbr, sizeof(mbr), 0);

    /* --- GPT headers (primary LBA1, secondary last LBA) ----------------------------- */
    uint32_t ent_crc = crc32_buf(ent, sizeof(ent));

    for (int which = 0; which < 2; which++) {
        uint64_t my = which ? lbas - 1 : 1;
        uint64_t alt = which ? 1 : lbas - 1;
        uint64_t ent_at = which ? lbas - 1 - ent_secs : ent_lba;
        uint8_t h[ESIZE];
        memset(h, 0, sizeof(h));
        memcpy(h, "EFI PART", 8);
        put_u32le(h + 8, 0x00010000);              /* rev 1.0 */
        put_u32le(h + 12, 92);                     /* header size */
        put_u32le(h + 16, 0);                      /* crc, filled below */
        put_u64le(h + 24, my);
        put_u64le(h + 32, alt);
        put_u64le(h + 40, first_usable);
        put_u64le(h + 48, last_usable);
        memcpy(h + 56, hdr + 56, 16);              /* keep the disk GUID */
        put_u64le(h + 72, ent_at);
        put_u32le(h + 80, NENTRIES);
        put_u32le(h + 84, ESIZE);
        put_u32le(h + 88, ent_crc);
        put_u64le(h + 96, ent_at + ent_secs);

        put_u32le(h + 16, crc32_buf(h, 92));
        pwrite_all(fd, ent, sizeof(ent), ent_at * ssz);   /* entries first */
        pwrite_all(fd, h, ESIZE, my * ssz);
    }

    if (ioctl(fd, BLKRRPART) < 0 && errno != EINVAL)
        fprintf(stderr, "mkgpt: BLKRRPART failed (%s) -- re-read manually\n", strerror(errno));

    printf("mkgpt: done (%d deleted, disk %llu LBAs x %uB, rootfs ends at %llu)\n",
           deleted, (unsigned long long)lbas, ssz, (unsigned long long)last_usable);
    close(fd);
    return 0;
}
