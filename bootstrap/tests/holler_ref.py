#!/usr/bin/env python3
# holler_ref.py -- holler (link 24 / native-codegen Link 40) integrated reference.
# C3 / SYS_WRITE: THE COMPILED MODULE EMITS ITS OWN MULTI-BYTE OUTPUT. The geeking kernel head below is kept
# BYTE-IDENTICAL; holler ADDS a do_write (int 0x30, eax=2) arm -- the FIRST confused-deputy kernel-contract
# surface (the kernel dereferences a module-supplied buffer at CPL0 where paging U/S does NOT fault, so an
# explicit software access_ok against the module's User page [alloc_lo,alloc_hi) -- read BY VALUE -- is the
# ONLY thing between a hostile module and a kernel-memory leak; M-nobounds makes the leak EMPIRICALLY real).
# The do_write arm + the link24 SYS_WRITE modules/graders/GATE-SPEC are below the geeking head. build_code/
# build_elf/graders/module builders are the PROVEN STEP-0 (QEMU+KVM+Bochs, 22/22) -- keep byte-for-byte.
#
# === geeking head provenance (kept byte-identical; do_write was absorbed by the align-pad, prefixlen 24564) ===
# THE KERNEL OUTLIVES ITS MODULE -- the lifecycle TERMINATE verb, both halves, grafted onto sitopia's
# proven resumable-syscall head (which is itself trukfit's COM1 read INTO nokta's ring-3-under-paging head):
#   (i) ASYNC WATCHDOG-KILL: a one-shot PIT (mode 0, ~55ms) armed per iretd-to-CPL3 (after a stale-IRR
#       drain), vec-0x20 tick handler RPL-KEYED -- a tick that lands IN THE MODULE (RPL3, IF=1 seed 0x202)
#       reloads kernel segs, EOIs, dumps a kill-witness frame CA<eip><cs><useresp><eflags>CB, stores 'K'
#       into [answer], switches to kstack and JMPs the body (NEVER iret to a killed module). The first
#       CPU-authored ASYNC ring-cross frame any landed link has produced. A tick at CPL0 (drain/poll) -> EOI+iret.
#   (ii) FAULT->CONTINUE: the #GP (vec 13) and #PF (vec 14) witness frames stay BYTE-IDENTICAL nokta, but
#       the TAILS no longer shutdown(): they store the fault kind ('G'=0x47 / 'P'=0x50) into [answer],
#       switch to kstack, and JMP the body -- the kernel NAMES the fault and keeps computing (DE47AD/DE50AD).
# Everything else in the head is byte-identical sitopia. Deltas vs sitopia are the proven step-0 watchdog
# set (/tmp/link21-step0/proto.py) PLUS the two fault tails + the geeking mutation knobs below.
#
# --- sitopia provenance (head is byte-identical) ---
# Grafts trukfit's PROVEN COM1 read lowering INTO nokta's PROVEN ring-3-under-paging head, turning the
# exit-only int 0x30 gate into a RESUMABLE SYSCALL ABI with a kernel SERVICE the sandboxed module cannot
# perform itself:
#
#   The build-unknown module runs at CPL3 under paging (nokta's sandbox). It issues a SYS_READ syscall
#   (int 0x30, eax=0); the kernel handler at CPL0 polls the COM1 LSR + reads the RBR byte (a LATE-BOUND
#   device read the CPL3 module CANNOT do itself -- a module `in al,dx` faults #GP, the IOPB is beyond
#   the TSS limit), dumps a read-witness frame, and IRETS BACK TO CPL3 with the byte in eax (the first
#   kernel->module re-entry). The module RESUMES, transforms the byte in its OWN code (module-resident
#   transform), and issues SYS_EXIT (int 0x30, eax=1, status in bl); the kernel stores the status, dumps
#   an exit-witness frame, and the compiled body (a PURE CONDUIT) emits f(status)=DE<status>AD.
#
# THE MAKE-OR-BREAK: the final answer is a transform of a byte the kernel DELIVERED into the module via a
# round trip the module could not do itself -- so the same image fed byte X vs Y emits T(X) vs T(Y), and a
# CPL0-only kernel pinned as a pure conduit cannot fake it. Proven by per-syscall witness frames pinned BY
# VALUE (cs==UCODE3 RPL3, eip==mod_start+exact-offset, useresp==alloc_hi), the inter-frame eip distance ==
# the module's transform-code length (the module ran between the syscalls), the delivered byte == the fed
# byte, the answer == T(fed byte), and X != Y -- all witnessed byte-identically on QEMU + Bochs + KVM.
import struct, sys, re

OUT=0xE9; LOAD=0x100000; ENTRY=0x10000C
KCODE=0x08; KDATA=0x10; UCODE=0x18; UDATA=0x20; TSS_SEL=0x28
UCODE3=UCODE|3; UDATA3=UDATA|3
SYS_READ=0; SYS_EXIT=1; SYS_WRITE=2   # link24: SYS_WRITE -- the module emits its OWN multi-byte output
NPT=4                       # 4 page tables -> COVER = 16 MiB (covers kernel+module+alloc with margin)
COVER=NPT*0x400000
CANARY_VADDR=ENTRY+7+5+12*4 # cell('answer') -- a present, mapped, Supervisor kernel cell (hostile target)
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def le16(v): return struct.pack('<H', v & 0xFFFF)
CELLS=['mbinfo','flags','modstart','modend','str','cmdline','elflo','elfhi',
       'region_lo','region_hi','alloc_lo','alloc_hi','answer',
       'mb_lo','mb_hi','st_lo','st_hi','cm_lo','cm_hi','mm_lo','mm_hi']
CIDX={n:i for i,n in enumerate(CELLS)}
CELLBASE=ENTRY+7+5
def cell(n): return CELLBASE+CIDX[n]*4
JNE,JE,JB,JAE,JA,JBE=0x85,0x84,0x82,0x83,0x87,0x86

class Asm:
    def __init__(s): s.items=[]
    def raw(s,*b): s.items.append(('b',bytes(b)))
    def blob(s,b): s.items.append(('b',bytes(b)))
    def lbl(s,n): s.items.append(('L',n))
    def j(s,cc,n): s.items.append(('J',cc,n))
    def absR(s,n,add=0): s.items.append(('A',n,add))
    def defer(s,length,fn): s.items.append(('D',length,fn))
    def align(s,a): s.items.append(('G',a))
    def _layout(s):
        off=0; pos={}
        for it in s.items:
            t=it[0]
            if t=='b': off+=len(it[1])
            elif t=='L': pos[it[1]]=off
            elif t=='J': off+=(5 if it[1] is None else 6)
            elif t=='A': off+=4
            elif t=='D': off+=it[1]
            elif t=='G': off+=(-(ENTRY+off))%it[1]
        return pos,off
    def assemble(s):
        pos,total=s._layout()
        labels={n:ENTRY+o for n,o in pos.items()}
        out=bytearray(); off=0
        for it in s.items:
            t=it[0]
            if t=='b': out+=it[1]; off+=len(it[1])
            elif t=='L': pass
            elif t=='J':
                cc,n=it[1],it[2]
                if cc is None: out+=b'\xE9'+struct.pack('<i',pos[n]-(off+5)); off+=5
                else: out+=bytes((0x0F,cc))+struct.pack('<i',pos[n]-(off+6)); off+=6
            elif t=='A':
                n,add=it[1],it[2]; out+=le32(ENTRY+pos[n]+add); off+=4
            elif t=='D':
                b=it[2](labels); assert len(b)==it[1],(len(b),it[1]); out+=b; off+=len(b)
            elif t=='G':
                pad=(-(ENTRY+off))%it[1]; out+=b'\x00'*pad; off+=pad
        return bytes(out),labels

def gdt_desc(base, limit, access, flags):
    return bytes([limit&0xFF,(limit>>8)&0xFF, base&0xFF,(base>>8)&0xFF,(base>>16)&0xFF,
                  access, ((flags&0xF)<<4)|((limit>>16)&0xF), (base>>24)&0xFF])
def idt_gate(off, sel, typ):
    return le16(off&0xFFFF)+le16(sel)+bytes([0,typ])+le16((off>>16)&0xFFFF)

KILL_STATUS=0x4B   # 'K' -- stored into [answer] on a CPL3-keyed timer kill; body emits DE 4B AD = f(kill)
PIT_COUNT=0xFFFF   # one-shot / periodic reload count ~= 55ms at 1.193182 MHz

