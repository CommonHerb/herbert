#!/usr/bin/env python3
"""Generate Herbert's Unicode 18 property table from pinned, local data files.

Development tooling only: the emitted program uses neither Python nor these
source files. Download the documented inputs separately; this tool never uses
the network. --check verifies reproducibility without changing any file.
"""

import argparse
import hashlib
import json
from pathlib import Path

INPUTS = {
    'GraphemeBreakProperty.txt': {
        'url': 'https://www.unicode.org/Public/18.0.0/ucd/auxiliary/GraphemeBreakProperty.txt',
        'sha256': '0839dcb79e4ac639ecd538b1abf7c9d22e3f9dd265b7e182d33627aa4d75b45a',
    },
    'emoji-data.txt': {
        'url': 'https://www.unicode.org/Public/18.0.0/ucd/emoji/emoji-data.txt',
        'sha256': '80d00f8e616a0ef27fd6b8de3b758c06383b5d917e2977709578e68baf733bf1',
    },
    'DerivedCoreProperties.txt': {
        'url': 'https://www.unicode.org/Public/18.0.0/ucd/DerivedCoreProperties.txt',
        'sha256': '09c928886a178fcafd93c29e4bd59073a058e5a100b716d425cb563ab50f68c9',
    },
    'LICENSE.txt': {
        'url': 'https://www.unicode.org/license.txt',
        'sha256': 'e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96',
    },
}
GCB = {
    'CR': 1, 'LF': 2, 'Control': 3, 'Extend': 4, 'ZWJ': 5,
    'Regional_Indicator': 6, 'Prepend': 7, 'SpacingMark': 8,
    'L': 9, 'V': 10, 'T': 11, 'LV': 12, 'LVT': 13,
}
INCB = {'Consonant': 64, 'Extend': 128, 'Linker': 192}
HEADER = '''-- Unicode 18.0.0 default extended grapheme boundaries, UAX #29 rev49.
-- Property data is mechanically merged from GraphemeBreakProperty.txt,
-- emoji-data.txt (Extended_Pictographic), DerivedCoreProperties.txt (InCB).
-- Each 14-character lowercase hexadecimal record: low6, high6, flags2.
-- Low nibble: Other0 CR1 LF2 Control3 Extend4 ZWJ5 RI6 Prepend7
-- SpacingMark8 L9 V10 T11 LV12 LVT13. Bit4: Extended_Pictographic.
-- Bits6..7: InCB None0 Consonant1 Extend2 Linker3.
-- Sorted disjoint nonzero ranges; Hangul syllables use exact arithmetic.
-- Generated asset, not foreign implementation code. See docs/UNICODE.md.
'''


def entries(data):
    for line in data.decode('utf-8').splitlines():
        fields = [field.strip() for field in line.split('#', 1)[0].split(';')]
        if len(fields) < 2:
            continue
        span = fields[0].split('..')
        yield int(span[0], 16), int(span[-1], 16), fields[1:]


def generate(source):
    # Read each input once: validated bytes are exactly the bytes parsed below.
    inputs = {name: (source / name).read_bytes() for name in INPUTS}
    for name, data in inputs.items():
        actual = hashlib.sha256(data).hexdigest()
        if actual != INPUTS[name]['sha256']:
            raise SystemExit(f'{name}: pinned SHA256 mismatch: {actual}')
    props = bytearray(0x110000)
    for lo, hi, fields in entries(inputs['GraphemeBreakProperty.txt']):
        value = GCB[fields[0]]
        for cp in range(lo, hi + 1):
            if props[cp] != 0:
                raise SystemExit(f'duplicate GCB scalar: {cp:x}')
            props[cp] = value
    for lo, hi, fields in entries(inputs['emoji-data.txt']):
        if fields[0] == 'Extended_Pictographic':
            for cp in range(lo, hi + 1):
                props[cp] |= 16
    for lo, hi, fields in entries(inputs['DerivedCoreProperties.txt']):
        if fields[0] == 'InCB':
            value = INCB[fields[1]]
            for cp in range(lo, hi + 1):
                if props[cp] & 192:
                    raise SystemExit(f'duplicate InCB scalar: {cp:x}')
                props[cp] |= value
    # Hangul syllable classes use exact arithmetic in the handwritten library.
    # Check that no other property would be lost by removing these ranges.
    for cp in range(0xAC00, 0xD7A4):
        if props[cp] != (12 if (cp - 0xAC00) % 28 == 0 else 13):
            raise SystemExit(f'unexpected Hangul properties: {cp:x}')
        props[cp] = 0
    ranges = []
    i = 0
    while i < len(props):
        value = props[i]
        j = i + 1
        while j < len(props) and props[j] == value:
            j += 1
        if value:
            ranges.append((i, j - 1, value))
        i = j
    encoded = ''.join(f'{lo:06x}{hi:06x}{value:02x}' for lo, hi, value in ranges)
    header = HEADER
    for name in ('GraphemeBreakProperty.txt', 'emoji-data.txt', 'DerivedCoreProperties.txt'):
        header += '-- ' + name + ' SHA256 ' + INPUTS[name]['sha256'] + '\n'
    header += '\n'.join('-- ' + line for line in inputs['LICENSE.txt'].decode('utf-8').splitlines())
    header += '\n\nfunc unicode_grapheme_ranges():\n    return "' + encoded + '"\nend\n'
    return header.encode('utf-8'), len(ranges), len(encoded)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True,
                        help='directory containing the four pinned Unicode source/license files')
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'lib/unicode_tables.herb')
    parser.add_argument('--check', action='store_true',
                        help='compare generated bytes with output without writing')
    args = parser.parse_args()
    data, ranges, encoded_bytes = generate(args.source_dir)
    if args.check:
        if args.output.read_bytes() != data:
            raise SystemExit(f'{args.output}: generated table differs')
    else:
        args.output.write_bytes(data)
    print(json.dumps({'ranges': ranges, 'encoded_bytes': encoded_bytes,
                      'output_sha256': hashlib.sha256(data).hexdigest(),
                      'mode': 'check' if args.check else 'write'}, sort_keys=True))


if __name__ == '__main__':
    main()
