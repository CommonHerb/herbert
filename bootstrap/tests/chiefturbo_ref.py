#!/usr/bin/env python3
# chiefturbo_ref.py -- chiefturbo (link 26 / native-codegen Link 42) STEP-0 oracle + BYTE-EXACT emitter target.
#
# chiefturbo = the module's FIRST RUNTIME-INDEXED MEMORY: a register-indexed load/store ([base+index*4]) into a
# runtime-filled buffer, so the compiled ring-3 module can HOLD a stream of input it cannot fit in named slots
# and read any element back by a RUNTIME-COMPUTED index. Every prior module ISA op addresses memory only at a
# COMPILE-TIME-CONSTANT slot ([ebp-disp8], <=31 slots) -- so a buffer of N>31 distinct live runtime values cannot
# be held, and the LIFO call stack gives only sequential/reverse access, never random access at a runtime offset.
#
#   func fill(base, i, n):                  # store n runtime bytes into buf[0..n-1] via INDEXED STORE
#       if i == n: return 0 end
#       let w = bufset(base, i, sys_read())
#       return fill(base, i + 1, n)
#   end
#   func gather(base, m):                   # m runtime queries: read k, emit buf[k] via INDEXED LOAD
#       if m == 0: return 0 end
#       let r = sys_write(bufget(base, sys_read()))
#       return gather(base, m - 1)
#   end
#   func main():
#       let base = bufbase()                # base of the User-page buffer (alloc_lo)
#       let n = sys_read()
#       let f = fill(base, 0, n)            # populate buf with n runtime bytes
#       let g = gather(base, n)             # n random-access queries -> n output words buf[idx[j]]
#       return f
#   end
#
# The make-or-break: the SAME module fed N=40 random 24-bit data WORDS + a runtime index SEQUENCE (out of LIFO
# order, with repeats) emits le32(data[idx[0]]), ..., le32(data[idx[N-1]]). To reproduce this the module must
# STORE the N runtime values and RANDOM-ACCESS them by a runtime index. Two forges defeat a naive byte/N>31
# claim (completeness-critic + cross-model Codex, 2026-06-14): (1) if the data is a KNOWN closed-form, a module
# recomputes each value with NO storage; (2) BYTE data packs 4-per-32-bit-slot, so 31 slots hold 124 bytes. The
# design closes BOTH: data is RANDOM (uncomputable) + HELD-BACK by a fresh gate seed (un-bakeable) + 24-bit WORDS
# (two cannot pack into one 32-bit slot) with N=40 > 31 (cannot fit named slots) -- so the gather genuinely
# REQUIRES register-indexed memory, which the module has only via the new bufget/bufset ops. The make-or-break
# is ALSO bound at the EMITTER layer (byte-pin to target_module + assert_indexed_load: a SS-relative SIB
# register-indexed load/store) -- the byte-pin is the ultimate binding (a forge is a DIFFERENT module), exactly
# as mmj binds the union by byte-pin + assert_backward_call rather than the always-forgeable runtime trace.
#
# TYPE-I: the FROZEN holler kernel (holler_ref.build_elf, ac7df9f) runs the module at ring 3 unchanged -- the
# buffer lives on the module's already-RW User page [alloc_lo,alloc_hi); the module's INDEXED stores/loads are
# plain CPL3 memory ops (no kernel involvement). An index that walks off the page faults cleanly (#PF), exactly
# like deep recursion -- the page boundary IS the bounds check (TYPE-I). chiefturbo only changes the COMPILER.
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holler_ref as H   # frozen holler kernel (build_elf), parse(), _all_wframes(), recompute_alloc(), UCODE3

SYS_READ = 0; SYS_EXIT = 1; SYS_WRITE = 2
UCODE3 = H.UCODE3
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def s32(v):  return struct.pack('<i', v)