def build_code(kstack, kend, mut=None, design='oneshot'):
    a=Asm()
    a._dctr=0
    def mmi(addr,imm): a.raw(0xC7,0x05); a.blob(le32(addr)); a.blob(le32(imm))
    def mme(addr): a.raw(0xA3); a.blob(le32(addr))
    def mem(addr): a.raw(0xA1); a.blob(le32(addr))
    def outi(v): a.raw(0xB0,v,0xE6,OUT)
    # ---- link21 timer machinery -------------------------------------------------------------
    def pic_remap():
        # crib cloggard's exact 8259 ICW sequence (vectors 0x20/0x28, only IRQ0 unmasked).
        for v,p in [(0x11,0x20),(0x11,0xA0),(0x20,0x21),(0x28,0xA1),(0x04,0x21),(0x02,0xA1),
                    (0x01,0x21),(0x01,0xA1),(0xFE,0x21),(0xFF,0xA1)]:
            a.raw(0xB0,v,0xE6,p)              # mov al,v ; out p,al
    def pit_arm(mode_cmd):
        a.raw(0xB0,mode_cmd,0xE6,0x43)        # mov al,cmd ; out 0x43,al  (channel0 lo/hi)
        a.raw(0xB0,PIT_COUNT&0xFF,0xE6,0x40)  # lo count
        a.raw(0xB0,(PIT_COUNT>>8)&0xFF,0xE6,0x40)  # hi count
    def drain_then_rearm():
        # ONLY in the one-shot design. At CPL0: open a brief sti;nop;nop;cli window up to 4x so any
        # STALE latched IRQ0 (latched during the IF=0 COM1 poll) delivers to the RPL0 discard path
        # BEFORE we enter the module; stop early when PIC IRR bit0 reads clear. THEN re-arm the
        # one-shot fresh. Order matters: drain (kill stale periodic-era ticks) BEFORE arming.
        if design in ('oneshot','oneshot_nodrain'):
            if design=='oneshot':
                a._dctr+=1; done=f'drain_done_{a._dctr}'
                for _ in range(4):
                    a.raw(0xFB,0x90,0x90,0xFA)    # sti ; nop ; nop ; cli   (1-insn sti delay -> tick in window)
                    a.raw(0xB0,0x0A,0xE6,0x20)     # OCW3: mov al,0x0A ; out 0x20,al  (latch IRR for read)
                    a.raw(0xE4,0x20)               # in al,0x20   -> al = IRR
                    a.raw(0xA8,0x01)               # test al,1
                    a.j(JE,done)                   # IRR bit0 clear -> drained
                a.lbl(done)
            pit_arm(0x30)                      # re-arm one-shot (mode 0): fresh ~55ms window. NOTE: the kernel
            # re-arm controls tick TIMING/determinism, not tick existence -- GRUB/BIOS leaves the 8254 ticking
            # (~18.2 Hz) from before handoff, so IRQ0 fires regardless of the re-arm (a "no-arm" mutation does
            # NOT prevent the kill; the drain + one-shot give the controlled 55ms window the determinism needs).
        # naive design: PIT is periodic + armed once in the head; no drain, no re-arm here.
    def dr_eax():
        a.raw(0xE6,OUT)
        for _ in range(3): a.raw(0xC1,0xE8,0x08,0xE6,OUT)
    def alignup_eax(): a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000))
    def shutdown():
        a.raw(0x66,0xBA,0xF4,0x00); a.raw(0xEE)
        a.raw(0x66,0xBA,0x00,0x89)
        for ch in b'Shutdown': a.raw(0xB0,ch,0xEE)
        a.raw(0xFA,0xF4,0xEB,0xFD)

    # ===== HEAD (capture + discover + parse-map + bump-alloc + dump) -- BYTE-IDENTICAL to nokta_ref =====
    a.blob(bytes((0x89,0x1D))+le32(cell('mbinfo')))   # mov [mbinfo],ebx  (byte 0)
    a.j(None,'glue')
    a.blob(b'\x00'*(len(CELLS)*4))
    sd_FAILS=['F1','F2','F3','F4','F5','F8','F9','F10']
    for idx,f in enumerate(sd_FAILS):
        a.lbl(f); a.blob(bytes([176,0x31+idx,0xE6,OUT])); a.j(None,'sdtail')
    a.lbl('sdtail'); shutdown()
    a.lbl('glue')
    a.raw(0x3D); a.blob(le32(0x2BADB002)); a.j(JNE,'F1')
    a.raw(0xBC); a.blob(le32(kstack))
    a.raw(0x31,0xC0); a.raw(0x0F,0x22,0xE0)
    a.raw(0x68); a.blob(le32(0x00000002)); a.raw(0x9D)
    a.raw(0x8B,0x35); a.blob(le32(cell('mbinfo')))
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
    a.raw(0x8B,0x46,20); a.raw(0x83,0xF8,0x01); a.j(JNE,'F4')
    a.raw(0x8B,0x6E,24)
    a.raw(0x8B,0x45,0x00); mme(cell('modstart'))
    a.raw(0x8B,0x45,0x04); mme(cell('modend'))
    a.raw(0x8B,0x45,0x08); mme(cell('str'))
    mem(cell('modstart')); a.raw(0x3B,0x05); a.blob(le32(cell('modend'))); a.j(JAE,'F5')
    a._ctr=0
    def excl_ptr(srccell, locell, hicell):
        a._ctr+=1; z=f'exz{a._ctr}'; d=f'exd{a._ctr}'
        mem(srccell); a.raw(0x85,0xC0); a.j(JE,z)
        a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(locell)
        a.raw(0x05); a.blob(le32(0x2000)); mme(hicell)
        a.j(None,d); a.lbl(z); mmi(locell,0); mmi(hicell,0); a.lbl(d)
    excl_ptr(cell('mbinfo'), cell('mb_lo'), cell('mb_hi'))
    excl_ptr(cell('str'),    cell('st_lo'), cell('st_hi'))
    excl_ptr(cell('cmdline'),cell('cm_lo'), cell('cm_hi'))
    a.raw(0x8B,0x46,48); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_lo'))
    a.raw(0x8B,0x46,48); a.raw(0x03,0x46,44); a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_hi'))
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
    mem(cell('region_lo')); a.raw(0x3D); a.blob(le32(0x100000)); a.j(JAE,'have_floor')
    a.raw(0xB8); a.blob(le32(0x100000)); a.lbl('have_floor')
    alignup_eax(); a.raw(0x89,0xC1)
    a.raw(0xBF); a.blob(le32(16))
    a.lbl('rescan')
    a.raw(0x4F); a.j(JE,'F10')
    a.raw(0x31,0xDB)
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
    if mut!='noexclude':
        excl(('lit',0x100000), ('lit',kend))
        excl(('cell',cell('modstart')), ('cell',cell('modend')))
        if mut!='noexclbuf':
            excl(('cell',cell('mb_lo')), ('cell',cell('mb_hi')))
            excl(('cell',cell('st_lo')), ('cell',cell('st_hi')))
            excl(('cell',cell('cm_lo')), ('cell',cell('cm_hi')))
            excl(('cell',cell('elflo')), ('cell',cell('elfhi')))
            excl(('cell',cell('mm_lo')), ('cell',cell('mm_hi')))
    a.raw(0x85,0xDB); a.j(JNE,'rescan')
    a.raw(0x8D,0x81); a.blob(le32(0x1000))
    a.raw(0x3B,0x05); a.blob(le32(cell('region_hi'))); a.j(JA,'F10')
    if mut=='hardcodeaddr':
        a.raw(0xB9); a.blob(le32(0x300000))
    a.raw(0x89,0x0D); a.blob(le32(cell('alloc_lo')))
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); mme(cell('alloc_hi'))
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

    # ===== install ring machinery (lgdt/lidt/ltr) -- BYTE-IDENTICAL to nokta_ref =====
    a.raw(0x0F,0x01,0x15); a.absR('gdtr')
    a.raw(0xEA); a.absR('reload'); a.raw(0x08,0x00)
    a.lbl('reload')
    a.raw(0xB8); a.blob(le32(KDATA))
    a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xD0,0x8E,0xE0,0x8E,0xE8)
    a.raw(0x0F,0x01,0x1D); a.absR('idtr')
    a.raw(0x66,0xB8,TSS_SEL,0x00); a.raw(0x0F,0x00,0xD8)

    # ===== turn paging ON + flip the module's pages to User -- BYTE-IDENTICAL to nokta_ref =====
    if mut!='nopaging':
        a.raw(0xB8); a.absR('pd')
        a.raw(0x0F,0x22,0xD8)
        a.raw(0x0F,0x20,0xC0)
        a.raw(0x0D); a.blob(le32(0x80000000))
        a.raw(0x0F,0x22,0xC0)
        a.raw(0xEB,0x00)
        def flip_user(srccell):
            a.raw(0xA1); a.blob(le32(srccell))
            a.raw(0xC1,0xE8,0x0A)
            a.raw(0x25); a.blob(le32(0xFFFFFFFC))
            a.raw(0x05); a.absR('pt')
            a.raw(0x83,0x08,0x04)
        if mut!='nomodflip':   flip_user(cell('modstart'))
        if mut!='nostackflip': flip_user(cell('alloc_lo'))
        if mut=='canaryuser':
            a.raw(0xB8); a.blob(le32(CANARY_VADDR))
            a.raw(0xC1,0xE8,0x0A); a.raw(0x25); a.blob(le32(0xFFFFFFFC)); a.raw(0x05); a.absR('pt'); a.raw(0x83,0x08,0x04)
        a.raw(0xB8); a.absR('pd'); a.raw(0x0F,0x22,0xD8)

    # ===== NEW (sitopia): init COM1 once at CPL0 (trukfit's proven 56-byte robust UART init) so the
    # SYS_READ service can poll+read it. CPL0 I/O works regardless of paging (I/O is IOPL/IOPB-gated).
    # Pinned by value (it sits inside the prefix byte-pin) but DEFENSIVE, not a biting mutation: QEMU/KVM
    # deliver the byte without it, so a "no-init" variant does not bite on the graded substrates -- the init
    # is the correctness contract for a real 16550 (tier-2), the same honest status nokta gives its CR3 reload.
    for port,val in [(0x3FB,0x03),(0x3F9,0x00),(0x3FB,0x80),(0x3F8,0x01),
                     (0x3F9,0x00),(0x3FB,0x03),(0x3FA,0x00),(0x3FC,0x03)]:
        a.raw(0x66,0xBA); a.blob(le16(port)); a.raw(0xB0,val,0xEE)

    # ===== NEW (link21): remap the PIC (vectors 0x20/0x28, only IRQ0 unmasked). In the NAIVE control we
    # also arm a FREE-RUNNING periodic PIT once here; in the one-shot design the PIT is armed per-iretd
    # by drain_then_rearm(). Kernel stays IF=0 (interrupt gates) except the brief drain windows. =====
    pic_remap()
    if design=='naive':
        pit_arm(0x34)                                          # periodic (mode 2) -- free-running ticks

    if mut=='callcpl0':
        a.raw(0x8B,0x25); a.blob(le32(cell('alloc_hi')))
        a.raw(0xFF,0x15); a.blob(le32(cell('modstart')))
        mme(cell('answer')); a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC)
        a.j(None,'body_start')
    else:
        a.raw(0xB8); a.blob(le32(UDATA3))
        a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
        # link21: seed EFLAGS image with IF=1 (0x202) so a CPL3 timer IRQ0 can preempt the module.
        # M-ifzero: seed 0x002 (IF=0) -> the CPL3 module runs with interrupts MASKED -> the one-shot tick
        # is never delivered -> the runaway victim is never killed -> timeout (SILICON-RED negative control).
        ef = (0x00003202 if mut=='iopl3frame' else
              0x00000002 if mut=='ifzero' else 0x00000202)
        uc = UCODE if mut=='dpl0frame' else UCODE3
        us = UDATA if mut=='dpl0frame' else UDATA3
        drain_then_rearm()                                    # drain stale ticks + arm one-shot (one-shot design)
        a.raw(0x68); a.blob(le32(us))
        a.raw(0xFF,0x35); a.blob(le32(cell('alloc_hi')))
        a.raw(0x68); a.blob(le32(ef))
        a.raw(0x68); a.blob(le32(uc))
        a.raw(0xFF,0x35); a.blob(le32(cell('modstart')))
        a.raw(0xCF)                                            # iretd -> CPL3 at the module (IF=1)

    # ===== syscall handler (vec 0x30): DISPATCH on eax. SYS_READ=0 reads COM1 + IRETS BACK to CPL3 with
    # the byte in eax (the new kernel->module re-entry); else SYS_EXIT (status in bl -> [answer] -> body). =====
    # The handler FALLS THROUGH (via SYS_EXIT's jmp) to the compiled body, which reads [answer] (pure conduit).
    a.lbl('exit_handler')   # IDT-wired label name kept from nokta
    # entry: eax=syscall#, DS/ES/FS/GS=UDATA3, SS=KDATA, esp=esp0 frame [eip,cs,eflags,useresp,userss].
    if mut!='nodispatch':
        a.raw(0x85,0xC0)                                       # test eax,eax
        a.j(JE,'do_read')                                      # jz do_read (SYS_READ)
        a.raw(0x83,0xF8,0x02)                                  # cmp eax,2   (SYS_WRITE)
        a.j(JE,'do_write')                                     # jz do_write; else fall to SYS_EXIT (eax=1)
    # ---- SYS_EXIT: status in bl. Reload kernel data segs FIRST (clobbers eax/al, NOT bl). ----
    a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    acell = cell('flags') if mut=='wrongcell' else cell('answer')
    a.raw(0x88,0xD8); a.raw(0xA2); a.blob(le32(acell))         # mov al,bl ; mov [answer],al
    outi(0xE0)
    a.raw(0x88,0xD8,0xE6,OUT)                                  # mov al,bl ; out (status)
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                       # cs   = [esp+4]
    a.raw(0x8B,0x04,0x24); dr_eax()                            # eip  = [esp+0]
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                       # useresp = [esp+12]
    outi(0xE1)
    a.raw(0xBC); a.blob(le32(kstack))                          # mov esp,kstack
    a.raw(0xFC)                                                # cld
    a.j(None,'body_start')
    # ---- SYS_READ: poll COM1 LSR + read RBR at CPL0, dump read-witness, IRET byte back to CPL3. ----
    a.lbl('do_read')
    if mut=='fakeread':
        a.raw(0xB3,0x5A)                                       # M-fakeread: bl=0x5A literal (no RBR read)
    else:
        a.blob(bytes.fromhex('66bafd03eca80174f766baf803ec'))  # poll LSR(0x3FD) + read RBR(0x3F8) -> al=byte
        a.raw(0x88,0xC3)                                       # mov bl,al  (save byte; survives the dump)
    outi(0xC0)                                                 # read-witness frame start
    a.raw(0x88,0xD8,0xE6,OUT)                                  # mov al,bl ; out (delivered byte)
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                       # cs   = [esp+4]  (== UCODE3)
    a.raw(0x8B,0x04,0x24); dr_eax()                            # eip  = [esp+0]  (== mod_start+READ_RET_OFF)
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                       # useresp = [esp+12]  (== alloc_hi)
    outi(0xC1)
    if mut=='noiret':
        a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC); a.j(None,'body_start')  # M-noiret: never return to CPL3
    else:
        drain_then_rearm()                                    # drain the stale tick latched during the poll + re-arm
        a.raw(0x0F,0xB6,0xC3)                                  # movzx eax,bl  (return byte in eax; bl survived drain)
        a.raw(0xCF)                                            # iretd -> back to CPL3, module resumes w/ eax=byte

    # ===== NEW (link24): SYS_WRITE (eax=2) -- the module emits its OWN multi-byte output. The kernel acts as
    # the module's DEPUTY: it dereferences a module-supplied buffer (ecx=ptr, edx=len) AT CPL0, where paging's
    # U/S does NOT fault (no CR4.SMAP) -- so an explicit SOFTWARE bounds-check of [ptr,ptr+len) against the
    # module's User page [alloc_lo,alloc_hi) (read BY VALUE from the cells the bump-allocator wrote) is the ONLY
    # thing stopping a CONFUSED-DEPUTY kernel-memory disclosure. Valid -> write-witness D4<len><cs><eip><useresp>
    # + the len relayed bytes + D5, iret back (eax=0). Invalid (ptr<alloc_lo | ptr+len>alloc_hi | 32-bit wrap)
    # -> reject D6<len><cs><eip><useresp>D7, NO relay. M-nobounds drops the check -> a hostile ptr=kernel-code
    # module makes the kernel LEAK kernel bytes (the make-or-break: the leak is empirically real, which is what
    # distinguishes a genuine kernel-contract deepening from re-proving nokta's passive #PF). =====
    a.lbl('do_write')
    a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)  # reload kernel data segs
    if mut!='nobounds':
        if mut=='bakebounds':
            # M-bakebounds: bake THIS-run alloc_lo/hi as immediates instead of loading the allocator cells
            # BY VALUE -- a forge that desyncs from the real allocation (covered structurally by the prefix
            # byte-pin; here as a knob for the build-phase by-value gate). esp_top is kstack; alloc is runtime,
            # so a literal cannot equal it -> a benign in-page write is REJECTED (RED). (Driven host-side.)
            a.raw(0xBE); a.blob(le32(0))                       # mov esi,0 (stale immediate)
            a.raw(0xBF); a.blob(le32(0xFFFFFFFF))             # mov edi,-1
        else:
            a.raw(0x8B,0x35); a.blob(le32(cell('alloc_lo')))  # mov esi,[alloc_lo]  (by-VALUE -- the page handed out)
            a.raw(0x8B,0x3D); a.blob(le32(cell('alloc_hi')))  # mov edi,[alloc_hi]
        a.raw(0x89,0xC8)                                       # mov eax,ecx         (ptr)
        a.raw(0x01,0xD0)                                       # add eax,edx         (eax = ptr+len)
        if mut!='nocarry':  a.j(JB,'reject_write')            # jc  -> 32-bit wrap/overflow  (M-nocarry drops)
        a.raw(0x39,0xF1)                                       # cmp ecx,esi         (ptr vs alloc_lo)
        if mut!='noptrlo':  a.j(JB,'reject_write')            # jb  -> ptr < alloc_lo        (M-noptrlo drops)
        a.raw(0x39,0xF8)                                       # cmp eax,edi         (ptr+len vs alloc_hi)
        if mut!='noendhi':  a.j(JA,'reject_write')            # ja  -> end > alloc_hi        (M-noendhi drops)
    # ---- VALID: write-relay witness + relay [ptr..ptr+len) byte-for-byte ----
    outi(0xD4)                                                 # write-witness frame start
    a.raw(0x89,0xD0); dr_eax()                                 # mov eax,edx ; dump len
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                       # cs   = [esp+4]   (== UCODE3 RPL3)
    a.raw(0x8B,0x04,0x24); dr_eax()                            # eip  = [esp+0]   (== mod_start+W_WRITE_RET)
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                       # useresp = [esp+12] (== alloc_hi)
    a.lbl('wrelay')
    a.raw(0x85,0xD2)                                           # test edx,edx
    a.j(JE,'wrelaydone')                                       # len exhausted -> done
    if mut=='fakewrite':
        a.raw(0xB0,0x99)                                       # M-fakewrite: mov al,0x99 (CONST, not module byte)
    else:
        a.raw(0x8A,0x01)                                       # mov al,[ecx]    (module-authored byte)
    if mut!='norelay':
        a.raw(0xE6,OUT)                                        # out 0xE9,al     (M-norelay: drop the relay)
    a.raw(0x41)                                                # inc ecx
    a.raw(0x4A)                                                # dec edx
    a.j(None,'wrelay')
    a.lbl('wrelaydone')
    outi(0xD5)                                                 # write-witness frame end
    drain_then_rearm()                                         # re-arm the watchdog (module still alive)
    a.raw(0x31,0xC0)                                           # xor eax,eax  (return 0; module ignores)
    a.raw(0xCF)                                                # iretd -> back to CPL3
    # ---- REJECT: a reject witness frame, NO bytes relayed (the confused-deputy defense) ----
    a.lbl('reject_write')
    outi(0xD6)                                                 # reject-witness frame start
    a.raw(0x89,0xD0); dr_eax()                                 # len (the rejected len)
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                       # cs
    a.raw(0x8B,0x04,0x24); dr_eax()                            # eip  (== mod_start+HOSTW_WRITE_RET)
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                       # useresp
    outi(0xD7)                                                 # reject-witness frame end
    drain_then_rearm()
    a.raw(0x31,0xC0)                                           # xor eax,eax  (rejected -> 0 bytes)
    a.raw(0xCF)                                                # iretd -> back to CPL3 (module continues to SYS_EXIT)

    # ===== #GP handler (vec 13): frame = [errcode,eip,cs,eflags,useresp,userss] -- BYTE-IDENTICAL nokta =====
    a.lbl('gp_handler')
    a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    outi(0xF0)
    a.raw(0x8B,0x04,0x24); dr_eax()
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()
    a.raw(0x8B,0x44,0x24,0x08); dr_eax()
    a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xF1)
    # ===== geeking FAULT->CONTINUE tail (#GP): the witness frame above is BYTE-IDENTICAL nokta; only the
    # tail changes. RPL-KEYED (uniform with the panic path, per the cross-model leg): a CPL3 module #GP (cs
    # at [esp+8] for this errcode frame, RPL 3) is NAMED ('G'=0x47) and the kernel CONTINUES (body emits
    # DE47AD); a genuine RPL0 KERNEL #GP panics (a kernel bug must NOT continue as a module fault). Every real
    # module fault is RPL3 so the continue path is unchanged; the RPL0->panic arm is white-box-pinned (exact
    # prefix), unreachable on this artifact (pure-conduit body cannot fault). M-shutdowngp reverts. =====
    if mut=='shutdowngp':
        shutdown()
    else:
        a.raw(0xF6,0x44,0x24,0x08,0x03)                             # test byte [esp+8],3  (RPL of interrupted cs)
        a.j(JE,'gp_kpanic')                                        # RPL0 -> genuine kernel #GP -> panic
        a.raw(0xB0,0x47); a.raw(0xA2); a.blob(le32(cell('answer')))   # mov al,'G' ; mov [answer],al
        a.raw(0xBC); a.blob(le32(kstack))                            # mov esp,kstack
        a.raw(0xFC)                                                  # cld
        a.j(None,'body_start')                                       # emit DE47AD; kernel continues
        a.lbl('gp_kpanic'); a.j(None,'sdtail')                       # RPL0 kernel #GP -> shared panic+shutdown

    # ===== #PF handler (vec 14): nokta's MEMORY-ISOLATION witness -- BYTE-IDENTICAL nokta =====
    a.lbl('pf_handler')
    a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    outi(0xD0)
    a.raw(0x8B,0x04,0x24); dr_eax()
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()
    a.raw(0x8B,0x44,0x24,0x08); dr_eax()
    a.raw(0x0F,0x20,0xD0); dr_eax()
    a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xD1)
    # ===== geeking FAULT->CONTINUE tail (#PF): the witness frame above (errcode, eip, cs, CR2, useresp) is
    # BYTE-IDENTICAL nokta; only the tail changes. RPL-KEYED (uniform with the panic path): a CPL3 module #PF
    # (cs at [esp+8], RPL 3) is NAMED ('P'=0x50) and the kernel CONTINUES (body emits DE50AD); a genuine RPL0
    # KERNEL #PF panics. M-shutdownpf reverts to shutdown(). =====
    if mut=='shutdownpf':
        shutdown()
    else:
        a.raw(0xF6,0x44,0x24,0x08,0x03)                             # test byte [esp+8],3  (RPL of interrupted cs)
        a.j(JE,'pf_kpanic')                                        # RPL0 -> genuine kernel #PF -> panic
        a.raw(0xB0,0x50); a.raw(0xA2); a.blob(le32(cell('answer')))   # mov al,'P' ; mov [answer],al
        a.raw(0xBC); a.blob(le32(kstack))                            # mov esp,kstack
        a.raw(0xFC)                                                  # cld
        a.j(None,'body_start')                                       # emit DE50AD; kernel continues
        a.lbl('pf_kpanic'); a.j(None,'sdtail')                       # RPL0 kernel #PF -> shared panic+shutdown

    # ===== NEW (link21): timer tick handler (vec 0x20), RPL-KEYED. Interrupt gate -> IF=0 on entry.
    # Frame from CPL3 (priv change): [eip, cs, eflags, useresp, userss]; from CPL0: [eip, cs, eflags].
    # cs is at [esp+4] in BOTH. If RPL==0 the tick landed in the kernel (drain window / poll) -> EOI + iret
    # (a harmless discard). If RPL==3 the tick landed IN THE MODULE -> EOI, dump a kill-witness frame
    # CA<eip><cs><useresp><eflags>CB, store kill status into [answer], switch to the kernel stack, and
    # JMP the compiled body (kernel OUTLIVES the module). NEVER iret back to a killed module. =====
    a.lbl('tick_handler')
    if mut!='rplkey':
        a.raw(0xF6,0x44,0x24,0x04,0x03)                       # test byte [esp+4],3   (RPL of interrupted cs)
        a.j(JNE,'tick_kill')                                  # RPL!=0 -> kill path
        a.raw(0xB0,0x20,0xE6,0x20)                            # EOI: mov al,0x20 ; out 0x20,al
        a.raw(0xCF)                                           # iretd -> discard (resume kernel)
    # M-rplkey: drop the RPL test -> fall straight into tick_kill (a CPL0 drain/poll tick now KILLS too ->
    # the benign/feeder path dies -> SILICON-RED). Pinning the test+jne TARGET is the talkert reachability lesson.
    a.lbl('tick_kill')
    if mut=='nokill':
        # M-nokill: the RPL3 path EOIs and IRETs BACK to the module instead of killing -> the runaway victim
        # resumes spinning, the one-shot already fired (won't fire again), so it hangs -> timeout (SILICON-RED).
        a.raw(0xB0,0x20,0xE6,0x20)                            # EOI
        a.raw(0xCF)                                           # iretd -> back to the (un-killed) module
    else:
        a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)  # reload kernel data segs
        if mut!='killnoeoi':
            a.raw(0xB0,0x20,0xE6,0x20)                        # EOI (M-killnoeoi skips it: white-box-RED -- post-kill
            #                                                   IF=0 makes it silicon-silent; honest split)
        outi(0xCA)                                            # kill-witness frame start
        a.raw(0x8B,0x04,0x24); dr_eax()                       # eip     = [esp+0]  (== mod_start for EB FE)
        a.raw(0x8B,0x44,0x24,0x04); dr_eax()                  # cs      = [esp+4]  (== UCODE3 = 0x1B)
        a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                  # useresp = [esp+12] (== alloc_hi)
        a.raw(0x8B,0x44,0x24,0x08); dr_eax()                  # eflags  = [esp+8]  (IF set)
        outi(0xCB)                                            # kill-witness frame end
        killcell = cell('flags') if mut=='wrongkillcell' else cell('answer')  # M-wrongkillcell: status to flags cell
        a.raw(0xB0,KILL_STATUS); a.raw(0xA2); a.blob(le32(killcell))   # mov al,'K' ; mov [answer],al
        a.raw(0xBC); a.blob(le32(kstack))                     # mov esp,kstack
        a.raw(0xFC)                                           # cld
        a.j(None,'body_start')                                # emit f(kill-status); kernel outlives module

    # ===== NEW (link21): spurious-IRQ7 handler (vec 0x27): plain iretd, NO EOI (a real spurious IRQ7
    # has no in-service bit to clear). Absorbs any stray IRQ7 without killing/parking. =====
    a.lbl('spur_handler')
    a.raw(0xCF)                                                # iretd

    # ===== panic handler -- geeking GENERALIZED fault->continue (Codex completeness gift). A CPU exception
    # with NO dedicated handler that originates at CPL3 (#DB via popfd-TF, #DE div0, #UD bad opcode -- all
    # NO-errcode, so cs is at [esp+4]) must NOT take the machine down, else a 3-byte hostile module halts the
    # kernel, falsifying "the kernel outlives its module". RPL-keyed: RPL0 = a genuine KERNEL fault ->
    # panic+shutdown (a kernel bug must NEVER masquerade as a module fault); RPL3 = NAME it 'F'(0x46) +
    # continue (body emits DE46AD). M-panicshutdown reverts to unconditional shutdown -> a CPL3 #DB/#DE/#UD
    # then HALTS the machine -> SILICON-RED on the TF/DIV0/BADOP probes. =====
    a.lbl('panic_handler')
    if mut=='panicshutdown':
        outi(ord('P')); shutdown()
    else:
        a.raw(0xF6,0x44,0x24,0x04,0x03)                       # test byte [esp+4],3  (RPL of interrupted cs)
        a.j(JE,'kpanic')                                     # RPL==0 -> genuine kernel fault -> panic
        a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)  # reload kernel data segs
        outi(0xE2)                                           # generic-fault witness frame start
        a.raw(0x8B,0x04,0x24); dr_eax()                      # eip = [esp+0]
        a.raw(0x8B,0x44,0x24,0x04); dr_eax()                 # cs  = [esp+4]  (== UCODE3, proves CPL3 origin)
        outi(0xE3)                                           # generic-fault witness frame end
        a.raw(0xB0,0x46); a.raw(0xA2); a.blob(le32(cell('answer')))   # mov al,'F' ; mov [answer],al
        a.raw(0xBC); a.blob(le32(kstack))                    # mov esp,kstack
        a.raw(0xFC)                                          # cld
        a.j(None,'body_start')                               # emit DE46AD; kernel outlives the module
        a.lbl('kpanic')
        outi(ord('P')); shutdown()

    # ===== descriptor tables -- BYTE-IDENTICAL nokta (TSS limit 0x67 + IOPB 0x68 => CPL3 I/O #GPs) =====
    a.lbl('gdtr'); a.blob(le16(0x2F)); a.absR('gdt')
    a.lbl('idtr'); a.blob(le16(0x31*8-1)); a.absR('idt')
    def gdt_bytes(L):
        b=bytearray()
        b+=gdt_desc(0,0,0,0)
        b+=gdt_desc(0,0xFFFFF,0x9A,0xC)
        b+=gdt_desc(0,0xFFFFF,0x92,0xC)
        b+=gdt_desc(0,0xFFFFF,0xFA,0xC)
        b+=gdt_desc(0,0xFFFFF,0xF2,0xC)
        b+=gdt_desc(L['tss'],0x67,0x89,0x0)
        return bytes(b)
    a.lbl('gdt'); a.defer(6*8, gdt_bytes)
    def idt_bytes(L):
        b=bytearray()
        exit_dpl = 0x8E if mut=='gatedpl0' else 0xEE
        for v in range(0x31):
            if v==13: b+=idt_gate(L['gp_handler'],KCODE,0x8E)
            elif v==14: b+=idt_gate(L['pf_handler'],KCODE,0x8E)
            elif v==0x20: b+=idt_gate(L['tick_handler'],KCODE,0x8E)   # link21: timer IRQ0 (interrupt gate, IF=0)
            elif v==0x27: b+=idt_gate(L['spur_handler'],KCODE,0x8E)   # link21: spurious IRQ7 absorber
            elif v==0x30: b+=idt_gate(L['exit_handler'],KCODE,exit_dpl)
            else: b+=idt_gate(L['panic_handler'],KCODE,0x8E)
        return bytes(b)
    a.lbl('idt'); a.defer(0x31*8, idt_bytes)
    def tss_bytes(L):
        t=bytearray(104)
        esp0 = 0xF0000000 if mut=='tssesp0' else kstack
        t[4:8]=le32(esp0); t[8:12]=le32(KDATA)
        t[0x66:0x68]=le16(0x10 if mut=='iomap' else 0x68)
        return bytes(t)
    a.lbl('tss'); a.defer(104, tss_bytes)
    # ===== page directory + page tables -- BYTE-IDENTICAL nokta (kernel Supervisor, module pages flipped) =====
    a.align(4096); a.lbl('pd')
    def pd_bytes(L):
        pde_us = 0 if mut=='pdesup' else 4
        b=bytearray()
        for i in range(1024):
            if i < NPT: b+=le32(L['pt'] + i*4096 + 3 + pde_us)
            else:       b+=le32(0)
        return bytes(b)
    a.defer(4096, pd_bytes)
    a.lbl('pt')
    def pt_bytes(L):
        b=bytearray()
        canary_pte = L['pt'] + (CANARY_VADDR>>12)*4
        ptuser_page = canary_pte>>12
        for g in range(1024*NPT):
            us = 4 if (mut=='ptuser' and g==ptuser_page) else 0
            b+=le32(g*4096 + 3 + us)
        return bytes(b)
    a.defer(4096*NPT, pt_bytes)
    a.lbl('body_start')
    if mut=='bodyio':
        # M-bodyio: inject a CPL0 device read (`in al,0x3F`, opcode e4) into the body. The answer is still
        # correct (echo_body overwrites eax), so it grades GREEN on the HOST grader -- ONLY the white-box
        # disasm body-scan (which bans all in/out/ins/outs by mnemonic) catches it. Proves that scan bites.
        a.blob(bytes([0xE4,0x3F])); a.blob(echo_body())
    else:
        a.blob(echo_body())
    a.blob(EPI)
    return a.assemble()

