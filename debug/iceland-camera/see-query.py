#!/usr/bin/env python3
"""Query SEE SUIDs and attributes over QRTR; never enable a sensor."""

import argparse
import json
import socket
import struct
import time

LOOKUP_UID = (0xABABABABABABABAB,) * 2


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result) + bytes([value])


def read_varint(data, pos):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError("truncated varint")
        byte = data[pos]
        pos += 1
        if shift == 63 and byte > 1:
            raise ValueError("overflowing varint")
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, pos
    raise ValueError("overlong varint")


def blob(number, value):
    return varint(number << 3 | 2) + varint(len(value)) + value


def fields(data):
    result = []
    pos = 0
    while pos < len(data):
        key, pos = read_varint(data, pos)
        number, wire = key >> 3, key & 7
        if not number:
            raise ValueError("zero protobuf field")
        if wire == 0:
            value, pos = read_varint(data, pos)
        else:
            if wire == 2:
                size, pos = read_varint(data, pos)
            elif wire in (1, 5):
                size = 8 if wire == 1 else 4
            else:
                raise ValueError(f"unsupported wire type {wire}")
            if size > len(data) - pos:
                raise ValueError("truncated protobuf field")
            value = data[pos:pos + size]
            pos += size
            if wire != 2:
                value = int.from_bytes(value, "little")
        result.append((number, wire, value))
    return result


def one(data, number, wire):
    values = [v for n, w, v in fields(data) if (n, w) == (number, wire)]
    if len(values) != 1:
        raise ValueError(f"expected one field {number}/{wire}")
    return values[0]


def uid_decode(data):
    return one(data, 1, 1), one(data, 2, 1)


def request(uid, message_id, payload):
    encoded_uid = b"\x09" + struct.pack("<Q", uid[0])
    encoded_uid += b"\x11" + struct.pack("<Q", uid[1])
    return (blob(1, encoded_uid) + b"\x15" + struct.pack("<I", message_id)
            + blob(3, b"\x08\x01\x10\x00") + blob(4, blob(2, payload)))


def tlv(number, value):
    return struct.pack("<BH", number, len(value)) + value


def qmi_decode(data):
    if len(data) < 7:
        raise ValueError("short QMI header")
    kind, txn, message, size = struct.unpack_from("<BHHH", data)
    if size != len(data) - 7:
        raise ValueError("QMI size mismatch")
    pos, values = 7, {}
    while pos < len(data):
        if len(data) - pos < 3:
            raise ValueError("short TLV header")
        number, length = struct.unpack_from("<BH", data, pos)
        pos += 3
        if length > len(data) - pos or number in values:
            raise ValueError("invalid TLV")
        values[number] = data[pos:pos + length]
        pos += length
    return kind, txn, message, values


