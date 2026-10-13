#!/usr/bin/env python3
"""Query the vendor Oplus AON capability message, without subscribing."""
import importlib.util
import json
from pathlib import Path
import struct
import time

spec = importlib.util.spec_from_file_location('see', Path(__file__).with_name('see-query.py'))
see = importlib.util.module_from_spec(spec)
spec.loader.exec_module(see)

def exchange(client, uid, message, payload, reply_id):
    client.transaction += 1
    encoded = see.request(uid, message, payload)
    body = see.tlv(1, struct.pack('<H', len(encoded)) + encoded) + see.tlv(16, b'\x01')
    client.sock.sendto(struct.pack('<BHHH', 0, client.transaction, 32, len(body)) + body, client.server)
    print(json.dumps({'send': message, 'uid': [hex(v) for v in uid], 'payload': payload.hex()}), flush=True)
    deadline = time.monotonic() + client.timeout
    ack, reply = False, None
    while not ack or reply is None:
        data, source = client.receive(deadline)
        if source != client.server:
            continue
        kind, txn, msg, values = see.qmi_decode(data)
        if kind == 2 and txn == client.transaction and msg == 32:
            result, error = struct.unpack('<HH', values[2])
            print(json.dumps({'qmi_result': result, 'qmi_error': error, 'tlvs': {str(k): v.hex() for k, v in values.items()}}), flush=True)
            if result or int.from_bytes(values.get(17, b'\0'), 'little'):
                raise RuntimeError('SEE request rejected')
            ack = True
        elif kind == 4 and msg in (33, 34):
            report = values[2]
            if struct.unpack_from('<H', report)[0] != len(report) - 2:
                raise ValueError('invalid report length')
            envelope = report[2:]
            if see.uid_decode(see.one(envelope, 1, 2)) != uid:
                continue
            for n, w, event in see.fields(envelope):
                if (n, w) != (2, 2):
                    continue
                event_id, raw = see.one(event, 1, 5), see.one(event, 3, 2)
                print(json.dumps({'event': event_id, 'payload': raw.hex()}), flush=True)
                if event_id == 129:
                    raise RuntimeError('SEE sensor error: ' + raw.hex())
                if event_id == reply_id:
                    reply = raw
    return reply

if __name__ == '__main__':
    client = see.Client(5)
    try:
        data = client.query(see.LOOKUP_UID, 512, 768, see.blob(1, b'camera_oplus_aon') + b'\x10\x00\x18\x00')
        uids = [see.uid_decode(v) for n, w, v in see.fields(data) if (n, w) == (2, 2)]
        if len(uids) != 1:
            raise RuntimeError(f'expected one camera_oplus_aon SUID: {uids}')
        exchange(client, uids[0], 0x204, b'', 0x210)
    finally:
        client.sock.close()
