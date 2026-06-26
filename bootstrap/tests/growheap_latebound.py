#!/usr/bin/env python3
# growheap_latebound.py -- the late-bound forcing harness for "growheap" (kernel-arc link 41 / native-codegen link 57):
# GROW THE HEAP -- the first MULTI-PAGE heap pool with cross-page split + address-ordered CROSS-PAGE-BOUNDARY coalesce.
# ADDITIVE sidecar to the FROZEN-lineage growheap_ref.py (it imports the ref's Asm, le32, the SYS_* + GROWHEAP_*
# constants, parse_head, build_elf, assert_growheap and adds NOTHING to the kernel). It carries:
#   (1) a host MULTI-PAGE FIRST-FIT GOLDEN (the Heap simulator) that mirrors step0_growheap.py EXACTLY: a contiguous
#       NPAGES-page pool, first-fit + split + address-ordered coalesce that MERGES ACROSS PAGE BOUNDARIES, with forge
#       variants (singlepage / nocrosspagecoalesce / no-free / static-arena) used both to compute the expected
#       kernel-emitted trace AND to VERIFY (by simulation) that a seed forces the grow-the-heap property before use;
#   (2) the AUTHOR-UNKNOWN witness -- the step0 A/B/C/D/free/E skeleton: the seed (chosen AFTER freeze) derives the chunk
#       SIZES so the offset trace is author-unknown; the FIXED SHAPE forces a BOUNDARY-STRADDLE (A,B fill page 1 with B
#       ending AT the boundary; C,D fill page 2 with D ending AT CAP -> peak live == 2 pages forces multi-page;
#       free(B)+free(C) leave a hole that STRADDLES the page boundary; E=alloc(sB+sC) fits ONLY that cross-page-coalesced
#       hole). Rejection-sampled so genuine NEVER OOMs AND the make-or-break hole genuinely STRADDLES (asserted in
#       _forces_all -- else the gate silently degrades to within-page coalesce that M-singlepage does NOT bite);
#   (3) the GENERIC ring-3 DRIVER (reused verbatim from larder: it interprets the COM1 op stream -- ALLOC/FREE/DUMP/DONE
#       -- the kernel reads each byte, a CPL3 module cannot touch the UART; ALLOC writes the sentinel THROUGH the
#       returned ptr -> forces REAL backing of the multi-page pool);
#   (4) FORGE legs for M-singlepage / M-nocrosspagecoalesce / no-free / static-arena (each DIVERGES: OOM where genuine
#       returns a ptr); and (5) the grader (positional parse of the 0xE0 alloc trace + the 0xE1..0xE2 live readback).
import os, sys, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import growheap_ref as G
from growheap_ref import (Asm, le32, parse_head, LARDER_MAGIC, LARDER_MAXCHUNKS,
                          GROWHEAP_PGSZ, GROWHEAP_NPAGES, GROWHEAP_CAP, GROWHEAP_POOL_VADDR,
                          SYS_READ, SYS_EXIT, SYS_ALLOC, SYS_FREE, SYS_DUMP, JE)

PGSZ     = GROWHEAP_PGSZ          # 4096 -- the page size; the cross-page boundary the witness straddles
NPAGES   = GROWHEAP_NPAGES        # 2
CAP      = GROWHEAP_CAP           # 8192 -- the multi-page pool capacity (== NPAGES*PGSZ)
MINALLOC = 4                      # the kernel's min-alloc (4-byte sentinel width) floor

# ---- module stack scratch layout (esp-relative; the driver remembers returned ptrs so a later FREE references them) ----
NSLOT     = 24
SLOT_OFF  = 0                 # NSLOT dwords = the returned-ptr table (indexed by allocation order)
ACOUNT_OFF= NSLOT*4           # alloc_count
SIZE_OFF  = ACOUNT_OFF+4      # the current alloc size (a 4-byte scratch)
SENT_OFF  = SIZE_OFF+4        # 4 sentinel bytes
KTMP_OFF  = SENT_OFF+4        # a 4-byte scratch
BUFSZ     = (KTMP_OFF+4+15)&~15

