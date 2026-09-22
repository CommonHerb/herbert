#!/usr/bin/env python3
"""Independent UTF-8 and text-editing contracts, with Unicode's boundary oracle.

Expected bytes come from Python's strict UTF-8 codec, hand-declared editing
states, or the literal break markers in the pinned official conformance file.
No Herbert property table or result is used to construct an expectation.
"""
if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

from pathlib import Path
import argparse
import hashlib
import json
import random
import struct
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
p.add_argument('--evidence', type=Path)
a = p.parse_args()
root = a.root.resolve()
work = a.evidence or Path(tempfile.mkdtemp(prefix='herbert-utf8-text-'))
work.mkdir(parents=True, exist_ok=True)
print(f'UTF-8/text evidence: {work}', flush=True)
seed = (root/'bootstrap/seed/gen1.seed').read_bytes()
seed_sha = hashlib.sha256(seed).hexdigest()
assert seed_sha == (root/'bootstrap/seed/gen1.seed.sha256').read_text().split()[0]
# Integrity pin for the reviewed, mechanically generated asset. This is not an
# independent semantic oracle; the official boundary fixture below serves that
# role. Deliberate table regeneration requires review before updating this pin.
table_sha = hashlib.sha256((root/'lib/unicode_tables.herb').read_bytes()).hexdigest()
assert table_sha == 'e7fbaff3b82430ccdfea344c9e694808f52b39654f5a6432d03f224b42fbb80c', 'reviewed Unicode table asset integrity mismatch'
prelude = '\n'.join((root/path).read_text() for path in (
    'lib/linux.herb', 'lib/file_io.herb', 'lib/utf8.herb', 'lib/unicode_tables.herb', 'lib/unicode_grapheme.herb', 'lib/text_buffer.herb')) + '\n'
checks = []
U64 = (1 << 64) - 1

def pack(*values):
    return struct.pack('<'+'Q'*len(values), *(value & U64 for value in values))

def check(name, condition, **details):
    assert condition, (name, details)
    checks.append(dict(check=name, **details))
    print('PASS', name, flush=True)

def compile_program(name, source, extra=''):
    d = work/name
    d.mkdir()
    (d/'compiler').write_bytes(seed)
    (d/'compiler').chmod(0o700)
    text = prelude+extra+source
    (d/'source.herb').write_text(text)
    r = subprocess.run(['./compiler'], cwd=d, input=text.encode(), capture_output=True, timeout=60)
    (d/'compile.stdout').write_bytes(r.stdout)
    (d/'compile.stderr').write_bytes(r.stderr)
    assert r.returncode == 0 and r.stdout == b'0\n' and not r.stderr, (name, r.returncode, r.stdout, r.stderr)
    exe = d/'a.out'
    assert exe.read_bytes().startswith(b'\x7fELF\x02\x01')
    exe.chmod(0o700)
    return exe

def execute(name, exe, data, expected, *args, timeout=30):
    d = work/name
    d.mkdir()
    (d/'input.bin').write_bytes(data)
    (d/'expected.bin').write_bytes(expected)
    r = subprocess.run([str(exe), *map(str,args)], input=data, capture_output=True, timeout=timeout)
    (d/'actual.bin').write_bytes(r.stdout)
    (d/'stderr').write_bytes(r.stderr)
    (d/'status.json').write_text(json.dumps(dict(returncode=r.returncode))+'\n')
    assert r.returncode == 0 and not r.stderr and r.stdout == expected, (name, r.returncode, len(expected), len(r.stdout), r.stderr)

# Binary frames avoid relying on the language parser's string literal syntax.
codec = compile_program('codec-driver', r'''func codec_run(input, at, limit, scratch, out):
 if at >= limit: return 0 end
 let mode = linux_u64(input, at)
 let value = linux_u64(input, at + 8)
 let count = linux_u64(input, at + 16)
 let next = at + 24 + count
 let copied = linux_copy(scratch, 0, input, at + 24, count)
 if mode == 0:
  let decoded = utf8_decode(scratch, value, count)
  let first = linux_put64(out, 0, decoded.0)
  let second = linux_put64(out, 8, decoded.1)
  let shown = file_write_bytes(1, out, 0, 16)
 else:
  let width = utf8_width(value)
  let stored = utf8_store(scratch, mode - 1, value)
  let first = linux_put64(out, 0, width)
  let second = linux_put64(out, 8, stored)
  let shown = file_write_bytes(1, out, 0, 16)
  let body = file_write_bytes(1, scratch, 0, 16)
 end
 return codec_run(input, next, limit, scratch, out)
end
func main():
 let input = stdin_read()
 let bytes = linux_cstring(input.1)
 let scratch = linux_buffer(16)
 let out = linux_buffer(16)
 let run = codec_run(bytes, 0, length(input.1), scratch, out)
 do process_exit(0)
 return 0
end
''')

