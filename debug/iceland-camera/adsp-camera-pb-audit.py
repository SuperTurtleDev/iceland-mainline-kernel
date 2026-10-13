#!/usr/bin/env python3
"""Offline camera PB identity/schema audit using recovered ADSP descriptors.

No firmware or target modifications. Numeric field paths are retained because
nanopb descriptors have no field names. Identity fields are mapped from the
ADSP translator and cross-checked against stock files.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def sibling(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pb = sibling('see-query')


def validate(raw, descriptor, path=''):
    """Validate encoded fields, including packed repeated scalar fields."""
    known = {f['tag']: f for f in descriptor['fields']}
    seen = set()
    count = 0
    for tag, wire, value in pb.fields(raw):
        field = known.get(tag)
        current = path + '.' + str(tag)
        if field is None:
            raise ValueError(f'{current}: unknown field in recovered schema')
        typ = int(field['type'], 16)
        scalar = typ & 15
        expected = 0 if scalar < 4 else 5 if scalar == 4 else 1 if scalar == 5 else 2
        repeated = typ & 0x30 == 0x20
        if not repeated and tag in seen:
            raise ValueError(f'{current}: duplicate singular field')
        seen.add(tag)
        if wire == 2 and expected != 2 and repeated:
            if expected == 0:
                pos = 0
                while pos < len(value):
                    _, pos = pb.read_varint(value, pos)
            elif len(value) % (4 if expected == 5 else 8):
                raise ValueError(f'{current}: truncated packed field')
        elif wire != expected:
            raise ValueError(f'{current}: wire {wire}, expected {expected}')
        if scalar in (8, 9):
            count += validate(value, field['submessage'], current)
        elif scalar == 7:
            value.decode('utf-8')
        count += 1
    missing = [f['tag'] for f in known.values()
               if int(f['type'], 16) & 0x30 == 0 and f['tag'] not in seen]
    if missing:
        raise ValueError(f'{path}: missing required fields {missing}')
    return count


def nested(raw, path, wire=0):
    for tag in path[:-1]:
        raw = pb.one(raw, tag, 2)
    return pb.one(raw, path[-1], wire)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('descriptor', type=Path)
    parser.add_argument('files', type=Path, nargs='+')
    args = parser.parse_args()
    schema = json.loads(args.descriptor.read_text())
    root = schema['descriptors'][0]
    if root['address'] != '0xb21388d8':
        raise ValueError('identity mapping requires the audited camera PB root')
    records = []
    for path in args.files:
        raw = path.read_bytes()
        count = validate(raw, root)
        position = nested(raw, [6, 14])
        if position not in (1, 2, 3, 4):
            raise ValueError('ADSP translator rejects this camera position')
        records.append({'file': str(path), 'sha256': hashlib.sha256(raw).hexdigest(),
                        'schema_field_count': count, 'root_field_1': nested(raw, [1]),
                        'sensor_name': nested(raw, [2, 2, 1], 2).decode(),
                        'slave_address_raw': nested(raw, [2, 2, 4]),
                        'sensor_id_register': hex(nested(raw, [2, 2, 7])),
                        'sensor_id': hex(nested(raw, [2, 2, 8])),
                        'sensor_id_mask': hex(nested(raw, [2, 2, 9])),
                        'camera_position': position,
                        'framework_index': 1 if position in (1, 3) else 0})
    print(json.dumps({'adsp_sha256': schema['sha256'], 'files': records}, indent=2))


if __name__ == '__main__':
    main()
