#!/usr/bin/env python3
# larder_latebound.py -- the PRODUCTION late-bound forcing harness for "larder" (kernel-arc link 40 / native-codegen
# link 56): the first general-purpose DYNAMIC HEAP ALLOCATOR. ADDITIVE sidecar to the FROZEN larder_ref.py (it imports
# the ref's Asm, le32, the SYS_* constants, LARDER_MAGIC/POOL, parse_head, build_elf, assert_larder, assert_cairn and
# adds NOTHING to the kernel). It carries:
#   (1) a host FIRST-FIT GOLDEN (the Heap simulator) with forge variants, used both to compute the expected kernel-emitted
#       trace AND to VERIFY (by simulation) that a seed's sequence forces every property before it is used;
#   (2) the AUTHOR-UNKNOWN sequence generator: the seed is chosen by the host AFTER the kernel + driver are frozen; it
#       derives the chunk SIZES (so the offset trace is author-unknown) and the SENTINELS (high-entropy, late-bound) and
#       rejection-samples until the sequence (a) fits the tight pool with NO OOM, (b) exercises split + prev-coalesce +
#       next-coalesce + NON-MRU reuse, and (c) makes EVERY forge mutant (bump / freenoop / nosplit / nocoalesce /
#       noprevmerge / nonextmerge) DIVERGE. Two seeds (gx/gy) give two different sequences -> cross-grading RED;
#   (3) the GENERIC ring-3 DRIVER module (hand-asm): it interprets an op stream off COM1 (the kernel reads each byte; a
#       CPL3 module cannot touch the UART) -- ALLOC (read 4-byte size + 4 sentinel bytes, SYS_ALLOC, store the returned
#       ptr, write the sentinel THROUGH the ptr -> forces REAL backing), FREE (by remembered ptr), FREE_OFF (an INTERIOR
#       ptr = a remembered ptr + delta -- the hostile interior-free), FREE_RAW (a wild absolute ptr -- the hostile
#       unowned/out-of-pool free), DUMP, DONE. SYS_ALLOC reads ONLY EBX; SYS_FREE ONLY ECX (no hidden hint channel);
#   (4) the CONFUSED-DEPUTY / robustness HOSTILE provers (interior-free, alloc(0), alloc(~4GiB), double-free, wild free)
#       with their goldens; and (5) the grader.
import os, sys, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import larder_ref as L
from larder_ref import (Asm, le32, parse_head, LARDER_MAGIC, LARDER_POOL, LARDER_MAXCHUNKS,
                        SYS_READ, SYS_EXIT, SYS_ALLOC, SYS_FREE, SYS_DUMP, JE)

# ---- module stack scratch layout (esp-relative; esp is STABLE across int 0x30 -- the module pushes nothing between
#      syscalls, the kernel iret restores useresp). SLOT[] remembers returned ptrs so a later FREE references them. ----
NSLOT     = 24
SLOT_OFF  = 0                 # NSLOT dwords = the returned-ptr table (indexed by allocation order)
ACOUNT_OFF= NSLOT*4           # alloc_count
SIZE_OFF  = ACOUNT_OFF+4      # the current alloc size / delta / raw ptr (a 4-byte scratch)
SENT_OFF  = SIZE_OFF+4        # 4 sentinel bytes
KTMP_OFF  = SENT_OFF+4        # a 4-byte scratch for the FREE_OFF slot index
BUFSZ     = (KTMP_OFF+4+15)&~15

# the COM1 opcodes the driver interprets (one byte each, then the op's operands).
OP_DONE=0; OP_ALLOC=1; OP_FREE=2; OP_FREE_OFF=3; OP_FREE_RAW=4; OP_DUMP=5

WILD_PTR = 0xDEADBEEF         # a wild absolute ptr for the unowned/out-of-pool free (never a chunk base -> a clean no-op)


