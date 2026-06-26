#!/usr/bin/env python3
# lethe_ref.py -- STEP-0 oracle + BYTE-EXACT emitter target for "ALIAS-REMAP + TARGETED TLB INVALIDATION"
# (native-codegen Link 52 / kernel-arc link 36). THE FIRST TIME THE KERNEL MUST INVALIDATE A STALE TLB ENTRY.
# tessera (link 34) gave the stack non-identity ALIASING; cleave (link 35) gave on-demand COPY-ON-WRITE. Both reload
# cr3 (a FULL TLB flush) after every page-table edit, so a STALE per-page TLB entry never had to be reasoned about.
# lethe is the first observable that forces the TARGETED primitive: when the kernel REMAPS a LIVE alias whose
# translation the CPU has already CACHED, a cr3 flush is correct but heavy; the surgical fix is `invlpg [V]`, which
# evicts exactly the one stale entry. WITHOUT it the CPU keeps using the GHOST of the old frame -> a store through the
# remapped alias lands in the OLD physical frame and CORRUPTS a second alias that still maps it.
#
# THE SCENARIO (one ring-3 prober, K=1, the timer DISARMED via IF=0 so no cr3-reloading preempt masks the bug):
#   Three NON-IDENTITY user aliases are installed at boot (all page-aligned, in the 16 MiB identity map, distinct from
#   each other / the kernel / the regions / the frame values):
#     A (0x600000) -- the WITNESS alias, stays mapped to F for the whole test.
#     V (0x800000) -- the REMAPPED alias: starts -> F, the kernel later remaps it -> F'.
#     B (0xC00000) -- a second witness alias, mapped to F' (so it reads F''s content).
#     F (0xA00000) -- the original shared physical frame (A and V both map it at boot).
#     F'(0xE00000) -- the fresh frame V is remapped to (F' != F, != any vaddr); pre-seeded with OLD_FP so a
#                     "no write reached F'" case is detectable.
#   1. The prober reads a late-bound seed byte (SYS_READ over COM1), derives two distinct dwords x=hx(seed),y=hy(seed).
#   2. WARM (LOAD-BEARING): write x to [V] (goes to F), read [A] (== x: confirms A,V alias F AND warms V->F into the TLB).
#   3. SYS_REMAP (int 0x30, eax=4): the kernel sets PTE[V] <- F'|7 and -- the link -- `invlpg [V]`. iret back.
#   4. write y to [V]  (WITH invlpg: a fresh walk -> F'; WITHOUT: the stale TLB entry -> the OLD frame F).
#   5. read [A] (-> F), read [V] (-> F' if invlpg else stale F), read [B] (-> F'). SYS_WRITE all three. SYS_EXIT.
#   GENUINE output: A==x, V==y, B==y.
#
# WHY GENUINELY OUTPUT-FORCED (within ONE execution; the cleave/homestead lesson -- a bare PTE edit is output-invisible,
# observable only via ALIASING). The corruption is observed in A, a DIFFERENT alias than the one written: with the
# stale entry, step-4's write y lands in F, so A (which still maps F) reads y instead of x -- A is CORRUPTED by the
# ghost. THREE binding layers:
#   (1) RUNTIME OUTPUT: M-noinvlpg (drop the invlpg) makes step-4 land in F -> A==y (corruption), B==OLD_FP -> RED.
#       The seed is late-bound so x,y cannot be baked.
#   (2) WHITE-BOX (assert_lethe): the SYS_REMAP arm must contain `0F 01 3D <le32(V)>` (invlpg of EXACTLY V) and must
#       NOT contain `0F 22 D8` (mov cr3) in that arm -- forcing the TARGETED primitive, not the heavy cr3 flush.
#       M-cr3insteadofinvlpg (a correct-output cr3 flush) is GREEN on output but assert_lethe REJECTS it.
#   (3) DIFFERENTIAL: a kernel that doesn't remap (M-noremap) leaves V->F -> step-4 y lands in F -> A==y, B==OLD_FP -> RED.
# Built additively on the FROZEN cleave lineage (lethe_ref started as a structural copy of cleave_ref): lodger parse +
# nokta paging-U/S + geeking fault->continue + tickover preempt + rollcall table + tenement reclaim + homestead grow +
# furlough block/wake + tessera alias + cleave COW. cleave's COW arm is REMOVED here (lethe's remap is a SYSCALL, not a
# #PF); cleave's preemptive/multi-proc/block machinery is inherited but INERT under K=1 + IF=0.
#
# Citations to cleave_ref.py line numbers appear inline (cleave Lnn) for each reused block.
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# durable_ref clones platter_ref (the FROZEN link37 block-device kernel) and adds SYS_DISK_WRITE (eax=6) -> DURABILITY.
# Locate holler_ref (the frozen lineage import) in the herbert tests dir if not beside this file (scratch build).
for _p in (os.path.dirname(os.path.abspath(__file__)),
           '/home/gulpin/Desktop/MEWTWO/herbert/bootstrap/tests'):
    if os.path.exists(os.path.join(_p, 'holler_ref.py')): sys.path.insert(0, _p)
import holler_ref as H
from holler_ref import Asm, gdt_desc, idt_gate, le16

OUT=H.OUT; LOAD=H.LOAD; ENTRY=H.ENTRY                                          # cleave L52
KCODE=H.KCODE; KDATA=H.KDATA; UCODE=H.UCODE; UDATA=H.UDATA; TSS_SEL=H.TSS_SEL  # cleave L53
UCODE3=H.UCODE3; UDATA3=H.UDATA3                                               # cleave L54
SYS_READ=0; SYS_EXIT=1; SYS_WRITE=2; SYS_REMAP=4   # cleave L55 + lethe: SYS_REMAP=4 (unused eax) -- the alias remap
SYS_DISK_READ=5            # link37 NEW (frozen platter): ATA PIO LBA28 single-sector read, access_ok on the read LBA
SYS_DISK_WRITE=6           # link38 NEW (DURABILITY): ATA PIO LBA28 single-sector WRITE + CACHE FLUSH, access_ok on the WRITE LBA
SYS_FS_PUT=7               # link39 NEW (FILESYSTEM CAIRN): name a payload + persist it (dir entry + data sector + flush)
SYS_FS_GET=8               # link39 NEW (FILESYSTEM CAIRN): resolve a name -> the stored payload (fixed-loop dir scan, data_lba bounded)
# The future compiler emit-mode marker for this link (baked into gen-1): `-- emit: multiboot32-cairn`.
# ---- link37 (the kernel's FIRST BLOCK DEVICE: a random-access disk READ) constants ----
# A confused-deputy disk read. The module puts an LBA in EBX and a byte-offset (0..511) in ECX; the kernel
# BOUNDS-CHECKS the LBA to a reserved window [DISK_RESV_LO, DISK_RESV_HI) (so a module can't read GRUB / the
# FAT partition / arbitrary sectors -- an access_ok on the LBA), does an ATA PIO LBA28 single-sector read of
# that LBA into a 512-byte KERNEL buffer, and returns the byte at [buf+ECX] in EAX. iret back to the module.
# The chase is a POINTER-CHASE: each sector's byte 0 NAMES the next sector as an INDEX into the window, so the
# next LBA = DISK_RESV_LO + b. A serial COM1 stream cannot reproduce a DATA-DEPENDENT random-access order.
DISK_RESV_LO = 120000      # reserved-window low LBA (STEP-0 proved 120000+ is safe -- past GRUB/FAT)
DISK_RESV_HI = 120064      # reserved-window high LBA (exclusive): 64 sectors, indices 0..63
DISK_KHOPS   = 4           # K=4 data-dependent hops (unrolled in the prober; no loops in Herbert)
DISK_START_IDX = 7         # the START sector's index within the window (LBA = DISK_RESV_LO + 7); author-known
assert DISK_RESV_LO < DISK_RESV_HI and DISK_RESV_HI - DISK_RESV_LO <= 256, 'window indices must fit a byte'
assert 0 <= DISK_START_IDX < (DISK_RESV_HI - DISK_RESV_LO), 'start index in-window'
ATA_PORTS = dict(data=0x1F0, sectcnt=0x1F2, lba0=0x1F3, lba1=0x1F4, lba2=0x1F5, drvhd=0x1F6, cmdsts=0x1F7)
DISK_DEBUG = bool(int(os.environ.get('DISK_DEBUG','0')))
# ---- link38 (DURABILITY: a byte WRITTEN by the kernel SURVIVES A REBOOT) constants ----
# SYS_DISK_WRITE is a confused-deputy disk WRITE. The module supplies an LBA in EBX, a byte-offset (0..511) in
# ECX, and the BYTE to write in DL (EDX low 8 bits). The kernel (CPL0) BOUNDS-CHECKS the LBA to a RESERVED WRITE
# window [DISK_WRESV_LO, DISK_WRESV_HI) so a hostile writer cannot scribble GRUB / the FAT partition / the MBR /
# arbitrary sectors -- a WRITE-ANYWHERE primitive is WORSE than the read leak: this bound is CRITICAL. It then
# bounds ECX<512 (else an arbitrary kernel WRITE past diskbuf), does an ATA software RESET prologue (STEP-0 proved
# Bochs needs it for writes), builds the sector in the kernel diskbuf (zero it, set diskbuf[ECX]=DL), ATA LBA28
# WRITES the sector to that LBA, then ATA CACHE FLUSH (0xE7) so the write survives a power cycle/reboot. iret back.
# On a rejected LBA/offset -> sentinel (no write at all), iret.
#
# WINDOW CHOICE (important, additive-frozen-read constraint): the READ arm is FROZEN byte-identical to platter, whose
# access_ok is the READ window [DISK_RESV_LO=120000, DISK_RESV_HI=120064). The BOOT-2 reader reads the durable byte
# back via SYS_DISK_READ (the frozen read arm), so the durable sector MUST be readable -> the WRITE window is a clean
# reserved SUB-RANGE at the TOP of the read window: [120060, 120064) (4 sectors). A write is bounded to those 4
# sectors (a hostile write to the MBR / GRUB / the chase sectors [120000,120060) is REJECTED -- the read-only chase
# data is protected), yet the unchanged reader can read the durable sector back (120060..120063 are in [120000,120064)).
# The chase prober (frozen platter) starts at index 7 and would only touch the top sectors via a data-dependent hop;
# the durability test does not run the chase, so there is no interference.
DISK_WRESV_LO = 120060     # reserved WRITE-window low LBA (a sub-range at the TOP of the FROZEN read window)
DISK_WRESV_HI = 120064     # reserved WRITE-window high LBA (exclusive) == the read window's HI: 4 sectors, indices 0..3
assert DISK_RESV_LO <= DISK_WRESV_LO and DISK_WRESV_HI <= DISK_RESV_HI, 'the write window must sit INSIDE the frozen read window (so the unchanged reader can read the durable sector back)'
assert DISK_WRESV_LO < DISK_WRESV_HI and DISK_WRESV_HI - DISK_WRESV_LO <= 256, 'write-window indices fit a byte'
DUR_WLBA = DISK_WRESV_LO   # the durability prober writes/reads the FIRST sector of the write window, offset 0
DUR_OFF  = 0               # the in-sector byte offset the durability byte X lands at (offset 0)
assert DISK_WRESV_LO <= DUR_WLBA < DISK_WRESV_HI, 'the durability LBA is inside the write window'
assert DISK_RESV_LO <= DUR_WLBA < DISK_RESV_HI, 'the durable sector must be READABLE by the frozen read arm'
DUR_SEED = 0x5A            # default late-bound COM1 byte X for the writer prober (the kernel reads it; CPL3 cannot)
# ---- link39 (FILESYSTEM CAIRN: a PERSISTENT NAMED LOOKUP) constants ----
# The cairn is the first time a kernel-written byte is resolved by NAME across a reboot, not by raw LBA. A tiny on-disk
# FS lives in a NEW reserved window past durable's [120000,120064): ONE directory sector + D=8 data sectors. The
# directory is a FIXED array of D slots; SYS_FS_PUT appends an entry (allocates the next data sector by INSERTION ORDER,
# data_lba = FS_DATA_LO + nentries -- NOT name-derived) and SYS_FS_GET scans the D slots for an exact 16-byte name match.
# The new SECURITY surface vs durable: the stored data_lba in a matched dir entry is an ATTACKER-INFLUENCED capability
# (a hostile PUT could write a dir entry naming data_lba=0=the MBR); the GET MUST bound the stored data_lba to
# [FS_DATA_LO,FS_DATA_HI) BY VALUE before the ATA read, else it is an arbitrary-sector read primitive.
FS_DIR_LBA   = 120064       # the ONE directory sector (immediately past durable's read window HI -- additive, untouched)
FS_DATA_LO   = 120065       # data-sector window low LBA (inclusive): one <=512B payload per sector
FS_DATA_HI   = 120073       # data-sector window high LBA (exclusive): D=8 data sectors, indices 0..7
FS_D         = FS_DATA_HI - FS_DATA_LO   # D = number of directory slots / data sectors (8)
FS_NAMELEN   = 16           # fixed name length in bytes (a full 16-byte compare, never a NUL/prefix scan)
FS_ENTSZ     = 28           # dir entry: {valid:u32, len:u32, name:16, data_lba:u32} = 4+4+16+4 = 28 bytes
FS_MAXLEN    = 512          # max payload length (one sector)
assert FS_D == 8, 'cairn: D=8 directory slots / data sectors'
assert FS_ENTSZ * FS_D <= 512, 'all D dir entries must fit one 512B directory sector'
assert FS_DATA_LO < FS_DATA_HI, 'the data window must be non-empty'
assert FS_DIR_LBA < FS_DATA_LO, 'the directory sector sits before the data window'
# ADDITIVITY: the cairn FS window [FS_DIR_LBA, FS_DATA_HI) must NOT overlap durable's read/write windows (those arms are
# FROZEN byte-identical). durable read window = [DISK_RESV_LO=120000, DISK_RESV_HI=120064); write = [120060,120064).
assert FS_DIR_LBA >= DISK_RESV_HI, 'the cairn FS window must sit PAST durable\'s read window (additive, no overlap)'
# Dir-entry field byte offsets within a 28-byte entry:
FS_OFF_VALID = 0            # u32 valid (1 = live, 0 = empty)
FS_OFF_LEN   = 4            # u32 payload length
FS_OFF_NAME  = 8            # 16 bytes: the name
FS_OFF_LBA   = 24           # u32 data_lba (the sector holding the payload)
# STEP-0 forcing names/payloads (hardcoded in the prober for STEP-0; late-binding over COM1 is for the real gate).
def fs_name(s16):
    b = s16.encode('ascii')[:FS_NAMELEN]
    return b + b'\x00' * (FS_NAMELEN - len(b))
FS_NAME_ALPHA = fs_name('ALPHA')    # the TARGET record name (16B, NUL-padded)
FS_NAME_BRAVO = fs_name('BRAVO')    # the DECOY record name
FS_PAY_ALPHA  = b'TARGET-payload-alpha'    # the TARGET payload (distinctive)
FS_PAY_BRAVO  = b'decoy-payload-bravo!!'    # the DECOY payload (a DIFFERENT byte string, same length here)
assert FS_NAME_ALPHA != FS_NAME_BRAVO, 'TARGET and DECOY names must differ'
assert FS_PAY_ALPHA != FS_PAY_BRAVO, 'TARGET and DECOY payloads must differ'
assert len(FS_PAY_ALPHA) <= FS_MAXLEN and len(FS_PAY_BRAVO) <= FS_MAXLEN, 'payloads fit one sector'
NPT=4                       # cleave L56: 4 page tables -> identity-map 16 MiB
PIT_DIV=0xFFFF              # cleave L57
MAXPROC=8                   # cleave L58: process-table capacity (compile-time cap; K<=MAXPROC at runtime)
MSLOTS=MAXPROC              # cleave L59: mint a region page PER proc
assert MSLOTS<=MAXPROC, 'MSLOTS must fit the process table'                    # cleave L61
GROWMAX=8                   # cleave L62: grow-window pages reserved below each proc's stack page (inherited; inert)
assert GROWMAX>=1, 'GROWMAX must reserve at least one grow page'               # cleave L65
GROWBYTES=GROWMAX*0x1000    # cleave L66
GROWER_N   = 400            # cleave L67 (inherited; inert)
GROWER_FRAME = 16           # cleave L68
GROWER_SEED = 0x5A          # cleave L69
# ---- furlough (block/wake) forcing constants (inherited; inert in lethe's scenario) ---- (cleave L70-73)
FBYTE   = 0x5A
RDR_TAG = 0xAB0000
FURL_SEED = 0x5EED1
# ---- lethe (ALIAS-REMAP + TARGETED TLB INVALIDATION) constants ----
# Three NON-IDENTITY aliases of physical frames F, F', all page-aligned, in the 16 MiB identity map, above the kernel
# (~1 MiB) and regions, RESERVED from the region bump allocator via fixed excl[] entries (mirrors cleave's SH_*/excl).
A_VADDR  = 0x600000         # the WITNESS alias: stays mapped to F for the whole test (identity frame 0x600000 ABANDONED)
V_VADDR  = 0x800000         # the REMAPPED alias: starts -> F, the kernel remaps it -> F' (the stale-TLB target)
B_VADDR  = 0xC00000         # a second witness alias: mapped to F' (reads F''s content)
F_FRAME  = 0xA00000         # F: the original shared physical frame (A and V both map it at boot; != any vaddr)
FP_FRAME = 0xE00000         # F': the fresh frame V is remapped to (F' != F, != any vaddr)
OLD_FP   = 0x3333CCCC       # pre-seed at F''s test slot so a "no write reached F'" case is detectable (distinct dword)
TEST_OFF = 0               # the test dword offset within each frame (word 0)
LETHE_TAG_X = 0x5A0000     # x = (LETHE_TAG_X | (seed&0xFF))         -- the WARM word (lands in F, read back via A)
LETHE_TAG_Y = 0x7B0000     # y = (LETHE_TAG_Y | (seed&0xFF)) + 0x40 -- the post-remap word (must land in F' via invlpg)
LETHE_SEED = 0x5A          # default late-bound seed byte for the prober (fed over COM1; the kernel is seed-agnostic)
def lethe_x(seed): return (LETHE_TAG_X | (seed & 0xFF)) & 0xFFFFFFFF
def lethe_y(seed): return ((LETHE_TAG_Y | (seed & 0xFF)) + 0x40) & 0xFFFFFFFF
def lethe_expect(seed):    # (A,V,B) the prober must emit: A==x (F untouched after remap), V==y, B==y (both -> F')
    x=lethe_x(seed); y=lethe_y(seed); return (x,y,y)
assert len({A_VADDR,V_VADDR,B_VADDR,F_FRAME,FP_FRAME})==5, 'lethe aliases + frames must be distinct'
assert F_FRAME!=FP_FRAME, 'F and F\' must differ (the remap must move to a NEW frame)'
assert F_FRAME not in (A_VADDR,V_VADDR,B_VADDR), 'F must be NON-IDENTITY (frame != vaddr)'
assert FP_FRAME not in (A_VADDR,V_VADDR,B_VADDR), 'F\' must be NON-IDENTITY (frame != vaddr)'
assert all(x<NPT*0x400000 and x%0x1000==0 for x in (A_VADDR,V_VADDR,B_VADDR,F_FRAME,FP_FRAME)), 'all in identity map, page-aligned'
for _s in (LETHE_SEED, 0x4D):
    _x,_y=lethe_x(_s),lethe_y(_s)
    assert len({_x,_y,OLD_FP})==3, 'x,y,OLD_FP must be distinct for every seed used'
NEXCL=9+3*MAXPROC           # cleave L113: 9 fixed (kernel/mb/cm/elf/mmap + lethe A/V/B + frame-pair window) + 2/module + 1/region
assert NEXCL >= 8+3*MAXPROC, 'excl[] must hold 8+ fixed + 2/module + 1/region for K up to MAXPROC'
JNE,JE,JB,JAE,JA,JBE=0x85,0x84,0x82,0x83,0x87,0x86   # cleave L119
JS=0x88                     # cleave L120
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)   # cleave L121
def s32(v): return struct.pack('<i', v)                 # cleave L122
REGN={'eax':0,'ecx':1,'edx':2,'ebx':3,'esp':4,'ebp':5,'esi':6,'edi':7}   # cleave L123

# ---- cell layout (cleave L125-145): scalars, per-process PARALLEL ARRAYS (MAXPROC each), then excl[] arrays (NEXCL each) ----
SCALARS=['mbinfo','flags','cmdline','elflo','elfhi','mm_lo','mm_hi','region_lo','region_hi',
         'nprocs','cur','live','switches','nexcl','answer','tmp0','tmp1','cow_next',  # cleave L126-127 (cow_next kept inert)
         'tmp2',  # link38: tmp2 holds the SYS_DISK_WRITE LBA (saved after the access_ok, like platter's tmp1 for reads)
         'fs_nameptr','fs_payptr','fs_len','fs_lba','fs_nent','fs_i','fs_match']  # link39: FS scratch (name/pay ptrs, len, data_lba, nentries, loop i, match flag)
PARR=['modstart','modend','st_lo','st_hi','alloc_lo','alloc_hi','grow_floor','started','exited',
      't_edi','t_esi','t_ebp','t_ebx','t_edx','t_ecx','t_eax','t_eip','t_eflags','t_esp',
      'blocked','disp']     # cleave L128-130
CELLS=[]
CELLS+= SCALARS
_ARRBASE={}
for nm in PARR:
    _ARRBASE[nm]=len(CELLS)
    CELLS+=[f'{nm}#{i}' for i in range(MAXPROC)]
_EXCLLO=len(CELLS); CELLS+=[f'excl_lo#{i}' for i in range(NEXCL)]
_EXCLHI=len(CELLS); CELLS+=[f'excl_hi#{i}' for i in range(NEXCL)]
CIDX={n:i for i,n in enumerate(CELLS)}
CELLBASE=ENTRY+6+5            # cleave L140
def cell(n): return CELLBASE+CIDX[n]*4     # cleave L141
def arr(nm): return CELLBASE+_ARRBASE[nm]*4   # cleave L142
def excl_lo(): return CELLBASE+_EXCLLO*4      # cleave L143
def excl_hi(): return CELLBASE+_EXCLHI*4      # cleave L144
ANSWER=cell('answer')        # cleave L145


