#!/usr/bin/env python3
"""deploy-send -- host client for the iceland streaming deploy server.

Streams to deployd (run from the deploy initrd over the NCM gadget):

    [u64 size][data ...][u32 crc32]   blob 0 = SPARSE rootfs image
    [u64 size][data ...][u32 crc32]   blobs 1.. = provision .debs (any order)
    [u64 0]                            terminator

Each blob is acknowledged with a u32 status (0 = OK); any non-zero ack
aborts the run.  CRC32 is computed over the bytes as transmitted (zlib).

usage: deploy-send.py <host> <port> <sparse-rootfs> [<deb> ...]
"""
import socket
import struct
import sys
import zlib

WINDOW = 256 * 1024


def send_blob(sock, path):
    crc = 0
    size = 0
    with open(path, "rb") as f:
        # first pass for size (files are local, cheap)
        while True:
            d = f.read(WINDOW)
            if not d:
                break
            size += len(d)
            crc = zlib.crc32(d, crc)
    sock.sendall(struct.pack("<Q", size))
    crc = 0
    sent = 0
    with open(path, "rb") as f:
        while True:
            d = f.read(WINDOW)
            if not d:
                break
            sock.sendall(d)
            crc = zlib.crc32(d, crc)
            sent += len(d)
            if sent % (16 * 1024 * 1024) < WINDOW:
                print(f"  {sent/1048576:.0f}/{size/1048576:.0f} MiB", end="\r", flush=True)
    print(f"  {size} bytes sent".ljust(40))
    assert sent == size
    sock.sendall(struct.pack("<I", crc & 0xFFFFFFFF))
    ack = struct.unpack(">I", recvn(sock, 4))[0]
    return ack


def recvn(sock, n):
    buf = b""
    while len(buf) < n:
        d = sock.recv(n - len(buf))
        if not d:
            raise ConnectionError("eof")
        buf += d
    return buf


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    host, port = sys.argv[1], int(sys.argv[2])
    blobs = sys.argv[3:]

    s = socket.create_connection((host, port), timeout=30)
    s.settimeout(None)
    print(f"connected to {host}:{port}")

    for i, path in enumerate(blobs):
        kind = "rootfs(sparse)" if i == 0 else "deb"
        print(f"[{i}] {kind}: {path}")
        ack = send_blob(s, path)
        if ack != 0:
            print(f"ERROR: server rejected blob {i} with status {ack}")
            return 1
        print(f"[{i}] ack OK")

    s.sendall(struct.pack("<Q", 0))
    ack = struct.unpack(">I", recvn(s, 4))[0]
    s.close()
    if ack != 0:
        print(f"ERROR: terminator ack {ack}")
        return 1
    print("deploy transfer complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