# Scalar edge values plus every single byte and all malformed sequence classes.
scalars = [0, 9, 10, 13, 31, 32, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff,
           0xe000, 0xffff, 0x10000, 0x10ffff, 0xfffe, 0xfeff, 0xfdd0]
rng = random.Random(3629)
scalars += [cp for cp in (rng.randrange(0x110000) for _ in range(256)) if not 0xd800 <= cp <= 0xdfff]
malformed = [bytes([value]) for value in range(0x80,256)]
malformed += [b'\xc0\x80',b'\xc1\xbf',b'\xe0\x80\x80',b'\xe0\x9f\xbf',
              b'\xed\xa0\x80',b'\xed\xbf\xbf',b'\xf0\x80\x80\x80',b'\xf0\x8f\xbf\xbf',
              b'\xf4\x90\x80\x80',b'\xf5\x80\x80\x80',b'\xf8\x88\x80\x80\x80',
              b'\xfc\x84\x80\x80\x80\x80',b'\xc2A',b'\xe2A\xa1',b'\xe2\x82A',
              b'\xf0A\x80\x80',b'\xf0\x9fA\x80',b'\xf0\x9f\x98A']
for cp in (0x80,0x800,0x10000,0x10ffff):
    encoded = chr(cp).encode()
    malformed.extend(encoded[:cut] for cut in range(1,len(encoded)))
data = bytearray(); expected = bytearray()
for cp in scalars:
    encoded = chr(cp).encode()
    for prefix in (b'',b'XYZ'):
        payload = prefix+encoded+b'!'
        data += pack(0,len(prefix),len(payload))+payload
        expected += pack(cp,len(prefix)+len(encoded))
for payload in malformed:
    try:
        payload.decode('utf-8')
    except UnicodeDecodeError:
        pass
    else:
        raise AssertionError(('malformed fixture is valid',payload))
    for prefix in (b'',b'XYZ'):
        data += pack(0,len(prefix),len(prefix+payload))+prefix+payload
        expected += pack(-84,len(prefix))
for offset,count in ((0,0),(1,0),(1,1),(17,1)):
    data += pack(0,offset,count)+b'A'*count
    expected += pack(-84,offset)
execute('codec-strict-decoding',codec,bytes(data),bytes(expected))
check('strict-rfc3629-decoding',True,valid_scalars=len(scalars),malformed_sequences=len(malformed),offset_cases=4)

# Each store begins with sixteen sentinels, so rejection or an accidental
# write outside the encoded span cannot hide behind untouched zero storage.
data = bytearray(); expected = bytearray()
for cp in scalars:
    encoded = chr(cp).encode()
    for offset in (0,1,12):
        wanted = bytearray(b'Z'*16);wanted[offset:offset+len(encoded)]=encoded
        data += pack(1+offset,cp,16)+b'Z'*16
        expected += pack(len(encoded),offset+len(encoded))+wanted
for cp in (0xd800,0xdfff,0x110000,U64):
    data += pack(1,cp,16)+b'Z'*16
    expected += pack(0,-84)+b'Z'*16
for cp in (0x41,0x80,0x800,0x10000):
    data += pack(17,cp,16)+b'Z'*16
    expected += pack(len(chr(cp).encode()),-27)+b'Z'*16
execute('codec-encoding-and-refusals',codec,bytes(data),bytes(expected))
check('strict-scalar-encoding-and-atomic-refusal',True,valid_scalars=len(scalars),offsets=3,refusals=8)

