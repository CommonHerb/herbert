#!/usr/bin/env python3
# tandem_ref.py -- STEP-0 oracle + BYTE-EXACT emitter target for "the kernel runs TWO DISTINCT loaded programs"
# (native-codegen Link 44 / kernel-arc link 28). WORKING NAME tandem; real link name chosen at land (A9).
#
# CAPABILITY: load TWO build-unknown ring-3 modules (Multiboot mods_count==2); give each its OWN bump-allocated
# working page AND its OWN User/Supervisor page view (per-program PTE-flip at the yield boundary: only the RUNNING
# program's code+stack pages are User, the inactive peer's are Supervisor); interleave them COOPERATIVELY under
# kernel control via SYS_YIELD (eax=3) + a one-cell A->B mailbox. The step from "sandboxed-payload runner" to
# "operating system that runs programs."
#
# Built on the FROZEN holler lineage (lodger discover/parse/bump-alloc + nokta paging-U/S + geeking fault->continue
# + the int 0x30 READ/WRITE/EXIT ABI), proven byte-identical sequences transcribed below. NEW vs holler:
#   HEAD     mods_count==2; read mod[0]=A and mod[1]=B; exclude BOTH module ranges; bump-allocate TWO regions
#            (regionB also excludes regionA).
#   ISOLATE  at boot flip A's code+stack pages User, leave B's Supervisor; iret into A.
#   SCHED    SYS_YIELD saves the outgoing {eip,esp,ebp} TCB, flips pages (out->Super,in->User)+reloads CR3, resumes
#            the peer (fresh entry first time; restored TCB after). A UNIDIRECTIONAL A->B one-cell mailbox carries
#            each value; cross-yield dependence b_i=f(a_{i-1}) is producible ONLY by genuine ping-pong THROUGH the
#            kernel. A kernel SWITCH COUNTER is dumped (anti run-A-then-B at the kernel layer).
#   cooperative only (IF=0 at CPL3; no timer/preempt -- that's the NEXT link). geeking fault->continue KEPT (the
#   hostile-peer #PF is named+continued); timer/kill machinery DROPPED.
#
# TCB INSIGHT (cross-model Codex-confirmed): across int 0x30 a stack-machine module holds NO live GP regs (results
# pushed immediately); all live state is on its stack (ebp/esp-relative). So a switch saves only {eip,useresp,ebp}.
# Codex folds: cld on entry; reload DS/ES/FS/GS=UDATA3 before every iret-to-CPL3; flip full code SPAN + stack page;
# flush CR3 after all PTE writes; wake-yield first-transfer; switch-counter anti-forge; #PF metadata grader asserts.
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holler_ref as H
from holler_ref import Asm, gdt_desc, idt_gate, le16

OUT=H.OUT; LOAD=H.LOAD; ENTRY=H.ENTRY
KCODE=H.KCODE; KDATA=H.KDATA; UCODE=H.UCODE; UDATA=H.UDATA; TSS_SEL=H.TSS_SEL
UCODE3=H.UCODE3; UDATA3=H.UDATA3
SYS_READ=0; SYS_EXIT=1; SYS_WRITE=2; SYS_YIELD=3
NPT=4
JNE,JE,JB,JAE,JA,JBE=0x85,0x84,0x82,0x83,0x87,0x86
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def s32(v): return struct.pack('<i', v)

# ---- cell layout: holler's 21 cells (same indices -> copied sequences resolve identically) + appended new cells ----
CELLS=['mbinfo','flags','modstart','modend','str','cmdline','elflo','elfhi',
       'region_lo','region_hi','alloc_lo','alloc_hi','answer',
       'mb_lo','mb_hi','st_lo','st_hi','cm_lo','cm_hi','mm_lo','mm_hi',
       # --- appended (program B + scheduler) ---
       'modstart2','modend2','str2','st2_lo','st2_hi',
       'alloc_lo2','alloc_hi2',
       'mbx','cur','b_started','a_exited','b_exited','switches',
       'a_eip','a_esp','a_ebp','b_eip','b_esp','b_ebp']
CIDX={n:i for i,n in enumerate(CELLS)}
CELLBASE=ENTRY+6+5    # byte-0 `mov [mbinfo],ebx`(6) + `jmp glue`(5) -> cells start here (true offset)
def cell(n): return CELLBASE+CIDX[n]*4
ANSWER=cell('answer')

