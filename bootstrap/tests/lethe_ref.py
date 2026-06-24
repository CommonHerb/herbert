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
import holler_ref as H
from holler_ref import Asm, gdt_desc, idt_gate, le16

OUT=H.OUT; LOAD=H.LOAD; ENTRY=H.ENTRY                                          # cleave L52
KCODE=H.KCODE; KDATA=H.KDATA; UCODE=H.UCODE; UDATA=H.UDATA; TSS_SEL=H.TSS_SEL  # cleave L53
UCODE3=H.UCODE3; UDATA3=H.UDATA3                                               # cleave L54
SYS_READ=0; SYS_EXIT=1; SYS_WRITE=2; SYS_REMAP=4   # cleave L55 + lethe: SYS_REMAP=4 (unused eax) -- the alias remap
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
         'nprocs','cur','live','switches','nexcl','answer','tmp0','tmp1','cow_next']  # cleave L126-127 (cow_next kept inert)
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
    a.raw(0x83,0xF8,SYS_REMAP); a.j(JE,'do_remap')         # eax==4 -> REMAP  (lethe NEW)
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


if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='kernelelf':
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
    elif cmd=='ncells': print(len(CELLS))
    else: raise SystemExit('usage: kernelelf|kend|modprober|modprober_nowarm|gradelethe|assertlethe|ncells')