def build_code(kstack, kend, mut=None, stage='full'):
    a=Asm()
    a._ctr=0
    # ---- byte helpers (cleave L151-179, VERBATIM) ----
    def mmi(addr,imm): a.raw(0xC7,0x05); a.blob(le32(addr)); a.blob(le32(imm))   # mov dword[addr],imm
    def mme(addr): a.raw(0xA3); a.blob(le32(addr))                               # mov [addr],eax
    def mem(addr): a.raw(0xA1); a.blob(le32(addr))                               # mov eax,[addr]
    def outi(v): a.raw(0xB0,v,0xE6,OUT)
    def dr_eax():
        a.raw(0xE6,OUT)
        for _ in range(3): a.raw(0xC1,0xE8,0x08,0xE6,OUT)
    def alignup_eax(): a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def ld(dst,base,idx):
        sib=0x80|(REGN[idx]<<3)|0x05
        a.raw(0x8B,(REGN[dst]<<3)|0x04,sib); a.blob(le32(base))
    def st(base,idx,src):
        sib=0x80|(REGN[idx]<<3)|0x05
        a.raw(0x89,(REGN[src]<<3)|0x04,sib); a.blob(le32(base))
    def pushidx(base,idx):
        sib=0x80|(REGN[idx]<<3)|0x05
        a.raw(0xFF,0x34,sib); a.blob(le32(base))
    def load_kdata(): a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    def load_udata(): a.raw(0xB8); a.blob(le32(UDATA3)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    def flip_pg(base,idx,setU):
        ld('eax',base,idx)
        a.raw(0xC1,0xE8,0x0A); a.raw(0x25); a.blob(le32(0xFFFFFFFC)); a.raw(0x05); a.absR('pt')
        if setU: a.raw(0x83,0x08,0x04)
        else:    a.raw(0x83,0x20,0xFB)
    def shutdown():
        a.raw(0x66,0xBA,0xF4,0x00); a.raw(0xEE)
        a.raw(0x66,0xBA,0x00,0x89)
        for ch in b'Shutdown': a.raw(0xB0,ch,0xEE)
        a.raw(0xFA,0xF4,0xEB,0xFD)

    # ---- link39 (FILESYSTEM CAIRN) inline ATA helpers. The cairn FS arms read/write WHOLE sectors (the directory sector
    # and a data sector) to/from a KERNEL buffer at an arbitrary (already-bounds-checked) LBA. These mirror the durable
    # read/write inline ATA PIO LBA28 sequences EXACTLY (same opcodes, same cld-before-rep, same software-RESET prologue
    # for writes) but parameterized over (buffer-label, lba-cell). Each call site gets UNIQUE poll labels via a counter.
    # DS/ES=KDATA (flat) must already be set by the caller. The LBA in `lba_cell` is the caller's RESPONSIBILITY to bound
    # BY VALUE before calling (the confused-deputy access_ok lives in the arm, not here).
    def _uniq(tag):
        a._ctr += 1
        return 'g_%s_%d' % (tag, a._ctr)
    def ata_read_sector(buf_label, lba_cell):
        # ATA PIO LBA28 single-sector READ of [lba_cell] into kernel buffer `buf_label` (512 bytes). Mirrors do_disk_read.
        a.raw(0x66,0xBA,0xF6,0x01); a.raw(0xB0,0xE0,0xEE)  # mov dx,0x1F6 ; mov al,0xE0 (master,LBA,27:24=0) ; out
        a.raw(0x66,0xBA,0xF2,0x01); a.raw(0xB0,0x01,0xEE)  # mov dx,0x1F2 ; mov al,1 (sector count) ; out
        a.raw(0x66,0xBA,0xF3,0x01); mem(lba_cell); a.raw(0xEE)                  # 0x1F3 ; LBA[7:0]  ; out
        a.raw(0x66,0xBA,0xF4,0x01); mem(lba_cell); a.raw(0xC1,0xE8,0x08,0xEE)   # 0x1F4 ; LBA[15:8] ; out
        a.raw(0x66,0xBA,0xF5,0x01); mem(lba_cell); a.raw(0xC1,0xE8,0x10,0xEE)   # 0x1F5 ; LBA[23:16]; out
        a.raw(0x66,0xBA,0xF7,0x01); a.raw(0xB0,0x20,0xEE)  # mov dx,0x1F7 ; mov al,0x20 (READ SECTORS) ; out
        bsy=_uniq('rbsy'); drq=_uniq('rdrq')
        a.lbl(bsy)
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)                    # in al,0x1F7
        a.raw(0xA8,0x80); a.j(JNE,bsy)                     # test al,0x80 ; jnz -> still BSY
        a.lbl(drq)
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)
        a.raw(0xA8,0x08); a.j(JE,drq)                      # test al,0x08 ; jz -> DRQ not ready
        a.raw(0x66,0xBA,0xF0,0x01)                         # mov dx,0x1F0 (data port)
        a.raw(0xBF); a.absR(buf_label)                     # mov edi, buf
        a.raw(0xB9,0x00,0x01,0x00,0x00)                    # mov ecx,256
        if mut!='fsnocld': a.raw(0xFC)                     # cld (forward; FS-helper sector READ. M-fsnocld drops it so a hostile std=DF=1 is NOT cleared before the downstream FS cmpsb/movsb -- this upstream cld would otherwise mask the FS-arm cld threat)
        a.raw(0x66,0xF3,0x6D)                              # rep insw (16-bit) -> 512 bytes
    def ata_write_sector(buf_label, lba_cell):
        # ATA software-RESET prologue + LBA28 single-sector WRITE of kernel buffer `buf_label` to [lba_cell] + CACHE
        # FLUSH (so the write reaches the medium). Mirrors do_disk_write's ATA (c)+(d). The CALLER builds buf first.
        a.raw(0x66,0xBA,0xF6,0x01); a.raw(0xB0,0xA0,0xEE)  # mov dx,0x1F6 ; mov al,0xA0 (select master) ; out
        a.raw(0x66,0xBA,0xF6,0x03); a.raw(0xB0,0x06,0xEE)  # mov dx,0x3F6 ; mov al,0x06 (SRST=1,nIEN=1) ; out
        d1=_uniq('wrdly1'); d2=_uniq('wrdly2'); rb=_uniq('wrbsy'); rr=_uniq('wrrdy')
        a.raw(0xB9); a.blob(le32(5))
        a.lbl(d1); a.raw(0x66,0xBA,0xF6,0x03,0xEC); a.raw(0xE2,0xFB)            # delay loop (read alt-status)
        a.raw(0x66,0xBA,0xF6,0x03); a.raw(0xB0,0x02,0xEE)  # mov dx,0x3F6 ; mov al,0x02 (SRST=0, nIEN=1) ; out
        a.raw(0xB9); a.blob(le32(5))
        a.lbl(d2); a.raw(0x66,0xBA,0xF6,0x03,0xEC); a.raw(0xE2,0xFB)
        a.lbl(rb); a.raw(0x66,0xBA,0xF7,0x01,0xEC); a.raw(0xA8,0x80); a.j(JNE,rb)   # wait BSY clear
        a.lbl(rr); a.raw(0x66,0xBA,0xF7,0x01,0xEC); a.raw(0xA8,0x40); a.j(JE,rr)    # wait RDY set
        # program + write
        a.raw(0x66,0xBA,0xF6,0x01); a.raw(0xB0,0xE0,0xEE)  # mov dx,0x1F6 ; al=0xE0 ; out
        a.raw(0x66,0xBA,0xF2,0x01); a.raw(0xB0,0x01,0xEE)  # mov dx,0x1F2 ; al=1 ; out
        a.raw(0x66,0xBA,0xF3,0x01); mem(lba_cell); a.raw(0xEE)                  # LBA[7:0]
        a.raw(0x66,0xBA,0xF4,0x01); mem(lba_cell); a.raw(0xC1,0xE8,0x08,0xEE)   # LBA[15:8]
        a.raw(0x66,0xBA,0xF5,0x01); mem(lba_cell); a.raw(0xC1,0xE8,0x10,0xEE)   # LBA[23:16]
        a.raw(0x66,0xBA,0xF7,0x01); a.raw(0xB0,0x30,0xEE)  # mov dx,0x1F7 ; al=0x30 (WRITE SECTORS) ; out
        wb=_uniq('wwbsy'); wd=_uniq('wwdrq'); dn=_uniq('wwdone'); fb=_uniq('wfbsy')
        a.lbl(wb); a.raw(0x66,0xBA,0xF7,0x01,0xEC); a.raw(0xA8,0x80); a.j(JNE,wb)   # wait BSY clear
        a.lbl(wd); a.raw(0x66,0xBA,0xF7,0x01,0xEC); a.raw(0xA8,0x08); a.j(JE,wd)    # wait DRQ set
        a.raw(0x66,0xBA,0xF0,0x01)                         # mov dx,0x1F0 (data port)
        a.raw(0xBE); a.absR(buf_label)                     # mov esi, buf
        a.raw(0xB9,0x00,0x01,0x00,0x00)                    # mov ecx,256
        if mut!='fsnocld': a.raw(0xFC)                     # cld (FS-helper sector WRITE; M-fsnocld drops it -> a hostile std=DF=1 walks the sector send BACKWARD, leaking page-table bytes below the buffer to disk)
        a.raw(0x66,0xF3,0x6F)                              # rep outsw (16-bit) -> 512 bytes
        a.lbl(dn); a.raw(0x66,0xBA,0xF7,0x01,0xEC); a.raw(0xA8,0x80); a.j(JNE,dn)   # wait BSY clear (data accepted)
        a.raw(0x66,0xBA,0xF7,0x01); a.raw(0xB0,0xE7,0xEE)  # mov dx,0x1F7 ; al=0xE7 (CACHE FLUSH) ; out
        a.lbl(fb); a.raw(0x66,0xBA,0xF7,0x01,0xEC); a.raw(0xA8,0x80); a.j(JNE,fb)   # wait BSY clear

    # ===== prologue (cleave L181-188, VERBATIM) =====
    a.blob(bytes((0x89,0x1D))+le32(cell('mbinfo')))   # mov [mbinfo],ebx  (byte 0)
    a.j(None,'glue')
    a.blob(b'\x00'*(len(CELLS)*4))                     # the cell storage block (CELLBASE..)
    sd_FAILS=['F1','F2','F3','F4','F5','F8','F9','F10','FOVER']
    for idx,f in enumerate(sd_FAILS):
        a.lbl(f); a.blob(bytes([176,0x31+idx,0xE6,OUT])); a.j(None,'sdtail')
    a.lbl('sdtail'); shutdown()

    # ===== glue: validate multiboot magic, set up stack, read mbinfo fields (cleave L190-209, VERBATIM) =====
    a.lbl('glue')
    a.raw(0x3D); a.blob(le32(0x2BADB002)); a.j(JNE,'F1')
    a.raw(0xBC); a.blob(le32(kstack))
    a.raw(0x31,0xC0); a.raw(0x0F,0x22,0xE0)            # xor eax,eax; mov cr4,eax
    a.raw(0x68); a.blob(le32(0x00000002)); a.raw(0x9D) # push 2; popf  (clear flags, IF=0)
    a.raw(0x8B,0x35); a.blob(le32(cell('mbinfo')))     # mov esi,[mbinfo]
    a.raw(0x8B,0x06); mme(cell('flags'))
    a.raw(0xA8,0x08); a.j(JE,'F2')                     # require mods (bit3)
    a.raw(0xA8,0x40); a.j(JE,'F3')                     # require mmap (bit6)
    a.raw(0xA8,0x04); a.j(JE,'no_cmd')                 # cmdline (bit2)
    a.raw(0x8B,0x46,16); mme(cell('cmdline')); a.j(None,'cmd_done')
    a.lbl('no_cmd'); mmi(cell('cmdline'),0); a.lbl('cmd_done')
    a.raw(0xF7,0x06); a.blob(le32(0x20)); a.j(JE,'no_elf')
    a.raw(0x8B,0x46,36); mme(cell('elflo'))
    a.raw(0x8B,0x46,28); a.raw(0x0F,0xAF,0x46,32); a.raw(0x03,0x46,36); mme(cell('elfhi'))
    a.j(None,'elf_done'); a.lbl('no_elf'); mmi(cell('elflo'),0); mmi(cell('elfhi'),0); a.lbl('elf_done')
    a.raw(0x8B,0x46,48); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_lo'))
    a.raw(0x8B,0x46,48); a.raw(0x03,0x46,44); a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_hi'))

    # ===== K-GENERIC module parse (cleave L211-239, VERBATIM; K=1 here but the loop stays generic) =====
    a.raw(0x8B,0x46,20)                                # eax = mods_count
    a.raw(0x83,0xF8,MAXPROC); a.j(JA,'FOVER')
    a.raw(0x83,0xF8,0x01); a.j(JB,'F4')
    mme(cell('nprocs'))
    mme(cell('live'))
    a.raw(0x8B,0x6E,24)                                # ebp = mods_addr
    a.raw(0x31,0xC9)
    a.lbl('parseloop')
    a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JAE,'parsedone')
    a.raw(0x89,0xC8); a.raw(0xC1,0xE0,0x04); a.raw(0x01,0xE8)
    a.raw(0x89,0xC2)
    a.raw(0x8B,0x02); st(arr('modstart'),'ecx','eax')
    a.raw(0x8B,0x42,0x04); st(arr('modend'),'ecx','eax')
    a.raw(0x8B,0x42,0x08)
    a.raw(0x85,0xC0); a.j(JE,'nostr')
    a.raw(0x25); a.blob(le32(0xFFFFF000)); st(arr('st_lo'),'ecx','eax')
    a.raw(0x05); a.blob(le32(0x2000)); st(arr('st_hi'),'ecx','eax')
    a.j(None,'strdone')
    a.lbl('nostr')
    a.raw(0x31,0xC0); st(arr('st_lo'),'ecx','eax'); st(arr('st_hi'),'ecx','eax')
    a.lbl('strdone')
    ld('eax',arr('modstart'),'ecx'); ld('edx',arr('modend'),'ecx'); a.raw(0x39,0xD0); a.j(JAE,'F5')
    a.raw(0x41); a.j(None,'parseloop')
    a.lbl('parsedone')

    # ===== excl[] array (cleave L241-274): 5 fixed + lethe A/V/B + frame-pair window + 2 per module =====
    a.raw(0x31,0xFF)
    def excl_push(lo_emit, hi_emit):
        lo_emit(); st(excl_lo(),'edi','eax')
        hi_emit(); st(excl_hi(),'edi','eax')
        a.raw(0x47)
    def _mbwin_lo(): mem(cell('mbinfo')); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def _mbwin_hi(): mem(cell('mbinfo')); a.raw(0x25); a.blob(le32(0xFFFFF000)); a.raw(0x05); a.blob(le32(0x2000))
    def _cmwin_lo(): mem(cell('cmdline')); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def _cmwin_hi(): mem(cell('cmdline')); a.raw(0x25); a.blob(le32(0xFFFFF000)); a.raw(0x05); a.blob(le32(0x2000))
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(0x100000))),        # kernel image [0x100000, kend]
              lambda:(a.raw(0xB8),a.blob(le32(kend))))
    excl_push(_mbwin_lo, _mbwin_hi)
    excl_push(_cmwin_lo, _cmwin_hi)
    excl_push(lambda:mem(cell('elflo')), lambda:mem(cell('elfhi')))
    excl_push(lambda:mem(cell('mm_lo')), lambda:mem(cell('mm_hi')))
    # lethe: reserve the three alias vaddr pages AND the F/F' frames from the region allocator (cleave L258-262 analogue).
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(A_VADDR))), lambda:(a.raw(0xB8),a.blob(le32(A_VADDR+0x1000))))     # A page
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(V_VADDR))), lambda:(a.raw(0xB8),a.blob(le32(V_VADDR+0x1000))))     # V page
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(B_VADDR))), lambda:(a.raw(0xB8),a.blob(le32(B_VADDR+0x1000))))     # B page
    # F and F' span [F, F+0x1000) and [F', F'+0x1000); reserve the pair window [min, max+0x1000) (F=0xA00000, F'=0xE00000,
    # contiguous-enough as one window also reserves the gap, which is fine -- it only over-reserves identity frames the
    # region allocator would otherwise hand out, all above the kernel). One excl entry suffices for the pair window.
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(min(F_FRAME,FP_FRAME)))),
              lambda:(a.raw(0xB8),a.blob(le32(max(F_FRAME,FP_FRAME)+0x1000))))                                   # F/F' window
    a.raw(0x31,0xC9)
    a.lbl('mexcl')
    a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JAE,'mexcldone')
    ld('eax',arr('modstart'),'ecx'); st(excl_lo(),'edi','eax')
    ld('eax',arr('modend'),'ecx');   st(excl_hi(),'edi','eax'); a.raw(0x47)
    ld('eax',arr('st_lo'),'ecx'); st(excl_lo(),'edi','eax')
    ld('eax',arr('st_hi'),'ecx'); st(excl_hi(),'edi','eax'); a.raw(0x47)
    a.raw(0x41); a.j(None,'mexcl')
    a.lbl('mexcldone')
    a.raw(0x89,0x3D); a.blob(le32(cell('nexcl')))

    # ===== memory-map scan -> region_lo/region_hi (cleave L276-300, VERBATIM) =====
    mmi(cell('region_lo'),0); mmi(cell('region_hi'),0)
    a.raw(0x8B,0x4E,48)
    a.raw(0x8B,0x56,44); a.raw(0x01,0xCA)
    a.raw(0xBF); a.blob(le32(64))
    a.lbl('mloop')
    a.raw(0x39,0xD1); a.j(JAE,'mdone')
    a.raw(0x4F); a.j(JE,'F8')
    outi(0x9C)
    for d in (0,4,8,12,16,20):
        a.raw(0x8B,0x01) if d==0 else a.raw(0x8B,0x41,d)
        dr_eax()
    mem(cell('region_hi')); a.raw(0x85,0xC0); a.j(JNE,'madv')
    a.raw(0x8B,0x41,20); a.raw(0x83,0xF8,0x01); a.j(JNE,'madv')
    a.raw(0x8B,0x41,8); a.raw(0x85,0xC0); a.j(JNE,'madv')
    a.raw(0x8B,0x41,4)
    a.raw(0x8B,0x59,12); a.raw(0x01,0xD8)
    a.raw(0x8B,0x59,16); a.raw(0x85,0xDB); a.j(JE,'no_clamp')
    a.raw(0xB8); a.blob(le32(0xFFFFF000)); a.lbl('no_clamp')
    a.raw(0x3D); a.blob(le32(0x100000)); a.j(JBE,'madv')
    mme(cell('region_hi')); a.raw(0x8B,0x41,4); mme(cell('region_lo'))
    a.lbl('madv')
    a.raw(0x8B,0x01); a.raw(0x83,0xC0,0x04); a.raw(0x01,0xC1); a.j(None,'mloop')
    a.lbl('mdone')
    mem(cell('region_hi')); a.raw(0x85,0xC0); a.j(JE,'F9')

    # ===== bump allocator (cleave L302-345, VERBATIM; mints K region pages, here K=1) =====
    a.raw(0xB8); a.blob(le32(MSLOTS))
    a.raw(0x3B,0x05); a.blob(le32(cell('nprocs'))); a.j(JBE,'mbok')
    a.raw(0xA1); a.blob(le32(cell('nprocs')))
    a.lbl('mbok')
    a.raw(0xA3); a.blob(le32(cell('tmp0')))
    a.raw(0x31,0xFF)
    a.lbl('allocloop')
    a.raw(0x3B,0x3D); a.blob(le32(cell('tmp0'))); a.j(JAE,'allocdone')
    mem(cell('region_lo')); a.raw(0x3D); a.blob(le32(0x100000)); a.j(JAE,'hf')
    a.raw(0xB8); a.blob(le32(0x100000)); a.lbl('hf')
    alignup_eax(); a.raw(0x05); a.blob(le32(GROWBYTES))
    a.raw(0x89,0xC1)
    a.lbl('rescan')
    a.raw(0x31,0xDB)
    a.raw(0x31,0xF6)
    a.lbl('eckloop')
    a.raw(0x3B,0x35); a.blob(le32(cell('nexcl'))); a.j(JAE,'eckdone')
    a.raw(0x8D,0x81); a.blob(le32((-GROWBYTES)&0xFFFFFFFF))
    ld('edx',excl_hi(),'esi'); a.raw(0x39,0xD0); a.j(JAE,'nextj')
    a.raw(0x8D,0x81); a.blob(le32(0x1000))
    ld('edx',excl_lo(),'esi'); a.raw(0x39,0xD0); a.j(JBE,'nextj')
    ld('eax',excl_hi(),'esi'); alignup_eax(); a.raw(0x05); a.blob(le32(GROWBYTES)); a.raw(0x89,0xC1); a.raw(0xBB); a.blob(le32(1))
    a.lbl('nextj')
    a.raw(0x46); a.j(None,'eckloop')
    a.lbl('eckdone')
    a.raw(0x85,0xDB); a.j(JNE,'rescan')
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); a.raw(0x3B,0x05); a.blob(le32(cell('region_hi'))); a.j(JA,'F10')
    st(arr('alloc_lo'),'edi','ecx')
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); st(arr('alloc_hi'),'edi','eax')
    a.raw(0x8D,0x81); a.blob(le32((-GROWBYTES)&0xFFFFFFFF)); st(arr('grow_floor'),'edi','eax')
    a.raw(0x8B,0x35); a.blob(le32(cell('nexcl')))
    a.raw(0x8D,0x81); a.blob(le32((-GROWBYTES)&0xFFFFFFFF)); st(excl_lo(),'esi','eax')
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); st(excl_hi(),'esi','eax')
    a.raw(0x46); a.raw(0x89,0x35); a.blob(le32(cell('nexcl')))
    a.raw(0x47); a.j(None,'allocloop')
    a.lbl('allocdone')

    # ===== dump OWN table (cleave L347-362, VERBATIM) =====
    outi(0x9A)
    a.raw(0xB8); a.blob(le32(LOAD)); dr_eax()
    a.raw(0xB8); a.blob(le32(kend)); dr_eax()
    a.raw(0x8B,0x46,48); dr_eax()
    a.raw(0x8B,0x46,44); dr_eax()
    a.raw(0xBE); a.blob(le32(CELLBASE))
    a.raw(0xB9); a.blob(le32(len(CELLS)))
    a.lbl('dumpcell')
    a.raw(0x8A,0x06,0xE6,OUT)
    a.raw(0x8A,0x46,0x01,0xE6,OUT)
    a.raw(0x8A,0x46,0x02,0xE6,OUT)
    a.raw(0x8A,0x46,0x03,0xE6,OUT)
    a.raw(0x83,0xC6,0x04)
    a.raw(0x49); a.raw(0x85,0xC9); a.j(JNE,'dumpcell')
    outi(0x9B)

    if stage=='head':
        outi(0x77); shutdown()
        return a.assemble()

    # ===== install ring machinery (lgdt/lidt/ltr) (cleave L368-375, VERBATIM) =====
    a.raw(0x0F,0x01,0x15); a.absR('gdtr')
    a.raw(0xEA); a.absR('reload'); a.raw(0x08,0x00)
    a.lbl('reload')
    a.raw(0xB8); a.blob(le32(KDATA))
    a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xD0,0x8E,0xE0,0x8E,0xE8)
    a.raw(0x0F,0x01,0x1D); a.absR('idtr')
    a.raw(0x66,0xB8,TSS_SEL,0x00); a.raw(0x0F,0x00,0xD8)

    # ===== paging ON + flip proc 0's pages User (cleave L377-384) =====
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # mov cr3,pd
    a.raw(0x0F,0x20,0xC0); a.raw(0x0D); a.blob(le32(0x80000000)); a.raw(0x0F,0x22,0xC0)  # cr0.PG=1
    a.raw(0xEB,0x00)
    a.raw(0x31,0xC9)                                   # xor ecx,ecx  (proc 0)
    flip_pg(arr('modstart'),'ecx',True)                # proc0 code page -> User
    flip_pg(arr('alloc_lo'),'ecx',True)                # proc0 stack page -> User
    # homestead grow-window commit/clear (cleave L385-413): inherited; with K=1 it clears proc0's grow window P=0. INERT
    # for lethe (the prober never pushes into the grow window). Kept so the cleave lineage is byte-structural.
    a.raw(0x31,0xFF)                                   # xor edi,edi  (proc p)
    a.lbl('gw_p')
    a.raw(0x3B,0x3D); a.blob(le32(cell('tmp0'))); a.j(JAE,'gw_pdone')
    ld('esi',arr('grow_floor'),'edi')
    a.lbl('gw_pg')
    ld('edx',arr('alloc_lo'),'edi'); a.raw(0x39,0xD6); a.j(JAE,'gw_pgdone')
    a.raw(0x89,0xF1)
    a.raw(0xC1,0xE9,0x0A); a.raw(0x83,0xE1,0xFC); a.raw(0x81,0xC1); a.absR('pt')
    a.raw(0x83,0x21,0xFE)                              # and dword[ecx],~1  (P=0)
    a.raw(0x81,0xC6); a.blob(le32(0x1000)); a.j(None,'gw_pg')
    a.lbl('gw_pgdone')
    a.raw(0x47); a.j(None,'gw_p')
    a.lbl('gw_pdone')
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # reload cr3 (flush TLB)

    # ===== lethe: install the THREE NON-IDENTITY ALIASES (THE LINK'S SETUP) =====
    # PTE[A>>12] <- F|7 ; PTE[V>>12] <- F|7 ; PTE[B>>12] <- F'|7 . All present+RW+User. Pre-seed F''s test slot with
    # OLD_FP (so "no write reached F'" is detectable). cr3 reload here is FINE (clean start -- no stale entry exists yet,
    # the prober has not yet warmed V->F into the TLB). The TARGETED invalidation only matters at SYS_REMAP time, AFTER
    # the prober has cached V->F. (cleave L416-431 analogue, but THREE installs + a frame pre-seed, no read-only alias.)
    #   M-noinstall: skip the installs -> A/V/B stay identity+Supervisor -> the CPL3 store #PFs terminally -> RED.
    #   M-sameframe: install/remap V to F (FP==F) -> after remap V->F still -> step-4 y lands in F -> A==y -> RED.
    if mut!='noinstall':
        af = F_FRAME
        vf = F_FRAME if mut=='sameframe' else F_FRAME   # V's BOOT frame is always F (the remap target is mutated, not boot)
        bf = F_FRAME if mut=='sameframe' else FP_FRAME  # M-sameframe: B also maps F (so B reads F) -- consistent with FP==F
        a.raw(0xC7,0x05); a.absR('pt',(A_VADDR>>12)*4); a.blob(le32(af|7))      # PTE[A] <- F | P|RW|User
        a.raw(0xC7,0x05); a.absR('pt',(V_VADDR>>12)*4); a.blob(le32(vf|7))      # PTE[V] <- F | P|RW|User
        a.raw(0xC7,0x05); a.absR('pt',(B_VADDR>>12)*4); a.blob(le32(bf|7))      # PTE[B] <- F'| P|RW|User
        # pre-seed F''s test slot with OLD_FP (write the identity vaddr of F', which maps to the F' frame at boot via the
        # identity PT entry -- F'=0xE00000 < 16 MiB is identity-mapped present+RW+Super at boot). DS=KDATA here (CPL0).
        a.raw(0xC7,0x05); a.blob(le32(FP_FRAME+TEST_OFF)); a.blob(le32(OLD_FP)) # mov dword[F'+TEST_OFF], OLD_FP
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)                        # reload cr3 (clean start; no stale entry yet)

    # ===== COM1 init (cleave L433-436, VERBATIM) =====
    for port,val in [(0x3FB,0x03),(0x3F9,0x00),(0x3FB,0x80),(0x3F8,0x01),
                     (0x3F9,0x00),(0x3FB,0x03),(0x3FA,0x00),(0x3FC,0x03)]:
        a.raw(0x66,0xBA); a.blob(le16(port)); a.raw(0xB0,val,0xEE)
    # ===== PIC remap (cleave L437-440, VERBATIM). PIT is NOT armed (lethe needs NO preemption; IF=0 anyway). =====
    for v,p in [(0x11,0x20),(0x11,0xA0),(0x20,0x21),(0x28,0xA1),(0x04,0x21),(0x02,0xA1),
                (0x01,0x21),(0x01,0xA1),(0xFE,0x21),(0xFF,0xA1)]:
        a.raw(0xB0,v,0xE6,p)
    # (lethe: the PIT is deliberately LEFT UNARMED -- with IF=0 a stray tick is masked anyway, but not arming it is
    # cleanest. A cr3-reloading preempt would re-vacuate M-noinvlpg, so the witness REQUIRES no mid-test cr3 flush.)

    # ===== iret into proc 0 with IF=0 (lethe: the timer never fires -> no sched_switch cr3 flush) (cleave L446-461) =====
    mem(arr('alloc_lo'))                                    # eax = proc0 page base
    a.raw(0xC7,0x00); a.blob(le32(0))                       # [alloc_lo[0]] = 0 (stop-flag clear; inert -- prober ignores it)
    mmi(arr('started'),1)                                  # started[0]=1 (so any resume goes through do_restore; inert K=1)
    load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))                       # push ss
    a.raw(0xFF,0x35); a.blob(le32(arr('alloc_hi')))        # push useresp = proc0 stack top
    a.raw(0x68); a.blob(le32(0x00000002))                  # push eflags = IF=0 (lethe: NO preemption during the witness)
    a.raw(0x68); a.blob(le32(UCODE3))                      # push cs
    a.raw(0xFF,0x35); a.blob(le32(arr('modstart')))       # push eip = proc0 entry
    a.raw(0xCF)                                            # iretd -> CPL3 proc0

    # ===== syscall handler (vec 0x30): READ / EXIT / WRITE / REMAP =====
    a.lbl('exit_handler')
    a.raw(0x85,0xC0); a.j(JE,'do_read')                    # eax==0 -> read
    a.raw(0x83,0xF8,0x02); a.j(JE,'do_write')              # eax==2 -> write
    a.raw(0x83,0xF8,SYS_REMAP); a.j(JE,'do_remap')         # eax==4 -> REMAP  (lethe)
    a.raw(0x83,0xF8,SYS_DISK_READ); a.j(JE,'do_disk_read') # eax==5 -> DISK READ  (frozen platter)
    a.raw(0x83,0xF8,SYS_DISK_WRITE); a.j(JE,'do_disk_write')# eax==6 -> DISK WRITE (link38 NEW -- DURABILITY)
    a.raw(0x83,0xF8,SYS_FS_PUT); a.j(JE,'do_fs_put')       # eax==7 -> FS PUT  (link39 NEW -- FILESYSTEM CAIRN)
    a.raw(0x83,0xF8,SYS_FS_GET); a.j(JE,'do_fs_get')       # eax==8 -> FS GET  (link39 NEW -- name resolution)
    # ---- SYS_EXIT (eax==1) (cleave L467-520 tail, trimmed to the K=1 finalize path) ----
    load_kdata()
    a.raw(0x88,0xD8); a.raw(0xA2); a.blob(le32(ANSWER))    # mov al,bl ; mov [answer],al
    a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))            # ecx = cur
    a.raw(0xC7,0x04,0x8D); a.blob(le32(arr('exited'))); a.blob(le32(1))   # exited[cur]=1
    a.raw(0xFF,0x0D); a.blob(le32(cell('live')))           # live--
    mem(cell('live')); a.raw(0x85,0xC0); a.j(JE,'finalize')   # live==0 -> finalize (K=1: always)
    a.raw(0x83,0xF8,0x01); a.j(JNE,'sched_switch')         # (inert with K=1)
    a.j(None,'sched_switch')
    a.lbl('finalize')
    outi(0xC8); mem(cell('switches')); dr_eax(); outi(0xC9)   # dump switch counter (cleave L509)
    outi(0xCA)                                             # per-proc dispatch dump (cleave L512-519)
    a.raw(0x31,0xC9)
    a.lbl('fdisp')
    a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JAE,'fdispdone')
    ld('eax',arr('disp'),'ecx'); dr_eax()
    a.raw(0x41); a.j(None,'fdisp')
    a.lbl('fdispdone')
    outi(0xCB)
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')

    # ---- SYS_READ (eax==0): poll COM1 LSR (cleave L522-555). With IF=0 + K=1 the block arm never fires usefully; the
    #      prober reads exactly ONE late-bound byte and the feeder holds the socket, so the byte is ready. Kept generic. ----
    a.lbl('do_read')
    a.blob(bytes.fromhex('66bafd03ec'))               # mov dx,0x3fd; in al,dx  (LSR)
    a.raw(0xA8,0x01); a.j(JNE,'do_read_ready')        # test al,1; jnz -> data ready
    # ---- BLOCK arm (cleave L531-543); inert under K=1 (no peer to run) but kept structurally ----
    load_kdata()
    a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))
    a.raw(0x8B,0x04,0x24)
    st(arr('t_eip'),'ecx','eax')
    a.raw(0x8B,0x44,0x24,0x08); st(arr('t_eflags'),'ecx','eax')
    a.raw(0x8B,0x44,0x24,0x0C); st(arr('t_esp'),'ecx','eax')
    a.raw(0xC7,0x04,0x8D); a.blob(le32(arr('blocked'))); a.blob(le32(1))
    a.j(None,'sched_switch')
    a.lbl('do_read_ready')
    a.blob(bytes.fromhex('66baf803ec'))               # mov dx,0x3f8; in al,dx  (read RBR)
    a.raw(0x88,0xC3)                                       # mov bl,al
    outi(0xC0)
    a.raw(0x88,0xD8,0xE6,OUT)
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                   # cs
    a.raw(0x8B,0x04,0x24); dr_eax()                        # eip
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                   # useresp
    outi(0xC1)
    load_udata()
    a.raw(0x0F,0xB6,0xC3)                                  # movzx eax,bl
    a.raw(0xCF)

    # ---- SYS_REMAP (eax==4): THE LINK. PTE[V] <- F'|7 ; invlpg [V] (targeted) ; iret. NO cr3 reload. =====
    #   The prober has, before this, WARMED V->F into the TLB (step-2). After the PTE edit the cached V->F is STALE; the
    #   surgical fix is `invlpg [V]` (0F 01 /7 -> 0F 01 3D <le32(V_VADDR)>), which evicts EXACTLY that one entry so the
    #   next access to V does a fresh walk -> F'. V_VADDR and FP_FRAME are BAKED CONSTANTS -- no params, no access_ok.
    #   M-noinvlpg: omit the invlpg -> the stale V->F entry survives -> step-4 write y lands in F (the GHOST) -> A==y -> RED.
    #   M-cr3insteadofinvlpg: replace invlpg with a cr3 reload -> output is GREEN (cr3 flush is correct) but assert_lethe
    #     REJECTS it (the remap arm must contain invlpg of V and must NOT contain mov cr3). Forces the TARGETED primitive.
    #   M-noremap: omit the PTE[V]<-F' write -> V stays ->F -> step-4 y lands in F -> A==y, B==OLD_FP -> RED.
    a.lbl('do_remap')
    load_kdata()
    if mut!='noremap':
        # PTE[V] <- F'|7  (or, M-sameframe: F'|7 with F'==F since FP is the SAME frame -> the "remap" is a no-op move to F)
        remap_frame = F_FRAME if mut=='sameframe' else FP_FRAME
        a.raw(0xC7,0x05); a.absR('pt',(V_VADDR>>12)*4); a.blob(le32(remap_frame|7))  # mov dword[PTE_V], F'|7
    if mut=='cr3insteadofinvlpg':
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)   # M-cr3..: mov cr3,pd (FULL flush -- correct output, WHITE-BOX REJECT)
    elif mut=='cr3edx':
        a.raw(0x0F,0x01,0x3D); a.blob(le32(V_VADDR))       # M-cr3edx: invlpg [V] PRESENT (passes assert check-2 adjacency)...
        a.raw(0xBA); a.absR('pd'); a.raw(0x0F,0x22,0xDA)   # ...PLUS mov cr3,edx (0F 22 DA) -- the D8..DF gap Codex found: GREEN
        #   on output (invlpg is correct) but the WIDENED assert_lethe REJECTS the cr3,edx in the arm (a D8-only reject passed it)
    elif mut!='noinvlpg':
        a.raw(0x0F,0x01,0x3D); a.blob(le32(V_VADDR))       # invlpg [V_VADDR]  (THE TARGETED INVALIDATION)
    # iret back into the prober (DS must be restored to UDATA3 for the prober's CPL3 data accesses)
    load_udata()
    a.raw(0x31,0xC0)                                       # eax=0 (clean return value)
    a.raw(0xCF)                                            # iretd -> resume the prober right after int 0x30

    # ---- SYS_DISK_READ (eax==5): THE LINK -- the kernel's FIRST BLOCK DEVICE. =====
    #   ABI (pass-by-register, kernel-channel doctrine): module supplies LBA in EBX, byte-offset (0..511) in ECX.
    #   The kernel (CPL0) BOUNDS-CHECKS the LBA to [DISK_RESV_LO, DISK_RESV_HI) -- a confused-deputy access_ok on
    #   the LBA so a module can't read GRUB / the FAT partition / arbitrary sectors -- does an ATA PIO LBA28
    #   single-sector read of that LBA into the kernel's OWN 512-byte `diskbuf` (a CPL3 module cannot do PIO
    #   itself: an `in al,dx` at CPL3 #GPs), and returns the byte at [diskbuf+offset] in EAX. iret back to CPL3.
    #   M-noboundscheck: drop the access_ok -> a malicious LBA escapes the window (rejected as a sandbox break).
    #   M-fixedlba: ignore EBX, always read DISK_RESV_LO+DISK_START_IDX -> every hop reads the SAME sector ->
    #     the chase collapses (b1==b2==b3==start byte) -> grade RED (the read is not ADDRESSED by the module).
    #   M-noread: skip the ATA sequence -> diskbuf stays zero -> emits zeros -> grade RED.
    a.lbl('do_disk_read')
    load_kdata()
    a.raw(0x89,0x0D); a.blob(le32(cell('tmp0')))           # mov [tmp0], ecx   (save the byte-offset)
    # access_ok on the LBA: reject (return 0) if EBX < DISK_RESV_LO or EBX >= DISK_RESV_HI.
    if mut!='noboundscheck':
        a.raw(0x81,0xFB); a.blob(le32(DISK_RESV_LO)); a.j(JB,'disk_reject')   # cmp ebx,LO ; jb reject
        a.raw(0x81,0xFB); a.blob(le32(DISK_RESV_HI)); a.j(JAE,'disk_reject')  # cmp ebx,HI ; jae reject
    # M-fixedlba: clobber EBX with the fixed start LBA so the read is NOT addressed by the module's request.
    if mut=='fixedlba':
        a.raw(0xBB); a.blob(le32(DISK_RESV_LO+DISK_START_IDX))                # mov ebx, LO+START (ignore module LBA)
    a.raw(0x89,0x1D); a.blob(le32(cell('tmp1')))           # mov [tmp1], ebx   (the LBA to read)
    if mut!='noread':
        # ATA PIO LBA28 single-sector read (the STEP-0-proven sequence). DS/ES=KDATA (flat) here.
        a.raw(0x66,0xBA,0xF6,0x01); a.raw(0xB0,0xE0,0xEE)  # mov dx,0x1F6 ; mov al,0xE0 (master,LBA,bits27:24=0) ; out
        a.raw(0x66,0xBA,0xF2,0x01); a.raw(0xB0,0x01,0xEE)  # mov dx,0x1F2 ; mov al,1 (sector count) ; out
        a.raw(0x66,0xBA,0xF3,0x01); mem(cell('tmp1')); a.raw(0xEE)           # mov dx,0x1F3 ; eax=LBA ; out al  (LBA[7:0])
        a.raw(0x66,0xBA,0xF4,0x01); mem(cell('tmp1')); a.raw(0xC1,0xE8,0x08,0xEE)   # 0x1F4 ; LBA>>8  ; out (LBA[15:8])
        a.raw(0x66,0xBA,0xF5,0x01); mem(cell('tmp1')); a.raw(0xC1,0xE8,0x10,0xEE)   # 0x1F5 ; LBA>>16 ; out (LBA[23:16])
        a.raw(0x66,0xBA,0xF7,0x01); a.raw(0xB0,0x20,0xEE)  # mov dx,0x1F7 ; mov al,0x20 (READ SECTORS) ; out
        if DISK_DEBUG:
            a.raw(0xB0,0xDA,0xE6,OUT)                       # mark 0xDA
            a.raw(0x66,0xBA,0xF7,0x01,0xEC,0xE6,OUT)        # in al,0x1F7 (status) ; out OUT,al
            a.raw(0x66,0xBA,0xF1,0x01,0xEC,0xE6,OUT)        # in al,0x1F1 (error)  ; out OUT,al
        a.lbl('disk_bsy')                                  # poll: wait while BSY (bit7) set
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)                    # mov dx,0x1F7 ; in al,dx
        a.raw(0xA8,0x80); a.j(JNE,'disk_bsy')              # test al,0x80 ; jnz -> still BSY
        a.lbl('disk_drq')                                  # then wait until DRQ (bit3) set
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)                    # mov dx,0x1F7 ; in al,dx
        a.raw(0xA8,0x08); a.j(JE,'disk_drq')               # test al,0x08 ; jz -> DRQ not ready
        a.raw(0x66,0xBA,0xF0,0x01)                         # mov dx,0x1F0  (data port)
        a.raw(0xBF); a.absR('diskbuf')                     # mov edi, diskbuf
        a.raw(0xB9,0x00,0x01,0x00,0x00)                    # mov ecx,256
        # cld: clear DF so `rep insw` walks FORWARD from diskbuf. The GENUINE kernel ALWAYS emits this (the guard below
        # keeps build_elf(none) byte-identical). M-nocld DROPS it -> a hostile module that does `std` (DF=1) before
        # int 0x30 makes `rep insw` walk BACKWARD from diskbuf, corrupting kernel memory BELOW diskbuf. That defect is
        # OUTPUT-INVISIBLE on the benign gate (the prober's ambient DF=0) -- the same output-invisible-forge class as the
        # ECX hole -- so it needs a white-box pin (assert_platter check (5)) + a hostile-DF output leg.
        if mut != 'nocld':
            a.raw(0xFC)                                    # cld
        a.raw(0x66,0xF3,0x6D)                              # rep insw (16-bit! operand-size prefix 0x66) -> 256 words =
        #   exactly 512 bytes into ES:[edi]=KDATA-flat diskbuf. WITHOUT the 0x66 this is `rep insd` (256 DWORDS=1024B),
        #   which overruns the one-sector DRQ buffer and returns stale data for EVERY read (the bug that made all hops
        #   return the same byte). STEP-0's GAS `rep insw` carried the 0x66 prefix; the hand-asm must too.
        if DISK_DEBUG:
            a.raw(0xB0,0xDB,0xE6,OUT)                       # mark 0xDB
            a.raw(0xA0); a.absR('diskbuf'); a.raw(0xE6,OUT) # mov al,[diskbuf] ; out OUT,al (diskbuf byte0 after read)
    # restore DS=UDATA3 FIRST (load_udata clobbers EAX with UDATA3's selector 0x23 -- so the return-byte read MUST
    # come AFTER it, else every read returns 0x23). DS=UDATA3 is flat base-0, and at CPL0 the handler can still read
    # the Supervisor-mapped diskbuf/tmp0 -- the segment is just a base/limit window, the page perms gate on CPL.
    load_udata()
    # return byte: movzx eax, byte [diskbuf + offset]   (EAX is the syscall return value -- set it LAST)
    a.raw(0x8B,0x0D); a.blob(le32(cell('tmp0')))           # mov ecx,[tmp0]  (the module-supplied byte-offset)
    # access_ok on the OFFSET: reject (sentinel 0) if ECX >= 512. WITHOUT this, `movzx eax,[ecx+diskbuf]` with a
    # CPL3-controlled ECX is a one-byte ARBITRARY KERNEL READ past the 512B supervisor diskbuf (a confused-deputy
    # info-leak). The LBA access_ok alone is NOT sufficient -- the offset is the second untrusted scalar. (Cross-model
    # Codex caught this before land; assert_platter pins this cmp, M-noecxcheck drops it -> RED.)
    if mut!='noecxcheck':
        a.raw(0x81,0xF9); a.blob(le32(512)); a.j(JAE,'disk_reject')   # cmp ecx,512 ; jae disk_reject
    a.raw(0x0F,0xB6,0x81); a.absR('diskbuf')               # movzx eax, byte [ecx + diskbuf]
    a.raw(0xCF)                                            # iretd -> resume the prober with the byte in eax
    a.lbl('disk_reject')
    load_udata()
    a.raw(0x31,0xC0)                                       # eax=0 (out-of-window LBA -> sentinel 0)
    a.raw(0xCF)

    # ---- SYS_DISK_WRITE (eax==6): THE LINK -- DURABILITY. A byte WRITTEN here SURVIVES A REBOOT. =====
    #   ABI (pass-by-register, kernel-channel doctrine): module supplies the LBA in EBX, a byte-offset (0..511)
    #   in ECX, the BYTE to write in DL (EDX low 8). The kernel (CPL0):
    #     (a) access_ok the LBA to the RESERVED WRITE window [DISK_WRESV_LO, DISK_WRESV_HI) -- reject out-of-window
    #         (-> sentinel, NO write). CRITICAL: without it a CPL3 module has a WRITE-ANYWHERE primitive (clobber
    #         the MBR / a read-window sector / GRUB) -- strictly WORSE than the read leak. M-nowboundscheck drops it.
    #     (b) bound ECX<512 -- reject otherwise (else `mov [ecx+diskbuf],DL` is an arbitrary kernel WRITE past the
    #         512B diskbuf). M-nowecxcheck drops it.
    #     (c) ATA software-RESET prologue (out 0x1F6,0xA0; out 0x3F6,0x06; delay; out 0x3F6,0x02; wait BSY clear+RDY)
    #         -- STEP-0 proved Bochs ignores a WRITE command while the BIOS leaves DRQ asserted mid-IDENTIFY.
    #     (d) build the sector: zero the 512B diskbuf, set diskbuf[ECX]=DL; ATA LBA28 WRITE (0x30) of that sector to
    #         the LBA (rep OUTSW 256w from diskbuf = 66 F3 6F); poll BSY clear; ATA CACHE FLUSH (0xE7); poll BSY clear.
    #   iret. The READ arm above is BYTE-IDENTICAL to frozen platter (additive). DS/ES=KDATA (flat) in this arm.
    #   M-nowrite: drop the ATA write (d) -> the byte never reaches the medium -> BOOT-2 reads stale 0 -> RED.
    a.lbl('do_disk_write')
    load_kdata()
    a.raw(0x89,0x0D); a.blob(le32(cell('tmp0')))           # mov [tmp0], ecx   (save the byte-offset)
    a.raw(0x88,0x15); a.blob(le32(cell('tmp1')))           # mov [tmp1], dl    (save the byte to write, low 8 of edx)
    # (a) access_ok on the WRITE LBA: reject (sentinel, NO write) if EBX < WLO or EBX >= WHI.
    if mut!='nowboundscheck':
        a.raw(0x81,0xFB); a.blob(le32(DISK_WRESV_LO)); a.j(JB,'diskw_reject')   # cmp ebx,WLO ; jb reject
        a.raw(0x81,0xFB); a.blob(le32(DISK_WRESV_HI)); a.j(JAE,'diskw_reject')  # cmp ebx,WHI ; jae reject
    # (b) access_ok on the OFFSET: reject if ECX >= 512 (else arbitrary kernel write past diskbuf).
    if mut!='nowecxcheck':
        a.raw(0x81,0xF9); a.blob(le32(512)); a.j(JAE,'diskw_reject')            # cmp ecx,512 ; jae reject
    a.raw(0x89,0x1D); a.blob(le32(cell('tmp2')))           # mov [tmp2], ebx   (the LBA to write -- after the checks)
    if mut!='nowrite':
        # (c) ATA software-RESET prologue (STEP-0: Bochs needs it for writes; QEMU tolerates it).
        a.raw(0x66,0xBA,0xF6,0x01); a.raw(0xB0,0xA0,0xEE)  # mov dx,0x1F6 ; mov al,0xA0 (select master) ; out
        a.raw(0x66,0xBA,0xF6,0x03); a.raw(0xB0,0x06,0xEE)  # mov dx,0x3F6 ; mov al,0x06 (SRST=1,nIEN=1) ; out  (dev-ctl)
        a.raw(0xB9); a.blob(le32(5))                       # mov ecx,5  (>=400ns delay: read alt-status a few times)
        a.lbl('diskw_rdly1')
        a.raw(0x66,0xBA,0xF6,0x03,0xEC)                    # mov dx,0x3F6 ; in al,dx  (alt-status)
        a.raw(0xE2,0xFB)                                   # loop diskw_rdly1
        a.raw(0x66,0xBA,0xF6,0x03); a.raw(0xB0,0x02,0xEE)  # mov dx,0x3F6 ; mov al,0x02 (SRST=0, keep nIEN=1) ; out
        a.raw(0xB9); a.blob(le32(5))                       # mov ecx,5
        a.lbl('diskw_rdly2')
        a.raw(0x66,0xBA,0xF6,0x03,0xEC)                    # mov dx,0x3F6 ; in al,dx
        a.raw(0xE2,0xFB)                                   # loop diskw_rdly2
        a.lbl('diskw_rbsy')                                # wait BSY (bit7) clear
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)                    # mov dx,0x1F7 ; in al,dx
        a.raw(0xA8,0x80); a.j(JNE,'diskw_rbsy')            # test al,0x80 ; jnz -> still BSY
        a.lbl('diskw_rrdy')                                # wait RDY (bit6) set
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)                    # mov dx,0x1F7 ; in al,dx
        a.raw(0xA8,0x40); a.j(JE,'diskw_rrdy')             # test al,0x40 ; jz -> RDY not set
        # (d) build the sector in the kernel diskbuf: zero 512 bytes, set diskbuf[ECX]=DL.
        a.raw(0xBF); a.absR('diskbuf')                     # mov edi, diskbuf
        a.raw(0x31,0xC0)                                   # xor eax,eax  (zero fill value)
        a.raw(0xB9,0x80,0x00,0x00,0x00)                    # mov ecx,128  (128 DWORDS = 512 bytes; rep stosd is 32-bit -- NOT 256, which would zero 1024B and overrun diskbuf by 512B into body_start. Codex caught the dword/word confusion.)
        # cld: clear DF so `rep stosd` zeroes diskbuf FORWARD (EDI=diskbuf upward). The GENUINE kernel ALWAYS emits this
        # (the guard keeps build_elf(none) byte-identical -- the genuine arm cld's regardless). M-nowcld DROPS BOTH clds
        # (this one and the one before rep outsw) -> a hostile module that does `std` (DF=1) before int 0x30 makes
        # `rep stosd` walk BACKWARD from diskbuf, zeroing 508 bytes of KERNEL memory BELOW diskbuf (here the top PTEs of
        # the page tables `pt`, which sit immediately below diskbuf) -- a kernel-memory corruption -- AND leaves diskbuf
        # offsets 4..511 uninitialised. That defect is OUTPUT-INVISIBLE on the benign two-boot (the prober's ambient DF=0,
        # and the durable byte is at offset 0). Output-invisible-forge class (cf the platter READ-arm cld/DF Codex caught).
        # Pinned as the EXACT adjacency `FC F3 AB` (assert_durability) + caught by the hostile-DF-WRITE output leg.
        if mut != 'nowcld':
            a.raw(0xFC)                                    # cld  (forward fill)
        a.raw(0xF3,0xAB)                                   # rep stosd  (zero the whole diskbuf sector)
        a.raw(0x8B,0x0D); a.blob(le32(cell('tmp0')))       # mov ecx,[tmp0]  (the byte-offset)
        a.raw(0x8A,0x05); a.blob(le32(cell('tmp1')))       # mov al,[tmp1]   (the byte to write)
        a.raw(0x88,0x81); a.absR('diskbuf')                # mov [ecx + diskbuf], al   (set diskbuf[ECX] = byte)
        # ATA PIO LBA28 WRITE (0x30) of the sector to [tmp2].
        a.raw(0x66,0xBA,0xF6,0x01); a.raw(0xB0,0xE0,0xEE)  # mov dx,0x1F6 ; mov al,0xE0 (master,LBA,27:24=0) ; out
        a.raw(0x66,0xBA,0xF2,0x01); a.raw(0xB0,0x01,0xEE)  # mov dx,0x1F2 ; mov al,1 (sector count) ; out
        a.raw(0x66,0xBA,0xF3,0x01); mem(cell('tmp2')); a.raw(0xEE)                  # 0x1F3 ; LBA[7:0]  ; out
        a.raw(0x66,0xBA,0xF4,0x01); mem(cell('tmp2')); a.raw(0xC1,0xE8,0x08,0xEE)   # 0x1F4 ; LBA[15:8] ; out
        a.raw(0x66,0xBA,0xF5,0x01); mem(cell('tmp2')); a.raw(0xC1,0xE8,0x10,0xEE)   # 0x1F5 ; LBA[23:16]; out
        a.raw(0x66,0xBA,0xF7,0x01); a.raw(0xB0,0x30,0xEE)  # mov dx,0x1F7 ; mov al,0x30 (WRITE SECTORS) ; out
        a.lbl('diskw_wbsy')                                # wait BSY clear then DRQ set (ready to accept data)
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)
        a.raw(0xA8,0x80); a.j(JNE,'diskw_wbsy')
        a.lbl('diskw_wdrq')
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)
        a.raw(0xA8,0x08); a.j(JE,'diskw_wdrq')
        a.raw(0x66,0xBA,0xF0,0x01)                         # mov dx,0x1F0  (data port) -- DX EXPLICITLY = 0x1F0 (the ATA data
        #   port) IMMEDIATELY before rep outsw, so DX cannot inherit the module's EDX or the 0x1F7 status port left from
        #   the BSY/DRQ polling above. assert_durability pins this `66 BA F0 01` adjacency before the `66 F3 6F`.
        a.raw(0xBE); a.absR('diskbuf')                     # mov esi, diskbuf
        a.raw(0xB9,0x00,0x01,0x00,0x00)                    # mov ecx,256
        # cld: clear DF so `rep outsw` reads diskbuf FORWARD (ESI=diskbuf upward) and sends the sector in order. The
        # GENUINE kernel ALWAYS emits this. M-nowcld DROPS it -> a hostile `std` (DF=1) makes `rep outsw` walk BACKWARD:
        # it sends diskbuf[0..1] then bytes BELOW diskbuf (the page tables) out the data port -> the WRONG sector content
        # reaches the medium (a kernel-memory info-leak TO DISK) and any sentinel the module wrote at offset >= 2 never
        # lands at that disk offset. OUTPUT-INVISIBLE on the benign two-boot (DF=0, offset 0). Pinned as `FC 66 F3 6F`.
        if mut != 'nowcld':
            a.raw(0xFC)                                    # cld
        a.raw(0x66,0xF3,0x6F)                              # rep outsw (16-bit! 0x66) -> 256 words = 512 bytes out
        a.lbl('diskw_wdone')                               # wait BSY clear (write data accepted by the drive)
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)
        a.raw(0xA8,0x80); a.j(JNE,'diskw_wdone')
        # ATA CACHE FLUSH (0xE7) -- CRITICAL: forces the write through to the medium so it survives a reboot.
        a.raw(0x66,0xBA,0xF7,0x01); a.raw(0xB0,0xE7,0xEE)  # mov dx,0x1F7 ; mov al,0xE7 (FLUSH CACHE) ; out
        a.lbl('diskw_fbsy')
        a.raw(0x66,0xBA,0xF7,0x01,0xEC)
        a.raw(0xA8,0x80); a.j(JNE,'diskw_fbsy')            # wait BSY clear
    load_udata()
    a.raw(0x31,0xC0)                                       # eax=0 (clean return)
    a.raw(0xCF)                                            # iretd -> resume the prober
    a.lbl('diskw_reject')
    load_udata()
    a.raw(0x31,0xC0)                                       # eax=0 (out-of-window LBA / bad offset -> sentinel, NO write)
    a.raw(0xCF)

    # ---- SYS_WRITE (eax==2): access_ok vs the ACTIVE region (cleave L557-581, VERBATIM) ----
    a.lbl('do_write')
    load_kdata()
    a.raw(0x8B,0x05); a.blob(le32(cell('cur')))
    ld('esi',arr('alloc_lo'),'eax'); ld('edi',arr('alloc_hi'),'eax')
    a.raw(0x89,0xC8); a.raw(0x01,0xD0)
    a.j(JB,'reject_write')
    a.raw(0x39,0xF1); a.j(JB,'reject_write')
    a.raw(0x39,0xF8); a.j(JA,'reject_write')
    outi(0xD4)
    a.raw(0x89,0xD0); dr_eax()
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()
    a.raw(0x8B,0x04,0x24); dr_eax()
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()
    a.lbl('wrelay')
    a.raw(0x85,0xD2); a.j(JE,'wrelaydone')
    a.raw(0x8A,0x01); a.raw(0xE6,OUT); a.raw(0x41); a.raw(0x4A); a.j(None,'wrelay')
    a.lbl('wrelaydone')
    outi(0xD5)
    load_udata(); a.raw(0x31,0xC0); a.raw(0xCF)
    a.lbl('reject_write')
    outi(0xD6)
    a.raw(0x89,0xD0); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax(); a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x0C); dr_eax()
    outi(0xD7)
    load_udata(); a.raw(0x31,0xC0); a.raw(0xCF)

    # ---- SYS_FS_PUT (eax==7): NAME a payload + persist it (THE LINK -- FILESYSTEM CAIRN). =====
    #   ABI (pass-by-register, kernel-channel doctrine): EBX=name_ptr (16 bytes), ECX=payload_ptr, EDX=len.
    #   The kernel (CPL0):
    #     (a) access_ok(name_ptr, 16) against the module's User region [alloc_lo,alloc_hi) -- a confused-deputy READ of
    #         module memory; reject (sentinel found=0) if out of region.
    #     (b) access_ok(payload_ptr, len) against [alloc_lo,alloc_hi); require 1 <= len <= FS_MAXLEN.
    #     (c) read the directory sector (FS_DIR_LBA) into dirbuf; count nentries = number of slots with valid==1 (a FIXED
    #         loop over EXACTLY FS_D slots -- never an untrusted on-disk terminator/counter). Require nentries < FS_D.
    #     (d) data_lba = FS_DATA_LO + nentries  (allocate the NEXT sector BY INSERTION ORDER -- NOT name-derived).
    #     (e) build the payload sector in diskbuf (zero it, copy len bytes from payload_ptr), ATA WRITE it to data_lba +
    #         CACHE FLUSH.
    #     (f) write the directory entry into dirbuf slot[nentries] = {valid=1, len, name(16), data_lba}, ATA WRITE dirbuf
    #         back to FS_DIR_LBA + CACHE FLUSH.
    #   Return eax = 1 (stored) / 0 (rejected). DS/ES=KDATA (flat) in the arm.
    a.lbl('do_fs_put')
    load_kdata()
    # save the three module-supplied scalars first.
    a.raw(0x89,0x1D); a.blob(le32(cell('fs_nameptr')))     # mov [fs_nameptr], ebx
    a.raw(0x89,0x0D); a.blob(le32(cell('fs_payptr')))      # mov [fs_payptr],  ecx
    a.raw(0x89,0x15); a.blob(le32(cell('fs_len')))         # mov [fs_len],     edx
    # (b-pre) require 1 <= len <= FS_MAXLEN  (len==0 rejected; len>512 rejected -- a one-sector payload).
    a.raw(0x85,0xD2); a.j(JE,'fs_put_reject')              # test edx,edx ; jz reject (len==0)
    a.raw(0x81,0xFA); a.blob(le32(FS_MAXLEN)); a.j(JA,'fs_put_reject')   # cmp edx,512 ; ja reject (len>512)
    # (a) access_ok(name_ptr, 16) against [alloc_lo,alloc_hi)[cur].
    a.raw(0x8B,0x05); a.blob(le32(cell('cur')))            # eax = cur
    ld('esi',arr('alloc_lo'),'eax'); ld('edi',arr('alloc_hi'),'eax')   # esi=lo, edi=hi
    a.raw(0x8B,0x1D); a.blob(le32(cell('fs_nameptr')))     # ebx = name_ptr
    a.raw(0x39,0xF3); a.j(JB,'fs_put_reject')              # cmp ebx,esi(lo) ; jb reject (name_ptr < lo)
    a.raw(0x89,0xDA)                                       # mov edx,ebx
    a.raw(0x83,0xC2,FS_NAMELEN)                            # add edx,16
    if mut!='nocarrycheck': a.j(JB,'fs_put_reject')        # JC reject (CARRY = 32-bit name_ptr+16 WRAP -> out-of-region; Codex caught the lea-overflow). M-nocarrycheck DROPS it -> the overflow forge (a near-4GiB ptr wraps small + passes cmp edx,hi)
    a.raw(0x39,0xFA); a.j(JA,'fs_put_reject')              # cmp edx,edi(hi) ; ja reject (name end > hi)
    # (b) access_ok(payload_ptr, len) against [alloc_lo,alloc_hi)[cur].
    a.raw(0x8B,0x1D); a.blob(le32(cell('fs_payptr')))      # ebx = payload_ptr
    a.raw(0x39,0xF3); a.j(JB,'fs_put_reject')              # cmp ebx,esi(lo) ; jb reject
    a.raw(0x8B,0x15); a.blob(le32(cell('fs_len')))         # edx = len  (1..512, checked above)
    a.raw(0x01,0xDA)                                       # add edx,ebx (payload end)
    if mut!='nocarrycheck': a.j(JB,'fs_put_reject')        # JC reject (CARRY = ptr+len WRAP -> out-of-region; Codex access_ok-overflow fix). M-nocarrycheck drops it.
    a.raw(0x39,0xFA); a.j(JA,'fs_put_reject')              # cmp edx,edi(hi) ; ja reject (payload end > hi)
    # (c) read the directory sector into dirbuf, count nentries over EXACTLY FS_D fixed slots.
    a.raw(0xC7,0x05); a.blob(le32(cell('tmp2'))); a.blob(le32(FS_DIR_LBA))   # mov [tmp2], FS_DIR_LBA
    ata_read_sector('dirbuf', cell('tmp2'))
    a.raw(0x31,0xC9)                                       # xor ecx,ecx  (i=0)
    a.raw(0x31,0xC0)                                       # xor eax,eax  (nentries=0)
    a.lbl('fs_put_count')
    a.raw(0x83,0xF9,FS_D); a.j(JAE,'fs_put_countdone')     # cmp ecx,FS_D ; jae done  (FIXED loop, exactly D slots)
    # esi = dirbuf + i*FS_ENTSZ : compute the slot base. (i*28 = i*4 + i*8 + i*16 -> use imul.)
    a.raw(0x6B,0xF1,FS_ENTSZ)                              # imul esi,ecx,28
    a.raw(0x81,0xC6); a.absR('dirbuf')                     # add esi, dirbuf
    a.raw(0x83,0x3E,0x01)                                  # cmp dword[esi+FS_OFF_VALID(0)],1
    a.j(JNE,'fs_put_countnext')                            # not valid -> skip
    a.raw(0x40)                                            # inc eax  (nentries++)
    a.lbl('fs_put_countnext')
    a.raw(0x41); a.j(None,'fs_put_count')                  # inc ecx ; loop
    a.lbl('fs_put_countdone')
    a.raw(0xA3); a.blob(le32(cell('fs_nent')))             # mov [fs_nent], eax  (nentries)
    a.raw(0x83,0xF8,FS_D); a.j(JAE,'fs_put_reject')        # cmp eax,FS_D ; jae reject (directory full: nentries>=D)
    # (d) data_lba = FS_DATA_LO + nentries  (BY INSERTION ORDER -- not name-derived).
    a.raw(0x05); a.blob(le32(FS_DATA_LO))                  # add eax, FS_DATA_LO   (eax was nentries)
    a.raw(0xA3); a.blob(le32(cell('fs_lba')))              # mov [fs_lba], eax  (the data sector LBA)
    # (e) build the payload sector in diskbuf: zero 512B, copy len bytes from payload_ptr (DS=KDATA flat -> the module's
    #     User page is identity-mapped readable at CPL0; access_ok'd above). Then ATA WRITE diskbuf -> data_lba + flush.
    a.raw(0xBF); a.absR('diskbuf')                         # mov edi, diskbuf
    a.raw(0x31,0xC0)                                       # xor eax,eax
    a.raw(0xB9,0x80,0x00,0x00,0x00)                        # mov ecx,128 (128 dwords = 512B; NOT 256 -> would overrun by 512B)
    if mut!='fsnocld': a.raw(0xFC)                         # cld  (PUT diskbuf-zero; M-fsnocld drops it -> a hostile std=DF=1 makes rep stosd walk BACKWARD into the page tables below diskbuf)
    a.raw(0xF3,0xAB)                                       # rep stosd  (zero diskbuf)
    a.raw(0x8B,0x35); a.blob(le32(cell('fs_payptr')))      # mov esi, payload_ptr
    a.raw(0xBF); a.absR('diskbuf')                         # mov edi, diskbuf
    a.raw(0x8B,0x0D); a.blob(le32(cell('fs_len')))         # mov ecx, len
    if mut!='fsnocld': a.raw(0xFC)                         # cld  (PUT payload-copy; M-fsnocld drops it -> backward rep movsb)
    a.raw(0xF3,0xA4)                                       # rep movsb  (copy len bytes payload_ptr -> diskbuf)
    ata_write_sector('diskbuf', cell('fs_lba'))            # write the payload sector + flush
    # (f) write the directory entry into dirbuf slot[nentries] (dirbuf still holds the directory read in (c)).
    a.raw(0x8B,0x0D); a.blob(le32(cell('fs_nent')))        # mov ecx, nentries
    a.raw(0x6B,0xF9,FS_ENTSZ)                              # imul edi,ecx,28      (slot byte offset)
    a.raw(0x81,0xC7); a.absR('dirbuf')                     # add edi, dirbuf      (edi -> slot base)
    a.raw(0xC7,0x07,0x01,0x00,0x00,0x00)                  # mov dword[edi+0(valid)],1
    a.raw(0x8B,0x05); a.blob(le32(cell('fs_len')))         # mov eax,len
    a.raw(0x89,0x47,FS_OFF_LEN)                            # mov [edi+4(len)],eax
    a.raw(0x8B,0x05); a.blob(le32(cell('fs_lba')))         # mov eax,data_lba
    a.raw(0x89,0x47,FS_OFF_LBA)                            # mov [edi+24(data_lba)],eax
    # copy the 16-byte name from name_ptr -> [edi+8] (rep movsb 16). Preserve edi (the slot base) for nothing further;
    # we use a fresh edi for the name dest then we're done with the entry.
    a.raw(0x8B,0x35); a.blob(le32(cell('fs_nameptr')))     # mov esi, name_ptr
    a.raw(0x83,0xC7,FS_OFF_NAME)                           # add edi, 8   (edi -> name field within the slot)
    a.raw(0xB9,FS_NAMELEN,0x00,0x00,0x00)                  # mov ecx,16
    if mut!='fsnocld': a.raw(0xFC)                         # cld  (PUT name-copy; M-fsnocld drops it -> backward rep movsb)
    a.raw(0xF3,0xA4)                                       # rep movsb  (copy 16-byte name into the dir entry)
    # ATA WRITE dirbuf back to FS_DIR_LBA + flush.
    a.raw(0xC7,0x05); a.blob(le32(cell('tmp2'))); a.blob(le32(FS_DIR_LBA))   # mov [tmp2], FS_DIR_LBA
    ata_write_sector('dirbuf', cell('tmp2'))
    load_udata()
    a.raw(0xB8,0x01,0x00,0x00,0x00)                        # eax=1 (stored)
    a.raw(0xCF)
    a.lbl('fs_put_reject')
    load_udata()
    a.raw(0x31,0xC0)                                       # eax=0 (rejected -- no store)
    a.raw(0xCF)

    # ---- SYS_FS_GET (eax==8): resolve a NAME -> the stored payload (THE LINK -- name resolution). =====
    #   ABI: EBX=name_ptr (16 bytes, the query), ECX=dst_ptr, EDX=dst_cap.
    #   The kernel (CPL0):
    #     (a) access_ok(name_ptr, 16) against [alloc_lo,alloc_hi)[cur].
    #     (b) read FS_DIR_LBA into dirbuf; FIXED-loop scan EXACTLY FS_D slots for valid==1 && the full 16-byte name ==
    #         the query (a 16-byte compare, NOT a prefix/NUL scan). On no match: return found=0.
    #     (c) on match: take stored len; require len<=FS_MAXLEN and len<=dst_cap. Take stored data_lba and BOUND it to
    #         [FS_DATA_LO,FS_DATA_HI) BY VALUE (THE NEW SECURITY SURFACE -- the stored data_lba is attacker-influenced).
    #         Read that sector into diskbuf, access_ok(dst_ptr,len), copy len bytes into dst.
    #     Return eax = found(1/0), ecx = len.
    a.lbl('do_fs_get')
    load_kdata()
    a.raw(0x89,0x1D); a.blob(le32(cell('fs_nameptr')))     # mov [fs_nameptr], ebx (query name ptr)
    a.raw(0x89,0x0D); a.blob(le32(cell('fs_payptr')))      # mov [fs_payptr],  ecx (dst_ptr)
    a.raw(0x89,0x15); a.blob(le32(cell('fs_len')))         # mov [fs_len],     edx (dst_cap)
    # (a) access_ok(name_ptr, 16).
    a.raw(0x8B,0x05); a.blob(le32(cell('cur')))            # eax = cur
    ld('esi',arr('alloc_lo'),'eax'); ld('edi',arr('alloc_hi'),'eax')
    a.raw(0x8B,0x1D); a.blob(le32(cell('fs_nameptr')))     # ebx = name_ptr
    a.raw(0x39,0xF3); a.j(JB,'fs_get_reject')              # cmp ebx,lo ; jb reject
    a.raw(0x89,0xDA)                                       # mov edx,ebx
    a.raw(0x83,0xC2,FS_NAMELEN)                            # add edx,16
    if mut!='nocarrycheck': a.j(JB,'fs_get_reject')        # JC reject (CARRY = name_ptr+16 WRAP -> out-of-region; Codex access_ok-overflow fix). M-nocarrycheck drops it.
    a.raw(0x39,0xFA); a.j(JA,'fs_get_reject')              # cmp edx,hi ; ja reject
    # (b) read the directory, FIXED-loop scan D slots for valid && name==query.
    a.raw(0xC7,0x05); a.blob(le32(cell('tmp2'))); a.blob(le32(FS_DIR_LBA))   # mov [tmp2], FS_DIR_LBA
    ata_read_sector('dirbuf', cell('tmp2'))
    a.raw(0xC7,0x05); a.blob(le32(cell('fs_match'))); a.blob(le32(0))        # mov [fs_match], 0  (slot index of match; -1 sentinel via match flag below)
    a.raw(0x31,0xC9)                                       # xor ecx,ecx  (i=0)
    a.lbl('fs_get_scan')
    a.raw(0x83,0xF9,FS_D); a.j(JAE,'fs_get_scandone')      # cmp ecx,FS_D ; jae done (FIXED loop, exactly D slots)
    a.raw(0x89,0x0D); a.blob(le32(cell('fs_i')))           # mov [fs_i], ecx  (save i across the compare)
    # esi = dirbuf + i*FS_ENTSZ
    a.raw(0x6B,0xF1,FS_ENTSZ)                              # imul esi,ecx,28
    a.raw(0x81,0xC6); a.absR('dirbuf')                     # add esi, dirbuf
    a.raw(0x83,0x3E,0x01); a.j(JNE,'fs_get_scannext')      # cmp dword[esi+0(valid)],1 ; jne skip (not live)
    if mut != 'returnfirst':
        # full 16-byte name compare: edi = name_ptr (query), esi -> slot name field (esi+8). rep cmpsb 16.
        a.raw(0x8D,0x7E,FS_OFF_NAME)                       # lea edi,[esi+8]   (slot name field)
        a.raw(0x89,0xFE)                                   # mov esi,edi       (esi -> slot name)
        a.raw(0x8B,0x3D); a.blob(le32(cell('fs_nameptr'))) # mov edi, name_ptr (query name)
        a.raw(0xB9,FS_NAMELEN,0x00,0x00,0x00)              # mov ecx,16
        if mut!='fsnocld': a.raw(0xFC)                     # cld  (GET name-compare; M-fsnocld drops it -> a hostile std=DF=1 makes repe cmpsb walk BACKWARD off the dir slot/query into kernel memory -> wrong resolution)
        a.raw(0xF3,0xA6)                                   # repe cmpsb  (compare 16 bytes; ZF=1 iff fully equal)
        a.raw(0x8B,0x0D); a.blob(le32(cell('fs_i')))       # mov ecx, [fs_i]  (restore i)
        a.j(JNE,'fs_get_scannext')                         # names differ -> next slot
    else:
        # M-returnfirst (FORGE): ignore the query name -> the FIRST valid slot "matches" (positional, not by name). The
        # decoy-after-target alone does NOT catch this; the TWO-QUERY design does (query BRAVO emits ALPHA's payload).
        a.raw(0x8B,0x0D); a.blob(le32(cell('fs_i')))       # mov ecx,[fs_i]  (i, so the fall-through records this slot)
    # MATCH: record slot index (i = ecx) and break (set match flag = i+1 so 0 == no-match).
    a.raw(0x41)                                            # inc ecx (i+1)
    a.raw(0x89,0x0D); a.blob(le32(cell('fs_match')))       # mov [fs_match], i+1
    a.j(None,'fs_get_scandone')                            # first match wins -> stop scanning
    a.lbl('fs_get_scannext')
    a.raw(0x8B,0x0D); a.blob(le32(cell('fs_i')))           # mov ecx, [fs_i]
    a.raw(0x41); a.j(None,'fs_get_scan')                   # inc i ; loop
    a.lbl('fs_get_scandone')
    a.raw(0x8B,0x05); a.blob(le32(cell('fs_match')))       # eax = match (i+1, or 0 if none)
    a.raw(0x85,0xC0); a.j(JE,'fs_get_notfound')            # test eax,eax ; jz -> not found
    # recompute the matched slot base: i = match-1 ; esi = dirbuf + i*28
    a.raw(0x48)                                            # dec eax (i)
    a.raw(0x6B,0xF0,FS_ENTSZ)                              # imul esi,eax,28
    a.raw(0x81,0xC6); a.absR('dirbuf')                     # add esi, dirbuf  (esi -> matched slot)
    # (c) stored len -> bound to FS_MAXLEN and dst_cap.
    a.raw(0x8B,0x46,FS_OFF_LEN)                            # mov eax,[esi+4(len)]
    a.raw(0x3D); a.blob(le32(FS_MAXLEN)); a.j(JA,'fs_get_reject')   # cmp eax,512 ; ja reject (corrupt/oversized len)
    a.raw(0x3B,0x05); a.blob(le32(cell('fs_len'))); a.j(JA,'fs_get_reject')  # cmp eax,dst_cap ; ja reject (won't fit)
    a.raw(0xA3); a.blob(le32(cell('fs_len')))             # mov [fs_len], eax  (the actual copy length = stored len)
    # ---- THE NEW SECURITY SURFACE: bound the stored data_lba to [FS_DATA_LO,FS_DATA_HI) BY VALUE before the ATA read.
    a.raw(0x8B,0x46,FS_OFF_LBA)                            # mov eax,[esi+24(data_lba)]  (ATTACKER-INFLUENCED capability)
    if mut != 'nolbabound':
        a.raw(0x3D); a.blob(le32(FS_DATA_LO)); a.j(JB,'fs_get_reject')   # cmp eax,FS_DATA_LO ; jb reject (below the data window)
        a.raw(0x3D); a.blob(le32(FS_DATA_HI)); a.j(JAE,'fs_get_reject')  # cmp eax,FS_DATA_HI ; jae reject (at/above the data window)
    # M-nolbabound (FORGE): drop the data_lba access_ok -> an attacker-named data_lba (e.g. 0=the MBR) is read+leaked.
    a.raw(0xA3); a.blob(le32(cell('fs_lba')))             # mov [fs_lba], eax  (the bounded data LBA)
    if mut == 'fixedlba':
        # M-fixedlba (FORGE): ignore the stored (per-entry) data_lba; always read FS_DATA_LO (the first data sector).
        # Then query BRAVO (whose data sector is FS_DATA_LO+1) reads the WRONG sector (ALPHA's) -> RED.
        a.raw(0xC7,0x05); a.blob(le32(cell('fs_lba'))); a.blob(le32(FS_DATA_LO))   # mov [fs_lba], FS_DATA_LO
    # read the payload sector into diskbuf.
    ata_read_sector('diskbuf', cell('fs_lba'))
    # access_ok(dst_ptr, len) against [alloc_lo,alloc_hi)[cur].
    a.raw(0x8B,0x05); a.blob(le32(cell('cur')))           # eax=cur
    ld('esi',arr('alloc_lo'),'eax'); ld('edi',arr('alloc_hi'),'eax')
    a.raw(0x8B,0x1D); a.blob(le32(cell('fs_payptr')))     # ebx=dst_ptr
    a.raw(0x39,0xF3); a.j(JB,'fs_get_reject')             # cmp ebx,lo ; jb reject
    a.raw(0x8B,0x15); a.blob(le32(cell('fs_len')))        # edx=len
    a.raw(0x01,0xDA)                                      # add edx,ebx (dst end)
    if mut!='nocarrycheck': a.j(JB,'fs_get_reject')       # JC reject (CARRY = ptr+len WRAP -> out-of-region; Codex access_ok-overflow fix). M-nocarrycheck drops it.
    a.raw(0x39,0xFA); a.j(JA,'fs_get_reject')             # cmp edx,hi ; ja reject
    # copy len bytes diskbuf -> dst_ptr.
    a.raw(0xBE); a.absR('diskbuf')                        # mov esi, diskbuf
    a.raw(0x8B,0x3D); a.blob(le32(cell('fs_payptr')))     # mov edi, dst_ptr
    a.raw(0x8B,0x0D); a.blob(le32(cell('fs_len')))        # mov ecx, len
    if mut!='fsnocld': a.raw(0xFC)                        # cld  (GET dst-copy; M-fsnocld drops it -> a hostile std=DF=1 makes rep movsb read BACKWARD from diskbuf into the page tables below it -> a kernel-memory LEAK into dst)
    a.raw(0xF3,0xA4)                                      # rep movsb (copy payload to dst)
    a.raw(0x8B,0x0D); a.blob(le32(cell('fs_len')))        # ecx = len (returned in ecx)
    load_udata()
    a.raw(0xB8,0x01,0x00,0x00,0x00)                       # eax=1 (found)
    a.raw(0xCF)
    a.lbl('fs_get_notfound')
    load_udata()
    a.raw(0x31,0xC9)                                      # ecx=0 (len)
    a.raw(0x31,0xC0)                                      # eax=0 (not found)
    a.raw(0xCF)
    a.lbl('fs_get_reject')
    load_udata()
    a.raw(0x31,0xC9)                                      # ecx=0
    a.raw(0x31,0xC0)                                      # eax=0 (rejected)
    a.raw(0xCF)

    # ===== TIMER handler (vec 0x20 / IRQ0) (cleave L583-601, VERBATIM). INERT under IF=0 (never fires). =====
    GP=[(0,'t_edi'),(4,'t_esi'),(8,'t_ebp'),(16,'t_ebx'),(20,'t_edx'),(24,'t_ecx'),(28,'t_eax'),
        (32,'t_eip'),(40,'t_eflags'),(44,'t_esp')]
    a.lbl('timer_handler')
    a.raw(0x60)
    load_kdata()
    a.raw(0xF6,0x44,0x24,0x24,0x03); a.j(JE,'timer_kpriv')
    a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))
    for off,nm in GP:
        a.raw(0x8B,0x44,0x24,off)
        st(arr(nm),'ecx','eax')
    a.raw(0xB0,0x20,0xE6,0x20)
    a.j(None,'sched_switch')
    a.lbl('timer_kpriv')
    a.raw(0xB0,0x20,0xE6,0x20); a.raw(0x61); a.raw(0xCF)

    # ===== shared SCHED-SWITCH (cleave L603-688, VERBATIM). INERT under K=1 (only proc0; finalize handles exit). =====
    a.lbl('sched_switch')
    a.lbl('sw_wake')
    a.blob(bytes.fromhex('66bafd03ec'))
    a.raw(0xA8,0x01); a.j(JE,'sw_pickstart')
    a.raw(0x31,0xF6)
    a.lbl('sw_wscan')
    a.raw(0x3B,0x35); a.blob(le32(cell('nprocs'))); a.j(JAE,'sw_pickstart')
    ld('eax',arr('blocked'),'esi'); a.raw(0x85,0xC0); a.j(JNE,'sw_wfound')
    a.raw(0x46); a.j(None,'sw_wscan')
    a.lbl('sw_wfound')
    a.blob(bytes.fromhex('66baf803ec'))
    a.raw(0x0F,0xB6,0xC0)
    a.raw(0x89,0xC3)
    st(arr('t_eax'),'esi','eax')
    outi(0xCC)
    a.raw(0x89,0xF0); dr_eax()
    a.raw(0x89,0xD8); dr_eax()
    outi(0xCD)
    a.raw(0xC7,0x04,0xB5); a.blob(le32(arr('blocked'))); a.blob(le32(0))
    a.lbl('sw_pickstart')
    a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))
    a.raw(0xBF); a.blob(le32(MAXPROC+1))
    a.lbl('pick')
    a.raw(0x41)
    a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JB,'nowrap')
    a.raw(0x31,0xC9)
    a.lbl('nowrap')
    a.raw(0x4F); a.j(JS,'sw_idle')
    ld('eax',arr('exited'),'ecx'); a.raw(0x85,0xC0); a.j(JNE,'pick')
    ld('eax',arr('blocked'),'ecx'); a.raw(0x85,0xC0); a.j(JNE,'pick')
    ld('eax',arr('alloc_lo'),'ecx'); a.raw(0x85,0xC0); a.j(JE,'pick')
    a.raw(0xFF,0x05); a.blob(le32(cell('switches')))
    a.raw(0xFF,0x04,0x8D); a.blob(le32(arr('disp')))
    a.raw(0x8B,0x15); a.blob(le32(cell('cur')))
    flip_pg(arr('modstart'),'edx',False); flip_pg(arr('alloc_lo'),'edx',False)
    flip_pg(arr('modstart'),'ecx',True);  flip_pg(arr('alloc_lo'),'ecx',True)
    a.raw(0x89,0x0D); a.blob(le32(cell('cur')))
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)
    ld('eax',arr('started'),'ecx'); a.raw(0x85,0xC0); a.j(JNE,'do_restore')
    a.raw(0xC7,0x04,0x8D); a.blob(le32(arr('started'))); a.blob(le32(1))
    a.raw(0xBC); a.blob(le32(kstack)); load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))
    pushidx(arr('alloc_hi'),'ecx')
    a.raw(0x68); a.blob(le32(0x00000002))                  # eflags IF=0 (lethe)
    a.raw(0x68); a.blob(le32(UCODE3))
    pushidx(arr('modstart'),'ecx')
    for _ in range(8): a.raw(0x68); a.blob(le32(0))
    a.raw(0x61); a.raw(0xCF)
    a.lbl('do_restore')
    a.raw(0xBC); a.blob(le32(kstack)); load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))
    pushidx(arr('t_esp'),'ecx')
    pushidx(arr('t_eflags'),'ecx')
    a.raw(0x68); a.blob(le32(UCODE3))
    pushidx(arr('t_eip'),'ecx')
    for nm in ('t_eax','t_ecx','t_edx','t_ebx'): pushidx(arr(nm),'ecx')
    a.raw(0x68); a.blob(le32(0))
    for nm in ('t_ebp','t_esi','t_edi'): pushidx(arr(nm),'ecx')
    a.raw(0x61)
    a.raw(0xCF)
    a.lbl('sw_idle')
    a.j(None,'sw_wake')

    # ===== #GP / #PF / panic fault->continue (cleave L690-797). lethe REMOVES cleave's COW arm from pf_handler (the
    #   remap is a SYSCALL, not a #PF); pf_handler keeps the homestead demand-commit branch (inert) + terminal kill. =====
    a.lbl('gp_handler')
    load_kdata(); outi(0xF0)
    a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax(); a.raw(0x8B,0x44,0x24,0x08); dr_eax(); a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xF1)
    a.raw(0xF6,0x44,0x24,0x08,0x03); a.j(JE,'gp_kpanic')
    a.raw(0xB0,0x47); a.raw(0xA2); a.blob(le32(ANSWER))
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('gp_kpanic'); a.j(None,'sdtail')
    a.lbl('pf_handler')
    # homestead demand-commit branch (cleave L704-735): inert in lethe (the prober never faults in the grow window). Kept.
    a.raw(0x60)                                        # pusha
    load_kdata()
    a.raw(0xF6,0x44,0x24,0x20,0x01); a.j(JNE,'pf_nodemand')   # err.P!=0 -> not not-present
    a.raw(0x0F,0x20,0xD0)                              # eax = cr2
    a.raw(0x8B,0x15); a.blob(le32(cell('cur')))
    ld('ecx',arr('grow_floor'),'edx'); a.raw(0x39,0xC8); a.j(JB,'pf_nodemand')
    ld('ecx',arr('alloc_lo'),'edx');   a.raw(0x39,0xC8); a.j(JAE,'pf_nodemand')
    a.raw(0x89,0xC1)
    a.raw(0xC1,0xE9,0x0A); a.raw(0x83,0xE1,0xFC); a.raw(0x81,0xC1); a.absR('pt')
    outi(0xC2)
    a.raw(0x8B,0x44,0x24,0x20); dr_eax()
    a.raw(0x0F,0x20,0xD0); dr_eax()
    a.raw(0x8B,0x01); dr_eax()
    a.raw(0x0F,0x20,0xD0); a.raw(0x25); a.blob(le32(0xFFFFF000)); a.raw(0x83,0xC8,0x07)
    a.raw(0x89,0x01)
    dr_eax()
    outi(0xC3)
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)
    a.raw(0x8B,0x15); a.blob(le32(cell('cur')))
    a.raw(0x0F,0x20,0xD0); a.raw(0x25); a.blob(le32(0xFFFFF000))
    st(arr('alloc_lo'),'edx','eax')
    load_udata()
    a.raw(0x61)
    a.raw(0x83,0xC4,0x04)
    a.raw(0xCF)
    a.lbl('pf_nodemand')
    # lethe: NO COW arm. A #PF that is not a demand-commit falls straight through to the terminal kill (restore + unwind).
    load_udata()
    a.raw(0x61)
    # ----- EXISTING terminal kill (cleave L782-789) -----
    load_kdata(); outi(0xD0)
    a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax(); a.raw(0x8B,0x44,0x24,0x08); dr_eax(); a.raw(0x0F,0x20,0xD0); dr_eax(); a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xD1)
    a.raw(0xF6,0x44,0x24,0x08,0x03); a.j(JE,'pf_kpanic')
    a.raw(0xB0,0x50); a.raw(0xA2); a.blob(le32(ANSWER))
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('pf_kpanic'); a.j(None,'sdtail')
    a.lbl('panic_handler')
    a.raw(0xF6,0x44,0x24,0x04,0x03); a.j(JE,'kpanic')
    load_kdata(); outi(0xE2)
    a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax()
    outi(0xE3)
    a.raw(0xB0,0x46); a.raw(0xA2); a.blob(le32(ANSWER))
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('kpanic'); outi(ord('P')); shutdown()

    # ===== descriptor tables (cleave L799-835, VERBATIM) =====
    a.lbl('gdtr'); a.blob(le16(0x2F)); a.absR('gdt')
    a.lbl('idtr'); a.blob(le16(0x31*8-1)); a.absR('idt')
    def gdt_bytes(L):
        b=bytearray()
        b+=gdt_desc(0,0,0,0); b+=gdt_desc(0,0xFFFFF,0x9A,0xC); b+=gdt_desc(0,0xFFFFF,0x92,0xC)
        b+=gdt_desc(0,0xFFFFF,0xFA,0xC); b+=gdt_desc(0,0xFFFFF,0xF2,0xC); b+=gdt_desc(L['tss'],0x67,0x89,0x0)
        return bytes(b)
    a.lbl('gdt'); a.defer(6*8, gdt_bytes)
    def idt_bytes(L):
        b=bytearray()
        for v in range(0x31):
            if v==13: b+=idt_gate(L['gp_handler'],KCODE,0x8E)
            elif v==14: b+=idt_gate(L['pf_handler'],KCODE,0x8E)
            elif v==0x20: b+=idt_gate(L['timer_handler'],KCODE,0x8E)
            elif v==0x30: b+=idt_gate(L['exit_handler'],KCODE,0xEE)
            else: b+=idt_gate(L['panic_handler'],KCODE,0x8E)
        return bytes(b)
    a.lbl('idt'); a.defer(0x31*8, idt_bytes)
    def tss_bytes(L):
        t=bytearray(104); t[4:8]=le32(kstack); t[8:12]=le32(KDATA); t[0x66:0x68]=le16(0x68)
        return bytes(t)
    a.lbl('tss'); a.defer(104, tss_bytes)
    a.align(4096); a.lbl('pd')
    def pd_bytes(L):
        b=bytearray()
        for i in range(1024):
            if i < NPT: b+=le32(L['pt'] + i*4096 + 3 + 4)
            else: b+=le32(0)
        return bytes(b)
    a.defer(4096, pd_bytes)
    a.lbl('pt')
    def pt_bytes(L):
        b=bytearray()
        for g in range(1024*NPT): b+=le32(g*4096 + 3)
        return bytes(b)
    a.defer(4096*NPT, pt_bytes)
    # link37: the KERNEL's 512-byte ATA sector buffer (the block device reads land here, NOT in module memory --
    # this is the confused-deputy boundary: a CPL3 module cannot DMA/PIO a sector itself, so the kernel reads into
    # its OWN supervisor RAM and hands back exactly the one bounds-checked byte the module asked for).
    a.align(4)
    a.lbl('diskbuf'); a.blob(b'\x00'*512)
    # link39: a SECOND kernel sector buffer for the FILESYSTEM directory sector. SYS_FS_PUT/GET read the directory into
    # dirbuf and scan/edit it there, keeping diskbuf free for the data (payload) sector -- both are kernel-private
    # supervisor RAM (the confused-deputy boundary: a CPL3 module never touches a sector buffer directly).
    a.align(4)
    a.lbl('dirbuf'); a.blob(b'\x00'*512)
    a.lbl('body_start')
    a.blob(bytes([0x0F,0xB6,0x05])+le32(ANSWER)+bytes([0x50,0x58]))   # movzx eax,[answer]; push;pop
    a.blob(EPI)
    return a.assemble()