# ============================ host FIRST-FIT golden (the reference allocator) ============================
class Heap:
    """Address-sorted, GAP-FREE free list over [0, POOL): a list of [base, length, used]. Mirrors the kernel arm EXACTLY
       (first-fit by address; split-on-alloc; free + coalesce with the address neighbours, which ARE the array neighbours
       since the list is gap-free). `mode` selects a forge prediction (used by the sequence VERIFIER to confirm each
       forge diverges from genuine)."""
    def __init__(self, pool=LARDER_POOL, mode='genuine'):
        self.c = [[0, pool, False]]
        self.maxchunks = LARDER_MAXCHUNKS
        self.pool = pool
        self.mode = mode
        self.cursor = 0                                  # M-bump cursor
    def alloc(self, size):
        if size < 4 or size > self.pool:                 # genuine size reject: min-alloc = the 4-byte SENTINEL WIDTH (so
            return None                                  # the SYS_DUMP readback [base,base+4) stays in-chunk) + the
            #   pool-size ceiling. M-nosizewrap drops the floor; matches the kernel `cmp ebx,4 ; jb` + `cmp ebx,[pool_size] ; ja`.
        if self.mode == 'bump':                          # M-bump: pure bump-pointer, no free-list, no reuse
            if self.cursor + size > self.pool: return None
            off = self.cursor; self.cursor += size; return off
        if self.mode == 'bestfit':                       # M-bestfit: SMALLEST fitting chunk (ties -> lowest addr)
            bi = None
            for i, ch in enumerate(self.c):
                if (not ch[2]) and ch[1] >= size and (bi is None or ch[1] < self.c[bi][1]):
                    bi = i
            if bi is None: return None
            ch = self.c[bi]
            if ch[1] > size:
                if len(self.c) >= self.maxchunks: return None
                self.c.insert(bi+1, [ch[0]+size, ch[1]-size, False]); ch[1] = size
            ch[2] = True; return ch[0]
        for i, ch in enumerate(self.c):
            if (not ch[2]) and ch[1] >= size:
                if ch[1] > size:
                    if self.mode == 'nosplit':           # M-nosplit: alloc the WHOLE chunk (never split)
                        ch[2] = True; return ch[0]
                    if len(self.c) >= self.maxchunks:
                        return None
                    self.c.insert(i+1, [ch[0]+size, ch[1]-size, False])
                    ch[1] = size
                ch[2] = True
                return ch[0]
        return None
    def free(self, ptr):
        if self.mode in ('bump', 'freenoop'):            # M-bump / M-freenoop: FREE never reclaims
            return
        for i, ch in enumerate(self.c):
            if ch[0] == ptr and ch[2]:                   # EXACT base match (interior/unowned ptr -> no match -> no-op)
                ch[2] = False
                do_next = self.mode not in ('nocoalesce', 'nonextmerge')
                do_prev = self.mode not in ('nocoalesce', 'noprevmerge')
                if do_next and i+1 < len(self.c) and not self.c[i+1][2]:
                    ch[1] += self.c[i+1][1]; del self.c[i+1]
                if do_prev and i > 0 and not self.c[i-1][2]:
                    self.c[i-1][1] += ch[1]; del self.c[i]
                return
        return
    def live_bases(self):
        return [ch[0] for ch in self.c if ch[2]]


def sentinel(seed, k):
    """A distinct, nonzero 4-byte sentinel for allocation k, derived from the late-bound host seed."""
    s = hashlib.sha256(b'larder-sent|' + seed + bytes([k])).digest()[:4]
    if s == b'\x00\x00\x00\x00':
        s = b'\x01\x00\x00\x00'
    return s


# ============================ AUTHOR-UNKNOWN witness sequence (seed-derived sizes, rejection-sampled) ============================
# The forcing SKELETON (proven on silicon by STEP-0) parametrised by three free sizes (A0, A1, A3); the rest are derived
# so the tight pool fills and the big allocs fit ONLY via coalesce:
#   A0 ; A1 ; A2=pool-A0-A1 ; F(A1) ; A3 ; A4=A1-A3 ; F(A0) ; F(A3) ; A5=A0+A3 (PREV-coalesce + NON-MRU) ; F(A2) ; F(A4) ;
#   A6=A4+A2 (NEXT-coalesce) ; DUMP ; DONE.
# A5 forces the PREV-merge (of the freed A0 + freed A3 spans) and lands in a NON-most-recently-freed span; A6 forces the
# NEXT-merge (of the freed A4 + already-free A2 span). The seed picks (A0,A1,A3) from ranges; we then SIMULATE genuine +
# every forge and accept only if genuine has no OOM AND every forge diverges. (Author-unknown: the seed is chosen AFTER
# freeze, so the SIZES -- hence the whole offset trace -- and the sentinels cannot be baked.)
def _derive_params(seed, nonce):
    h = hashlib.sha256(b'larder-params|' + seed + bytes([nonce])).digest()
    A0 = 56 + (h[0] % 33)                 # 56..88
    A1 = 32 + (h[1] % 25)                 # 32..56
    A3 = 8  + (h[2] % 24)                 # 8..31
    return A0, A1, A3