def echo_body(): return bytes([0x0F,0xB6,0x05])+le32(cell('answer'))+bytes([0x50,0x58])
EPI=bytes([136,195, 102,186,233,0, 176,222,238, 136,216,238, 176,173,238,
           136,216, 52,49, 36,127,
           102,186,244,0,238, 102,186,0,137]) \
    + b''.join(bytes([176,c,238]) for c in b'Shutdown') + bytes([250,244,235,253])

def build_elf(mut=None, design='oneshot'):
    code0,_=build_code(0,0,mut,design); clen=len(code0)
    memsz=12+clen+16384
    kstack=LOAD+memsz; kend=LOAD+memsz
    code,labels=build_code(kstack,kend,mut,design); assert len(code)==clen,(len(code),clen)
    filesz=12+len(code); pad4=(4-(filesz%4))%4
    shoff=4096+filesz+pad4
    ehdr=(b'\x7fELF\x01\x01\x01\x00'+b'\x00'*8+struct.pack('<HHI',2,3,1)+le32(ENTRY)+le32(52)+le32(shoff)+le32(0)
          +struct.pack('<HHHHHH',52,32,1,40,1,0))
    phdr=le32(1)+le32(4096)+le32(LOAD)+le32(LOAD)+le32(filesz)+le32(memsz)+le32(7)+le32(4096)
    mbh=bytes((0x02,0xB0,0xAD,0x1B))+le32(0x00000003)+le32(0xE4524FFB)
    img=ehdr+phdr+b'\x00'*(4096-84)+mbh+code+b'\x00'*pad4+b'\x00'*40
    return img,kend,labels

