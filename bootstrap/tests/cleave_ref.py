#!/usr/bin/env python3
# tessera_ref.py -- STEP-0 oracle + BYTE-EXACT emitter target for "SHARED MEMORY via a NON-IDENTITY ALIASED FRAME"
# (native-codegen Link 50 / kernel-arc link 34). THE FIRST TIME vaddr != paddr IN THE STACK. Every prior link mapped
# virtual page g to physical frame g (identity: PTE[g]=g*4096+3); "memory" capabilities (U/S isolation, demand-commit,
# region reclaim) were all permission/identity tricks an identity-backed reserve can forge. tessera installs, AT RUNTIME,
# ONE shared physical frame F mapped at TWO distinct virtual pages Va != Vb, with F != Va and F != Vb -- the first
# NON-IDENTITY page-table entries. A producer ring-3 program writes a late-bound multi-word payload through Va; a
# consumer ring-3 program reads the SAME bytes back through Vb (a plain CPL3 mov -- no kernel copy in the data path) and
# emits them. Genuine ZERO-COPY SHARED MEMORY: a payload LARGER than tandem's one-register (4-byte) mailbox can carry,
# crossing between two isolated programs through ONE physical frame at TWO names.
#
# WHY IT IS UNFAKEABLE (the homestead lesson -- a single non-identity frame is OUTPUT-INVISIBLE: a program cannot
# observe its own physical backing; non-identity is observable ONLY via ALIASING -- write through one name, read through
# another). Three binding layers: (1) RUNTIME -- the consumer emits a per-run HELD-BACK payload it could only have read
# through the shared frame (its own region is peer-isolated, the 4-byte mailbox can't carry a multi-word payload, the
# payload is late-bound over COM1 so it cannot be baked); (2) WHITE-BOX -- assert_tessera pins the two non-identity
# installs PTE[Va]<-F and PTE[Vb]<-F with F != Va and F != Vb (an identity map / U-bit flip / fixed-large reserve
# provably cannot satisfy PFN(Va)==PFN(Vb) != either vaddr); (3) DIFFERENTIAL -- the FROZEN furlough kernel (no alias
# install) leaves Va,Vb identity+Supervisor, so the modules #PF on the shared window (or, with a permission-only forge,
# read DISJOINT frames) -> the consumer never sees the producer's payload -> RED.
#
# Built additively on the FROZEN furlough lineage (tessera_ref started as a byte-identical copy of furlough_ref):
# lodger parse/bump-alloc + nokta paging-U/S + geeking fault->continue + tickover preemptive full-context switch +
# rollcall runtime-K table + tenement region reclaim + homestead demand-paged grow + furlough block/wake. NEW vs
# furlough (the ONLY additions; furlough's machinery is inherited byte-identical and inert here):
#   SH_FRAME / SH_VA / SH_VB  the shared physical frame and its two non-identity virtual aliases (compile-time fixed,
#              all clear of the kernel/regions/page-tables; see SH_* constants + the excl reservation).
#   ALIAS arm  at boot, after paging is on (just before COM1 init): install PTE[SH_VA>>12] <- SH_FRAME|7 and
#              PTE[SH_VB>>12] <- SH_FRAME|7 (present+RW+User), zero the shared frame's sentinel slot, reload cr3 (TLB
#              flush so the new mappings take). NON-IDENTITY: SH_FRAME != SH_VA and != SH_VB; ALIASED: both PTEs hold F.
#   producer   (proc0): SYS_READ a late-bound seed byte, derive SH_N distinct seed-dependent words, write them through
#              SH_VA (mov [SH_VA+i*4]), write SH_SENTINEL LAST (sentinel-last so no half-filled frame is observed; uniproc
#              program order), SYS_EXIT. Emits NOTHING itself.
#   consumer   (proc1): spin-read [SH_VB+SH_N*4] until == SH_SENTINEL (deterministic; preemptible, can't starve the
#              producer), then read the SH_N words through SH_VB and SYS_WRITE each, SYS_EXIT. The words it emits could
#              only have come through the shared frame.
# FORCING (hand-assembled, byte-pinned): K=2. GREEN requires the consumer to emit ALL SH_N late-bound words. The FROZEN
# furlough kernel, fed the SAME pair, leaves the shared window unmapped/identity -> RED. Mutations (all RED): M-noinstall
# (no alias -> #PF), M-identity (install Va->Va, Vb->Vb User: accessible but DISJOINT -> consumer sees nothing -- the KEY
# mutation, the homestead-M-eager analogue proving ALIASING not permission is load-bearing), M-onlyone (only Va aliased
# -> Vb disjoint), M-supervisor (alias both to F but Supervisor -> CPL3 #PF on the shared window). (M-noflush is VACUOUS
# and dropped: the windows are first touched AFTER the install, so the TLB never cached the stale identity mapping --
# the flush is defensive hygiene, kept, but not load-bearing; cf. the BIOS-leaves-PIT-ticking vacuous-mutation lesson.)
# The link's data path is UNIDIRECTIONAL (producer writes Va, consumer reads Vb); empirical STEP-0 booted the runtime
# alias-install on QEMU-TCG + KVM + Bochs before the emitter, and there exercised the mapping in BOTH directions (write
# Va/read Vb AND write Vb/read Va) to confirm the alias is a true shared frame, not a one-way copy.
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holler_ref as H
from holler_ref import Asm, gdt_desc, idt_gate, le16

OUT=H.OUT; LOAD=H.LOAD; ENTRY=H.ENTRY
KCODE=H.KCODE; KDATA=H.KDATA; UCODE=H.UCODE; UDATA=H.UDATA; TSS_SEL=H.TSS_SEL
UCODE3=H.UCODE3; UDATA3=H.UDATA3
SYS_READ=0; SYS_EXIT=1; SYS_WRITE=2
NPT=4                       # 4 page tables -> identity-map 16 MiB (kernel + K small modules + K 1-page regions)
PIT_DIV=0xFFFF
MAXPROC=8                   # process-table capacity (a compile-time cap like any OS MAX_PROCS; K<=MAXPROC at runtime)
MSLOTS=MAXPROC              # furlough: mint a region page PER proc (min(MSLOTS,K)=K) -- every forcing proc gets its own
#   region, so reclamation/waiting (tenement) stays in the kernel ADDITIVELY but is inert for the block/wake scenario.
assert MSLOTS<=MAXPROC, 'MSLOTS must fit the process table'
GROWMAX=8                   # homestead: grow-window pages reserved BELOW each proc's committed stack page. The full
#   span [alloc_lo - GROWMAX*0x1000, alloc_hi) is excluded from peers/kernel; only the top page is committed at boot;
#   the GROWMAX pages below it start P=0 (not present) and are committed ON DEMAND as the stack grows into them.
assert GROWMAX>=1, 'GROWMAX must reserve at least one grow page'
GROWBYTES=GROWMAX*0x1000
GROWER_N   = 400            # recursion depth of the forcing grower; ~N frames clearly exceed 1 page but fit GROWMAX
GROWER_FRAME = 16           # extra stack reserved per recursion level (on top of the 4-byte call return addr)
GROWER_SEED = 0x5A          # default held-back seed byte (overridable; the kernel is seed-agnostic, fed via COM1)
# ---- furlough (block/wake) forcing constants (inherited; inert in tessera's scenario) ----
FBYTE   = 0x5A              # the held-back byte delivered to the naive reader A in RUN-2 (fed late-bound over COM1)
RDR_TAG = 0xAB0000          # A emits le32(RDR_TAG | delivered_byte) -- output DEPENDS on the byte (byte-correctness pin)
FURL_SEED = 0x5EED1         # seed for B,C's distinct held-back peer tokens (worker_tokens); distinct from RDR_TAG space
# ---- cleave (COPY-ON-WRITE) constants ----
# The COW scenario: ONE shared physical frame F mapped at TWO non-identity user aliases -- VW (writable, F|7) and VR
# (read-only, F|5). A ring-3 prober fills F through VW, then writes a marker THROUGH VR (read-only) -> a write-protection
# #PF (err P=1,W=1,U=1) -> the kernel's COW arm allocates a FRESH frame F' from a reserved pool, COPIES F->F' (4096 B),
# remaps PTE[VR] <- F'|7 (now private+writable), and iret-resumes the faulting store, which lands in F'. The prober then
# reads back BOTH aliases: VR diverged at the written word (its private copy F'); VW is UNCHANGED (the shared frame F).
# Output-forced WITHIN ONE execution (no cross-process / SMP needed): a no-copy forge that just flips VR writable makes
# the marker land in the SHARED frame F -> VW reads the marker too -> RED. SH_VA/SH_VB/SH_FRAME repurposed: SH_VA=VW
# (RW alias), SH_VB=VR (RO alias), SH_FRAME=F (the shared frame). All page-aligned, in the 16 MiB identity map, above
# the kernel (~1 MiB) and regions (~1.3 MiB), and RESERVED from the region bump allocator via fixed excl[] entries.
# HONEST-SCOPE RESIDUE: the windows + pool are FIXED vaddrs (the lodger-style audited residue, verified clear on 3
# substrates); a runtime frame allocator that chooses the pool dynamically is the DEFERRED other-D20-half, not this atom.
SH_VA   = 0x600000          # VW: the WRITABLE alias onto the shared frame F (vaddr; identity frame 0x600000 ABANDONED)
SH_VB   = 0x800000          # VR: the READ-ONLY alias onto the shared frame F (vaddr; the COW write target)
SH_FRAME= 0xA00000          # F: the SHARED physical frame both aliases map  (!= VW, != VR -> NON-IDENTITY)
COW_POOL= 0xC00000          # base of the reserved COW copy-frame pool; cow_next bumps from here per COW fault (1 frame)
COW_POOL_N = 4              # pool capacity (frames available for COW copies; >= the prober's COW-fault count)
COW_MARK= 0x00C0FFEE        # the marker the prober writes THROUGH VR to trigger COW (distinct from every payload word)
COW_IDX = 2                 # which payload word the prober overwrites via VR (0..SH_N-1)
COW_DEEP_IDX = 1023         # the LAST dword in the page (offset 0xFFC): the prober fills+reads it so a SHORT-copy forge
COW_DEEP_TAG = 0x7D0000     #   (copy only the first words) leaves it uninitialized -> RED. Output-forces the FULL 4 KiB copy
                            #   (cross-model Codex flagged that reading only the first words leaves the full copy byte-pin-only).
SH_N    = 4                 # number of seed-derived payload words filled through VW (the page contents to be COW-copied)
SH_TAG  = 0x5E0000          # payload high bits: word_i = (SH_TAG | (seed & 0xFF)) + i*0x100  (distinct, seed-dependent)
SH_SEED = 0x5A              # default late-bound seed byte for the prober (fed over COM1; the kernel is seed-agnostic)
assert len({SH_VA,SH_VB,SH_FRAME,COW_POOL})==4, 'cleave windows + pool must be distinct'
assert SH_FRAME not in (SH_VA,SH_VB), 'aliases must be NON-IDENTITY (frame != vaddr)'
assert 0 <= COW_IDX < SH_N
def sh_words(seed):         # the SH_N seed-derived payload words the prober fills through VW (the grade reproduces these)
    base=(SH_TAG | (seed & 0xFF)) & 0xFFFFFFFF
    return [(base + i*0x100) & 0xFFFFFFFF for i in range(SH_N)]
def cow_deep(seed): return (COW_DEEP_TAG | (seed & 0xFF)) & 0xFFFFFFFF   # the deep-page word (offset 0xFFC), seed-derived
def cow_expect(seed):       # (vw_words, vr_words) the prober must emit: SH_N payload words + the deep word, each via VW
    p=sh_words(seed); d=cow_deep(seed)    #   (== payload: F UNCHANGED) then via VR (== payload but COW_IDX==MARK; the deep
    vw=p+[d]                              #   word preserved by the COPY). A short-copy forge leaves VR's deep word wrong.
    vr=p[:]; vr[COW_IDX]=COW_MARK; vr=vr+[d]
    return vw, vr
assert COW_MARK not in sh_words(SH_SEED) and cow_deep(SH_SEED) not in sh_words(SH_SEED) and cow_deep(SH_SEED)!=COW_MARK, \
    'marker + deep word must each differ from every payload word'
NEXCL=9+3*MAXPROC           # excl[] capacity: 9 fixed (kernel/mb/cm/elf/mmap + cleave VW/VR/F + COW pool) + 2 per
#   module (range + string window) + 1 per ALLOCATED region (appended during the bump loop so the next region avoids
#   it). With K<=MAXPROC enforced at parse (FOVER), the running nexcl is bounded by 8+3*K <= 8+3*MAXPROC, so it can
#   never overflow. (Cross-model Codex caught the original 5+2*MAXPROC undersize: it omitted the per-region append;
#   K>=6 overflowed into the code. tessera adds 3 fixed entries to reserve the shared window from the region allocator.)
assert NEXCL >= 8+3*MAXPROC, 'excl[] must hold 8 fixed + 2/module + 1/region for K up to MAXPROC'
JNE,JE,JB,JAE,JA,JBE=0x85,0x84,0x82,0x83,0x87,0x86
JS=0x88                     # jump if sign (0F 88) -- furlough idle-detect: budget went negative -> no runnable proc
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def s32(v): return struct.pack('<i', v)
REGN={'eax':0,'ecx':1,'edx':2,'ebx':3,'esp':4,'ebp':5,'esi':6,'edi':7}

# ---- cell layout: scalars, then per-process PARALLEL ARRAYS (MAXPROC each), then the excl[] arrays (NEXCL each) ----
SCALARS=['mbinfo','flags','cmdline','elflo','elfhi','mm_lo','mm_hi','region_lo','region_hi',
         'nprocs','cur','live','switches','nexcl','answer','tmp0','tmp1','cow_next']  # cleave: cow_next = COW copy-frame bump ptr
PARR=['modstart','modend','st_lo','st_hi','alloc_lo','alloc_hi','grow_floor','started','exited',
      't_edi','t_esi','t_ebp','t_ebx','t_edx','t_ecx','t_eax','t_eip','t_eflags','t_esp',
      'blocked','disp']     # furlough: blocked[]=parked-on-not-ready-SYS_READ; disp[]=per-proc dispatch counter
CELLS=[]
CELLS+= SCALARS
_ARRBASE={}
for nm in PARR:
    _ARRBASE[nm]=len(CELLS)
    CELLS+=[f'{nm}#{i}' for i in range(MAXPROC)]
_EXCLLO=len(CELLS); CELLS+=[f'excl_lo#{i}' for i in range(NEXCL)]
_EXCLHI=len(CELLS); CELLS+=[f'excl_hi#{i}' for i in range(NEXCL)]
CIDX={n:i for i,n in enumerate(CELLS)}
CELLBASE=ENTRY+6+5            # byte-0 `mov [mbinfo],ebx`(6) + `jmp glue`(5) -> cells start here (matches tickover)
def cell(n): return CELLBASE+CIDX[n]*4
def arr(nm): return CELLBASE+_ARRBASE[nm]*4
def excl_lo(): return CELLBASE+_EXCLLO*4
def excl_hi(): return CELLBASE+_EXCLHI*4
ANSWER=cell('answer')


