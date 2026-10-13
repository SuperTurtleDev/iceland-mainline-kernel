#!/usr/bin/env python3
"""Bounded Oplus camera subscription experiment; no AP I2C or algorithms.

Field mapping from vendor config serializer: width, height, two parameters
(default 5/1000), delivery mode, placement, fps. All requests use one QRTR
client; unsubscribe is attempted even if subscribe times out.
"""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('oplus', Path(__file__).with_name('see-oplus-query.py'))
oplus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oplus)
see = oplus.see

def check_ack(raw):
    error = see.one(raw, 1, 0)
    if error:
        raise RuntimeError(f'Oplus ACK error {error}')

def main():
    placement = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    if placement not in (0, 1):
        raise ValueError('placement must be 0 or 1')
    client = see.Client(5)
    attempted = False
    try:
        lookup = client.query(see.LOOKUP_UID, 512, 768, see.blob(1, b'camera_oplus_aon') + b'\x10\x00\x18\x00')
        uids = [see.uid_decode(v) for n, w, v in see.fields(lookup) if (n, w) == (2, 2)]
        if len(uids) != 1:
            raise RuntimeError(f'expected one camera_oplus_aon SUID: {uids}')
        uid = uids[0]
        caps = oplus.exchange(client, uid, 0x204, b'', 0x210)
        info = see.one(caps, 2, 2)
        width, height = see.one(info, 1, 0), see.one(info, 2, 0)
        rates = []
        for n, w, v in see.fields(info):
            if (n, w) == (3, 0):
                rates.append(v)
            elif (n, w) == (3, 2):
                pos = 0
                while pos < len(v):
                    rate, pos = see.read_varint(v, pos)
                    rates.append(rate)
        if not rates or min(rates) <= 0:
            raise ValueError('no valid advertised rates')
        values = [width, height, 5, 1000, 0, placement, min(rates)]
        payload = b''.join(see.varint(n << 3) + see.varint(v) for n, v in enumerate(values, 1))
        print(json.dumps({'config_fields': values}), flush=True)
        attempted = True
        check_ack(oplus.exchange(client, uid, 0x201, payload, 0x20d))
        print(json.dumps({'subscribe_ack_success': True, 'ap_i2c_attempted': False}), flush=True)
    finally:
        try:
            if attempted:
                check_ack(oplus.exchange(client, uid, 0x202, b'', 0x20e))
                print(json.dumps({'unsubscribe_ack_success': True}), flush=True)
        finally:
            client.sock.close()

if __name__ == '__main__':
    main()