OP_DONE=0; OP_ALLOC=1; OP_FREE=2; OP_FREE_OFF=3; OP_FREE_RAW=4; OP_DUMP=5


# ============================ host MULTI-PAGE FIRST-FIT golden (mirrors step0_growheap.py EXACTLY) ============================
class Heap:
    """Address-sorted, GAP-FREE free list over [0, CAP): a list of [base, length, used]. Mirrors the kernel arm AND
       step0_growheap.py: first-fit by address; split-on-alloc; free + coalesce with the address neighbours (which ARE
       the array neighbours since the list is gap-free). Because the pool is ONE CONTIGUOUS NPAGES-page span, coalesce
       merges ACROSS the internal page boundary automatically -- that IS the grow-the-heap capability. `mode` selects a
       forge prediction used by the VERIFIER to confirm each forge diverges:
         'genuine'             -- the full NPAGES-page pool with cross-page coalesce.
         'singlepage'          -- the pool is CAPPED to ONE page (CAP -> PGSZ); a page-2 alloc OOMs (M-singlepage).
         'nocrosspagecoalesce' -- coalesce REFUSES to merge when the two chunks meet AT a page boundary (base%PGSZ==0).
         'freenoop'            -- FREE never reclaims (no-free).
         'bump'                -- bump-pointer, no free-list, no reuse (static arena)."""
    def __init__(self, mode='genuine'):
        eff = PGSZ if mode == 'singlepage' else CAP      # M-singlepage: only the first page exists
        self.c = [[0, eff, False]]
        self.maxchunks = LARDER_MAXCHUNKS
        self.pool = eff
        self.mode = mode
        self.cursor = 0                                  # static-arena (bump) cursor
    def alloc(self, size):
        if size < MINALLOC or size > self.pool:          # min-alloc (sentinel width) floor + pool-size ceiling
            return None
        if self.mode == 'bump':                          # static arena: bump-pointer, no reuse
            if self.cursor + size > self.pool: return None
            off = self.cursor; self.cursor += size; return off
        for i, ch in enumerate(self.c):                  # first fit by address
            if (not ch[2]) and ch[1] >= size:
                if ch[1] > size:                         # split, remainder stays free
                    if len(self.c) >= self.maxchunks: return None
                    self.c.insert(i+1, [ch[0]+size, ch[1]-size, False])
                    ch[1] = size
                ch[2] = True
                return ch[0]
        return None                                      # OOM
    def free(self, ptr):
        if self.mode in ('bump', 'freenoop'):            # no-free / static arena: never reclaim
            return
        for i, ch in enumerate(self.c):
            if ch[0] == ptr and ch[2]:                   # EXACT base match (interior/unowned ptr -> no match -> no-op)
                ch[2] = False
                do_next = i+1 < len(self.c) and not self.c[i+1][2]
                do_prev = i > 0 and not self.c[i-1][2]
                # NEXT-merge boundary = c[i+1].base ; PREV-merge boundary = c[i].base (the higher chunk's base in each
                # case). M-nocrosspagecoalesce REFUSES when that boundary is page-aligned (the spans meet AT a boundary).
                refuse_next = do_next and (self.mode == 'nocrosspagecoalesce') and (self.c[i+1][0] % PGSZ == 0)
                refuse_prev = do_prev and (self.mode == 'nocrosspagecoalesce') and (ch[0] % PGSZ == 0)
                if do_next and not refuse_next:
                    ch[1] += self.c[i+1][1]; del self.c[i+1]
                if do_prev and not refuse_prev:
                    self.c[i-1][1] += ch[1]; del self.c[i]
                return
        return
    def live_bases(self):
        return [ch[0] for ch in self.c if ch[2]]


def sentinel(seed, k):
    """A distinct, nonzero 4-byte sentinel for allocation k, derived from the late-bound host seed."""
    s = hashlib.sha256(b'growheap-sent|' + seed + bytes([k])).digest()[:4]
    if s == b'\x00\x00\x00\x00':
        s = b'\x01\x00\x00\x00'
    return s