boundary = compile_program('boundary-driver', r'''func boundary_offsets(bytes, count, marks, at, out):
 if at > count: return 0 end
 let a = linux_put64(out, 0, buffer_get(marks, at))
 let b = linux_put64(out, 8, unicode_grapheme_next(bytes, count, at))
 let c = linux_put64(out, 16, unicode_grapheme_previous(bytes, count, at))
 let shown = file_write_bytes(1, out, 0, 24)
 return boundary_offsets(bytes, count, marks, at + 1, out)
end
func boundary_run(input, at, limit, bytes, marks, out):
 if at >= limit: return 0 end
 let count = linux_u64(input, at)
 let copied = linux_copy(bytes, 0, input, at + 8, count)
 let marked = unicode_grapheme_mark(bytes, count, marks)
 let state = linux_put64(out, 0, marked)
 let header = file_write_bytes(1, out, 0, 8)
 let shown = boundary_offsets(bytes, count, marks, 0, out)
 return boundary_run(input, at + 8 + count, limit, bytes, marks, out)
end
func main():
 let input = stdin_read()
 let all = linux_cstring(input.1)
 let bytes = linux_buffer(65536)
 let marks = linux_buffer(65537)
 let out = linux_buffer(24)
 let run = boundary_run(all, 0, length(input.1), bytes, marks, out)
 do process_exit(0)
 return 0
end
''')
fixture=root/'bootstrap/tests/fixtures/unicode-18.0.0/GraphemeBreakTest.txt'
fixture_sha=hashlib.sha256(fixture.read_bytes()).hexdigest()
assert fixture_sha=='b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31'
oracle=[]
for line_number,line in enumerate(fixture.read_text().splitlines(),1):
    body=line.split('#',1)[0].strip()
    if not body:continue
    payload=bytearray();breaks=[]
    for token in body.split():
        if token=='÷':breaks.append(len(payload))
        elif token!='×':payload+=chr(int(token,16)).encode()
    assert breaks[0]==0 and breaks[-1]==len(payload)
    oracle.append((line_number,bytes(payload),breaks))
data=bytearray(pack(0));expected=bytearray(pack(0,1,0,0))
for line_number,payload,breaks in oracle:
    data+=pack(len(payload))+payload;expected+=pack(0)
    for pos in range(len(payload)+1):
        following=next((b for b in breaks if b>pos),len(payload))
        previous=next((b for b in reversed(breaks) if b<pos),0)
        expected+=pack(int(pos in breaks),following,previous)
execute('unicode18-official-boundaries',boundary,bytes(data),bytes(expected),timeout=60)
check('unicode18-official-extended-grapheme-breaks',True,cases=len(oracle),fixture_sha256=fixture_sha)

editor = compile_program('editor-driver', r'''func editor_state(t, status, out):
 let a = linux_put64(out, 0, status)
 let b = linux_put64(out, 8, text_length(t))
 let c = linux_put64(out, 16, text_file_length(t))
 let d = linux_put64(out, 24, text_cursor(t))
 let style = 0
 if text_crlf(t): style = 1 end
 let e = linux_put64(out, 32, style)
 let header = file_write_bytes(1, out, 0, 40)
 return file_write_bytes(1, text_file_bytes(t), 0, text_file_length(t))
end
func editor_run(t, input, at, limit, out):
 if at >= limit: return 0 end
 let op = linux_u64(input, at)
 let value = linux_u64(input, at + 8)
 let changed = 0
 if op == 105: changed = text_insert(t, value)
 elif op == 100: changed = text_delete(t)
 elif op == 98: changed = text_backspace(t)
 elif op == 115: changed = text_seek(t, value)
 elif op == 117: changed = text_undo(t)
 elif op == 114: changed = text_redo(t)
 elif op == 108: changed = text_seek(t, text_next(t, text_cursor(t)))
 elif op == 104: changed = text_seek(t, text_previous(t, text_cursor(t)))
 elif op == 118: changed = text_vertical(t, true, value)
 elif op == 119: changed = text_vertical(t, false, value)
 end
 let shown = editor_state(t, 0, out)
 return editor_run(t, input, at + 16, limit, out)
end
func main():
 let args = linux_arguments()
 let original = file_open(linux_argument(args, 1), 65536)
 let input = stdin_read()
 let bytes = linux_cstring(input.1)
 let t = text_buffer(linux_u64(bytes, 0))
 let status = file_status(original)
 if status == 0: status = text_load(t, original.1, file_count(original)) end
 let out = linux_buffer(40)
 let shown = editor_state(t, status, out)
 let run = editor_run(t, bytes, 8, length(input.1), out)
 let closed = file_close(original)
 do process_exit(0)
 return 0
end
''')