# ---- CPL3 modules (raw, position-independent). sitopia round-trip: a benign module first WRITES ITS OWN
# User stack page (the nokta partition carry), then SYS_READ (kernel delivers a late-bound COM1 byte the
# module CANNOT read itself), TRANSFORMS it in its own code, and SYS_EXIT(status). ----
OWNW=bytes([0xC7,0x44,0x24,0xFC])+le32(0x11223344)     # mov dword [esp-4],0x11223344  (own User stack write) (8)
READ=bytes([0xB8])+le32(SYS_READ)+bytes([0xCD,0x30])   # mov eax,SYS_READ ; int 0x30   (read syscall)        (7)
EXITSC=bytes([0x88,0xC3])+bytes([0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])  # mov bl,al;mov eax,1;int 0x30     (9)
READ_RET_OFF=len(OWNW)+len(READ)                       # eip in the read-witness frame  (= 15)
# per-transform module bodies + their host transform T + their exit-witness eip offset.
XFORMS={
  'echo': (b'',                                lambda b: b & 0xFF),                 # T(b)=b
  'inc':  (bytes([0x05])+le32(7),              lambda b: (b+7) & 0xFF),             # add eax,7   -> T(b)=b+7
  'xor':  (bytes([0x35])+le32(0x5A),           lambda b: (b ^ 0x5A) & 0xFF),        # xor eax,0x5A-> T(b)=b^0x5A
}
def mod_roundtrip(kind, tag):
    xf,_=XFORMS[kind]
    return OWNW+READ+xf+EXITSC+tag.encode()
# CONSTBL: a DEAD/lazy module -- it issues SYS_READ and SYS_EXIT with byte-identical witness frames to echo,
# but IGNORES the kernel-delivered byte and bakes bl=0x5A. Same offsets as echo (mov bl,0x5A [B3 5A] is the
# same length as mov bl,al [88 C3]), so EVERY structural witness check passes; only answer==T(fed) + the X!=Y
# differential catches it (answer is the constant 0x5A regardless of the fed byte). Proves the differential bites.
def mod_constbl(tag='SICB'):
    return OWNW+READ+bytes([0xB3,0x5A,0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])+tag.encode()
def exit_ret_off(kind):
    xf,_=XFORMS[kind]
    return READ_RET_OFF+len(xf)+len(EXITSC)                # eip in the exit-witness frame
def host_T(kind, b): return XFORMS[kind][1](b)

# hostile-IN (the make-or-break of the syscall ABI): a CPL3 `in al,dx` -> #GP (IOPB beyond TSS limit),
# so the module CANNOT read the device itself -- only the kernel-mediated SYS_READ can. faulting eip = mod+4.
HOSTIN_OFF=4
def mod_hostin(tag='HOIN'):
    return (bytes([0x66,0xBA,0xF8,0x03])      # mov dx,0x3F8                          (4)
            +bytes([0xEC])                    # in al,dx  -> #GP at CPL3 (eip=mod+4)  (1)
            +bytes([0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])  # (only if it didn't fault) exit-breach witness
            +tag.encode())