# ============================ AUTHOR-UNKNOWN witness (step0 A/B/C/D/free/E skeleton; seed-derived sizes) ============================
# Late-bound, author-unknown SIZES; the SHAPE is FIXED and forces the boundary-straddle:
#   sA + sB == PGSZ   (B ends EXACTLY at the page boundary 4096)
#   sC + sD == PGSZ   (D ends EXACTLY at CAP 8192)  -> A,B,C,D pack [0,CAP) full -> peak live == 2 pages (forces multi-page)
#   sE = sB + sC      (the make-or-break alloc; fits ONLY the cross-page-coalesced hole)
NALLOC = 5                                            # A,B,C,D,E
def _derive_sizes(seed, nonce):
    h = hashlib.sha256(b'growheap-sizes|' + seed + bytes([nonce])).digest()
    span = PGSZ - 2 * MINALLOC                        # keep sA,sC in [MINALLOC, PGSZ-MINALLOC) so sB,sD >= MINALLOC too
    sA = MINALLOC + int.from_bytes(h[0:4], 'little') % span
    sB = PGSZ - sA                                    # B ends exactly at the page boundary
    sC = MINALLOC + int.from_bytes(h[4:8], 'little') % span
    sD = PGSZ - sC                                    # D ends exactly at CAP
    sE = sB + sC                                      # the make-or-break alloc
    return (sA, sB, sC, sD, sE)


def _skeleton_ops(sizes):
    """The fixed forcing skeleton. alloc indices: A=0, B=1, C=2, D=3, E=4. free(B), free(C) -> the straddling hole."""
    sA, sB, sC, sD, sE = sizes
    return [('A', sA, 0), ('A', sB, 1), ('A', sC, 2), ('A', sD, 3),
            ('F', 1), ('F', 2),                       # free B then C -> coalesced hole [sA, PGSZ+sC) straddles boundary
            ('A', sE, 4),                             # E fits ONLY that cross-page hole, at offset sA
            ('D',), ('Q',)]


def _simulate(ops, sizes, mode='genuine'):
    """Run the op list on a Heap(mode); return (alloc_offsets, live) where live = [(base, sentinel-index)] in ADDRESS
       order at the DUMP. alloc_offsets[k] = the offset (None=OOM) the kernel must emit for the k-th ALLOC."""
    h = Heap(mode=mode)
    slot = {}; off_seq = []; last_writer = {}
    for op in ops:
        if op[0] == 'A':
            _, size, k = op
            off = h.alloc(size); slot[k] = off; off_seq.append(off)
            if off is not None:
                last_writer[off] = k                  # the module writes sentinel[k] THROUGH this ptr
        elif op[0] == 'F':
            h.free(slot.get(op[1]))
        # ('D',) / ('Q',) do not change heap state
    live = [(b, last_writer.get(b)) for b in h.live_bases()]
    return off_seq, live


FORGES = ('singlepage', 'nocrosspagecoalesce', 'freenoop', 'bump')   # the grow-the-heap forge modes (host + kernel)