def frame(payload,cursor=0,style=False,status=0):
    logical=payload.replace(b'\r\n',b'\n') if style else payload
    return pack(status,len(logical),len(payload),cursor,int(style))+payload

def editing(name,initial,operations,states,capacity=65536,style=False):
    target=work/(name+'.document');target.write_bytes(initial)
    data=pack(capacity)+b''.join(pack(ord(op),value) for op,value in operations)
    expected=frame(initial,style=style)+b''.join(frame(text,cursor,style) for text,cursor in states)
    assert len(operations)==len(states)
    execute(name,editor,data,expected,target)
    assert target.read_bytes()==initial

# The official file supplies boundaries for text navigation too. Notes refuses
# C0/C1 controls other than TAB/LF, and bare CR; these remain library-only cases.
accepted=[]
for line_number,payload,breaks in oracle:
    chars=payload.decode()
    if any((ord(ch)<32 and ch not in '\t\n') or 0x7f<=ord(ch)<=0x9f for ch in chars):continue
    accepted.append((line_number,payload,breaks))
for line_number,payload,breaks in accepted:
    operations=[];states=[]
    for pos in range(len(payload)+2):
        operations.append(('s',pos));states.append((payload,max(b for b in breaks if b<=min(pos,len(payload)))))
    operations.append(('s',0));states.append((payload,0))
    for b in breaks[1:]+[len(payload)]:operations.append(('l',0));states.append((payload,b))
    for b in list(reversed(breaks[:-1]))+[0]:operations.append(('h',0));states.append((payload,b))
    editing(f'official-text-{line_number}',payload,operations,states)
check('text-navigation-agrees-with-official-boundaries',True,cases=len(accepted))

# Explicit long clusters, flags, emoji modifiers/ZWJ, Hangul and Indic conjuncts.
clusters=['e\u0301', '\U0001f1fa\U0001f1f8', '👩🏽\u200d💻', '\u1100\u1161\u11a8',
          '\u0915\u094d\u0937', 'a'+'\u0301'*4096]
for i,cluster in enumerate(clusters):
    body=cluster.encode();initial=b'X'+body+b'Y'
    operations=[('s',1),('d',0),('u',0),('r',0),('u',0),('l',0),('b',0),('u',0)]
    states=[(initial,1),(b'XY',1),(initial,1),(b'XY',1),(initial,1),
            (initial,1+len(body)),(b'XY',1),(initial,1+len(body))]
    editing(f'whole-cluster-history-{i}',initial,operations,states)
check('whole-cluster-deletion-and-history',True,cases=len(clusters),long_cluster_bytes=len(clusters[-1].encode()))

# A scalar operation may merge with either side. Undo removes just that scalar,
# even when its bytes now lie inside one large cluster; redo restores the cursor.
def b(text):return text.encode()
editing('join-combining',b('e!'),[('s',1),('i',0x301),('u',0),('r',0),('b',0),('u',0)],
        [(b('e!'),1),(b('é!'),3),(b('e!'),1),(b('é!'),3),(b('!'),0),(b('é!'),3)])
editing('join-right-prepend',b('A!'),[('i',0x600),('u',0),('r',0),('b',0),('u',0)],
        [(b('\u0600A!'),3),(b('A!'),0),(b('\u0600A!'),3),(b('!'),0),(b('\u0600A!'),3)])
editing('join-emoji-zwj',b('👩💻!'),[('s',4),('i',0x200d),('u',0),('r',0),('b',0),('u',0)],
        [(b('👩💻!'),4),(b('👩\u200d💻!'),11),(b('👩💻!'),4),(b('👩\u200d💻!'),11),
         (b('!'),0),(b('👩\u200d💻!'),11)])
editing('delete-joins-regional-indicators',b('🇦X🇧!'),[('s',4),('d',0),('u',0),('r',0)],
        [(b('🇦X🇧!'),4),(b('🇦🇧!'),0),(b('🇦X🇧!'),4),(b('🇦🇧!'),0)])
