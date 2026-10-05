// deployclient -- stream a deploy.blob to deployd on the device.
//
//     deployclient <host> <port> <deploy.blob>
//
// Parses the blob framing ([u64 size][data][u32 crc] ... [u64 0]) so it
// can await and verify deployd's per-blob u32 ack (network order), then
// sends each frame through a fixed 256 KiB window -- the blob may be far
// larger than memory.  Abort on any non-zero ack.
//
// SPDX-License-Identifier: MIT

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define WINDOW (256 * 1024)

static int readn(int fd, void *buf, size_t n)
{
    unsigned char *p = buf;
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r == 0) { fprintf(stderr, "deployclient: server closed\n"); return -1; }
        if (r < 0) { if (errno == EINTR) continue; perror("recv"); return -1; }
        p += r; n -= r;
    }
    return 0;
}

static int sendall(int fd, const void *buf, size_t n)
{
    const unsigned char *p = buf;
    while (n) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) { if (errno == EINTR) continue; perror("send"); return -1; }
        p += w; n -= w;
    }
    return 0;
}

static int recv_ack(int fd, uint32_t *v)
{
    unsigned char b[4];
    if (readn(fd, b, 4)) return -1;
    *v = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <host> <port> <deploy.blob>\n", argv[0]);
        return 2;
    }
    const char *host = argv[1];
    int port = atoi(argv[2]);
    FILE *bf = fopen(argv[3], "rb");
    if (!bf) { perror(argv[3]); return 2; }

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 2; }
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) {
        fprintf(stderr, "bad host: %s\n", host);
        return 2;
    }
    // deployd starts right after the gadget in the initrd; the first
    // connect may race it -- retry for up to ~60 s
    int ctry;
    for (ctry = 0; ; ctry++) {
        if (connect(s, (struct sockaddr *)&a, sizeof(a)) == 0) break;
        if (errno != ECONNREFUSED && errno != ETIMEDOUT) { perror("connect"); return 2; }
        if (ctry >= 30) { fprintf(stderr, "deployclient: connect giving up\n"); return 2; }
        fprintf(stderr, "deployclient: connect retry %d\n", ctry + 1);
        close(s);
        sleep(2);
        s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) { perror("socket"); return 2; }
    }
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    fprintf(stderr, "deployclient: connected %s:%d\n", host, port);

    static unsigned char win[WINDOW];
    unsigned char hdr[8];
    unsigned blob = 0;

    for (;;) {
        if (fread(hdr, 1, 8, bf) != 8) { fprintf(stderr, "deployclient: blob truncated\n"); return 1; }
        uint64_t size = 0;
        for (int i = 7; i >= 0; i--) size = (size << 8) | hdr[i];
        if (size == 0 && blob > 0) {
            // terminator (frame 0 with size 0 is the "no rootfs" marker
            // and was already forwarded when it was read)
            if (sendall(s, hdr, 8)) return 1;
            uint32_t ack;
            if (recv_ack(s, &ack)) return 1;
            fprintf(stderr, "deployclient: terminator ack %u\n", ack);
            close(s);
            fprintf(stderr, "deployclient: transfer complete\n");
            fclose(bf);
            return ack ? 1 : 0;
        }

        fprintf(stderr, "deployclient: blob %u (%" PRIu64 " bytes)%s\n",
                blob, size,
                blob == 0 ? (size ? " [sparse rootfs]" : " [no rootfs: packages only]") : "");
        if (sendall(s, hdr, 8)) return 1;
        if (size == 0) {
            uint32_t ack;
            if (recv_ack(s, &ack)) return 1;
            if (ack) { fprintf(stderr, "deployclient: no-rootfs marker rejected (%u)\n", ack); return 1; }
            fprintf(stderr, "deployclient: blob 0 ack OK (package-only)\n");
            blob++;
            continue;
        }

        uint64_t left = size;
        while (left) {
            size_t want = left > WINDOW ? WINDOW : (size_t)left;
            if (fread(win, 1, want, bf) != want) { fprintf(stderr, "deployclient: blob data truncated\n"); return 1; }
            if (sendall(s, win, want)) return 1;
            left -= want;
        }

        unsigned char crcb[4];
        if (fread(crcb, 1, 4, bf) != 4) { fprintf(stderr, "deployclient: crc truncated\n"); return 1; }
        if (sendall(s, crcb, 4)) return 1;

        uint32_t ack;
        if (recv_ack(s, &ack)) return 1;
        if (ack != 0) {
            fprintf(stderr, "deployclient: blob %u rejected, status %u\n", blob, ack);
            return 1;
        }
        fprintf(stderr, "deployclient: blob %u ack OK\n", blob);
        blob++;
    }
}