def build_code(kstack, kend, mut=None, stage='full'):
    a=Asm()
    a._ctr=0
    def mmi(addr,imm): a.raw(0xC7,0x05); a.blob(le32(addr)); a.blob(le32(imm))   # mov dword[addr],imm
    def mme(addr): a.raw(0xA3); a.blob(le32(addr))                               # mov [addr],eax
    def mem(addr): a.raw(0xA1); a.blob(le32(addr))                               # mov eax,[addr]
    def outi(v): a.raw(0xB0,v,0xE6,OUT)
    def dr_eax():
        a.raw(0xE6,OUT)
        for _ in range(3): a.raw(0xC1,0xE8,0x08,0xE6,OUT)
    def alignup_eax(): a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def ld(dst,base,idx):   # mov dst,[base + idx*4]   (8B /r, SIB scale=4 index=idx base=none disp32)
        sib=0x80|(REGN[idx]<<3)|0x05
        a.raw(0x8B,(REGN[dst]<<3)|0x04,sib); a.blob(le32(base))
    def st(base,idx,src):   # mov [base + idx*4], src   (89 /r)
        sib=0x80|(REGN[idx]<<3)|0x05
        a.raw(0x89,(REGN[src]<<3)|0x04,sib); a.blob(le32(base))
    def pushidx(base,idx):  # push dword [base + idx*4]   (FF /6)
        sib=0x80|(REGN[idx]<<3)|0x05
        a.raw(0xFF,0x34,sib); a.blob(le32(base))
    def load_kdata(): a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    def load_udata(): a.raw(0xB8); a.blob(le32(UDATA3)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    def flip_pg(base,idx,setU):  # eax=[base+idx*4] (page addr) -> PTE = pt+(addr>>12)*4 -> or/and U bit
        ld('eax',base,idx)
        a.raw(0xC1,0xE8,0x0A); a.raw(0x25); a.blob(le32(0xFFFFFFFC)); a.raw(0x05); a.absR('pt')
        if setU: a.raw(0x83,0x08,0x04)        # or dword[eax],4  (-> User)
        else:    a.raw(0x83,0x20,0xFB)        # and dword[eax],~4 (-> Supervisor)
    def shutdown():
        a.raw(0x66,0xBA,0xF4,0x00); a.raw(0xEE)
        a.raw(0x66,0xBA,0x00,0x89)
        for ch in b'Shutdown': a.raw(0xB0,ch,0xEE)
        a.raw(0xFA,0xF4,0xEB,0xFD)

    # ===== prologue: capture mbinfo (byte 0), jump over the cell block, FAIL handlers, shutdown tail =====
    a.blob(bytes((0x89,0x1D))+le32(cell('mbinfo')))   # mov [mbinfo],ebx  (byte 0)
    a.j(None,'glue')
    a.blob(b'\x00'*(len(CELLS)*4))                     # the cell storage block (CELLBASE..)
    sd_FAILS=['F1','F2','F3','F4','F5','F8','F9','F10','FOVER']
    for idx,f in enumerate(sd_FAILS):
        a.lbl(f); a.blob(bytes([176,0x31+idx,0xE6,OUT])); a.j(None,'sdtail')
    a.lbl('sdtail'); shutdown()

    # ===== glue: validate multiboot magic, set up stack, read mbinfo fields (VERBATIM holler head) =====
    a.lbl('glue')
    a.raw(0x3D); a.blob(le32(0x2BADB002)); a.j(JNE,'F1')
    a.raw(0xBC); a.blob(le32(kstack))
    a.raw(0x31,0xC0); a.raw(0x0F,0x22,0xE0)            # xor eax,eax; mov cr4,eax
    a.raw(0x68); a.blob(le32(0x00000002)); a.raw(0x9D) # push 2; popf  (clear flags, IF=0)
    a.raw(0x8B,0x35); a.blob(le32(cell('mbinfo')))     # mov esi,[mbinfo]
    a.raw(0x8B,0x06); mme(cell('flags'))               # flags=[esi]
    a.raw(0xA8,0x08); a.j(JE,'F2')                     # require mods (bit3)
    a.raw(0xA8,0x40); a.j(JE,'F3')                     # require mmap (bit6)
    a.raw(0xA8,0x04); a.j(JE,'no_cmd')                 # cmdline (bit2)
    a.raw(0x8B,0x46,16); mme(cell('cmdline')); a.j(None,'cmd_done')
    a.lbl('no_cmd'); mmi(cell('cmdline'),0); a.lbl('cmd_done')
    a.raw(0xF7,0x06); a.blob(le32(0x20)); a.j(JE,'no_elf')   # elf shdr (bit5)
    a.raw(0x8B,0x46,36); mme(cell('elflo'))
    a.raw(0x8B,0x46,28); a.raw(0x0F,0xAF,0x46,32); a.raw(0x03,0x46,36); mme(cell('elfhi'))
    a.j(None,'elf_done'); a.lbl('no_elf'); mmi(cell('elflo'),0); mmi(cell('elfhi'),0); a.lbl('elf_done')
    # mmap window (mm_lo,mm_hi) -- VERBATIM holler
    a.raw(0x8B,0x46,48); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_lo'))
    a.raw(0x8B,0x46,48); a.raw(0x03,0x46,44); a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_hi'))

    # ===== K-GENERIC module parse: mods_count -> K (1..MAXPROC); loop reads K entries into the parallel arrays =====
    a.raw(0x8B,0x46,20)                                # eax = mods_count
    a.raw(0x83,0xF8,MAXPROC); a.j(JA,'FOVER')          # K > MAXPROC -> FAIL (honest cap)
    a.raw(0x83,0xF8,0x01); a.j(JB,'F4')                # K < 1 -> FAIL
    if mut=='cap2':                                    # M-cap2: clamp K<=2 (tickover-style) -> starves proc>=2 (RED)
        a.raw(0x83,0xF8,0x02); a.j(JBE,'capok'); a.raw(0xB8); a.blob(le32(2)); a.lbl('capok')
    mme(cell('nprocs'))                                # nprocs = K
    mme(cell('live'))                                  # live = K  (decremented as procs exit)
    a.raw(0x8B,0x6E,24)                                # ebp = mods_addr
    a.raw(0x31,0xC9)                                   # xor ecx,ecx  (i=0)
    a.lbl('parseloop')
    a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JAE,'parsedone')   # i >= K?
    a.raw(0x89,0xC8); a.raw(0xC1,0xE0,0x04); a.raw(0x01,0xE8)   # eax=i; shl eax,4; add eax,ebp  -> &mod[i]
    a.raw(0x89,0xC2)                                   # edx = &mod[i]
    a.raw(0x8B,0x02); st(arr('modstart'),'ecx','eax')          # modstart[i]=[edx+0]
    a.raw(0x8B,0x42,0x04); st(arr('modend'),'ecx','eax')       # modend[i]=[edx+4]
    # module string window: str=[edx+8]; lo=str&~0xFFF, hi=lo+0x2000 (or 0,0 if str==0)
    a.raw(0x8B,0x42,0x08)                              # eax = str
    a.raw(0x85,0xC0); a.j(JE,'nostr')
    a.raw(0x25); a.blob(le32(0xFFFFF000)); st(arr('st_lo'),'ecx','eax')   # st_lo[i]=str&~0xFFF
    a.raw(0x05); a.blob(le32(0x2000)); st(arr('st_hi'),'ecx','eax')       # st_hi[i]=+0x2000
    a.j(None,'strdone')
    a.lbl('nostr')
    a.raw(0x31,0xC0); st(arr('st_lo'),'ecx','eax'); st(arr('st_hi'),'ecx','eax')   # 0,0
    a.lbl('strdone')
    # sanity: modstart[i] < modend[i]
    ld('eax',arr('modstart'),'ecx'); ld('edx',arr('modend'),'ecx'); a.raw(0x39,0xD0); a.j(JAE,'F5')  # cmp eax,edx; jae
    a.raw(0x41); a.j(None,'parseloop')                 # inc ecx
    a.lbl('parsedone')

    # ===== build the excl[] array (data-driven): 5 fixed windows + 2 per module ([0,0] entries are inert) =====
    a.raw(0x31,0xFF)                                   # xor edi,edi  (nexcl counter)
    def excl_push(lo_emit, hi_emit):
        # lo_emit()/hi_emit() leave the value in eax; store at excl_lo[edi]/excl_hi[edi]; inc edi
        lo_emit(); st(excl_lo(),'edi','eax')
        hi_emit(); st(excl_hi(),'edi','eax')
        a.raw(0x47)                                    # inc edi
    def _mbwin_lo(): mem(cell('mbinfo')); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def _mbwin_hi(): mem(cell('mbinfo')); a.raw(0x25); a.blob(le32(0xFFFFF000)); a.raw(0x05); a.blob(le32(0x2000))
    def _cmwin_lo(): mem(cell('cmdline')); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def _cmwin_hi(): mem(cell('cmdline')); a.raw(0x25); a.blob(le32(0xFFFFF000)); a.raw(0x05); a.blob(le32(0x2000))
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(0x100000))),        # kernel image [0x100000, kend]
              lambda:(a.raw(0xB8),a.blob(le32(kend))))
    excl_push(_mbwin_lo, _mbwin_hi)                               # mbinfo window
    excl_push(_cmwin_lo, _cmwin_hi)                               # cmdline window
    excl_push(lambda:mem(cell('elflo')), lambda:mem(cell('elfhi')))   # elf shdr [elflo,elfhi]
    excl_push(lambda:mem(cell('mm_lo')), lambda:mem(cell('mm_hi')))   # mmap window
    # cleave: reserve the shared window (VW/VR/F) + the COW copy-frame pool so the region allocator never overlaps them
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(SH_VA))),    lambda:(a.raw(0xB8),a.blob(le32(SH_VA+0x1000))))      # VW page
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(SH_VB))),    lambda:(a.raw(0xB8),a.blob(le32(SH_VB+0x1000))))      # VR page
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(SH_FRAME))), lambda:(a.raw(0xB8),a.blob(le32(SH_FRAME+0x1000))))   # F page
    excl_push(lambda:(a.raw(0xB8),a.blob(le32(COW_POOL))), lambda:(a.raw(0xB8),a.blob(le32(COW_POOL+COW_POOL_N*0x1000))))  # COW copy-frame pool
    # NOTE: mbinfo/cmdline are guaranteed present (we required flags bits); if 0 the window [0,0x2000) is harmless
    # (it only excludes the zero page, never used). elf/mm are [0,0]/real as computed. Per-module windows:
    a.raw(0x31,0xC9)                                   # xor ecx,ecx (module i)
    a.lbl('mexcl')
    a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JAE,'mexcldone')
    ld('eax',arr('modstart'),'ecx'); st(excl_lo(),'edi','eax')
    ld('eax',arr('modend'),'ecx');   st(excl_hi(),'edi','eax'); a.raw(0x47)   # module range; inc edi
    ld('eax',arr('st_lo'),'ecx'); st(excl_lo(),'edi','eax')
    ld('eax',arr('st_hi'),'ecx'); st(excl_hi(),'edi','eax'); a.raw(0x47)      # module string window; inc edi
    a.raw(0x41); a.j(None,'mexcl')                     # inc ecx
    a.lbl('mexcldone')
    a.raw(0x89,0x3D); a.blob(le32(cell('nexcl')))      # mov [nexcl],edi

    # ===== memory-map scan -> region_lo/region_hi (VERBATIM holler/tickover) =====
    mmi(cell('region_lo'),0); mmi(cell('region_hi'),0)
    a.raw(0x8B,0x4E,48)                                # ecx = mmap_addr
    a.raw(0x8B,0x56,44); a.raw(0x01,0xCA)              # edx = mmap_addr + mmap_length (end)
    a.raw(0xBF); a.blob(le32(64))                      # edi = 64 (entry-count safety)
    a.lbl('mloop')
    a.raw(0x39,0xD1); a.j(JAE,'mdone')                 # ecx >= end?
    a.raw(0x4F); a.j(JE,'F8')                          # dec edi; ==0 -> FAIL (too many)
    outi(0x9C)
    for d in (0,4,8,12,16,20):
        a.raw(0x8B,0x01) if d==0 else a.raw(0x8B,0x41,d)
        dr_eax()
    mem(cell('region_hi')); a.raw(0x85,0xC0); a.j(JNE,'madv')   # already found one -> advance
    a.raw(0x8B,0x41,20); a.raw(0x83,0xF8,0x01); a.j(JNE,'madv') # type != 1 -> advance
    a.raw(0x8B,0x41,8); a.raw(0x85,0xC0); a.j(JNE,'madv')       # base_hi != 0 -> advance
    a.raw(0x8B,0x41,4)                                 # base_lo
    a.raw(0x8B,0x59,12); a.raw(0x01,0xD8)              # + len_lo -> end
    a.raw(0x8B,0x59,16); a.raw(0x85,0xDB); a.j(JE,'no_clamp')   # len_hi -> clamp
    a.raw(0xB8); a.blob(le32(0xFFFFF000)); a.lbl('no_clamp')
    a.raw(0x3D); a.blob(le32(0x100000)); a.j(JBE,'madv')        # end <= 1MiB -> advance
    mme(cell('region_hi')); a.raw(0x8B,0x41,4); mme(cell('region_lo'))
    a.lbl('madv')
    a.raw(0x8B,0x01); a.raw(0x83,0xC0,0x04); a.raw(0x01,0xC1); a.j(None,'mloop')   # ecx += [ecx]+4
    a.lbl('mdone')
    mem(cell('region_hi')); a.raw(0x85,0xC0); a.j(JE,'F9')

    # ===== tenement bump allocator: mint only M=min(MSLOTS,nprocs) region pages (procs M..K-1 start WAITING) =====
    # alloc_bound = min(MSLOTS, nprocs)  (guards MSLOTS<=nprocs: with K<MSLOTS only K pages are minted)
    a.raw(0xB8); a.blob(le32(MSLOTS))                  # eax = MSLOTS
    a.raw(0x3B,0x05); a.blob(le32(cell('nprocs'))); a.j(JBE,'mbok')   # MSLOTS <= nprocs?
    a.raw(0xA1); a.blob(le32(cell('nprocs')))          # else eax = nprocs
    a.lbl('mbok')
    a.raw(0xA3); a.blob(le32(cell('tmp0')))            # tmp0 = min(MSLOTS,nprocs)  (the alloc bound)
    a.raw(0x31,0xFF)                                   # xor edi,edi  (slot p)
    a.lbl('allocloop')
    a.raw(0x3B,0x3D); a.blob(le32(cell('tmp0'))); a.j(JAE,'allocdone')   # p >= M?  (NOT p>=K: M<N => waiters)
    # homestead: the candidate FOOTPRINT is [cur-GROWBYTES, cur+0x1000) (the grow window + the committed page). cur is
    # the COMMITTED-PAGE base (== alloc_lo). Start cur = max(region_lo, 0x100000) + GROWBYTES so grow_floor=cur-GROWBYTES
    # >= 0x100000. The overlap scan tests the FULL footprint vs every excl entry; the whole footprint is reserved.
    mem(cell('region_lo')); a.raw(0x3D); a.blob(le32(0x100000)); a.j(JAE,'hf')
    a.raw(0xB8); a.blob(le32(0x100000)); a.lbl('hf')
    alignup_eax(); a.raw(0x05); a.blob(le32(GROWBYTES))   # add eax,GROWBYTES (reserve the grow window below cur)
    a.raw(0x89,0xC1)                                   # ecx = cur (committed base; foot_lo = cur-GROWBYTES)
    a.lbl('rescan')
    a.raw(0x31,0xDB)                                   # xor ebx,ebx (changed flag)
    a.raw(0x31,0xF6)                                   # xor esi,esi (excl index j)
    a.lbl('eckloop')
    a.raw(0x3B,0x35); a.blob(le32(cell('nexcl'))); a.j(JAE,'eckdone')      # j >= nexcl?
    a.raw(0x8D,0x81); a.blob(le32((-GROWBYTES)&0xFFFFFFFF))  # eax = cur - GROWBYTES = foot_lo (lea eax,[ecx-GROWBYTES])
    ld('edx',excl_hi(),'esi'); a.raw(0x39,0xD0); a.j(JAE,'nextj')          # foot_lo >= hi[j] -> no overlap (above it)
    a.raw(0x8D,0x81); a.blob(le32(0x1000))            # eax = cur + 0x1000 = foot_hi (lea eax,[ecx+0x1000])
    ld('edx',excl_lo(),'esi'); a.raw(0x39,0xD0); a.j(JBE,'nextj')          # foot_hi <= lo[j] -> no overlap
    # overlap: cur = alignup(excl_hi[j]) + GROWBYTES; ebx=1  (push the whole footprint above the colliding entry)
    ld('eax',excl_hi(),'esi'); alignup_eax(); a.raw(0x05); a.blob(le32(GROWBYTES)); a.raw(0x89,0xC1); a.raw(0xBB); a.blob(le32(1))
    a.lbl('nextj')
    a.raw(0x46); a.j(None,'eckloop')                   # inc esi
    a.lbl('eckdone')
    a.raw(0x85,0xDB); a.j(JNE,'rescan')                # changed -> rescan
    # footprint clear: check foot_hi = cur+0x1000 <= region_hi
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); a.raw(0x3B,0x05); a.blob(le32(cell('region_hi'))); a.j(JA,'F10')
    st(arr('alloc_lo'),'edi','ecx')                    # alloc_lo[p] = cur (committed base)
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); st(arr('alloc_hi'),'edi','eax')   # alloc_hi[p] = cur+0x1000
    a.raw(0x8D,0x81); a.blob(le32((-GROWBYTES)&0xFFFFFFFF)); st(arr('grow_floor'),'edi','eax')  # grow_floor[p]=cur-GROWBYTES
    # append the FULL footprint [foot_lo, foot_hi) to excl so peers/kernel never overlap the grow window:
    a.raw(0x8B,0x35); a.blob(le32(cell('nexcl')))      # esi = nexcl
    a.raw(0x8D,0x81); a.blob(le32((-GROWBYTES)&0xFFFFFFFF)); st(excl_lo(),'esi','eax')   # excl_lo=foot_lo
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); st(excl_hi(),'esi','eax')                    # excl_hi=foot_hi
    a.raw(0x46); a.raw(0x89,0x35); a.blob(le32(cell('nexcl')))   # inc esi; [nexcl]=esi
    a.raw(0x47); a.j(None,'allocloop')                 # inc edi
    a.lbl('allocdone')

    # ===== dump OWN table: 0x9A LOAD kend mmap_addr mmap_len <cells> 0x9B (parser reads cells by name) =====
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

    # ===== install ring machinery (lgdt/lidt/ltr) (VERBATIM tickover) =====
    a.raw(0x0F,0x01,0x15); a.absR('gdtr')
    a.raw(0xEA); a.absR('reload'); a.raw(0x08,0x00)
    a.lbl('reload')
    a.raw(0xB8); a.blob(le32(KDATA))
    a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xD0,0x8E,0xE0,0x8E,0xE8)
    a.raw(0x0F,0x01,0x1D); a.absR('idtr')
    a.raw(0x66,0xB8,TSS_SEL,0x00); a.raw(0x0F,0x00,0xD8)

    # ===== paging ON + flip proc 0's pages User (the first to run) =====
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # mov cr3,pd
    a.raw(0x0F,0x20,0xC0); a.raw(0x0D); a.blob(le32(0x80000000)); a.raw(0x0F,0x22,0xC0)  # cr0.PG=1
    a.raw(0xEB,0x00)
    if mut!='noflip0':
        a.raw(0x31,0xC9)                                   # xor ecx,ecx  (proc 0)
        flip_pg(arr('modstart'),'ecx',True)                # proc0 code page -> User
        flip_pg(arr('alloc_lo'),'ecx',True)                # proc0 stack page -> User
    # ===== homestead: COMMIT/CLEAR each minted proc's grow window. M-eager: map the WHOLE window present+RW+User up
    #   front (no faults -> no commit witness -> RED). default/M-noclear-skip: CLEAR Present on every window PTE so a
    #   stack push into it faults NOT-PRESENT. M-noclear: skip entirely -> the window stays present+Supervisor -> a
    #   CPL3 push hits a present-Supervisor page -> PROTECTION #PF (err.P=1) -> terminal kill -> RED. =====
    if mut!='noclear':
        # for p in 0..tmp0-1: for page in [grow_floor[p], alloc_lo[p]) step 0x1000: pte=pt+(page>>12)*4
        a.raw(0x31,0xFF)                                   # xor edi,edi  (proc p)
        a.lbl('gw_p')
        a.raw(0x3B,0x3D); a.blob(le32(cell('tmp0'))); a.j(JAE,'gw_pdone')   # p >= minted count?
        ld('esi',arr('grow_floor'),'edi')                  # esi = grow_floor[p] (page walker)
        a.lbl('gw_pg')
        ld('edx',arr('alloc_lo'),'edi'); a.raw(0x39,0xD6); a.j(JAE,'gw_pgdone')   # esi >= alloc_lo[p] -> window done
        a.raw(0x89,0xF1)                                   # ecx = esi (page addr)
        a.raw(0xC1,0xE9,0x0A); a.raw(0x83,0xE1,0xFC); a.raw(0x81,0xC1); a.absR('pt')   # ecx = pt + (page>>12)*4
        if mut=='eager':                                   # M-eager: COMMIT the whole window up front (present+RW+User)
            a.raw(0x89,0xF0); a.raw(0x83,0xC8,0x07)        # eax=esi; or eax,7  (page&~0xFFF already aligned | P|RW|U)
            a.raw(0x89,0x01)                               # mov [ecx],eax
        else:                                              # default: CLEAR Present (PTE &= ~1) -> not-present
            a.raw(0x83,0x21,0xFE)                          # and dword[ecx],~1
        a.raw(0x81,0xC6); a.blob(le32(0x1000)); a.j(None,'gw_pg')   # esi += 0x1000
        a.lbl('gw_pgdone')
        if mut=='eager':                                   # M-eager: the WHOLE window is committed up front, so the
            #   committed region spans [grow_floor,alloc_hi) -- set alloc_lo[p]=grow_floor[p] so SYS_WRITE's access_ok
            #   accepts writes from any window page. The grower then descends fully and emits ALL N words (FULL correct
            #   output) but takes ZERO #PF -> ZERO commit witnesses -> RED on the temporal demand gate. (KEY MUTATION:
            #   distinguishes demand-commit from eager/fixed-large-reserve -- correct OUTPUT, missing commit witness.)
            ld('eax',arr('grow_floor'),'edi'); st(arr('alloc_lo'),'edi','eax')
        a.raw(0x47); a.j(None,'gw_p')                      # inc edi (next proc)
        a.lbl('gw_pdone')
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # reload cr3 (flush TLB)

    # ===== cleave: install the COW ALIASES (THE LINK'S SETUP) =====
    # PTE[VW>>12] <- F|7 (present+RW+User) ; PTE[VR>>12] <- F|5 (present+User, READ-ONLY -- NO RW bit). Both NON-IDENTITY
    # (F != VW, F != VR) and ALIASED (both hold F). The prober fills F through VW, then a store THROUGH VR (read-only)
    # traps a write-protection #PF -> the COW arm (pf_handler) copies F->F' and remaps VR. Also seed cow_next = COW_POOL.
    #   M-noinstall: skip install -> VR stays identity+Supervisor -> a CPL3 store #PFs terminally (no COW) -> RED.
    #   M-vrwritable: install VR as RW (F|7) -> the store does NOT fault -> NO COW -> it lands in the SHARED F -> VW reads
    #     the marker -> RED. Proves the READ-ONLY alias (the write-protect trap) is what triggers COW, not a copy by luck.
    #   M-videntr: install VR -> VR (identity, a DISJOINT frame) -> the prober reads its own empty window, never F's
    #     payload -> RED. Proves VR genuinely ALIASES F (the homestead-M-identity analogue).
    if mut!='noinstall':
        vr_frame = SH_VB if mut=='videntr' else SH_FRAME
        vr_perm  = 7      if mut=='vrwritable' else 5                              # VR read-only (|5) unless M-vrwritable
        a.raw(0xC7,0x05); a.absR('pt',(SH_VA>>12)*4); a.blob(le32(SH_FRAME|7))      # PTE[VW] <- F | P|RW|User
        a.raw(0xC7,0x05); a.absR('pt',(SH_VB>>12)*4); a.blob(le32(vr_frame|vr_perm))# PTE[VR] <- F | P|User|(RO)
        mmi(cell('cow_next'), COW_POOL)                                            # cow_next = COW_POOL (copy-frame bump)
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)                            # reload cr3 (TLB flush)

    # ===== COM1 init (VERBATIM tickover) =====
    for port,val in [(0x3FB,0x03),(0x3F9,0x00),(0x3FB,0x80),(0x3F8,0x01),
                     (0x3F9,0x00),(0x3FB,0x03),(0x3FA,0x00),(0x3FC,0x03)]:
        a.raw(0x66,0xBA); a.blob(le16(port)); a.raw(0xB0,val,0xEE)
    # ===== PIC remap (only IRQ0 unmasked) + PIT periodic (mode 2) (VERBATIM tickover) =====
    for v,p in [(0x11,0x20),(0x11,0xA0),(0x20,0x21),(0x28,0xA1),(0x04,0x21),(0x02,0xA1),
                (0x01,0x21),(0x01,0xA1),(0xFE,0x21),(0xFF,0xA1)]:
        a.raw(0xB0,v,0xE6,p)
    if mut!='noarm':
        a.raw(0xB0,0x34,0xE6,0x43)                          # out 0x43,0x34 (ch0, lo/hi, mode2 rate-gen, binary)
        a.raw(0xB0,PIT_DIV&0xFF,0xE6,0x40)
        a.raw(0xB0,(PIT_DIV>>8)&0xFF,0xE6,0x40)

    # ===== zero proc 0's spin stop-flag; wake immediately if it is the ONLY program; iret into proc 0 (IF=1) =====
    mem(arr('alloc_lo'))                                    # eax = proc0 page base
    a.raw(0xC7,0x00); a.blob(le32(0))                       # [alloc_lo[0]] = 0 (stop-flag clear)
    mem(cell('nprocs')); a.raw(0x83,0xF8,0x01); a.j(JNE,'nowake1')
    mem(arr('alloc_lo')); a.raw(0xC7,0x00); a.blob(le32(1))  # K==1: wake the lone spinner so it terminates
    a.lbl('nowake1')
    mmi(arr('started'),1)                                  # started[0]=1: proc0 is started by THIS boot iret, so a
    #   later resume must go through do_restore (restore the saved TCB) -- NOT fresh-restart it. This is what makes
    #   the full-context save/restore load-bearing for the spinner (M-minimal/M-noeflags lose edx/DF -> sentinel).
    load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))                       # push ss
    a.raw(0xFF,0x35); a.blob(le32(arr('alloc_hi')))        # push useresp = proc0 stack top
    a.raw(0x68); a.blob(le32(0x00000002 if mut=='coop' else 0x00000202))  # push eflags (M-coop: IF=0 -> no preempt)
    a.raw(0x68); a.blob(le32(UCODE3))                      # push cs
    a.raw(0xFF,0x35); a.blob(le32(arr('modstart')))       # push eip = proc0 entry
    a.raw(0xCF)                                            # iretd -> CPL3 proc0

    # ===== syscall handler (vec 0x30): READ / EXIT / WRITE =====
    a.lbl('exit_handler')
    a.raw(0x85,0xC0); a.j(JE,'do_read')                    # eax==0 -> read
    a.raw(0x83,0xF8,0x02); a.j(JE,'do_write')              # eax==2 -> write
    # ---- SYS_EXIT (eax==1): status in bl; mark exited[cur]; live--; finalize / wake-spinner / switch ----
    load_kdata()
    a.raw(0x88,0xD8); a.raw(0xA2); a.blob(le32(ANSWER))    # mov al,bl ; mov [answer],al
    a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))            # ecx = cur
    a.raw(0xC7,0x04,0x8D); a.blob(le32(arr('exited'))); a.blob(le32(1))   # mov dword[exited+ecx*4],1
    if mut!='nolive':                                      # M-nolive: never dec live -> live never hits 1/0 ->
        a.raw(0xFF,0x0D); a.blob(le32(cell('live')))       #   spinner never woken + never finalize -> hang (RED)
    # ===== tenement RECLAIM: hand the exiting proc's region to the FIRST waiting proc (physical page REUSE) =====
    # ecx still = cur (the exiting proc). Scan w=0..K-1 for the first WAITING proc (alloc_lo[w]==0 AND exited[w]==0).
    if mut!='noreclaim':                                   # M-noreclaim: skip the handoff -> waiters never get a page,
        a.raw(0x31,0xD2)                                   #   sched skips them, live never reaches 0 -> hang (RED)
        a.lbl('rcscan')                                    # xor edx,edx (w=0)
        a.raw(0x3B,0x15); a.blob(le32(cell('nprocs'))); a.j(JAE,'rcnone')   # w >= K -> no waiter
        ld('eax',arr('alloc_lo'),'edx'); a.raw(0x85,0xC0); a.j(JNE,'rcnext')   # alloc_lo[w]!=0 -> has region, skip
        ld('eax',arr('exited'),'edx');   a.raw(0x85,0xC0); a.j(JNE,'rcnext')   # exited[w]!=0 -> dead, skip
        a.j(None,'rcfound')                                # found a waiting proc w=edx
        a.lbl('rcnext')
        a.raw(0x42); a.j(None,'rcscan')                    # inc edx
        a.lbl('rcfound')
        # HAND OVER the region: alloc_lo[w]=alloc_lo[cur]; alloc_hi[w]=alloc_hi[cur] (same physical page -> REUSE).
        # NOTE: the page User-flips below ((A) region, (B) code) are IDEMPOTENT with sched_switch's own per-pick flip
        # (it re-Users whichever proc it schedules), so REMOVING them is vacuous -- the genuinely load-bearing remap
        # is the alloc_lo/alloc_hi CELL handoff: w needs BOTH halves (lo to be schedulable past the WAITING-skip, hi
        # for its fresh-start stack top). M-noremap therefore hands lo but SKIPS the alloc_hi store -> w is scheduled
        # (lo!=0) but fresh-starts with useresp=alloc_hi[w]==0 -> its first push #PFs at addr ~0 -> token missing -> RED.
        ld('eax',arr('alloc_lo'),'ecx'); st(arr('alloc_lo'),'edx','eax')
        if mut!='noremap':
            ld('eax',arr('alloc_hi'),'ecx'); st(arr('alloc_hi'),'edx','eax')
        flip_pg(arr('alloc_lo'),'edx',True)                # (A) region page -> User for w (idempotent w/ sched flip)
        flip_pg(arr('modstart'),'edx',True)                # (B) w's CODE page -> User (idempotent w/ sched flip)
        flip_pg(arr('modstart'),'ecx',False)               # cur's CODE page -> Supervisor (cur is done). NOT the
        #   region page -- w owns it now. started[w] stays 0 so sched fresh-starts w (esp=alloc_hi[w], eip=modstart[w]).
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)   # reload cr3 (flush TLB after the flips)
        a.j(None,'sched_switch')                           # handoff done -> just switch (skip finalize/wake tail)
    a.lbl('rcnone')
    mem(cell('live')); a.raw(0x85,0xC0); a.j(JE,'finalize')   # live==0 -> finalize
    a.raw(0x83,0xF8,0x01); a.j(JNE,'sched_switch')         # live>1 -> just switch
    if mut!='nowake':                                      # M-nowake: spinner never woken -> spins forever (RED)
        mem(arr('alloc_lo'))                               # live==1: wake the spinner (proc0)
        a.raw(0xC7,0x00); a.blob(le32(1))                  # [alloc_lo[0]] = 1
    a.j(None,'sched_switch')
    a.lbl('finalize')
    outi(0xC8); mem(cell('switches')); dr_eax(); outi(0xC9)   # dump switch counter
    # furlough: dump per-proc DISPATCH counts -- CA <disp[0]> .. <disp[K-1]> CB. The forge-killer witness: a genuine
    # block parks the reader (dispatched O(1) times); a runnable-retry forge re-dispatches it every cycle (disp >> peers).
    outi(0xCA)
    a.raw(0x31,0xC9)                                       # xor ecx,ecx
    a.lbl('fdisp')
    a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JAE,'fdispdone')   # ecx >= K?
    ld('eax',arr('disp'),'ecx'); dr_eax()                 # dump disp[ecx]
    a.raw(0x41); a.j(None,'fdisp')                        # inc ecx
    a.lbl('fdispdone')
    outi(0xCB)
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')

    # ---- SYS_READ (eax==0): poll COM1 LSR ONCE. Ready -> read RBR + iret byte back. NOT ready -> BLOCK arm:
    #      snapshot the int-0x30 return frame into TCB[cur] (t_eip=[esp], t_eflags=[esp+8], t_esp=useresp=[esp+0xC]),
    #      set blocked[cur]=1, jmp sched_switch. The wake arm (in sched_switch) later delivers the byte into t_eax. ----
    a.lbl('do_read')
    if mut=='noblock':                                    # M-noblock: revert to the FROZEN IF=0 busy-poll (74 f7 loop)
        a.blob(bytes.fromhex('66bafd03eca80174f766baf803ec'))   #   -> a not-ready reader spins forever, machine FREEZES
    else:
        a.blob(bytes.fromhex('66bafd03ec'))               # mov dx,0x3fd; in al,dx  (LSR)
        a.raw(0xA8,0x01); a.j(JNE,'do_read_ready')        # test al,1; jnz -> data ready, read now
        # ---- BLOCK arm (park the caller) ----
        load_kdata()
        a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))       # ecx = cur
        a.raw(0x8B,0x04,0x24)                             # mov eax,[esp]      (return eip after int 0x30)
        if mut=='restart': a.raw(0x83,0xE8,0x02)          # M-restart (runnable-retry forge): eax-=2 -> re-exec int 0x30
        st(arr('t_eip'),'ecx','eax')                      # t_eip[cur] = resume eip
        a.raw(0x8B,0x44,0x24,0x08); st(arr('t_eflags'),'ecx','eax')   # t_eflags[cur] = [esp+8]
        a.raw(0x8B,0x44,0x24,0x0C); st(arr('t_esp'),'ecx','eax')      # t_esp[cur]   = useresp [esp+0xC]
        if mut not in ('noblockflag','restart'):
            a.raw(0xC7,0x04,0x8D); a.blob(le32(arr('blocked'))); a.blob(le32(1))   # blocked[cur] = 1
            #   M-noblockflag: omit -> caller stays RUNNABLE (resumes after int 0x30 with stale t_eax -> wrong byte).
            #   M-restart: omit + restart eip -> caller re-runs the read every dispatch (runnable-retry) -> disp[A] >> 2.
        a.j(None,'sched_switch')
        a.lbl('do_read_ready')
        a.blob(bytes.fromhex('66baf803ec'))               # mov dx,0x3f8; in al,dx  (read RBR)
    a.raw(0x88,0xC3)                                       # mov bl,al  (shared read-completion tail)
    outi(0xC0)
    a.raw(0x88,0xD8,0xE6,OUT)
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                   # cs
    a.raw(0x8B,0x04,0x24); dr_eax()                        # eip
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                   # useresp
    outi(0xC1)
    load_udata()
    a.raw(0x0F,0xB6,0xC3)                                  # movzx eax,bl
    a.raw(0xCF)

    # ---- SYS_WRITE (eax==2): access_ok vs the ACTIVE region (indexed by cur); relay ----
    a.lbl('do_write')
    load_kdata()
    a.raw(0x8B,0x05); a.blob(le32(cell('cur')))            # eax = cur
    ld('esi',arr('alloc_lo'),'eax'); ld('edi',arr('alloc_hi'),'eax')   # esi=lo[cur], edi=hi[cur]
    a.raw(0x89,0xC8); a.raw(0x01,0xD0)                     # eax=ecx(ptr)+edx(len)
    a.j(JB,'reject_write')
    a.raw(0x39,0xF1); a.j(JB,'reject_write')               # ptr<lo
    a.raw(0x39,0xF8); a.j(JA,'reject_write')               # ptr+len>hi
    outi(0xD4)
    a.raw(0x89,0xD0); dr_eax()                             # len
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                   # cs
    a.raw(0x8B,0x04,0x24); dr_eax()                        # eip
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                   # useresp
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

    # ===== TIMER handler (vec 0x20 / IRQ0): PREEMPT a CPL3 program, save full ctx into TCB[cur], switch =====
    GP=[(0,'t_edi'),(4,'t_esi'),(8,'t_ebp'),(16,'t_ebx'),(20,'t_edx'),(24,'t_ecx'),(28,'t_eax'),
        (32,'t_eip'),(40,'t_eflags'),(44,'t_esp')]
    MIN=[(8,'t_ebp'),(32,'t_eip'),(44,'t_esp')]
    a.lbl('timer_handler')
    a.raw(0x60)                                            # pusha
    load_kdata()
    a.raw(0xF6,0x44,0x24,0x24,0x03); a.j(JE,'timer_kpriv') # CPL0 tick (cs RPL==0) -> no preempt
    if mut=='noswitch':
        a.j(None,'timer_kpriv')                           # M-noswitch: EOI+iret without switching
    a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))           # ecx = cur (TCB index)
    fields = MIN if mut=='minimal' else ([f for f in GP if f[1]!='t_eflags'] if mut=='noeflags' else GP)
    for off,nm in fields:
        a.raw(0x8B,0x44,0x24,off)                          # mov eax,[esp+off]
        st(arr(nm),'ecx','eax')                            # TCB[cur].nm = eax  (indexed)
    a.raw(0xB0,0x20,0xE6,0x20)                             # EOI
    a.j(None,'sched_switch')
    a.lbl('timer_kpriv')
    a.raw(0xB0,0x20,0xE6,0x20); a.raw(0x61); a.raw(0xCF)   # EOI; popa; iret

    # ===== shared SCHED-SWITCH: WAKE a ready blocked reader, round-robin pick, flip pages, restore/fresh, iret =====
    a.lbl('sched_switch')
    # ---- WAKE arm + idle entry (furlough): re-poll COM1 LSR; if a byte is ready AND a proc is blocked, deliver it
    #      into the wakee's saved t_eax and unblock it. DS is always KDATA here (every caller load_kdata's first). ----
    a.lbl('sw_wake')
    a.blob(bytes.fromhex('66bafd03ec'))                    # mov dx,0x3fd; in al,dx  (LSR)
    a.raw(0xA8,0x01); a.j(JE,'sw_pickstart')               # test al,1; jz -> no byte ready -> go pick
    a.raw(0x31,0xF6)                                       # xor esi,esi  (scan index w)
    a.lbl('sw_wscan')
    a.raw(0x3B,0x35); a.blob(le32(cell('nprocs'))); a.j(JAE,'sw_pickstart')   # w >= K -> nobody blocked, leave the byte
    ld('eax',arr('blocked'),'esi'); a.raw(0x85,0xC0); a.j(JNE,'sw_wfound')    # blocked[w]!=0 -> found the parked reader
    a.raw(0x46); a.j(None,'sw_wscan')                      # inc esi
    a.lbl('sw_wfound')
    a.blob(bytes.fromhex('66baf803ec'))                    # mov dx,0x3f8; in al,dx  (read RBR; clobbers dx, w is in esi)
    a.raw(0x0F,0xB6,0xC0)                                  # movzx eax,al  (the delivered byte)
    a.raw(0x89,0xC3)                                       # mov ebx,eax   (save byte for the witness)
    if mut!='nodeliver':
        st(arr('t_eax'),'esi','eax')                       # t_eax[w] = byte  (DELIVER into the wakee's saved eax slot)
        #   M-nodeliver: omit -> w resumes via do_restore with a STALE t_eax (garbage byte) -> wrong output (RED)
    outi(0xCC)                                             # wake witness: CC <w> <byte> CD
    a.raw(0x89,0xF0); dr_eax()                             # eax=w; dump
    a.raw(0x89,0xD8); dr_eax()                             # eax=byte; dump
    outi(0xCD)
    if mut!='nowake':
        a.raw(0xC7,0x04,0xB5); a.blob(le32(arr('blocked'))); a.blob(le32(0))   # blocked[w] = 0  (UNBLOCK -> runnable)
        #   M-nowake: omit -> w stays blocked, the pick never schedules it -> the reader never resumes (RED)
    # ---- pick: ecx = next runnable proc after cur (round-robin); skip exited / blocked / region-less ----
    a.lbl('sw_pickstart')
    if mut=='norobin':                                     # M-norobin: toggle 0<->1 (tickover-style) -> starves proc>=2
        a.raw(0x8B,0x0D); a.blob(le32(cell('cur'))); a.raw(0x83,0xF1,0x01)   # ecx=cur; xor ecx,1
    else:
        a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))        # ecx = cur
        a.raw(0xBF); a.blob(le32(MAXPROC+1))               # edi = idle budget (>= a full cycle; exhausted -> all parked)
        a.lbl('pick')
        a.raw(0x41)                                        # inc ecx
        a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JB,'nowrap')   # ecx < K?
        a.raw(0x31,0xC9)                                   # ecx = 0 (wrap)
        a.lbl('nowrap')
        a.raw(0x4F); a.j(JS,'sw_idle')                     # dec edi; js -> a full cycle found NO runnable proc -> idle
        ld('eax',arr('exited'),'ecx'); a.raw(0x85,0xC0); a.j(JNE,'pick')   # exited[ecx] -> keep looking
        # furlough BLOCKED-skip: a parked reader (blocked[ecx]!=0) is NOT schedulable -> keep looking. This is the new
        # scheduler verb: the runnable SET shrinks/grows on I/O state. M-noskipblk INVERTS it (jne->je, byte-length
        # identical): it now skips RUNNABLE procs and PICKS a blocked one -> do_restore resumes a parked reader at a
        # wrong/blocked point -> RED.
        ld('eax',arr('blocked'),'ecx'); a.raw(0x85,0xC0); a.j(JE if mut=='noskipblk' else JNE,'pick')
        # tenement WAITING-skip (inherited; inert when MSLOTS=MAXPROC so every proc owns a region): alloc_lo[ecx]==0
        # -> not schedulable. M-noskip INVERTS it (jz->jnz).
        ld('eax',arr('alloc_lo'),'ecx'); a.raw(0x85,0xC0); a.j(JNE if mut=='noskip' else JE,'pick')
    # ---- a runnable proc ecx was picked: count the dispatch (global switch counter + per-proc disp[]) ----
    a.raw(0xFF,0x05); a.blob(le32(cell('switches')))       # inc [switches]
    a.raw(0xFF,0x04,0x8D); a.blob(le32(arr('disp')))       # inc dword[disp + ecx*4]  (per-proc DISPATCH counter)
    # flip: clear cur's pages Super, set next(ecx)'s pages User
    if mut!='noflip':
        a.raw(0x8B,0x15); a.blob(le32(cell('cur')))        # edx = cur
        flip_pg(arr('modstart'),'edx',False); flip_pg(arr('alloc_lo'),'edx',False)
        flip_pg(arr('modstart'),'ecx',True);  flip_pg(arr('alloc_lo'),'ecx',True)
    a.raw(0x89,0x0D); a.blob(le32(cell('cur')))            # cur = next (ecx)
    if mut!='nocr3':
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)   # reload cr3
    ld('eax',arr('started'),'ecx'); a.raw(0x85,0xC0); a.j(JNE,'do_restore')   # started? -> restore
    # fresh start: started[ecx]=1; build a fresh CPL3 frame (entry, stack, IF=1, zero GP)
    a.raw(0xC7,0x04,0x8D); a.blob(le32(arr('started'))); a.blob(le32(1))      # started[ecx]=1
    a.raw(0xBC); a.blob(le32(kstack)); load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))
    pushidx(arr('alloc_hi'),'ecx')                         # useresp = stack top
    a.raw(0x68); a.blob(le32(0x00000002 if mut=='coop' else 0x00000202))     # eflags
    a.raw(0x68); a.blob(le32(UCODE3))
    pushidx(arr('modstart'),'ecx')                         # eip = entry
    for _ in range(8): a.raw(0x68); a.blob(le32(0))        # zero GP
    a.raw(0x61); a.raw(0xCF)                               # popa; iret -> fresh proc
    a.lbl('do_restore')
    a.raw(0xBC); a.blob(le32(kstack)); load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))                      # push ss
    pushidx(arr('t_esp'),'ecx')                            # push useresp
    if mut!='noeflags2': pushidx(arr('t_eflags'),'ecx')    # push eflags
    else: a.raw(0x68); a.blob(le32(0x202))
    a.raw(0x68); a.blob(le32(UCODE3))                      # push cs
    pushidx(arr('t_eip'),'ecx')                            # push eip
    for nm in ('t_eax','t_ecx','t_edx','t_ebx'): pushidx(arr(nm),'ecx')
    a.raw(0x68); a.blob(le32(0))                           # esp_dummy
    for nm in ('t_ebp','t_esi','t_edi'): pushidx(arr(nm),'ecx')
    a.raw(0x61)                                            # popa
    a.raw(0xCF)                                            # iretd -> CPL3 proc at its preempt point
    # ---- IDLE stub: all procs are parked/exited; loop back to the wake re-poll (poll COM1 until a byte wakes one). ----
    a.lbl('sw_idle')
    a.j(None,'sw_wake')

    # ===== #GP / #PF / panic fault->continue (VERBATIM tickover/geeking) =====
    a.lbl('gp_handler')
    load_kdata(); outi(0xF0)
    a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax(); a.raw(0x8B,0x44,0x24,0x08); dr_eax(); a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xF1)
    a.raw(0xF6,0x44,0x24,0x08,0x03); a.j(JE,'gp_kpanic')
    a.raw(0xB0,0x47); a.raw(0xA2); a.blob(le32(ANSWER))
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('gp_kpanic'); a.j(None,'sdtail')
    a.lbl('pf_handler')
    # ===== homestead DEMAND-COMMIT branch (the heart): try to commit-on-fault BEFORE the terminal kill. The CPU does
    #   NOT save GP regs on #PF and we IRET-RESUME the faulting instruction, so we pusha/popa to preserve the user's
    #   full GP state across the commit. After pusha the IRET frame is at [esp+0x20..]: err=[esp+0x20] eip=[esp+0x24]
    #   cs=[esp+0x28] eflags=[esp+0x2C] useresp=[esp+0x30]. The terminal path below is UNCHANGED (fallthrough). =====
    if mut!='nogrow':
        a.raw(0x60)                                        # pusha (save user GP; err/IRET frame now at [esp+0x20..])
        load_kdata()                                       # DS=KDATA to reach kernel cells (clobbers eax; popa restores)
        a.raw(0xF6,0x44,0x24,0x20,0x01); a.j(JNE,'pf_nodemand')   # test byte[esp+0x20],1 ; err.P!=0 -> not not-present
        a.raw(0x0F,0x20,0xD0)                              # eax = cr2 (faulting linear addr)
        a.raw(0x8B,0x15); a.blob(le32(cell('cur')))        # edx = cur (active proc)
        ld('ecx',arr('grow_floor'),'edx'); a.raw(0x39,0xC8); a.j(JB,'pf_nodemand')   # cr2 < grow_floor[cur] -> outside
        ld('ecx',arr('alloc_lo'),'edx');   a.raw(0x39,0xC8); a.j(JAE,'pf_nodemand')  # cr2 >= alloc_lo[cur] -> outside
        # COMMIT: pte = pt + (cr2>>12)*4 ; pte_before -> witness ; pte = (cr2 & ~0xFFF) | 7 ; pte_after -> witness
        a.raw(0x89,0xC1)                                   # ecx = cr2
        a.raw(0xC1,0xE9,0x0A); a.raw(0x83,0xE1,0xFC); a.raw(0x81,0xC1); a.absR('pt')   # ecx = pt + (cr2>>12)*4 (pte addr)
        outi(0xC2)
        a.raw(0x8B,0x44,0x24,0x20); dr_eax()              # witness err  (= [esp+0x20])
        a.raw(0x0F,0x20,0xD0); dr_eax()                   # witness cr2
        a.raw(0x8B,0x01); dr_eax()                        # witness pte_before (BEFORE the store; must be P==0)
        a.raw(0x0F,0x20,0xD0); a.raw(0x25); a.blob(le32(0xFFFFF000)); a.raw(0x83,0xC8,0x07)  # eax=(cr2&~0xFFF)|7
        a.raw(0x89,0x01)                                   # mov [pte],eax  (COMMIT: present+RW+User, identity frame)
        dr_eax()                                          # witness pte_after (AFTER the store; must be P==1)
        outi(0xC3)
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)   # reload cr3 (TLB flush so the resumed push sees the commit)
        # descend the committed-stack floor to the FAULTING page base: alloc_lo[cur] = cr2 & ~0xFFF. For contiguous
        # stack growth (a push faults on the first byte of the next page down) this equals alloc_lo-0x1000; but binding
        # the floor to the ACTUAL faulting page (not a blind -0x1000) is correct even if a fault lands >1 page below
        # (e.g. a large `sub esp`), so the floor (and thus SYS_WRITE's access_ok bound) always tracks the real
        # committed frontier with no metadata desync (Codex cross-model review caught the blind-subtract edge case).
        a.raw(0x8B,0x15); a.blob(le32(cell('cur')))        # edx = cur
        a.raw(0x0F,0x20,0xD0); a.raw(0x25); a.blob(le32(0xFFFFF000))   # eax = cr2 & ~0xFFF (faulting page base)
        st(arr('alloc_lo'),'edx','eax')                    # alloc_lo[cur] = page(cr2)
        load_udata()                                       # restore user DS/ES/FS/GS (= UDATA3) before resuming CPL3
        a.raw(0x61)                                        # popa (restore user GP)
        a.raw(0x83,0xC4,0x04)                              # add esp,4 (drop the err code)
        a.raw(0xCF)                                        # iretd -> re-execute the faulting push (now demand-committed)
        a.lbl('pf_nodemand')
        # ===== cleave COW ARM (THE LINK'S CORE): a write-protection #PF (err P=1, W=1, U=1) on the read-only VR page ->
        #   allocate a FRESH frame F' from the COW pool (cow_next), COPY the shared frame F -> F' (4096 B), remap
        #   PTE[VR] <- F'|7 (private + writable), and IRET-resume the faulting store, which now lands in F'. VW still
        #   maps F (UNCHANGED) -- the divergence the prober observes. The CPU did not save GP on #PF and we iret-resume,
        #   so the pusha/popa preserves the user's full GP across the copy.
        #   M-nocopy: skip the copy (just flip VR writable over the SHARED F) -> the store lands in F -> VW reads the
        #     marker too -> RED (the Codex-named forge; proves the COPY is load-bearing, not just the permission flip).
        #   M-noremap: copy but don't remap -> the resumed store re-faults on the still-RO VR -> re-COW / kill -> RED. =====
        a.raw(0xF6,0x44,0x24,0x20,0x02); a.j(JE,'pf_kill')  # err.W==0 (read fault) -> not a COW write -> terminal kill
        a.raw(0xF6,0x44,0x24,0x20,0x01); a.j(JE,'pf_kill')  # err.P==0 (not-present) -> not a COW protection fault -> kill
        a.raw(0xF6,0x44,0x24,0x20,0x04); a.j(JE,'pf_kill')  # err.U==0 (SUPERVISOR) -> not a CPL3 COW store -> kill. SOUNDNESS
        #   (cross-model Codex): with CR0.WP=1 a kernel write to a read-only page faults P=1,W=1,U=0; without this gate the
        #   arm would wrongly COW a kernel access. No in-scenario CPL0 path writes linear VR, so this is a robustness rail.
        a.raw(0x0F,0x20,0xD0); a.raw(0x25); a.blob(le32(0xFFFFF000))        # eax = cr2 & ~0xFFF (faulting page base)
        a.raw(0x3D); a.blob(le32(SH_VB & 0xFFFFF000)); a.j(JNE,'pf_kill')   # cr2 page != VR page -> not COW (only VR) -> kill
        a.raw(0xB9); a.absR('pt',(SH_VB>>12)*4)            # ecx = pte_addr (VR's PTE entry; a constant)
        a.raw(0x8B,0x31); a.raw(0x81,0xE6); a.blob(le32(0xFFFFF000))        # esi = [pte_addr] & ~0xFFF  (F, the shared frame)
        a.raw(0x8B,0x3D); a.blob(le32(cell('cow_next')))   # edi = [cow_next]  (F', the fresh copy frame)
        a.raw(0x81,0xFF); a.blob(le32(COW_POOL+COW_POOL_N*0x1000)); a.j(JAE,'pf_kill')  # cow_next exhausted -> kill, never
        #   overrun the reserved pool (cross-model Codex; in-scenario the prober faults once so 1 <= COW_POOL_N=4, a rail)
        outi(0xC8)                                         # COW witness frame: C8 <cr2> <F> <F'> C9
        a.raw(0x0F,0x20,0xD0); dr_eax()                    # witness cr2
        a.raw(0x89,0xF0); dr_eax()                         # witness F  (esi, the shared frame)
        a.raw(0x89,0xF8); dr_eax()                         # witness F' (edi, the private copy)
        outi(0xC9)
        if mut!='nocopy':
            a.raw(0x56); a.raw(0x57)                       # push esi; push edi  (rep movsd clobbers esi/edi)
            cnt = (SH_N+1) if mut=='shortcopy' else 1024   # M-shortcopy: copy only the first few words, NOT the full page ->
            a.raw(0xB9); a.blob(le32(cnt)); a.raw(0xFC); a.raw(0xF3,0xA5)   # mov ecx,cnt; cld; rep movsd (F -> F'); the deep
            a.raw(0x5F); a.raw(0x5E)                       # pop edi; pop esi   word at offset 0xFFC is left uncopied -> RED
        if mut!='noremap':
            if mut=='cowshare': a.raw(0x89,0xF0)           # M-cowshare (the Codex forge): eax = F (esi, the SHARED frame)
            else:               a.raw(0x89,0xF8)           #   -- "flip VR writable WITHOUT a private copy"; else F' (edi)
            a.raw(0x83,0xC8,0x07)                          # or eax,7  (present+RW+User)
            a.raw(0xB9); a.absR('pt',(SH_VB>>12)*4)        # ecx = pte_addr
            a.raw(0x89,0x01)                               # mov [pte_addr], eax   (remap VR; cowshare -> shared F -> VW reads MARK -> RED)
        a.raw(0x81,0x05); a.blob(le32(cell('cow_next'))); a.blob(le32(0x1000))   # cow_next += 0x1000 (bump the copy pool)
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)   # reload cr3 (TLB flush so the resumed store sees the remap)
        load_udata()                                       # restore user DS/ES/FS/GS before resuming CPL3
        a.raw(0x61)                                        # popa (restore user GP)
        a.raw(0x83,0xC4,0x04)                              # add esp,4 (drop the err code)
        a.raw(0xCF)                                        # iretd -> re-execute the faulting store (now into F', writable)
        a.lbl('pf_kill')
        load_udata()                                       # not a COW fault: restore user segs, unwind pusha, fall
        a.raw(0x61)                                        #   through to the EXISTING terminal kill (which reloads all)
    # ----- EXISTING terminal kill (geeking/tenement fault->continue): dump the D0 witness frame, answer 'P', reset -----
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

    # ===== descriptor tables (VERBATIM tickover) =====
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