editing('insert-repairs-regional-pairing',b('🇦🇧🇨!'),[('i',0x1f1e9),('u',0),('r',0)],
        [(b('🇩🇦🇧🇨!'),8),(b('🇦🇧🇨!'),0),(b('🇩🇦🇧🇨!'),8)])
check('history-restores-scalar-operations-across-cluster-merges',True,cases=5)

# A history payload can fill the complete byte budget. The following two-byte
# insert evicts the whole old deletion; no partially retained edit is possible.
long=b('a'+'\u0301'*127) # 255 bytes, one cluster
editing('history-payload-eviction',long,[('d',0),('i',0xe9),('u',0),('u',0),('r',0)],
        [(b'',0),(b('é'),2),(b'',0),(b'',0),(b('é'),2)],capacity=255)
editing('history-divergence-after-long-undo',b('é!'),
        [('d',0),('u',0),('i',0x3bb),('r',0),('u',0),('u',0)],
        [(b('!'),0),(b('é!'),0),(b('λé!'),2),(b('λé!'),2),(b('é!'),0),(b('é!'),0)])
# Record ring rollover independently models whole document/cursor snapshots;
# this alphabet has one cluster per scalar and no joining behavior.
rng=random.Random(18003629);model=bytearray();cursor=0;history=[];applied=0
operations=[('i',0xe9),('b',0)]*300+[('u',0)]*270+[('r',0)]*270
operations += [(rng.choice('iidbsuur'),rng.choice([0x41,0xe9,0x3bb,0x4e2d,0x1f600])) for _ in range(600)]
states=[]
for op,value in operations:
    before=(bytes(model),cursor);changed=False;cost=0
    positions=[0];position=0
    for ch in model.decode():position+=len(ch.encode());positions.append(position)
    if op=='i':
        piece=chr(value).encode()
        if len(model)+len(piece)<=65536:model[cursor:cursor]=piece;cursor+=len(piece);changed=True;cost=len(piece)
    elif op=='d' and cursor<len(model):
        end=positions[positions.index(cursor)+1];cost=end-cursor;del model[cursor:end];changed=True
    elif op=='b' and cursor:
        start=positions[positions.index(cursor)-1];cost=cursor-start;del model[start:cursor];cursor=start;changed=True
    elif op=='s':cursor=max(pos for pos in positions if pos<=min(value,len(model)))
    elif op=='u' and applied:applied-=1;content,cursor=history[applied][0];model=bytearray(content)
    elif op=='r' and applied<len(history):content,cursor=history[applied][1];model=bytearray(content);applied+=1
    if changed:
        history=history[:applied]+[(before,(bytes(model),cursor),cost)]
        while len(history)>256 or sum(entry[2] for entry in history)>65536:history.pop(0)
        applied=len(history)
    states.append((bytes(model),cursor))
editing('unicode-history-independent-model',b'',operations,states)
check('history-byte-budget-ring-and-divergence',True,random_operations=len(operations))

# Encoded bytes, rather than code points or cells, consume capacity. Failed
# edits preserve both the document and the preceding undo/redo operation.
editing('multibyte-capacity',b('é'),[('s',2),('i',0x1f600),('i',0xe9),('i',0x41),('u',0),('r',0)],
        [(b('é'),2),(b('é'),2),(b('éé'),4),(b('éé'),4),(b('é'),2),(b('éé'),4)],capacity=4)
editing('multibyte-crlf-capacity',b('é\r\n'),[('s',3),('i',0xe9),('i',10),('i',0x41),('u',0),('r',0)],
        [(b('é\r\n'),3),(b('é\r\né'),5),(b('é\r\né'),5),(b('é\r\né'),5),
         (b('é\r\n'),3),(b('é\r\né'),5)],capacity=6,style=True)
editing('unicode-vertical-tabs',b('é́x\n\tZ\n中文\nq'),[('s',5),('v',1),('v',1),('w',2)],
        [(b('é́x\n\tZ\n中文\nq'),5),(b('é́x\n\tZ\n中文\nq'),6),
         (b('é́x\n\tZ\n中文\nq'),15),(b('é́x\n\tZ\n中文\nq'),5)])
check('encoded-capacity-and-cluster-column-navigation',True,cases=3)