EPI=bytes([136,195, 102,186,233,0, 176,222,238, 136,216,238, 176,173,238,
           136,216, 52,49, 36,127,
           102,186,244,0,238, 102,186,0,137]) \
    + b''.join(bytes([176,c,238]) for c in b'Shutdown') + bytes([250,244,235,253])


def build_elf(mut=None, stage='full'):       # cleave L847-859, VERBATIM
    code0,_=build_code(0,0,mut,stage); clen=len(code0)
    memsz=12+clen+16384
    kstack=LOAD+memsz; kend=LOAD+memsz
    code,labels=build_code(kstack,kend,mut,stage); assert len(code)==clen,(len(code),clen)
    filesz=12+len(code); pad4=(4-(filesz%4))%4
    shoff=4096+filesz+pad4
    ehdr=(b'\x7fELF\x01\x01\x01\x00'+b'\x00'*8+struct.pack('<HHI',2,3,1)+le32(ENTRY)+le32(52)+le32(shoff)+le32(0)
          +struct.pack('<HHHHHH',52,32,1,40,1,0))
    phdr=le32(1)+le32(4096)+le32(LOAD)+le32(LOAD)+le32(filesz)+le32(memsz)+le32(7)+le32(4096)
    mbh=bytes((0x02,0xB0,0xAD,0x1B))+le32(0x00000003)+le32(0xE4524FFB)
    img=ehdr+phdr+b'\x00'*(4096-84)+mbh+code+b'\x00'*pad4+b'\x00'*40
    return img,kend,labels