def build_elf(mut=None, stage='full'):
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


# ============================ PARSE (STEP-0 head grade) ============================
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
def _wframes(tail):
    out=[];pos=0
    while True:
        j=tail.find(b'\xD4',pos)
        if j<0: break
        if j+17>len(tail): break
        ln,cs,eip,esp=struct.unpack('<4I',tail[j+1:j+17]); body=tail[j+17:j+17+ln]
        closed=tail[j+17+ln:j+18+ln]==b'\xD5'
        out.append(dict(ln=ln,cs=cs,eip=eip,esp=esp,body=body,closed=closed,at=j)); pos=j+18+ln
    return out

def grade(stream, kend_elf, K, seed=0x501CA1):
    """FULL grade (timing-robust, per-program COMPLETENESS -- NOT interleave order):
       - K parsed; K distinct 1-page regions; no overlap; module-disjoint; within the identity map.
       - proc 0 (SPINNER) emitted EXACTLY le32(VA) once (full GP+eflags survived the preempt + indexed-TCB restore).
       - each proc i in 1..K-1 (WORKER) emitted its held-back token WREPS times (it RAN = preemption got the CPU off
         the non-yielding spinner; a cooperative kernel hangs -> M-coop RED). Distinct per-worker tokens => not bakeable.
       - NO write-frame outside the K modules' eip-ranges (no phantom (K+1)th program).
       - switch counter >= K (>=1 preempt + the exit-switch chain); answer == 0 (clean spinner exit)."""
    errs=[]
    r=parse_head(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or hung on the spinner -> NO preemption?)']
    if r['nprocs']!=K: errs.append(f'nprocs={r["nprocs"]} != K={K}')
    regions=[(parr(r,'alloc_lo',i),parr(r,'alloc_hi',i)) for i in range(K)]
    mods=[(parr(r,'modstart',i),parr(r,'modend',i)) for i in range(K)]
    for i in range(K):
        lo,hi=regions[i]
        if hi-lo!=0x1000: errs.append(f'region[{i}] != 1 page')
        if not (0x100000<=lo and hi<=NPT*0x400000): errs.append(f'region[{i}] outside identity map')
    for i in range(K):
        for j in range(i+1,K):
            a0,a1=regions[i]; b0,b1=regions[j]
            if a0<b1 and b0<a1: errs.append(f'region[{i}]/region[{j}] OVERLAP')
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==4 and w['cs']==UCODE3 and (w['cs']&3)==3]
    tagged=[None]*len(wfs)
    for wi,w in enumerate(wfs):
        for i in range(K):
            ms,me=mods[i]
            if ms<=w['eip']<me: tagged[wi]=i; break
    untag=[w for wi,w in enumerate(wfs) if tagged[wi] is None]
    if untag: errs.append(f'{len(untag)} write-frame(s) from NO known module eip-range (phantom program?)')
    # proc 0 = spinner
    sp=[w for wi,w in enumerate(wfs) if tagged[wi]==0]
    if len(sp)!=1: errs.append(f'spinner(proc0) wrote {len(sp)} frames != 1 (not woken, or full-ctx lost across preempt)')
    elif sp[0]['body']!=le32(VA): errs.append(f'spinner wrote {sp[0]["body"].hex()} != le32(VA) {le32(VA).hex()} (GP/eflags NOT preserved)')
    # procs 1..K-1 = workers
    toks=worker_tokens(K,seed)
    for i in range(1,K):
        wi_frames=[w for wi,w in enumerate(wfs) if tagged[wi]==i]
        want=le32(toks[i-1])
        if len(wi_frames)!=WREPS: errs.append(f'worker(proc{i}) wrote {len(wi_frames)} frames != WREPS={WREPS} (STARVED -> no preemption / run-queue skipped it?)')
        for w in wi_frames:
            if w['body']!=want: errs.append(f'worker(proc{i}) wrote {w["body"].hex()} != le32(token) {want.hex()}')
            lo,hi=regions[i]
            if not (lo<=w['esp']<hi): errs.append(f'worker(proc{i}) write esp 0x{w["esp"]:x} not in region[{i}]')
    m=re.search(rb'\xC8(.{4})\xC9', tail, re.S)
    if not m: errs.append('no switch-counter frame (C8<sw>C9)')
    else:
        sw=struct.unpack('<I',m.group(1))[0]
        if sw < K: errs.append(f'context switches {sw} < K={K} (run-queue did not advance through all procs)')
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if not an or an.group(1)[0]!=0: errs.append(f'answer {an.group(1)[0] if an else None} != 0 (spinner exit status)')
    return errs