# A failed replacement load cannot destroy an existing Unicode edit/history.
retain = compile_program('retained-load-driver', r'''func main():
 let args = linux_arguments()
 let first = file_open(linux_argument(args, 1), 65536)
 let bad = file_open(linux_argument(args, 2), 65536)
 let t = text_buffer(65536)
 let loaded = text_load(t, first.1, file_count(first))
 let moved = text_seek(t, text_length(t))
 let inserted = text_insert(t, 128512)
 let refused = text_load(t, bad.1, file_count(bad))
 let out = linux_buffer(40)
 let before = editor_state(t, refused, out)
 let undo = text_undo(t)
 let after = editor_state(t, 0, out)
 let closed = file_close(first)
 let closedbad = file_close(bad)
 do process_exit(0)
 return 0
end
'''.replace('func main():', r'''func editor_state(t, status, out):
 let a = linux_put64(out, 0, status)
 let b = linux_put64(out, 8, text_length(t))
 let c = linux_put64(out, 16, text_file_length(t))
 let d = linux_put64(out, 24, text_cursor(t))
 let style = 0
 if text_crlf(t): style = 1 end
 let e = linux_put64(out, 32, style)
 let shown = file_write_bytes(1, out, 0, 40)
 return file_write_bytes(1, text_file_bytes(t), 0, text_file_length(t))
end
func main():
'''))
initial=b('é café\r\n')
first=work/'retain-first.document';first.write_bytes(initial)
for label,payload in [('malformed',b'\xed\xa0\x80'),('mixed',b('é\r\nλ\n')),('control',b('é\u0085'))]:
    bad=work/('retain-'+label+'.document');bad.write_bytes(payload)
    wanted=frame(initial+b('😀'),len(initial)-1+4,True,-84)+frame(initial,len(initial)-1,True)
    execute('retained-load-'+label,retain,b'',wanted,first,bad)
    assert first.read_bytes()==initial and bad.read_bytes()==payload
check('rejected-load-retains-unicode-style-cursor-and-history',True,cases=3)

# Valid noncharacters/BOM are preserved, without normalization. Controls and
# malformed sequences fail closed. Successful loads remain byte-for-byte exact.
loads=[('bom',b'\xef\xbb\xbfhello',0),('noncharacters',b('\ufffe\U0010ffff'),0)]
loads += [(f'c0-{cp}',bytes([cp]),-84) for cp in range(32) if cp not in (9,10)]
loads += [(f'c1-{cp}',chr(cp).encode(),-84) for cp in range(0x7f,0xa0)]
loads += [(f'malformed-{i}',payload,-84) for i,payload in enumerate(malformed)]
loads += [('oversize-multibyte',b('é')*32769,-27),('exact-multibyte',b('é')*32768,0)]
for label,payload,status in loads:
    target=work/(f'load-{label}.document');target.write_bytes(payload)
    wanted=frame(b'',status=status) if status else frame(payload)
    execute('load-'+label,editor,pack(65536),wanted,target)
    assert target.read_bytes()==payload
check('utf8-load-validation-preserves-input',True,cases=len(loads))

search = compile_program('search-driver', r'''func search_run(t, input, at, limit, query, out):
 if at >= limit: return 0 end
 let count = linux_u64(input, at)
 let start = linux_u64(input, at + 8)
 let backward = linux_u64(input, at + 16) != 0
 let copied = linux_copy(query, 0, input, at + 24, count)
 let found = text_find(t, query, count, start, backward)
 let stored = linux_put64(out, 0, found)
 let shown = file_write_bytes(1, out, 0, 8)
 return search_run(t, input, at + 24 + count, limit, query, out)
end
func main():
 let args = linux_arguments()
 let file = file_open(linux_argument(args, 1), 65536)
 let t = text_buffer(65536)
 let loaded = text_load(t, file.1, file_count(file))
 let input = stdin_read()
 let bytes = linux_cstring(input.1)
 let query = linux_buffer(65536)
 let out = linux_buffer(8)
 let run = search_run(t, bytes, 0, length(input.1), query, out)
 let closed = file_close(file)
 do process_exit(0)
 return 0
end
''')
# Explicit cluster list is the oracle; this is not a second segmentation engine.
cluster_list=['é',' ','é',' ','👩\u200d💻',' ','🇦🇧',' ','é','x','\n']
text=''.join(cluster_list).encode();boundaries=[0];offset=0
for cluster in cluster_list:offset+=len(cluster.encode());boundaries.append(offset)
queries=['é','é','e','́','👩','👩\u200d💻','💻','🇦','🇦🇧','éx','x\n','','É']
query_bytes=[q.encode() for q in queries]+[b'\xa9',b'\xc3',b'\xff']
data=bytearray();expected=bytearray();cases=0
for query in query_bytes:
    candidates=len(text)-len(query)+1
    matches=[p for p in boundaries if p+len(query) in boundaries and text[p:p+len(query)]==query] if query else []
    for start in [0,1,2,4,9,len(text)-1,len(text),999]:
        for backward in (False,True):
            pos=start if start<candidates else candidates-1 if backward else 0
            order=sorted(matches,key=lambda match: (pos-match if backward else match-pos)%candidates) if matches else []
            expected+=pack(order[0] if order else -1)
            data+=pack(len(query),start,int(backward))+query;cases+=1