def _forces_all(ops, sizes):
    """True iff this seed's sequence forces the GROW-THE-HEAP capability:
       (a) genuine NEVER OOMs; (b) A,B,C,D pack [0,CAP) full -> peak live == 2 pages (forces multi-page); (c) the
       make-or-break hole genuinely STRADDLES the page boundary and E lands at the hole start; (d) every cheaper forge
       DIVERGES (OOM where genuine returns a ptr) -- specifically M-singlepage OOMs the page-2 alloc C, and
       M-nocrosspagecoalesce / no-free / static-arena OOM the make-or-break alloc E.
       The STRADDLE assertion is load-bearing: without it the hole could be within one page, where M-singlepage would
       NOT bite (the gate would silently degrade to a within-page coalesce test)."""
    sA, sB, sC, sD, sE = sizes
    g_off, _ = _simulate(ops, sizes, 'genuine')
    if any(o is None for o in g_off): return False               # (a) genuine must never OOM
    if sA + sB != PGSZ or sC + sD != PGSZ: return False          # (b) A,B,C,D pack [0,CAP) full (peak live == 2 pages)
    hole_start, hole_end = sA, PGSZ + sC                         # the coalesced hole [off(B), off(C)+sC)
    if not (hole_start < PGSZ < hole_end): return False          # (c) the hole STRADDLES the page boundary
    if g_off[4] != hole_start: return False                      #     E lands EXACTLY at the cross-page hole start
    # (d) each cheaper forge diverges, in the specific way step0 proved.
    sp_off, _ = _simulate(ops, sizes, 'singlepage')
    if sp_off[2] is not None: return False                       # M-singlepage: the page-2 alloc C must OOM
    for m in ('nocrosspagecoalesce', 'freenoop', 'bump'):
        m_off, _ = _simulate(ops, sizes, m)
        if m_off[4] is not None: return False                    # the make-or-break alloc E must OOM under the forge
        if m_off == g_off: return False                          # (defensive) the forge trace must differ from genuine
    return True


def choose_sequence(seed, max_nonce=64):
    """Deterministically pick the first seed-derived sizes whose skeleton forces the grow-the-heap capability and makes
       every forge diverge. Returns (ops, sizes, nonce). Raises if none found (the fixed shape forces it for ~every
       seed, so this practically always succeeds on nonce 0; the loop is a rejection-sampling safety net)."""
    for nonce in range(max_nonce):
        sizes = _derive_sizes(seed, nonce)
        ops = _skeleton_ops(sizes)
        if _forces_all(ops, sizes):
            return ops, sizes, nonce
    raise RuntimeError('no forcing sequence found for seed (widen ranges)')


# ============================ COM1 stream + golden ============================
def _emit_op_bytes(stream, op, sents):
    if op[0] == 'A':
        _, size, k = op
        stream += bytes([OP_ALLOC]) + le32(size) + sents[k]
    elif op[0] == 'F':
        stream += bytes([OP_FREE, op[1]])
    elif op[0] == 'D':
        stream += bytes([OP_DUMP])
    elif op[0] == 'Q':
        stream += bytes([OP_DONE])


def make_witness(seed):
    """The AUTHOR-UNKNOWN make-or-break witness for `seed`: returns (com1_stream, golden_off, golden_live, sizes)."""
    ops, sizes, _ = choose_sequence(seed)
    sents = [sentinel(seed, k) for k in range(NALLOC)]
    off, live = _simulate(ops, sizes, 'genuine')
    golden_live = [(o, sents[k]) for (o, k) in live]
    stream = bytearray()
    for op in ops:
        _emit_op_bytes(stream, op, sents)
    return bytes(stream), off, golden_live, sizes


# ---- FORGE legs: each runs the SAME author-unknown witness against a kernel MUTANT that should make it RED (the mutant
#      OOMs where genuine returns a ptr). Returns (com1_stream, genuine_golden_off, genuine_golden_live, leg, mutant). ----
FORGE_LEGS = {
    'singlepage':          'singlepage',           # the pool is one page -> the page-2 alloc OOMs
    'nocrosspagecoalesce': 'nocrosspagecoalesce',  # coalesce refuses across the boundary -> the make-or-break alloc OOMs
    'nofree':              'freenoop',             # FREE never reclaims -> the hole never forms -> the alloc OOMs
    'staticarena':         'bump',                 # bump-pointer, no reuse -> the alloc OOMs
}
def make_forge(seed, leg):
    if leg not in FORGE_LEGS:
        raise ValueError('unknown forge leg ' + leg)
    mut = FORGE_LEGS[leg]
    ops, sizes, _ = choose_sequence(seed)
    sents = [sentinel(seed, k) for k in range(NALLOC)]
    off, live = _simulate(ops, sizes, 'genuine')                 # the GENUINE golden (what the mutant must DIVERGE from)
    golden_live = [(o, sents[k]) for (o, k) in live]
    stream = bytearray()
    for op in ops:
        _emit_op_bytes(stream, op, sents)
    return bytes(stream), off, golden_live, leg, mut


