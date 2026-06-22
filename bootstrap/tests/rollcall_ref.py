#!/usr/bin/env python3
# rollcall_ref.py -- STEP-0 oracle + BYTE-EXACT emitter target for "the scheduler becomes a DATA STRUCTURE"
# (native-codegen Link 46 / kernel-arc link 30). RUNTIME-K PROCESS TABLE + RUN-QUEUE: the SAME kernel binary runs
# an author-unknown number K of ring-3 programs (K read from mods_count at RUNTIME), generalizing tickover's
# hardcoded-TWO (two TCBs UNROLLED, cur^=1) to a TCB ARRAY indexed by a round-robin run-queue loop. tickover is the
# K=2 case (1 spinner + 1 worker). The first time the kernel's process model is DATA the kernel iterates, not code.
#
# Built on the FROZEN tickover lineage (lodger discover/parse/bump-alloc + nokta paging-U/S per-program flip +
# geeking fault->continue + tickover's preemptive vec-0x20 full-context switch). NEW vs tickover:
#   PARSE    mods_count -> K (1..MAXPROC), then a LOOP reads K module entries into parallel arrays modstart[i]/
#            modend[i] (indexed `[base+ecx*4]` stores -- not tickover's two unrolled mod[0]/mod[1] reads).
#   ALLOC    a data-driven bump allocator: an excl[] array (kernel/mbinfo/cmdline/elf/mmap + the K modules + each
#            allocated region) the inner scan LOOPS over; K regions bump-allocated, each appended to excl[] so the
#            next avoids it (not tickover's two unrolled alloc_region() calls).
#   TABLE    per-process PARALLEL ARRAYS (modstart/modend/alloc_lo/alloc_hi/started/exited + a full TCB
#            edi..esp+eflags+eip), indexed `[base+proc*4]` -- not tickover's named a_*/b_* cells.
#   SCHED    a round-robin run-queue: next = the next NON-exited proc after cur (a `(cur+1) mod K` loop skipping
#            exited), the per-process U/S flip + TCB restore indexed by proc -- not cur^=1 / resume_A/resume_B.
#   EXIT     dequeue-on-exit: a proc's exited[] set + live-- ; live==1 (only the spinner) -> wake the spinner;
#            live==0 -> finalize. The run-queue SHRINKS (a real run-queue, not a fixed pair).
#
# FORCING (hand-assembled ref fixtures, byte-pinned): module 0 = a register-carry SPINNER that NEVER yields (edx=VA
# + DF=1 held live across a PURE spin), woken by the kernel's page-base stop-flag only after all workers exit;
# modules 1..K-1 = WORKERS, each emitting a per-module HELD-BACK random token sequence (baked in its own image) then
# SYS_EXIT. The workers running AT ALL proves preemption (the non-yielding spinner would starve them cooperatively);
# the SAME kernel binary running K=3 AND K=5 AND K=7 images (all workers complete) proves the run-queue is genuinely
# K-generic (a 2-/finite-unrolled kernel fails an unseen K). Graded TIMING-ROBUST on per-program COMPLETENESS (every
# worker's full token sequence present, eip-tagged), NOT interleave order.
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
NEXCL=5+3*MAXPROC           # excl[] capacity: 5 fixed (kernel/mb/cm/elf/mmap) + 2 per module (range + string window)
#   + 1 per ALLOCATED region (appended during the bump loop so the next region avoids it). With K<=MAXPROC enforced
#   at parse (FOVER), the running nexcl is bounded by 5+3*K <= 5+3*MAXPROC, so it can never overflow. (Cross-model
#   Codex caught the original 5+2*MAXPROC undersize: it omitted the per-region append; K>=6 overflowed into the code.)
assert NEXCL >= 5+3*MAXPROC, 'excl[] must hold 5 fixed + 2/module + 1/region for K up to MAXPROC'
JNE,JE,JB,JAE,JA,JBE=0x85,0x84,0x82,0x83,0x87,0x86
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def s32(v): return struct.pack('<i', v)
REGN={'eax':0,'ecx':1,'edx':2,'ebx':3,'esp':4,'ebp':5,'esi':6,'edi':7}

# ---- cell layout: scalars, then per-process PARALLEL ARRAYS (MAXPROC each), then the excl[] arrays (NEXCL each) ----
SCALARS=['mbinfo','flags','cmdline','elflo','elfhi','mm_lo','mm_hi','region_lo','region_hi',
         'nprocs','cur','live','switches','nexcl','answer','tmp0','tmp1']
