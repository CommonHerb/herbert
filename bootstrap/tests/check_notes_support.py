#!/usr/bin/env python3
"""Independent headless Herbert text/file tests; all files belong to scratch."""
if not __debug__:
    raise SystemExit('verification requires Python assertions; remove -O/-OO and PYTHONOPTIMIZE')

from pathlib import Path
import argparse, hashlib, json, os, random, select, shutil, signal, stat, struct, subprocess, tempfile, time
p = argparse.ArgumentParser()
p.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
p.add_argument('--evidence', type=Path)
a = p.parse_args()
root = a.root.resolve()
if shutil.which('strace') is None:
    raise SystemExit('notes support: strace is required for save-failure injection')
seed = (root / 'bootstrap/seed/gen1.seed').read_bytes()
seed_sha = hashlib.sha256(seed).hexdigest()
assert seed_sha == (root / 'bootstrap/seed/gen1.seed.sha256').read_text().split()[0], 'committed seed checksum mismatch'
work = a.evidence or Path(tempfile.mkdtemp(prefix='herbert-notes-support-'))
work.mkdir(exist_ok=True, parents=True)
libs = ['lib/linux.herb', 'lib/file_io.herb', 'lib/text_buffer.herb', 'lib/session_recovery.herb']
prelude = '\n'.join(((root / x).read_text() for x in libs)) + '\n'
checks = []
print(f'notes support evidence: {work}', flush=True)

def compile(name, source):
    d = work / name
    d.mkdir()
    (d / 'compiler').write_bytes(seed)
    (d / 'compiler').chmod(0o700)
    source = source.replace('\\t', '\t')
    (d / 'source.herb').write_text(prelude + source)
    r = subprocess.run(['./compiler'], cwd=d, input=(prelude + source).encode(), capture_output=True, timeout=30)
    (d / 'compile.stdout').write_bytes(r.stdout)
    (d / 'compile.stderr').write_bytes(r.stderr)
    assert r.returncode == 0 and r.stdout == b'0\n' and (not r.stderr), (name, r.stdout, r.stderr)
    exe = d / 'a.out'
    exe.chmod(0o700)
    return exe

def result(name, ok, **extra):
    assert ok, (name, extra)
    checks.append(dict(check=name, **extra))
    print('PASS', name, flush=True)