# hostile-OUT (the 19a carry): a privileged `out` at CPL3/IOPL=0 -> #GP. faulting eip = mod+2.
HOSTILE_OUT_OFF=2
def mod_hostile(tag='HOST'): return bytes([0xB0,0x77, 0xE6,OUT, 0xB0,0xBB,0xE6,OUT])+tag.encode()
# hostile-WRITE (nokta 19b): plain store to a Supervisor kernel cell -> #PF(7). eip = mod+0. eax=SYS_EXIT
# so a BREACH (write lands) routes to SYS_EXIT and produces a detectable exit frame.
HOSTILE_WRITE_STATUS=0xDE
def mod_hostile_write(tag='HOSW'):
    return (bytes([0xC7,0x05])+le32(CANARY_VADDR)+le32(0xDEADBEEF)
            +bytes([0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
            +tag.encode())
# hostile-READ (nokta confidentiality): CPL3 read of a Supervisor cell -> #PF(5). eip = mod+0. eax=SYS_EXIT
# (set after the faulting read) so a breach routes to SYS_EXIT.
def mod_hostile_read(tag='HOSR'):
    return (bytes([0x8B,0x1D])+le32(CANARY_VADDR)
            +bytes([0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
            +tag.encode())
# hostile-PT-WRITE (nokta tamper-closure): CPL3 write to the canary's own PTE -> #PF(7). eip = mod+0.
def mod_hostile_pt(pte_addr, tag='HOPT'):
    return (bytes([0xC7,0x05])+le32(pte_addr)+le32(0x00000007)
            +bytes([0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
            +tag.encode())
# link21 VICTIM: a RUNAWAY module that never syscalls -- EB FE (jmp $, a 2-byte self-jump; eip stays at
# mod_start) + 4 tag bytes. The one-shot timer must fire at CPL3 and KILL it (RPL3 tick path).
def mod_victim(tag='VICT'):
    return bytes([0xEB,0xFE])+tag.encode()
# geeking READ-THEN-HANG victim: a module that completes ONE round-trip syscall (SYS_READ -> kernel delivers
# a late-bound COM1 byte, IRETs back) and THEN runs away (EB FE self-jump). Proves the watchdog is RE-ARMED
# by do_read's drain_then_rearm() and bites AFTER a syscall, not just on the initial entry. The read-witness
# eip and the kill eip are BOTH mod_start+len(READ) (the int 0x30 return addr == the EB FE spin site).
READHANG_SPIN_OFF=len(READ)                            # = 7 (mov eax,0[5] + int 0x30[2]); EB FE sits right after
def mod_readhang(tag='RTHV'):
    return READ+bytes([0xEB,0xFE])+tag.encode()

# geeking GENERALIZED-fault probes (Codex completeness gift): CPL3 CPU exceptions with NO dedicated handler
# that the OLD panic path would shutdown()+halt on -> now named 'F'(0x46) + continued (DE46AD). Each proves
# the kernel outlives a whole fault class it has no special handler for. Faults at CPL3 -> generic-fault frame.
def mod_tf(tag='HTTF'):
    return bytes([0x68,0x00,0x01,0x00,0x00, 0x9D, 0x90])+tag.encode()   # push 0x100(TF); popfd; nop -> #DB trap
def mod_div0(tag='HDE0'):
    return bytes([0x31,0xC0, 0x99, 0xF7,0xF0])+tag.encode()             # xor eax,eax; cdq; div eax -> #DE
def mod_badop(tag='HUD2'):
    return bytes([0x0F,0x0B])+tag.encode()                             # ud2 -> #UD

# ---- link24 / SYS_WRITE modules (raw, position-independent) ----
# W_READ: the same SYS_READ glue (mov eax,0; int 0x30 -> eax=b), without sitopia's OWNW preamble.
W_READ = bytes([0xB8])+le32(SYS_READ)+bytes([0xCD,0x30])               # mov eax,0 ; int 0x30   (7) -> eax=b
# mod_write (BENIGN): SYS_READ a byte b, compute a 3-byte buffer [b, b^0x5A, (b+0x11)&0xFF] on its OWN User
# stack page, SYS_WRITE(ptr=that buffer, len=3) -> the kernel relays the 3 MODULE-AUTHORED bytes, SYS_EXIT(b).
# The relayed bytes are a value-function of the late-bound b, so X!=Y -> relayed(X)!=relayed(Y): a kernel that
# bakes a constant string diverges. (bl already == b via ebx, which do_write preserves, so SYS_EXIT needs no mov.)
def mod_write(tag='SIWR'):
    body = (W_READ
        + bytes([0x89,0xC3])                  # mov ebx,eax           (2)  ebx=b (survives SYS_WRITE)
        + bytes([0x88,0x44,0x24,0xFC])        # mov [esp-4],al        (4)  buf[0]=b
        + bytes([0x34,0x5A])                  # xor al,0x5A           (2)
        + bytes([0x88,0x44,0x24,0xFD])        # mov [esp-3],al        (4)  buf[1]=b^0x5A
        + bytes([0x88,0xD8])                  # mov al,bl             (2)  al=b
        + bytes([0x04,0x11])                  # add al,0x11           (2)
        + bytes([0x88,0x44,0x24,0xFE])        # mov [esp-2],al        (4)  buf[2]=(b+0x11)&0xFF
        + bytes([0x8D,0x4C,0x24,0xFC])        # lea ecx,[esp-4]       (4)  ptr (in-page: alloc_hi-4)
        + bytes([0xBA,0x03,0x00,0x00,0x00])   # mov edx,3             (5)  len
        + bytes([0xB8,0x02,0x00,0x00,0x00])   # mov eax,2 (SYS_WRITE) (5)
        + bytes([0xCD,0x30])                  # int 0x30              (2)  -> W_WRITE_RET here
        + bytes([0xB8,0x01,0x00,0x00,0x00])   # mov eax,1 (SYS_EXIT)  (5)  bl already = b
        + bytes([0xCD,0x30]))                 # int 0x30              (2)  -> W_EXIT_RET here
    return body + tag.encode()
W_READ_RET  = 7                               # eip in the read-witness frame (after W_READ int 0x30)
W_WRITE_RET = 7+2+4+2+4+2+2+4+4+5+5+2         # = 43  eip in the write-witness frame (after SYS_WRITE int 0x30)
W_EXIT_RET  = W_WRITE_RET+5+2                 # = 50  eip in the exit-witness frame
def host_write_bytes(b): return bytes([b & 0xFF, (b ^ 0x5A) & 0xFF, (b + 0x11) & 0xFF])

# mod_writeconst (DEAD/baker): same shape + same offsets as mod_write, but bakes a CONSTANT [0x11,0x22,0x33]
# buffer (ignores b). Every structural witness pin passes; only relayed==host_write_bytes(fed) + X!=Y catches
# it. Proves the by-VALUE relayed-bytes pin + the X!=Y differential are load-bearing (the toggler/provenance rule).
def mod_writeconst(tag='SIWC'):
    body = (W_READ
        + bytes([0x89,0xC3])                                   # mov ebx,eax          (2)
        + bytes([0xB0,0x11,0x88,0x44,0x24,0xFC])               # mov al,0x11; mov [esp-4],al  (6)
        + bytes([0xB0,0x22,0x88,0x44,0x24,0xFD])               # mov al,0x22; mov [esp-3],al  (6)
        + bytes([0xB0,0x33,0x88,0x44,0x24,0xFE])               # mov al,0x33; mov [esp-2],al  (6)
        + bytes([0x8D,0x4C,0x24,0xFC])                         # lea ecx,[esp-4]      (4)
        + bytes([0xBA,0x03,0x00,0x00,0x00])                    # mov edx,3            (5)
        + bytes([0xB8,0x02,0x00,0x00,0x00])                    # mov eax,2            (5)
        + bytes([0xCD,0x30])                                   # int 0x30            (2)
        + bytes([0xB8,0x01,0x00,0x00,0x00])                    # mov eax,1            (5)
        + bytes([0xCD,0x30]))                                  # int 0x30            (2)
    return body + tag.encode()

# mod_hostwrite (HOSTILE confused-deputy): SYS_WRITE a pointer OUTSIDE its User page -- ptr=ENTRY (the kernel's
# OWN first code bytes, Supervisor), len=8. The kernel bounds-check MUST reject it (no kernel bytes leak). Under
# M-nobounds the kernel relays code[0:8] (a real kernel-memory disclosure) -- the empirical make-or-break leak.
HOSTW_LEAK_PTR = ENTRY        # 0x10000C
HOSTW_LEAK_LEN = 8
def mod_hostwrite(tag='HOWR'):
    body = (bytes([0xB9])+le32(HOSTW_LEAK_PTR)                 # mov ecx,ENTRY        (5)
        + bytes([0xBA])+le32(HOSTW_LEAK_LEN)                   # mov edx,8            (5)
        + bytes([0xB8,0x02,0x00,0x00,0x00])                   # mov eax,2 (SYS_WRITE)(5)
        + bytes([0xCD,0x30])                                   # int 0x30            (2)  -> HOSTW_WRITE_RET
        + bytes([0xB8,0x01,0x00,0x00,0x00])                   # mov eax,1 (SYS_EXIT) (5)
        + bytes([0xCD,0x30]))                                  # int 0x30            (2)
    return body + tag.encode()
HOSTW_WRITE_RET = 5+5+5+2     # = 17  eip in the reject (or, under M-nobounds, the leak) write frame

# mod_straddle (HOSTILE boundary): ptr = esp-1 = alloc_hi-1 (in-page), len = 0x100 -> ptr+len straddles PAST
# alloc_hi into the Supervisor neighbor page. Isolates the END>alloc_hi branch: the benign kernel REJECTS
# (end>hi); under M-noendhi the kernel relays 0x100 bytes incl. kernel neighbor memory (a leak past the page).
def mod_straddle(tag='STRD'):
    body = (bytes([0x8D,0x4C,0x24,0xFF])                       # lea ecx,[esp-1]     (4)  ptr=alloc_hi-1
        + bytes([0xBA,0x00,0x01,0x00,0x00])                   # mov edx,0x100       (5)  len straddles page end
        + bytes([0xB8,0x02,0x00,0x00,0x00])                   # mov eax,2 (SYS_WRITE)(5)
        + bytes([0xCD,0x30])                                   # int 0x30            (2)
        + bytes([0xB8,0x01,0x00,0x00,0x00])                   # mov eax,1 (SYS_EXIT) (5)
        + bytes([0xCD,0x30]))                                  # int 0x30            (2)
    return body + tag.encode()

# ---- link24 COMPILED module (the HEADLINE: emitted by the NEW `module-holler` emit mode, NOT hand-crafted) ----
# Source: func main(): let b = sys_read()  let x = sys_write(b)  return sys_write(b * 3) end
# IR [47,4,3,48,4,3,0,42,48,21], nlocals=2. op 48 (sys_write) = a VALUE builtin returning 0; lowering
# [lea ecx,[esp]; mov edx,4; mov eax,2 (SYS_WRITE); int 0x30; mov [esp],eax] -- relays le32 of the operand on
# TOS (in the module's OWN User page), net stack effect 0 (pop arg, push result). The module SYS_WRITEs le32(b)
# then le32(3*b), so the kernel relays 8 module-authored bytes that are a value-function of the late-bound b:
# X!=Y -> relayed(X)!=relayed(Y). TWO checks (NOT independent of each other, so BOTH are run): (1) the emitter
# output == target_module() byte-for-byte; (2) the module RUNS on the holler kernel and relays le32(b)/le32(3b)
# (the independent silicon leg -- emitter and hand-oracle could share a bug; silicon cannot).
def _op48_syswrite():   # op 48 lowering (18 bytes) -- the byte sequence the `module-holler` emitter must produce
    return bytes([0x8D,0x0C,0x24, 0xBA,0x04,0x00,0x00,0x00, 0xB8,0x02,0x00,0x00,0x00, 0xCD,0x30, 0x89,0x04,0x24])
def _compiled_module_build():
    frame = bytes([0x89,0xE5, 0x83,0xEC,0x08])         # mov ebp,esp; sub esp,8       (nlocals=2 -> prefix_len 5)
    op47  = bytes([0xB8,0,0,0,0, 0xCD,0x30, 0x50])     # sys_read:  mov eax,0; int 0x30; push eax            (8)
    st0   = bytes([0x8F,0x45,0xFC])                    # store b -> [ebp-4] (slot0): pop [ebp-4]              (3)
    ld0   = bytes([0xFF,0x75,0xFC])                    # load  b <- [ebp-4]:        push [ebp-4]             (3)
    sw    = _op48_syswrite()                           # sys_write (18)
    st1   = bytes([0x8F,0x45,0xF8])                    # store x -> [ebp-8] (slot1): pop [ebp-8]              (3)
    psh3  = bytes([0x68,3,0,0,0])                      # push 3                                               (5)
    imul  = bytes([0x59,0x58,0x0F,0xAF,0xC1,0x50])     # pop ecx; pop eax; imul eax,ecx; push eax (b*3)       (6)
    ret   = bytes([0x58])                              # return: pop eax (last op -> value in eax)            (1)
    exitsc= bytes([0x88,0xC3, 0xB8,1,0,0,0, 0xCD,0x30]) # implicit sys_exit: mov bl,al; mov eax,1; int 0x30  (9)
    parts = [frame, op47, st0, ld0, sw, st1, ld0, psh3, imul, sw, ret, exitsc]
    SW_INT_END = 3+5+5+2                               # offset within sw just AFTER its int 0x30 (= 15)
    pre1 = len(frame+op47+st0+ld0)                     # start of 1st sw
    pre2 = len(frame+op47+st0+ld0+sw+st1+ld0+psh3+imul)# start of 2nd sw
    return b''.join(parts), pre1+SW_INT_END, pre2+SW_INT_END   # (module, write1 eip, write2 eip)
def target_module(): return _compiled_module_build()[0]
TM_W1_RET = _compiled_module_build()[1]    # = 34   eip in the 1st write-witness frame
TM_W2_RET = _compiled_module_build()[2]    # = 69   eip in the 2nd write-witness frame
def host_compiled_writes(b):
    b &= 0xFF
    return [le32(b), le32((3*b) & 0xFFFFFFFF)]
# At each sys_write the module's esp (useresp witnessed by the kernel == the checked ptr ecx) is the operand-
# stack TOS, NOT alloc_hi: it sits below alloc_hi by the frame (sub esp,4*nlocals = 8 for nlocals=2) plus the
# ONE operand dword being written (4). So useresp == alloc_hi - 12 for BOTH writes of this fixed forcing
# program. Pinning this (vs the hand-crafted mod_write's alloc_hi) proves the write ptr is the module's live
# operand-stack TOS -- a baked/forged pointer would witness a different esp. (frame 8 + operand 4 = 12.)
TM_WRITE_ESP_DELTA = 12

def _all_wframes(stream, start, end, has_body):
    # locate EVERY start<len:4><cs:4><eip:4><useresp:4>[len body]end in order; returns list of dicts.
    out=[]; pos=0
    while True:
        i = stream.find(start, pos)
        if i < 0: break
        j = i + 1
        if j + 16 > len(stream): break
        ln, cs, eip, esp = struct.unpack('<4I', stream[j:j+16]); j += 16
        body = b''
        if has_body:
            body = stream[j:j+ln]; j += ln
        out.append(dict(ln=ln, cs=cs, eip=eip, esp=esp, body=body, closed=(stream[j:j+1] == end)))
        pos = j + 1
    return out

def grade_compiled_write(stream, kend_elf, fed):
    # BENIGN COMPILED module: read-witness (delivered==fed) + TWO write-relay frames (le32(fed), le32(3*fed),
    # BY VALUE, cs/useresp/eip by value) + exit (status 0 -- `return sys_write(..)` returns 0). The X!=Y
    # differential lives in the relayed bytes; a kernel that bakes a constant relay diverges across fed.
    errs=[]; r=parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump or RED)']
    rec=recompute_alloc(r,kend_elf)
    if rec:
        elo,ehi,_=rec
        if r.get('al')!=elo: errs.append(f'alloc_lo 0x{r.get("al"):x} != recomputed 0x{elo:x}')
        if r.get('ah')!=ehi: errs.append(f'alloc_hi 0x{r.get("ah"):x} != recomputed 0x{ehi:x}')
    ms,ah=r.get('ms'),r.get('ah')
    if 'rd_byte' not in r: errs.append('no read-witness frame (SYS_READ not serviced)')
    elif r['rd_byte']!=fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x}')
    wfs=_all_wframes(stream, b'\xD4', b'\xD5', True)
    want=host_compiled_writes(fed)
    if len(wfs)!=2:
        errs.append(f'{len(wfs)} write-relay frame(s) (D4..D5) != 2 (compiled module SYS_WRITEs twice)')
    else:
        eips=[ms+TM_W1_RET, ms+TM_W2_RET]
        for idx,wf in enumerate(wfs):
            if not wf['closed']: errs.append(f'write frame {idx} not closed by D5')
            if wf['ln']!=4: errs.append(f'write frame {idx} len {wf["ln"]} != 4 (le32)')
            if wf['cs']!=UCODE3 or (wf['cs']&3)!=3: errs.append(f'write frame {idx} cs 0x{wf["cs"]:x} != UCODE3/RPL3')
            want_esp = (ah - TM_WRITE_ESP_DELTA) if ah is not None else None
            if want_esp is not None and wf['esp']!=want_esp: errs.append(f'write frame {idx} useresp 0x{wf["esp"]:x} != alloc_hi-{TM_WRITE_ESP_DELTA} 0x{want_esp:x} (module operand-stack TOS)')
            if ms is not None and wf['eip']!=eips[idx]: errs.append(f'write frame {idx} eip 0x{wf["eip"]:x} != mod+{[TM_W1_RET,TM_W2_RET][idx]}')
            if wf['body']!=want[idx]: errs.append(f'write frame {idx} relayed {wf["body"].hex()} != {want[idx].hex()} (NOT module-authored / wrong lowering)')
    if r.get('answer')!=0: errs.append(f'answer {_h(r.get("answer"))} != 0 (return sys_write(..) yields 0)')
    return errs

# ---- BUILD-PHASE GATE SPEC (completeness-critic synthesis; fold into run_native_codegen_link40.sh + _mutation.sh) ----
# (1) MASTER PREFIX BYTE-PIN: do_write lives in the byte-pinned prefix, so ANY bounds-check mutation (partial
#     drop, off-by-one, signed jcc, baked immediate, reordered seg-reload) changes the prefix -> RED structurally.
# (2) PER-SUB-CHECK ISOLATION (must-fix; empirically proven here for the ptr<lo and end>hi branches):
#       M-noptrlo + HOWR(ptr=ENTRY,len=8)      -> leaks code[0:8] (gradeleak GREEN); benign rejects.
#       M-noendhi + STRD(ptr=esp-1,len=0x100)  -> relays past the page (grade_noleak RED); benign rejects.
#       M-nocarry: a wrapping ptr+len lands unmapped -> CPL0 #PF -> RPL0 panic/shutdown (DoS, not a clean leak);
#                  the carry check is kept + pinned by the prefix byte-pin (the wrap exploit is a crash, not exfil).
# (3) BY-VALUE OPERANDS: pin `mov esi,[disp32 alloc_lo]` / `mov edi,[disp32 alloc_hi]` (modrm=mem, disp32==the
#     allocator cells), banning imm32 mov forms (M-bakebounds). The prefix byte-pin already binds this.
# (4) BOUNDARY: accept (ptr=esp-1,len=1) and (ptr=alloc_lo,len=page); reject (ptr=esp-1,len=2),(ptr=alloc_lo-1,
#     len=1) -> catches jb->jbe / ja->jae off-by-one. (5) len==0 -> zero relay, valid path (M-loopguard bites).
# (6) SRC==CHECKED PTR: relay `mov al,[ecx]` base==the checked ecx (M-srcswap / M-fakewrite bite). (7) UNSIGNED
#     jb/ja (not jl/jg): highbit ptr (0x80000000) rejects via end>hi (M-signedjcc bites). (8) DESIGN: the module
#     CODE page is User-mapped but NOT in [alloc_lo,alloc_hi) -> SYS_WRITE of own code is rejected (v1 policy: a
#     module writes computed bytes on its stack; revisit when C2/static-data lands).

# mod_hoststraddle (HOSTILE boundary): an in-page ptr whose ptr+len STRADDLES alloc_hi -> must reject (proves
# the ptr+len check, not just the ptr check). ptr = alloc_hi-2 is supplied at build time as a tag the module
# computes from useresp; simplest STEP-0 form: a fixed straddle is hard without alloc_hi, so we drive it via the
# nobounds differential on mod_hostwrite (kernel-addr ptr) which already exercises the ptr<alloc_lo arm; the
# ptr+len/wrap arms are unit-checked in the host on the bounds predicate. (Kept minimal for STEP-0.)

# ===================== host grader =====================
CK={'mbinfo':'mb','modstart':'ms','modend':'me','str':'st','cmdline':'cm','elflo':'el','elfhi':'eh',
    'region_lo':'rl','region_hi':'rh','alloc_lo':'al','alloc_hi':'ah'}
def _h(v): return 'None' if v is None else ('0x%x'%v)   # None-safe hex for grader messages (fixes the 0x{int}
                                                        # decimal-render artifact the integrated step-0 flagged)
def parse(stream):
    r={}; i=0; entries=[]; n=len(stream)
    while i<n and stream[i]==0x9C and i+25<=n:
        vals=struct.unpack('<6I', stream[i+1:i+25]); i+=25
        entries.append(dict(size=vals[0],blo=vals[1],bhi=vals[2],llo=vals[3],lhi=vals[4],ty=vals[5]))
    r['entries']=entries
    if i<n and stream[i]==0x9A:
        i+=1; k0,k1,ma,ml=struct.unpack('<4I', stream[i:i+16]); i+=16
        r['k0'],r['k1'],r['ma'],r['ml']=k0,k1,ma,ml
        nc=len(CELLS); cells=struct.unpack('<%dI'%nc, stream[i:i+4*nc]); i+=4*nc
        for nm,v in zip(CELLS,cells):
            if nm in CK: r[CK[nm]]=v
            else: r[nm]=v
        r['block_ok']=(i<n and stream[i]==0x9B); i+=1
    else: return None
    tail=stream[i:]
    rd=re.search(rb'\xC0(.)(.{4})(.{4})(.{4})\xC1', tail, re.S)    # read-witness frame (byte,cs,eip,useresp)
    if rd:
        r['rd_byte']=rd.group(1)[0]
        r['rd_cs'],r['rd_eip'],r['rd_esp']=[struct.unpack('<I',rd.group(k))[0] for k in (2,3,4)]
    be=re.search(rb'\xE0(.)(.{4})(.{4})(.{4})\xE1', tail, re.S)    # exit-witness frame (status,cs,eip,useresp)
    if be:
        r['ex_status']=be.group(1)[0]
        r['ex_cs'],r['ex_eip'],r['ex_esp']=[struct.unpack('<I',be.group(k))[0] for k in (2,3,4)]
    gp=re.search(rb'\xF0(.{4})(.{4})(.{4})(.{4})\xF1', tail, re.S)
    if gp:
        r['gp_err'],r['gp_eip'],r['gp_cs'],r['gp_esp']=[struct.unpack('<I',gp.group(k))[0] for k in (1,2,3,4)]
    pf=re.search(rb'\xD0(.{4})(.{4})(.{4})(.{4})(.{4})\xD1', tail, re.S)
    if pf:
        r['pf_err'],r['pf_eip'],r['pf_cs'],r['pf_cr2'],r['pf_esp']=[struct.unpack('<I',pf.group(k))[0] for k in (1,2,3,4,5)]
    # link21: kill-witness frame CA<eip><cs><useresp><eflags>CB (timer killed a CPL3 module)
    kf=re.search(rb'\xCA(.{4})(.{4})(.{4})(.{4})\xCB', tail, re.S)
    if kf:
        r['kl_eip'],r['kl_cs'],r['kl_esp'],r['kl_eflags']=[struct.unpack('<I',kf.group(k))[0] for k in (1,2,3,4)]
    # geeking generalized fault->continue: generic-fault witness E2<eip><cs>E3 (a CPL3 CPU exception with no
    # dedicated handler -- #DB/#DE/#UD -- named 'F' and continued instead of panic+shutdown)
    gf=re.search(rb'\xE2(.{4})(.{4})\xE3', tail, re.S)
    if gf:
        r['gf_eip'],r['gf_cs']=[struct.unpack('<I',gf.group(k))[0] for k in (1,2)]
    an=re.search(rb'\xDE(.)\xAD', tail, re.S)
    if an: r['answer']=an.group(1)[0]
    if b'\xBB' in tail: r['saw_bb']=True
    return r

def recompute_alloc(r, kend):
    region=None
    for e in r['entries']:
        if region: break
        if e['ty']!=1 or e['bhi']!=0: continue
        hi=0xFFFFF000 if e['lhi'] else (e['blo']+e['llo'])
        if hi>0x100000: region=(e['blo'],hi)
    if not region: return None
    rlo,rhi=region
    excl=[(0x100000,kend),(r['ms'],r['me'])]
    for p in ('mb','st','cm'):
        if r[p]: lo=r[p]&~0xFFF; excl.append((lo,lo+0x2000))
    if r['el'] and r['eh']: excl.append((r['el'],r['eh']))
    if r['ma'] is not None and r['ml']:
        excl.append((r['ma']&~0xFFF,(r['ma']+r['ml']+0xFFF)&~0xFFF))
    cur=(max(rlo,0x100000)+0xFFF)&~0xFFF
    for _ in range(16):
        moved=False
        for lo,hi in excl:
            if cur<hi and lo<cur+0x1000: cur=(hi+0xFFF)&~0xFFF; moved=True
        if not moved: break
    if cur+0x1000>rhi: return None
    return cur,cur+0x1000,region

def grade(stream, kend_elf, golden, kind='echo', ram_mb=None, expect_cr2=None, cont=False):
    # golden = the FED byte (benign round-trip: answer expected = host_T(kind,fed)); ignored for hostile kinds.
    # cont=True  -> geeking FAULT->CONTINUE mode: the carried "#PF -> answer cell stays 0" breach-signal is
    #               REPLACED by the wrapper's answer==kind pin (see grade_fault_continue + the report's
    #               contract-change note). ALL by-value witness-frame pins are UNCHANGED in either mode.
    errs=[]; r=parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump or RED)']
    if r['k1']!=kend_elf: errs.append(f'dumped k1=0x{r["k1"]:x} != ELF kend=0x{kend_elf:x}')
    if r['k0']!=0x100000: errs.append('k0 != 0x100000')
    if not any(e['ty']==1 and e['bhi']==0 and e['blo']<=0x100000 and kend_elf<=e['blo']+e['llo'] for e in r['entries']):
        errs.append('kernel not inside any dumped type-1 region (fabricated map?)')
    if not r['mb']: errs.append('dumped mbinfo pointer is 0')
    rec=recompute_alloc(r,kend_elf)
    if not rec: errs.append('host could not recompute a fit')
    else:
        elo,ehi,reg=rec
        if r['al']!=elo: errs.append(f'alloc_lo 0x{r["al"]:x} != recomputed 0x{elo:x}')
        if r['ah']!=ehi: errs.append(f'alloc_hi 0x{r["ah"]:x} != recomputed 0x{ehi:x}')
    al,ah=r['al'],r['ah']
    def ov(lo,hi): return lo is not None and hi is not None and al<hi and lo<ah
    if ov(0x100000,kend_elf): errs.append('alloc overlaps kernel')
    if ov(r['ms'],r['me']): errs.append('alloc overlaps module')
    if kind in XFORMS:
        # ---- BENIGN ROUND TRIP: read-witness + exit-witness + answer == T(fed) ----
        fed=golden
        read_ret=READ_RET_OFF; exit_ret=exit_ret_off(kind)
        if 'rd_byte' not in r: errs.append('no read-witness frame (kernel did not service SYS_READ at CPL3)')
        else:
            if r['rd_cs']!=UCODE3 or (r['rd_cs']&3)!=3: errs.append(f'read frame cs 0x{r["rd_cs"]:x} != ucode|3 / RPL!=3')
            if r['rd_esp']!=r['ah']: errs.append(f'read frame useresp 0x{r["rd_esp"]:x} != alloc_hi 0x{r["ah"]:x}')
            if r['rd_eip']!=r['ms']+read_ret: errs.append(f'read frame eip 0x{r["rd_eip"]:x} != mod_start+{read_ret}')
            if r['rd_byte']!=fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x} (kernel did not read the live RBR)')
        if 'ex_status' not in r: errs.append('no exit-witness frame (module did not SYS_EXIT at CPL3 after re-entry)')
        else:
            if r['ex_cs']!=UCODE3 or (r['ex_cs']&3)!=3: errs.append(f'exit frame cs 0x{r["ex_cs"]:x} != ucode|3 / RPL!=3')
            if r['ex_esp']!=r['ah']: errs.append(f'exit frame useresp 0x{r["ex_esp"]:x} != alloc_hi 0x{r["ah"]:x}')
            if r['ex_eip']!=r['ms']+exit_ret: errs.append(f'exit frame eip 0x{r["ex_eip"]:x} != mod_start+{exit_ret}')
        if 'rd_eip' in r and 'ex_eip' in r:
            if r['ex_eip']-r['rd_eip']!=exit_ret-read_ret:
                errs.append(f'inter-frame eip distance 0x{r["ex_eip"]-r["rd_eip"]:x} != module transform len 0x{exit_ret-read_ret:x} (module did not run between syscalls)')
        want=host_T(kind,fed)
        if r.get('answer')!=want: errs.append(f'answer {_h(r.get("answer"))} != T_{kind}(0x{fed:x})=0x{want:x}')
    elif kind=='hostile' or kind=='hostin':
        off = HOSTILE_OUT_OFF if kind=='hostile' else HOSTIN_OFF
        what = 'out' if kind=='hostile' else 'in'
        if 'gp_err' not in r: errs.append(f'no #GP frame ({what} did not fault at CPL3)')
        else:
            if r['gp_err']!=0: errs.append(f'#GP errcode 0x{r["gp_err"]:x} != 0 (not a privileged-op/IO fault)')
            if r['gp_cs']!=UCODE3: errs.append(f'#GP cs 0x{r["gp_cs"]:x} != ucode|3 (fault not from CPL3)')
            if r['gp_esp']!=r['ah']: errs.append(f'#GP useresp 0x{r["gp_esp"]:x} != alloc_hi 0x{r["ah"]:x}')
            if r['gp_eip']!=r['ms']+off: errs.append(f'#GP eip 0x{r["gp_eip"]:x} != mod_start+{off} (not the {what})')
        if r.get('saw_bb'): errs.append(f'saw 0xBB after the faulting {what} (it did NOT fault!)')
        if 'ex_status' in r: errs.append(f'module reached SYS_EXIT (status 0x{r["ex_status"]:x}) -> the {what} did NOT fault, isolation BREACHED')
    elif kind in ('pfault','pfault_read','pfault_fetch','pfault_pt'):
        want_err = 0x05 if kind in ('pfault_read','pfault_fetch') else 0x07
        want_cr2 = (r['ms'] if kind=='pfault_fetch'
                    else expect_cr2 if (kind=='pfault_pt' and expect_cr2 is not None)
                    else CANARY_VADDR)
        what = {'pfault':'write','pfault_read':'read','pfault_fetch':'fetch','pfault_pt':'PT-write'}[kind]
        if 'pf_err' not in r: errs.append(f'no #PF frame (the kernel {what} did NOT fault -> isolation absent)')
        else:
            if r['pf_err']!=want_err: errs.append(f'#PF errcode 0x{r["pf_err"]:x} != EXACTLY 0x{want_err:x} (P/W/U/RSVD/I-D for a CPL3 {what} of a Supervisor page)')
            if r['pf_cs']!=UCODE3 or (r['pf_cs']&3)!=3: errs.append(f'#PF cs 0x{r["pf_cs"]:x} != ucode|3 / RPL!=3 (fault not from CPL3)')
            if r['pf_cr2']!=want_cr2: errs.append(f'#PF cr2 0x{r["pf_cr2"]:x} != target 0x{want_cr2:x}')
            if r['pf_esp']!=r['ah']: errs.append(f'#PF useresp 0x{r["pf_esp"]:x} != alloc_hi 0x{r["ah"]:x} (module on a different stack)')
            if r['pf_eip']!=r['ms']: errs.append(f'#PF eip 0x{r["pf_eip"]:x} != mod_start 0x{r["ms"]:x} (not the faulting access)')
        if 'ex_status' in r: errs.append(f'module reached SYS_EXIT (status 0x{r["ex_status"]:x}) -> the {what} LANDED, isolation BREACHED')
        # CONTRACT CHANGE (geeking fault->continue): under cont=True the #PF tail deliberately stores 0x50
        # ('P') into [answer], so the carried "answer==0" no-breach signal cannot hold. It is REPLACED, not
        # weakened: grade_fault_continue pins answer==0x50 exactly, and the breach is STILL triple-covered
        # (no #PF frame / ex_status present / answer!=0x50). cont=False keeps the original sitopia semantics.
        if not cont and r.get('answer') not in (None,0): errs.append(f'answer cell 0x{r.get("answer"):x} != 0 (the {what} LANDED -> breach)')
    return errs

# ===================== link21 prototype graders =====================
def grade_benign_nokill(stream, kend_elf, fed, kind):
    # Benign round-trip under the timer design: full sitopia round-trip GREEN **and** NOT killed.
    errs=grade(stream, kend_elf, fed, kind=kind)
    r=parse(stream)
    if r is None: return errs+['no cell table parsed']
    if 'kl_eip' in r:
        errs.append(f'BENIGN MODULE WAS KILLED: kill frame eip=0x{r["kl_eip"]:x} cs=0x{r["kl_cs"]:x} '
                    f'eflags=0x{r["kl_eflags"]:x} answer={_h(r.get("answer"))}')
    if r.get('answer')==KILL_STATUS:
        errs.append(f'answer == KILL_STATUS 0x{KILL_STATUS:x} (benign module produced the kill output)')
    return errs

def grade_victim(stream, kend_elf):
    # Runaway victim under the one-shot design: the CPL3-keyed kill MUST fire with an exact witness frame.
    errs=[]; r=parse(stream)
    if r is None: return ['no cell table parsed (kernel head did not complete)']
    ms=r.get('ms'); ah=r.get('ah')
    if 'kl_eip' not in r:
        errs.append('NO KILL FRAME: the runaway module was never preempted+killed (timer/kill path did not fire)')
        return errs
    if r['kl_eip']!=ms: errs.append(f'kill eip 0x{r["kl_eip"]:x} != mod_start 0x{ms:x} (EB FE self-jump boundary)')
    if r['kl_cs']!=UCODE3: errs.append(f'kill cs 0x{r["kl_cs"]:x} != UCODE|3 0x{UCODE3:x} (tick not from CPL3)')
    if r['kl_esp']!=ah: errs.append(f'kill useresp 0x{r["kl_esp"]:x} != alloc_hi 0x{ah:x} (module on a different stack)')
    # geeking honesty rule: QEMU-TCG sets RF (0x10000) in the captured preempted eflags; Bochs/KVM do not.
    # Mask RF and pin the WHOLE value 0x202 exactly (IF=1, IOPL=0, reserved bit1) -- STRONGER than the carried
    # bare IF-bit test: it forbids any stray bit (e.g. IOPL leakage, a wrong seed) that the IF test would miss.
    masked = r['kl_eflags'] & ~0x10000
    if masked != 0x00000202:
        errs.append(f'kill eflags (RF-masked) 0x{masked:x} != 0x00000202 exactly (raw 0x{r["kl_eflags"]:x})')
    if r.get('answer')!=KILL_STATUS: errs.append(f'answer {_h(r.get("answer"))} != KILL_STATUS 0x{KILL_STATUS:x}')
    if 'ex_status' in r: errs.append('module reached SYS_EXIT -> a spinner cannot syscall; stream is wrong')
    return errs

def grade_fault_continue(stream, kend_elf, kind, expect_cr2=None):
    # geeking FAULT->CONTINUE grader for the carried hostile probes. kind in:
    #   'hostile'/'hostin'  -> #GP witness by value (carried) + answer=='G'(0x47) + DE47AD + NO SYS_EXIT breach
    #   'pfault'/'pfault_read'/'pfault_pt' -> #PF witness by value (errcode 7/5/7, CR2, carried) + answer=='P'(0x50)
    #                                          + DE50AD + NO breach
    # It calls grade(cont=True) so EVERY by-value witness pin sitopia makes is re-made; only the (incompatible)
    # "#PF answer==0" secondary breach-signal is gated off there and REPLACED by the answer==kind pin below.
    errs=grade(stream, kend_elf, 0, kind=kind, expect_cr2=expect_cr2, cont=True)
    r=parse(stream)
    if r is None: return errs+['no cell table parsed']
    if kind in ('hostile','hostin'): wk,nm=0x47,'G'
    else:                            wk,nm=0x50,'P'
    # answer==wk IS the "body emitted DE<kind>AD by value" check (parse pins DE(.)AD -> r['answer']).
    if r.get('answer')!=wk:
        errs.append(f"fault-continue answer {_h(r.get('answer'))} != 0x{wk:x} ('{nm}') -- kernel did not name the fault and continue (no DE{wk:02X}AD)")
    # NOTE: the "no SYS_EXIT breach" check is enforced inside grade() (the ex_status append) -- not duplicated here.
    return errs

def grade_generic_continue(stream, kend_elf):
    # geeking GENERALIZED fault->continue grader (Codex gift). A CPL3 CPU exception with NO dedicated handler
    # (#DB via TF, #DE div0, #UD bad opcode) must be NAMED 'F'(0x46), emit DE46AD, and NOT halt -- proving the
    # kernel outlives a fault class it has no special handler for. The E2/E3 witness frame's cs must be UCODE3
    # (the fault genuinely came from CPL3 -- not a forged kernel-side store). A panic 'P' byte must NOT appear.
    errs=[]; r=parse(stream)
    if r is None: return ['no cell table parsed (kernel head did not complete)']
    if 'gf_cs' not in r:
        return ['NO generic-fault frame: the CPL3 exception was not caught+continued (panic+shutdown instead?)']
    if r['gf_cs']!=UCODE3: errs.append(f'generic-fault cs 0x{r["gf_cs"]:x} != UCODE|3 0x{UCODE3:x} (fault not from CPL3)')
    if r.get('answer')!=0x46:
        errs.append(f"generic-fault answer {_h(r.get('answer'))} != 0x46 ('F') -- no DE46AD (kernel did not name+continue)")
    return errs

def grade_readhang(stream, kend_elf, fed):
    # geeking READ-THEN-HANG grader: a read-witness frame (by value, delivered byte == fed) PROVING the
    # round-trip completed, THEN a kill frame at the spin offset PROVING the RE-ARMED watchdog bit after the
    # syscall. eip of both frames == mod_start+READHANG_SPIN_OFF (the int 0x30 return addr == the EB FE site).
    errs=[]; r=parse(stream)
    if r is None: return ['no cell table parsed (kernel head did not complete)']
    ms=r.get('ms'); ah=r.get('ah')
    if 'rd_byte' not in r:
        errs.append('no read-witness frame (kernel did not service SYS_READ before the hang)')
    else:
        if r['rd_cs']!=UCODE3 or (r['rd_cs']&3)!=3: errs.append(f'read frame cs 0x{r["rd_cs"]:x} != ucode|3 / RPL!=3')
        if r['rd_esp']!=ah: errs.append(f'read frame useresp 0x{r["rd_esp"]:x} != alloc_hi 0x{ah:x}')
        if r['rd_eip']!=ms+READHANG_SPIN_OFF: errs.append(f'read frame eip 0x{r["rd_eip"]:x} != mod_start+{READHANG_SPIN_OFF}')
        if r['rd_byte']!=fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x} (kernel did not read the live RBR)')
    if 'kl_eip' not in r:
        errs.append('NO KILL FRAME after the read: the RE-ARMED watchdog did not bite the post-syscall spin')
        return errs
    if r['kl_eip']!=ms+READHANG_SPIN_OFF: errs.append(f'kill eip 0x{r["kl_eip"]:x} != mod_start+{READHANG_SPIN_OFF} (spin offset)')
    if r['kl_cs']!=UCODE3: errs.append(f'kill cs 0x{r["kl_cs"]:x} != UCODE|3 0x{UCODE3:x} (tick not from CPL3)')
    if r['kl_esp']!=ah: errs.append(f'kill useresp 0x{r["kl_esp"]:x} != alloc_hi 0x{ah:x}')
    masked = r['kl_eflags'] & ~0x10000
    if masked != 0x00000202: errs.append(f'kill eflags (RF-masked) 0x{masked:x} != 0x00000202 exactly (raw 0x{r["kl_eflags"]:x})')
    if r.get('answer')!=KILL_STATUS: errs.append(f'answer {_h(r.get("answer"))} != KILL_STATUS 0x{KILL_STATUS:x}')
    if 'ex_status' in r: errs.append('module reached SYS_EXIT -> read-then-hang must not exit; stream is wrong')
    return errs

# ===================== link24 / SYS_WRITE graders =====================
def _wframe(stream, start, end, has_body):
    # locate start<len:4><cs:4><eip:4><useresp:4>[len body if has_body]end ; returns dict or None.
    i = stream.find(start)
    if i < 0: return None
    j = i + 1
    if j + 16 > len(stream): return None
    ln, cs, eip, esp = struct.unpack('<4I', stream[j:j+16]); j += 16
    body = b''
    if has_body:
        body = stream[j:j+ln]; j += ln
    return dict(ln=ln, cs=cs, eip=eip, esp=esp, body=body, closed=(stream[j:j+1] == end))

def grade_write(stream, kend_elf, fed):
    # BENIGN SYS_WRITE round trip: read-witness (delivered byte==fed) + write-relay witness (D4..D5: the 3
    # MODULE-AUTHORED bytes relayed BY VALUE == host_write_bytes(fed), cs/eip/useresp by value) + exit + answer.
    errs=[]; r=parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump or RED)']
    rec=recompute_alloc(r,kend_elf)
    if not rec: errs.append('host could not recompute an alloc fit')
    else:
        elo,ehi,_=rec
        if r['al']!=elo: errs.append(f'alloc_lo 0x{r["al"]:x} != recomputed 0x{elo:x}')
        if r['ah']!=ehi: errs.append(f'alloc_hi 0x{r["ah"]:x} != recomputed 0x{ehi:x}')
    ms,ah=r.get('ms'),r.get('ah')
    if 'rd_byte' not in r: errs.append('no read-witness frame (SYS_READ not serviced)')
    else:
        if r['rd_cs']!=UCODE3 or (r['rd_cs']&3)!=3: errs.append(f'read frame cs 0x{r["rd_cs"]:x} != UCODE3/RPL3')
        if r['rd_esp']!=ah: errs.append(f'read frame useresp 0x{r["rd_esp"]:x} != alloc_hi 0x{ah:x}')
        if r['rd_eip']!=ms+W_READ_RET: errs.append(f'read frame eip 0x{r["rd_eip"]:x} != mod+{W_READ_RET}')
        if r['rd_byte']!=fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x}')
    wf=_wframe(stream, b'\xD4', b'\xD5', True)
    if not wf: errs.append('no write-relay frame (D4..D5) -- kernel did not service SYS_WRITE')
    else:
        if not wf['closed']: errs.append('write frame not closed by D5 (len/relay mismatch)')
        if wf['ln']!=3: errs.append(f'write len {wf["ln"]} != 3')
        if wf['cs']!=UCODE3 or (wf['cs']&3)!=3: errs.append(f'write frame cs 0x{wf["cs"]:x} != UCODE3/RPL3')
        if wf['esp']!=ah: errs.append(f'write frame useresp 0x{wf["esp"]:x} != alloc_hi 0x{ah:x}')
        if wf['eip']!=ms+W_WRITE_RET: errs.append(f'write frame eip 0x{wf["eip"]:x} != mod+{W_WRITE_RET}')
        want=host_write_bytes(fed)
        if wf['body']!=want: errs.append(f'relayed {wf["body"].hex()} != host_write_bytes(0x{fed:x})={want.hex()} (NOT module-authored / wrong lowering)')
    if 'ex_status' not in r: errs.append('no exit-witness frame (module did not SYS_EXIT after SYS_WRITE)')
    else:
        if r['ex_cs']!=UCODE3: errs.append(f'exit frame cs 0x{r["ex_cs"]:x} != UCODE3')
        if r['ex_eip']!=ms+W_EXIT_RET: errs.append(f'exit frame eip 0x{r["ex_eip"]:x} != mod+{W_EXIT_RET}')
    if r.get('answer')!=fed: errs.append(f'answer {_h(r.get("answer"))} != fed 0x{fed:x}')
    return errs