def _skeleton_ops(A0, A1, A3, pool=LARDER_POOL):
    """Return the op list (with sentinel indices) for the parametrised forcing skeleton, or None if the params are
       structurally invalid (sizes must be positive, fit, and keep the derived sizes positive)."""
    A2 = pool - A0 - A1
    A4 = A1 - A3
    A5 = A0 + A3
    A6 = A4 + A2
    # bestfit-forcing EXTENSION (seed-independent): after the coalesce forcing, F(A5)+F(A6) always coalesce back to one
    # hole [0,pool) (since A5+A6==pool), so the extension starts from a clean pool regardless of the seed. It carves four
    # chunks D0..D3 that fill the pool, frees D0 + D2 to leave TWO NON-ADJACENT holes -- a BIG one (D0=40 @0) below a
    # SMALL one (D2=24 @48) -- then E0=20 fits BOTH. FIRST-fit takes the lowest-address (big) hole @0; BEST-fit takes the
    # smaller hole @48 -> a DIFFERENT returned ptr -> M-bestfit's emitted trace diverges from the host first-fit golden.
    D0, D1, D2 = 40, 8, 24
    D3 = pool - (D0 + D1 + D2)                            # fill the pool exactly (pool=168 -> D3=96)
    E0 = 20                                               # fits both the 40-hole and the 24-hole; first-fit@0 != best-fit@48
    EXT = [D0, D1, D2, D3, E0]
    sizes = [A0, A1, A2, A3, A4, A5, A6] + EXT
    if any(s < 4 for s in sizes): return None            # every alloc must clear the 4-byte sentinel-width floor (so the
    #   witness is never tripped by the kernel's min-alloc reject; A4=A1-A3 is the only seed-derived one that can be small)
    if A0 + A1 >= pool: return None
    if A3 >= A1: return None
    if A5 > pool or A6 > pool: return None
    if not (E0 <= D2 < D0 <= pool): return None          # the bestfit extension's two-hole invariant (small high, big low)
    # op schedule: ('A', size, alloc_index) / ('F', alloc_index) / ('D',) / ('Q',)
    ops = [('A', A0, 0), ('A', A1, 1), ('A', A2, 2), ('F', 1), ('A', A3, 3), ('A', A4, 4),
           ('F', 0), ('F', 3), ('A', A5, 5), ('F', 2), ('F', 4), ('A', A6, 6),
           ('F', 5), ('F', 6),                                            # free A5,A6 -> one hole [0,pool)
           ('A', D0, 7), ('A', D1, 8), ('A', D2, 9), ('A', D3, 10),       # carve 4 chunks (pool full)
           ('F', 7), ('F', 9),                                            # free D0,D2 -> TWO holes: D0=40@0, D2=24@48
           ('A', E0, 11),                                                 # E0=20: first-fit@0 vs best-fit@48 (M-bestfit diverges)
           ('D',), ('Q',)]
    return ops, sizes


def _simulate(ops, sizes, mode='genuine'):
    """Run the op list on a Heap(mode); return (alloc_offsets, live) where live = [(base, sentinel-index)] in ADDRESS
       order at the DUMP. alloc_offsets[k] = the offset (None=OOM) the kernel must emit for the k-th ALLOC."""
    h = Heap(mode=mode)
    slot = {}                                            # alloc_index -> offset
    off_seq = []
    last_writer = {}                                     # base -> alloc_index that last wrote a sentinel there
    for op in ops:
        if op[0] == 'A':
            _, size, k = op
            off = h.alloc(size)
            slot[k] = off
            off_seq.append(off)
            if off is not None:
                last_writer[off] = k                     # the module writes sentinel[k] THROUGH this ptr
        elif op[0] == 'F':
            h.free(slot.get(op[1]))
        elif op[0] == 'FO':                              # interior free (no-op under genuine exact-base match)
            base = slot.get(op[1])
            if base is not None:
                h.free(base + op[2])
        elif op[0] == 'FR':                              # wild/raw free (no-op)
            pass
    live = [(b, last_writer.get(b)) for b in h.live_bases()]
    return off_seq, live