def stop_owned(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.communicate(timeout=5)

def ready(proc):
    """Bound partial-marker reads too; each helper owns its process group."""
    wanted = b'READY\n'
    marker = b''
    deadline = time.monotonic() + 10
    while marker != wanted:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([proc.stderr], [], [], remaining)[0]:
            stop_owned(proc)
            raise AssertionError('child did not reach READY within ten seconds')
        byte = os.read(proc.stderr.fileno(), 1)
        marker += byte
        if not byte or not wanted.startswith(marker):
            stop_owned(proc)
            raise AssertionError(('unexpected READY marker', marker))

def finish(proc, input_bytes=None):
    try:
        return proc.communicate(input_bytes, timeout=10)
    except subprocess.TimeoutExpired:
        stop_owned(proc)
        raise

basic = compile('file', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let initial = file_status(f)
 let used = file_count(f)
 if initial != 0:
  let closed = file_close(f)
  return (initial, used, 0)
 end
 let bytes = linux_cstring("new\nnotes\t!\n")
 let saved = file_save(f, bytes, 12)
 let closed = file_close(f)
 return (initial, used, saved)
end
""")
new = b'new\nnotes\t!\n'
old = b'old untouched\n'
u = lambda n: str(n % (1 << 64)).encode()

# Newline expectations are constructed from literal bytes and an independent
# logical edit model. Never derive expected file bytes from Herbert's output.
newline = compile('newline-model', r"""func newline_state(t, header, status):
 let a = linux_put64(header, 0, status)
 let b = linux_put64(header, 8, text_length(t))
 let c = linux_put64(header, 16, text_file_length(t))
 let d = linux_put64(header, 24, text_cursor(t))
 let style = 0
 if text_crlf(t): style = 1 end
 let e = linux_put64(header, 32, style)
 let h = file_write_bytes(1, header, 0, 40)
 return file_write_bytes(1, text_file_bytes(t), 0, text_file_length(t))
end
func newline_run(t, commands, at, header):
 if at >= length(commands): return 0 end
 let op = index(commands, at)
 let value = (index(commands, at + 1) - 48) * 100 + (index(commands, at + 2) - 48) * 10 + index(commands, at + 3) - 48
 let changed = 0
 if op == 105: changed = text_insert(t, value)
 elif op == 100: changed = text_delete(t)
 elif op == 98: changed = text_backspace(t)
 elif op == 115: changed = text_seek(t, value)
 elif op == 117: changed = text_undo(t)
 elif op == 114: changed = text_redo(t)
 elif op == 118: changed = text_vertical(t, true, value)
 elif op == 119: changed = text_vertical(t, false, value)
 elif op == 101: changed = text_seek(t, text_length(t))
 end
 let shown = newline_state(t, header, 0)
 return newline_run(t, commands, at + 5, header)
end
func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let t = text_buffer(65536)
 let status = file_status(f)
 if status == 0: status = text_load(t, f.1, file_count(f)) end
 let header = linux_buffer(40)
 let shown = newline_state(t, header, status)
 let commands = stdin_read()
 let run = newline_run(t, commands.1, 0, header)
 let closed = file_close(f)
 do process_exit(0)
 return 0
end
""")

def newline_frame(payload, cursor=0, status=0, style=None):
    if style is None:
        style = b'\r\n' in payload
    logical = payload.replace(b'\r\n', b'\n') if style else payload
    return struct.pack('<QQQQQ', status % (1 << 64), len(logical), len(payload), cursor, int(style)) + payload

# Real repository text copies establish nontrivial round trips. The CRLF
# variants are explicitly made test fixtures; no source file is rewritten.
source_copy = (root/'examples/notes.herb').read_bytes()
roundtrips = [('empty', b''), ('no-newline', b'abc\t~'), ('lf', b'a\nb\n'),
              ('crlf', b'a\r\nb\r\n'), ('crlf-no-final-newline', b'a\r\nb'),
              ('only-crlf', b'\r\n\r\n'), ('repository-lf', source_copy),
              ('repository-crlf', source_copy.replace(b'\n', b'\r\n')),
              ('crlf-capacity', b'\r\n' * 32768), ('lf-capacity', b'\n' * 65536)]
for label, payload in roundtrips:
    d = work/('newline-'+label); d.mkdir(); target = d/'document'; target.write_bytes(payload)
    r = subprocess.run([str(newline), str(target)], input=b'', capture_output=True, timeout=10)
    expected = newline_frame(payload)
    (d/'expected.bin').write_bytes(expected); (d/'actual.bin').write_bytes(r.stdout)
    result('newline-roundtrip-'+label, r.returncode == 0 and not r.stderr and r.stdout == expected and target.read_bytes() == payload)

for label, payload, error in [('mixed-crlf-first', b'a\r\nb\n', -84), ('mixed-lf-first', b'a\nb\r\n', -84),
                              ('bare-cr', b'a\rb', -84), ('trailing-cr', b'abc\r', -84),
                              ('double-cr', b'a\r\r\n', -84), ('nul', b'a\x00\r\n', -84),
                              ('unicode', 'naïve\r\n'.encode(), -84),
                              ('repository-unicode', (root/'docs/BUILDING.md').read_bytes(), -84), ('oversize-crlf', b'\r\n'*32768+b'x', -27)]:
    d=work/('newline-reject-'+label);d.mkdir();target=d/'document';target.write_bytes(payload)
    r=subprocess.run([str(newline),str(target)],input=b'',capture_output=True,timeout=10)
    result('newline-refuses-'+label, r.returncode==0 and not r.stderr and r.stdout==newline_frame(b'',status=error) and target.read_bytes()==payload)

# Exact output after every history state, including deletion of all original
# newlines, redo divergence, ring rollover, and full encoded-byte capacity.
rng = random.Random(20160921)
for label, initial, operations in [
    ('crlf-history', b'alpha\r\nbeta\r\n', [('s',5),('d',0),('u',0),('r',0),('b',0),('u',0)] +
     [('s',0),('d',0)] * 12 + [('i',10),('u',0),('r',0)] +
     [(rng.choice('iidbsuur'), rng.choice([9,10,13,32,65,90,126,255])) for _ in range(1800)]),
    ('crlf-capacity', b'x'*65533+b'\r\n', [('i',10),('i',65),('i',10),('b',0),('i',10),('e',0),('b',0),('i',10),('u',0),('r',0)]),
    ('crlf-full', b'x'*65534+b'\r\n', [('i',65),('i',10),('b',0),('e',0),('b',0),('i',10),('i',65),('u',0),('u',0),('r',0)]),
]:
    d=work/('newline-model-'+label);d.mkdir();target=d/'document';target.write_bytes(initial)
    model=bytearray(initial.replace(b'\r\n', b'\n'));cursor=0;entries=[];applied=0
    expected=bytearray(newline_frame(initial))
    for op,value in operations:
        before=(bytes(model),cursor);changed=False
        width=2 if value==10 else 1
        if op=='i' and len(model)+model.count(10)+width <=65536 and (value in (9,10) or 32<=value<=126):
            model[cursor:cursor]=bytes([value]);cursor+=1;changed=True
        elif op=='d' and cursor<len(model):del model[cursor];changed=True
        elif op=='b' and cursor:cursor-=1;del model[cursor];changed=True
        elif op=='s':cursor=min(value,len(model))
        elif op=='e':cursor=len(model)
        elif op=='u' and applied:
            applied-=1;content,cursor=entries[applied][0];model=bytearray(content)
        elif op=='r' and applied<len(entries):
            content,cursor=entries[applied][1];model=bytearray(content);applied+=1
        if changed:
            entries=(entries[:applied]+[(before,(bytes(model),cursor))])[-256:];applied=len(entries)
        expected+=newline_frame(bytes(model).replace(b'\n',b'\r\n'),cursor=cursor,style=True)
    commands=''.join(f'{op}{value:03d}\n' for op,value in operations).encode()
    r=subprocess.run([str(newline),str(target)],input=commands,capture_output=True,timeout=10)
    (d/'commands').write_bytes(commands);(d/'expected.bin').write_bytes(expected);(d/'actual.bin').write_bytes(r.stdout)
    result('newline-independent-'+label,r.returncode==0 and not r.stderr and r.stdout==expected and target.read_bytes()==initial,operations=len(operations))

# CRLF decoding must preserve the existing logical navigation contract.
d=work/'newline-navigation';d.mkdir();target=d/'document'
payload=b'abcde\r\nX\r\n\tdefgh\r\nend';target.write_bytes(payload)
commands=b's004\nv001\nv001\nw002\n'
r=subprocess.run([str(newline),str(target)],input=commands,capture_output=True,timeout=10)
expected=b''.join(newline_frame(payload,cursor=pos) for pos in (0,4,7,9,4))
result('newline-crlf-navigation-short-lines-tabs',r.returncode==0 and not r.stderr and r.stdout==expected)

# A failed load must retain style, bytes, cursor AND the prior undo history.
rejected_load = compile('newline-rejected-load', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 16)
 let t = text_buffer(16)
 let bytes = linux_cstring("a\nb")
 let cr = buffer_set(bytes, 1, 13)
 let lf = buffer_set(bytes, 2, 10)
 let loaded = text_load(t, bytes, 3)
 let moved = text_seek(t, 2)
 let inserted = text_insert(t, 88)
 let status = text_load(t, f.1, file_count(f))
 let samecursor = text_cursor(t)
 let undone = text_undo(t)
 let shown = file_write_bytes(1, text_file_bytes(t), 0, text_file_length(t))
 let closed = file_close(f)
 return (status, samecursor, undone, text_file_length(t), text_cursor(t))
end
""")
for label,payload in [('mixed',b'a\r\nb\n'),('bare',b'a\r'),('unicode',b'a\xff')]:
    d=work/('newline-retain-'+label);d.mkdir();target=d/'document';target.write_bytes(payload)
    r=subprocess.run([str(rejected_load),str(target)],capture_output=True,timeout=10)
    expected=b'a\r\n('+u(-84)+b', 3, 1, 3, 2)\n'
    result('newline-rejected-load-retains-'+label,r.returncode==0 and not r.stderr and r.stdout==expected)

newline_save = compile('newline-save', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let t = text_buffer(65536)
 let loaded = text_load(t, f.1, file_count(f))
 let recovery = recovery_new(65536)
 let mode = linux_argument(args, 2)
 let first = 0
 if equal(mode, "recovery"):
  first = recovery_save(recovery, f, text_file_bytes(t), text_file_length(t))
 end
 let finish = text_seek(t, text_length(t))
 if not equal(mode, "roundtrip"):
  let line = text_insert(t, 10)
  let inserted = text_insert(t, 33)
 end
 let saved = 0
 if equal(mode, "save") or equal(mode, "roundtrip"): saved = file_save(f, text_file_bytes(t), text_file_length(t))
 elif equal(mode, "copy"): saved = file_save_copy(f, text_file_bytes(t), text_file_length(t))
 else: saved = recovery_save(recovery, f, text_file_bytes(t), text_file_length(t))
 end
 let closedrecovery = recovery_close(recovery)
 let closed = file_close(f)
 return (loaded, first, saved)
end
""")
for label,payload in [('lf',source_copy),('crlf',source_copy.replace(b'\n',b'\r\n'))]:
    d=work/('newline-save-repository-'+label);d.mkdir();target=d/'document';target.write_bytes(payload)
    r=subprocess.run([str(newline_save),str(target),'roundtrip'],capture_output=True,timeout=10)
    result('newline-file-save-repository-'+label,r.returncode==0 and not r.stderr and r.stdout==b'(0, 0, 0)\n' and target.read_bytes()==payload)

for mode in ('save','copy','recovery'):
    for faultlabel,fault,expected in [('success',None,0),('prepublication','fsync:error=EIO:when='+('4' if mode=='recovery' else '1'),-5),('postpublication','fsync:error=EIO:when='+('5' if mode=='recovery' else '2'),1)]:
        d=work/f'newline-{mode}-{faultlabel}';d.mkdir();target=d/'document';payload=b'original\r\ntext';target.write_bytes(payload)
        before=target.stat();command=[str(newline_save),str(target),mode]
        if fault:command=['strace','-o',str(d/'strace.log'),'-e','inject='+fault]+command
        r=subprocess.run(command,capture_output=True,timeout=10)
        expected_output=b'(0, 0, '+u(expected)+b')\n'
        assert r.returncode==0 and not r.stderr and r.stdout==expected_output,(mode,faultlabel,r.stdout,r.stderr)
        wanted=payload+b'\r\n!'
        if mode=='save':assert target.read_bytes()==(payload if expected<0 else wanted)
        else:
            assert target.read_bytes()==payload and target.stat().st_ino==before.st_ino
            copies=list(d.glob('herbert-rescue-*.txt' if mode=='copy' else '.herbert-notes-*/recovery.txt'))
            if mode=='copy' and expected<0:assert not copies
            else:assert len(copies)==1 and copies[0].read_bytes()==(payload if expected<0 else wanted)
        assert not list(d.rglob('.herbert-save-*.tmp'))
        result(f'newline-{mode}-{faultlabel}-exact-bytes',True)


def run_file(label, initial='regular', fault=None, expected=0):
    d = work / ('case-' + label)
    d.mkdir()
    target = d / 'document.txt'
    other = d / 'other.txt'
    if initial == 'regular':
        target.write_bytes(old)
        target.chmod(0o640)
    elif initial == 'symlink':
        other.write_bytes(old)
        target.symlink_to(other.name)
    elif initial == 'directory':
        target.mkdir()
    elif initial == 'fifo':
        os.mkfifo(target)
    elif initial == 'hardlink':
        other.write_bytes(old)
        os.link(other, target)
    elif initial == 'oversize':
        target.write_bytes(b'x' * 65537)
    elif initial == 'exact':
        target.write_bytes(b'x' * 65536)
        target.chmod(0o644)
    before = target.stat() if initial in ('regular', 'exact') else None
    argv = [str(basic), str(target)]
    if fault:
        argv = ['strace', '-o', str(d / 'strace.log'), '-e', 'inject=' + fault] + argv
    r = subprocess.run(argv, capture_output=True, timeout=10)
    (d / 'stdout').write_bytes(r.stdout)
    (d / 'stderr').write_bytes(r.stderr)
    assert r.returncode == 0 and (not r.stderr), (label, r.returncode, r.stderr)
    values = [int(v.strip()) for v in r.stdout.strip().strip(b'()').split(b',')]
    if initial in ('symlink', 'directory', 'fifo', 'hardlink', 'oversize'):
        assert values[0] == expected % (1 << 64), (label, values, expected)
        if initial == 'symlink':
            assert target.is_symlink() and other.read_bytes() == old
        if initial == 'hardlink':
            assert target.stat().st_nlink == 2 and target.read_bytes() == old
    else:
        assert values[2] == expected % (1 << 64), (label, values, expected)
        if expected == 0 or expected == 1:
            assert target.read_bytes() == new, (label, target.read_bytes())
        elif initial == 'regular':
            assert target.read_bytes() == old and (target.stat().st_dev, target.stat().st_ino) == (before.st_dev, before.st_ino)
        else:
            assert not target.exists()
        if expected == 0:
            assert stat.S_IMODE(target.stat().st_mode) == (416 if initial == 'regular' else 420 if initial == 'exact' else 384)
    assert not list(d.glob('.herbert-save-*.tmp')), (label, 'temp not cleaned')
    result(label, True, output=r.stdout.decode().strip())
run_file('create', 'missing')
run_file('replace')
run_file('exact-capacity', 'exact')
for kind, err in [('symlink', -40), ('directory', -22), ('fifo', -22), ('hardlink', -31), ('oversize', -27)]:
    run_file('reject-' + kind, kind, expected=err)
for label, fault, err in [('write-error', 'write:error=ENOSPC:when=1', -28), ('mode-error', 'fchmod:error=EPERM:when=1', -1), ('file-sync-error', 'fsync:error=EIO:when=1', -5), ('rename-error', 'renameat:error=EACCES:when=1', -13), ('close-error', 'close:error=EIO:when=3', -5)]:
    run_file(label, fault=fault, expected=err)
run_file('new-publication-error', 'missing', fault='renameat2:error=ENOSYS:when=1', expected=-38)
run_file('post-publication-sync', 'regular', fault='fsync:error=EIO:when=2', expected=1)
run_file('post-publication-stat', 'regular', fault='newfstatat:error=EIO:when=5', expected=1)
retry = compile('retry', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let bytes = linux_cstring("new\nnotes\t!\n")
 let first = file_save(f, bytes, 12)
 let second = file_save(f, bytes, 12)
 let closed = file_close(f)
 return (first, second)
end
""")
d = work / 'case-retry'
d.mkdir()
target = d / 'document'
target.write_bytes(old)
r = subprocess.run(['strace', '-o', str(d / 'strace.log'), '-e', 'inject=fsync:error=EIO:when=2', str(retry), str(target)], capture_output=True, timeout=10)
result('retry-after-directory-sync-error', r.returncode == 0 and not r.stderr and r.stdout == b'(1, 0)\n' and target.read_bytes() == new, output=r.stdout.decode())
d = work / 'case-stat-retry'
d.mkdir()
target = d / 'document'
target.write_bytes(old)
r = subprocess.run(['strace', '-o', str(d / 'strace.log'), '-e', 'inject=newfstatat:error=EIO:when=5', str(retry), str(target)], capture_output=True, timeout=10)
result('retry-after-post-publication-stat-error', r.returncode == 0 and not r.stderr and r.stdout == b'(1, 0)\n' and target.read_bytes() == new, output=r.stdout.decode())
# Same-size contents with restored mtime must still fail recovery's byte check.
recovery_conflict = compile('recovery-conflict', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let bytes = linux_cstring("new\nnotes\t!\n")
 let first = file_save(f, bytes, 12)
 let ready = stderr_write("READY\n")
 let wait = stdin_read()
 let second = file_save(f, bytes, 12)
 let closed = file_close(f)
 return (first, second)
end
""")
d = work / 'case-recovery-conflict'
d.mkdir()
target = d / 'document'
target.write_bytes(old)
proc = subprocess.Popen(['strace', '-o', str(d / 'strace.log'), '-e', 'inject=newfstatat:error=EIO:when=5', str(recovery_conflict), str(target)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
ready(proc)
before = target.stat()
target.write_bytes(b'BAD\nnotes\t!\n')
os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns))
out, err = finish(proc, b'\n')
result('recovery-refuses-changed-bytes-with-restored-mtime', proc.returncode == 0 and not err and out == b'(1, ' + u(-116) + b')\n' and target.read_bytes() == b'BAD\nnotes\t!\n', output=out.decode())
conflict = compile('conflict', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let ready = stderr_write("READY\n")
 let wait = stdin_read()
 let bytes = linux_cstring("new\nnotes\t!\n")
 let saved = file_save(f, bytes, 12)
 let closed = file_close(f)
 return saved
end
""")
for label, exists in [('changed', True), ('appeared', False), ('symlink-replacement', True)]:
    d = work / ('case-conflict-' + label)
    d.mkdir()
    target = d / 'document'
    if exists:
        target.write_bytes(old)
    proc = subprocess.Popen([str(conflict), str(target)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    ready(proc)
    if label == 'symlink-replacement':
        target.unlink()
        other = d / 'other'
        other.write_bytes(b'outside')
        target.symlink_to(other.name)
    else:
        target.write_bytes(b'outside')
    out, err = finish(proc, b'\n')
    expected = {'changed': -116, 'appeared': -17, 'symlink-replacement': -40}[label]
    result('conflict-' + label, proc.returncode == 0 and not err and out == u(expected) + b'\n' and target.read_bytes() == b'outside' and (not list(d.glob('.herbert-save-*.tmp'))), output=out.decode())
# Rescue copies bypass the conflicted original, without changing its baseline.
rescue = compile('rescue-copy', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let bytes = linux_cstring("rescued\n")
 let ready = stderr_write("READY\n")
 let wait = stdin_read()
 let copied = file_save_copy(f, bytes, 8)
 let conflict = file_conflict(f)
 let closed = file_close(f)
 return (copied, conflict)
end
""")

def rescue_case(label, *, conflict=False, collisions=0, fault=None, expected=0):
    d = work / ('case-rescue-' + label)
    d.mkdir()
    target = d / 'document.txt'
    target.write_bytes(old)
    command = [str(rescue), str(target)]
    if fault:
        command = ['strace', '--kill-on-exit', '-o', str(d/'strace.log'), '-e', 'inject='+fault] + command
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    ready(proc)
    preserved = {}
    for serial in range(1, collisions + 1):
        name = d / f'herbert-rescue-{proc.pid}-{serial}.txt'
        name.write_bytes(b'preexisting rescue')
        preserved[name] = name.read_bytes()
    if conflict:
        target.write_bytes(b'external edit\n')
    before = target.stat()
    before_bytes = target.read_bytes()
    out, err = finish(proc, b'\n')
    expected_conflict = -116 if conflict else 0
    assert proc.returncode == 0 and not err and out == b'(' + u(expected) + b', ' + u(expected_conflict) + b')\n', (label, out, err)
    assert target.read_bytes() == before_bytes and target.stat().st_ino == before.st_ino
    assert all(path.read_bytes() == content for path, content in preserved.items())
    created = set(d.glob('herbert-rescue-*.txt')) - set(preserved)
    if expected in (0, 1):
        assert len(created) == 1
        copy = created.pop()
        assert copy.read_bytes() == b'rescued\n' and stat.S_IMODE(copy.stat().st_mode) == 0o600
        if collisions:
            assert copy.name == f'herbert-rescue-{proc.pid}-{collisions + 1}.txt'
    else:
        assert not created
    assert not list(d.glob('.herbert-save-*.tmp'))
    result('rescue-' + label, True, output=out.decode())

rescue_case('source-unchanged')
rescue_case('conflict-retained', conflict=True)
rescue_case('existing-copy-not-overwritten', collisions=1)
rescue_case('bounded-collision-refusal', collisions=32, expected=-17)
# READY is write #1; the rescue's content write is #2.
rescue_case('write-failure', fault='write:error=ENOSPC:when=2', expected=-28)
rescue_case('file-sync-failure', fault='fsync:error=EIO:when=1', expected=-5)
rescue_case('publication-failure', fault='renameat2:error=EIO:when=1', expected=-5)
rescue_case('directory-sync-warning', fault='fsync:error=EIO:when=2', expected=1)
copy_recovery = compile('copy-during-recovery', r"""func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let bytes = linux_cstring("new\nnotes\t!\n")
 let first = file_save(f, bytes, 12)
 let copied = file_save_copy(f, bytes, 12)
 let second = file_save(f, bytes, 12)
 let closed = file_close(f)
 return (first, copied, second)
end
""")
d = work/'case-copy-during-recovery'
d.mkdir()
target = d/'document.txt'
target.write_bytes(old)
r = subprocess.run(['strace', '--kill-on-exit', '-o', str(d/'strace.log'), '-e', 'inject=newfstatat:error=EIO:when=5', str(copy_recovery), str(target)], capture_output=True, timeout=10)
copies = list(d.glob('herbert-rescue-*.txt'))
result('rescue-preserves-uncertain-original-recovery', r.returncode == 0 and not r.stderr and r.stdout == b'(1, 0, 0)\n' and target.read_bytes() == new and len(copies) == 1 and copies[0].read_bytes() == new, output=r.stdout.decode())

# Independent Python edit model; the expected bytes are never supplied by Herbert.
rng = random.Random(8675309)
model = bytearray()
cursor = 0
lines = ['func main():', ' let t = text_buffer(128)', ' let r = 0']
ops = []
for i in range(700):
    op = rng.choice(['insert', 'insert', 'delete', 'backspace', 'seek'])
    if op == 'insert':
        ch = rng.choice([9, 10, 32, 33, 65, 90, 97, 126])
        lines.append(f' r = text_insert(t, {ch})')
        ops.append([op, ch])
        if len(model) < 128:
            model[cursor:cursor] = bytes([ch])
            cursor += 1
    elif op == 'delete':
        lines.append(' r = text_delete(t)')
        ops.append([op])
        if cursor < len(model):
            del model[cursor]
    elif op == 'backspace':
        lines.append(' r = text_backspace(t)')
        ops.append([op])
        if cursor > 0:
            cursor -= 1
            del model[cursor]
    else:
        pos = rng.randrange(len(model) + 3)
        lines.append(f' r = text_seek(t, {pos})')
        ops.append([op, pos])
        cursor = min(pos, len(model))
lines += [' let header = linux_buffer(16)', ' let a = linux_put64(header, 0, text_length(t))', ' let b = linux_put64(header, 8, text_cursor(t))', ' let h = linux_syscall6(1, 1, buffer_address(header), 16, 0, 0, 0)', ' let body = linux_syscall6(1, 1, buffer_address(t.0), text_length(t), 0, 0, 0)', ' do process_exit(0)', ' return 0', 'end']
exe = compile('random-text', '\n'.join(lines))
r = subprocess.run([str(exe)], capture_output=True, timeout=10)
(work / 'random-text/operations.json').write_text(json.dumps(ops))
(work / 'random-text/actual.bin').write_bytes(r.stdout)
expected = struct.pack('<QQ', len(model), cursor) + model
(work / 'random-text/expected.bin').write_bytes(expected)
result('random-edit-model-700-operations', r.returncode == 0 and r.stdout == expected and (not r.stderr), length=len(model), cursor=cursor)
nav = compile('navigation', r"""func main():
 let t = text_buffer(64)
 let b = linux_cstring("abcde\nX\n\tdefgh\nend")
 let a = text_load(t, b, 18)
 let start = text_seek(t, 4)
 let down = text_vertical(t, true, 1)
 let p1 = text_cursor(t)
 let down2 = text_vertical(t, true, 1)
 let p2 = text_cursor(t)
 let up = text_vertical(t, false, 2)
 let p3 = text_cursor(t)
 let end = text_seek(t, 999)
 let row = text_row(t, text_cursor(t))
 return (a, p1, p2, p3, text_length(t), row)
end
""".replace('let end =', 'let finish ='))
r = subprocess.run([str(nav)], capture_output=True, timeout=10)
result('vertical-short-lines-and-tabs', r.stdout == b'(0, 7, 9, 4, 18, 3)\n', output=r.stdout.decode())
# Rejected edits/loads must retain the existing document.
bounds = compile('bounds', r"""func main():
 let t = text_buffer(3)
 let a = text_insert(t, 65)
 let b = text_insert(t, 66)
 let c = text_insert(t, 67)
 let overflow = text_insert(t, 68)
 let invalid = text_insert(t, 255)
 let dirty = linux_buffer(1)
 let byte = buffer_set(dirty, 0, 128)
 let badload = text_load(t, dirty, 1)
 let long = linux_cstring("long")
 let longload = text_load(t, long, 4)
 let moved = text_seek(t, 0)
 let back = text_backspace(t)
 let finish = text_seek(t, 999)
 let forward = text_delete(t)
 return (overflow, invalid, badload, longload, back, forward, text_length(t), buffer_get(t.0, 0), buffer_get(t.0, 1), buffer_get(t.0, 2))
end
""")
r = subprocess.run([str(bounds)], capture_output=True, timeout=10)
expected = b'(0, 0, ' + u(-84) + b', ' + u(-27) + b', 0, 0, 3, 65, 66, 67)\n'
result('capacity-invalid-load-and-endpoints', r.stdout == expected, output=r.stdout.decode())

# Exercise every intermediate history state against an independent snapshot model.
history = compile('history-model', r"""func history_run(t, commands, at, header):
 if at >= length(commands): return 0 end
 let op = index(commands, at)
 let value = (index(commands, at + 1) - 48) * 100 + (index(commands, at + 2) - 48) * 10 + index(commands, at + 3) - 48
 let changed = 0
 if op == 105: changed = text_insert(t, value)
 elif op == 100: changed = text_delete(t)
 elif op == 98: changed = text_backspace(t)
 elif op == 115: changed = text_seek(t, value)
 elif op == 117: changed = text_undo(t)
 elif op == 114: changed = text_redo(t)
 end
 let a = linux_put64(header, 0, text_length(t))
 let b = linux_put64(header, 8, text_cursor(t))
 let h = file_write_bytes(1, header, 0, 16)
 let body = file_write_bytes(1, t.0, 0, text_length(t))
 return history_run(t, commands, at + 5, header)
end
func main():
 let t = text_buffer(128)
 let commands = stdin_read()
 let header = linux_buffer(16)
 let run = history_run(t, commands.1, 0, header)
 do process_exit(0)
 return 0
end
""")
rng = random.Random(73109)
operations = [('i', 65)] * 130 + [('u', 0)] * 3 + [('r', 0)] * 4 + [('b', 0)] * 130
operations += [('i', 65), ('b', 0)] * 300 + [('u', 0)] * 270 + [('r', 0)] * 270
operations += [(rng.choice('iidbsuur'), rng.choice([9,10,32,65,90,97,126,129])) for _ in range(2200)]
model, cursor, entries, applied = bytearray(), 0, [], 0
expected = bytearray()
for op, value in operations:
    before = (bytes(model), cursor)
    changed = False
    if op == 'i' and len(model) < 128 and (value in (9,10) or 32 <= value <= 126):
        model[cursor:cursor] = bytes([value]); cursor += 1; changed = True
    elif op == 'd' and cursor < len(model):
        del model[cursor]; changed = True
    elif op == 'b' and cursor:
        cursor -= 1; del model[cursor]; changed = True
    elif op == 's':
        cursor = min(value, len(model))
    elif op == 'u' and applied:
        applied -= 1
        content, cursor = entries[applied][0]
        model = bytearray(content)
    elif op == 'r' and applied < len(entries):
        content, cursor = entries[applied][1]
        model = bytearray(content); applied += 1
    if changed:
        entries = entries[:applied] + [(before, (bytes(model), cursor))]
        entries = entries[-256:]; applied = len(entries)
    expected += struct.pack('<QQ', len(model), cursor) + model
commands = ''.join(f'{op}{value:03d}\n' for op,value in operations).encode()
r = subprocess.run([str(history)], input=commands, capture_output=True, timeout=10)
(work/'history-model/commands').write_bytes(commands)
(work/'history-model/actual.bin').write_bytes(r.stdout)
(work/'history-model/expected.bin').write_bytes(expected)
result('undo-redo-independent-model-every-intermediate-state', r.returncode == 0 and not r.stderr and r.stdout == expected, operations=len(operations))

# Search oracle enumerates positions directly, including empty/oversized query,
# wrap, overlap, case sensitivity, absent matches and starts past the last match.
search_text = 'ababa ABABA xy ababa'
search_cases = [(q, start, backward) for q in ['', 'a', 'aba', 'ABA', 'z', search_text+'!']
                for start in [0,1,4,18,99] for backward in [False,True]]
lines = ['func emit_find(t, query, count, start, backward, out):',
         ' let saved = linux_put64(out, 0, text_find(t, query, count, start, backward))',
         ' return file_write_bytes(1, out, 0, 8)', 'end', 'func main():',
         ' let t = text_buffer(64)', f' let bytes = linux_cstring("{search_text}")',
         f' let loaded = text_load(t, bytes, {len(search_text)})', ' let out = linux_buffer(8)']
expected = bytearray()
for i,(query,start,backward) in enumerate(search_cases):
    lines += [f' let q{i} = linux_cstring("{query}")',
              f' let r{i} = emit_find(t, q{i}, {len(query)}, {start}, {str(backward).lower()}, out)']
    candidates = len(search_text)-len(query)+1
    found = -1
    if query and candidates > 0:
        pos = start if start < candidates else candidates-1 if backward else 0
        for step in range(candidates):
            p = (pos + (-step if backward else step)) % candidates
            if search_text.startswith(query,p): found=p;break
    expected += struct.pack('<Q', found % (1<<64))
lines += [' do process_exit(0)', ' return 0', 'end']
exe = compile('search-model','\n'.join(lines))
r = subprocess.run([str(exe)],capture_output=True,timeout=10)
(work/'search-model/actual.bin').write_bytes(r.stdout)
(work/'search-model/expected.bin').write_bytes(expected)
result('literal-search-60-independent-forward-backward-cases', r.returncode == 0 and not r.stderr and r.stdout == expected, cases=len(search_cases))

reset = compile('history-load-reset', r"""func main():
 let t = text_buffer(8)
 let inserted = text_insert(t, 65)
 let undo = text_undo(t)
 let bytes = linux_cstring("loaded")
 let loaded = text_load(t, bytes, 6)
 return (loaded, text_undo(t), text_redo(t), text_length(t), text_cursor(t))
end
""")
r = subprocess.run([str(reset)],capture_output=True,timeout=10)
result('load-clears-undo-and-redo-history',r.returncode==0 and not r.stderr and r.stdout==b'(0, 0, 0, 6, 0)\n')

checkpoint = compile('session-recovery', r"""func main():
 let args = linux_arguments()
 let original = file_open(linux_argument(args, 1), 65536)
 let recovery = recovery_new(65536)
 let firstbytes = linux_cstring("first checkpoint\n")
 let nextbytes = linux_cstring("second checkpoint\n")
 let first = recovery_save(recovery, original, firstbytes, 17)
 let ready = stderr_write("READY\n")
 let wait = stdin_read()
 let second = recovery_save(recovery, original, nextbytes, 18)
 let closed = recovery_close(recovery)
 let closedfile = file_close(original)
 return (first, second)
end
""")

def checkpoint_case(label, fault=None, first=0, second=0, mask=0):
    d = work/('case-session-'+label); d.mkdir()
    target=d/'document.txt'; target.write_bytes(old)
    command=[str(checkpoint),str(target)]
    if fault: command=['strace','--kill-on-exit','-o',str(d/'strace.log'),'-e','inject='+fault]+command
    proc=subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True, umask=mask)
    ready(proc)
    dirs=list(d.glob('.herbert-notes-*'))
    snapshots=[directory/'recovery.txt' for directory in dirs]
    before={path:path.read_bytes() for path in snapshots if path.exists()} if first in (0,1) else {}
    out,err=finish(proc,b'\n')
    (d/'stdout').write_bytes(out);(d/'stderr').write_bytes(err)
    assert proc.returncode==0 and not err and out == b'('+u(first)+b', '+u(second)+b')\n', (label,out,err)
    assert target.read_bytes()==old
    assert len(list(d.glob('.herbert-notes-*'))) <= 1, 'retry created multiple session directories'
    if first==0 and second not in (0,1):
        assert all(path.read_bytes()==body for path,body in before.items()), label
    if second in (0,1):
        snapshots=list(d.glob('.herbert-notes-*/recovery.txt'))
        assert len(snapshots)==1 and snapshots[0].read_bytes()==b'second checkpoint\n'
        assert stat.S_IMODE(snapshots[0].stat().st_mode)==0o600
        assert stat.S_IMODE(snapshots[0].parent.stat().st_mode)==0o700
    directories=list(d.glob('.herbert-notes-*'))
    modes=[stat.S_IMODE(directory.stat().st_mode) for directory in directories]
    if mask:assert modes==[0o700 & ~mask], (label,modes)
    result('session-'+label,True,output=out.decode(),created_directory_modes=[oct(mode) for mode in modes])
    # These are this harness's empty refused directories. Record their tested
    # modes above, then make retained evidence traversable for later inspection.
    for directory,mode in zip(directories,modes):
        if mode!=0o700:directory.chmod(0o700)

checkpoint_case('private-reusable-copy')
# First checkpoint: file fsync #1, session directory #2, original directory #3.
checkpoint_case('write-failure-retains-prior', 'write:error=ENOSPC:when=3',second=-28)
checkpoint_case('file-sync-failure-retains-prior','fsync:error=EIO:when=4',second=-5)
checkpoint_case('rename-failure-retains-prior','renameat:error=EIO:when=1',second=-5)
checkpoint_case('directory-sync-warning','fsync:error=EIO:when=5',second=1)
checkpoint_case('parent-sync-warning-retry','fsync:error=EIO:when=3',first=1)
checkpoint_case('startup-create-refusal-retry','mkdirat:error=EACCES:when=1',first=-13)
checkpoint_case('open-after-mkdir-failure-bounded','openat:error=EMFILE:when=2+',first=-24,second=-24)
checkpoint_case('stat-after-mkdir-failure-bounded','fstat:error=EIO:when=3+',first=-5,second=-5)
checkpoint_case('restrictive-umask-refusal-bounded',first=-13,second=-13,mask=0o100)

# Same-user external edits must fail closed without changing that version.
d=work/'case-session-external';d.mkdir();target=d/'document';target.write_bytes(old)
proc=subprocess.Popen([str(checkpoint),str(target)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
ready(proc);snapshot=next(d.glob('.herbert-notes-*/recovery.txt'));snapshot.write_bytes(b'external')
out,err=finish(proc,b'\n')
result('session-external-change-refused',proc.returncode==0 and not err and out==b'(0, '+u(-116)+b')\n' and snapshot.read_bytes()==b'external' and target.read_bytes()==old)
# Holding both parent and session descriptors survives an unrelated pathname move.
d=work/'case-session-parent-move';d.mkdir();parent=d/'parent';parent.mkdir();target=parent/'document';target.write_bytes(old)
proc=subprocess.Popen([str(checkpoint),str(target)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
ready(proc);moved=d/'moved';parent.rename(moved);parent.mkdir();(parent/'document').write_bytes(b'unrelated')
out,err=finish(proc,b'\n')
result('session-descriptor-relative-after-parent-move',proc.returncode==0 and not err and out==b'(0, 0)\n' and next(moved.glob('.herbert-notes-*/recovery.txt')).read_bytes()==b'second checkpoint\n' and (parent/'document').read_bytes()==b'unrelated')

# Exclusive session names skip existing directories and symlinks without touch.
collision = compile('session-collision', r"""func main():
 let args = linux_arguments()
 let original = file_open(linux_argument(args, 1), 65536)
 let recovery = recovery_new(65536)
 let bytes = linux_cstring("checkpoint")
 let ready = stderr_write("READY\n")
 let wait = stdin_read()
 let saved = recovery_save(recovery, original, bytes, 10)
 let closed = recovery_close(recovery)
 let closedfile = file_close(original)
 return saved
end
""")
for count in (1,32):
 d=work/f'case-session-collisions-{count}';d.mkdir();target=d/'document';target.write_bytes(old)
 outside=d/'outside';outside.mkdir();(outside/'recovery.txt').write_bytes(b'untouched')
 proc=subprocess.Popen([str(collision),str(target)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
 ready(proc)
 for serial in range(1,count+1):(d/f'.herbert-notes-{proc.pid}-{serial}').symlink_to(outside.name)
 out,err=finish(proc,b'\n')
 expected=0 if count==1 else -17
 assert proc.returncode==0 and not err and out==u(expected)+b'\n'
 assert (outside/'recovery.txt').read_bytes()==b'untouched' and target.read_bytes()==old
 if count==1:assert (d/f'.herbert-notes-{proc.pid}-2/recovery.txt').read_bytes()==b'checkpoint'
 result(f'session-exclusive-collision-bound-{count}',True)

# A replacement session symlink is refused; the referent remains unchanged.
d=work/'case-session-symlink';d.mkdir();target=d/'document';target.write_bytes(old)
proc=subprocess.Popen([str(checkpoint),str(target)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
ready(proc);snapshot=next(d.glob('.herbert-notes-*/recovery.txt'));prior=snapshot.read_bytes()
snapshot.rename(snapshot.with_name('first-preserved.txt'));outside=d/'outside';outside.write_bytes(b'untouched');snapshot.symlink_to(outside)
out,err=finish(proc,b'\n')
result('session-symlink-replacement-refused',proc.returncode==0 and not err and out==b'(0, '+u(-40)+b')\n' and outside.read_bytes()==b'untouched' and snapshot.with_name('first-preserved.txt').read_bytes()==prior)

# Warm and sample the actual history/search/checkpoint path at full document size.
recovery_reuse = compile('session-reuse', r"""func run(original, recovery, text, query, poll, left, sampling):
 if left == 0: return 0 end
 let start = text_seek(text, 0)
 let deleted = text_delete(text)
 let undo = text_undo(text)
 let redo = text_redo(text)
 let undo2 = text_undo(text)
 let found = text_find(text, query, 1, 0, false)
 if found != 0: return linux_die("search failed\n") end
 let saved = recovery_save(recovery, original, text_file_bytes(text), text_file_length(text))
 if saved != 0: return linux_die("checkpoint failed\n") end
 if sampling: let wait = linux_poll(0 - 1, poll, 0, 2) end
 return run(original, recovery, text, query, poll, left - 1, sampling)
end
func main():
 let args = linux_arguments()
 let original = file_open(linux_argument(args, 1), 65536)
 let recovery = recovery_new(65536)
 let text = text_buffer(65536)
 let loaded = text_load(text, original.1, file_count(original))
 let query = linux_cstring("A")
 let poll = linux_buffer(8)
 let warm = run(original, recovery, text, query, poll, 300, false)
 let ready = stderr_write("READY\n")
 let sampled = run(original, recovery, text, query, poll, 2000, true)
 let closed = recovery_close(recovery)
 let closedfile = file_close(original)
 return 0
end
""")
d=work/'case-session-reuse';d.mkdir();target=d/'document';target.write_bytes(b'A'*65534+b'\r\n')
proc=subprocess.Popen([str(recovery_reuse),str(target)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
ready(proc);samples=[];started=time.monotonic()
while proc.poll() is None:
 if time.monotonic()-started>60:stop_owned(proc);raise AssertionError('session endurance exceeded 60 seconds')
 try:
  fields={line.split(':',1)[0]:line.split(':',1)[1].strip() for line in Path(f'/proc/{proc.pid}/status').read_text().splitlines() if ':' in line}
  rollup={line.split(':',1)[0]:line.split(':',1)[1].strip() for line in Path(f'/proc/{proc.pid}/smaps_rollup').read_text().splitlines() if ':' in line}
  if 'Rss' in rollup and 'VmSize' in fields:samples.append(dict(seconds=round(time.monotonic()-started,3),rss_kib=int(rollup['Rss'].split()[0]),vmsize_kib=int(fields['VmSize'].split()[0])))
 except (FileNotFoundError,ProcessLookupError):pass
 time.sleep(.1)
out,err=finish(proc);(d/'memory.json').write_text(json.dumps(samples,indent=2)+'\n')
snapshot=next(d.glob('.herbert-notes-*/recovery.txt'))
assert proc.returncode==0 and not err and out==b'0\n' and snapshot.read_bytes()==b'A'*65534+b'\r\n' and target.read_bytes()==b'A'*65534+b'\r\n'
rss=[s['rss_kib'] for s in samples];vm=[s['vmsize_kib'] for s in samples]
result('session-2000-full-capacity-crlf-checkpoints-undo-redo-search-bounded-memory',len(samples)>=20 and max(rss)-min(rss)<=64 and max(vm)==min(vm),seconds=round(time.monotonic()-started,3),samples=len(samples),rss_min_kib=min(rss),rss_max_kib=max(rss),vmsize_kib=vm[0])

# Sample steady-state memory after warmup across 4,000 real save transactions.
reuse = compile('reuse', r"""func cycle(f, t, poll, left, sampling):
 if left == 0: return 0 end
 let start = text_seek(t, 0)
 let insert = text_insert(t, 65)
 let back = text_backspace(t)
 let saved = file_save(f, text_file_bytes(t), text_file_length(t))
 if saved != 0: return linux_die("save failed\n") end
 if sampling:
  let waited = linux_poll(0 - 1, poll, 0, 2)
 end
 return cycle(f, t, poll, left - 1, sampling)
end
func main():
 let args = linux_arguments()
 let f = file_open(linux_argument(args, 1), 65536)
 let t = text_buffer(65536)
 let b = linux_cstring("Stable notes.\n")
 let loaded = text_load(t, b, 14)
 let poll = linux_buffer(8)
 let warmup = cycle(f, t, poll, 100, false)
 let ready = stderr_write("READY\n")
 let run = cycle(f, t, poll, 4000, true)
 let closed = file_close(f)
 return 0
end
""")
d = work / 'case-reuse'
d.mkdir()
target = d / 'document'
proc = subprocess.Popen([str(reuse), str(target)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
ready(proc)
samples = []
started = time.monotonic()
while proc.poll() is None:
    if time.monotonic() - started > 60:
        stop_owned(proc)
        raise AssertionError('sustained save test exceeded 60 seconds')
    try:
        fields = {x.split(':', 1)[0]: x.split(':', 1)[1].strip() for x in Path(f'/proc/{proc.pid}/status').read_text().splitlines() if ':' in x}
        precise = {x.split(':', 1)[0]: x.split(':', 1)[1].strip() for x in Path(f'/proc/{proc.pid}/smaps_rollup').read_text().splitlines() if ':' in x}
        if 'Rss' in precise and 'VmSize' in fields:
            samples.append(dict(seconds=round(time.monotonic() - started, 3), rss_kib=int(precise['Rss'].split()[0]), vmsize_kib=int(fields['VmSize'].split()[0])))
    except (FileNotFoundError, ProcessLookupError):
        pass
    time.sleep(0.1)
out, err = finish(proc)
(d / 'memory.json').write_text(json.dumps(samples, indent=2) + '\n')
assert proc.returncode == 0 and out == b'0\n' and (not err) and (target.read_bytes() == b'Stable notes.\n')
rss = [v['rss_kib'] for v in samples]
vm = [v['vmsize_kib'] for v in samples]
result('sustained-4000-saves-8000-edits', len(samples) >= 20 and max(rss) - min(rss) <= 64 and (max(vm) == min(vm)), seconds=round(time.monotonic() - started, 3), samples=len(samples), rss_min_kib=min(rss), rss_max_kib=max(rss), vmsize_kib=vm[0])
(work / 'result.json').write_text(json.dumps(dict(checks=checks, compiler_sha256=seed_sha, prelude_sha256=hashlib.sha256(prelude.encode()).hexdigest()), indent=2) + '\n')
print(f'notes support: {len(checks)} checks passed; evidence: {work}', flush=True)
