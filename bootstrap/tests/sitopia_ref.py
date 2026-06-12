#!/usr/bin/env python3
# sitopia_ref.py -- sitopia (link 20 / native-codegen Link 36) STEP-0 / committed-reference candidate.
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
SYS_READ=0; SYS_EXIT=1
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

def build_code(kstack, kend, mut=None):
    a=Asm()
    def mmi(addr,imm): a.raw(0xC7,0x05); a.blob(le32(addr)); a.blob(le32(imm))
    def mme(addr): a.raw(0xA3); a.blob(le32(addr))
    def mem(addr): a.raw(0xA1); a.blob(le32(addr))
    def outi(v): a.raw(0xB0,v,0xE6,OUT)
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

    if mut=='callcpl0':
        a.raw(0x8B,0x25); a.blob(le32(cell('alloc_hi')))
        a.raw(0xFF,0x15); a.blob(le32(cell('modstart')))
        mme(cell('answer')); a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC)
        a.j(None,'body_start')
    else:
        a.raw(0xB8); a.blob(le32(UDATA3))
        a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
        ef = 0x00003002 if mut=='iopl3frame' else 0x00000002
        uc = UCODE if mut=='dpl0frame' else UCODE3
        us = UDATA if mut=='dpl0frame' else UDATA3
        a.raw(0x68); a.blob(le32(us))
        a.raw(0xFF,0x35); a.blob(le32(cell('alloc_hi')))
        a.raw(0x68); a.blob(le32(ef))
        a.raw(0x68); a.blob(le32(uc))
        a.raw(0xFF,0x35); a.blob(le32(cell('modstart')))
        a.raw(0xCF)                                            # iretd -> CPL3 at the module

    # ===== syscall handler (vec 0x30): DISPATCH on eax. SYS_READ=0 reads COM1 + IRETS BACK to CPL3 with
    # the byte in eax (the new kernel->module re-entry); else SYS_EXIT (status in bl -> [answer] -> body). =====
    # The handler FALLS THROUGH (via SYS_EXIT's jmp) to the compiled body, which reads [answer] (pure conduit).
    a.lbl('exit_handler')   # IDT-wired label name kept from nokta
    # entry: eax=syscall#, DS/ES/FS/GS=UDATA3, SS=KDATA, esp=esp0 frame [eip,cs,eflags,useresp,userss].
    if mut!='nodispatch':
        a.raw(0x85,0xC0)                                       # test eax,eax
        a.j(JE,'do_read')                                      # jz do_read (SYS_READ); else fall to SYS_EXIT
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
        a.raw(0x0F,0xB6,0xC3)                                  # movzx eax,bl  (return byte in eax)
        a.raw(0xCF)                                            # iretd -> back to CPL3, module resumes w/ eax=byte

    # ===== #GP handler (vec 13): frame = [errcode,eip,cs,eflags,useresp,userss] -- BYTE-IDENTICAL nokta =====
    a.lbl('gp_handler')
    a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    outi(0xF0)
    a.raw(0x8B,0x04,0x24); dr_eax()
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()
    a.raw(0x8B,0x44,0x24,0x08); dr_eax()
    a.raw(0x8B,0x44,0x24,0x10); dr_eax()
    outi(0xF1)
    shutdown()

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
    shutdown()

    # ===== panic handler =====
    a.lbl('panic_handler')
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

def build_elf(mut=None):
    code0,_=build_code(0,0,mut); clen=len(code0)
    memsz=12+clen+16384
    kstack=LOAD+memsz; kend=LOAD+memsz
    code,labels=build_code(kstack,kend,mut); assert len(code)==clen,(len(code),clen)
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

# ===================== host grader =====================
CK={'mbinfo':'mb','modstart':'ms','modend':'me','str':'st','cmdline':'cm','elflo':'el','elfhi':'eh',
    'region_lo':'rl','region_hi':'rh','alloc_lo':'al','alloc_hi':'ah'}
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

def grade(stream, kend_elf, golden, kind='echo', ram_mb=None, expect_cr2=None):
    # golden = the FED byte (benign round-trip: answer expected = host_T(kind,fed)); ignored for hostile kinds.
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
        if r.get('answer')!=want: errs.append(f'answer 0x{r.get("answer")} != T_{kind}(0x{fed:x})=0x{want:x}')
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
        if r.get('answer') not in (None,0): errs.append(f'answer cell 0x{r.get("answer"):x} != 0 (the {what} LANDED -> breach)')
    return errs

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
    elif cmd=='mutate':
        img,_,_=build_elf(sys.argv[2]); open(sys.argv[3],'wb').write(img)
    elif cmd=='kend':
        m=None if sys.argv[2]=='-' else sys.argv[2]; _,k,_=build_elf(m); print('%x'%k)
    elif cmd=='module':
        k=sys.argv[2]
        if k in XFORMS: b=mod_roundtrip(k, {'echo':'SIEC','inc':'SIIN','xor':'SIXO'}[k])
        elif k=='ECHOFAT': b=mod_roundtrip('echo','SIFT')+b'\xCC'*(4*1024*1024)
        elif k=='CONSTBL': b=mod_constbl()
        elif k=='HOIN': b=mod_hostin()
        elif k=='HOST': b=mod_hostile()
        elif k=='HOSW': b=mod_hostile_write()
        elif k=='HOSR': b=mod_hostile_read()
        elif k=='HOSPT':
            _,_,L=build_elf(); b=mod_hostile_pt(L['pt'] + (CANARY_VADDR>>12)*4)
        else: raise SystemExit('module?')
        open(sys.argv[3],'wb').write(b)
    elif cmd=='grade':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); gb=int(sys.argv[4],16)
        kind=sys.argv[5] if len(sys.argv)>5 else 'echo'
        ec2=int(sys.argv[6],16) if len(sys.argv)>6 else None
        errs=grade(stream,kend,gb,kind=kind,expect_cr2=ec2)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='ptaddr':
        _,_,L=build_elf(); print('%x'%(L['pt'] + (CANARY_VADDR>>12)*4))
    elif cmd=='offsets':   # per-kind module witness offsets (for the gate)
        for k in XFORMS: print(k, 'read_ret', READ_RET_OFF, 'exit_ret', exit_ret_off(k))
        print('hostin_off', HOSTIN_OFF, 'hostile_out_off', HOSTILE_OUT_OFF)
    elif cmd=='labels':
        _,k,L=build_elf()
        for n in ('reload','exit_handler','do_read','gp_handler','pf_handler','panic_handler','gdt','idt','tss','gdtr','idtr','pd','pt','body_start'):
            print(n, hex(L[n]))
        print('kend', hex(k), 'prefixlen', L['body_start']-ENTRY, 'canary', hex(CANARY_VADDR), 'cover', hex(COVER))
    else: raise SystemExit('usage: code|prefix|epi|cleanelf|mutate|kend|module|grade|ptaddr|offsets|labels')