# ============================ PARSE (cleave L862-889, VERBATIM) ============================
def parse_head(stream):
    i=0
    while i<len(stream) and stream[i]==0x9C and i+25<=len(stream): i+=25
    if i>=len(stream) or stream[i]!=0x9A: return None
    i+=1
    nc=len(CELLS)
    if i+16+4*nc > len(stream): return None
    k0,k1,ma,ml=struct.unpack('<4I',stream[i:i+16]); i+=16
    cells=struct.unpack('<%dI'%nc,stream[i:i+4*nc]); i+=4*nc
    cd=dict(zip(CELLS,cells)); cd['k0']=k0; cd['k1']=k1
    cd['_blockok']=(i<len(stream) and stream[i]==0x9B); i+=1
    cd['_tail']=stream[i:]
    return cd

def parr(cd,nm,i): return cd[f'{nm}#{i}']

import re
def _wframes(tail):     # cleave L880-889, VERBATIM
    out=[];pos=0
    while True:
        j=tail.find(b'\xD4',pos)
        if j<0: break
        if j+17>len(tail): break
        ln,cs,eip,esp=struct.unpack('<4I',tail[j+1:j+17]); body=tail[j+17:j+17+ln]
        closed=tail[j+17+ln:j+18+ln]==b'\xD5'
        out.append(dict(ln=ln,cs=cs,eip=eip,esp=esp,body=body,closed=closed,at=j)); pos=j+18+ln
    return out


