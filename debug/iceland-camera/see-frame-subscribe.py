#!/usr/bin/env python3
"""Bounded replay of ADSP's Oplus-to-frame subscription, with error details.

Derived from b2127c30 and descriptor b2137634 in ADSP sha256 75c4de75...fa6.
No handshake REVOKE, AP I2C, or algorithm enable. Always unsubscribe this client.
The configuration mirrors the observed Oplus 320x240/5fps capability experiment;
it is a diagnostic, not the eventual camera resource acquisition protocol.
"""
import argparse
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('oplus', Path(__file__).with_name('see-oplus-query.py'))
oplus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oplus)
see = oplus.see


def decode_ack(raw):
    detail = see.one(raw, 2, 2)
    return {'status': see.one(raw, 1, 0), 'error': see.one(detail, 1, 0),
            'detail_fields': see.fields(detail)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('placement', type=int, choices=(0, 1))
    args = parser.parse_args()
    client = see.Client(5)
    attempted = False
    ack = None
    try:
        lookup = client.query(see.LOOKUP_UID, 512, 768,
                             see.blob(1, b'camera_frame') + b'\x10\x00\x18\x00')
        uids = [see.uid_decode(v) for n, w, v in see.fields(lookup) if (n, w) == (2, 2)]
        if len(uids) != 1:
            raise RuntimeError(f'expected one camera_frame SUID: {uids}')
        uid = uids[0]
        values = {1: 7, 2: 0, 3: 0xffffffff, 4: 1000, 5: 1,
                  6: 320, 7: 240, 8: 320, 9: 240, 10: args.placement, 16: 1}
        payload = b''.join(see.varint(n << 3) + see.varint(v) for n, v in values.items())
        print(json.dumps({'frame_fields': values}), flush=True)
        attempted = True
        ack = decode_ack(oplus.exchange(client, uid, 0x280, payload, 0x380))
        print(json.dumps({'subscribe_ack': ack, 'ap_i2c_attempted': False}), flush=True)
    finally:
        try:
            if attempted:
                cleanup = decode_ack(oplus.exchange(client, uid, 0x281, b'', 0x381))
                print(json.dumps({'unsubscribe_ack': cleanup}), flush=True)
                if cleanup['status'] or cleanup['error']:
                    raise RuntimeError('frame unsubscribe failed')
        finally:
            client.sock.close()
    return int(bool(ack['status'] or ack['error']))


if __name__ == '__main__':
    raise SystemExit(main())