def _forces_all(ops, sizes):
    """True iff the genuine run uses split AND prev-coalesce AND next-coalesce AND a non-MRU reuse -- checked by replaying
       and watching the free-list transitions. Implemented structurally: the skeleton is designed to force all four; we
       additionally confirm no OOM and the two coalesce-fed allocs (A5,A6) succeed where their un-merged spans alone
       could not."""
    g_off, _ = _simulate(ops, sizes, 'genuine')
    if any(o is None for o in g_off): return False        # genuine must never OOM
    # A5 (index 5) must reuse a span formed by the PREV-merge; A6 (index 6) by the NEXT-merge. If either forge that drops
    # the relevant merge OOMs that alloc, the merge is load-bearing -> forced.
    np_off, _ = _simulate(ops, sizes, 'noprevmerge')
    nn_off, _ = _simulate(ops, sizes, 'nonextmerge')
    ns_off, _ = _simulate(ops, sizes, 'nosplit')
    if np_off[5] is not None: return False                # A5 must OOM without prev-merge
    if nn_off[6] is not None: return False                # A6 must OOM without next-merge
    if ns_off[1] is not None and ns_off == g_off: return False  # nosplit must diverge (A1 onward)
    return True


def _all_forges_diverge(ops, sizes):
    g = _simulate(ops, sizes, 'genuine')
    for mode in ('bump', 'freenoop', 'nosplit', 'nocoalesce', 'noprevmerge', 'nonextmerge', 'bestfit'):
        if _simulate(ops, sizes, mode) == g:
            return False
    return True


def choose_sequence(seed, max_nonce=64):
    """Deterministically pick the first seed-derived (A0,A1,A3) whose skeleton forces every property and makes every
       forge diverge. Returns (ops, sizes, nonce). Raises if none found (ranges are wide enough that this never happens)."""
    for nonce in range(max_nonce):
        A0, A1, A3 = _derive_params(seed, nonce)
        r = _skeleton_ops(A0, A1, A3)
        if not r: continue
        ops, sizes = r
        if _forces_all(ops, sizes) and _all_forges_diverge(ops, sizes):
            return ops, sizes, nonce
    raise RuntimeError('no forcing sequence found for seed (widen ranges)')


# ============================ COM1 stream + golden ============================
def _emit_op_bytes(stream, op, sizes, sents):
    if op[0] == 'A':
        _, size, k = op
        stream += bytes([OP_ALLOC]) + le32(size) + sents[k]
    elif op[0] == 'F':
        stream += bytes([OP_FREE, op[1]])
    elif op[0] == 'FO':
        stream += bytes([OP_FREE_OFF, op[1]]) + le32(op[2])
    elif op[0] == 'FR':
        stream += bytes([OP_FREE_RAW]) + le32(op[1])
    elif op[0] == 'D':
        stream += bytes([OP_DUMP])
    elif op[0] == 'Q':
        stream += bytes([OP_DONE])


def make_witness(seed):
    """The AUTHOR-UNKNOWN make-or-break witness for `seed`: returns (com1_stream, golden_off, golden_live, sizes)."""
    ops, sizes, _ = choose_sequence(seed)
    sents = [sentinel(seed, k) for k in range(len(sizes))]
    off, live = _simulate(ops, sizes, 'genuine')
    golden_live = [(o, sents[k]) for (o, k) in live]
    stream = bytearray()
    for op in ops:
        _emit_op_bytes(stream, op, sizes, sents)
    return bytes(stream), off, golden_live, sizes