# ============================ lethe FORCING: the alias-remap prober ============================
def module_lethe_prober(seed=None, variant='full'):
    # The lethe prober (proc0, K=1). With seed=None it reads a LATE-BOUND seed byte over COM1 (SYS_READ); with seed
    # given it BAKES the seed (STEP-0 smoke). variant='full' = the witness prober; variant='nowarm' = the CONTROL that
    # SKIPS step-2's warm (used to prove the warm is load-bearing for the M-noinvlpg witness).
    #   (1) read seed -> x=hx(seed), y=hy(seed) (kept on the stack/recomputed; no register survives int 0x30).
    #   (2) WARM (full only): write x to [V] (-> F) ; read [A] (== x: confirms A,V alias F AND warms V->F into the TLB).
    #   (3) SYS_REMAP (int 0x30, eax=4): the kernel remaps V->F' + invlpg [V].
    #   (4) write y to [V]  (WITH invlpg -> F' ; WITHOUT -> the stale TLB entry -> F).
    #   (5) read [A] (-> F), [V] (-> F' if invlpg else stale F), [B] (-> F'); SYS_WRITE all three; SYS_EXIT.
    m=Asm()
    if seed is None:
        m.raw(0xB8,0x00,0x00,0x00,0x00)           # mov eax,0  (SYS_READ)
        m.raw(0xCD,0x30)                          # int 0x30 -> seed byte in eax
        m.raw(0x25); m.blob(le32(0xFF))           # and eax,0xFF -> eax = seed
    else:
        m.raw(0xB8); m.blob(le32(seed & 0xFF))    # mov eax, seed (baked)
    m.raw(0x89,0xC3)                              # mov ebx,eax   (save seed in ebx; ebx survives between our int 0x30s
    #   because we recompute x/y from ebx and the kernel's REMAP/WRITE arms preserve ebx -- they only set eax. We do NOT
    #   rely on ebx across SYS_WRITE either: each emit re-derives the address constant; ebx only feeds the x/y compute.)
    def derive_x():                              # eax = x = LETHE_TAG_X | seed
        m.raw(0x89,0xD8)                          # mov eax,ebx (seed)
        m.raw(0x0D); m.blob(le32(LETHE_TAG_X))    # or eax,LETHE_TAG_X
    def derive_y():                              # eax = y = (LETHE_TAG_Y | seed) + 0x40
        m.raw(0x89,0xD8)                          # mov eax,ebx (seed)
        m.raw(0x0D); m.blob(le32(LETHE_TAG_Y))    # or eax,LETHE_TAG_Y
        m.raw(0x05); m.blob(le32(0x40))           # add eax,0x40
    if variant!='nowarm':
        # (2) WARM: write x to [V] (-> F), then a read of [A] (-> F) to confirm aliasing AND warm V->F into the TLB.
        derive_x()
        m.raw(0xA3); m.blob(le32(V_VADDR+TEST_OFF))   # mov [V], x   (-> F; this caches V->F in the TLB)
        m.raw(0xA1); m.blob(le32(A_VADDR+TEST_OFF))   # mov eax,[A]  (-> F; confirms A reads x -- aliasing live)
        # (warm read of V too so the V->F translation is definitely cached, independent of write-vs-read TLB nuances)
        m.raw(0xA1); m.blob(le32(V_VADDR+TEST_OFF))   # mov eax,[V]  (-> F; explicit V->F TLB warm)
    # (3) SYS_REMAP
    m.raw(0xB8); m.blob(le32(SYS_REMAP))          # mov eax,4 (SYS_REMAP)
    m.raw(0xCD,0x30)                              # int 0x30 -> kernel: PTE[V]<-F'|7 ; invlpg [V] ; iret
    # (4) write y to [V]  (WITH invlpg -> F' ; WITHOUT -> stale -> F)
    derive_y()
    m.raw(0xA3); m.blob(le32(V_VADDR+TEST_OFF))   # mov [V], y
    # (5) read A, V, B and SYS_WRITE each (in-region buf so SYS_WRITE access_ok passes)
    def emit_word_at(addr):
        m.raw(0xA1); m.blob(le32(addr))           # mov eax,[addr]
        m.raw(0x50)                               # push eax (onto the prober's OWN in-region stack)
        m.raw(0x8D,0x0C,0x24)                     # lea ecx,[esp]
        m.raw(0xBA,0x04,0x00,0x00,0x00)           # mov edx,4
        m.raw(0xB8,0x02,0x00,0x00,0x00)           # mov eax,2 (SYS_WRITE)
        m.raw(0xCD,0x30)
        m.raw(0x83,0xC4,0x04)                     # add esp,4
    emit_word_at(A_VADDR+TEST_OFF)                # A (-> F): must be x (F untouched by the remap)
    emit_word_at(V_VADDR+TEST_OFF)                # V (-> F' if invlpg else stale F): must be y
    emit_word_at(B_VADDR+TEST_OFF)                # B (-> F'): must be y
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


# ============================ link37 FORCING: the disk pointer-chase prober ============================
def module_disk_prober(khops=DISK_KHOPS, start_idx=DISK_START_IDX):
    # The link37 prober (proc0, K=1 process, a fixed UNROLLED khops-hop chase; no loops -- Herbert has none).
    #   hop 0: read sector LBA = DISK_RESV_LO + start_idx, offset 0 -> b0  ; SYS_WRITE b0
    #   hop i: read sector LBA = DISK_RESV_LO + b_{i-1}, offset 0 -> b_i   ; SYS_WRITE b_i
    # Each next-LBA is DATA-DEPENDENT on the prior byte read off the disk -> the kernel must do ADDRESSED
    # random-access reads in a late-bound order a serial COM1 stream cannot reproduce. The author-unknown disk
    # bytes ARE the late-bound input (recorded at disk-build time; grade37 follows the same chase to predict).
    # Register contract across our int 0x30 eax=5 calls: the kernel do_disk_read returns the byte in EAX and
    # preserves EBX (it never writes EBX in the genuine path); SYS_WRITE clobbers eax/ecx/edx. We therefore
    # stash each read byte on our OWN in-region stack before emitting, and recompute the next LBA from it.
    m=Asm()
    def do_read(lba_setup):
        lba_setup()                               # leaves the target LBA in ebx
        m.raw(0x31,0xC9)                          # xor ecx,ecx  (byte-offset 0 within the sector)
        m.raw(0xB8); m.blob(le32(SYS_DISK_READ))  # mov eax,5 (SYS_DISK_READ)
        m.raw(0xCD,0x30)                          # int 0x30 -> kernel ATA read; byte in eax (0..255)
        m.raw(0x25); m.blob(le32(0xFF))           # and eax,0xFF  (defensive: keep just the byte)
    def emit_byte_from_stack():
        # the read byte is on TOS as a dword (we push eax). SYS_WRITE 1 byte from [esp].
        m.raw(0x8D,0x0C,0x24)                     # lea ecx,[esp]   (points at the byte)
        m.raw(0xBA,0x01,0x00,0x00,0x00)           # mov edx,1       (1 byte)
        m.raw(0xB8,0x02,0x00,0x00,0x00)           # mov eax,2 (SYS_WRITE)
        m.raw(0xCD,0x30)
    # hop 0: fixed start LBA
    do_read(lambda:(m.raw(0xBB), m.blob(le32(DISK_RESV_LO+start_idx))))   # mov ebx, LO+start_idx
    m.raw(0x50)                                   # push eax  (save b0 on our stack)
    emit_byte_from_stack()                        # SYS_WRITE b0
    # hops 1..khops-1: next LBA = DISK_RESV_LO + (b_prev & 0x3F)  (b_prev is on TOS)
    # platter FIX (the module's job -- the KERNEL is unchanged): the chase byte is 8-bit (0..255) but the window is
    # 64 sectors (indices 0..63). MASK b_prev to b&0x3F so next-LBA = DISK_RESV_LO + (b&0x3F) ALWAYS stays in-window;
    # without the mask a byte >= 64 -> out-of-window LBA -> the kernel's access_ok rejects (returns sentinel 0) ->
    # re-chase index 0, and the oracle's chase_bytes[b] KeyErrors. Masking in BOTH prober and oracle keeps the
    # benign chase well-defined every hop.
    for _ in range(khops-1):
        # set ebx = DISK_RESV_LO + ([esp] & 0x3F)  (the prior byte, masked into the 64-sector window)
        m.raw(0x8B,0x1C,0x24)                     # mov ebx,[esp]   (b_prev, zero-extended dword we pushed)
        m.raw(0x81,0xE3); m.blob(le32(DISK_WINMASK))   # and ebx, 0x3F  (mask into the window: indices 0..63)
        m.raw(0x81,0xC3); m.blob(le32(DISK_RESV_LO))   # add ebx, DISK_RESV_LO
        m.raw(0x83,0xC4,0x04)                     # add esp,4  (pop the consumed prior byte)
        do_read(lambda:None)                      # ebx already set
        m.raw(0x50)                               # push eax (save b_i)
        emit_byte_from_stack()                    # SYS_WRITE b_i
    m.raw(0x83,0xC4,0x04)                          # add esp,4  (pop the last byte)
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


DISK_WINMASK = (DISK_RESV_HI - DISK_RESV_LO) - 1   # window is 64 sectors -> mask 0x3F (must be 2^k-1)
assert DISK_WINMASK & (DISK_WINMASK + 1) == 0, 'window size must be a power of two so b&MASK stays in-window'
assert DISK_WINMASK == 0x3F, 'platter: window is 64 sectors -> b&0x3F'

def disk_chase_expect(chase_bytes, khops=DISK_KHOPS, start_idx=DISK_START_IDX):
    # Follow the SAME pointer-chase in Python over the recorded disk bytes. chase_bytes: dict {index -> byte}
    # giving the byte at offset 0 of sector DISK_RESV_LO+index. Returns the list of bytes the prober must emit.
    # platter FIX (mirrors the prober's and ebx,0x3F): the chase byte b is 8-bit (0..255) but the window is 64
    # sectors (indices 0..63). MASK the next index to b&0x3F so every hop stays in-window and the benign chase is
    # always well-defined (no out-of-window reject -> sentinel 0 -> re-chase / KeyError).
    out=[]; idx=start_idx
    for _ in range(khops):
        b=chase_bytes[idx] & 0xFF
        out.append(b)
        idx = b & DISK_WINMASK   # the byte NAMES the next index within the window (next LBA = DISK_RESV_LO + (b&0x3F))
    return out


# ============================ WHITE-BOX assert ============================
def assert_lethe(kelf):
    """White-box structural co-pin for lethe's ALIAS-REMAP + TARGETED TLB INVALIDATION (the byte-pin to build_elf() is
       the PRIMARY binding). Pins the pieces no cr3-flush / no-remap forge can produce:
         (1) the THREE NON-IDENTITY alias installs at boot: PTE[A]<-F|7, PTE[V]<-F|7, PTE[B]<-F'|7 -- same F for A,V
             (ALIASED), F!=A,F!=V (NON-IDENTITY), F'!=F (the remap target is a NEW frame), F'!=B.
         (2) the SYS_REMAP arm: PTE[V] <- F'|7  (the remap) AND `invlpg [V]` == 0F 01 3D <le32(V_VADDR)> (the TARGETED
             invalidation of EXACTLY V).
         (3) the remap arm must NOT use a cr3 reload as its invalidation: between the PTE[V]<-F' write and the iret there
             must be NO `mov cr3,eax` (0F 22 D8) -- otherwise it is the heavy flush, not the surgical primitive.
       M-noinvlpg (drop invlpg), M-noremap (drop the PTE[V] write), M-cr3insteadofinvlpg (cr3 not invlpg), M-sameframe
       (F'==F) each break one of these AND (except cr3) go RED on output. Returns True/False."""
    _,_,labels=build_elf()
    pt=labels['pt']
    inst_a = bytes([0xC7,0x05])+le32(pt+(A_VADDR>>12)*4)+le32(F_FRAME|7)    # PTE[A] <- F|7
    inst_v = bytes([0xC7,0x05])+le32(pt+(V_VADDR>>12)*4)+le32(F_FRAME|7)    # PTE[V] <- F|7  (boot: V aliases F)
    inst_b = bytes([0xC7,0x05])+le32(pt+(B_VADDR>>12)*4)+le32(FP_FRAME|7)   # PTE[B] <- F'|7
    if inst_a not in kelf: return False
    if inst_v not in kelf: return False
    if inst_b not in kelf: return False
    # NON-IDENTITY + distinct-frame invariants
    if (F_FRAME&0xFFFFF000)==(A_VADDR&0xFFFFF000): return False
    if (F_FRAME&0xFFFFF000)==(V_VADDR&0xFFFFF000): return False
    if (FP_FRAME&0xFFFFF000)==(B_VADDR&0xFFFFF000): return False
    if (F_FRAME&0xFFFFF000)==(FP_FRAME&0xFFFFF000): return False
    # (2) the SYS_REMAP arm: PTE[V] <- F'|7 followed (in the same arm) by invlpg [V]. Pin them as ONE adjacent block
    # (pin-reachability-not-presence): the remap write THEN the targeted invalidation, contiguous, so a forge can't
    # leave a stray invlpg elsewhere while the arm actually cr3-flushes.
    remap_write = bytes([0xC7,0x05])+le32(pt+(V_VADDR>>12)*4)+le32(FP_FRAME|7)   # mov dword[PTE_V], F'|7
    invlpg_v    = bytes([0x0F,0x01,0x3D])+le32(V_VADDR)                          # invlpg [V_VADDR]
    if (remap_write+invlpg_v) not in kelf: return False
    # (3) the remap arm must NOT contain a cr3 reload between the remap write and the iret. Locate the remap arm: from
    # the remap_write to the FIRST iret (0xCF) after it; assert no `mov cr3,eax` (0F 22 D8) in that span.
    p = kelf.find(remap_write)
    if p < 0: return False
    arm_end = kelf.find(b'\xCF', p)
    if arm_end < 0: return False
    arm = kelf[p:arm_end]
    if any(bytes([0x0F,0x22,b]) in arm for b in range(0xD8,0xE0)): return False  # mov cr3,r32 (0F 22 D8..DF, ANY reg) in
    #   the remap arm -> heavy flush, REJECT. (Codex caught the D8-only reject: a cr3,edx (0F 22 DA) flush slipped through
    #   while a dead/adjacent invlpg passed check-2; widening to D8..DF bans every mov cr3,r32 so the ONLY invalidation can
    #   be the targeted invlpg. M-cr3edx proves this bites.)
    if invlpg_v not in arm: return False                # the invlpg must be IN the remap arm (reachable before iret)
    return True


def assert_platter(kelf):
    """White-box structural co-pin for platter's BLOCK DEVICE (the byte-pin to build_elf() is the PRIMARY binding;
       this co-pin REQUIRED because M-noboundscheck is OUTPUT-INVISIBLE to the benign grade_disk -- a sandbox break
       that still chases correctly through the window yet would happily leak the MBR / GRUB / FAT sectors for a
       hostile LBA. The benign output grade can't see the dropped access_ok; this assert does). Pins, in the
       do_disk_read arm and contiguous-and-reachable so a forge can't leave the pieces dead elsewhere:
         (1) the TWO LBA-bound cmp instructions guarding the window: `cmp ebx,DISK_RESV_LO ; jb reject` and
             `cmp ebx,DISK_RESV_HI ; jae reject` -- i.e. the byte pair 81 FB <le32(LO)> ... 81 FB <le32(HI)>,
             BOTH present, the LO-cmp before the HI-cmp, BOTH inside the arm and before the ATA programming.
             M-noboundscheck drops both -> REJECT.
         (2) the ATA PIO LBA28 command sequence, in order, contiguous within the arm: program 0x1F6<-0xE0 (drive/LBA),
             0x1F2<-1 (sector count), the LBA bytes out to 0x1F3/0x1F4/0x1F5, 0x1F7<-0x20 (READ SECTORS), the BSY/DRQ
             poll on 0x1F7, then `66 F3 6D` (rep INSW, 16-bit) transferring exactly one 512-byte sector. M-noread
             drops the whole sequence -> REJECT.
         (2b) the `cld` (0xFC) IMMEDIATELY before the `rep insw` -- DF=0 forces the transfer FORWARD from diskbuf. A
             forge that DROPS the cld (M-nocld) is OUTPUT-INVISIBLE on the benign gate (the prober's ambient DF=0) but
             lets a hostile module `std` (DF=1) before int 0x30 walk rep insw BACKWARD, corrupting kernel memory below
             diskbuf. Pinned as the EXACT adjacency `FC 66 F3 6D` (cld then rep insw) -> M-nocld REJECT. (Same output-
             invisible-forge class as the dropped ECX bound; primary white-box discriminator + the hostile-DF output leg.)
         (3) the returned byte is `movzx eax, byte [ecx + diskbuf]` (0F B6 81 <le32(diskbuf)>) reading the LIVE kernel
             diskbuf the rep-insw just filled -- NOT a baked immediate (no `mov eax,imm32` / `mov al,imm8` feeding the
             return). A baked-byte forge that returns a constant instead of the freshly-read sector byte -> REJECT.
       All three are pinned BY THE EXACT EMITTED BYTES (built from build_elf()'s own labels), and located WITHIN the
       do_disk_read arm (from the diskbuf-return movzx's containing arm), so the loader/CPU actually executes them on
       the eax=5 path. Returns True/False."""
    _,_,labels=build_elf()
    diskbuf=labels['diskbuf']
    # --- locate the do_disk_read arm: it BEGINS after the dispatch and ENDS at the disk_reject path. We bound it as
    #     [first cmp ebx,LO ... first iret after the movzx-from-diskbuf]. The two cmp guards and the ATA sequence and
    #     the movzx-return all live in that span; the reject arm (eax=0;iret) is AFTER the genuine arm's iret. ---
    cmp_lo = bytes([0x81,0xFB])+le32(DISK_RESV_LO)       # cmp ebx, DISK_RESV_LO
    cmp_hi = bytes([0x81,0xFB])+le32(DISK_RESV_HI)       # cmp ebx, DISK_RESV_HI
    movzx_ret = bytes([0x0F,0xB6,0x81])+le32(diskbuf)    # movzx eax, byte [ecx + diskbuf]   (the LIVE return)
    # (3) the return MUST read the live diskbuf (movzx from [ecx+diskbuf]); pin its presence first (it also anchors the arm).
    if movzx_ret not in kelf: return False
    ret_at = kelf.find(movzx_ret)
    # the genuine arm runs from the FIRST cmp_lo up to the iret right after the movzx-return.
    p_lo = kelf.find(cmp_lo)
    if p_lo < 0: return False                            # LO-bound cmp absent -> M-noboundscheck
    if ret_at < p_lo: return False                       # the return must be AFTER the bound check (same arm, in order)
    arm_end = kelf.find(b'\xCF', ret_at)                 # the iret that resumes the prober
    if arm_end < 0: return False
    arm = kelf[p_lo:arm_end+1]
    # (1) BOTH cmp guards, in order, inside the arm and BEFORE the ATA programming.
    if cmp_lo not in arm: return False
    i_lo = arm.find(cmp_lo)
    i_hi = arm.find(cmp_hi)
    if i_hi < 0: return False                            # HI-bound cmp absent -> M-noboundscheck
    if not (i_lo < i_hi): return False                   # LO must be checked before HI
    # (2) the ATA PIO LBA28 command sequence, contiguous and reachable, AFTER the bound checks. Pin each step by its
    #     exact emitted bytes and require strictly increasing positions within the arm (so the sequence is in order and
    #     not a scrambled / dead fragment). The LBA-byte outs read [tmp1], so bind the port-program prefixes.
    seq = [
        bytes([0x66,0xBA,0xF6,0x01, 0xB0,0xE0,0xEE]),                # mov dx,0x1F6 ; mov al,0xE0 ; out  (drive/LBA head)
        bytes([0x66,0xBA,0xF2,0x01, 0xB0,0x01,0xEE]),                # mov dx,0x1F2 ; mov al,1   ; out  (sector count = 1)
        bytes([0x66,0xBA,0xF3,0x01]),                               # mov dx,0x1F3  (LBA[7:0]  out follows)
        bytes([0x66,0xBA,0xF4,0x01]),                               # mov dx,0x1F4  (LBA[15:8])
        bytes([0x66,0xBA,0xF5,0x01]),                               # mov dx,0x1F5  (LBA[23:16])
        bytes([0x66,0xBA,0xF7,0x01, 0xB0,0x20,0xEE]),                # mov dx,0x1F7 ; mov al,0x20 ; out  (READ SECTORS cmd)
        bytes([0xA8,0x80]),                                         # test al,0x80   (BSY poll)
        bytes([0xA8,0x08]),                                         # test al,0x08   (DRQ poll)
        bytes([0x66,0xF3,0x6D]),                                    # rep insw (16-bit) -> 512 bytes into diskbuf
    ]
    pos = i_hi + len(cmp_hi)                             # the ATA sequence must come AFTER the HI-bound check
    for step in seq:
        k = arm.find(step, pos)
        if k < 0: return False                          # a missing step -> M-noread (or a tampered ATA sequence)
        pos = k + len(step)
    # the BSY/DRQ poll reads the status port (0x1F7) right before each test -- bind the status `in al,dx` (66 BA F7 01 EC)
    # appears at least twice within the arm (once for BSY, once for DRQ); a forge that drops the poll desyncs the DRQ buffer.
    status_in = bytes([0x66,0xBA,0xF7,0x01,0xEC])
    if arm.count(status_in) < 2: return False
    # (2b) the `cld` (0xFC) must sit IMMEDIATELY before the `rep insw` (66 F3 6D), so DF=0 forces the transfer to walk
    # FORWARD from diskbuf. WITHOUT it (M-nocld) a hostile module that does `std` (DF=1) before int 0x30 makes rep insw
    # walk BACKWARD, corrupting kernel memory below diskbuf. That defect is OUTPUT-INVISIBLE on the benign grade (the
    # prober's ambient DF=0) -- the same forge class as the dropped ECX bound -- so this white-box pin is the primary
    # discriminator (paired with the hostile-DF output leg). Pin the EXACT adjacency (cld THEN rep insw), within the arm.
    cld_repinsw = bytes([0xFC, 0x66,0xF3,0x6D])           # cld ; rep insw  (adjacent)
    if cld_repinsw not in arm: return False               # M-nocld drops the 0xFC -> REJECT
    # (3, strengthened) the return is the live movzx, and there is NO `mov eax,imm32` (B8) or `mov al,imm8` (B0) feeding
    # EAX between the rep-insw and the movzx-return that would let a baked byte stand in for the read. We bound the
    # post-read tail (from the rep insw to the return) and require it free of a return-value bake (mov eax,imm into the
    # return). load_udata legitimately does `mov eax,UDATA3` (B8) -- that is OVERWRITTEN by the movzx, so we only forbid
    # a B8/B0-into-eax AFTER the movzx and before the iret (there must be none: the movzx is the LAST eax write).
    tail = arm[arm.find(movzx_ret)+len(movzx_ret):]      # bytes after the movzx-return, up to (incl) the iret
    # the only thing between the movzx and the iret is the iret itself (0xCF). Any B8/B0 here = a post-read return bake.
    if (0xB8 in tail[:-1]) or (0xB0 in tail[:-1]): return False
    # (4) the OFFSET access_ok: `cmp ecx,512 ; jae disk_reject` (81 F9 00 02 00 00, then 0F 8x) guarding the movzx,
    # present in the arm and BEFORE the movzx-return. WITHOUT it a CPL3-controlled ECX makes `movzx eax,[ecx+diskbuf]`
    # a one-byte ARBITRARY KERNEL READ past the 512B supervisor diskbuf (a confused-deputy info-leak Codex caught).
    # M-noecxcheck drops the cmp -> REJECT (the white-box primary discriminator, like M-noboundscheck for the LBA).
    cmp_ecx = bytes([0x81,0xF9])+le32(512)               # cmp ecx, 512
    if cmp_ecx not in arm: return False                  # ECX-bound cmp absent -> M-noecxcheck
    i_ecx = arm.find(cmp_ecx)
    if not (i_ecx < arm.find(movzx_ret)): return False   # the bound check must come BEFORE the leaking movzx
    # the cmp must be followed (immediately) by a `jae` (0F 83 rel32) to the reject path -- a bare cmp with no branch
    # is dead. The two-byte 0F 83 jae prefix sits right after the 6-byte cmp.
    jae_after = arm[i_ecx+len(cmp_ecx):i_ecx+len(cmp_ecx)+2]
    if jae_after != bytes([0x0F,0x83]): return False     # cmp ecx,512 not followed by jae -> ECX bound not enforced
    return True