def grade_hostwrite(stream, kend_elf):
    # HOSTILE confused-deputy (benign-kernel expectation): the OOB SYS_WRITE must be REFUSED -- a reject frame
    # (D6..D7) present AND NO relay frame (D4..D5, the leak vehicle). Under M-nobounds a relay frame appears -> RED.
    errs=[]; r=parse(stream)
    if not r: return ['no OWN table parsed']
    ms,ah=r.get('ms'),r.get('ah')
    wf=_wframe(stream, b'\xD4', b'\xD5', True)
    rj=_wframe(stream, b'\xD6', b'\xD7', False)
    if wf is not None:
        errs.append(f'LEAK: kernel RELAYED {wf["body"].hex()} for a kernel-address buffer -- bounds-check FAILED (confused deputy)')
    if rj is None:
        errs.append('no reject frame (D6..D7) -- kernel did not refuse the out-of-bounds SYS_WRITE')
    else:
        if not rj['closed']: errs.append('reject frame not closed by D7')
        if rj['ln']!=HOSTW_LEAK_LEN: errs.append(f'reject len {rj["ln"]} != {HOSTW_LEAK_LEN}')
        if rj['cs']!=UCODE3 or (rj['cs']&3)!=3: errs.append(f'reject frame cs 0x{rj["cs"]:x} != UCODE3/RPL3')
        if rj['esp']!=ah: errs.append(f'reject frame useresp 0x{rj["esp"]:x} != alloc_hi 0x{ah:x}')
        if rj['eip']!=ms+HOSTW_WRITE_RET: errs.append(f'reject frame eip 0x{rj["eip"]:x} != mod+{HOSTW_WRITE_RET}')
    return errs