def build_code(kstack, kend, mut=None, stage='full'):
    a=Asm(); a._dctr=0; a._ctr=0
    def mmi(addr,imm): a.raw(0xC7,0x05); a.blob(le32(addr)); a.blob(le32(imm))
    def mme(addr): a.raw(0xA3); a.blob(le32(addr))
    def mem(addr): a.raw(0xA1); a.blob(le32(addr))
    def outi(v): a.raw(0xB0,v,0xE6,OUT)
    def dr_eax():
        a.raw(0xE6,OUT)
        for _ in range(3): a.raw(0xC1,0xE8,0x08,0xE6,OUT)
    def alignup_eax(): a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def load_kdata(): a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    def load_udata(): a.raw(0xB8); a.blob(le32(UDATA3)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    def shutdown():
        a.raw(0x66,0xBA,0xF4,0x00); a.raw(0xEE)
        a.raw(0x66,0xBA,0x00,0x89)
        for ch in b'Shutdown': a.raw(0xB0,ch,0xEE)
        a.raw(0xFA,0xF4,0xEB,0xFD)

    # ===== HEAD: capture + magic + parse mbinfo =====
    a.blob(bytes((0x89,0x1D))+le32(cell('mbinfo')))   # mov [mbinfo],ebx  (byte 0)
    a.j(None,'glue')
    a.lbl('cells'); a.blob(b'\x00'*(len(CELLS)*4+8))   # cell array (+8 slack)
    sd_FAILS=['F1','F2','F3','F4','F5','F8','F9','F10','FB']
    for idx,f in enumerate(sd_FAILS):
        a.lbl(f); a.blob(bytes([176,0x31+idx,0xE6,OUT])); a.j(None,'sdtail')
    a.lbl('sdtail'); shutdown()
    a.lbl('glue')
    a.raw(0x3D); a.blob(le32(0x2BADB002)); a.j(JNE,'F1')   # cmp eax,magic
    a.raw(0xBC); a.blob(le32(kstack))
    a.raw(0x31,0xC0); a.raw(0x0F,0x22,0xE0)                 # xor eax,eax; mov cr4,eax (PAE/PSE/PGE off)
    a.raw(0x68); a.blob(le32(0x00000002)); a.raw(0x9D)     # push 2; popfd (IF=0)
    a.raw(0x8B,0x35); a.blob(le32(cell('mbinfo')))         # esi=[mbinfo]
    a.raw(0x8B,0x06); mme(cell('flags'))
    a.raw(0xA8,0x08); a.j(JE,'F2')
    a.raw(0xA8,0x40); a.j(JE,'F3')
    a.raw(0xA8,0x04); a.j(JE,'no_cmd')
    a.raw(0x8B,0x46,16); mme(cell('cmdline')); a.j(None,'cmd_done')
    a.lbl('no_cmd'); mmi(cell('cmdline'),0); a.lbl('cmd_done')
    a.raw(0xF7,0x06); a.blob(le32(0x20)); a.j(JE,'no_elf')
    a.raw(0x8B,0x46,36); mme(cell('elflo'))
    a.raw(0x8B,0x46,28); a.raw(0x0F,0xAF,0x46,32); a.raw(0x03,0x46,36); mme(cell('elfhi'))
    a.j(None,'elf_done'); a.lbl('no_elf'); mmi(cell('elflo'),0); mmi(cell('elfhi'),0); a.lbl('elf_done')
    # mods_count == 2  (M-singleslot reverts to ==1)
    want=1 if mut=='singleslot' else 2
    a.raw(0x8B,0x46,20); a.raw(0x83,0xF8,want); a.j(JNE,'F4')
    a.raw(0x8B,0x6E,24)                                     # ebp=mods_addr
    a.raw(0x8B,0x45,0x00); mme(cell('modstart'))           # mod[0]
    a.raw(0x8B,0x45,0x04); mme(cell('modend'))
    a.raw(0x8B,0x45,0x08); mme(cell('str'))
    a.raw(0x8B,0x45,16);   mme(cell('modstart2'))          # mod[1] (stride 16)
    a.raw(0x8B,0x45,20);   mme(cell('modend2'))
    a.raw(0x8B,0x45,24);   mme(cell('str2'))
    mem(cell('modstart'));  a.raw(0x3B,0x05); a.blob(le32(cell('modend')));  a.j(JAE,'F5')
    mem(cell('modstart2')); a.raw(0x3B,0x05); a.blob(le32(cell('modend2'))); a.j(JAE,'FB')
    # exclusion pages for pointer cells
    def excl_ptr(srccell, locell, hicell):
        a._ctr+=1; z=f'exz{a._ctr}'; d=f'exd{a._ctr}'
        mem(srccell); a.raw(0x85,0xC0); a.j(JE,z)
        a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(locell)
        a.raw(0x05); a.blob(le32(0x2000)); mme(hicell)
        a.j(None,d); a.lbl(z); mmi(locell,0); mmi(hicell,0); a.lbl(d)
    excl_ptr(cell('mbinfo'), cell('mb_lo'), cell('mb_hi'))
    excl_ptr(cell('str'),    cell('st_lo'), cell('st_hi'))
    excl_ptr(cell('str2'),   cell('st2_lo'),cell('st2_hi'))
    excl_ptr(cell('cmdline'),cell('cm_lo'), cell('cm_hi'))
    a.raw(0x8B,0x46,48); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_lo'))
    a.raw(0x8B,0x46,48); a.raw(0x03,0x46,44); a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_hi'))

    # ===== memory-map scan -> region_lo/region_hi (VERBATIM holler) =====
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

    # ===== bump-alloc helper: rescan from region floor, bump past exclusions, write (lo_cell,hi_cell) =====
    def excl(lo, hi):
        a._ctr+=1; sk=f'sk{a._ctr}'
        if hi[0]=='lit': a.raw(0x81,0xF9); a.blob(le32(hi[1]))
        else: a.raw(0x3B,0x0D); a.blob(le32(hi[1]))
        a.j(JAE,sk)
        a.raw(0x8D,0x81); a.blob(le32(0x1000))
        if lo[0]=='lit': a.raw(0x3D); a.blob(le32(lo[1]))
        else: a.raw(0x3B,0x05); a.blob(le32(lo[1]))
        a.j(JBE,sk)
        if hi[0]=='lit': a.raw(0xB8); a.blob(le32(hi[1]))
        else: mem(hi[1])
        alignup_eax(); a.raw(0x89,0xC1); a.raw(0xBB); a.blob(le32(1))
        a.lbl(sk)
    def alloc_region(lo_cell, hi_cell, extra_excls, tag):
        # start cur=max(region_lo,1MiB) aligned
        mem(cell('region_lo')); a.raw(0x3D); a.blob(le32(0x100000)); a.j(JAE,f'hf_{tag}')
        a.raw(0xB8); a.blob(le32(0x100000)); a.lbl(f'hf_{tag}')
        alignup_eax(); a.raw(0x89,0xC1)
        a.raw(0xBF); a.blob(le32(16))
        a.lbl(f'rescan_{tag}')
        a.raw(0x4F); a.j(JE,'F10')
        a.raw(0x31,0xDB)
        excl(('lit',0x100000), ('lit',kend))
        excl(('cell',cell('modstart')), ('cell',cell('modend')))
        excl(('cell',cell('modstart2')),('cell',cell('modend2')))
        excl(('cell',cell('mb_lo')), ('cell',cell('mb_hi')))
        excl(('cell',cell('st_lo')), ('cell',cell('st_hi')))
        excl(('cell',cell('st2_lo')),('cell',cell('st2_hi')))
        excl(('cell',cell('cm_lo')), ('cell',cell('cm_hi')))
        excl(('cell',cell('elflo')), ('cell',cell('elfhi')))
        excl(('cell',cell('mm_lo')), ('cell',cell('mm_hi')))
        for (lc,hc) in extra_excls:
            excl(('cell',lc), ('cell',hc))
        a.raw(0x85,0xDB); a.j(JNE,f'rescan_{tag}')
        a.raw(0x8D,0x81); a.blob(le32(0x1000))
        a.raw(0x3B,0x05); a.blob(le32(cell('region_hi'))); a.j(JA,'F10')
        a.raw(0x89,0x0D); a.blob(le32(lo_cell))            # lo_cell = ecx
        a.raw(0x8D,0x81); a.blob(le32(0x1000)); mme(hi_cell)  # hi_cell = ecx+0x1000
    alloc_region(cell('alloc_lo'),  cell('alloc_hi'),  [], 'A')
    alloc_region(cell('alloc_lo2'), cell('alloc_hi2'), [(cell('alloc_lo'),cell('alloc_hi'))], 'B')

    # ===== dump OWN table: 0x9A k0 k1 mmap_addr mmap_len <cells> 0x9B (parser reads cells by name) =====
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
        outi(0x77); shutdown()              # Stage A: stop after dump (verify head/alloc)
        return a.assemble()

    # ===== install ring machinery (lgdt/lidt/ltr) (VERBATIM holler) =====
    a.raw(0x0F,0x01,0x15); a.absR('gdtr')
    a.raw(0xEA); a.absR('reload'); a.raw(0x08,0x00)
    a.lbl('reload')
    a.raw(0xB8); a.blob(le32(KDATA))
    a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xD0,0x8E,0xE0,0x8E,0xE8)
    a.raw(0x0F,0x01,0x1D); a.absR('idtr')
    a.raw(0x66,0xB8,TSS_SEL,0x00); a.raw(0x0F,0x00,0xD8)

    # ===== paging ON + DUAL FLIP (A's pages User, B's stay Supervisor) =====
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # mov cr3,pd
    a.raw(0x0F,0x20,0xC0); a.raw(0x0D); a.blob(le32(0x80000000)); a.raw(0x0F,0x22,0xC0)  # cr0.PG=1
    a.raw(0xEB,0x00)
    def flip_user(srccell):
        a.raw(0xA1); a.blob(le32(srccell))     # eax=[cell] page addr
        a.raw(0xC1,0xE8,0x0A)                  # shr eax,10
        a.raw(0x25); a.blob(le32(0xFFFFFFFC))  # and eax,~3
        a.raw(0x05); a.absR('pt')              # add eax,pt
        a.raw(0x83,0x08,0x04)                  # or dword [eax],4 (U/S)
    if mut!='noflipA':
        flip_user(cell('modstart'))            # A code page
        flip_user(cell('alloc_lo'))            # A stack page
    # M-noflip variant flips BOTH programs' pages User at boot (isolation defeated -> hostile-peer #PF disappears)
    if mut=='noflip':
        flip_user(cell('modstart2')); flip_user(cell('alloc_lo2'))
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # reload cr3 (flush TLB)

    # ===== COM1 init (VERBATIM holler) =====
    for port,val in [(0x3FB,0x03),(0x3F9,0x00),(0x3FB,0x80),(0x3F8,0x01),
                     (0x3F9,0x00),(0x3FB,0x03),(0x3FA,0x00),(0x3FC,0x03)]:
        a.raw(0x66,0xBA); a.blob(le16(port)); a.raw(0xB0,val,0xEE)
    # mask all IRQs (cooperative, IF=0)
    a.raw(0xB0,0xFF,0xE6,0x21); a.raw(0xB0,0xFF,0xE6,0xA1)

    # ===== iret into A (cur already 0; b_started 0) -- IF=0 cooperative =====
    load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))            # push ss
    a.raw(0xFF,0x35); a.blob(le32(cell('alloc_hi')))   # push useresp=A stack top
    a.raw(0x68); a.blob(le32(0x00000002))        # push eflags IF=0
    a.raw(0x68); a.blob(le32(UCODE3))            # push cs
    a.raw(0xFF,0x35); a.blob(le32(cell('modstart')))   # push eip=A entry
    a.raw(0xCF)                                   # iretd -> CPL3 A

    # ===== syscall handler (vec 0x30): dispatch eax = READ/EXIT/WRITE/YIELD =====
    a.lbl('exit_handler')
    a.raw(0x85,0xC0); a.j(JE,'do_read')          # eax==0 -> read
    a.raw(0x83,0xF8,0x02); a.j(JE,'do_write')    # eax==2 -> write
    a.raw(0x83,0xF8,0x03); a.j(JE,'do_yield')    # eax==3 -> yield
    # ---- SYS_EXIT (eax==1): status in bl. If peer not exited -> switch to peer; else finalize. ----
    load_kdata()
    a.raw(0x88,0xD8); a.raw(0xA2); a.blob(le32(ANSWER))   # [answer]=bl
    # mark current exited
    a.raw(0xA1); a.blob(le32(cell('cur'))); a.raw(0x85,0xC0); a.j(JNE,'exit_curB')
    mmi(cell('a_exited'),1); a.j(None,'exit_chk')
    a.lbl('exit_curB'); mmi(cell('b_exited'),1)
    a.lbl('exit_chk')
    # both exited test: a_exited!=0 AND b_exited!=0
    mem(cell('a_exited')); a.raw(0x85,0xC0); a.j(JE,'exit_switch')
    mem(cell('b_exited')); a.raw(0x85,0xC0); a.j(JE,'exit_switch')
    # finalize: dump the switch counter (C8 <switches> C9) -- anti run-A-then-B kernel witness -- then emit answer
    outi(0xC8); mem(cell('switches')); dr_eax(); outi(0xC9)
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('exit_switch')
    # switch to peer (no value), like yield's resume path but mbx irrelevant
    a.j(None,'sched_to_peer')

    # ---- SYS_READ (eax==0): poll COM1 + read RBR, dump read-witness, iret byte back (VERBATIM holler) ----
    a.lbl('do_read')
    a.blob(bytes.fromhex('66bafd03eca80174f766baf803ec'))   # poll LSR 0x3FD; read RBR 0x3F8 -> al
    a.raw(0x88,0xC3)                                          # mov bl,al
    outi(0xC0)
    a.raw(0x88,0xD8,0xE6,OUT)
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                     # cs
    a.raw(0x8B,0x04,0x24); dr_eax()                          # eip
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                     # useresp
    outi(0xC1)
    load_udata()                                             # restore UDATA3 (Codex) -- BEFORE eax=byte (clobbers eax)
    a.raw(0x0F,0xB6,0xC3)                                     # movzx eax,bl  (delivered byte in eax for the module)
    a.raw(0xCF)

    # ---- SYS_WRITE (eax==2): access_ok vs ACTIVE region; relay (holler do_write, bounds by cur) ----
    a.lbl('do_write')
    load_kdata()
    # esi=active_lo, edi=active_hi (select by cur)
    a.raw(0xA1); a.blob(le32(cell('cur'))); a.raw(0x85,0xC0); a.j(JNE,'wB')
    a.raw(0x8B,0x35); a.blob(le32(cell('alloc_lo'))); a.raw(0x8B,0x3D); a.blob(le32(cell('alloc_hi'))); a.j(None,'wbounds')
    a.lbl('wB')
    a.raw(0x8B,0x35); a.blob(le32(cell('alloc_lo2'))); a.raw(0x8B,0x3D); a.blob(le32(cell('alloc_hi2')))
    a.lbl('wbounds')
    a.raw(0x89,0xC8); a.raw(0x01,0xD0)                       # eax=ecx+edx (ptr+len)
    a.j(JB,'reject_write')
    a.raw(0x39,0xF1); a.j(JB,'reject_write')                 # ptr<lo
    a.raw(0x39,0xF8); a.j(JA,'reject_write')                 # ptr+len>hi
    outi(0xD4)
    a.raw(0x89,0xD0); dr_eax()                               # len
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                     # cs
    a.raw(0x8B,0x04,0x24); dr_eax()                          # eip
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                     # useresp
    a.lbl('wrelay')
    a.raw(0x85,0xD2); a.j(JE,'wrelaydone')
    a.raw(0x8A,0x01); a.raw(0xE6,OUT); a.raw(0x41); a.raw(0x4A); a.j(None,'wrelay')
    a.lbl('wrelaydone')
    outi(0xD5)
    load_udata(); a.raw(0x31,0xC0); a.raw(0xCF)              # load segs BEFORE eax=0 (return 0)
    a.lbl('reject_write')
    outi(0xD6)
    a.raw(0x89,0xD0); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax(); a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x0C); dr_eax()
    outi(0xD7)
    load_udata(); a.raw(0x31,0xC0); a.raw(0xCF)

    # ---- SYS_YIELD (eax==3): unidirectional mailbox + context switch ----
    a.lbl('do_yield')
    # the passed value P arrives in EBX (the module did `pop ebx` before int 0x30); EBX is intact on syscall entry,
    # so the kernel NEVER dereferences a module-supplied address here -- the yield channel is confused-deputy-free
    # (no access_ok needed; a hostile module cannot make the kernel read kernel/peer memory via yield). [Codex fix.]
    a.raw(0x89,0x1D); a.blob(le32(cell('mbx')))             # mov [mbx],ebx  (P, by register -- no module-memory read)
    if mut=='noswap':
        # M-noswap: yield does NOT switch programs -- iret back to the SAME program (eax=mbx). A then runs to exit
        # before B ever runs -> no ping-pong -> B gets only the stale sentinel -> 0 B-writes -> grade RED.
        load_udata(); a.raw(0xA1); a.blob(le32(cell('mbx'))); a.raw(0xCF)
    load_kdata()
    # save outgoing TCB {eip,esp,ebp} keyed by cur
    a.raw(0x8B,0x04,0x24)                                    # eax=[esp+0]=eip
    a.raw(0x8B,0x5C,0x24,0x0C)                               # ebx=[esp+12]=useresp
    a.raw(0xA1); a.blob(le32(cell('cur'))); a.raw(0x85,0xC0); a.j(JNE,'saveB')
    a.raw(0x8B,0x04,0x24); a.raw(0xA3); a.blob(le32(cell('a_eip')))
    a.raw(0x8B,0x5C,0x24,0x0C); a.raw(0x89,0x1D); a.blob(le32(cell('a_esp')))
    a.raw(0x89,0x2D); a.blob(le32(cell('a_ebp')))           # a_ebp=ebp
    a.j(None,'sched_to_peer')
    a.lbl('saveB')
    a.raw(0x8B,0x04,0x24); a.raw(0xA3); a.blob(le32(cell('b_eip')))
    a.raw(0x8B,0x5C,0x24,0x0C); a.raw(0x89,0x1D); a.blob(le32(cell('b_esp')))
    a.raw(0x89,0x2D); a.blob(le32(cell('b_ebp')))
    a.j(None,'sched_to_peer')

    # ===== sched_to_peer: flip pages, toggle cur, resume peer (fresh first time, else restore TCB) =====
    a.lbl('sched_to_peer')
    # bump switch counter
    a.raw(0xFF,0x05); a.blob(le32(cell('switches')))        # inc [switches]
    # flip: current cur's pages -> Supervisor, peer's -> User; then reload cr3
    def clear_user(srccell):
        a.raw(0xA1); a.blob(le32(srccell)); a.raw(0xC1,0xE8,0x0A); a.raw(0x25); a.blob(le32(0xFFFFFFFC))
        a.raw(0x05); a.absR('pt'); a.raw(0x83,0x20,0xFB)    # and dword [eax],~4
    def set_user(srccell):
        a.raw(0xA1); a.blob(le32(srccell)); a.raw(0xC1,0xE8,0x0A); a.raw(0x25); a.blob(le32(0xFFFFFFFC))
        a.raw(0x05); a.absR('pt'); a.raw(0x83,0x08,0x04)    # or dword [eax],4
    a.raw(0xA1); a.blob(le32(cell('cur'))); a.raw(0x85,0xC0); a.j(JNE,'flip_BtoA')
    # cur==0 (A active): A->Super, B->User
    clear_user(cell('modstart')); clear_user(cell('alloc_lo'))
    set_user(cell('modstart2')); set_user(cell('alloc_lo2'))
    a.j(None,'flip_done')
    a.lbl('flip_BtoA')
    clear_user(cell('modstart2')); clear_user(cell('alloc_lo2'))
    set_user(cell('modstart')); set_user(cell('alloc_lo'))
    a.lbl('flip_done')
    a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)        # reload cr3 (flush TLB)
    # toggle cur = 1 - cur
    a.raw(0xA1); a.blob(le32(cell('cur'))); a.raw(0x83,0xF0,0x01); a.raw(0xA3); a.blob(le32(cell('cur')))
    # now cur = the program we are switching TO. If it is B and b_started==0 -> fresh start.
    a.raw(0xA1); a.blob(le32(cell('cur'))); a.raw(0x85,0xC0); a.j(JE,'resume_A')
    # switching to B
    mem(cell('b_started')); a.raw(0x85,0xC0); a.j(JNE,'resume_B')
    mmi(cell('b_started'),1)
    # fresh B: iret to B entry (eip=modstart2, esp=alloc_hi2); B ignores eax
    a.raw(0xBC); a.blob(le32(kstack))
    load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))
    a.raw(0xFF,0x35); a.blob(le32(cell('alloc_hi2')))
    a.raw(0x68); a.blob(le32(0x00000002))
    a.raw(0x68); a.blob(le32(UCODE3))
    a.raw(0xFF,0x35); a.blob(le32(cell('modstart2')))
    a.raw(0xCF)
    a.lbl('resume_B')
    a.raw(0x8B,0x2D); a.blob(le32(cell('b_ebp')))           # ebp=b_ebp
    a.raw(0xBC); a.blob(le32(kstack)); load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))
    a.raw(0xFF,0x35); a.blob(le32(cell('b_esp')))
    a.raw(0x68); a.blob(le32(0x00000002))
    a.raw(0x68); a.blob(le32(UCODE3))
    a.raw(0xFF,0x35); a.blob(le32(cell('b_eip')))
    a.raw(0xA1); a.blob(le32(cell('mbx')))                  # eax=mbx (yield return)
    a.raw(0xCF)
    a.lbl('resume_A')
    a.raw(0x8B,0x2D); a.blob(le32(cell('a_ebp')))           # ebp=a_ebp
    a.raw(0xBC); a.blob(le32(kstack)); load_udata()
    a.raw(0x68); a.blob(le32(UDATA3))
    a.raw(0xFF,0x35); a.blob(le32(cell('a_esp')))
    a.raw(0x68); a.blob(le32(0x00000002))
    a.raw(0x68); a.blob(le32(UCODE3))
    a.raw(0xFF,0x35); a.blob(le32(cell('a_eip')))
    a.raw(0xA1); a.blob(le32(cell('mbx')))
    a.raw(0xCF)

    # ===== #GP (vec 13) fault->continue (VERBATIM holler) =====
    a.lbl('gp_handler')
    load_kdata(); outi(0xF0)
    a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax(); a.raw(0x8B,0x44,0x24,0x08); dr_eax(); a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xF1)
    a.raw(0xF6,0x44,0x24,0x08,0x03); a.j(JE,'gp_kpanic')
    a.raw(0xB0,0x47); a.raw(0xA2); a.blob(le32(ANSWER))
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('gp_kpanic'); a.j(None,'sdtail')

    # ===== #PF (vec 14) fault->continue + hostile-peer witness (VERBATIM holler) =====
    a.lbl('pf_handler')
    load_kdata(); outi(0xD0)
    a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax(); a.raw(0x8B,0x44,0x24,0x08); dr_eax(); a.raw(0x0F,0x20,0xD0); dr_eax(); a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xD1)
    a.raw(0xF6,0x44,0x24,0x08,0x03); a.j(JE,'pf_kpanic')
    a.raw(0xB0,0x50); a.raw(0xA2); a.blob(le32(ANSWER))
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('pf_kpanic'); a.j(None,'sdtail')

    # ===== panic (all other vectors) fault->continue (VERBATIM holler) =====
    a.lbl('panic_handler')
    a.raw(0xF6,0x44,0x24,0x04,0x03); a.j(JE,'kpanic')
    load_kdata(); outi(0xE2)
    a.raw(0x8B,0x04,0x24); dr_eax(); a.raw(0x8B,0x44,0x24,0x04); dr_eax()
    outi(0xE3)
    a.raw(0xB0,0x46); a.raw(0xA2); a.blob(le32(ANSWER))
    a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')
    a.lbl('kpanic'); outi(ord('P')); shutdown()

    # ===== descriptor tables (VERBATIM holler) =====
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
            if i < NPT: b+=le32(L['pt'] + i*4096 + 3 + 4)   # PDE user+rw+present (per-page U/S in PT)
            else: b+=le32(0)
        return bytes(b)
    a.defer(4096, pd_bytes)
    a.lbl('pt')
    def pt_bytes(L):
        b=bytearray()
        for g in range(1024*NPT): b+=le32(g*4096 + 3)       # present+rw, Supervisor (U/S flipped per-page at runtime)
        return bytes(b)
    a.defer(4096*NPT, pt_bytes)
    a.lbl('body_start')
    a.blob(bytes([0x0F,0xB6,0x05])+le32(ANSWER)+bytes([0x50,0x58]))   # echo_body: movzx eax,[answer]; push;pop
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