# ============================ the GENERIC ring-3 DRIVER module (hand-asm; reused from larder) ============================
def module_growheap_driver():
    """Interpret the COM1 op stream: ALLOC (4-byte size + 4 sentinel bytes -> SYS_ALLOC, store ptr, write the sentinel
       THROUGH the ptr if nonzero -> forces REAL backing of the multi-page pool), FREE (1-byte k -> SYS_FREE slot[k]),
       DUMP, DONE. All state lives at [esp+...]; registers do not survive int 0x30. SYS_ALLOC is given size in EBX only;
       SYS_FREE the ptr in ECX only (no hidden hint channel)."""
    m = Asm()
    def rd_byte_to(off):
        m.raw(0xB8,0x00,0x00,0x00,0x00); m.raw(0xCD,0x30)  # mov eax,0 (SYS_READ) ; int 0x30 -> al = byte
        m.raw(0x88,0x84,0x24); m.blob(le32(off))           # mov [esp+off], al
    def rd4_to(off):
        for i in range(4): rd_byte_to(off+i)
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))                  # sub esp, BUFSZ
    m.raw(0xC7,0x84,0x24); m.blob(le32(ACOUNT_OFF)); m.blob(le32(0))   # mov dword[esp+ACOUNT], 0
    m.lbl('op_loop')
    m.raw(0xB8,0x00,0x00,0x00,0x00); m.raw(0xCD,0x30)      # SYS_READ -> al = opcode
    m.raw(0x3C,OP_ALLOC);    m.j(JE,'do_alloc_op')
    m.raw(0x3C,OP_FREE);     m.j(JE,'do_free_op')
    m.raw(0x3C,OP_DUMP);     m.j(JE,'do_dump_op')
    m.j(None,'do_done')                                   # 0/unknown -> done
    # ---- ALLOC ----
    m.lbl('do_alloc_op')
    rd4_to(SIZE_OFF)                                       # 4-byte size -> [esp+SIZE]
    rd4_to(SENT_OFF)                                       # 4 sentinel bytes -> [esp+SENT]
    m.raw(0x8B,0x9C,0x24); m.blob(le32(SIZE_OFF))         # mov ebx,[esp+SIZE]
    m.raw(0xB8); m.blob(le32(SYS_ALLOC)); m.raw(0xCD,0x30)# SYS_ALLOC -> eax=ptr (0=OOM/reject)
    m.raw(0x8B,0x8C,0x24); m.blob(le32(ACOUNT_OFF))       # mov ecx,[esp+ACOUNT]
    m.raw(0x89,0x84,0x8C); m.blob(le32(SLOT_OFF))         # mov [esp+ecx*4+SLOT], eax (remember the ptr)
    m.raw(0x89,0xC2)                                      # mov edx, eax (ptr)
    m.raw(0x85,0xD2); m.j(JE,'alloc_skipwrite')          # test edx,edx ; jz -> ptr==0 (OOM): skip the write-through
    m.raw(0x8B,0x84,0x24); m.blob(le32(SENT_OFF))        # mov eax,[esp+SENT]
    m.raw(0x89,0x02)                                     # mov [edx], eax (WRITE the sentinel THROUGH the returned ptr)
    m.lbl('alloc_skipwrite')
    m.raw(0xFF,0x84,0x24); m.blob(le32(ACOUNT_OFF))      # inc dword[esp+ACOUNT]
    m.j(None,'op_loop')
    # ---- FREE (by remembered ptr) ----
    m.lbl('do_free_op')
    m.raw(0xB8,0x00,0x00,0x00,0x00); m.raw(0xCD,0x30)     # read k -> eax
    m.raw(0x89,0xC1)                                      # mov ecx,eax (k)
    m.raw(0x8B,0x8C,0x8C); m.blob(le32(SLOT_OFF))        # mov ecx,[esp+ecx*4+SLOT] (the remembered ptr)
    m.raw(0xB8); m.blob(le32(SYS_FREE)); m.raw(0xCD,0x30)
    m.j(None,'op_loop')
    # ---- DUMP ----
    m.lbl('do_dump_op')
    m.raw(0xB8); m.blob(le32(SYS_DUMP)); m.raw(0xCD,0x30)
    m.j(None,'op_loop')
    # ---- DONE ----
    m.lbl('do_done')
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))                # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8); m.blob(le32(SYS_EXIT)); m.raw(0xCD,0x30)  # SYS_EXIT(0)
    m.raw(0xEB,0xFE)                                     # jmp $
    return m.assemble()[0]