def grade_leak(stream, kend_elf):
    # POSITIVE leak assertion: confirm M-nobounds made the kernel exfiltrate its OWN code bytes (the empirical
    # make-or-break). want = code[0:HOSTW_LEAK_LEN] = the kernel's first bytes at vaddr ENTRY (file off 4108).
    errs=[]; r=parse(stream)
    if not r: return ['no OWN table parsed']
    want = build_elf('nobounds')[0][4108:4108+HOSTW_LEAK_LEN]
    wf=_wframe(stream, b'\xD4', b'\xD5', True)
    if wf is None: return ['NO leak: no relay frame (D4..D5) -- the kernel did not relay the OOB buffer']
    if wf['body']!=want:
        errs.append(f'relayed {wf["body"].hex()} != expected kernel code {want.hex()} at ENTRY (leak content mismatch)')
    return errs

def grade_noleak(stream, kend_elf):
    # Assert NO relay frame (D4..D5) -- the OOB write was REJECTED, nothing leaked. GREEN on the benign kernel;
    # RED when a branch-drop mutation lets the relay through (the per-sub-check isolation bite).
    wf=_wframe(stream, b'\xD4', b'\xD5', True)
    if wf is not None:
        return [f'LEAK: relay frame present (len={wf["ln"]}, body[:16]={wf["body"][:16].hex()}) -- the OOB write was NOT rejected']
    return []