def grade_hostile(stream, kend_elf, kind='write'):
    """proc0 (active/User) accessing a PEER region (Supervisor while proc0 runs) must #PF -- the un-fakeable peer
       isolation proof. WRITE -> err 7, READ -> err 5; CR2 in SOME peer region (not proc0's, not kernel); RPL3."""
    errs=[]; r=parse_head(stream)
    if not r: return ['no OWN table parsed']
    K=r['nprocs']; regions=[(parr(r,'alloc_lo',i),parr(r,'alloc_hi',i)) for i in range(K)]; tail=r['_tail']
    want_err=5 if kind=='read' else 7
    pf=re.search(rb'\xD0(.{4})(.{4})(.{4})(.{4})(.{4})\xD1', tail, re.S)
    if not pf: return [f'no #PF witness (D0..D1) -- the hostile {kind} did NOT fault (isolation BROKEN)']
    err,eip,cs,cr2,esp=[struct.unpack('<I',pf.group(k))[0] for k in (1,2,3,4,5)]
    if err!=want_err: errs.append(f'#PF err 0x{err:x} != exact 0x{want_err:x}')
    if (cs&3)!=3: errs.append(f'#PF cs 0x{cs:x} RPL != 3')
    a0,a1=regions[0]
    if a0<=cr2<a1: errs.append(f'#PF CR2 0x{cr2:x} in proc0 OWN region (not a peer fault)')
    if 0x100000<=cr2<kend_elf: errs.append(f'#PF CR2 0x{cr2:x} in kernel image (not a peer fault)')
    if not any(lo<=cr2<hi for j,(lo,hi) in enumerate(regions) if j!=0):
        errs.append(f'#PF CR2 0x{cr2:x} not in ANY peer region')
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if not an or an.group(1)[0]!=0x50: errs.append('answer != 0x50 (P) -- fault->continue did not name the #PF')
    return errs