search_file=work/'search.document';search_file.write_bytes(text)
execute('unicode-exact-boundary-search',search,bytes(data),bytes(expected),search_file)
check('literal-search-requires-both-cluster-boundaries',True,cases=cases)

# These are authored pixel expectations, not snapshots read from the renderer.
# Five columns by ten rows make accent height, shortened bodies, removed i dots,
# and cedilla rows explicit. Canonical pairs retain distinct input bytes.
font_pixels = {
    'é': ('00010','00100','00000','00000','01110','10001','11111','10000','01111','00000'),
    'e\u0301': ('00010','00100','00000','00000','01110','10001','11111','10000','01111','00000'),
    'Å': ('00100','01010','00100','01110','10001','11111','10001','10001','10001','00000'),
    'ç': ('00000','00000','00000','01111','10000','10000','10000','01111','00100','01000'),
    'í': ('00010','00100','00000','00000','01100','00100','00100','00100','01110','00000'),
    '€': ('00000','00000','00111','01000','11110','01000','11110','01000','00111','00000'),
    '•': ('00000','00000','00000','00000','01110','01110','01110','00000','00000','00000'),
    '👩\u200d💻': ('11111','10001','10001','11011','10101','10101','11011','10001','10001','11111'),
    'a\u0301\u0301': ('11111','10001','10001','11011','10101','10101','11011','10001','10001','11111'),
}
font = compile_program('font-driver', r'''func font_clear(out, at):
 if at == 482: return 0 end
 let cleared = buffer_set(out, at, 0)
 return font_clear(out, at + 1)
end
-- The only replaced boundary is rectangle emission. Captured pixels include
-- padding around the complete cell; invalid rectangles set an error flag.
func x11_rect(out, x, y, width, height):
 if x < 3 or x > 11 or y < 2 or y > 20 or width != 2 or height != 2:
  let bad = buffer_set(out, 1, 1)
  return 0
 end
 let p = 2 + y * 20 + x
 let a = buffer_set(out, p, 1)
 let b = buffer_set(out, p + 1, 1)
 let c = buffer_set(out, p + 20, 1)
 let d = buffer_set(out, p + 21, 1)
 return 0
end
func font_run(input, at, limit, out):
 if at >= limit: return 0 end
 let mode = linux_u64(input, at)
 let count = linux_u64(input, at + 8)
 let start = at + 16
 let stop = start + count
 let cleared = font_clear(out, 0)
 if unicode_display_supported(input, start, stop):
  let supported = buffer_set(out, 0, 1)
 end
 let size = 1
 if mode != 0:
  let drawn = pixel_unicode_cluster(out, input, start, stop, 3, 2, 2)
  size = 482
 end
 let shown = file_write_bytes(1, out, 0, size)
 return font_run(input, stop, limit, out)
end
func main():
 let input = stdin_read()
 let bytes = linux_cstring(input.1)
 let out = linux_buffer(482)
 let run = font_run(bytes, 0, length(input.1), out)
 do process_exit(0)
 return 0
end
''', extra=(root/'lib/pixel_text.herb').read_text()+'\n'+(root/'lib/unicode_display.herb').read_text()+'\n')
# Declare the repertoire independently of the source's classification branches.
font_extras = [0x2013,0x2014,0x2018,0x2019,0x201a,0x201c,0x201d,0x201e,
               0x2022,0x2026,0x20ac,0x2190,0x2191,0x2192,0x2193,0x2194,
               0x2212,0x2260,0x2264,0x2265]