# ============================ GRADE ============================
def grade_lethe(stream, kend_elf, seed=LETHE_SEED):
    """lethe FULL grade -- ALIAS-REMAP + TARGETED TLB INVALIDATION. ONE prober (K=1) warms V->F, the kernel remaps V->F'
       + invlpg [V], the prober writes y to V and reads back A,V,B. GREEN requires A==x (F untouched -- the remap moved V
       to a NEW frame, the write y did NOT corrupt F), V==y (the post-remap write reached F' via a fresh walk), B==y
       (the second alias of F' sees y). RED on: M-noinvlpg (stale V->F: y lands in F -> A==y corruption, B==OLD_FP);
       M-noremap (V stays ->F: y lands in F -> A==y, B==OLD_FP); M-sameframe (F'==F: y lands in F -> A==y); M-noinstall
       (the store #PFs terminally -> no dump). Returns errs."""
    errs=[]
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the prober dumped -- e.g. M-noinstall: the alias store #PFs terminally) -> RED']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==4 and w['cs']==UCODE3 and (w['cs']&3)==3]
    bodies=[struct.unpack('<I',w['body'])[0] for w in wfs]
    x,y,_=lethe_expect(seed); exp=[x,y,y]; names=['A','V','B']
    if len(bodies)!=3:
        errs.append(f'emitted {len(bodies)} words != 3 (got {[hex(b) for b in bodies]}; expected A=0x{x:08x} V=0x{y:08x} B=0x{y:08x})')
    else:
        for i,(got,want) in enumerate(zip(bodies,exp)):
            if got!=want:
                why={
                    'A':'A must == x (F UNCHANGED). A==y means the post-remap write hit F (a STALE TLB entry V->F): M-noinvlpg / M-noremap / M-sameframe corrupted the witness frame.',
                    'V':'V must == y (the post-remap write reached F\' via a fresh walk after invlpg).',
                    'B':f'B must == y (the second alias of F\' sees the new value). B==0x{OLD_FP:08x}(OLD_FP) means the write never reached F\' (no remap / stale entry).',
                }[names[i]]
                errs.append(f'{names[i]}=0x{got:08x} != 0x{want:08x} -- {why}')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (lethe is a single-program probe)')
    return errs


def grade_disk(stream, kend_elf, chase_bytes, khops=DISK_KHOPS, start_idx=DISK_START_IDX):
    """link37 grade -- the kernel's FIRST BLOCK DEVICE. The prober pointer-chases khops sectors via SYS_DISK_READ,
       each next-LBA DATA-DEPENDENT on the prior byte, and SYS_WRITEs each byte. GREEN requires the emitted chain
       == disk_chase_expect(chase_bytes) -- a genuine ADDRESSED random-access read in the late-bound chase order is
       the ONLY way to produce it. RED on: the FROZEN lethe kernel (no SYS_DISK_READ -> eax=5 falls to SYS_EXIT,
       the prober's first int 0x30 EXITs with bl=0 -> no chain emitted); M-fixedlba (every hop reads the same start
       sector -> b1=b2=b3 -> chain collapses); M-noread (diskbuf stays 0 -> emits zeros); M-noboundscheck is a
       SANDBOX break (output may still be GREEN -> the white-box assert catches it, not this output grade)."""
    errs=[]
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the prober dumped) -> RED']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==1 and w['cs']==UCODE3 and (w['cs']&3)==3]
    emitted=[w['body'][0] for w in wfs]
    expected=disk_chase_expect(chase_bytes, khops, start_idx)
    if emitted!=expected:
        errs.append(f'emitted chain {[hex(b) for b in emitted]} != expected {[hex(b) for b in expected]} '
                    f'(chase from start_idx={start_idx} over recorded disk bytes)')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (link37 is a single-program probe)')
    return errs


def _parse_chase_arg(s):
    # "7:12,12:40,40:3,3:99,..." -> {7:0x.., ...} (decimal idx:byte; byte may be 0x-prefixed)
    d={}
    for part in s.split(','):
        k,v=part.split(':'); d[int(k,0)]=int(v,0)&0xFF
    return d


# ============================ platter HOSTILE-LBA leg: the sandbox boundary ============================
# DEFAULT hostile targets: LBA 0 (the MBR -- partition table + boot code, the classic exfiltration target) and a
# few sectors INSIDE the FAT partition (which begins at 1 MiB = LBA 2048 on the GRUB substrate). All are OUTSIDE
# the reserved window [DISK_RESV_LO, DISK_RESV_HI), so the kernel's access_ok MUST reject each -> return sentinel 0.
HOSTILE_LBAS = [0, 1, 2048, DISK_RESV_LO-1, DISK_RESV_HI]   # MBR, MBR+1, FAT start, just-below-window, just-above-window

def module_hostile_prober(lbas=None):
    # A hostile prober (proc0, K=1): for each forbidden LBA it issues SYS_DISK_READ (eax=5, EBX=LBA, ECX=0) and
    # SYS_WRITEs the returned byte. A SANDBOXED kernel rejects every out-of-window LBA and returns 0 (sentinel), so
    # the emitted chain is all-zeros. M-noboundscheck (the access_ok dropped) would actually READ LBA 0 etc. and
    # hand back the MBR byte -> a NONZERO leak -> grade_disk_hostile RED. (This is the OUTPUT witness of the leak
    # that the benign grade_disk is blind to; assert_platter is the white-box witness of the same defect.)
    lbas = HOSTILE_LBAS if lbas is None else lbas
    m=Asm()
    for lba in lbas:
        m.raw(0xBB); m.blob(le32(lba))            # mov ebx, <forbidden LBA>
        m.raw(0x31,0xC9)                          # xor ecx,ecx  (byte-offset 0 -> sector's first byte)
        m.raw(0xB8); m.blob(le32(SYS_DISK_READ))  # mov eax,5 (SYS_DISK_READ)
        m.raw(0xCD,0x30)                          # int 0x30 -> kernel: out-of-window -> sentinel 0 (genuine)
        m.raw(0x25); m.blob(le32(0xFF))           # and eax,0xFF
        m.raw(0x50)                               # push eax  (the returned byte, on our stack)
        m.raw(0x8D,0x0C,0x24)                     # lea ecx,[esp]
        m.raw(0xBA,0x01,0x00,0x00,0x00)           # mov edx,1
        m.raw(0xB8,0x02,0x00,0x00,0x00)           # mov eax,2 (SYS_WRITE) -- emit the returned byte
        m.raw(0xCD,0x30)
        m.raw(0x83,0xC4,0x04)                     # add esp,4
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


def grade_disk_hostile(stream, kend_elf, nlbas=None):
    """platter HOSTILE-LBA grade -- the access_ok / sandbox boundary. A prober requests forbidden out-of-window LBAs
       (LBA 0 / partition sectors); a SANDBOXED kernel MUST reject each and return sentinel 0. GREEN requires every
       emitted byte == 0 (rejected). RED on: ANY nonzero byte (the kernel leaked a real disk sector -- M-noboundscheck);
       wrong emitted-count (the prober faulted / a hop wasn't rejected cleanly). This is the OUTPUT-side witness of the
       leak that the benign grade_disk cannot see; pair it with assert_platter (the white-box witness)."""
    nlbas = len(HOSTILE_LBAS) if nlbas is None else nlbas
    errs=[]
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the hostile prober dumped) -> RED']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==1 and w['cs']==UCODE3 and (w['cs']&3)==3]
    emitted=[w['body'][0] for w in wfs]
    if len(emitted)!=nlbas:
        errs.append(f'emitted {len(emitted)} hostile bytes != {nlbas} (a forbidden read faulted or was not handled) '
                    f'-- got {[hex(b) for b in emitted]}')
    leaks=[(i,b) for i,b in enumerate(emitted) if b!=0]
    if leaks:
        errs.append(f'LEAK: hostile read(s) returned NONZERO {[ (i,hex(b)) for i,b in leaks ]} -- the kernel handed back '
                    f'a real out-of-window disk byte (e.g. the MBR). The access_ok is broken (M-noboundscheck): a CPL3 '
                    f'module escaped the reserved window [{DISK_RESV_LO},{DISK_RESV_HI}). A sandboxed kernel must return 0.')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (platter is a single-program probe)')
    return errs


# ============================ platter HOSTILE-ECX leg: the OFFSET sandbox boundary ============================
# The SECOND untrusted scalar is the byte-OFFSET ECX. The genuine kernel returns `movzx eax,[ecx+diskbuf]` only after
# `cmp ecx,512 ; jae reject`. WITHOUT that check (M-noecxcheck) a CPL3-controlled ECX makes the read a one-byte ARBITRARY
# KERNEL READ past the 512B supervisor diskbuf -- the confused-deputy info-leak Codex caught. This leg picks an ECX_PROBE
# such that (ECX_PROBE + diskbuf) mod 2^32 lands on a KNOWN-NONZERO, mapped kernel byte, issues a SYS_DISK_READ with a
# VALID in-window LBA (so the LBA access_ok passes) and that hostile ECX, and SYS_WRITEs the returned byte:
#   GENUINE  -> ECX_PROBE >= 512 -> jae reject -> sentinel 0 (GREEN).
#   M-noecxcheck -> no cmp -> movzx reads [diskbuf+ECX_PROBE] -> LEAKS the nonzero kernel byte (RED).
def disk_hostile_ecx_probe():
    """Compute (ECX_PROBE, leaked_byte): the SMALLEST byte-offset >= 512 (so the genuine `jae 512` rejects it) such that
       vaddr (diskbuf+ECX_PROBE) is within the loaded, identity-mapped kernel image and holds a NONZERO byte. The classic
       choice is ECX_PROBE=512 -> the first byte just PAST the 512B diskbuf (the off-by-buffer overread). Returned values
       are derived from build_elf() so they track the real image -- no baked constants."""
    img,kend,labels=build_elf()
    diskbuf=labels['diskbuf']
    for off in range(512, 0x10000):
        v=(diskbuf+off)&0xFFFFFFFF
        if LOAD<=v<kend:                                 # within the loaded image -> file-backed, identity-mapped, present
            b=img[v-LOAD+4096]                           # phys[v] == file byte at (v-LOAD+4096) (the phdr maps off 4096->LOAD)
            if b!=0:
                assert off>=512, 'ECX_PROBE must be >= 512 so the genuine jae rejects it'
                return off,b
    raise SystemExit('no nonzero mapped byte found past diskbuf for the hostile-ECX probe')

def module_hostile_ecx_prober(ecx_probe=None, lba_idx=DISK_START_IDX):
    # A hostile-ECX prober (proc0, K=1): ONE SYS_DISK_READ with a VALID in-window LBA (DISK_RESV_LO+lba_idx -- so the LBA
    # access_ok passes and the ATA read succeeds) but a HOSTILE byte-offset ECX_PROBE (>= 512, mapping to a nonzero kernel
    # byte). A sandboxed kernel rejects ECX>=512 and returns sentinel 0; M-noecxcheck leaks [diskbuf+ECX_PROBE] (nonzero).
    if ecx_probe is None: ecx_probe,_=disk_hostile_ecx_probe()
    m=Asm()
    m.raw(0xBB); m.blob(le32(DISK_RESV_LO+lba_idx))   # mov ebx, valid in-window LBA (the LBA bound check passes)
    m.raw(0xB9); m.blob(le32(ecx_probe))              # mov ecx, ECX_PROBE  (the HOSTILE offset, >= 512)
    m.raw(0xB8); m.blob(le32(SYS_DISK_READ))          # mov eax,5 (SYS_DISK_READ)
    m.raw(0xCD,0x30)                                  # int 0x30 -> GENUINE: ecx>=512 -> sentinel 0 ; M-noecxcheck: LEAK
    m.raw(0x25); m.blob(le32(0xFF))                   # and eax,0xFF
    m.raw(0x50)                                       # push eax (the returned byte, on our stack)
    m.raw(0x8D,0x0C,0x24)                             # lea ecx,[esp]
    m.raw(0xBA,0x01,0x00,0x00,0x00)                   # mov edx,1
    m.raw(0xB8,0x02,0x00,0x00,0x00)                   # mov eax,2 (SYS_WRITE) -- emit the returned byte
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)                             # add esp,4
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def grade_disk_hostile_ecx(stream, kend_elf):
    """platter HOSTILE-ECX grade -- the OFFSET access_ok / sandbox boundary. A prober issues SYS_DISK_READ with a VALID
       in-window LBA but a hostile ECX>=512 mapping to a KNOWN-NONZERO kernel byte. A sandboxed kernel MUST reject the
       out-of-range offset and return sentinel 0. GREEN requires the single emitted byte == 0. RED on: a NONZERO byte
       (the kernel leaked a kernel byte past diskbuf -- M-noecxcheck, the confused-deputy info-leak); wrong emitted-count
       (the prober faulted). This is the OUTPUT-side witness of the leak; pair it with assert_platter (the white-box
       witness)."""
    errs=[]
    ecx_probe,leak_byte=disk_hostile_ecx_probe()
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the hostile-ECX prober dumped) -> RED']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==1 and w['cs']==UCODE3 and (w['cs']&3)==3]
    emitted=[w['body'][0] for w in wfs]
    if len(emitted)!=1:
        errs.append(f'emitted {len(emitted)} hostile-ECX bytes != 1 (the prober faulted or the read was not handled) '
                    f'-- got {[hex(b) for b in emitted]}')
    elif emitted[0]!=0:
        errs.append(f'LEAK: hostile ECX={ecx_probe} (>= 512) returned NONZERO 0x{emitted[0]:02x} (expected the kernel byte '
                    f'0x{leak_byte:02x} at diskbuf+{ecx_probe}) -- the kernel handed back a byte PAST the 512B supervisor '
                    f'diskbuf. The OFFSET access_ok is broken (M-noecxcheck): `movzx eax,[ecx+diskbuf]` with a CPL3 ECX is '
                    f'an arbitrary one-byte kernel READ. A sandboxed kernel must `cmp ecx,512 ; jae reject` -> return 0.')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (platter is a single-program probe)')
    return errs


# ============================ platter HOSTILE-DF leg: the DIRECTION-FLAG (cld) sandbox boundary ============================
# The THIRD output-invisible scalar of state a CPL3 module controls before int 0x30 is the DIRECTION FLAG (DF, eflags.bit10).
# The genuine kernel's do_disk_read does `cld` (DF=0) right before `rep insw`, so the transfer ALWAYS walks FORWARD from
# diskbuf -- regardless of the module's DF. WITHOUT that cld (M-nocld) the kernel inherits the module's DF: a hostile module
# that does `std` (DF=1) before int 0x30 makes `rep insw` walk BACKWARD from diskbuf, so only the FIRST word lands at
# [diskbuf]; the subsequent 255 words land at [diskbuf-2], [diskbuf-4], ... -- CORRUPTING kernel memory BELOW diskbuf, and
# leaving the REST of diskbuf (offsets 2..511) UNWRITTEN (it stays zero -- the kernel zeroes diskbuf at build time and the
# backward walk never touches it). So the OBSERVABLE discriminator is NOT offset 0 (which gets the sector's word 0 EITHER
# direction -- empirically confirmed identical), but any offset >= 2: forward fills it with the real sector byte, backward
# leaves it ZERO. This defect is OUTPUT-INVISIBLE on the benign gate (the prober there has DF=0 ambiently AND reads only
# offset 0) -- the same forge class as the dropped ECX/LBA bounds -- so it needs a dedicated leg: a prober that SETS DF=1
# (std) then issues a benign in-window read AT A NONZERO OFFSET and checks the returned byte == the KNOWN disk byte there.
#   GENUINE  -> the kernel cld's -> rep insw walks forward -> diskbuf[DF_PROBE_OFF] == the sector's real byte -> correct (GREEN even with std).
#   M-nocld  -> DF=1 reaches rep insw -> backward walk -> diskbuf[DF_PROBE_OFF] is ZERO (never written) -> != the known byte -> RED.
# The harness dd's a KNOWN-NONZERO sentinel (DF_PROBE_BYTE) at (start sector, DF_PROBE_OFF) so the forward read is well-
# defined and the backward read (zero) is observably wrong. DF_PROBE_OFF is in-bounds (< 512) so the ECX access_ok passes.
HOSTILE_DF_LBA_IDX = DISK_START_IDX   # a VALID in-window index (the start sector) the prober reads
DF_PROBE_OFF  = 2                     # the byte-offset to read (>= 2, in-bounds): forward=real byte, backward=zero (the discriminator)
DF_PROBE_BYTE = 0xC7                  # the KNOWN-NONZERO sentinel the harness dd's at (start sector, DF_PROBE_OFF)
assert 2 <= DF_PROBE_OFF < 512 and DF_PROBE_OFF % 2 == 0, 'DF_PROBE_OFF must be an in-bounds, word-aligned, >=2 offset (forward!=backward)'
assert 0 < DF_PROBE_BYTE < 256, 'DF_PROBE_BYTE must be a nonzero byte (so the forward read is distinguishable from the backward zero)'

def module_hostile_df_prober(lba_idx=HOSTILE_DF_LBA_IDX, off=DF_PROBE_OFF):
    # A hostile-DF prober (proc0, K=1): set DF=1 via `std`, then ONE SYS_DISK_READ with a VALID in-window LBA
    # (DISK_RESV_LO+lba_idx) and ECX=DF_PROBE_OFF (a nonzero in-bounds offset), then SYS_WRITE the returned byte. The
    # genuine kernel cld's before rep insw so the transfer is FORWARD and diskbuf[off] holds the sector's real byte
    # (correct DESPITE the module's std). M-nocld inherits DF=1 -> rep insw runs BACKWARD -> only diskbuf[0..1] is
    # written, diskbuf[off>=2] stays ZERO -> the returned byte is 0 != the known sentinel.
    m=Asm()
    m.raw(0xFD)                                       # std  (DF=1 -- the hostile direction flag)
    m.raw(0xBB); m.blob(le32(DISK_RESV_LO+lba_idx))   # mov ebx, valid in-window LBA (the LBA bound check passes)
    m.raw(0xB9); m.blob(le32(off))                    # mov ecx, DF_PROBE_OFF  (nonzero in-bounds byte-offset; ECX bound passes)
    m.raw(0xB8); m.blob(le32(SYS_DISK_READ))          # mov eax,5 (SYS_DISK_READ)
    m.raw(0xCD,0x30)                                  # int 0x30 -> GENUINE: kernel cld's -> forward -> real byte ; M-nocld: backward -> 0
    m.raw(0xFC)                                       # cld  (restore DF=0 for the prober's OWN forthcoming SYS_WRITE relay)
    m.raw(0x25); m.blob(le32(0xFF))                   # and eax,0xFF
    m.raw(0x50)                                       # push eax (the returned byte, on our stack)
    m.raw(0x8D,0x0C,0x24)                             # lea ecx,[esp]
    m.raw(0xBA,0x01,0x00,0x00,0x00)                   # mov edx,1
    m.raw(0xB8,0x02,0x00,0x00,0x00)                   # mov eax,2 (SYS_WRITE) -- emit the returned byte
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)                             # add esp,4
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def grade_disk_hostile_df(stream, kend_elf, want=DF_PROBE_BYTE, off=DF_PROBE_OFF):
    """platter HOSTILE-DF grade -- the DIRECTION-FLAG (cld) sandbox boundary. A prober sets DF=1 (std) then issues a
       BENIGN in-window SYS_DISK_READ (valid LBA) at a NONZERO offset (DF_PROBE_OFF) the harness seeded with a known
       sentinel (DF_PROBE_BYTE). The genuine kernel cld's before rep insw, so the transfer is FORWARD regardless of the
       module's DF and diskbuf[off] holds the real sentinel. GREEN requires the single emitted byte == that known sentinel.
       RED on: a byte != the sentinel (M-nocld: DF=1 reached rep insw -> backward walk -> diskbuf[off>=2] is ZERO, never
       written -- and kernel memory below diskbuf was corrupted); wrong emitted-count (the prober faulted). This is the
       OUTPUT-side witness of the dropped cld; pair it with assert_platter (the white-box witness, check (2b))."""
    errs=[]
    want &= 0xFF
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the hostile-DF prober dumped) -> RED']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==1 and w['cs']==UCODE3 and (w['cs']&3)==3]
    emitted=[w['body'][0] for w in wfs]
    if len(emitted)!=1:
        errs.append(f'emitted {len(emitted)} hostile-DF bytes != 1 (the prober faulted or the read was not handled) '
                    f'-- got {[hex(b) for b in emitted]}')
    elif emitted[0]!=want:
        errs.append(f'WRONG-DIRECTION READ: hostile-DF (std before int 0x30) at offset {off} returned 0x{emitted[0]:02x} '
                    f'!= the known disk sentinel 0x{want:02x} at (LBA {DISK_RESV_LO+HOSTILE_DF_LBA_IDX}, offset {off}) -- '
                    f'the kernel did NOT `cld` before `rep insw` (M-nocld), so DF=1 made the transfer walk BACKWARD from '
                    f'diskbuf: only diskbuf[0..1] was written, diskbuf[offset {off}] stayed ZERO (and kernel memory below '
                    f'diskbuf was corrupted). A sandboxed kernel must `cld` so the read is FORWARD regardless of the '
                    f'module\'s direction flag.')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (platter is a single-program probe)')
    return errs


# ============================ link38 FORCING: the two-boot durability probers ============================
# THE MAKE-OR-BREAK is a TWO-BOOT chain on ONE persistent disk medium:
#   BOOT-1 (writer prober): SYS_READ a late-bound COM1 byte X (the kernel reads it -- a CPL3 module cannot do PIO/UART),
#     SYS_DISK_WRITE X to (DUR_WLBA, DUR_OFF), SYS_EXIT. The kernel writes X to the medium + CACHE FLUSH.
#   <<< the machine REBOOTS -- a FRESH kernel process, RAM WIPED; the SAME disk.img persists (the medium) >>>
#   BOOT-2 (reader prober): SYS_DISK_READ (DUR_WLBA, DUR_OFF) -> the byte in eax, SYS_WRITE it, SYS_EXIT.
#   grade_durability: BOOT-2 emits X == the author-unknown COM1 byte BOOT-1 was fed. X is NEVER in either prober/kernel
#   image and NOT in BOOT-2's RAM (wiped on reboot) -> it can ONLY have come from DISK. A RAM-stash forge (write to RAM
#   not disk) grades RED on BOOT-2 (the stash is gone).
#   THE PRIMARY DURABILITY DIFFERENTIAL is M-nowrite: the SAME genuine durable kernel with ONLY the ATA write+flush
#     sequence (d) dropped from the do_disk_write arm -- everything else (the access_ok bounds, the dispatch, the read
#     arm, the whole ELF) byte-identical. The benign two-boot then reads back stale 0 -> RED. Because M-nowrite isolates
#     EXACTLY the write+flush (one mutated arm, nothing else moves), it cleanly attributes the durable byte to the ATA
#     write to the medium -- it is the make-or-break the grade leans on.
#   THE FROZEN-PLATTER DIFFERENTIAL (frozen platter kernel: no SYS_DISK_WRITE arm; eax=6 unknown -> falls to SYS_EXIT ->
#     writes NOTHING -> BOOT-2 reads stale 0 -> RED) is kept as a SECONDARY corroborator only: it is FRAMING-CONFOUNDED.
#     The frozen platter is a DIFFERENT ELF -- it differs from durable in the entire do_disk_write arm's presence, not
#     just the medium write, so its RED conflates "no write reached the disk" with "this is an older kernel that lacks
#     the whole capability". It shows durability is a genuinely NEW observable (additive on platter), but M-nowrite is the
#     clean primary because it severs only the write while holding the kernel otherwise fixed.
# The kernel is the SAME ELF both boots (it carries BOTH the read and write arms); only the loaded prober module differs.