def assert_rollcall(kelf):
    """White-box structural smoke test (the byte-pin to build_elf() is the PRIMARY binding; this survives an emitter
       that fakes the bytes another way). Pins the RUNTIME-K PROCESS TABLE + RUN-QUEUE -- distinct from tickover's
       hardcoded-2 (unrolled a_*/b_* cells, cur^=1):
         - mods_count read + a MAXPROC bound (proves K is a RUNTIME value, not a compile-time constant);
         - NO `mods_count == <const>` hard-assert (tickover/tandem's 8B 46 14 83 F8 01/02);
         - an INDEXED module-table STORE (89 04 8D <modstart_base> -- the data-driven K-parse loop);
         - an INDEXED run-queue READ of exited[] (8B 04 8D <exited_base> -- the round-robin scheduler over the table);
         - an INDEXED TCB STORE (89 04 8D <t_eip_base> -- save_ctx[cur], the per-process TCB array)."""
    def idx_st(base): return bytes([0x89,0x04,0x8D])+le32(base)   # mov [base+ecx*4],eax
    def idx_ld(base): return bytes([0x8B,0x04,0x8D])+le32(base)   # mov eax,[base+ecx*4]
    if bytes([0x8B,0x46,0x14,0x83,0xF8,MAXPROC]) not in kelf: return False   # mods_count read + MAXPROC bound
    if bytes([0x8B,0x46,0x14,0x83,0xF8,0x02]) in kelf: return False          # no ==2 hard-assert (tandem/tickover)
    if bytes([0x8B,0x46,0x14,0x83,0xF8,0x01]) in kelf: return False          # no ==1 hard-assert (single-program)
    if idx_st(arr('modstart')) not in kelf: return False                    # indexed module-table store
    if idx_ld(arr('exited')) not in kelf: return False                      # indexed run-queue read (round-robin)
    if idx_st(arr('t_eip')) not in kelf: return False                       # indexed TCB store (save_ctx[cur])
    return True

def assert_tenement(kelf):
    """White-box structural smoke test for tenement's NEW reclamation capability (the byte-pin to build_elf() is the
       PRIMARY binding; this survives a forge that fakes the bytes another way). Pins MEMORY RECLAMATION -- distinct
       from rollcall (which mints K pages, one per proc, and never hands one over):
         - the RECLAIM HANDOFF: an indexed alloc_lo STORE keyed by the SCANNED waiting index edx
           (89 04 95 <alloc_lo_base> == `mov [alloc_lo+edx*4],eax`), preceded by an indexed alloc_lo LOAD from cur
           (8B 04 8D <alloc_lo_base> == `mov eax,[alloc_lo+ecx*4]`) -- i.e. cur's region is COPIED to a waiting proc.
           rollcall has no edx-indexed alloc_lo store (no handoff). A forge omitting the handoff fails this.
         - the WAITING-SKIP in the scheduler pick: an indexed alloc_lo READ keyed by ecx gating the round-robin pick
           (8B 04 8D <alloc_lo_base> followed by `test eax,eax; jz` == 85 C0 0F 84) -- sched consults alloc_lo[ecx],
           distinct from rollcall whose pick only consults exited[ecx]. A forge omitting the skip fails this.
         - the MSLOTS-BOUNDED allocation: `mov eax,MSLOTS` (B8 <MSLOTS imm32>) feeding the min(MSLOTS,nprocs)
           computation (3B 05 <nprocs> == `cmp eax,[nprocs]`), and the alloc loop bounded by [tmp0]=min not [nprocs]
           (3B 3D <tmp0> == `cmp edi,[tmp0]`). Pins that only M<N pages are minted (the rest start WAITING).
       Returns True/False."""
    def idx_st_edx(base): return bytes([0x89,0x04,0x95])+le32(base)   # mov [base+edx*4],eax  (handoff, scanned idx)
    def idx_ld_ecx(base): return bytes([0x8B,0x04,0x8D])+le32(base)   # mov eax,[base+ecx*4]
    ALO=arr('alloc_lo'); AHI=arr('alloc_hi')
    # (1) reclaim handoff -- a CONTIGUOUS REACHABLE motif (pin-reachability-not-presence, Codex red-team): the FULL
    #     two-half region copy cur->w must appear as ONE adjacent block: alloc_lo[w]<-alloc_lo[cur] THEN
    #     alloc_hi[w]<-alloc_hi[cur]. Requiring BOTH halves contiguous (a) proves the handoff is a real reachable unit
    #     (not two stray bytes) and (b) CATCHES M-noremap (which omits the alloc_hi store -> motif absent). rollcall has
    #     no edx-indexed alloc_lo/alloc_hi store at all. 28 bytes: 8B048D<lo> 890495<lo> 8B048D<hi> 890495<hi>.
    handoff = idx_ld_ecx(ALO)+idx_st_edx(ALO)+idx_ld_ecx(AHI)+idx_st_edx(AHI)
    if handoff not in kelf: return False
    # (2) WAITING-skip in the pick: an indexed alloc_lo READ keyed by ecx, then `test eax,eax; jz` gating the pick
    if (idx_ld_ecx(ALO)+bytes([0x85,0xC0,0x0F,0x84])) not in kelf: return False
    # (3) MSLOTS-bounded allocation: mov eax,MSLOTS feeding min(MSLOTS,nprocs); the alloc loop reads [tmp0] as bound
    if (bytes([0xB8])+le32(MSLOTS)+bytes([0x3B,0x05])+le32(cell('nprocs'))) not in kelf: return False
    if (bytes([0x3B,0x3D])+le32(cell('tmp0'))) not in kelf: return False
    return True


def assert_homestead(kelf):
    """White-box structural smoke test for homestead's NEW demand-paging capability (the byte-pin to build_elf() is
       the PRIMARY binding; this survives a forge that fakes the bytes another way). Pins GENUINE DEMAND PAGING --
       distinct from tenement/mumbani, which only EVER toggle the User bit (`or dword[pte],4` / `and ~4`) on
       ALWAYS-PRESENT pages and never fault not-present nor install a frame:
         - the BOOT P-CLEAR of the grow window: `and dword[ecx],~1` (83 21 FE) -- clears the Present bit so a stack
           push into the window faults NOT-PRESENT (no prior kernel ever clears Present anywhere). M-eager (eager-map
           the window present) and M-noclear (skip the clear) both LACK this byte.
         - the #PF NOT-PRESENT gate: `test byte[esp+0x20],1` (F6 44 24 20 01) -- the demand branch fires only on an
           err.P==0 fault. M-nogrow (no demand branch) LACKS this.
         - the DEMAND COMMIT value+store: `mov eax,cr2; and eax,~0xFFF; or eax,7; mov [ecx],eax`
           (0F 20 D0 25 00 F0 FF FF 83 C8 07 89 01) -- installs a PRESENT+RW+User identity frame at the faulting page.
           A U/S-flip forge (tenement's `or [pte],4`) cannot produce this present-install motif.
       Returns True/False."""
    pclear   = bytes([0x83,0x21,0xFE])                                  # and dword[ecx],~1  (boot P-clear)
    npgate   = bytes([0xF6,0x44,0x24,0x20,0x01])                        # test byte[esp+0x20],1  (err.P==0 gate)
    commit   = bytes([0x0F,0x20,0xD0,0x25,0x00,0xF0,0xFF,0xFF,0x83,0xC8,0x07,0x89,0x01])  # cr2->present+RW+User PTE
    if pclear not in kelf: return False
    if npgate not in kelf: return False
    if commit not in kelf: return False
    return True


def grade_head(stream, kend_elf, K):
    """STEP-0 head grade: K parsed, K distinct 1-page regions, no overlap, all within the 16 MiB identity map."""
    errs=[]
    r=parse_head(stream)
    if not r: return ['no OWN table parsed (faulted before dump?)']
    if r['k1']!=kend_elf: errs.append(f'k1=0x{r["k1"]:x} != kend 0x{kend_elf:x}')
    if r['nprocs']!=K: errs.append(f'nprocs={r["nprocs"]} != K={K}')
    if not r['_blockok']: errs.append('cell block not closed (0x9B missing)')
    regions=[]
    for i in range(K):
        lo=parr(r,'alloc_lo',i); hi=parr(r,'alloc_hi',i)
        if hi-lo!=0x1000: errs.append(f'region[{i}] [0x{lo:x},0x{hi:x}) != 1 page')
        if not (0x100000<=lo and hi<=NPT*0x400000): errs.append(f'region[{i}] 0x{lo:x} outside identity map')
        regions.append((lo,hi))
    for i in range(K):
        for j in range(i+1,K):
            a0,a1=regions[i]; b0,b1=regions[j]
            if a0<b1 and b0<a1: errs.append(f'region[{i}] and region[{j}] OVERLAP')
    # regions must also exclude every module
    for i in range(K):
        ms=parr(r,'modstart',i); me=parr(r,'modend',i)
        for j,(lo,hi) in enumerate(regions):
            if lo<me and ms<hi: errs.append(f'region[{j}] OVERLAPS module[{i}] [0x{ms:x},0x{me:x})')
    return errs