supported_scalars = list(range(32,127))+[cp for cp in range(160,256) if cp!=173]+font_extras
unsupported_scalars = [0,9,10,31,127,159,173,256,0x301,0x4e2d,0x1f600,0x10ffff]
assert len(supported_scalars)==210
data=bytearray();expected=bytearray()
for supported,cps in ((True,supported_scalars),(False,unsupported_scalars)):
    for cp in cps:
        payload=chr(cp).encode();data+=pack(0,len(payload))+payload;expected+=bytes([int(supported)])
for cluster,rows in font_pixels.items():
    assert len(rows)==10 and all(len(row)==5 and set(row)<=set('01') for row in rows)
    payload=cluster.encode();data+=pack(1,len(payload))+payload
    expected+=bytes([int(cluster not in ('👩\u200d💻','a\u0301\u0301')),0])
    # Expand the literal cell at scale2 into a 20x24 canvas with untouched
    # margins. This independently checks every captured pixel and both axes.
    canvas=bytearray(20*24)
    for row,bits in enumerate(rows):
        for col,bit in enumerate(bits):
            if bit=='1':
                for dy in (0,1):
                    for dx in (0,1):canvas[(2+row*2+dy)*20+3+col*2+dx]=1
    expected+=canvas
execute('font-literal-geometry-and-repertoire',font,bytes(data),bytes(expected))
check('font-literal-geometry-repertoire-scale-and-bounds',True,
      supported_scalars=len(supported_scalars),unsupported_scalars=len(unsupported_scalars),pixel_fixtures=len(font_pixels))

# Test the real X11 helper as a pure function: no display or connection is used.
# Core keysyms below0x100 and direct Unicode keysyms have separate valid ranges.
keyscalar = compile_program('keyscalar-driver', r'''func keyscalar_run(input, at, limit, out):
 if at >= limit: return 0 end
 let key = linux_u64(input, at)
 let stored = linux_put64(out, 0, x11_text_scalar(key))
 let shown = file_write_bytes(1, out, 0, 8)
 return keyscalar_run(input, at + 8, limit, out)
end
func main():
 let input = stdin_read()
 let bytes = linux_cstring(input.1)
 let out = linux_buffer(8)
 let run = keyscalar_run(bytes, 0, length(input.1), out)
 do process_exit(0)
 return 0
end
''', extra=(root/'lib/x11.herb').read_text()+'\n')
keyscalar_cases = [(0,-1),(9,-1),(10,-1),(31,-1),(32,32),(126,126),
    (127,-1),(128,-1),(159,-1),(160,160),(233,233),(255,255),(256,-1),
    (0xff0d,-1),(0xff08,-1),(0x07e1,-1),(0x01000000,-1),(0x01000020,-1),
    (0x0100007f,-1),(0x01000080,-1),(0x0100009f,-1),(0x010000ff,-1),
    (0x01000100,0x100),(0x01002014,0x2014),(0x0100d7ff,0xd7ff),
    (0x0100d800,-1),(0x0100dfff,-1),(0x0100e000,0xe000),
    (0x0100ffff,0xffff),(0x01010000,0x10000),(0x0110ffff,0x10ffff),
    (0x01110000,-1),(0x01ffffff,-1),(U64,-1)]
execute('x11-scalar-boundaries',keyscalar,b''.join(pack(key) for key,value in keyscalar_cases),
        b''.join(pack(value) for key,value in keyscalar_cases))
check('x11-core-and-direct-unicode-scalar-boundaries',True,cases=len(keyscalar_cases))

(work/'result.json').write_text(json.dumps(dict(checks=checks,compiler_sha256=seed_sha,
    prelude_sha256=hashlib.sha256(prelude.encode()).hexdigest(),fixture_sha256=fixture_sha,
    reviewed_table_sha256=table_sha),indent=2)+'\n')
print(f'UTF-8/text: {len(checks)} checks passed; evidence: {work}',flush=True)
