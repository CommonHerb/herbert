"""Boundary-aware decoder for the OWN-table kernel lineage.

Profiles name source-emitted records; payload bytes are never scanned for markers.
An unescaped protocol can have multiple interpretations (C8 is both a counter
and a COW record, and heap dumps have no length). Count complete parses, capped
at two, and reject ambiguity instead of selecting a convenient interpretation.
See DEBUGCON-FRAMES.md for source derivations and the transport boundary.
"""
from dataclasses import dataclass
import re
import os
import struct
import sys


class TraceError(ValueError):
    """Malformed/ambiguous capture; not an empty successful observation."""


class IncompleteTrace(TraceError):
    """No complete guest result (including expected mutant hangs/faults)."""


# A caught exception is not a process verdict. Only uncaught capture errors
# poison a shell gate; incomplete runtime observations remain ordinary RED.
if os.environ.get('KERNEL_PARSE_ERROR_FILE'):
    _previous_excepthook = sys.excepthook
    def _capture_excepthook(kind, value, traceback):
        if isinstance(value, TraceError) and not isinstance(value, IncompleteTrace):
            with open(os.environ['KERNEL_PARSE_ERROR_FILE'], 'a') as out:
                out.write(str(value) + '\n')
        _previous_excepthook(kind, value, traceback)
    sys.excepthook = _capture_excepthook


@dataclass(frozen=True)
class Record:
    kind: str
    at: int
    raw: bytes


BASE = frozenset({'read', 'write', 'reject', 'counter', 'pf', 'gp', 'panic', 'answer', 'halt', 'stage'})
PROFILES = {
    'holler': (BASE - {'counter','stage'}) | {'exit','kill','escape','escaped'},
    'tickover': BASE, 'tandem': BASE, 'rollcall': BASE, 'tenement': BASE,
    'homestead': BASE | {'commit'},
    'furlough': BASE | {'commit', 'wake', 'dispatch'},
    'tessera': BASE | {'commit', 'wake', 'dispatch'},
    'cleave': BASE | {'commit', 'wake', 'dispatch', 'cow'},
}
PROFILES['trikon'] = frozenset({'exit', 'gp', 'answer', 'halt', 'escape', 'escaped'})
PROFILES['nokta'] = PROFILES['trikon'] | {'pf'}
PROFILES['sitopia'] = PROFILES['nokta'] | {'read'}
PROFILES['geeking'] = PROFILES['sitopia'] | {'kill', 'panic'}
for _name in ('lethe', 'platter', 'durable', 'cairn'):
    PROFILES[_name] = BASE | {'commit', 'wake', 'dispatch'}
for _name in ('larder_step0', 'larder', 'growheap', 'delete', 'backfill', 'tract'):
    PROFILES[_name] = (BASE - {'read'}) | {'commit', 'wake', 'dispatch', 'banner', 'alloc', 'heap'}
PROFILES['highwater'] = PROFILES['tract'] | {'falloc', 'frames'}

# marker -> (kind, body byte count, closing byte). None = no closing byte.
FIXED = {
    0xC0: [('read', 13, 0xC1)],
    0xC2: [('commit', 16, 0xC3)],
    0xC8: [('counter', 4, 0xC9), ('cow', 12, 0xC9)],
    0xCC: [('wake', 8, 0xCD)],
    0xD0: [('pf', 20, 0xD1)],
    0xD6: [('reject', 16, 0xD7)],
    0xDE: [('answer', 1, 0xAD)],
    0xE0: [('alloc', 4, None), ('exit',13,0xE1)],
    0xCA: [('kill',16,0xCB)],
    0xE2: [('panic', 8, 0xE3)],
    0xF0: [('gp', 16, 0xF1), ('falloc', 4, None)],
    0x50: [('halt', 0, None)],
    0x77: [('stage', 0, None), ('escape',0,None)],
    0xBB: [('escaped',0,None)],
}
BANNER = b'LARDER\xa5\x5a'

# Bochs mixes shutdown diagnostics into its port-e9 stdout. This recognition is
# allowed ONLY at a terminal guest record boundary; never searched in payloads.
# Debugger lines vary in CPU/clock/address/spacing, but remain ASCII and follow
# the complete fixed shutdown envelope. Unexpected diagnostics fail closed.
_YES_DIAGNOSTIC = b'yes: standard output: Broken pipe\n'
_FURLOUGH_KILLED = re.compile(
    rb'bash: line 1: [0-9]+ Broken pipe +yes c\n'
    rb' +[0-9]+ Killed +\| timeout -s KILL 50 bochs -q -f bochsrc\.txt\n')