def grade_ten(stream, kend_elf, N, M, seed=0x501CA1):
    """tenement FULL grade -- MEMORY RECLAMATION (physical page REUSE), N held-back-token WORKERS / M region slots,
       M<N (canonical N=6, M=MSLOTS=2). NO spinner: all N procs are workers. Graded TIMING-ROBUST on per-worker
       COMPLETENESS (every worker's full held-back token sequence present), NOT interleave order:
       - the OWN table parsed (kernel got through bump-alloc + dump -> no fault); nprocs==N.
       - ONLY M region pages minted at dump time (alloc_lo[0..M-1] != 0, alloc_lo[M..N-1] == 0 -> WAITING procs).
       - EVERY worker i in 0..N-1 emitted its HELD-BACK token worker_tokens(N,seed)[i] EXACTLY WREPS times, as closed
         UCODE3/RPL3 write-frames. Each frame is tagged to a worker BY ITS DISTINCT TOKEN VALUE (the un-bakeable pin:
         a no-reclaim kernel never schedules the WAITING worker, so its distinct token never appears -> that worker
         STARVED -> RED). A wrong/missing token => the page was not handed over.
       - the DISTINCT region page bases among ALL the write-frame esps number <= M: N programs ran inside <= M
         physical pages == genuine REUSE (a non-reclaiming kernel uses N pages, or starves waiters -> a token missing).
       - each write-frame esp lies within an allocated region page (one of the M minted slots).
       - the context-switch counter is present and >= N-1 (the run-queue advanced through all N workers via N-1
         inter-worker transitions; the boot iret into proc0 is not a switch); answer == 0 (clean last-worker exit).
       Returns (errs, sorted(distinct_pages)). The CLI prints GREEN/RED + the page list."""
    errs=[]
    r=parse_head(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or hung -> no reclaim?)'], []
    if r['nprocs']!=N: errs.append(f'nprocs={r["nprocs"]} != N={N}')
    # the M minted region pages (state captured at the dump, BEFORE any proc runs / any handoff)
    minted=[]
    for p in range(M):
        lo=parr(r,'alloc_lo',p); hi=parr(r,'alloc_hi',p)
        if hi-lo!=0x1000: errs.append(f'minted region[{p}] [0x{lo:x},0x{hi:x}) != 1 page')
        elif not (0x100000<=lo and hi<=NPT*0x400000): errs.append(f'minted region[{p}] 0x{lo:x} outside identity map')
        else: minted.append((lo,hi))
    for p in range(M,N):
        if parr(r,'alloc_lo',p)!=0:
            errs.append(f'proc{p} should start WAITING (alloc_lo==0) but minted 0x{parr(r,"alloc_lo",p):x} -- only M={M} pages should exist')
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==4 and w['cs']==UCODE3 and (w['cs']&3)==3]
    # TOKEN-VALUE tagging (the un-bakeable reuse pin): each worker emits its distinct held-back token; tag a write
    # frame to worker i iff its 4-byte body == le32(token[i]). A starved worker (never handed a page) emits NOTHING.
    toks=worker_tokens(N, seed)
    bytok={le32(toks[i]): i for i in range(N)}
    if len(bytok)!=N: errs.append(f'token collision: {N} workers but only {len(bytok)} distinct tokens (raise seed entropy)')
    counts=[0]*N; pages=set(); untagged=0; page_workers={}
    for w in wfs:
        i=bytok.get(w['body'])
        if i is None: untagged+=1; continue
        counts[i]+=1
        esp=w['esp']; base=esp & 0xFFFFF000; pages.add(base)
        page_workers.setdefault(base, set()).add(i)
        if not any(lo<=esp<hi for (lo,hi) in minted):
            errs.append(f'worker{i} write esp 0x{esp:x} not within any minted region page (esp not in a reclaimable page)')
    if untagged: errs.append(f'{untagged} write-frame(s) carry NO known worker token (phantom output / corrupted reuse)')
    for i in range(N):
        if counts[i]==0:
            errs.append(f'worker{i} STARVED -> emitted its held-back token 0x{toks[i]:06x} ZERO times (reclamation did NOT give it a page)')
        elif counts[i]!=WREPS:
            errs.append(f'worker{i} emitted token 0x{toks[i]:06x} {counts[i]} times != WREPS={WREPS} (partial run / page handed away mid-loop?)')
    # REUSE: distinct region page bases among ALL write-frame esps must be <= M
    if len(pages)>M:
        errs.append(f'{len(pages)} distinct region pages hosted the N={N} programs (>{M}) -- NO reuse (each proc got its own page?)')
    # REUSE-OVER-TIME witness (closes the pressure-pin-isn't-handoff gap): when N>M, each physical page must serve
    # MULTIPLE distinct workers (sequentially, as one exits and hands the page to the next), and ALL M minted pages
    # must be exercised. A forge that merely crams every worker into ONE pre-granted page (so it never reclaims) would
    # leave the other minted page unused (caught here); a forge giving each worker its own page is caught above by
    # distinct-pages>M. With N>M at least one minted page MUST host >=2 distinct workers.
    if N>M:
        for (lo,hi) in minted:
            wk=page_workers.get(lo, set())
            if len(wk)==0:
                errs.append(f'minted page 0x{lo:x} hosted NO worker -- reuse not spread across all {M} pages (forge crammed into fewer pages?)')
            elif len(wk)<2:
                errs.append(f'minted page 0x{lo:x} hosted only worker {sorted(wk)} (1 worker) -- that page was NOT reused over time (no handoff into it?)')
    # switch counter advanced through all N workers; answer clean. The run-queue advances proc0 -> proc1 -> ... ->
    # proc(N-1) via N-1 inter-worker transitions (the boot iret into proc0 is NOT a sched_switch). A starving kernel
    # produces far fewer than N-1 (and missing tokens); >= N-1 is the robust, timing-independent floor.
    m=re.search(rb'\xC8(.{4})\xC9', tail, re.S)
    if not m: errs.append('no switch-counter frame (C8<sw>C9)')
    else:
        sw=struct.unpack('<I',m.group(1))[0]
        if sw < N-1: errs.append(f'context switches {sw} < N-1={N-1} (run-queue did not advance through all {N} workers)')
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if not an or an.group(1)[0]!=0: errs.append(f'answer {an.group(1)[0] if an else None} != 0 (last worker exit status)')
    return errs, sorted(pages)


def _commit_frames(tail):
    """parse the homestead COMMIT WITNESS frames: 0xC2 <err:4> <cr2:4> <pte_before:4> <pte_after:4> 0xC3."""
    out=[]; pos=0
    while True:
        j=tail.find(b'\xC2',pos)
        if j<0: break
        if j+18>len(tail): break
        if tail[j+17]!=0xC3: pos=j+1; continue
        err,cr2,pb,pa=struct.unpack('<4I',tail[j+1:j+17])
        out.append(dict(err=err,cr2=cr2,pte_before=pb,pte_after=pa,at=j)); pos=j+18
    return out


def grade_homestead(stream, kend_elf, N=GROWER_N, seed=GROWER_SEED):
    """homestead FULL grade -- DEMAND-PAGED STACK GROWTH. The single recursive GROWER (proc0) reads a held-back seed
       byte via SYS_READ, recurses N deep (~N frames > 1 page), and emits N held-back words REVERSED on the unwind.
       GREEN requires ALL of:
       - the OWN table parsed (kernel got through bump-alloc + dump -> no early fault); nprocs>=1; grow_floor[0] sane.
       - the grower's FULL held-back output present: all N words grower_words(N,seed) as closed UCODE3/RPL3 le32
         write-frames, in emit order word(1)..word(N) -- proves it ran to FULL depth (the stack grew the whole way).
       - >= 1 COMMIT WITNESS (C2..C3) with err.P==0 (err&1==0), pte_before.P==0, pte_after.P==1, AND cr2 within
         proc0's grow window [grow_floor0, alloc_lo0_initial) -- proves DEMAND commit (not eager, not protection).
       - answer == 0 (clean grower exit); switch counter frame present.
       Returns (errs, ncommits). The CLI prints GREEN/RED + the commit count."""
    errs=[]
    r=parse_head(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or hung -> kernel never reached the grower?)'], 0
    if r['nprocs']<1: errs.append(f'nprocs={r["nprocs"]} < 1')
    gf0=parr(r,'grow_floor',0); alo0=parr(r,'alloc_lo',0); ahi0=parr(r,'alloc_hi',0)
    if ahi0-alo0!=0x1000: errs.append(f'committed region[0] [0x{alo0:x},0x{ahi0:x}) != 1 page')
    if alo0-gf0 != GROWBYTES: errs.append(f'grow window [0x{gf0:x},0x{alo0:x}) span 0x{alo0-gf0:x} != GROWMAX*0x1000=0x{GROWBYTES:x}')
    if not (0x100000<=gf0): errs.append(f'grow_floor 0x{gf0:x} below 0x100000')
    if not (ahi0<=NPT*0x400000): errs.append(f'committed region top 0x{ahi0:x} outside the 16 MiB identity map')
    tail=r['_tail']
    # the held-back N-word reversed stream as closed CPL3 write-frames (le32 bodies), in emit order
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==4 and w['cs']==UCODE3 and (w['cs']&3)==3]
    bodies=[struct.unpack('<I',w['body'])[0] for w in wfs]
    want=grower_words(N, seed)
    if len(bodies)!=N:
        errs.append(f'grower emitted {len(bodies)} write-frames != N={N} (stack did NOT grow to full depth -> '
                    f'killed mid-descent? partial unwind?)')
    # match the full sequence (order matters: emit order is word(1)..word(N))
    nmatch=sum(1 for a,b in zip(bodies,want) if a==b)
    if bodies[:N]!=want:
        # locate the first divergence for a precise message
        k=next((i for i in range(min(len(bodies),N)) if bodies[i]!=want[i]), min(len(bodies),N))
        errs.append(f'grower output diverges from the held-back stream at word {k} '
                    f'(got 0x{(bodies[k] if k<len(bodies) else 0):06x} want 0x{(want[k] if k<N else 0):06x}); '
                    f'{nmatch}/{N} words matched -- the held-back seed-derived stream was NOT fully produced')
    # write-frame esps must lie within the committed page OR a now-committed grow page (i.e. >= grow_floor0, < ahi0)
    for w in wfs:
        if not (gf0 <= w['esp'] < ahi0):
            errs.append(f'grower write esp 0x{w["esp"]:x} not within [grow_floor0 0x{gf0:x}, region_top 0x{ahi0:x})')
            break
    # the DEMAND-COMMIT witnesses (the temporal proof: pte_before.P==0 -> pte_after.P==1, fault was NOT-PRESENT)
    cfs=_commit_frames(tail)
    good=[c for c in cfs
          if (c['err'] & 1)==0                     # err.P==0  (NOT-PRESENT fault, not a protection fault)
          and (c['pte_before'] & 1)==0             # the PTE was not present BEFORE the commit (the temporal proof)
          and (c['pte_after'] & 1)==1              # ... and present AFTER
          and gf0 <= c['cr2'] < alo0]              # cr2 was inside proc0's GROW WINDOW (not the committed page/peer)
    # DEPTH-DERIVED floor (closes the 1-staged-fault hybrid the completeness critic raised): EVERY grow-window page the
    # stack actually WROTE INTO must have been genuinely demand-committed. A forge that commits one grow page then
    # EAGER-maps the rest present (so later pages never fault) emits the full output and rides one valid commit, but it
    # USED >=2 grow pages while producing <2 demand commits -> caught here. grow_pages_used is deterministic (a fixed
    # function of N and the frame size, identical on every substrate), so this floor is tight and non-flaky.
    grow_pages_used=sorted({w['esp'] & 0xFFFFF000 for w in wfs if w['esp'] < alo0})
    need=max(1, len(grow_pages_used))
    committed_pages={c['cr2'] & 0xFFFFF000 for c in good}
    if len(good) < need:
        errs.append(f'{len(cfs)} commit-witness frame(s), {len(good)} VALID demand commits but the stack WROTE INTO '
                    f'{len(grow_pages_used)} grow-window page(s) (need a genuine demand commit per used grow page; '
                    f'a forge that eager-maps some pages emits full output with too few commits) -- needs >= {need} '
                    f'(err.P==0, pte_before.P==0, pte_after.P==1, cr2 in [0x{gf0:x},0x{alo0:x}))')
    elif not set(grow_pages_used).issubset(committed_pages):
        miss=sorted(set(grow_pages_used)-committed_pages)
        errs.append(f'grow page(s) {[hex(p) for p in miss]} were WRITTEN INTO but never demand-committed (err.P==0 '
                    f'P=0->P=1) -- eager-mapped, not demand-grown')
    # detail-check each commit (catch a partially-malformed witness)
    for c in cfs:
        if (c['err'] & 1)!=0: errs.append(f'commit witness cr2=0x{c["cr2"]:x} err 0x{c["err"]:x} has P=1 (protection, not demand)')
        elif (c['pte_before'] & 1)!=0: errs.append(f'commit witness cr2=0x{c["cr2"]:x} pte_before 0x{c["pte_before"]:x} was ALREADY present (not demand)')
        elif (c['pte_after'] & 1)!=1: errs.append(f'commit witness cr2=0x{c["cr2"]:x} pte_after 0x{c["pte_after"]:x} NOT present after commit')
    m=re.search(rb'\xC8(.{4})\xC9', tail, re.S)
    if not m: errs.append('no switch-counter frame (C8<sw>C9) -- kernel did not run its scheduler')
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if not an or an.group(1)[0]!=0: errs.append(f'answer {an.group(1)[0] if an else None} != 0 (grower clean exit; 0x50=P means it was KILLED by a #PF)')
    return errs, len(good)


# ============================ THE FORCING MODULES ============================
# tenement's forcing has NO spinner: all N procs (0..N-1) are WORKERS, each emitting its own HELD-BACK random
# 24-bit token WREPS times then SYS_EXIT. With M=MSLOTS=2 region pages and N>M workers, the M slots are REUSED
# (~N/M workers per physical page) as each finished worker HANDS its region to the next WAITING worker. The workers
# running at all exercises preemption implicitly (their stack-counter loop is preempted by IRQ0), but the link
# WITNESSES is RECLAMATION -- N>M programs completing inside <=M physical pages.
VA=0x00CAFE                         # (legacy) spinner GP-survival marker, kept for the rollcall-style grade() below
MSI=0x515511; MDI=0xD1D1BB; MBP=0xB9B9CC; MBX=0xB8B8DD   # additional markers (esi/edi/ebp/ebx)
WREPS=3                             # each worker emits its held-back token this many times then exits
import random
def worker_tokens(N, seed=0x501CA1):
    # N distinct held-back random 24-bit tokens, ONE PER PROC (procs 0..N-1; tenement has no spinner). Baked into
    # each worker's own image; the byte-pinned kernel is module-agnostic and does NOT know N or the tokens at emit
    # time. Tagging a write-frame to a worker BY ITS DISTINCT TOKEN VALUE is the un-bakeable reuse pin (a no-reclaim
    # kernel cannot emit a starved worker's distinct token at all). (For the legacy rollcall-style grade() the
    # spinner is proc0 and workers 1..K-1 use tokens[0..K-2]; for the tenement grade_ten() worker i uses tokens[i].)
    rng=random.Random(seed)
    return [rng.randint(1,0x7F)|(rng.randint(1,0x7F)<<8)|(rng.randint(1,0x7F)<<16) for _ in range(N)]

def module_spinner():
    # proc 0: a register-carry SPINNER that NEVER yields. edx=VA + DF=1 + esi/edi/ebp/ebx markers held live across a
    # PURE spin; woken by the kernel writing its page-base stop-flag (set after all workers exit), then emits le32(edx)
    # IFF every marker + DF survived the preempt(s) + the indexed-TCB restore, else a sentinel. (Port of tickover's A.)
    m=Asm()
    m.raw(0xFD)                                   # std -> DF=1 (eflags survival marker)
    m.raw(0xBA); m.blob(le32(VA))                 # mov edx,VA
    m.raw(0xBE); m.blob(le32(MSI))                # mov esi,MSI
    m.raw(0xBF); m.blob(le32(MDI))                # mov edi,MDI
    m.raw(0xBD); m.blob(le32(MBP))                # mov ebp,MBP
    m.raw(0xBB); m.blob(le32(MBX))                # mov ebx,MBX
    m.lbl('spin')
    m.raw(0x89,0xE0)                              # mov eax,esp
    m.raw(0x2D); m.blob(le32(0x1000))             # sub eax,0x1000 -> page base
    m.raw(0x83,0x38,0x00)                         # cmp dword[eax],0
    m.j(JE,'spin')
    m.raw(0x9C); m.raw(0x58); m.raw(0xFC)         # pushf; pop eax; cld
    m.raw(0xF7,0xC0); m.blob(le32(0x400)); m.j(JE,'df_lost')   # test eax,DF
    m.raw(0x81,0xFE); m.blob(le32(MSI)); m.j(JNE,'df_lost')
    m.raw(0x81,0xFF); m.blob(le32(MDI)); m.j(JNE,'df_lost')
    m.raw(0x81,0xFD); m.blob(le32(MBP)); m.j(JNE,'df_lost')
    m.raw(0x81,0xFB); m.blob(le32(MBX)); m.j(JNE,'df_lost')
    m.raw(0x52); m.j(None,'a_write')              # push edx
    m.lbl('df_lost'); m.raw(0x68); m.blob(le32(0xBADBAD))
    m.lbl('a_write')
    m.raw(0x8D,0x0C,0x24)                         # lea ecx,[esp]
    m.raw(0xBA,0x04,0x00,0x00,0x00)               # mov edx,4
    m.raw(0xB8,0x02,0x00,0x00,0x00)               # mov eax,2 (SYS_WRITE)
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)
    m.raw(0xB3,0x00)                              # mov bl,0
    m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def module_worker(token, reps=WREPS):
    # a WORKER (procs 1..K-1): emit le32(token) `reps` times then SYS_EXIT. The loop counter is kept ON THE STACK
    # (the kernel clobbers caller GP across int 0x30, and a preempt can land mid-loop -- the counter rides the TCB
    # esp + the worker's own page). Running AT ALL proves preemption got the CPU off the non-yielding spinner.
    m=Asm()
    m.raw(0x68); m.blob(le32(reps))               # push reps (counter)
    m.lbl('wl')
    m.raw(0x83,0x3C,0x24,0x00); m.j(JE,'wd')      # cmp dword[esp],0 ; jz done
    m.raw(0x68); m.blob(le32(token))              # push token
    m.raw(0x8D,0x0C,0x24)                         # lea ecx,[esp]
    m.raw(0xBA,0x04,0x00,0x00,0x00)               # mov edx,4
    m.raw(0xB8,0x02,0x00,0x00,0x00)               # mov eax,2
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)                         # add esp,4
    m.raw(0xFF,0x0C,0x24)                         # dec dword[esp]
    m.j(None,'wl')
    m.lbl('wd')
    m.raw(0x83,0xC4,0x04)                         # add esp,4 (pop counter)
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    return m.assemble()[0]

# ---- HOSTILE-PEER probe: a variant spinner (proc 0, active/User) that writes proc 1's region (Supervisor while
# proc0 runs) -> #PF. esp = alloc_hi[0] = alloc_lo[1] (regions are contiguous in alloc order), so [esp+0x10] is in
# proc1's window. A single-address-space forge cannot produce a CR2-in-a-peer-window fault. ----
def module_hostile_peer():
    return bytes([0x89,0xE0, 0x05,0x10,0,0,0, 0xC7,0x00,0x44,0x33,0x22,0x11, 0xEB,0xFE])  # mov eax,esp; +0x10; mov[eax],imm; jmp$
def module_hostile_read():
    return bytes([0x89,0xE0, 0x05,0x10,0,0,0, 0x8B,0x18, 0xEB,0xFE])                       # mov eax,esp; +0x10; mov ebx,[eax]; jmp$

# ============================ homestead FORCING: the recursive GROWER ============================
# A CPL3 program that reads ONE held-back seed byte via SYS_READ over COM1, then recurses N deep (no loops / no TCO,
# so ~N stack frames), generating N distinct 24-bit words deterministically from the seed in-module and emitting them
# REVERSED on the unwind via SYS_WRITE. The recursion stack EXCEEDS one page (N chosen so N frames > 4096 B but fit
# GROWMAX pages) -> the stack MUST grow. On the FROZEN tenement kernel (1 committed page + terminal #PF) the descent
# faults mid-stack and is KILLED before emitting -> partial/zero output (THE DIFFERENTIAL). On homestead each
# over-page push demand-commits the next grow page and the FULL reversed stream comes out.
#
# Word generation (mirrored EXACTLY in grower_words() for the grader): a held-back-but-deterministic LCG seeded by the
# COM1 byte. word(k) for k=1..N is computed as the recursion unwinds; emit order is word(1),word(2),...,word(N) (the
# reverse of the descent order word(N)..word(1)). The seed is held back by the gate, so the N-word stream cannot be
# baked, compressed, or stream-reproduced; a kernel that cannot grow the stack cannot emit the deep words at all.
# (GROWER_N / GROWER_FRAME / GROWER_SEED are defined with the kernel constants near the top of the file.)