PARR=['modstart','modend','st_lo','st_hi','alloc_lo','alloc_hi','started','exited',
      't_edi','t_esi','t_ebp','t_ebx','t_edx','t_ecx','t_eax','t_eip','t_eflags','t_esp']
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

    # ===== K-GENERIC bump allocator: per proc p, find a clear page avoiding excl[0..nexcl-1], append it =====
    a.raw(0x31,0xFF)                                   # xor edi,edi  (proc p)
    a.lbl('allocloop')
    a.raw(0x3B,0x3D); a.blob(le32(cell('nprocs'))); a.j(JAE,'allocdone')   # p >= K?
    # cur = max(region_lo, 0x100000) aligned up
    mem(cell('region_lo')); a.raw(0x3D); a.blob(le32(0x100000)); a.j(JAE,'hf')
    a.raw(0xB8); a.blob(le32(0x100000)); a.lbl('hf')
    alignup_eax(); a.raw(0x89,0xC1)                    # ecx = cur
    a.lbl('rescan')
    a.raw(0x31,0xDB)                                   # xor ebx,ebx (changed flag)
    a.raw(0x31,0xF6)                                   # xor esi,esi (excl index j)
    a.lbl('eckloop')
    a.raw(0x3B,0x35); a.blob(le32(cell('nexcl'))); a.j(JAE,'eckdone')      # j >= nexcl?
    ld('eax',excl_hi(),'esi'); a.raw(0x39,0xC1); a.j(JAE,'nextj')          # cur >= hi[j] -> no overlap
    a.raw(0x8D,0x81); a.blob(le32(0x1000))            # eax = cur + 0x1000  (lea eax,[ecx+0x1000])
    ld('edx',excl_lo(),'esi'); a.raw(0x39,0xD0); a.j(JBE,'nextj')          # cur+0x1000 <= lo[j] -> no overlap
    # overlap: cur = alignup(excl_hi[j]); ebx=1
    ld('eax',excl_hi(),'esi'); alignup_eax(); a.raw(0x89,0xC1); a.raw(0xBB); a.blob(le32(1))
    a.lbl('nextj')
    a.raw(0x46); a.j(None,'eckloop')                   # inc esi
    a.lbl('eckdone')
    a.raw(0x85,0xDB); a.j(JNE,'rescan')                # changed -> rescan
    # cur clear: check cur+0x1000 <= region_hi
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); a.raw(0x3B,0x05); a.blob(le32(cell('region_hi'))); a.j(JA,'F10')
    st(arr('alloc_lo'),'edi','ecx')                    # alloc_lo[p] = cur
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); st(arr('alloc_hi'),'edi','eax')   # alloc_hi[p] = cur+0x1000
    # append region[p] to excl: excl_lo[nexcl]=cur, excl_hi[nexcl]=cur+0x1000; nexcl++
    a.raw(0x8B,0x35); a.blob(le32(cell('nexcl')))      # esi = nexcl
    st(excl_lo(),'esi','ecx')
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); st(excl_hi(),'esi','eax')
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
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # reload cr3 (flush TLB)

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
    mem(cell('live')); a.raw(0x85,0xC0); a.j(JE,'finalize')   # live==0 -> finalize
    a.raw(0x83,0xF8,0x01); a.j(JNE,'sched_switch')         # live>1 -> just switch
    if mut!='nowake':                                      # M-nowake: spinner never woken -> spins forever (RED)
        mem(arr('alloc_lo'))                               # live==1: wake the spinner (proc0)
        a.raw(0xC7,0x00); a.blob(le32(1))                  # [alloc_lo[0]] = 1
    a.j(None,'sched_switch')
    a.lbl('finalize')
    outi(0xC8); mem(cell('switches')); dr_eax(); outi(0xC9)   # dump switch counter
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')

    # ---- SYS_READ (eax==0): poll COM1 + read RBR, iret byte back (VERBATIM tickover) ----
    a.lbl('do_read')
    a.blob(bytes.fromhex('66bafd03eca80174f766baf803ec'))
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

    # ===== shared SCHED-SWITCH: round-robin pick next live proc, flip pages, restore/fresh, iret =====
    a.lbl('sched_switch')
    a.raw(0xFF,0x05); a.blob(le32(cell('switches')))       # inc [switches]
    # pick: ecx = next non-exited proc after cur (round-robin run-queue)
    if mut=='norobin':                                     # M-norobin: toggle 0<->1 (tickover-style) -> starves proc>=2
        a.raw(0x8B,0x0D); a.blob(le32(cell('cur'))); a.raw(0x83,0xF1,0x01)   # ecx=cur; xor ecx,1
    else:
        a.raw(0x8B,0x0D); a.blob(le32(cell('cur')))        # ecx = cur
        a.lbl('pick')
        a.raw(0x41)                                        # inc ecx
        a.raw(0x3B,0x0D); a.blob(le32(cell('nprocs'))); a.j(JB,'nowrap')   # ecx < K?
        a.raw(0x31,0xC9)                                   # ecx = 0 (wrap)
        a.lbl('nowrap')
        ld('eax',arr('exited'),'ecx'); a.raw(0x85,0xC0); a.j(JNE,'pick')   # exited[ecx] -> keep looking
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


# ============================ THE FORCING MODULES: 1 spinner (proc 0) + K-1 workers ============================
VA=0x00CAFE                         # spinner's GP-survival marker (carried in edx across the preempt; emitted)
MSI=0x515511; MDI=0xD1D1BB; MBP=0xB9B9CC; MBX=0xB8B8DD   # additional markers (esi/edi/ebp/ebx)
WREPS=3                             # each worker emits its held-back token this many times then exits
import random
def worker_tokens(K, seed=0x501CA1):
    # K-1 distinct held-back random 24-bit tokens, one per worker (procs 1..K-1). Baked into each worker's image;
    # the byte-pinned kernel is module-agnostic and does NOT know K or the tokens at emit time.
    rng=random.Random(seed)
    return [rng.randint(1,0x7F)|(rng.randint(1,0x7F)<<8)|(rng.randint(1,0x7F)<<16) for _ in range(K-1)]

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
    elif cmd=='modworker':   # out K i [seed]
        K=int(sys.argv[3]); i=int(sys.argv[4]); seed=int(sys.argv[5],0) if len(sys.argv)>5 else 0x501CA1
        open(sys.argv[2],'wb').write(module_worker(worker_tokens(K,seed)[i-1]))
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
    elif cmd=='rollcall':
        sys.exit(0 if assert_rollcall(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='ncells': print(len(CELLS))
    else: raise SystemExit('usage: kernelelf|kend|modspinner|modworker|modhostile|modhostileread|grade|gradehead|gradehostile|ncells')