_BOCHS_SUFFIX = re.compile(
    rb'={72}\nBochs is exiting with the following message:\n'
    rb'\[UNMAP \] Shutdown port: shutdown requested\n={72}\n'
    rb'(?:\([0-9]+\)\.\[[0-9]+\] \[0x[0-9a-fA-F]+\] '
    rb'[0-9a-fA-F]+:[0-9a-fA-F]+ \([^\r\n]*\): [\x20-\x7e]*\n)*'
    rb'(?:yes: standard output: Broken pipe\n)?')


def _transport_suffix(raw):
    return raw == _YES_DIAGNOSTIC or _BOCHS_SUFFIX.fullmatch(raw) is not None


def _prefix_diagnostic(raw, profile):
    return raw == _YES_DIAGNOSTIC or (profile == 'furlough' and _FURLOUGH_KILLED.fullmatch(raw) is not None)


def _parse(raw, profile, nprocs, *, prefix=False):
    if profile not in PROFILES:
        raise TraceError(f'unknown debugcon profile {profile!r}')
    if not isinstance(nprocs, int) or nprocs < 0:
        raise TraceError('debugcon nprocs must come from the OWN table')
    raw = bytes(raw)
    allowed = PROFILES[profile]
    n = len(raw)
    if not n:
        if prefix: return ()
        raise IncompleteTrace(f'{profile} empty runtime tail')
    # A forward chart: only record boundaries reached from byte zero are visited.
    # Each endpoint stores at most two paths and one predecessor; no recursion.
    ways = {0: 1}; previous = {}; farthest = 0; truncated = set(); incomplete_end = False
    for at in range(n):
        if at not in ways:
            continue
        farthest = at
        if _prefix_diagnostic(raw[at:], profile):
            incomplete_end = True
            continue
        marker = raw[at]
        candidates = []
        for kind, size, closing in FIXED.get(marker, ()):
            if kind not in allowed:
                continue
            end = at + 1 + size + (closing is not None)
            if end > n: truncated.add(at)
            if end <= n and (closing is None or raw[end-1] == closing):
                candidates.append((kind, end))
        if marker == 0xD4 and 'write' in allowed and at+17 > n:
            truncated.add(at)
        if marker == 0xD4 and 'write' in allowed and at+17 <= n:
            length = int.from_bytes(raw[at+1:at+5], 'little')
            # All write-capable profiles map four page tables (16 MiB); access_ok cannot
            # emit a closed write of this size. This is not an EOF truncation.
            if length >= 0x1000000:
                continue
            end = at+18+length
            if end > n: truncated.add(at)
            if end <= n and raw[end-1] == 0xD5:
                candidates.append(('write', end))
        if marker == 0xCA and 'dispatch' in allowed:
            end = at+2+4*nprocs
            if end > n: truncated.add(at)
            if end <= n and raw[end-1] == 0xCB:
                candidates.append(('dispatch', end))
        if marker == BANNER[0] and 'banner' in allowed:
            if raw.startswith(BANNER, at):
                candidates.append(('banner', at+len(BANNER)))
            elif BANNER.startswith(raw[at:]):
                truncated.add(at)
        for kind, opening, closing in [('heap', 0xE1, 0xE2), ('frames', 0xF1, 0xF3)]:
            if kind in allowed and marker == opening:
                # An uncounted dump can continue past EOF, even when an earlier
                # entry byte also supplied a closing candidate on another path.
                truncated.add(at)
                for close in range(at+1, n, 8):
                    if raw[close] == closing:
                        candidates.append((kind, close+1))
        for kind, end in candidates:
            next_at = end
            if prefix and _prefix_diagnostic(raw[end:], profile):
                next_at = n
            if kind in {'pf', 'gp', 'panic'} and end != n and _transport_suffix(raw[end:]):
                next_at = n
            if kind in {'answer', 'halt', 'stage'}:
                if end != n:
                    if not _transport_suffix(raw[end:]):
                        continue
                    next_at = n
            if not prefix and next_at == n and kind not in {'answer', 'halt', 'stage', 'pf', 'gp', 'panic'}:
                incomplete_end = True
                continue
            count = ways.get(next_at, 0)
            ways[next_at] = min(2, count + ways[at])
            if count == 0:
                previous[next_at] = (at, Record(kind, at, raw[at:end]))
    if ways.get(n, 0) == 0:
        if truncated or incomplete_end:
            raise IncompleteTrace(f'{profile} truncated debugcon record at byte {farthest} of {n}')
        raise TraceError(f'{profile} malformed/truncated debugcon record at byte {farthest} of {n}')
    if ways[n] != 1:
        raise TraceError(f'{profile} ambiguous debugcon capture (multiple complete parses)')
    records = []; end = n
    while end:
        at, record = previous[end]; records.append(record); end = at
    result = tuple(reversed(records))
    if not prefix and result[-1].kind not in {'answer', 'halt', 'stage', 'pf', 'gp', 'panic'}:
        raise IncompleteTrace(f'{profile} runtime trace has no terminal record')
    return result