def module_durable_writer(seed=None, wlba=DUR_WLBA, off=DUR_OFF):
    # BOOT-1 (proc0, K=1): read a late-bound seed byte X over COM1 (SYS_READ), then SYS_DISK_WRITE X to (wlba, off).
    # With seed=None the byte is LATE-BOUND (the kernel reads it off COM1 -- a CPL3 module cannot); with seed given it
    # BAKES the seed (STEP-0 smoke only). The genuine forcing run uses seed=None: X is author-unknown, fed by the COM1 feeder.
    m=Asm()
    if seed is None:
        m.raw(0xB8,0x00,0x00,0x00,0x00)           # mov eax,0  (SYS_READ)
        m.raw(0xCD,0x30)                          # int 0x30 -> seed byte X in eax (the kernel read it off COM1)
        m.raw(0x25); m.blob(le32(0xFF))           # and eax,0xFF -> eax = X
    else:
        m.raw(0xB8); m.blob(le32(seed & 0xFF))    # mov eax, X (baked -- STEP-0 only)
    m.raw(0x89,0xC2)                              # mov edx,eax   (DL = the byte X to write)
    m.raw(0xBB); m.blob(le32(wlba))               # mov ebx, DUR_WLBA  (the WRITE LBA, in the write window)
    m.raw(0xB9); m.blob(le32(off))                # mov ecx, DUR_OFF   (the in-sector byte-offset, 0..511)
    m.raw(0xB8); m.blob(le32(SYS_DISK_WRITE))     # mov eax,6 (SYS_DISK_WRITE)
    m.raw(0xCD,0x30)                              # int 0x30 -> kernel: access_ok, build sector, ATA WRITE + CACHE FLUSH
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def module_durable_reader(wlba=DUR_WLBA, off=DUR_OFF):
    # BOOT-2 (proc0, K=1, a FRESH boot -- RAM wiped): SYS_DISK_READ (wlba, off) -> the durable byte, SYS_WRITE it, SYS_EXIT.
    # No knowledge of X is baked in: the byte comes back from the medium the writer persisted it to. (Same shape as the
    # platter disk read, but a single fixed in-window read of the WRITE sector.)
    m=Asm()
    m.raw(0xBB); m.blob(le32(wlba))               # mov ebx, DUR_WLBA  (the LBA the writer wrote to)
    m.raw(0xB9); m.blob(le32(off))                # mov ecx, DUR_OFF   (the byte-offset)
    m.raw(0xB8); m.blob(le32(SYS_DISK_READ))      # mov eax,5 (SYS_DISK_READ)
    m.raw(0xCD,0x30)                              # int 0x30 -> kernel ATA read; the durable byte in eax (0..255)
    m.raw(0x25); m.blob(le32(0xFF))               # and eax,0xFF
    m.raw(0x50)                                   # push eax (the byte, on our in-region stack)
    m.raw(0x8D,0x0C,0x24)                         # lea ecx,[esp]
    m.raw(0xBA,0x01,0x00,0x00,0x00)               # mov edx,1  (1 byte)
    m.raw(0xB8,0x02,0x00,0x00,0x00)               # mov eax,2 (SYS_WRITE) -- emit the durable byte
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)                         # add esp,4
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

# ---- the hostile-WRITER prober: the WRITE access_ok / sandbox boundary (the M-nowboundscheck output witness) ----
# A WRITE-ANYWHERE primitive is WORSE than the read leak: a hostile module could overwrite the MBR (brick the boot),
# scribble a read-window sector (corrupt the block device's data), or smash GRUB/the FAT. The genuine kernel REJECTS
# any out-of-write-window LBA (sentinel, NO write). M-nowboundscheck drops the check -> the hostile write LANDS.
# DEFAULT hostile target: LBA 0 (the MBR). The harness pre-records the forbidden sector's bytes, runs the hostile
# writer, and checks the sector was NOT modified (genuine) vs WAS modified (M-nowboundscheck escape).
HOSTILE_WRITE_LBA  = 0          # the MBR -- the classic write-anywhere target (out of the write window -> must be rejected)
HOSTILE_WRITE_OFF  = 4          # an in-sector offset to scribble (avoid the very first MBR bytes for clarity; any offset works)
HOSTILE_WRITE_BYTE = 0xE7       # the sentinel byte the hostile writer tries to write (distinctive, nonzero)
assert not (DISK_WRESV_LO <= HOSTILE_WRITE_LBA < DISK_WRESV_HI), 'the hostile LBA must be OUTSIDE the write window'

def module_hostile_writer(lba=HOSTILE_WRITE_LBA, off=HOSTILE_WRITE_OFF, byte=HOSTILE_WRITE_BYTE):
    # A hostile WRITER (proc0, K=1): ONE SYS_DISK_WRITE to a FORBIDDEN LBA (out of the write window) with a sentinel
    # byte, then SYS_EXIT. A sandboxed kernel rejects the out-of-window LBA and writes NOTHING; M-nowboundscheck lets
    # the write land -> the forbidden sector is modified (a write-anywhere escape). The harness checks the sector bytes.
    m=Asm()
    m.raw(0xBA); m.blob(le32(byte & 0xFF))        # mov edx, byte  (DL = the sentinel byte to scribble)
    m.raw(0xBB); m.blob(le32(lba))                # mov ebx, <forbidden LBA>  (out of the write window)
    m.raw(0xB9); m.blob(le32(off))                # mov ecx, off   (in-sector offset)
    m.raw(0xB8); m.blob(le32(SYS_DISK_WRITE))     # mov eax,6 (SYS_DISK_WRITE)
    m.raw(0xCD,0x30)                              # int 0x30 -> GENUINE: out-of-window -> sentinel, NO write ; M-nowb: LANDS
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

# ---- the hostile-ECX WRITER prober: the OFFSET access_ok boundary (the M-nowecxcheck witness) ----
# The second untrusted scalar is the byte-OFFSET ECX. The genuine kernel does `mov [ecx+diskbuf],DL` only after
# `cmp ecx,512 ; jae reject`. WITHOUT that (M-nowecxcheck) a CPL3-controlled ECX makes the store an arbitrary one-byte
# KERNEL WRITE past the 512B supervisor diskbuf -- a confused-deputy memory-corruption primitive. This prober issues a
# VALID in-window WRITE LBA (so the LBA access_ok passes) but a hostile ECX>=512. The OUTPUT witness is indirect (the
# corruption is in kernel RAM), so the PRIMARY discriminator is assert_durability's white-box pin of the `cmp ecx,512`;
# this prober is wired so the M-nowecxcheck run can be observed to NOT fault-cleanly / corrupt (defense in depth).
def module_hostile_ecx_writer(lba=DUR_WLBA, ecx_probe=512, byte=0xC3):
    m=Asm()
    m.raw(0xBA); m.blob(le32(byte & 0xFF))        # mov edx, byte
    m.raw(0xBB); m.blob(le32(lba))                # mov ebx, valid in-window WRITE LBA (the LBA bound passes)
    m.raw(0xB9); m.blob(le32(ecx_probe))          # mov ecx, ECX_PROBE (>= 512 -- the HOSTILE offset)
    m.raw(0xB8); m.blob(le32(SYS_DISK_WRITE))     # mov eax,6 (SYS_DISK_WRITE)
    m.raw(0xCD,0x30)                              # int 0x30 -> GENUINE: ecx>=512 -> sentinel, NO write ; M-nowecx: arb kernel write
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

# ---- the hostile-DF WRITER prober: the DIRECTION-FLAG (cld) boundary on the WRITE arm (the M-nowcld witness) ----
# The THIRD output-invisible scalar a CPL3 module controls before int 0x30 is the DIRECTION FLAG (DF, eflags.bit10). The
# genuine do_disk_write cld's TWICE -- before `rep stosd` (zero diskbuf) and before `rep outsw` (send the sector) -- so
# both string ops walk FORWARD regardless of the module's DF. WITHOUT the clds (M-nowcld) a hostile module that does
# `std` (DF=1) before int 0x30 makes the kernel inherit DF=1: `rep stosd` walks BACKWARD (zeroing 508 bytes of the page
# tables `pt` immediately below diskbuf -- a kernel-memory corruption -- and leaving diskbuf[4..511] uninitialised), then
# `rep outsw` walks BACKWARD, sending diskbuf[0..1] then page-table bytes below diskbuf out the data port. So the SECTOR
# WRITTEN TO DISK is wrong: a sentinel the module wrote at an offset >= 2 NEVER lands at that disk offset (forward it
# would). The OBSERVABLE is NOT offset 0 (vacuous -- the byte store fixes diskbuf[0], and the backward outsw's first word
# still carries diskbuf[0..1]); it is any offset >= 2: forward the kernel writes the module's sentinel there, backward it
# writes a zero / page-table byte. This is OUTPUT-INVISIBLE on the benign two-boot (the writer's ambient DF=0 AND it
# writes at DUR_OFF=0). The leg: a writer that SETS DF=1 (std) then SYS_DISK_WRITEs a known sentinel at DF_W_OFF (>= 2,
# in-bounds so the ECX access_ok passes) to a VALID in-window LBA, then the harness inspects the disk sector at that
# offset directly (single-boot, like the hostile-ECX leg -- no dependence on a second boot succeeding through the
# corrupted page tables). GENUINE: disk[off]==sentinel (forward, correct DESPITE the module's std) -> GREEN. M-nowcld:
# disk[off]!=sentinel (backward -> 0/pt byte) -> RED.  (Same output-invisible-forge class as the WRITE-LBA/ECX bounds;
# the white-box assert_durability cld-adjacency pins (FIX B) are the primary discriminator, this is the output witness.)
DF_W_LBA  = DUR_WLBA   # a VALID in-window WRITE LBA the hostile-DF writer targets (the LBA access_ok passes)
DF_W_OFF  = 16         # the in-sector offset to write (>= 2, word-aligned, in-bounds): forward=sentinel, backward=0/pt-byte
DF_W_BYTE = 0xA5       # the KNOWN-NONZERO sentinel the writer tries to persist at (DF_W_LBA, DF_W_OFF)
assert DISK_WRESV_LO <= DF_W_LBA < DISK_WRESV_HI, 'the hostile-DF write LBA must be IN the write window (the LBA bound passes)'
assert 2 <= DF_W_OFF < 512 and DF_W_OFF % 2 == 0, 'DF_W_OFF must be in-bounds, word-aligned, >= 2 (forward != backward)'
assert 0 < DF_W_BYTE < 256, 'DF_W_BYTE must be a nonzero byte'

def module_hostile_df_writer(lba=DF_W_LBA, off=DF_W_OFF, byte=DF_W_BYTE):
    # A hostile-DF WRITER (proc0, K=1): set DF=1 via `std`, then ONE SYS_DISK_WRITE of a known sentinel byte at a VALID
    # in-window LBA and an in-bounds offset (>= 2), then SYS_EXIT. The genuine kernel cld's before BOTH rep stosd and rep
    # outsw, so the sector is built + sent FORWARD and the sentinel lands at (lba, off) on the medium DESPITE the module's
    # std. M-nowcld inherits DF=1 -> the backward rep outsw sends diskbuf[0..1] then page-table bytes -> the sentinel
    # never reaches disk offset `off` (it reads back as 0 / a pt byte). The harness inspects the disk sector directly.
    m=Asm()
    m.raw(0xFD)                                   # std  (DF=1 -- the hostile direction flag)
    m.raw(0xBA); m.blob(le32(byte & 0xFF))        # mov edx, byte  (DL = the sentinel to persist)
    m.raw(0xBB); m.blob(le32(lba))                # mov ebx, valid in-window WRITE LBA (the LBA bound passes)
    m.raw(0xB9); m.blob(le32(off))                # mov ecx, DF_W_OFF  (in-bounds offset >= 2; the ECX bound passes)
    m.raw(0xB8); m.blob(le32(SYS_DISK_WRITE))     # mov eax,6 (SYS_DISK_WRITE)
    m.raw(0xCD,0x30)                              # int 0x30 -> GENUINE: cld -> forward -> sentinel at (lba,off) ; M-nowcld: backward -> wrong
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


# ============================ link38 GRADE ============================
def grade_durability(stream, kend_elf, want_byte):
    """link38 DURABILITY grade -- BOOT-2. The reader prober SYS_DISK_READs (DUR_WLBA, DUR_OFF) the durable byte and
       SYS_WRITEs it. GREEN requires the single emitted byte == want_byte (the author-unknown X the writer was fed in
       BOOT-1). RED on:
         - M-nowrite -> stale 0  (THE PRIMARY DURABILITY DIFFERENTIAL: the SAME genuine kernel with ONLY the ATA
           write+flush severed -- everything else byte-identical, so the RED attributes the durable byte cleanly to the
           write to the medium);
         - a RAM-stash forge -> the stash is gone after the reboot -> stale 0;
         - the FROZEN platter kernel wrote nothing -> stale 0 (a SECONDARY corroborator: framing-confounded -- it is a
           different ELF lacking the whole do_disk_write arm, so its RED conflates "no medium write" with "older kernel
           without the capability"; it confirms durability is a new observable but M-nowrite is the make-or-break);
         - wrong emitted-count (the prober faulted).
       want_byte is the SAME byte the BOOT-1 feeder supplied -- the harness threads it through."""
    errs=[]
    want = want_byte & 0xFF
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the reader prober dumped) -> RED']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==1 and w['cs']==UCODE3 and (w['cs']&3)==3]
    emitted=[w['body'][0] for w in wfs]
    if len(emitted)!=1:
        errs.append(f'BOOT-2 emitted {len(emitted)} bytes != 1 (the reader prober faulted or the read was not handled) '
                    f'-- got {[hex(b) for b in emitted]}')
    elif emitted[0]!=want:
        errs.append(f'NOT DURABLE: BOOT-2 reader read back 0x{emitted[0]:02x} != the author-unknown byte 0x{want:02x} '
                    f'BOOT-1 was fed (and wrote). A byte of 0x00 means the write never reached the medium: the PRIMARY '
                    f'differential M-nowrite dropped the ATA write+flush (the genuine kernel otherwise unchanged); or a '
                    f'RAM-stash forge lost the byte when the machine rebooted + wiped RAM; or (the SECONDARY, framing-'
                    f'confounded case) the FROZEN platter kernel has no SYS_DISK_WRITE arm at all -> eax=6 fell to '
                    f'SYS_EXIT, NOTHING was written. Durability requires the byte to SURVIVE on DISK across a fresh boot.')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (link38 is a single-program probe)')
    return errs


# ============================ link38 WHITE-BOX assert ============================
def assert_durability(kelf):
    """White-box structural co-pin for link38's SYS_DISK_WRITE durability arm (the two-boot output grade is the PRIMARY
       binding; this co-pin is REQUIRED because M-nowboundscheck and M-nowecxcheck are OUTPUT-INVISIBLE on the benign
       two-boot -- a sandbox break that still persists the benign byte correctly yet would happily write the MBR / past
       diskbuf for a hostile request). Pins, in the do_disk_write arm and reachable-before the ATA write:
         (1) the WRITE-LBA access_ok: `cmp ebx,DISK_WRESV_LO ; jb reject` AND `cmp ebx,DISK_WRESV_HI ; jae reject`
             (81 FB <le32(WLO)> ... 81 FB <le32(WHI)>), BOTH present, LO before HI, BOTH before the ATA programming.
             M-nowboundscheck drops both -> REJECT.
         (2) the OFFSET access_ok: `cmp ecx,512 ; jae reject` (81 F9 00 02 00 00 then 0F 8x) before the diskbuf store.
             M-nowecxcheck drops it -> REJECT.
         (3) the ATA PIO LBA28 WRITE sequence: 0x1F7<-0x30 (WRITE SECTORS), the rep OUTSW (66 F3 6F), and the ATA
             CACHE FLUSH (0x1F7<-0xE7). M-nowrite drops the whole sequence -> REJECT.
       All pinned BY THE EXACT EMITTED BYTES (built from build_elf()'s own labels) and located WITHIN the do_disk_write
       arm so the loader/CPU actually executes them on the eax=6 path. The READ arm is unchanged (assert_platter still
       holds -- additive). Returns True/False."""
    # The diskbuf address + the do_disk_write/do_write arm-anchor BYTES come from the GENUINE build's labels (so they
    # track the real image), but the arm we GRADE is located WITHIN THE PASSED kelf (a mutated candidate's arm shifts
    # and shrinks). The arm STARTS at the do_disk_write prologue `mov [tmp0],ecx ; mov [tmp1],dl`
    # (89 0D <tmp0> 88 15 <tmp1>) -- a sequence unique to this arm -- and ENDS at the do_write prologue's first
    # instruction (load_kdata = mov eax,KDATA = B8 <KDATA> ; the do_write arm starts there). We bound [arm_start, arm_end).
    _,_,labels=build_elf()
    diskbuf=labels['diskbuf']
    arm_start_anchor = bytes([0x89,0x0D])+le32(cell('tmp0'))+bytes([0x88,0x15])+le32(cell('tmp1'))  # do_disk_write prologue
    s = kelf.find(arm_start_anchor)
    if s < 0: return False                               # the do_disk_write arm is absent entirely
    # the arm ends at the do_write arm's prologue: `mov [tmp0=cur?]`... do_write begins `load_kdata; mov eax,[cur]`.
    # The unique do_write start is `mov eax,[cur]` = A1 <cur> right after its load_kdata. We bound the arm by the NEXT
    # do_write-prologue marker after s: load_kdata (B8 <KDATA> 8E D8...) immediately followed by `mov eax,[cur]` (A1<cur>).
    dowrite_anchor = bytes([0xB8])+le32(KDATA)+bytes([0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8])+bytes([0x8B,0x05])+le32(cell('cur'))
    e = kelf.find(dowrite_anchor, s)
    if e < 0: return False
    arm = kelf[s:e]
    cmp_wlo = bytes([0x81,0xFB])+le32(DISK_WRESV_LO)     # cmp ebx, DISK_WRESV_LO
    cmp_whi = bytes([0x81,0xFB])+le32(DISK_WRESV_HI)     # cmp ebx, DISK_WRESV_HI
    cmp_ecx = bytes([0x81,0xF9])+le32(512)               # cmp ecx, 512
    write_cmd = bytes([0x66,0xBA,0xF7,0x01, 0xB0,0x30,0xEE])   # mov dx,0x1F7 ; mov al,0x30 (WRITE SECTORS) ; out
    rep_outsw = bytes([0x66,0xF3,0x6F])                  # rep outsw (16-bit)
    flush_cmd = bytes([0x66,0xBA,0xF7,0x01, 0xB0,0xE7,0xEE])   # mov dx,0x1F7 ; mov al,0xE7 (CACHE FLUSH) ; out
    # (1) the WRITE-LBA bounds, in order, before the ATA programming.
    i_wlo = arm.find(cmp_wlo); i_whi = arm.find(cmp_whi)
    if i_wlo < 0: return False                           # LO-bound absent -> M-nowboundscheck
    if i_whi < 0: return False                           # HI-bound absent -> M-nowboundscheck
    if not (i_wlo < i_whi): return False                 # LO must be checked before HI
    # (2) the OFFSET bound, present, before the ATA programming, immediately followed by a jae (0F 83) to the reject.
    i_ecx = arm.find(cmp_ecx)
    if i_ecx < 0: return False                           # ECX-bound absent -> M-nowecxcheck
    if arm[i_ecx+len(cmp_ecx):i_ecx+len(cmp_ecx)+2] != bytes([0x0F,0x83]): return False  # cmp not followed by jae
    # (3) the ATA WRITE sequence: WRITE SECTORS cmd, then rep outsw, then CACHE FLUSH -- in order, after the bounds.
    i_wcmd = arm.find(write_cmd); i_rout = arm.find(rep_outsw, max(i_wcmd,0)); i_flush = arm.find(flush_cmd, max(i_rout,0))
    if i_wcmd < 0: return False                          # no WRITE SECTORS -> M-nowrite
    if i_rout < 0: return False                          # no rep outsw -> M-nowrite
    if i_flush < 0: return False                         # no CACHE FLUSH -> not durable (M-nowrite / no-flush forge)
    if not (i_whi < i_wcmd): return False                # the WRITE must come AFTER the LBA bound check
    if not (i_ecx < i_wcmd): return False                # the WRITE must come AFTER the offset bound check
    if not (i_wcmd < i_rout < i_flush): return False     # WRITE SECTORS -> rep outsw -> CACHE FLUSH, in order
    # the write must store the byte INTO the live diskbuf (mov [ecx+diskbuf],al = 88 81 <le32(diskbuf)>), not a baked
    # sector -- the durable byte is the module-supplied DL placed at diskbuf[ECX].
    store_byte = bytes([0x88,0x81])+le32(diskbuf)        # mov byte [ecx + diskbuf], al
    if store_byte not in arm: return False
    if not (arm.find(store_byte) < i_rout): return False # the byte must be placed in diskbuf BEFORE the rep outsw flushes it
    # ---- FIX A (pin_reachability_not_presence / talcott class): pin the THREE write-access_ok jcc BRANCH TARGETS, not
    # just the cmp;jcc opcodes. Opcode-presence alone is FORGEABLE: a neutered forge keeps `cmp ebx,WLO ; jb` /
    # `cmp ebx,WHI ; jae` / `cmp ecx,512 ; jae` byte-for-byte but zeroes each jcc's rel32, so EVERY out-of-bounds branch
    # FALLS THROUGH into the ATA write path instead of rejecting -- the bounds are DECORATIVE, the sandbox is wide open,
    # yet the old presence-only check (and even the (2) "cmp followed by 0F 83" adjacency) PASSED. We decode each jcc's
    # rel32 and require its TARGET to land on the genuine reject block (load_udata ; xor eax,eax ; iret), which performs
    # NO write. The reject target is computed in FILE-OFFSET space: the jcc and its target both live in the contiguous
    # loaded `code` segment (file 4096 -> vaddr LOAD), so target_file = jcc_file + 6 + rel32 is identical to the vaddr
    # arithmetic the CPU does. (talcott/pin_reachability doctrine: a disasm gate must bind the branch TARGET, never just
    # the opcode, or a rel32=0 fall-through neuters the guard while every byte the gate looks for is still present.)
    reject_blk = bytes([0xB8])+le32(UDATA3)+bytes([0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8])+bytes([0x31,0xC0,0xCF])
    # the GENUINE diskw_reject is the LAST reject-shaped block in the arm (the clean-return path emits the same shape just
    # before it; diskw_reject is emitted last). Identify it AFTER the CACHE FLUSH so a forge can't pass by targeting a
    # reject-shaped block that sits in front of / inside the write path.
    rj = arm.rfind(reject_blk)
    if rj < 0: return False                              # no reject block at all -> nothing to branch to
    if not (i_flush < rj): return False                  # the reject block must sit AFTER the ATA write/flush path
    reject_arm_off = rj                                  # arm-relative offset of the genuine reject block
    # each guard: (cmp arm-off, expected jcc opcode byte). jb=0x82 for WLO (reject when ebx<WLO); jae=0x83 for WHI/ECX.
    guards = [(i_wlo, len(cmp_wlo), 0x82, 'cmp ebx,WLO ; jb reject'),
              (i_whi, len(cmp_whi), 0x83, 'cmp ebx,WHI ; jae reject'),
              (i_ecx, len(cmp_ecx), 0x83, 'cmp ecx,512 ; jae reject')]
    for cmp_off, cmp_len, want_cc, _why in guards:
        jcc = arm[cmp_off+cmp_len:cmp_off+cmp_len+6]     # the 6-byte near jcc immediately after the cmp
        if len(jcc) < 6: return False
        if jcc[0] != 0x0F or jcc[1] != want_cc: return False   # not the expected conditional branch (or no branch) -> REJECT
        rel32 = int.from_bytes(jcc[2:6], 'little', signed=True)
        # the jcc instruction occupies [cmp_off+cmp_len, cmp_off+cmp_len+6); its next_ip is +6, target = next_ip + rel32.
        jcc_arm_off = cmp_off + cmp_len
        target_arm_off = jcc_arm_off + 6 + rel32
        if target_arm_off != reject_arm_off: return False     # rel32=0 (neutered forge) -> target falls through, NOT the
        #   reject block -> REJECT. ANY target other than the genuine reject block (a decorative bound) -> REJECT.
    # ---- FIX B (output_invisible_sandbox_break / the platter cld/DF class, Codex caught for the WRITE arm): pin BOTH
    # DF=0 invariants the write arm depends on. load_kdata sets the segments but does NOT clear DF, so a hostile module
    # that does `std` (DF=1) before int 0x30 inherits DF=1 into the arm. The genuine arm cld's TWICE -- once before
    # `rep stosd` (zeroing diskbuf) and once before `rep outsw` (sending the sector) -- so both string ops walk FORWARD
    # regardless of the module's DF. WITHOUT the clds (M-nowcld) DF=1 makes (i) `rep stosd` walk BACKWARD, zeroing 508
    # bytes of KERNEL memory below diskbuf (the top PTEs of the page tables `pt` sit immediately below diskbuf) and
    # leaving diskbuf[4..511] uninitialised, and (ii) `rep outsw` walk BACKWARD, sending diskbuf[0..1] then page-table
    # bytes BELOW diskbuf out the data port -> the WRONG sector content reaches the medium AND any sentinel the module
    # wrote at offset>=2 never lands at that disk offset. OUTPUT-INVISIBLE on the benign two-boot (ambient DF=0, durable
    # byte at offset 0). Pin the EXACT adjacencies (cld IMMEDIATELY before each string op), within the arm:
    cld_stosd  = bytes([0xFC, 0xF3, 0xAB])                # cld ; rep stosd   (zero diskbuf FORWARD)
    cld_outsw  = bytes([0xFC, 0x66, 0xF3, 0x6F])          # cld ; rep outsw   (send the sector FORWARD)
    if cld_stosd not in arm: return False                 # M-nowcld drops the 0xFC before rep stosd -> REJECT
    if cld_outsw not in arm: return False                 # M-nowcld drops the 0xFC before rep outsw -> REJECT
    # (Codex tightening: pin the EXACT EXECUTED stosd lead-in contiguously -- as for outsw -- so a DEAD `FC F3 AB`
    # planted elsewhere in the arm can't satisfy a presence-only check while the live rep stosd runs with no cld.
    # The genuine lead-in is `mov edi,diskbuf ; xor eax,eax ; mov ecx,256 ; cld ; rep stosd`.)
    stosd_leadin = bytes([0xBF])+le32(diskbuf)+bytes([0x31,0xC0, 0xB9,0x80,0x00,0x00,0x00, 0xFC, 0xF3,0xAB])  # ECX=128 dwords=512B (stosd is 32-bit; 256 would overrun diskbuf by 512B -- Codex)
    if stosd_leadin not in arm: return False              # the live rep stosd is not immediately preceded by cld -> REJECT
    # both clds must sit on the ATA write path (after the bound checks, in the write sequence): the rep stosd cld zeroes
    # the buffer BEFORE the WRITE SECTORS programming; the rep outsw cld sits between WRITE SECTORS and the CACHE FLUSH.
    i_cld_stosd = arm.find(cld_stosd); i_cld_outsw = arm.find(cld_outsw)
    if not (i_whi < i_cld_stosd): return False            # the buffer-zero must come AFTER the LBA bound check
    if not (i_cld_stosd < i_cld_outsw): return False      # zero diskbuf (stosd) BEFORE flushing it out (outsw)
    if not (i_wcmd < i_cld_outsw < i_flush): return False # the outsw (with its cld) sits between WRITE SECTORS and FLUSH
    # ---- (Codex audit (b)): the rep outsw uses DX; `mov dx,0x1F0` (66 BA F0 01) must IMMEDIATELY precede the cld;rep
    # outsw, so DX is the ATA data port 0x1F0 and CANNOT inherit the module's EDX or the 0x1F7 status port left from the
    # BSY/DRQ polling. Pin the exact `66 BA F0 01 ... BE <diskbuf> B9 00 01 00 00 FC 66 F3 6F` lead-in to the outsw.
    set_dx_1f0 = bytes([0x66,0xBA,0xF0,0x01])             # mov dx,0x1F0
    outsw_leadin = set_dx_1f0 + bytes([0xBE])+le32(diskbuf)+bytes([0xB9,0x00,0x01,0x00,0x00, 0xFC, 0x66,0xF3,0x6F])
    if outsw_leadin not in arm: return False              # DX not explicitly set to 0x1F0 right before rep outsw -> REJECT
    return True