def grower_words(n, seed):
    # deterministic N distinct nonzero 24-bit words from the seed byte. Mirrors the in-module generator BYTE-FOR-BYTE.
    out=[]; x=(seed & 0xFF) | 0x010101
    for k in range(1, n+1):
        x = (x * 1103515245 + 12345 + k*2654435761) & 0xFFFFFFFF
        w = (x & 0x7F7F7F) | 0x010101            # 24-bit, every byte in 0x01..0x80 (nonzero, distinct, le32-safe)
        out.append(w)
    return out

def module_grower(n=GROWER_N, seed_unused=None):
    # A self-contained two-pass assembler (the shared Asm() builder has no `call`; recursion needs call/ret). All jumps
    # and the recursive call are PC-relative (E8/E9/0F-cc rel32), so the module is position-independent (the kernel
    # loads it at modstart, not ENTRY) -- exactly like the other hand-assembled fixtures.
    #
    # Layout (the GROWER program):
    #   _start:
    #     mov eax,0 ; int 0x30            ; SYS_READ -> seed byte in eax
    #     and eax,0xFF ; or eax,0x010101  ; x = (seed&0xFF)|0x010101  (the LCG state seed; matches grower_words)
    #     push eax                        ; [ebp-? ] keep x on the stack as the running LCG state... we keep x in a
    #                                     ; CALLEE-RECOMPUTED way instead (see below) so no register survives int 0x30.
    #     push N ; call rev ; add esp,4   ; rev(N)
    #     mov eax,1; mov bl,0; int 0x30   ; SYS_EXIT(0)
    #   rev:   ; arg k at [esp+4] on entry (after the call pushes return addr). k==0 -> ret.
    #     ... reserve GROWER_FRAME bytes, recurse rev(k-1), then COMPUTE+EMIT word(k) on the unwind ...
    #
    # We must NOT rely on any register surviving an int 0x30 (the kernel clobbers caller GP). So the running LCG state
    # is recomputed FROM SCRATCH on each unwind: word(k) is a pure function of (seed, k). We pass `seed_x` (the seeded
    # initial state x0 = (seed&0xFF)|0x010101) down the recursion ON THE STACK alongside k, and recompute the LCG
    # iterate for index k from x0 with a small inner loop -- O(k) per level, O(N^2) total but tiny N. This keeps the
    # emitted word independent of clobbered registers. word(k) = (lcg_k(x0) & 0x7F7F7F)|0x010101.
    code=bytearray(); labels={}; fixups=[]
    def emit(*b): code.extend(b)
    def lbl(n): labels[n]=len(code)
    def rel32(n):                                  # emit a 4-byte placeholder; record a fixup to label n
        fixups.append((len(code), n)); code.extend(b'\x00\x00\x00\x00')
    def call(n): emit(0xE8); rel32(n)
    def jmp(n):  emit(0xE9); rel32(n)
    def jcc(cc,n): emit(0x0F,cc); rel32(n)

    # ----- _start -----
    emit(0xB8,0,0,0,0)                             # mov eax,0  (SYS_READ)
    emit(0xCD,0x30)                                # int 0x30 -> seed byte in eax
    emit(0x25,0xFF,0,0,0)                          # and eax,0xFF
    emit(0x0D,0x01,0x01,0x01,0x00)                 # or  eax,0x010101  -> x0 (seeded LCG state)
    emit(0x89,0xC3)                                # mov ebx,eax       (x0 in ebx for the push; ebx not used across int)
    emit(0x53)                                     # push x0           (arg2 to rev: the seed state)
    emit(0x68); emit(*le32(n))                     # push N            (arg1 to rev: depth k)
    call('rev')                                    # rev(N, x0)
    emit(0x83,0xC4,0x08)                           # add esp,8         (pop the two args)
    emit(0xB8,0x01,0,0,0)                          # mov eax,1 (SYS_EXIT)
    emit(0xB3,0x00)                                # mov bl,0
    emit(0xCD,0x30)                                # int 0x30
    emit(0xEB,0xFE)                                # jmp $ (never reached)

    # ----- rev(k, x0):  on entry [esp+4]=k, [esp+8]=x0 (the call pushed the 4-byte return addr at [esp]) -----
    lbl('rev')
    emit(0x55)                                     # push ebp
    emit(0x89,0xE5)                                # mov ebp,esp        ; frame: [ebp+8]=k, [ebp+12]=x0
    emit(0x83,0xEC,GROWER_FRAME)                   # sub esp,GROWER_FRAME  (reserve frame -> forces the stack to grow)
    emit(0x8B,0x45,0x08)                           # mov eax,[ebp+8]    ; eax = k
    emit(0x85,0xC0)                                # test eax,eax
    jcc(JE,'rev_ret')                              # k==0 -> return (base case)
    # --- recurse rev(k-1, x0) FIRST (descend), so emit happens on the UNWIND (reversed order) ---
    emit(0xFF,0x75,0x0C)                           # push dword [ebp+12]  (x0)
    emit(0x8B,0x45,0x08); emit(0x48)              # mov eax,[ebp+8] ; dec eax  -> k-1
    emit(0x50)                                     # push eax           (k-1)
    call('rev')                                    # rev(k-1, x0)
    emit(0x83,0xC4,0x08)                           # add esp,8
    # --- on the unwind: compute word(k) = lcg iterate k times from x0, mask, emit le32 ---
    # ecx = k ; edx = x0 (running state). loop ecx times: x = x*1103515245 + 12345 + i*2654435761  (i = iteration#)
    emit(0x8B,0x4D,0x08)                           # mov ecx,[ebp+8]    ; ecx = k (iteration count)
    emit(0x8B,0x55,0x0C)                           # mov edx,[ebp+12]   ; edx = x0 (state)
    emit(0x31,0xFF)                                # xor edi,edi        ; edi = i (1..k); pre-inc below
    lbl('lcg')
    emit(0x47)                                     # inc edi            ; i++  (i runs 1..k)
    # x = x*1103515245
    emit(0x69,0xD2); emit(*le32(1103515245))       # imul edx,edx,1103515245
    emit(0x81,0xC2); emit(*le32(12345))            # add edx,12345
    # + i*2654435761
    emit(0x89,0xF8)                                # mov eax,edi
    emit(0x69,0xC0); emit(*le32(2654435761))       # imul eax,eax,2654435761
    emit(0x01,0xC2)                                # add edx,eax
    emit(0x39,0xCF)                                # cmp edi,ecx
    jcc(JB,'lcg')                                  # i < k -> keep iterating (so we do exactly k iterates)
    # word = (edx & 0x7F7F7F) | 0x010101
    emit(0x81,0xE2,0x7F,0x7F,0x7F,0x00)            # and edx,0x7F7F7F
    emit(0x81,0xCA,0x01,0x01,0x01,0x00)            # or  edx,0x010101
    emit(0x52)                                     # push edx           (the word, on the stack, to SYS_WRITE le32)
    emit(0x8D,0x0C,0x24)                           # lea ecx,[esp]      (buf = &word)
    emit(0xBA,0x04,0x00,0x00,0x00)                 # mov edx,4          (len)
    emit(0xB8,0x02,0x00,0x00,0x00)                 # mov eax,2          (SYS_WRITE)
    emit(0xCD,0x30)                                # int 0x30
    emit(0x83,0xC4,0x04)                           # add esp,4          (pop the word)
    lbl('rev_ret')
    emit(0x89,0xEC)                                # mov esp,ebp        (release frame)
    emit(0x5D)                                     # pop ebp
    emit(0xC3)                                     # ret
    # ----- resolve fixups (PC-relative) -----
    for at,name in fixups:
        disp = labels[name] - (at + 4)
        code[at:at+4] = struct.pack('<i', disp)
    return bytes(code)


# ============================ minimal STEP-0 modules ============================
def module_tiny(tag):
    # a tiny ring-3 program: SYS_WRITE(le32(tag)) then SYS_EXIT(0). (STEP-0 placeholder; the real spinner/workers
    # come with the scheduler stage.)
    m=Asm()
    m.raw(0x68); m.blob(le32(tag))                    # push tag
    m.raw(0x8D,0x0C,0x24)                             # lea ecx,[esp]
    m.raw(0xBA,0x04,0x00,0x00,0x00)                   # mov edx,4
    m.raw(0xB8,0x02,0x00,0x00,0x00)                   # mov eax,2 (SYS_WRITE)
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)                             # add esp,4
    m.raw(0xB3,0x00)                                  # mov bl,0
    m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30) # SYS_EXIT
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


# ============================ furlough FORCING: the naive reader + peer emitters ============================
def module_reader(tag=RDR_TAG):
    # A (proc0): a NAIVE blocking reader. ONE `mov eax,0; int 0x30` (SYS_READ) -- no retry loop, and SYS_YIELD was
    # deleted at tickover, so there is NO module-side escape from a not-ready read. On the FROZEN kernel this busy-polls
    # COM1 with IF=0 and FREEZES the machine; on furlough the kernel parks A and runs the peers, then wakes A with the
    # delivered byte. A then emits le32(tag | byte) -- output DEPENDS on the delivered byte -- and SYS_EXITs.
    m=Asm()
    m.raw(0xB8,0x00,0x00,0x00,0x00)                   # mov eax,0  (SYS_READ)
    m.raw(0xCD,0x30)                                  # int 0x30 -> byte in eax (delivered by the wake arm into t_eax)
    m.raw(0x25); m.blob(le32(0xFF))                   # and eax,0xFF      (mask to the byte)
    m.raw(0x0D); m.blob(le32(tag))                    # or  eax,tag       -> tag | byte  (byte-dependent output)
    m.raw(0x50)                                       # push eax
    m.raw(0x8D,0x0C,0x24)                             # lea ecx,[esp]
    m.raw(0xBA,0x04,0x00,0x00,0x00)                   # mov edx,4
    m.raw(0xB8,0x02,0x00,0x00,0x00)                   # mov eax,2 (SYS_WRITE)
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)                             # add esp,4
    m.raw(0xB3,0x00)                                  # mov bl,0
    m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30) # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def furl_peer_tokens(K, seed=FURL_SEED):
    # distinct held-back tokens for the peer emitters B,C,... (procs 1..K-1). A (proc0) has no peer token. Reuse the
    # worker_tokens generator (24-bit, every byte 0x01..0x7F -> distinct from A's 0xAB00xx output: high byte 0xAB>0x7F
    # and middle byte 0x00, so no collision with any peer token).
    return worker_tokens(K, seed)

# ============================ cleave FORCING: the COW prober (one program, copy-on-write) ============================
def module_cow_prober(seed=None):
    # The COW prober (proc0, K=1). With seed=None it reads a LATE-BOUND seed byte over COM1 (SYS_READ); with seed given
    # it BAKES the seed (STEP-0 smoke). It then:
    #   (1) fills the shared frame F THROUGH VW (the writable alias): for i in 0..N-1, [VW+i*4] = base + i*0x100,
    #       base = (SH_TAG | (seed & 0xFF))  -- the page contents to be copied-on-write;
    #   (2) stores COW_MARK THROUGH VR (the READ-ONLY alias) at word COW_IDX -> a write-protection #PF -> the kernel's
    #       COW arm copies F->F', remaps VR->F'|7, and resumes the store, which lands in the PRIVATE copy F';
    #   (3) emits the digest: N words read THROUGH VW (== payload: F is UNCHANGED) then N words read THROUGH VR
    #       (== payload but word COW_IDX == COW_MARK: the private copy). Each word is re-read fresh after the
    #       GP-clobbering int 0x30. A no-copy forge makes the VR store hit the SHARED F -> VW word COW_IDX == MARK -> RED.
    m=Asm()
    if seed is None:
        m.raw(0xB8,0x00,0x00,0x00,0x00)           # mov eax,0  (SYS_READ)
        m.raw(0xCD,0x30)                          # int 0x30 -> seed byte in eax
        m.raw(0x25); m.blob(le32(0xFF))           # and eax,0xFF   -> eax = seed (no int after here until the SYS_WRITEs)
    else:
        m.raw(0xB8); m.blob(le32(seed & 0xFF))    # mov eax, seed (baked)
    m.raw(0x89,0xC3)                              # mov ebx,eax   (save seed; ebx survives -- no int 0x30 until the emits)
    m.raw(0x0D); m.blob(le32(SH_TAG))            # or eax,SH_TAG -> base = SH_TAG | seed
    for i in range(SH_N):                         # (1) fill F through VW: SH_N payload words at offsets 0..(SH_N-1)*4
        if i>0: m.raw(0x05); m.blob(le32(0x100))  # add eax,0x100  (word_i = base + i*0x100)
        m.raw(0xA3); m.blob(le32(SH_VA + i*4))    # mov [VW + i*4], eax
    m.raw(0x89,0xD8); m.raw(0x0D); m.blob(le32(COW_DEEP_TAG))    # eax = seed (ebx); or eax,COW_DEEP_TAG -> the deep word
    m.raw(0xA3); m.blob(le32(SH_VA + COW_DEEP_IDX*4))            # mov [VW + DEEP*4], eax  (fill the LAST dword of the page)
    m.raw(0xC7,0x05); m.blob(le32(SH_VB + COW_IDX*4)); m.blob(le32(COW_MARK))   # (2) COW write THROUGH VR (read-only) -> #PF
    def emit_word_at(addr):                       # (3) read a word through the given alias and SYS_WRITE it (in-region buf)
        m.raw(0xA1); m.blob(le32(addr))           # mov eax,[addr]
        m.raw(0x50)                               # push eax (onto the prober's OWN in-region stack)
        m.raw(0x8D,0x0C,0x24)                     # lea ecx,[esp]   (in-region buf -> SYS_WRITE access_ok passes)
        m.raw(0xBA,0x04,0x00,0x00,0x00)           # mov edx,4
        m.raw(0xB8,0x02,0x00,0x00,0x00)           # mov eax,2 (SYS_WRITE)
        m.raw(0xCD,0x30)
        m.raw(0x83,0xC4,0x04)                     # add esp,4
    for i in range(SH_N): emit_word_at(SH_VA + i*4)   # VW payload words (F, unchanged -- proves the store hit a COPY)
    emit_word_at(SH_VA + COW_DEEP_IDX*4)              # VW deep word (F unchanged)
    for i in range(SH_N): emit_word_at(SH_VB + i*4)   # VR payload words (private copy F' -- preserved except COW_IDX==MARK)
    emit_word_at(SH_VB + COW_DEEP_IDX*4)              # VR deep word (the COPY must have covered the WHOLE page -> == deep)
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

DISP_MAX = 1000  # a LOOSE gross-spin sanity bound (supporting evidence; Codex: "counters are instrumentation, not proof").
#   Genuine block parks the reader -> dispatched O(1) times (1 wake + a few latched/jitter timer preempts: TCG~2, KVM~3,
#   Bochs single digits; timeout-bounded well under 1000). A runnable-retry forge re-dispatches it EVERY idle cycle ->
#   tens of thousands. The PRIMARY runnable-retry killer is the wake-witness==1 gate (a runnable-retry forge never marks
#   the reader blocked, so the wake arm never fires -> 0 wake witnesses); disp is the loose, timing-robust confirmation.

def _wake_frames(tail):
    """parse the furlough WAKE WITNESS frames: 0xCC <w:4> <byte:4> 0xCD."""
    out=[]; pos=0
    while True:
        j=tail.find(b'\xCC',pos)
        if j<0: break
        if j+10>len(tail): break
        if tail[j+9]!=0xCD: pos=j+1; continue
        w,b=struct.unpack('<2I',tail[j+1:j+9])
        out.append(dict(w=w,byte=b,at=j)); pos=j+10
    return out

def _disp_counts(tail, K):
    """parse the furlough per-proc DISPATCH dump: 0xCA <disp[0]:4> .. <disp[K-1]:4> 0xCB. Returns a list or None.
       Rescans on a bad terminator (like _wake_frames/_commit_frames) so a spurious 0xCA inside a placement-dependent
       write-frame header cannot mis-parse the finalize dump."""
    pos=0
    while True:
        j=tail.find(b'\xCA',pos)
        if j<0: return None
        if j+1+4*K+1<=len(tail) and tail[j+1+4*K]==0xCB:
            return list(struct.unpack('<%dI'%K, tail[j+1:j+1+4*K]))
        pos=j+1