# ============================ MODULE EMITTER (mmj's emit + a YIELD op) ============================
# Same two-pass multi-function layout as mmj_ref/mumbani; ADDS op 'yield' (eax=3 int 0x30, replace TOS with the
# peer's value -- net stack 0, like syswrite). Modules are POSITION-INDEPENDENT (ebp/esp-relative + rel32).
def _OP_PUSH(imm): return bytes([0x68])+le32(imm)
def _OP_LOADL(s):  return bytes([0xFF,0x75,(256-4*(s+1))&0xFF])
def _OP_STOREL(s): return bytes([0x8F,0x45,(256-4*(s+1))&0xFF])
_OP_ADD=bytes([0x59,0x58,0x01,0xC8,0x50]); _OP_SUB=bytes([0x59,0x58,0x29,0xC8,0x50])
_OP_MUL=bytes([0x59,0x58,0x0F,0xAF,0xC1,0x50]); _OP_EQ=bytes([0x59,0x58,0x39,0xC8,0x0F,0x94,0xC0,0x0F,0xB6,0xC0,0x50])
_OP_XORK=lambda k: bytes([0x58,0x35])+le32(k)+bytes([0x50])     # pop eax; xor eax,K; push eax  (transform f)
_OP_SYSREAD=bytes([0xB8])+le32(SYS_READ)+bytes([0xCD,0x30,0x50])
_OP_SYSWRITE=bytes([0x8D,0x0C,0x24,0xBA,0x04,0x00,0x00,0x00,0xB8,0x02,0x00,0x00,0x00,0xCD,0x30,0x89,0x04,0x24])
# yield: pop ebx (P -> a REGISTER; no kernel deref of module memory -- the confused-deputy-free channel, cross-model
# Codex's fix), mov eax,3, int 0x30, push eax (the peer's value). 9 bytes, net stack 0.
_OP_YIELD=bytes([0x5B,0xB8])+le32(SYS_YIELD)+bytes([0xCD,0x30,0x50])        # pop ebx; mov eax,3; int 0x30; push eax (9)
_SZ={'push':5,'loadl':3,'storel':3,'add':5,'sub':5,'mul':6,'eq':11,'xork':7,'sysread':8,'syswrite':18,'yield':9,
     'br':5,'brf':9,'ret_last':1,'ret_mid':6}