# ---- nc32 op byte-emitters (mirror of nc_ouro_lower_body + the chiefturbo indexed-memory arm) ----
def OP_PUSH(imm):   return bytes([0x68]) + le32(imm)
def OP_LOADL(slot): return bytes([0xFF, 0x75, (256 - 4*(slot+1)) & 0xFF])   # push [ebp-4*(slot+1)]
def OP_STOREL(slot):return bytes([0x8F, 0x45, (256 - 4*(slot+1)) & 0xFF])   # pop  [ebp-4*(slot+1)]
OP_ADD   = bytes([0x59,0x58,0x01,0xC8,0x50])
OP_SUB   = bytes([0x59,0x58,0x29,0xC8,0x50])
OP_MUL   = bytes([0x59,0x58,0x0F,0xAF,0xC1,0x50])
OP_EQ    = bytes([0x59,0x58,0x39,0xC8,0x0F,0x94,0xC0,0x0F,0xB6,0xC0,0x50])
OP_SYSREAD = bytes([0xB8])+le32(SYS_READ)+bytes([0xCD,0x30,0x50])
# op48 SYS_WRITE (18 bytes), IDENTICAL to holler/mmj: lea ecx,[esp]; mov edx,4; mov eax,2; int 0x30; mov [esp],eax
OP_SYSWRITE = bytes([0x8D,0x0C,0x24, 0xBA,0x04,0x00,0x00,0x00, 0xB8,0x02,0x00,0x00,0x00, 0xCD,0x30, 0x89,0x04,0x24])
assert len(OP_SYSWRITE) == 18
# ---- NEW (chiefturbo) runtime-indexed-memory ops ----
# bufbase(): push the captured buffer base. The module PROLOGUE (main only) stashes alloc_lo at [ebp+0]:
#   mov eax,esp; sub eax,0x1000; push eax   (esp==alloc_hi at module entry -> eax = alloc_lo)
OP_BUFBASE = bytes([0xFF,0x75,0x00])                                   # push [ebp+0]  (3)
# bufget(base, k): TOS=k, next=base. pop ecx(k); pop edx(base); SS: mov eax,[edx+ecx*4]; push eax
# SS OVERRIDE (0x36) is LOAD-BEARING: the buffer lives in the module's STACK SEGMENT, and the [edx+..] base
# register defaults to DS. After a SYS_WRITE the kernel leaves DS=KDATA(DPL0), which iret-to-CPL3 NULLS on real
# silicon (caught by KVM; TCG does not null) -> a DS-relative indexed load #GPs. SS is restored to UDATA3 (DPL3,
# flat) by every iret, so SS-relative addressing of the in-page buffer is correct and substrate-stable.
OP_BUFGET  = bytes([0x59, 0x5A, 0x36, 0x8B,0x04,0x8A, 0x50])           # (7) -- SS:[edx+ecx*4] (assert site)
# bufset(base, i, v): TOS=v, next=i, next=base. pop edx(v); pop ecx(i); pop eax(base); SS: mov [eax+ecx*4],edx; push edx
OP_BUFSET  = bytes([0x5A, 0x59, 0x58, 0x36, 0x89,0x14,0x88, 0x52])     # (8) -- SS:[eax+ecx*4]
MAIN_CAPTURE = bytes([0x89,0xE0, 0x2D,0x00,0x10,0x00,0x00, 0x50])      # (8) mov eax,esp; sub eax,0x1000; push eax

SZ = {'push':5,'loadl':3,'storel':3,'add':5,'sub':5,'mul':6,'eq':11,'sysread':8,'syswrite':18,
      'bufbase':3,'bufget':7,'bufset':8,'br':5,'brf':9,'ret_last':1,'ret_mid':6}

def instr_size(kind, nargs, is_last):
    if kind == 'ret':  return SZ['ret_last'] if is_last else SZ['ret_mid']
    if kind == 'call':
        cl = 0 if nargs == 0 else (3 if 4*nargs <= 127 else 6)
        return 5 + cl + 1
    return SZ[kind]