def parse(raw, profile, nprocs):
    return _parse(raw, profile, nprocs)


def parse_prefix(raw, profile, nprocs):
    """Complete records only, with no runtime-completion claim (withheld-input proof)."""
    return _parse(raw, profile, nprocs, prefix=True)


class FramedTail(bytes):
    """Raw-byte-compatible tail with its explicit OWN-table decoding context."""
    _prefix = False
    def __new__(cls, raw, profile, nprocs):
        result = super().__new__(cls, raw)
        result.profile = profile
        result.nprocs = nprocs
        decoder = parse_prefix if cls._prefix else parse
        result.records = decoder(raw, profile, nprocs)
        return result


class FramedPrefix(FramedTail):
    """Explicit positive-prefix observation; never implies runtime completion."""
    _prefix = True


def records(tail, kind):
    if not isinstance(tail, FramedTail):
        raise TraceError('expected FramedTail from parse_head; plain bytes need explicit profile and nprocs')
    return tuple(record for record in tail.records if record.kind == kind)


def search(tail, kind, pattern):
    """Compatibility Match object, scoped to a decoded record, never raw data."""
    selected = records(tail, kind)
    if len(selected) > 1 and kind in {'answer', 'counter', 'dispatch'}:
        raise TraceError(f'duplicate {kind} records')
    return re.fullmatch(pattern, selected[0].raw, re.S) if selected else None


def write_frames(tail):
    if not isinstance(tail, FramedTail):
        raise TraceError('expected FramedTail from parse_head; plain bytes need explicit profile and nprocs')
    if tail.records and tail.records[-1].kind == 'stage':
        raise IncompleteTrace('stage-A table dump does not establish runtime execution')
    out = []
    for record in records(tail, 'write'):
        length, cs, eip, esp = struct.unpack('<4I', record.raw[1:17])
        out.append(dict(ln=length, cs=cs, eip=eip, esp=esp,
                        body=record.raw[17:-1], closed=True, at=record.at))
    return out


def fields(tail, kind, names):
    return [dict(zip(names, struct.unpack('<'+'I'*len(names), r.raw[1:-1])), at=r.at)
            for r in records(tail, kind)]


def heap_observation(tail):
    """The larder/growheap driver emits banner, allocations, one live dump."""
    rs = list(tail.records)
    if not rs or rs[0].kind != 'banner':
        return None
    at = 1; allocs = []
    while at < len(rs) and rs[at].kind == 'alloc':
        allocs.append(int.from_bytes(rs[at].raw[1:], 'little')); at += 1
    if at >= len(rs) or rs[at].kind != 'heap':
        return None
    body = rs[at].raw[1:-1]
    live = [(int.from_bytes(body[i:i+4], 'little'), body[i+4:i+8]) for i in range(0,len(body),8)]
    if [r.kind for r in rs[at+1:]] != ['counter','dispatch','answer'] or rs[-1].raw != b'\xde\x00\xad':
        return None
    return allocs, live


def extract_bochs(raw):
    """Remove only an ASCII emulator preamble, retaining the entire guest tail."""
    at = raw.find(b'\x9c')
    prefix = raw[:at] if at >= 0 else raw
    if any(byte not in (9, 10, 13) and not 32 <= byte <= 126 for byte in prefix):
        raise TraceError('non-ASCII bytes before the Bochs OWN-table boundary')
    return raw[at:] if at >= 0 else b''


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != 'extract':
        raise SystemExit('usage: debugcon_frames.py extract BOCHS_LOG RAW_OUTPUT')
    with open(sys.argv[2], 'rb') as source:
        raw = extract_bochs(source.read())
    with open(sys.argv[3], 'wb') as target:
        target.write(raw)