def assert_furlough(kelf):
    """White-box structural smoke test for furlough's NEW block/wake capability (the byte-pin to build_elf() is the
       PRIMARY binding; this survives a forge that fakes the bytes another way). Pins KERNEL-SIDE DESCHEDULE +
       WAKE-WITH-DELIVERY -- distinct from every prior link, none of which ever removes a proc from the runnable set on
       an EXTERNAL (I/O) event and re-admits it:
         - BLOCK snapshot: `mov eax,[esp]` then the indexed t_eip store (8B 04 24 ; 89 04 8D <t_eip_base>) -- the
           syscall-return frame is saved into the TCB at block time (NOT relying on the stale timer snapshot). M-restart
           inserts `sub eax,2` between them (breaks the motif); M-noblock emits no block arm at all.
         - BLOCK set: blocked[cur]=1 (C7 04 8D <blocked_base> 01 00 00 00). M-noblockflag/M-restart omit it.
         - BLOCKED-skip in the pick: ld eax,blocked[ecx]; test; JNE pick (8B 04 8D <blocked_base> 85 C0 0F 85).
           M-noskipblk inverts to JE (0F 84) -> motif absent.
         - WAKE deliver: mov [t_eax + esi*4], eax (89 04 B5 <t_eax_base>) -- the byte injected into the wakee's saved
           eax. M-nodeliver omits it.
         - WAKE clear: blocked[w]=0 (C7 04 B5 <blocked_base> 00 00 00 00) -- unblock on delivery. M-nowake omits it.
         - DISPATCH counter: inc dword[disp + ecx*4] (FF 04 8D <disp_base>) -- the forge-killer instrument.
       Returns True/False."""
    BLK=arr('blocked'); TEIP=arr('t_eip'); TEAX=arr('t_eax'); DISP=arr('disp')
    block_snap  = bytes([0x8B,0x04,0x24, 0x89,0x04,0x8D])+le32(TEIP)         # mov eax,[esp]; mov [t_eip+ecx*4],eax
    block_set   = bytes([0xC7,0x04,0x8D])+le32(BLK)+le32(1)                  # blocked[cur]=1
    blk_skip    = bytes([0x8B,0x04,0x8D])+le32(BLK)+bytes([0x85,0xC0,0x0F,0x85])  # ld blocked[ecx]; test; jne pick
    wake_deliver= bytes([0x89,0x04,0xB5])+le32(TEAX)                         # mov [t_eax+esi*4],eax
    wake_clear  = bytes([0xC7,0x04,0xB5])+le32(BLK)+le32(0)                  # blocked[w]=0
    disp_inc    = bytes([0xFF,0x04,0x8D])+le32(DISP)                         # inc dword[disp+ecx*4]
    for motif in (block_snap, block_set, blk_skip, wake_deliver, wake_clear, disp_inc):
        if motif not in kelf: return False
    return True


def grade_furlough(stream, kend_elf, K, run='run2', fbyte=FBYTE, seed=FURL_SEED):
    """furlough FULL grade -- BLOCKING SYS_READ (block / wake). 3 programs: A(proc0)=naive reader (emits le32(RDR_TAG|byte)),
       B,C(procs 1..K-1)=token emitters (worker_tokens, WREPS each, no SYS_READ).
       RUN-1 (A's byte WITHHELD forever -- the freeze differential): GREEN requires every PEER token present WREPS times
         (A parked, peers ran). On the FROZEN kernel A busy-polls IF=0 and FREEZES the machine -> peers ABSENT -> RED.
         (A never completes / no finalize -- expected, the byte never comes; we only check the peers made progress.)
       RUN-2 (byte DELIVERED -- wake + byte-correctness): GREEN requires ALL of: every peer token present WREPS times;
         A's frame le32(RDR_TAG|fbyte) present (the delivered byte reached A -- byte-correct); EXACTLY ONE wake witness
         (w==0, byte==fbyte); disp[0] (the reader) <= DISP_MAX (it was PARKED, not re-dispatched -- kills runnable-retry);
         answer==0 (A's clean exit -> finalize reached). Returns errs (CLI prints GREEN/RED)."""
    errs=[]
    # parse the own-table to locate the clean tail (parse_head skips the cell block BY COUNT, so a spurious 0xD4 byte in
    # the boot cell-dump cannot derail the write-frame scan). On the FROZEN-kernel differential the cell count differs /
    # the output is short -> parse_head returns None or mis-aligns, but the peers never ran -> peer tokens absent -> RED.
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (frozen kernel froze before the peers ran, or early fault) -> peers absent']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==4 and w['cs']==UCODE3 and (w['cs']&3)==3]
    bodies=[struct.unpack('<I',w['body'])[0] for w in wfs]
    peer_toks=furl_peer_tokens(K, seed)
    # PEER PROGRESS: every peer i in 1..K-1 emitted its distinct held-back token WREPS times
    for i in range(1, K):
        cnt=bodies.count(peer_toks[i])
        if cnt!=WREPS:
            errs.append(f'peer proc{i} emitted its held-back token 0x{peer_toks[i]:06x} {cnt} times != WREPS={WREPS} '
                        f'(FROZEN: the naive reader busy-polls IF=0 and starves the peers -> token absent)')
    if run=='run1':
        return errs   # freeze differential: peer progress is the whole proof (the byte never arrives)
    # RUN-2: the reader woke with the CORRECT byte and ran to completion
    want_a=(RDR_TAG | (fbyte & 0xFF)) & 0xFFFFFFFF
    a_cnt=bodies.count(want_a)
    if a_cnt!=1:
        errs.append(f'reader proc0 emitted le32(RDR_TAG|byte)=0x{want_a:06x} {a_cnt} times != 1 '
                    f'(M-nodeliver: stale t_eax -> wrong byte; M-nowake: never resumed -> absent)')
    if r['nprocs']!=K: errs.append(f'nprocs={r["nprocs"]} != K={K}')
    wakes=_wake_frames(tail)
    good_wakes=[wk for wk in wakes if wk['w']==0 and wk['byte']==(fbyte & 0xFF)]
    if len(good_wakes)!=1:
        errs.append(f'{len(wakes)} wake witness(es), {len(good_wakes)} with (w==0, byte==0x{fbyte&0xFF:x}) != 1 '
                    f'(the kernel must wake the parked reader exactly once with the delivered byte)')
    disp=_disp_counts(tail, K)
    if disp is None:
        errs.append('no per-proc dispatch dump (CA..CB) -- finalize not reached')
    else:
        if disp[0] > DISP_MAX:
            errs.append(f'reader proc0 was DISPATCHED {disp[0]} times > DISP_MAX={DISP_MAX} -- it was NOT parked but '
                        f're-dispatched every cycle (runnable-retry forge: deschedule without a real blocked state)')
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if not an or an.group(1)[0]!=0:
        errs.append(f'answer {an.group(1)[0] if an else None} != 0 (reader clean exit / finalize)')
    return errs


def assert_cleave(kelf):
    """White-box structural co-pin for cleave's COPY-ON-WRITE mechanism (the byte-pin to build_elf() is the PRIMARY
       binding). Pins the pieces no permission-only / fixed-reserve forge can produce:
         (1) the COW ALIAS install: PTE[VW] <- F|7 (writable) AND PTE[VR] <- F|5 (READ-ONLY) -- same frame F (ALIASED),
             F != VW, F != VR (NON-IDENTITY), and VR carries NO RW bit (|5) so a store traps a write-protection #PF;
         (2) the COW COPY: a `rep movsd` (F3 A5) page copy in the kernel;
         (3) the PRIVATE remap: the copy destination comes from the cow_next pool (8B 3D <cow_next>), NOT the shared F --
             so the resumed store lands in a PRIVATE frame, not the shared one. M-cowshare (remap to F) and M-nocopy
             (skip the copy) each break (2)/(3) AND go RED on output. Returns True/False."""
    _,_,labels=build_elf()
    pt=labels['pt']
    inst_vw = bytes([0xC7,0x05])+le32(pt+(SH_VA>>12)*4)+le32(SH_FRAME|7)   # PTE[VW] <- F | P|RW|U
    inst_vr = bytes([0xC7,0x05])+le32(pt+(SH_VB>>12)*4)+le32(SH_FRAME|5)   # PTE[VR] <- F | P|U  (READ-ONLY)
    if inst_vw not in kelf: return False                                  # writable alias present?
    if inst_vr not in kelf: return False                                  # READ-ONLY alias present? (|5 -> write traps)
    if (SH_FRAME&0xFFFFF000)==(SH_VA&0xFFFFF000): return False            # NON-IDENTITY vs VW
    if (SH_FRAME&0xFFFFF000)==(SH_VB&0xFFFFF000): return False            # NON-IDENTITY vs VR
    copy = bytes([0xB9])+le32(1024)+bytes([0xFC,0xF3,0xA5])               # mov ecx,1024; cld; rep movsd -- the FULL-page copy
    if copy not in kelf: return False                                     # the 4 KiB page COPY (M-nocopy/M-shortcopy break it)
    load_cow = bytes([0x8B,0x3D])+le32(cell('cow_next'))                  # mov edi,[cow_next] -- copy dst from the PRIVATE pool
    if load_cow not in kelf: return False                                 # the private-frame remap source present?
    # the REMAP must take the PRIVATE copy (edi=F'), not the shared frame (esi=F): mov eax,edi; or eax,7; mov ecx,pte_addr;
    # mov [ecx],eax. M-cowshare (mov eax,esi -> shared F) and M-noremap (no remap) each break this exact sequence.
    remap = bytes([0x89,0xF8,0x83,0xC8,0x07,0xB9])+le32(pt+(SH_VB>>12)*4)+bytes([0x89,0x01])
    if remap not in kelf: return False                                    # remap VR -> F'(private) | 7 (NOT the shared F)
    return True


def _cow_frames(tail):
    """parse the cleave COW WITNESS frames: 0xC8 <cr2:4> <F:4> <Fp:4> 0xC9 (emitted by the kernel's COW arm)."""
    out=[]; pos=0
    while True:
        j=tail.find(b'\xC8',pos)
        if j<0: break
        if j+13>len(tail): break
        cr2,F,Fp=struct.unpack('<3I',tail[j+1:j+13])
        if tail[j+13:j+14]==b'\xC9':
            out.append(dict(cr2=cr2,F=F,Fp=Fp,at=j))
        pos=j+1
    return out


def grade_cleave(stream, kend_elf, seed=SH_SEED):
    """cleave FULL grade -- COPY-ON-WRITE. ONE prober (K=1) fills the shared frame F THROUGH VW, stores COW_MARK THROUGH
       the READ-ONLY alias VR (-> write-protection #PF -> the kernel copies F->F', remaps VR private, resumes), then emits
       2*SH_N words: SH_N read THROUGH VW (must == payload -- F UNCHANGED, proving the store hit a COPY) then SH_N read
       THROUGH VR (must == payload but word COW_IDX == COW_MARK -- the PRIVATE copy F'). RED on: FROZEN/M-noinstall (the
       VR store #PFs terminally -> no dump / wrong); M-vrwritable / M-cowshare (the store hits the SHARED F -> VW reads the
       MARK); M-nocopy (VR's copy is uncopied garbage); M-videntr (VR reads a disjoint empty frame). Returns errs."""
    errs=[]
    r=parse_head(stream)
    if not r:
        return ['no OWN table parsed (the kernel faulted before the prober dumped -- e.g. M-noinstall: the VR store #PFs terminally) -> RED']
    tail=r['_tail']
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==4 and w['cs']==UCODE3 and (w['cs']&3)==3]
    bodies=[struct.unpack('<I',w['body'])[0] for w in wfs]
    vw_exp,vr_exp=cow_expect(seed); exp=vw_exp+vr_exp; nvw=len(vw_exp)   # vw_exp/vr_exp each = SH_N payload words + 1 deep word
    if len(bodies)!=len(exp):
        errs.append(f'emitted {len(bodies)} words != expected {len(exp)} '
                    f'(got {[hex(b) for b in bodies]}; expected VW={[hex(x) for x in vw_exp]} then VR={[hex(x) for x in vr_exp]})')
    else:
        for i,(got,want) in enumerate(zip(bodies,exp)):
            if got!=want:
                half='VW' if i<nvw else 'VR'; idx=i if i<nvw else i-nvw
                deep=' (the DEEP word -- a short-copy forge that copies only the first words leaves it wrong)' if idx==nvw-1 else ''
                why=('VW must == payload (F UNCHANGED); a forge that wrote the SHARED frame (M-cowshare/M-vrwritable) shows the MARK here'
                     if half=='VW' else
                     'VR must == payload except word COW_IDX==COW_MARK (the PRIVATE copy); M-nocopy leaves garbage, M-videntr reads empty')
                errs.append(f'{half}[{idx}]=0x{got:08x} != 0x{want:08x}{deep} -- {why}')
    cowf=_cow_frames(tail)
    if not cowf:
        errs.append('no COW witness frame (C8..C9): the write-protection #PF did not reach the copy-on-write arm')
    else:
        c=cowf[0]
        if (c['F']&0xFFFFF000)==(c['Fp']&0xFFFFF000):
            errs.append(f'COW witness: F=0x{c["F"]:x} == F\'=0x{c["Fp"]:x} -- the copy destination is NOT a fresh frame (no private copy)')
        if (c['cr2']&0xFFFFF000)!=(SH_VB&0xFFFFF000):
            errs.append(f'COW witness: cr2=0x{c["cr2"]:x} not in the VR page 0x{SH_VB:x} (the fault was not the COW write)')
    if r['nprocs']!=1: errs.append(f'nprocs={r["nprocs"]} != 1 (cleave is a single-program COW probe)')
    return errs


if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='kernelelf':
        mut=sys.argv[3] if len(sys.argv)>3 else None
        stage=sys.argv[4] if len(sys.argv)>4 else 'full'
        img,kend,_=build_elf(mut if mut!='none' else None,stage); open(sys.argv[2],'wb').write(img); print('%x'%kend)
    elif cmd=='kend':
        _,kend,_=build_elf(); print('%x'%kend)
    elif cmd=='modtiny':
        open(sys.argv[2],'wb').write(module_tiny(int(sys.argv[3],0)))
    elif cmd=='modspinner':
        open(sys.argv[2],'wb').write(module_spinner())
    elif cmd=='modworker':   # out K i [seed]  (rollcall-style: proc0=spinner, worker proc i uses token[i-1])
        K=int(sys.argv[3]); i=int(sys.argv[4]); seed=int(sys.argv[5],0) if len(sys.argv)>5 else 0x501CA1
        open(sys.argv[2],'wb').write(module_worker(worker_tokens(K,seed)[i-1]))
    elif cmd=='modworker_ten':   # out N i [seed]  (tenement all-worker: proc i IS worker i, uses token[i])
        N=int(sys.argv[3]); i=int(sys.argv[4]); seed=int(sys.argv[5],0) if len(sys.argv)>5 else 0x501CA1
        open(sys.argv[2],'wb').write(module_worker(worker_tokens(N,seed)[i]))
    elif cmd=='modhostile': open(sys.argv[2],'wb').write(module_hostile_peer())
    elif cmd=='modhostileread': open(sys.argv[2],'wb').write(module_hostile_read())
    elif cmd=='gradehead':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); K=int(sys.argv[4])
        errs=grade_head(stream,kend,K)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='grade':       # stream kend K [seed]
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); K=int(sys.argv[4])
        seed=int(sys.argv[5],0) if len(sys.argv)>5 else 0x501CA1
        errs=grade(stream,kend,K,seed)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradehostile':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); kind=sys.argv[4] if len(sys.argv)>4 else 'write'
        errs=grade_hostile(stream,kend,kind)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradeten':    # stream kend N M [seed]  (tenement FULL reclamation grade)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        N=int(sys.argv[4]); M=int(sys.argv[5]) if len(sys.argv)>5 else MSLOTS
        seed=int(sys.argv[6],0) if len(sys.argv)>6 else 0x501CA1
        errs,pages=grade_ten(stream,kend,N,M,seed)
        print('distinct region pages hosting %d programs: %s (<= M=%d => REUSE)'
              % (N, ' '.join('0x%x'%p for p in pages), M))
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='modgrower':   # out [N] [seed]  (homestead recursive grower; seed is informational -- it is fed via COM1)
        N=int(sys.argv[3]) if len(sys.argv)>3 else GROWER_N
        open(sys.argv[2],'wb').write(module_grower(N))
    elif cmd=='gradehome':   # stream kend [N] [seed]  (homestead FULL demand-paging grade)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        N=int(sys.argv[4]) if len(sys.argv)>4 else GROWER_N
        seed=int(sys.argv[5],0) if len(sys.argv)>5 else GROWER_SEED
        errs,ncommit=grade_homestead(stream,kend,N,seed)
        print('demand commits witnessed (P=0 -> P=1, cr2 in grow window): %d' % ncommit)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='rollcall':
        sys.exit(0 if assert_rollcall(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='tenement':
        sys.exit(0 if assert_tenement(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='homestead':
        sys.exit(0 if assert_homestead(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='modreader':   # out  (furlough proc0: naive blocking reader -> emits le32(RDR_TAG|byte))
        open(sys.argv[2],'wb').write(module_reader())
    elif cmd=='modpeer':     # out K i [seed]  (furlough peer proc i in 1..K-1: token emitter, no SYS_READ)
        K=int(sys.argv[3]); i=int(sys.argv[4]); seed=int(sys.argv[5],0) if len(sys.argv)>5 else FURL_SEED
        open(sys.argv[2],'wb').write(module_worker(furl_peer_tokens(K,seed)[i]))
    elif cmd=='gradefurl':   # stream kend K run [fbyte] [seed]  (furlough block/wake grade)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); K=int(sys.argv[4])
        run=sys.argv[5] if len(sys.argv)>5 else 'run2'
        fbyte=int(sys.argv[6],0) if len(sys.argv)>6 else FBYTE
        seed=int(sys.argv[7],0) if len(sys.argv)>7 else FURL_SEED
        errs=grade_furlough(stream,kend,K,run,fbyte,seed)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='furlough':
        sys.exit(0 if assert_furlough(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='modcowprober':  # out [seed]  (cleave K=1 COW prober; seed baked if given, else late-bound SYS_READ)
        seed=int(sys.argv[3],0) if len(sys.argv)>3 else None
        open(sys.argv[2],'wb').write(module_cow_prober(seed))
    elif cmd=='gradecleave':   # stream kend [seed]  (cleave copy-on-write grade)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        seed=int(sys.argv[4],0) if len(sys.argv)>4 else SH_SEED
        errs=grade_cleave(stream,kend,seed)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='cleave':
        sys.exit(0 if assert_cleave(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='ncells': print(len(CELLS))
    else: raise SystemExit('usage: kernelelf|kend|modtiny|modspinner|modworker|modworker_ten|modgrower|modreader|modpeer|modcowprober|modhostile|modhostileread|grade|gradehead|gradeten|gradehome|gradefurl|gradecleave|gradehostile|rollcall|tenement|homestead|furlough|cleave|ncells')