# ---- hostile / robustness legs: each returns (com1_stream, golden_off, golden_live, label, biting_mutant) ----
def make_hostile(seed, leg):
    """Build a confused-deputy / robustness leg. `biting_mutant` names the kernel mutant that should make this leg RED
       (or None for a robustness leg with no distinguishing mutant -- those only confirm the GENUINE survives + is
       output-correct, see the report on why the out-of-band-metadata design makes them non-forceable)."""
    sents = [sentinel(seed, k) for k in range(NSLOT)]     # enough for the table-fill leg (up to LARDER_MAXCHUNKS allocs)
    s0 = 40; s1 = 48                                       # two ordinary allocs (fit the tight pool, leave a remainder)
    if leg == 'interior':                                  # interior-ptr free -> genuine no-op ; M-nointeriorfree frees A1
        ops = [('A', s0, 0), ('A', s1, 1), ('FO', 1, 8), ('D',), ('Q',)]
        biting = 'nointeriorfree'
    elif leg == 'alloc0':                                  # alloc(0) -> genuine reject (ptr 0) ; M-nosizewrap returns base
        ops = [('A', s0, 0), ('A', 0, 1), ('D',), ('Q',)]
        biting = 'nosizewrap'
    elif leg == 'smallalloc':                              # sub-sentinel sizes (2,3) -> genuine reject (ptr 0) ; M-nosizewrap
        # accepts -> returns a NONZERO base to a chunk SHORTER than the 4-byte sentinel -> the SYS_DUMP readback would
        # cross the chunk boundary. This proves the FLOOR specifically (size<4), not just size==0. genuine emits 0 for
        # both; M-nosizewrap emits nonzero -> RED.
        ops = [('A', s0, 0), ('A', 2, 1), ('A', 3, 2), ('D',), ('Q',)]
        biting = 'nosizewrap'
    elif leg == 'allochuge':                               # alloc(~4GiB) -> reject (genuine + nosizewrap both OOM: robustness)
        ops = [('A', s0, 0), ('A', 0xFFFFFFFF, 1), ('D',), ('Q',)]
        biting = None
    elif leg == 'doublefree':                              # free A1 twice -> idempotent no-op (robustness)
        ops = [('A', s0, 0), ('A', s1, 1), ('F', 1), ('F', 1), ('D',), ('Q',)]
        biting = None
    elif leg == 'wildfree':                                # free a wild ptr -> no match -> no-op (robustness)
        ops = [('A', s0, 0), ('FR', WILD_PTR), ('D',), ('Q',)]
        biting = None
    elif leg == 'tablefill':                               # fill the descriptor table to LARDER_MAXCHUNKS, then ONE over-cap alloc
        # Each min-size (4B) alloc SPLITS the trailing free chunk -> +1 descriptor; LARDER_MAXCHUNKS-1 such allocs bring
        # nchunks to LARDER_MAXCHUNKS. The next (over-cap) alloc must split again but the table is FULL. Genuine: the
        # chunk-table-full guard (cmp nchunks,MAX ; jae la_oom) REJECTS it -> ptr 0 -> GREEN. M-nomaxchunks: the guard is
        # dropped -> emit_larder_split runs at nchunks==MAX -> it writes the new remainder at chunk[MAX], OVERRUNNING the
        # 16-entry descriptor array (and sets nchunks>MAX) -> the over-cap alloc emits a NONZERO ptr (+ corrupts state) -> RED.
        nfill = LARDER_MAXCHUNKS - 1                       # 15 splitting allocs -> nchunks == LARDER_MAXCHUNKS
        ops = [('A', 4, k) for k in range(nfill)] + [('A', 4, nfill), ('D',), ('Q',)]
        biting = 'nomaxchunks'
    else:
        raise ValueError('unknown leg ' + leg)
    sizes = [s0, s1, 0, 0, 0, 0, 0, 0]
    off, live = _simulate(ops, sizes, 'genuine')
    golden_live = [(o, sents[k]) for (o, k) in live]
    stream = bytearray()
    for op in ops:
        _emit_op_bytes(stream, op, sizes, sents)
    return bytes(stream), off, golden_live, leg, biting