def frame_size(fn):  # max(nparams, max slot touched)
    nparams = fn[1]; s = nparams
    for (k, a) in fn[2]:
        if k in ('loadl','storel'):
            if a + 1 > s: s = a + 1
    return s

def prologue_len(is_main, nparams, S):
    if S == 0: return 0
    if is_main: return 8 + 5           # MAIN_CAPTURE(8) + (mov ebp,esp; sub esp,4S)(5)
    return 6 + nparams*6
def epilogue_len(is_main, S):
    if is_main: return 9
    return 4 if S > 0 else 1

def callarg(instr): return instr[1][1] if instr[0] == 'call' else 0

def layout(funcs):
    bases = {}; instr_offs = []; epi_off = []; cur = 0
    for fi, fn in enumerate(funcs):
        name = fn[0]; is_main = (fi == 0); S = frame_size(fn)
        bases[name] = cur
        cur += prologue_len(is_main, fn[1], S)
        offs = []; n = len(fn[2])
        for i, instr in enumerate(fn[2]):
            offs.append(cur)
            cur += instr_size(instr[0], callarg(instr), i == n-1)
        instr_offs.append(offs); epi_off.append(cur)
        cur += epilogue_len(is_main, S)
    return bases, instr_offs, epi_off, cur

def emit(funcs):
    bases, instr_offs, epi_off, total = layout(funcs)
    out = b''
    for fi, fn in enumerate(funcs):
        is_main = (fi == 0); S = frame_size(fn); nparams = fn[1]
        if S > 0:
            if is_main:
                out += MAIN_CAPTURE                                    # capture alloc_lo -> [ebp+0]
                out += bytes([0x89,0xE5, 0x83,0xEC, (4*S)&0xFF])
            else:
                out += bytes([0x55, 0x89,0xE5, 0x83,0xEC, (4*S)&0xFF])
                for i in range(nparams):
                    src = 8 + 4*(nparams-1-i)
                    out += bytes([0x8B,0x45, src & 0xFF, 0x89,0x45, (256-4*(i+1)) & 0xFF])
        offs = instr_offs[fi]; n = len(fn[2]); epi = epi_off[fi]
        for i, instr in enumerate(fn[2]):
            kind = instr[0]; is_last = (i == n-1)
            end = offs[i] + instr_size(kind, callarg(instr), is_last)
            if kind == 'push':   out += OP_PUSH(instr[1])
            elif kind == 'loadl':  out += OP_LOADL(instr[1])
            elif kind == 'storel': out += OP_STOREL(instr[1])
            elif kind == 'add':    out += OP_ADD
            elif kind == 'sub':    out += OP_SUB
            elif kind == 'mul':    out += OP_MUL
            elif kind == 'eq':     out += OP_EQ
            elif kind == 'sysread':out += OP_SYSREAD
            elif kind == 'syswrite':out += OP_SYSWRITE
            elif kind == 'bufbase':out += OP_BUFBASE
            elif kind == 'bufget': out += OP_BUFGET
            elif kind == 'bufset': out += OP_BUFSET
            elif kind == 'br':
                tgt = epi if instr[1] == n else offs[instr[1]]
                out += bytes([0xE9]) + s32(tgt - end)
            elif kind == 'brf':
                tgt = epi if instr[1] == n else offs[instr[1]]
                out += bytes([0x58,0x85,0xC0,0x0F,0x84]) + s32(tgt - end)
            elif kind == 'call':
                callee, nargs = instr[1]
                rel = bases[callee] - (offs[i] + 5)
                out += bytes([0xE8]) + s32(rel)
                if nargs > 0:
                    if 4*nargs <= 127: out += bytes([0x83,0xC4, (4*nargs)&0xFF])
                    else:              out += bytes([0x81,0xC4]) + le32(4*nargs)
                out += bytes([0x50])
            elif kind == 'ret':
                if is_last: out += bytes([0x58])
                else:       out += bytes([0x58,0xE9]) + s32(epi - end)
            else: raise SystemExit('op? '+kind)
        if is_main:
            out += bytes([0x88,0xC3, 0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
        elif S > 0:
            out += bytes([0x89,0xEC, 0x5D, 0xC3])
        else:
            out += bytes([0xC3])
    assert len(out) == total, (len(out), total)
    return out

# ---- the chiefturbo forcing program: readword (assemble a 24-bit word) + fill (indexed store) + gather (indexed load) ----
# Layout order is [main, fill, gather, readword] (main hoisted to index 0; the emit mode must match this order
# for the byte-pin). Each data element is a 24-bit WORD assembled from 3 input bytes -- NOT a byte -- so two
# elements cannot pack into one 32-bit slot, and N=40 elements > 31 named slots cannot be held in named storage.
# readword(): b0 b1 b2 = 3x sys_read();  return b0 + 256*(b1 + 256*b2)
# fill(base,i,n): if i==n ret0; let w = bufset(base, i, readword()); return fill(base, i+1, n)
# gather(base,m): if m==0 ret0; let r = sys_write(bufget(base, sys_read())); return gather(base, m-1)   (index = 1 byte)
# main: base=bufbase(); n=sys_read(); f=fill(base,0,n); g=gather(base,n); return f
GATHER_FUNCS = [
    ('main', 0, [('bufbase',0),('storel',0),('sysread',0),('storel',1),
                 ('loadl',0),('push',0),('loadl',1),('call',('fill',3)),('storel',2),
                 ('loadl',0),('loadl',1),('call',('gather',2)),('storel',3),
                 ('loadl',2),('ret',0)]),
    ('fill', 3, [('loadl',1),('loadl',2),('eq',0),('brf',6),('push',0),('ret',0),
                 ('loadl',0),('loadl',1),('call',('readword',0)),('bufset',0),('storel',3),
                 ('loadl',0),('loadl',1),('push',1),('add',0),('loadl',2),('call',('fill',3)),('ret',0)]),
    ('gather', 2, [('loadl',1),('push',0),('eq',0),('brf',6),('push',0),('ret',0),
                   ('loadl',0),('sysread',0),('bufget',0),('syswrite',0),('storel',2),
                   ('loadl',0),('loadl',1),('push',1),('sub',0),('call',('gather',2)),('ret',0)]),
    # readword arithmetic IR is the compiler's LEFT-OPERAND-FIRST lowering of `b0 + 256*(b1 + 256*b2)`:
    # [loadl0, push256, loadl1, push256, loadl2, mul, add, mul, add] -- evaluates to b0 + 256*(b1 + 256*b2)
    # (256*b2 then +b1 then *256 then +b0). Identical value + size to an interleaved fold; aligned to the emit
    # mode so the byte-pin holds (the compiler lowers a+b left-first).
    ('readword', 0, [('sysread',0),('storel',0),('sysread',0),('storel',1),('sysread',0),('storel',2),
                     ('loadl',0),('push',256),('loadl',1),('push',256),('loadl',2),
                     ('mul',0),('add',0),('mul',0),('add',0),('ret',0)]),
]

import random
NDEF = 40                                          # N=40 > 31 named slots (unholdable in named storage)
SEEDS = {'gx': 0xC1A0F0, 'gy': 0xC1A0F1}           # STEP-0 named probes; the GATE feeds FRESH random seeds (held-back)
def _resolve(arg):
    if arg in SEEDS: return SEEDS[arg], NDEF
    return int(arg) & 0xFFFFFFFF, NDEF
def _probe(seed, N):
    """deterministic (seed,N) -> (data, idx). data = N random 24-bit WORDS whose 3 bytes are each in [1,0x7F]
       (so le32(word)=[b0,b1,b2,0] carries NO witness-marker byte). idx = N random indices in [0,N), out of
       LIFO order with repeats. RANDOM => cannot be recomputed (kills the closed-form-arithmetic forge);
       HELD-BACK by a fresh gate seed => cannot be baked; 24-bit => cannot pack 2-per-slot; N>31 => cannot
       fit named slots. So reproducing the gather output genuinely REQUIRES register-indexed memory."""
    rng = random.Random(seed)
    data = [rng.randint(1,0x7F) | (rng.randint(1,0x7F) << 8) | (rng.randint(1,0x7F) << 16) for _ in range(N)]
    idx  = [rng.randrange(N) for _ in range(N)]
    return data, idx

def target_module(kind='gx'): return emit(GATHER_FUNCS)             # data-INDEPENDENT: ONE module for all probes
def herb_src(kind='gx'):
    return ("func readword():\n    let b0 = sys_read()\n    let b1 = sys_read()\n    let b2 = sys_read()\n"
            "    return b0 + 256 * (b1 + 256 * b2)\nend\n"
            "func fill(base, i, n):\n    if i == n:\n        return 0\n    end\n"
            "    let w = bufset(base, i, readword())\n    return fill(base, i + 1, n)\nend\n"
            "func gather(base, m):\n    if m == 0:\n        return 0\n    end\n"
            "    let r = sys_write(bufget(base, sys_read()))\n    return gather(base, m - 1)\nend\n"
            "func main():\n    let base = bufbase()\n    let n = sys_read()\n"
            "    let f = fill(base, 0, n)\n    let g = gather(base, n)\n    return f\nend")
def fed_stream(arg='gx'):
    seed, N = _resolve(arg); data, idx = _probe(seed, N)
    out = bytes([N])
    for w in data: out += bytes([w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF])   # 3 bytes/word -> readword
    return out + bytes(idx)
def host_gather(arg='gx'):
    seed, N = _resolve(arg); data, idx = _probe(seed, N)
    return [le32(data[k]) for k in idx]                              # expected N write-frame bodies
def host_answer(arg='gx'): return 0                                 # main returns f = 0
def expect_reads(arg='gx'):
    seed, N = _resolve(arg); return 1 + 3*N + N                     # N count(1) + N words(3 each) + N indices

# ---- mutant modules (negative controls): each RUNS but is BROKEN, so the grade must go RED ----
def mutant_module(mut):
    if mut == 'wrongidx':
        # genuine indexed module but gather reads buf[k+1] not buf[k] (off-by-one): RUNS, CONTENT pin catches it.
        f = [list(x) for x in GATHER_FUNCS]; g = list(f[2][2])
        g = g[:8] + [('push',1),('add',0)] + g[8:]   # gather idx7 sysread -> insert push1;add (k -> k+1) before bufget
        f[2] = ('gather', 2, g)
        return emit(f)
    if mut == 'constidx':
        # genuine indexed module but gather uses a CONSTANT index 0 (ignores the runtime index): RUNS, but the
        # CONTENT pin catches it (emits data[0] for every query) -> proves the random-access pin bites the INDEX.
        f = [list(x) for x in GATHER_FUNCS]; g = list(f[2][2])
        g[7] = ('push', 0)                               # gather idx7 sys_read() -> push 0 (constant index)
        f[2] = ('gather', 2, g)
        return emit(f)
    raise SystemExit('mutant? '+mut)

def forge_module(kind='gx'):
    """HEADLINE forge: a NON-INDEXED module that BAKES the gather output for the KNOWN gx seed. It reads all
       1+3N+N inputs (recursive drain, to pass the read-count pin) then emits the N expected words as IMMEDIATES
       -- no buffer, no bufget/bufset. It grades GREEN at runtime on gx (proving the runtime trace alone is
       forgeable for KNOWN data), but is caught at the EMITTER layer: byte-pin (forge != target_module) +
       assert_indexed_load (ZERO SS-SIB ops). The genuine gate feeds HELD-BACK random data a baked forge cannot
       precompute; this forge only exists because it is hand-built against the fixed gx seed."""
    seed, N = _resolve(kind)
    data, idx = _probe(seed, N)
    vals = [data[k] for k in idx]                                   # the N baked gather output values (ints)
    main_body = [('sysread',0),('storel',0),                       # read count, discard into slot0
                 ('push', 4*N),('call',('drain',1)),('storel',1)]  # drain the remaining 4N bytes, discard result
    for v in vals:
        main_body += [('push', v),('syswrite',0),('storel',1)]     # emit baked le32(v); discard syswrite result
    main_body += [('push',0),('ret',0)]
    # drain(c): param c is slot0; scratch (discarded byte) is slot1. if c==0 ret0; read+discard; drain(c-1).
    drain_body = [('loadl',0),('push',0),('eq',0),('brf',6),('push',0),('ret',0),
                  ('sysread',0),('storel',1),('loadl',0),('push',1),('sub',0),('call',('drain',1)),('ret',0)]
    return emit([('main',0,main_body),('drain',1,drain_body)])

def _read_frames(stream):
    """count well-formed read-witness frames C0<byte><cs=UCODE3><eip><useresp>C1 (validate each candidate)."""
    out = []; i = 0; n = len(stream)
    while i < n:
        i = stream.find(b'\xC0', i)
        if i < 0: break
        if i + 15 <= n:
            cs, eip, esp = struct.unpack('<3I', stream[i+2:i+14])
            if cs == UCODE3 and stream[i+14] == 0xC1:
                out.append(dict(byte=stream[i+1], eip=eip, esp=esp)); i += 15; continue
        i += 1
    return out

# ===================== STEP-0 / gate grader =====================
def grade(stream, kend_elf, arg='gx'):
    """RUNTIME grade for the chiefturbo gather. Pins: first delivered byte == N; the module CONSUMED the whole
       input (read-frame count == 1+3N+N -- a baked/ignore-index forge skips reads); EXACTLY N write frames;
       frame j relays le32(data[idx[j]]) where (data,idx) are RANDOM and seed-derived [the random-access content
       pin]; every write esp in [alloc_lo,alloc_hi); answer == 0.
       HONESTY (completeness-critic + Codex, 2026-06-14): a RUNTIME trace alone cannot PROVE register-indexed
       memory -- for a KNOWN/closed-form data set a forge can recompute each value (no storage), and BYTE data
       packs 4-per-dword-slot. This grade closes BOTH: data is RANDOM (uncomputable) + HELD-BACK via a fresh gate
       seed (un-bakeable) + 24-bit WORDS with N=40>31 (two cannot share a 32-bit slot, 40 cannot fit 31 slots),
       so reproducing the output genuinely REQUIRES register-indexed memory. The make-or-break is ALSO bound at
       the EMITTER layer (byte-pin to target_module + assert_indexed_load); the byte-pin is the ultimate binding,
       exactly as in mmj (a forge is a DIFFERENT module)."""
    errs = []
    seed, N = _resolve(arg)
    r = H.parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or kernel RED)']
    if r.get('k1') is not None and r['k1'] != kend_elf:
        errs.append(f'dumped k1=0x{r["k1"]:x} != frozen kend=0x{kend_elf:x}')
    ah, al = r.get('ah'), r.get('al')
    rec = H.recompute_alloc(r, kend_elf)
    if rec:
        elo, ehi, _ = rec
        if al != elo: errs.append(f'alloc_lo 0x{al:x} != recomputed 0x{elo:x}')
        if ah != ehi: errs.append(f'alloc_hi 0x{ah:x} != recomputed 0x{ehi:x}')
    rfs = _read_frames(stream)
    if not rfs: errs.append('no read-witness frame (SYS_READ not serviced at CPL3)')
    else:
        if rfs[0]['byte'] != N: errs.append(f'first delivered byte 0x{rfs[0]["byte"]:x} != N={N} (the count read)')
        if len(rfs) != expect_reads(arg):
            errs.append(f'{len(rfs)} read frames != expected {expect_reads(arg)} (=1+3N+N) -- module skipped input '
                        f'(a baked/ignore-index forge does not consume all data+index bytes)')
    wfs  = _write_frames(stream)
    want = host_gather(arg)
    if len(wfs) != N:
        errs.append(f'{len(wfs)} write-relay frame(s) (D4..D5) != N={N} (gather must emit exactly N words)')
    else:
        for j, wf in enumerate(wfs):
            if wf['cs'] != UCODE3 or (wf['cs'] & 3) != 3: errs.append(f'write frame {j} cs 0x{wf["cs"]:x} != UCODE3/RPL3')
            if al is not None and ah is not None and not (al <= wf['esp'] < ah):
                errs.append(f'write frame {j} useresp 0x{wf["esp"]:x} not in [alloc_lo 0x{al:x}, alloc_hi 0x{ah:x})')
            if wf['body'] != want[j]:
                errs.append(f'write frame {j} relayed {wf["body"].hex()} != {want[j].hex()} '
                            f'(NOT data[idx[{j}]] -- wrong index/load, the random-access pin)')
    if r.get('answer') != host_answer(arg):
        errs.append(f'answer {r.get("answer")} != {host_answer(arg)} (main returns 0)')
    return errs

def _write_frames(stream):
    """Robustly extract the well-formed SYS_WRITE relay frames D4<len=4><cs=UCODE3><eip><useresp><4 body>D5.
       Scans every 0xD4 candidate and validates independently (advance by 1 on mismatch) -- so a spurious 0xD4
       inside an address field (with a bogus large len) cannot skip past real frames, the way H._all_wframes
       (which trusts the len) would. Returns ordered list of dicts {cs,eip,esp,body}."""
    out = []; i = 0; n = len(stream)
    while i < n:
        i = stream.find(b'\xD4', i)
        if i < 0: break
        if i + 22 <= n:
            ln, cs, eip, esp = struct.unpack('<4I', stream[i+1:i+17])
            body = stream[i+17:i+21]
            if ln == 4 and cs == UCODE3 and stream[i+21] == 0xD5:
                out.append(dict(cs=cs, eip=eip, esp=esp, body=body)); i += 22; continue
        i += 1
    return out

def assert_indexed_load(modbytes):
    """white-box: the module carries a SS-relative SIB register-indexed load (the bufget lowering 36 8B 04 8A)
       or store (36 89 14 88). A branch-tree forge has NONE (it uses only [ebp-disp8] fixed slots)."""
    return (bytes([0x36,0x8B,0x04,0x8A]) in modbytes) or (bytes([0x36,0x89,0x14,0x88]) in modbytes)

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'module':     open(sys.argv[2], 'wb').write(target_module())            # data-independent: one module
    elif cmd == 'mutant':   open(sys.argv[3], 'wb').write(mutant_module(sys.argv[2]))
    elif cmd == 'forge':    open(sys.argv[3], 'wb').write(forge_module(sys.argv[2]))
    elif cmd == 'hex':      sys.stdout.write(target_module().hex())
    elif cmd == 'src':      sys.stdout.write(herb_src())
    elif cmd == 'stream':   sys.stdout.write(' '.join(str(b) for b in fed_stream(sys.argv[2] if len(sys.argv)>2 else 'gx')))
    elif cmd == 'kernelelf': img, kend, _ = H.build_elf(); open(sys.argv[2], 'wb').write(img); print('%x' % kend)
    elif cmd == 'kend':     _, kend, _ = H.build_elf(); print('%x' % kend)
    elif cmd == 'indexed':  sys.exit(0 if assert_indexed_load(open(sys.argv[2],'rb').read()) else 1)
    elif cmd == 'offsets':
        b, io, eo, tot = layout(GATHER_FUNCS)
        print('len', len(target_module()), 'bases', b, 'total', tot, 'N', NDEF)
    elif cmd == 'grade':
        stream = open(sys.argv[2], 'rb').read(); kend = int(sys.argv[3], 16)
        arg = sys.argv[4] if len(sys.argv) > 4 else 'gx'
        errs = grade(stream, kend, arg)
        if errs: print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    else: raise SystemExit('usage: module|mutant|hex|src|stream|kernelelf|kend|indexed|offsets|grade')