# ============================ the grader ============================
def grade(stream, golden_off, golden_live):
    """Locate the magic banner, positionally parse the 0xE0 alloc trace + the 0xE1..0xE2 live readback, compare to the
       golden. pool_base is read from the kernel's OWN dumped cell table (== GROWHEAP_POOL_VADDR for the multi-page
       pool). Returns (errs, info); errs empty == GREEN."""
    cd = parse_head(stream)
    if not cd:
        return ['no parseable kernel cell-dump (boot failed before iret?)'], {}
    pool_base = cd['pool_base']
    info = {'pool_base': pool_base, 'pool_size': cd['pool_size'], 'alloc_ptrs': [], 'live': []}
    i = stream.find(LARDER_MAGIC)
    if i < 0:
        return ['MAGIC banner not found -- kernel did not reach iret-to-proc0'], info
    if stream.find(LARDER_MAGIC, i+1) != -1:
        return ['MAGIC banner appears MORE THAN ONCE (ambiguous)'], info
    p = i + len(LARDER_MAGIC)
    errs = []
    for k, goff in enumerate(golden_off):
        if p >= len(stream) or stream[p] != 0xE0:
            errs.append('alloc %d: missing 0xE0 marker at byte %d (got %r)' % (k, p, stream[p:p+1])); return errs, info
        p += 1
        if p+4 > len(stream):
            errs.append('alloc %d: truncated ptr' % k); return errs, info
        ptr = int.from_bytes(stream[p:p+4], 'little'); p += 4
        info['alloc_ptrs'].append(ptr)
        want = 0 if goff is None else (pool_base + goff)
        if ptr != want:
            errs.append('alloc %d: emitted 0x%08x != expected 0x%08x (offset=%s)' % (k, ptr, want, goff))
    if p >= len(stream) or stream[p] != 0xE1:
        errs.append('dump: missing 0xE1 begin marker (got %r)' % (stream[p:p+1])); return errs, info
    p += 1
    for j, (goff, sent) in enumerate(golden_live):
        if p+8 > len(stream):
            errs.append('live %d: truncated' % j); return errs, info
        ptr = int.from_bytes(stream[p:p+4], 'little'); s = stream[p+4:p+8]; p += 8
        info['live'].append((ptr, s.hex()))
        if ptr != pool_base + goff:
            errs.append('live %d: ptr 0x%08x != expected 0x%08x (offset=%d)' % (j, ptr, pool_base+goff, goff))
        if s != sent:
            errs.append('live %d: sentinel %s != expected %s' % (j, s.hex(), sent.hex()))
    if p >= len(stream) or stream[p] != 0xE2:
        errs.append('dump: missing 0xE2 terminator (got %r) -- emitted MORE live chunks than golden' % (stream[p:p+1]))
    return errs, info


