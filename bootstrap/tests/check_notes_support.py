#!/usr/bin/env python3
"""Independent headless Herbert text/file tests; all files belong to scratch."""
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
libs = ['lib/linux.herb', 'lib/file_io.herb', 'lib/text_buffer.herb']
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
# Sample steady-state memory after warmup across 4,000 real save transactions.
reuse = compile('reuse', r"""func cycle(f, t, poll, left, sampling):
 if left == 0: return 0 end
 let start = text_seek(t, 0)
 let insert = text_insert(t, 65)
 let back = text_backspace(t)
 let saved = file_save(f, t.0, text_length(t))
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