# ============================ the GENERIC ring-3 DRIVER module (hand-asm) ============================
def module_larder_driver():
    """Interpret the COM1 op stream: ALLOC (4-byte size + 4 sentinel bytes -> SYS_ALLOC, store ptr, write sentinel THROUGH
       ptr if nonzero), FREE (1-byte k -> SYS_FREE slot[k]), FREE_OFF (1-byte k + 4-byte delta -> SYS_FREE slot[k]+delta,
       interior), FREE_RAW (4-byte ptr -> SYS_FREE ptr, wild), DUMP, DONE. All state lives at [esp+...]; registers do not
       survive int 0x30. SYS_ALLOC is given size in EBX only; SYS_FREE the ptr in ECX only."""
    m = Asm()
    def rd_byte_to(off):                                   # SYS_READ one byte -> store at [esp+off]
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
    m.raw(0x3C,OP_FREE_OFF); m.j(JE,'do_free_off_op')
    m.raw(0x3C,OP_FREE_RAW); m.j(JE,'do_free_raw_op')
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
    # ---- FREE_OFF (interior ptr = slot[k] + delta) ----
    m.lbl('do_free_off_op')
    m.raw(0xB8,0x00,0x00,0x00,0x00); m.raw(0xCD,0x30)     # read k -> eax
    m.raw(0x89,0x84,0x24); m.blob(le32(KTMP_OFF))        # mov [esp+KTMP], eax (k)
    rd4_to(SIZE_OFF)                                      # 4-byte delta -> [esp+SIZE]
    m.raw(0x8B,0x8C,0x24); m.blob(le32(KTMP_OFF))        # mov ecx,[esp+KTMP] (k)
    m.raw(0x8B,0x8C,0x8C); m.blob(le32(SLOT_OFF))        # mov ecx,[esp+ecx*4+SLOT] (the remembered ptr)
    m.raw(0x03,0x8C,0x24); m.blob(le32(SIZE_OFF))        # add ecx,[esp+SIZE] (ptr + delta -> INTERIOR)
    m.raw(0xB8); m.blob(le32(SYS_FREE)); m.raw(0xCD,0x30)
    m.j(None,'op_loop')
    # ---- FREE_RAW (wild absolute ptr) ----
    m.lbl('do_free_raw_op')
    rd4_to(SIZE_OFF)                                      # 4-byte raw ptr -> [esp+SIZE]
    m.raw(0x8B,0x8C,0x24); m.blob(le32(SIZE_OFF))        # mov ecx,[esp+SIZE]
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
       golden. pool_base is read from the kernel's OWN dumped cell table. Returns (errs, info); errs empty == GREEN."""
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


# ============================ CLI ============================
if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'kernel':                       # out [mut]  -> build the kernel ELF, print kend
        mut = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != 'none' else None
        img, kend, _ = L.build_elf(mut=mut)
        open(sys.argv[2], 'wb').write(img); print('0x%x' % kend); sys.exit(0)
    elif cmd == 'driver':                     # out  -> build the generic ring-3 driver module
        open(sys.argv[2], 'wb').write(module_larder_driver()); sys.exit(0)
    elif cmd == 'stream':                     # seedhex  -> print the COM1 byte stream (decimal bytes)
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
    elif cmd == 'hostile_stream':             # seedhex leg  -> print the hostile leg's COM1 byte stream
        seed = bytes.fromhex(sys.argv[2]); s, off, live, lbl, bit = make_hostile(seed, sys.argv[3])
        print(' '.join(str(b) for b in s)); sys.exit(0)
    elif cmd == 'hostile_grade':              # streamfile seedhex leg
        stream = open(sys.argv[2], 'rb').read(); seed = bytes.fromhex(sys.argv[3])
        _, off, live, lbl, bit = make_hostile(seed, sys.argv[4])
        errs, info = grade(stream, off, live)
        print('leg=%s biting_mutant=%s pool_base=0x%x' % (lbl, bit, info.get('pool_base', 0)))
        print('emitted alloc ptrs:', ['0x%x' % p for p in info.get('alloc_ptrs', [])])
        print('emitted live:', info.get('live', []))
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'hostile_biting':             # leg -> print the biting mutant name (or NONE)
        seed = b'\x00'*8; _, _, _, lbl, bit = make_hostile(seed, sys.argv[2]); print(bit or 'NONE'); sys.exit(0)
    else:
        raise SystemExit('usage: kernel|driver|stream|golden|grade|hostile_stream|hostile_grade|hostile_biting')