# ============================ simulation-level self-test (no QEMU; the silicon grade is the orchestrator's) ============================
def selftest(nseeds=300):
    """Mirror step0_growheap.py at the harness level: per seed, confirm genuine succeeds, the hole straddles, E lands at
       the hole start, and each forge DIVERGES (OOM). Returns (ok, rows) where rows is a per-seed divergence table."""
    rows = []
    ok = True
    for sd in range(1, nseeds+1):
        seed = sd.to_bytes(4, 'little')
        ops, sizes, nonce = choose_sequence(seed)
        sA, sB, sC, sD, sE = sizes
        g_off, _ = _simulate(ops, sizes, 'genuine')
        straddle = (sA < PGSZ < PGSZ + sC) and (g_off[4] == sA)
        div = {}
        for m in FORGES:
            m_off, _ = _simulate(ops, sizes, m)
            # the divergence: the first alloc index where the forge emits OOM (None) but genuine returns a ptr
            idx = next((k for k in range(NALLOC) if m_off[k] is None and g_off[k] is not None), None)
            div[m] = idx
        row = dict(seed=sd, sizes=sizes, genuine_ok=all(o is not None for o in g_off), straddle=straddle,
                   E_off=g_off[4], div=div)
        rows.append(row)
        if not (row['genuine_ok'] and straddle and all(div[m] is not None for m in FORGES)):
            ok = False
    return ok, rows


# ============================ CLI ============================
if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'kernel':                       # out [mut]  -> build the GROWHEAP kernel ELF (npages=NPAGES), print kend
        mut = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != 'none' else None
        img, kend, _ = G.build_elf(mut=mut, npages=NPAGES)
        open(sys.argv[2], 'wb').write(img); print('0x%x' % kend); sys.exit(0)
    elif cmd == 'driver':                     # out  -> build the generic ring-3 driver module
        open(sys.argv[2], 'wb').write(module_growheap_driver()); sys.exit(0)
    elif cmd == 'stream':                     # seedhex  -> print the witness COM1 byte stream (decimal bytes)
        seed = bytes.fromhex(sys.argv[2]); s, off, live, sizes = make_witness(seed)
        print(' '.join(str(b) for b in s)); sys.exit(0)
    elif cmd == 'golden':                     # seedhex  -> print the golden offsets + live + sizes
        seed = bytes.fromhex(sys.argv[2]); s, off, live, sizes = make_witness(seed)
        print('sizes:', sizes); print('alloc_offsets:', off)
        print('live:', [(o, sn.hex()) for o, sn in live]); sys.exit(0)
    elif cmd == 'grade':                      # streamfile seedhex
        stream = open(sys.argv[2], 'rb').read(); seed = bytes.fromhex(sys.argv[3])
        _, off, live, _ = make_witness(seed)
        errs, info = grade(stream, off, live)
        print('pool_base=0x%x pool_size=%s' % (info.get('pool_base', 0), info.get('pool_size')))
        print('emitted alloc ptrs:', ['0x%x' % p for p in info.get('alloc_ptrs', [])])
        print('emitted live:', info.get('live', []))
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'forge_stream':               # seedhex leg  -> print the forge leg's COM1 byte stream (== the witness)
        seed = bytes.fromhex(sys.argv[2]); s, off, live, lbl, mut = make_forge(seed, sys.argv[3])
        print(' '.join(str(b) for b in s)); sys.exit(0)
    elif cmd == 'forge_grade':                # streamfile seedhex leg  (grade a MUTANT-kernel run vs the GENUINE golden)
        stream = open(sys.argv[2], 'rb').read(); seed = bytes.fromhex(sys.argv[3])
        _, off, live, lbl, mut = make_forge(seed, sys.argv[4])
        errs, info = grade(stream, off, live)
        print('leg=%s biting_mutant=%s pool_base=0x%x' % (lbl, mut, info.get('pool_base', 0)))
        print('emitted alloc ptrs:', ['0x%x' % p for p in info.get('alloc_ptrs', [])])
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'forge_mutant':               # leg -> print the biting kernel mutant name
        print(FORGE_LEGS[sys.argv[2]]); sys.exit(0)
    elif cmd == 'selftest':                   # [nseeds]  -> simulation-level forcing self-test (no QEMU)
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 300
        ok, rows = selftest(n)
        print('selftest over %d seeds: %s' % (n, 'PASS' if ok else 'FAIL'))
        sys.exit(0 if ok else 1)
    else:
        raise SystemExit('usage: kernel|driver|stream|golden|grade|forge_stream|forge_grade|forge_mutant|selftest')