def build_neutered_forge():
    """THE FORGE that motivates FIX A (talcott / pin_reachability_not_presence). It is the GENUINE build_elf() image with
       ONLY the three write-access_ok jcc rel32s ZEROED -- every `cmp ; jb/jae reject` byte is still present (the bound
       looks enforced) but each branch now FALLS THROUGH into the ATA write path, so an out-of-window / out-of-offset
       request LANDS instead of rejecting: a WRITE-ANYWHERE sandbox break that is OUTPUT-INVISIBLE on the benign two-boot
       (the benign request is in-window, so the dropped reject never fires). It PASSED the old presence-only
       assert_durability (and the (2) cmp-followed-by-0F-83 adjacency); it FAILS the FIX-A assert_durability (the branch
       TARGETS no longer land on the reject block). Returns (forged_image, kend)."""
    img,kend,_=build_elf()
    b=bytearray(img)
    arm_start=bytes([0x89,0x0D])+le32(cell('tmp0'))+bytes([0x88,0x15])+le32(cell('tmp1'))
    s=bytes(b).find(arm_start)
    if s<0: raise RuntimeError('do_disk_write arm not found -- cannot build the neutered forge')
    dowrite=bytes([0xB8])+le32(KDATA)+bytes([0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8])+bytes([0x8B,0x05])+le32(cell('cur'))
    e=bytes(b).find(dowrite,s); arm=bytes(b)[s:e]
    for c in (bytes([0x81,0xFB])+le32(DISK_WRESV_LO),
              bytes([0x81,0xFB])+le32(DISK_WRESV_HI),
              bytes([0x81,0xF9])+le32(512)):
        ci=arm.find(c); jcc=s+ci+len(c)
        assert b[jcc]==0x0F and b[jcc+1] in (0x82,0x83), 'expected a near jcc after the bound cmp'
        b[jcc+2:jcc+6]=b'\x00\x00\x00\x00'    # rel32 <- 0 (the bound becomes decorative; the reject branch never taken)
    return bytes(b),kend


# ============================ link39 (FILESYSTEM CAIRN) FORCING: the two-boot named-lookup probers ============================
# THE STEP-0 SCENARIO is a TWO-BOOT on ONE persistent disk medium:
#   BOOT-1 (writer prober): SYS_FS_PUT a TARGET record (name ALPHA, payload P_A) then a DECOY (name BRAVO, payload P_B),
#     DECOY PUT *after* TARGET. SYS_EXIT. (For STEP-0 the names/payloads are hardcoded in the prober; late-binding over
#     COM1 is for the real gate.)
#   REBOOT (fresh kernel, RAM wiped, SAME disk).
#   BOOT-2 (reader prober, TWO variants): SYS_FS_GET by a QUERY name, SYS_WRITE the resolved payload, EXIT.
#     (i) query ALPHA -> must emit P_A ; (ii) query BRAVO -> must emit P_B.
#   Emitting the CORRECT different payload per query is what proves name resolution (not a positional rule). The decoy-
#   after-target ordering + the TWO-QUERY check is what makes M-returnfirst (always the first valid) RED on query BRAVO.
#
# The module lays its name + payload + dst buffers in its OWN in-region stack (so the kernel's access_ok passes). The
# prober pushes the 16-byte name and the payload bytes onto the stack, points EBX/ECX/EDX at them, and int 0x30's.

def _push_bytes(m, data):
    # push `data` (len multiple-of-4 padded) onto the prober stack so [esp] holds data[0..]; returns nothing.
    # We push 4 bytes at a time from the END so the lowest address (esp) holds data[0]. Pad to a 4-byte multiple.
    pad = (-len(data)) % 4
    d = data + b'\x00'*pad
    for i in range(len(d)-4, -1, -4):
        w = int.from_bytes(d[i:i+4], 'little')
        m.raw(0x68); m.blob(le32(w))              # push imm32
    return len(d)   # number of stack bytes consumed

def module_fs_writer():
    # BOOT-1 (proc0, K=1): PUT (ALPHA, P_A) then PUT (BRAVO, P_B) [decoy after target], then SYS_EXIT.
    m=Asm()
    def do_put(name16, payload):
        # build the payload on the stack, then the 16-byte name ABOVE it (lower address) so we can point at both.
        # layout after pushes (low -> high addr): [name16][payload]. esp -> name16.
        plen = len(payload)
        pbytes = _push_bytes(m, payload)          # push payload first (it ends up at the HIGHER address)
        nbytes = _push_bytes(m, name16)           # push name next   (it ends up at the LOWER address = esp)
        # esp -> name (16B region: nbytes), esp+nbytes -> payload.
        m.raw(0x89,0xE3)                          # mov ebx,esp                 (name_ptr)
        m.raw(0x8D,0x8C,0x24); m.blob(le32(nbytes))   # lea ecx,[esp+nbytes]    (payload_ptr)
        m.raw(0xBA); m.blob(le32(plen))           # mov edx, len
        m.raw(0xB8); m.blob(le32(SYS_FS_PUT))     # mov eax,7 (SYS_FS_PUT)
        m.raw(0xCD,0x30)                          # int 0x30
        m.raw(0x81,0xC4); m.blob(le32(pbytes+nbytes))   # add esp, (restore stack)
    do_put(FS_NAME_ALPHA, FS_PAY_ALPHA)           # TARGET first
    do_put(FS_NAME_BRAVO, FS_PAY_BRAVO)           # DECOY after target
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def module_fs_reader(query16):
    # BOOT-2 (proc0, K=1, fresh boot): SYS_FS_GET(query16) -> resolved payload in a dst buffer, SYS_WRITE the len bytes.
    m=Asm()
    DSTCAP = FS_MAXLEN
    # reserve a dst buffer on the stack (DSTCAP bytes, zeroed via sub esp), and push the 16-byte query name above it.
    m.raw(0x81,0xEC); m.blob(le32(DSTCAP))        # sub esp, DSTCAP   (dst buffer; esp -> dst)
    m.raw(0x89,0xE6)                              # mov esi,esp       (remember dst base in esi -- preserved? no: int 0x30
    #   may clobber. We re-derive dst from esp after the GET instead.)
    nbytes = _push_bytes(m, query16)              # push the query name (esp -> name; name is BELOW dst now)
    # esp -> name(16) ; esp+nbytes -> dst buffer(DSTCAP).
    m.raw(0x89,0xE3)                             # mov ebx,esp                  (name_ptr = query)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(nbytes))  # lea ecx,[esp+nbytes]         (dst_ptr)
    m.raw(0xBA); m.blob(le32(DSTCAP))            # mov edx, dst_cap
    m.raw(0xB8); m.blob(le32(SYS_FS_GET))        # mov eax,8 (SYS_FS_GET)
    m.raw(0xCD,0x30)                             # int 0x30 -> eax=found, ecx=len
    # save found+len on the stack for clarity; emit the dst buffer's len bytes via SYS_WRITE.
    # ecx = len (returned). dst_ptr = esp+nbytes. SYS_WRITE(dst_ptr, len).
    m.raw(0x89,0xCA)                             # mov edx,ecx                  (edx = len)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(nbytes))  # lea ecx,[esp+nbytes]         (dst_ptr again)
    m.raw(0xB8); m.blob(le32(SYS_WRITE))         # mov eax,2 (SYS_WRITE)
    m.raw(0xCD,0x30)                             # int 0x30 -> emit the len resolved bytes
    m.raw(0x81,0xC4); m.blob(le32(nbytes+DSTCAP))   # add esp (restore)
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

# ---- the hostile-LBA PUT prober: writes a dir entry naming a FORBIDDEN data_lba (=0=the MBR), then a GET must REJECT ----
# This forces the NEW security surface: the stored data_lba is attacker-influenced. We cannot make a benign PUT name an
# arbitrary data_lba (PUT allocates by insertion order), so the hostile leg writes a CRAFTED directory sector DIRECTLY
# (via a separate writer that pokes the dir via SYS_FS_PUT is insufficient). For STEP-0 we instead UNIT-TEST the bound in
# Python (the data_lba access_ok) AND optionally craft a hostile dir on the host disk + GET it. The host-crafted dir
# approach is exercised in the runner; here we expose the GET prober for an arbitrary query (reused as the hostile GET).
def module_fs_get_query(query16):
    return module_fs_reader(query16)


# ============================ link39 GRADE ============================
def grade_fs(stream, kend_elf, want_payload):
    """cairn FS grade -- BOOT-2 reader. The reader SYS_FS_GETs by a query name and SYS_WRITEs the resolved payload.
       GREEN requires the emitted bytes == want_payload (the payload the named record was PUT with in BOOT-1, persisted
       across the reboot). RED on: M-returnfirst (query BRAVO emits ALPHA's payload -- positional, not by-name);
       M-fixedlba (query BRAVO reads FS_DATA_LO=ALPHA's sector -> wrong payload); not-found (emits nothing / 0 bytes);
       a stale/empty disk (nothing persisted). want_payload is threaded from the harness."""
    errs=[]
    want = want_payload
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the reader prober dumped) -> RED']
    tail=r['_tail']
    # the reader does ONE SYS_WRITE of `len` bytes -> ONE wframe whose body is the resolved payload.
    wfs=[w for w in _wframes(tail) if w['closed'] and w['cs']==UCODE3 and (w['cs']&3)==3]
    if len(wfs)!=1:
        errs.append(f'BOOT-2 emitted {len(wfs)} write-frames != 1 (the reader faulted or the GET was not handled)')
        return errs
    emitted = wfs[0]['body']
    if emitted != want:
        errs.append(f'WRONG PAYLOAD: BOOT-2 emitted {emitted!r} (len {len(emitted)}) != the named record\'s payload '
                    f'{want!r} (len {len(want)}). A wrong payload means name-resolution failed: M-returnfirst (always the '
                    f'first valid slot -> query BRAVO emits ALPHA\'s payload) or M-fixedlba (always FS_DATA_LO -> query '
                    f'BRAVO reads ALPHA\'s sector); empty means not-found / nothing persisted across the reboot.')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (cairn is a single-program probe)')
    return errs


# ============================ link39 access_ok UNIT TEST (the new security surface, in Python) ============================
def fs_get_data_lba_ok(stored_lba):
    """The exact BY-VALUE bound the do_fs_get arm applies to a matched entry's stored data_lba before the ATA read:
       require FS_DATA_LO <= stored_lba < FS_DATA_HI. Returns True (read allowed) / False (rejected -> found=0, no leak).
       A hostile PUT that smuggled data_lba=0 (the MBR) or any out-of-window sector is REJECTED here, so the GET never
       becomes an arbitrary-sector read primitive."""
    return FS_DATA_LO <= stored_lba < FS_DATA_HI


# ============================ link39 WHITE-BOX assert ============================
def assert_cairn(kelf):
    """White-box co-pin for the cairn's data_lba bound (the NEW security surface) + the fixed-D dir scan + the FS string-op
       cld-adjacencies (GAP-2). The two-query output grade is the PRIMARY binding; this catches the output-invisible
       sandbox breaks (a GET that reads an attacker-named data_lba; a GET/PUT whose rep walks BACKWARD off diskbuf/dirbuf
       into the page tables when a hostile module does std=DF=1 before int 0x30). Pins:
         (1) the data_lba BY-VALUE bound: `cmp eax,FS_DATA_LO ; jb reject` AND `cmp eax,FS_DATA_HI ; jae reject` on the
             value loaded from the dir entry's data_lba field (mov eax,[esi+24]).
         (2) the FIXED-D dir scan bound: `cmp ecx,FS_D ; jae scandone` (the scan is over EXACTLY FS_D slots).
         (3) the FS string-op cld-adjacencies (mirroring assert_durability's cld pin -- an output-invisible confused-deputy
             op needs an assert-pin + a hostile-DF leg + a mutant, because the byte-pin cannot see a bug its oracle shares),
             pinned ARM-LOCALLY (pin_reachability_not_presence: a global count is forgeable by dead FC F3 A6/A4/AB bytes
             planted elsewhere while the LIVE reps run cld-less -- a cross-model review flagged this -- so we bound the
             do_fs_put / do_fs_get arms and count the cld-adjacencies INSIDE each):
               PUT arm: ONE `FC F3 AB` (cld;rep stosd -- diskbuf-zero) + TWO `FC F3 A4` (cld;rep movsb -- payload + name copy).
               GET arm: ONE `FC F3 A6` (cld;repe cmpsb -- the 16-byte name compare) + ONE `FC F3 A4` (cld;rep movsb -- dst copy).
             M-fsnocld drops every FS cld -> each per-arm count goes to 0 -> REJECT. (M-returnfirst also fails here, since it
             removes the GET name-compare cmpsb+cld entirely -> a bonus white-box catch on top of its output-leg RED.)
       Returns True/False."""
    load_eax_lba = bytes([0x8B,0x46,FS_OFF_LBA])              # mov eax,[esi+24]  (load the stored data_lba)
    cmp_lo = bytes([0x3D])+le32(FS_DATA_LO)                   # cmp eax, FS_DATA_LO
    cmp_hi = bytes([0x3D])+le32(FS_DATA_HI)                   # cmp eax, FS_DATA_HI
    if load_eax_lba not in kelf: return False
    p = kelf.find(load_eax_lba)
    region = kelf[p:p+64]
    i_lo = region.find(cmp_lo); i_hi = region.find(cmp_hi)
    if i_lo < 0 or i_hi < 0: return False                     # one of the data_lba bounds absent
    if not (i_lo < i_hi): return False                        # LO before HI
    # each cmp must be immediately followed by a near jcc (0F 82 jb / 0F 83 jae)
    if region[i_lo+len(cmp_lo):i_lo+len(cmp_lo)+2] != bytes([0x0F,0x82]): return False   # cmp LO ; jb
    if region[i_hi+len(cmp_hi):i_hi+len(cmp_hi)+2] != bytes([0x0F,0x83]): return False   # cmp HI ; jae
    # (2) the fixed-D scan bound appears in the kernel (cmp ecx,FS_D ; jae). FS_D fits a byte -> `83 F9 <D>`.
    scan_bound = bytes([0x83,0xF9,FS_D])
    if scan_bound not in kelf: return False
    # (3) the FS string-op cld-adjacencies (GAP-2), pinned ARM-LOCALLY (pin_reachability_not_presence / the durable
    # cld-adjacency doctrine): cld IMMEDIATELY before each FS rep, located WITHIN the do_fs_put / do_fs_get arm so a forge
    # cannot satisfy a global count with dead `FC F3 A6/A4/AB` bytes planted elsewhere while the LIVE FS reps run cld-less.
    # Both FS arms share an identical 3-save prologue `mov [fs_nameptr],ebx ; mov [fs_payptr],ecx ; mov [fs_len],edx`
    # (89 1D <nameptr> 89 0D <payptr> 89 15 <len>) emitted EXACTLY twice -- the FIRST is do_fs_put, the SECOND do_fs_get
    # (do_fs_put is emitted before do_fs_get). The PUT arm = [put#0, put#1); the GET arm = [put#1, the timer_handler
    # signature that immediately follows do_fs_get). We require the exact cld-adjacency byte-counts per arm.
    cld_cmpsb = bytes([0xFC,0xF3,0xA6])      # cld ; repe cmpsb  (GET name compare)
    cld_movsb = bytes([0xFC,0xF3,0xA4])      # cld ; rep movsb   (GET dst-copy ; PUT payload-copy + name-copy)
    cld_stosd = bytes([0xFC,0xF3,0xAB])      # cld ; rep stosd   (PUT diskbuf-zero)
    fs_prologue = (bytes([0x89,0x1D])+le32(cell('fs_nameptr'))
                   + bytes([0x89,0x0D])+le32(cell('fs_payptr'))
                   + bytes([0x89,0x15])+le32(cell('fs_len')))   # the shared do_fs_put/do_fs_get prologue
    pp = [i for i in range(len(kelf)) if kelf.startswith(fs_prologue, i)]
    if len(pp) != 2: return False                             # exactly do_fs_put + do_fs_get; anything else is a forge
    put0, put1 = pp[0], pp[1]
    timer_sig = bytes([0x60, 0xB8])+le32(KDATA)+bytes([0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8])  # timer_handler after do_fs_get
    t = kelf.find(timer_sig, put1)
    if t < 0: return False
    put_arm = kelf[put0:put1]                                 # the do_fs_put arm
    get_arm = kelf[put1:t]                                    # the do_fs_get arm
    # PUT arm: the diskbuf-zero stosd + the payload-copy + name-copy movsb's must each be cld-led (1 stosd + 2 movsb).
    if put_arm.count(cld_stosd) != 1: return False            # M-fsnocld drops the PUT diskbuf-zero cld -> 0 -> REJECT
    if put_arm.count(cld_movsb) != 2: return False            # M-fsnocld drops the PUT payload+name copy clds -> 0 -> REJECT
    # GET arm: the name-compare cmpsb + the dst-copy movsb must each be cld-led (1 cmpsb + 1 movsb).
    if get_arm.count(cld_cmpsb) != 1: return False            # M-fsnocld drops the GET name-compare cld -> 0 -> REJECT
    if get_arm.count(cld_movsb) != 1: return False            # M-fsnocld drops the GET dst-copy cld -> 0 -> REJECT
    return True


if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='fswriter':        # out  (BOOT-1: PUT ALPHA(target) then BRAVO(decoy))
        open(sys.argv[2],'wb').write(module_fs_writer()); sys.exit(0)
    elif cmd=='fsreader':      # out queryname  (BOOT-2: GET <queryname> -> emit the resolved payload)
        q = fs_name(sys.argv[3])
        open(sys.argv[2],'wb').write(module_fs_reader(q)); sys.exit(0)
    elif cmd=='fspayload':     # name -> print the payload (hex) the harness expects for a query (alpha->P_A, bravo->P_B)
        nm = sys.argv[2].lower()
        pay = FS_PAY_ALPHA if nm in ('alpha','a') else (FS_PAY_BRAVO if nm in ('bravo','b') else None)
        if pay is None: raise SystemExit('unknown name '+nm)
        print(pay.hex()); sys.exit(0)
    elif cmd=='gradefs':       # stream kend wantpayloadhex
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); want=bytes.fromhex(sys.argv[4])
        errs=grade_fs(stream,kend,want)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='fswindow':      # print FS_DIR_LBA FS_DATA_LO FS_DATA_HI FS_D
        print(FS_DIR_LBA, FS_DATA_LO, FS_DATA_HI, FS_D); sys.exit(0)
    elif cmd=='assertcairn':    # kelf -> exit 0 if the cairn white-box co-pin holds
        sys.exit(0 if assert_cairn(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='fslbaok':       # stored_lba -> print 1/0 (the data_lba access_ok unit test)
        print(1 if fs_get_data_lba_ok(int(sys.argv[2],0)) else 0); sys.exit(0)
    elif cmd=='durwriter':     # out [seed]  (BOOT-1 writer prober; seed baked if given, else late-bound SYS_READ over COM1)
        seed=int(sys.argv[3],0) if len(sys.argv)>3 else None
        open(sys.argv[2],'wb').write(module_durable_writer(seed)); sys.exit(0)
    elif cmd=='durreader':     # out  (BOOT-2 reader prober)
        open(sys.argv[2],'wb').write(module_durable_reader()); sys.exit(0)
    elif cmd=='durwindow':     # print DISK_WRESV_LO DISK_WRESV_HI DUR_WLBA DUR_OFF
        print(DISK_WRESV_LO, DISK_WRESV_HI, DUR_WLBA, DUR_OFF); sys.exit(0)
    elif cmd=='gradedur':      # stream kend wantbyte(hex)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); want=int(sys.argv[4],0)
        errs=grade_durability(stream,kend,want)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='neuteredforge': # out  (the FIX-A forge: genuine image with the 3 write-bound jcc rel32s zeroed)
        forge,kend=build_neutered_forge(); open(sys.argv[2],'wb').write(forge); print('%x'%kend); sys.exit(0)
    elif cmd=='assertdurable': # kelf -> exit 0 if the write-arm white-box co-pin holds
        sys.exit(0 if assert_durability(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='hostilewriter': # out  (the hostile-writer prober: writes to a FORBIDDEN LBA -> must be rejected)
        open(sys.argv[2],'wb').write(module_hostile_writer()); sys.exit(0)
    elif cmd=='hostilewritetarget':  # print "LBA OFF BYTE" -- the forbidden sector the harness checks is NOT modified
        print(HOSTILE_WRITE_LBA, HOSTILE_WRITE_OFF, HOSTILE_WRITE_BYTE); sys.exit(0)
    elif cmd=='hostileecxwriter':    # out  (valid LBA + ECX>=512 -> must be rejected, no kernel write past diskbuf)
        open(sys.argv[2],'wb').write(module_hostile_ecx_writer()); sys.exit(0)
    elif cmd=='hostiledfwriter':     # out  (std (DF=1) + a valid in-window WRITE at DF_W_OFF -> the kernel must cld so the sector is built/sent FORWARD)
        open(sys.argv[2],'wb').write(module_hostile_df_writer()); sys.exit(0)
    elif cmd=='hostiledfwritetarget':  # print "LBA OFF BYTE" -- the (write LBA, in-sector offset, sentinel) the harness inspects after the DF-writer
        print(DF_W_LBA, DF_W_OFF, DF_W_BYTE); sys.exit(0)
    elif cmd=='diskprober':      # out  (link37 K-hop disk pointer-chase prober)
        open(sys.argv[2],'wb').write(module_disk_prober())
        sys.exit(0)
    elif cmd=='gradedisk':     # stream kend chasemap  (chasemap = "idx:byte,idx:byte,...")
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        chase=_parse_chase_arg(sys.argv[4])
        errs=grade_disk(stream,kend,chase)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='diskexpect':    # chasemap -> print expected chain hex
        chase=_parse_chase_arg(sys.argv[2])
        print(' '.join('%02x'%b for b in disk_chase_expect(chase)))
        sys.exit(0)
    elif cmd=='diskwindow':    # print DISK_RESV_LO DISK_RESV_HI DISK_KHOPS DISK_START_IDX
        print(DISK_RESV_LO, DISK_RESV_HI, DISK_KHOPS, DISK_START_IDX); sys.exit(0)
    elif cmd=='kernelelf':
        mut=sys.argv[3] if len(sys.argv)>3 else None
        stage=sys.argv[4] if len(sys.argv)>4 else 'full'
        img,kend,_=build_elf(mut if mut!='none' else None,stage); open(sys.argv[2],'wb').write(img); print('%x'%kend)
    elif cmd=='kend':
        _,kend,_=build_elf(); print('%x'%kend)
    elif cmd=='modprober':     # out [seed]  (lethe K=1 alias-remap prober; seed baked if given, else late-bound SYS_READ)
        seed=int(sys.argv[3],0) if len(sys.argv)>3 else None
        open(sys.argv[2],'wb').write(module_lethe_prober(seed))
    elif cmd=='modprober_nowarm':  # out [seed]  (the CONTROL prober that SKIPS the warm)
        seed=int(sys.argv[3],0) if len(sys.argv)>3 else None
        open(sys.argv[2],'wb').write(module_lethe_prober(seed, variant='nowarm'))
    elif cmd=='gradelethe':    # stream kend [seed]
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        seed=int(sys.argv[4],0) if len(sys.argv)>4 else LETHE_SEED
        errs=grade_lethe(stream,kend,seed)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='assertlethe':
        sys.exit(0 if assert_lethe(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='assertplatter':     # kelf  -> exit 0 if the block-device white-box co-pin holds (bound cmps + ATA seq + live movzx)
        sys.exit(0 if assert_platter(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='hostileprober':     # out  (the hostile-LBA prober: requests forbidden LBAs, must get sentinel 0)
        open(sys.argv[2],'wb').write(module_hostile_prober())
        sys.exit(0)
    elif cmd=='hostilelbas':       # print the hostile LBAs + count (for the disk-builder / harness)
        print(' '.join(str(x) for x in HOSTILE_LBAS)); sys.exit(0)
    elif cmd=='gradehostile':      # stream kend  (GREEN iff every hostile read returned sentinel 0)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_disk_hostile(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='hostileecxprober':  # out  (the hostile-ECX prober: valid LBA + ECX>=512 -> must get sentinel 0)
        open(sys.argv[2],'wb').write(module_hostile_ecx_prober())
        sys.exit(0)
    elif cmd=='hostileecxprobe':   # print "ECX_PROBE LEAK_BYTE" (for the harness / disk-builder)
        off,b=disk_hostile_ecx_probe(); print(off, b); sys.exit(0)
    elif cmd=='gradehostileecx':   # stream kend  (GREEN iff the hostile-ECX read returned sentinel 0)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_disk_hostile_ecx(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='hostiledfprober':   # out  (the hostile-DF prober: std (DF=1) + a valid in-window read at DF_PROBE_OFF -> must still read FORWARD)
        open(sys.argv[2],'wb').write(module_hostile_df_prober())
        sys.exit(0)
    elif cmd=='hostiledfprobe':    # print "LBA OFF BYTE" -- the (absolute LBA, in-sector offset, sentinel byte) the harness dd's so the forward read is well-defined
        print(DISK_RESV_LO+HOSTILE_DF_LBA_IDX, DF_PROBE_OFF, DF_PROBE_BYTE); sys.exit(0)
    elif cmd=='gradehostiledf':    # stream kend  (GREEN iff the hostile-DF read returned the KNOWN sentinel at DF_PROBE_OFF -- forward read)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_disk_hostile_df(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='ncells': print(len(CELLS))
    else: raise SystemExit('usage: kernelelf|kend|diskprober|gradedisk|diskexpect|diskwindow|hostileprober|hostilelbas|'
                           'gradehostile|hostileecxprober|hostileecxprobe|gradehostileecx|hostiledfprober|gradehostiledf|'
                           'modprober|modprober_nowarm|gradelethe|assertlethe|assertplatter|ncells')