if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='code':
        et=int(sys.argv[2],16); c,_=build_code(et,et); sys.stdout.write(c.hex())
    elif cmd=='prefix':
        et=int(sys.argv[2],16); c,L=build_code(et,et); sys.stdout.write(c[:L['body_start']-ENTRY].hex())
    elif cmd=='epi':
        sys.stdout.write(EPI.hex())
    elif cmd=='cleanelf':
        img,_,_=build_elf(); open(sys.argv[2],'wb').write(img)
    elif cmd=='elf':                                   # link21: elf <design:oneshot|naive> <out>
        img,_,_=build_elf(design=sys.argv[2]); open(sys.argv[3],'wb').write(img)
    elif cmd=='kend2':                                 # link21: kend2 <design>
        _,k,_=build_elf(design=sys.argv[2]); print('%x'%k)
    elif cmd=='mutate':
        img,_,_=build_elf(sys.argv[2]); open(sys.argv[3],'wb').write(img)
    elif cmd=='kend':
        m=None if sys.argv[2]=='-' else sys.argv[2]; _,k,_=build_elf(m); print('%x'%k)
    elif cmd=='module':
        k=sys.argv[2]
        if k in XFORMS: b=mod_roundtrip(k, {'echo':'SIEC','inc':'SIIN','xor':'SIXO'}[k])
        elif k=='ECHOFAT': b=mod_roundtrip('echo','SIFT')+b'\xCC'*(4*1024*1024)
        elif k=='CONSTBL': b=mod_constbl()
        elif k=='VICTIM': b=mod_victim()
        elif k=='HOIN': b=mod_hostin()
        elif k=='HOST': b=mod_hostile()
        elif k=='HOSW': b=mod_hostile_write()
        elif k=='HOSR': b=mod_hostile_read()
        elif k=='HOSPT':
            _,_,L=build_elf(); b=mod_hostile_pt(L['pt'] + (CANARY_VADDR>>12)*4)
        elif k in ('RTHV','READHANG'): b=mod_readhang()      # geeking: read-then-hang victim
        elif k=='TF': b=mod_tf()                             # geeking generalized-fault probes (Codex gift):
        elif k=='DIV0': b=mod_div0()                         #   #DB / #DE / #UD at CPL3 -> named 'F' + continue
        elif k=='BADOP': b=mod_badop()
        elif k=='WRITE': b=mod_write()                       # link24: benign multi-byte SYS_WRITE
        elif k=='WRITEC': b=mod_writeconst()                 # link24: dead/const baker (proves the differential)
        elif k=='HOWR': b=mod_hostwrite()                    # link24: hostile confused-deputy (kernel-addr ptr)
        elif k=='STRD': b=mod_straddle()                     # link24: hostile straddle (ptr+len past page end)
        else: raise SystemExit('module?')
        open(sys.argv[3],'wb').write(b)
    elif cmd=='gradegeneric':                          # gradegeneric <stream> <kend>  (TF/DIV0/BADOP -> #DB/#DE/#UD)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_generic_continue(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradebenign':                           # gradebenign <stream> <kend> <fedbyte> <kind>
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); gb=int(sys.argv[4],16)
        kind=sys.argv[5] if len(sys.argv)>5 else 'echo'
        errs=grade_benign_nokill(stream,kend,gb,kind)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradevictim':                           # gradevictim <stream> <kend>
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_victim(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradereadhang':                         # gradereadhang <stream> <kend> <fedbyte>
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); fb=int(sys.argv[4],16)
        errs=grade_readhang(stream,kend,fb)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradefaultcont':                        # gradefaultcont <stream> <kend> <kind> [cr2]
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); kind=sys.argv[4]
        ec2=int(sys.argv[5],16) if len(sys.argv)>5 else None
        errs=grade_fault_continue(stream,kend,kind,expect_cr2=ec2)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='grade':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); gb=int(sys.argv[4],16)
        kind=sys.argv[5] if len(sys.argv)>5 else 'echo'
        ec2=int(sys.argv[6],16) if len(sys.argv)>6 else None
        errs=grade(stream,kend,gb,kind=kind,expect_cr2=ec2)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradewrite':                            # gradewrite <stream> <kend> <fedbyte>
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); fb=int(sys.argv[4],16)
        errs=grade_write(stream,kend,fb)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradehostwrite':                        # gradehostwrite <stream> <kend>
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_hostwrite(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradeleak':                             # gradeleak <stream> <kend>  (positive leak assertion)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_leak(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='gradenoleak':                           # gradenoleak <stream> <kend>  (assert no relay frame)
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        errs=grade_noleak(stream,kend)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='targetmod':                             # targetmod <out>  -- the compiled module byte-identity oracle
        open(sys.argv[2],'wb').write(target_module())
    elif cmd=='tmoffs':                                # tmoffs  -- compiled-module write-witness eip offsets
        print('w1_ret', TM_W1_RET, 'w2_ret', TM_W2_RET, 'modlen', len(target_module()))
    elif cmd=='gradecompiled':                         # gradecompiled <stream> <kend> <fedbyte>
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); fb=int(sys.argv[4],16)
        errs=grade_compiled_write(stream,kend,fb)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='ptaddr':
        _,_,L=build_elf(); print('%x'%(L['pt'] + (CANARY_VADDR>>12)*4))
    elif cmd=='offsets':   # per-kind module witness offsets (for the gate)
        for k in XFORMS: print(k, 'read_ret', READ_RET_OFF, 'exit_ret', exit_ret_off(k))
        print('hostin_off', HOSTIN_OFF, 'hostile_out_off', HOSTILE_OUT_OFF)
        print('readhang_spin_off', READHANG_SPIN_OFF, 'victim_kill_off', 0)
        print('gp_kind', hex(0x47), 'pf_kind', hex(0x50), 'kill_status', hex(KILL_STATUS))
    elif cmd=='labels':
        _,k,L=build_elf()
        for n in ('reload','exit_handler','do_read','gp_handler','pf_handler','panic_handler','gdt','idt','tss','gdtr','idtr','pd','pt','body_start'):
            print(n, hex(L[n]))
        print('kend', hex(k), 'prefixlen', L['body_start']-ENTRY, 'canary', hex(CANARY_VADDR), 'cover', hex(COVER))
    else: raise SystemExit('usage: code|prefix|epi|cleanelf|mutate|kend|module|grade|ptaddr|offsets|labels')