def _instr_size(kind,nargs,is_last):
    if kind=='ret': return _SZ['ret_last'] if is_last else _SZ['ret_mid']
    if kind=='call':
        cl=0 if nargs==0 else (3 if 4*nargs<=127 else 6); return 5+cl+1
    return _SZ[kind]
def _frame_size(fn):
    s=fn[1]
    for (k,arg) in fn[2]:
        if k in ('loadl','storel') and arg+1>s: s=arg+1
    return s
def _callarg(instr): return instr[1][1] if instr[0]=='call' else 0
def _layout(funcs):
    bases={}; instr_offs=[]; epi_off=[]; cur=0
    for fi,fn in enumerate(funcs):
        is_main=(fi==0); S=_frame_size(fn); bases[fn[0]]=cur
        cur += (0 if S==0 else (5 if is_main else 6+fn[1]*6))
        offs=[]; n=len(fn[2])
        for i,instr in enumerate(fn[2]):
            offs.append(cur); cur+=_instr_size(instr[0],_callarg(instr),i==n-1)
        instr_offs.append(offs); epi_off.append(cur)
        cur += (9 if is_main else (4 if S>0 else 1))
    return bases,instr_offs,epi_off,cur
def module_emit(funcs):
    bases,instr_offs,epi_off,total=_layout(funcs); out=b''
    for fi,fn in enumerate(funcs):
        is_main=(fi==0); S=_frame_size(fn); nparams=fn[1]
        if S>0:
            if is_main: out+=bytes([0x89,0xE5,0x83,0xEC,(4*S)&0xFF])
            else:
                out+=bytes([0x55,0x89,0xE5,0x83,0xEC,(4*S)&0xFF])
                for i in range(nparams):
                    src=8+4*(nparams-1-i); out+=bytes([0x8B,0x45,src&0xFF,0x89,0x45,(256-4*(i+1))&0xFF])
        offs=instr_offs[fi]; n=len(fn[2]); epi=epi_off[fi]
        for i,instr in enumerate(fn[2]):
            kind=instr[0]; is_last=(i==n-1); end=offs[i]+_instr_size(kind,_callarg(instr),is_last)
            if kind=='push': out+=_OP_PUSH(instr[1])
            elif kind=='loadl': out+=_OP_LOADL(instr[1])
            elif kind=='storel': out+=_OP_STOREL(instr[1])
            elif kind=='add': out+=_OP_ADD
            elif kind=='sub': out+=_OP_SUB
            elif kind=='mul': out+=_OP_MUL
            elif kind=='eq': out+=_OP_EQ
            elif kind=='xork': out+=_OP_XORK(instr[1])
            elif kind=='sysread': out+=_OP_SYSREAD
            elif kind=='syswrite': out+=_OP_SYSWRITE
            elif kind=='yield': out+=_OP_YIELD
            elif kind=='br':
                tgt=epi if instr[1]==n else offs[instr[1]]; out+=bytes([0xE9])+s32(tgt-end)
            elif kind=='brf':
                tgt=epi if instr[1]==n else offs[instr[1]]; out+=bytes([0x58,0x85,0xC0,0x0F,0x84])+s32(tgt-end)
            elif kind=='call':
                callee,nargs=instr[1]; rel=bases[callee]-(offs[i]+5); out+=bytes([0xE8])+s32(rel)
                if nargs>0:
                    out+= bytes([0x83,0xC4,(4*nargs)&0xFF]) if 4*nargs<=127 else bytes([0x81,0xC4])+le32(4*nargs)
                out+=bytes([0x50])
            elif kind=='ret':
                out+= bytes([0x58]) if is_last else bytes([0x58,0xE9])+s32(epi-end)
            else: raise SystemExit('op? '+kind)
        if is_main: out+=bytes([0x88,0xC3,0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
        elif S>0: out+=bytes([0x89,0xEC,0x5D,0xC3])
        else: out+=bytes([0xC3])
    assert len(out)==total,(len(out),total)
    return out

# ============================ THE FORCING PROGRAMS (A producer / B consumer) ============================
# A reads N held-back random 24-bit words from COM1, ECHOES each (le32(w), A's own output) and YIELDS each to B.
# B receives each via yield, writes le32(3*w) (the cross-yield-DERIVED output), recurses; terminates on sentinel 0.
# The debugcon write-frames INTERLEAVE A:w0, B:3*w0, A:w1, B:3*w1, ... (the kernel-scheduled witness; a sequential
# run-A-then-B would emit all of A then all of B). f(w)=3*w is producible by B ONLY via the mailbox (w is held-back
# random, read only by A). readword is byte-identical to mumbani's (same source line).
A_FUNCS=[
  ('main',0,[('call',('readword',0)),('storel',0),         # n = readword()
             ('push',0),('yield',0),('storel',1),          # wake = yield(0)  (park B)
             ('loadl',0),('call',('drive',1)),('ret',0)]), # return drive(n)
  ('readword',0,[('sysread',0),('storel',0),('sysread',0),('storel',1),('sysread',0),('storel',2),
                 ('loadl',0),('push',256),('loadl',1),('push',256),('loadl',2),
                 ('mul',0),('add',0),('mul',0),('add',0),('ret',0)]),
  ('drive',1,[('loadl',0),('push',0),('eq',0),('brf',9),       # 0..3: if k==0
              ('push',0),('yield',0),('storel',1),             # 4..6: z = yield(0)  [sentinel; z=slot1]
              ('push',0),('ret',0),                            # 7,8: return 0
              ('call',('readword',0)),('storel',2),            # 9,10: w = readword()  [w=slot2]
              ('loadl',2),('syswrite',0),('storel',3),         # 11..13: e = sys_write(w)  (A echo) [e=slot3]
              ('loadl',2),('yield',0),('storel',4),            # 14..16: a = yield(w)  [a=slot4]
              ('loadl',0),('push',1),('sub',0),('call',('drive',1)),('ret',0)]),  # 17..21: return drive(k-1)
]
B_FUNCS=[
  ('main',0,[('call',('consume',0)),('ret',0)]),
  ('consume',0,[('push',0),('yield',0),('storel',0),       # 0,1,2: a = yield(0)
                ('loadl',0),('push',0),('eq',0),('brf',9), # 3..6: if a==0 skip
                ('push',0),('ret',0),                      # 7,8: return 0
                ('loadl',0),('push',3),('mul',0),('syswrite',0),('storel',1),  # 9..13: d = sys_write(3*a)
                ('call',('consume',0)),('ret',0)]),        # 14,15: return consume()
]
def module_A_real(): return module_emit(A_FUNCS)
def module_B_real(): return module_emit(B_FUNCS)

# ---- .herb SOURCES (the program bodies, no emit-directive line; the gate prepends the marker). These compile
# BYTE-IDENTICAL to module_A_real()/module_B_real() via the module-tandem emit mode (verified). ----
def herb_src_A():
    return ("func readword():\n    let b0 = sys_read()\n    let b1 = sys_read()\n    let b2 = sys_read()\n"
            "    return b0 + 256 * (b1 + 256 * b2)\nend\n"
            "func drive(k):\n    if k == 0:\n        let z = yield(0)\n        return 0\n    end\n"
            "    let w = readword()\n    let e = sys_write(w)\n    let a = yield(w)\n    return drive(k - 1)\nend\n"
            "func main():\n    let n = readword()\n    let wake = yield(0)\n    return drive(n)\nend")
def herb_src_B():
    return ("func consume():\n    let a = yield(0)\n    if a == 0:\n        return 0\n    end\n"
            "    let d = sys_write(a * 3)\n    return consume()\nend\n"
            "func main():\n    return consume()\nend")

# ---- HOSTILE-PEER probe: a variant A (mod[0], active/User) that writes into B's region (Supervisor while A runs).
# A is PIC: its entry esp == alloc_hi == alloc_lo2 (B's region start), so `mov eax,esp; add eax,0x10; mov [eax],imm`
# targets B's window -> #PF (err P|W|U=7, CR2 in [alloc_lo2,alloc_hi2), cs RPL3), caught by geeking fault->continue.
# A single-address-space forge CANNOT produce this fault. (KVM-load-bearing: iret-to-CPL3 + the PTE-flip.)
def module_hostile_peer():
    return bytes([0x89,0xE0,        # mov eax,esp          (= alloc_hi = B region start)
                  0x05,0x10,0,0,0,  # add eax,0x10
                  0xC7,0x00,0x44,0x33,0x22,0x11,  # mov dword [eax],0x11223344  -> WRITE into B's page -> #PF err 7
                  0xEB,0xFE])       # jmp $ (never reached; #PF preempts)
def module_hostile_read():
    # a variant A that READS B's region (Supervisor while A runs) -> #PF err 5 (P|U, no W) -- confidentiality
    # isolation (peer A cannot READ peer B), complementing the write probe. CR2 in B's window, cs RPL3.
    return bytes([0x89,0xE0,        # mov eax,esp
                  0x05,0x10,0,0,0,  # add eax,0x10
                  0x8B,0x18,        # mov ebx,[eax]   -> READ B's page -> #PF err 5
                  0xEB,0xFE])       # jmp $

import random
NDEF=24   # N held-back words; small enough to fit one page each, big enough to be unfakeable random
SEEDS={'gx':0x7A2E10,'gy':0x7A2E11}
def _resolve(arg):
    if arg in SEEDS: return SEEDS[arg],NDEF
    return int(arg)&0xFFFFFFFF,NDEF
def _words(seed,N):
    rng=random.Random(seed)
    return [rng.randint(1,0x7F)|(rng.randint(1,0x7F)<<8)|(rng.randint(1,0x7F)<<16) for _ in range(N)]
def fed_stream(arg='gx'):
    seed,N=_resolve(arg); words=_words(seed,N)
    out=bytes([N&0xFF,(N>>8)&0xFF,(N>>16)&0xFF])
    for w in words: out+=bytes([w&0xFF,(w>>8)&0xFF,(w>>16)&0xFF])
    return out
def host_A_writes(arg='gx'):
    seed,N=_resolve(arg); return [le32(w) for w in _words(seed,N)]
def host_B_writes(arg='gx'):
    seed,N=_resolve(arg); return [le32((3*w)&0xFFFFFFFF) for w in _words(seed,N)]
def expect_reads(arg='gx'):
    seed,N=_resolve(arg); return 3*(N+1)

XORK=0x00ABCDEF   # (legacy, unused)
# ---- SIMPLE scheduler test (fixed values, N=2) ----
A_SIMPLE=[('main',0,[('push',0),('yield',0),('storel',0),
                     ('push',0x41),('yield',0),('storel',1),
                     ('push',0x42),('yield',0),('storel',2),
                     ('push',0),('yield',0),('storel',3),
                     ('push',0),('ret',0)])]
B_SIMPLE=[('main',0,[('call',('consume',0)),('ret',0)]),
          ('consume',0,[('push',0),('yield',0),('storel',0),       # 0,1,2: a = yield(0)
                        ('loadl',0),('push',0),('eq',0),('brf',9), # 3,4,5,6: if a==0 skip-to-9
                        ('push',0),('ret',0),                      # 7,8: return 0
                        ('loadl',0),('syswrite',0),('storel',1),   # 9,10,11: d = sys_write(a)
                        ('call',('consume',0)),('ret',0)])]        # 12,13: return consume()
def module_A(kind='simple'): return module_emit(A_SIMPLE)
def module_B(kind='simple'): return module_emit(B_SIMPLE)

# ============================ PARSE + GRADE ============================
import re
def parse_head(stream):
    i=0
    while i<len(stream) and stream[i]==0x9C and i+25<=len(stream): i+=25
    if i>=len(stream) or stream[i]!=0x9A: return None
    i+=1; k0,k1,ma,ml=struct.unpack('<4I',stream[i:i+16]); i+=16
    nc=len(CELLS); cells=struct.unpack('<%dI'%nc,stream[i:i+4*nc]); i+=4*nc
    cd=dict(zip(CELLS,cells)); cd['k0']=k0; cd['k1']=k1
    cd['_blockok']=(i<len(stream) and stream[i]==0x9B); i+=1
    cd['_tail']=stream[i:]
    return cd
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
def _rframes(tail):
    return [m.start() for m in re.finditer(rb'\xC0.{13}\xC1', tail, re.S)]

def grade(stream, kend_elf, arg='gx'):
    """RUNTIME grade for the two-program cooperative run. Pins, all on the existing debugcon/COM1 oracle:
       - both alloc regions recomputed match the dumped cells; regions distinct.
       - A's reads delivered (3*(N+1) read-frames).
       - A's writes == le32(w_i) (echo) at eip in [modstart,modend), esp in regionA; B's writes == le32(3*w_i)
         at eip in [modstart2,modend2), esp in regionB. Both count N.
       - INTERLEAVE: write-frames alternate A_i,B_i,... (kernel-scheduled witness; run-A-then-B emits A*,B*).
       - switch counter (C8<sw>C9) >= 2N (genuine ping-pong).
       - answer == 0 (A exited clean)."""
    errs=[]; seed,N=_resolve(arg)
    r=parse_head(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or kernel RED)']
    if r['k1']!=kend_elf: errs.append(f'k1=0x{r["k1"]:x} != kend 0x{kend_elf:x}')
    al,ah,al2,ah2=r['alloc_lo'],r['alloc_hi'],r['alloc_lo2'],r['alloc_hi2']
    ms,me,ms2,me2=r['modstart'],r['modend'],r['modstart2'],r['modend2']
    if ah-al!=0x1000: errs.append('regionA != 1 page')
    if ah2-al2!=0x1000: errs.append('regionB != 1 page')
    if al<ah2 and al2<ah: errs.append('regionA/regionB OVERLAP (not isolated)')
    tail=r['_tail']
    rfs=_rframes(tail)
    if len(rfs)!=expect_reads(arg):
        errs.append(f'{len(rfs)} read-frames != expected {expect_reads(arg)} (=3*(N+1); A skipped input)')
    wfs=[w for w in _wframes(tail) if w['closed'] and w['ln']==4 and w['cs']==UCODE3 and (w['cs']&3)==3]
    Aw=[w for w in wfs if ms<=w['eip']<me]
    Bw=[w for w in wfs if ms2<=w['eip']<me2]
    other=[w for w in wfs if not (ms<=w['eip']<me or ms2<=w['eip']<me2)]
    if other: errs.append(f'{len(other)} write-frame(s) from neither module range (eip e.g. 0x{other[0]["eip"]:x})')
    wantA=host_A_writes(arg); wantB=host_B_writes(arg)
    if len(Aw)!=N: errs.append(f'A wrote {len(Aw)} frames != N={N}')
    if len(Bw)!=N: errs.append(f'B wrote {len(Bw)} frames != N={N}')
    for j,w in enumerate(Aw[:N]):
        if w['body']!=wantA[j]: errs.append(f'A write {j} {w["body"].hex()} != le32(w_{j}) {wantA[j].hex()}')
        if not (al<=w['esp']<ah): errs.append(f'A write {j} esp 0x{w["esp"]:x} not in regionA')
    for j,w in enumerate(Bw[:N]):
        if w['body']!=wantB[j]: errs.append(f'B write {j} {w["body"].hex()} != le32(3*w_{j}) {wantB[j].hex()} (cross-yield-derived)')
        if not (al2<=w['esp']<ah2): errs.append(f'B write {j} esp 0x{w["esp"]:x} not in regionB')
    # INTERLEAVE: in stream order the module-writes must alternate A,B,A,B (A_i then B_i)
    seq=[('A' if ms<=w['eip']<me else 'B') for w in wfs]
    expect_seq=['A','B']*N
    if seq!=expect_seq:
        errs.append(f'write interleave {"".join(seq)[:20]}... != ABAB... (kernel-scheduled witness FAILED; run-A-then-B?)')
    # switch counter
    m=re.search(rb'\xC8(.{4})\xC9', tail, re.S)
    if not m: errs.append('no switch-counter frame (C8<sw>C9)')
    else:
        sw=struct.unpack('<I',m.group(1))[0]
        if sw < 2*N: errs.append(f'switches {sw} < 2N={2*N} (insufficient ping-pong)')
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if not an or an.group(1)[0]!=0: errs.append(f'answer {an.group(1)[0] if an else None} != 0 (A exit status)')
    return errs

def assert_tandem(kelf):
    """White-box: the kernel carries the mods_count==2 gate (cmp eax,2 = 83 F8 02, distinct from a 1-program
       kernel's 83 F8 01) AND references a SECOND alloc region cell (alloc_lo2) -- so it is genuinely a two-program
       kernel, not a re-skinned single-program one. (The byte-pin to build_elf() is the primary binding; this is a
       structural smoke test that survives an emitter that fakes the bytes another way.)"""
    # the EXACT mods_count gate: mov eax,[esi+20]; cmp eax,2  (a 1-program kernel has ...83 F8 01 here; the bare
    # 83 F8 01 elsewhere is the legitimate mem-map type==1 check, mov eax,[ecx+20] = 8B 41 14, so we pin the FULL
    # mods-site sequence 8B 46 14 83 F8 0x to discriminate without false-positiving on the type check).
    if bytes([0x8B,0x46,0x14,0x83,0xF8,0x02]) not in kelf: return False   # mods_count==2 gate present
    if bytes([0x8B,0x46,0x14,0x83,0xF8,0x01]) in kelf: return False       # the ==1 (single-program) gate absent
    if le32(cell('alloc_lo2')) not in kelf: return False        # a SECOND alloc region cell
    if le32(cell('modstart2')) not in kelf: return False        # the SECOND module is parsed
    return True

def grade_hostile(stream, kend_elf, kind='write'):
    """A (active, User) accessing peer B's region (Supervisor while A runs) must #PF -- the un-fakeable PEER
       isolation proof (a single address space cannot produce a CR2-in-peer-window fault). EXACT err pin:
       a WRITE faults err==7 (P|W/R|U/S); a READ faults err==5 (P|U/S, no W) -- proving BOTH directions
       (confidentiality + integrity). cs RPL3, CR2 strictly inside [alloc_lo2,alloc_hi2) AND outside the
       kernel + A's region, answer named 'P' (fault->continue)."""
    errs=[]; r=parse_head(stream)
    if not r: return ['no OWN table parsed']
    al,ah,al2,ah2=r['alloc_lo'],r['alloc_hi'],r['alloc_lo2'],r['alloc_hi2']; tail=r['_tail']
    want_err = 5 if kind=='read' else 7
    pf=re.search(rb'\xD0(.{4})(.{4})(.{4})(.{4})(.{4})\xD1', tail, re.S)
    if not pf: return [f'no #PF witness frame (D0..D1) -- the hostile peer {kind} did NOT fault (isolation BROKEN)']
    err,eip,cs,cr2,esp=[struct.unpack('<I',pf.group(k))[0] for k in (1,2,3,4,5)]
    if err!=want_err: errs.append(f'#PF err 0x{err:x} != exact 0x{want_err:x} (a {kind} of a present supervisor peer page)')
    if (cs&3)!=3: errs.append(f'#PF cs 0x{cs:x} RPL != 3 (fault not from CPL3 module)')
    if not (al2<=cr2<ah2): errs.append(f'#PF CR2 0x{cr2:x} not in B region [0x{al2:x},0x{ah2:x}) -- not a PEER fault')
    if al<=cr2<ah: errs.append(f'#PF CR2 0x{cr2:x} is in A''s OWN region (not a peer fault)')
    if 0x100000<=cr2<kend_elf: errs.append(f'#PF CR2 0x{cr2:x} is in the kernel image (not a peer fault)')
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if not an or an.group(1)[0]!=0x50: errs.append('answer != 0x50 (P) -- fault->continue did not name the #PF')
    return errs

if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='modhostile': open(sys.argv[2],'wb').write(module_hostile_peer())
    elif cmd=='modhostileread': open(sys.argv[2],'wb').write(module_hostile_read())
    elif cmd=='gradehostile':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        kind=sys.argv[4] if len(sys.argv)>4 else 'write'
        errs=grade_hostile(stream,kend,kind)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='tandem':
        sys.exit(0 if assert_tandem(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='modA': open(sys.argv[2],'wb').write(module_A_real())
    elif cmd=='modB': open(sys.argv[2],'wb').write(module_B_real())
    elif cmd=='modA_simple': open(sys.argv[2],'wb').write(module_A())
    elif cmd=='modB_simple': open(sys.argv[2],'wb').write(module_B())
    elif cmd=='modhex': print((module_A_real() if sys.argv[2]=='A' else module_B_real()).hex())
    elif cmd=='srcA': sys.stdout.write(herb_src_A())
    elif cmd=='srcB': sys.stdout.write(herb_src_B())
    elif cmd=='stream': sys.stdout.write(' '.join(str(b) for b in fed_stream(sys.argv[2] if len(sys.argv)>2 else 'gx')))
    elif cmd=='kernelelf':
        mut=sys.argv[3] if len(sys.argv)>3 else None
        stage=sys.argv[4] if len(sys.argv)>4 else 'full'
        img,kend,_=build_elf(mut if mut!='none' else None,stage); open(sys.argv[2],'wb').write(img); print('%x'%kend)
    elif cmd=='kend':
        _,kend,_=build_elf(); print('%x'%kend)
    elif cmd=='grade':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        arg=sys.argv[4] if len(sys.argv)>4 else 'gx'
        errs=grade(stream,kend,arg)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    else: raise SystemExit('usage: modA|modB|stream|kernelelf|kend|grade')