class Client:
    def __init__(self, timeout):
        self.timeout = timeout
        self.transaction = 0
        self.sock = socket.socket(socket.AF_QIPCRTR, socket.SOCK_DGRAM)
        try:
            local_node, _ = self.sock.getsockname()
            self.sock.bind((local_node, 0))
            self.sock.sendto(struct.pack("<IIIII", 10, 400, 0, 0, 0),
                             (local_node, 0xFFFFFFFE))
            deadline = time.monotonic() + timeout
            while True:
                data, source = self.receive(deadline)
                if source[1] != 0xFFFFFFFE or len(data) < 20:
                    continue
                cmd, service, instance, node, port = struct.unpack_from("<IIIII", data)
                if cmd == 4 and service == 400 and port:
                    self.server = (node, port)
                    self.instance = instance
                    break
        except BaseException:
            self.sock.close()
            raise

    def receive(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("SEE query timed out")
        self.sock.settimeout(remaining)
        return self.sock.recvfrom(65535)

    def query(self, uid, message_id, reply_id, payload):
        # Deliberately restricted to discovery/attribute requests.
        if message_id not in (1, 512):
            raise ValueError("only read-only SEE queries are allowed")
        self.transaction += 1
        encoded = request(uid, message_id, payload)
        body = tlv(1, struct.pack("<H", len(encoded)) + encoded) + tlv(16, b"\x01")
        self.sock.sendto(struct.pack("<BHHH", 0, self.transaction, 32, len(body))
                         + body, self.server)
        deadline = time.monotonic() + self.timeout
        acknowledged, reply = False, None
        while not acknowledged or reply is None:
            data, source = self.receive(deadline)
            if source != self.server:
                continue
            kind, txn, message, values = qmi_decode(data)
            if kind == 2 and txn == self.transaction and message == 32:
                result, error = struct.unpack("<HH", values[2])
                if result:
                    raise RuntimeError(f"SEE QMI error {error}")
                if 17 in values and int.from_bytes(values[17], "little"):
                    raise RuntimeError(f"SEE response error {values[17].hex()}")
                acknowledged = True
            elif kind == 4 and message in (33, 34):
                report = values[2]
                size, = struct.unpack_from("<H", report)
                if size != len(report) - 2:
                    raise ValueError("SSC report size mismatch")
                envelope = report[2:]
                if uid_decode(one(envelope, 1, 2)) != uid:
                    continue
                for number, wire, event in fields(envelope):
                    if (number, wire) != (2, 2):
                        continue
                    event_id = one(event, 1, 5)
                    if event_id == 129:
                        raise RuntimeError(f"SEE sensor error {one(event, 3, 2).hex()}")
                    if event_id == reply_id:
                        reply = one(event, 3, 2)
        return reply


def attribute_values(data, depth=0):
    if depth > 8:
        raise ValueError("attribute nesting too deep")
    result = []
    for number, wire, value in fields(data):
        if (number, wire) == (1, 2):
            result.append([attribute_values(v, depth + 1)
                           for n, w, v in fields(value) if (n, w) == (1, 2)])
        elif (number, wire) == (2, 2):
            result.append(value.rstrip(b"\0").decode("utf-8", errors="replace"))
        elif (number, wire) == (3, 5):
            result.append(struct.unpack("<f", struct.pack("<I", value))[0])
        elif (number, wire) == (4, 1):
            result.append(value if value < 1 << 63 else value - (1 << 64))
        elif (number, wire) == (5, 0):
            result.append(bool(value))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("types", nargs="*", default=[
        "camera_handshake", "camera_oplus_aon", "camera_frame",
        "camera_motion", "oplus_camera_orient"])
    parser.add_argument("--timeout", type=float, default=3)
    args = parser.parse_args()
    client = Client(args.timeout)
    try:
        print(json.dumps({"server": client.server, "instance": client.instance}), flush=True)
        for data_type in args.types:
            result = {"data_type": data_type, "sensors": []}
            try:
                response = client.query(LOOKUP_UID, 512, 768,
                                        blob(1, data_type.encode()) + b"\x10\x00\x18\x00")
                if one(response, 1, 2).rstrip(b"\0") != data_type.encode():
                    raise ValueError("SUID data_type mismatch")
                for number, wire, value in fields(response):
                    if (number, wire) != (2, 2):
                        continue
                    uid = uid_decode(value)
                    sensor = {"uid_low": f"{uid[0]:016x}", "uid_high": f"{uid[1]:016x}"}
                    result["sensors"].append(sensor)
                    attributes = client.query(uid, 1, 128, b"\x10\x00")
                    sensor["attributes"] = {
                        str(one(v, 1, 0)): [attribute_values(a)
                                           for n, w, a in fields(one(v, 2, 2))
                                           if (n, w) == (1, 2)]
                        for n, w, v in fields(attributes) if (n, w) == (1, 2)}
            except (OSError, ValueError, RuntimeError) as error:
                result["error"] = str(error)
            print(json.dumps(result, ensure_ascii=False), flush=True)
    finally:
        client.sock.close()


if __name__ == "__main__":
    main()
