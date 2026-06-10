#!/usr/bin/env python3
# trikon_ref.py -- trikonderoga (link 18) STEP-0 / committed-reference candidate.
# Grafts the PROVEN ring-3 machinery (audits/link18-whether/step0/trikon_step0.py, dual-substrate-proven)
# onto lodger's PROVEN discover+allocate head (bootstrap/tests/lodger_ref.py). The build-unknown module
# now runs at CPL 3 on the bump-allocated page; it EXITS via `int 0x30` (the first syscall), and a hostile
# `out` faults #GP. The lodger module-emitted CA/FE witness is REPLACED by the CPU-authored ring-cross
# frame (the CPU, not the module, writes cs/eip/esp), because at CPL3/IOPL=0 the module cannot `out` or `ret`.
import struct, sys, re

OUT=0xE9; LOAD=0x100000; ENTRY=0x10000C
KCODE=0x08; KDATA=0x10; UCODE=0x18; UDATA=0x20; TSS_SEL=0x28
UCODE3=UCODE|3; UDATA3=UDATA|3
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def le16(v): return struct.pack('<H', v & 0xFFFF)
# the cell array (UNCHANGED from lodger -- the head/grader ownership-recompute contract is identical)
CELLS=['mbinfo','flags','modstart','modend','str','cmdline','elflo','elfhi',
       'region_lo','region_hi','alloc_lo','alloc_hi','answer',
       'mb_lo','mb_hi','st_lo','st_hi','cm_lo','cm_hi','mm_lo','mm_hi']
CIDX={n:i for i,n in enumerate(CELLS)}
CELLBASE=ENTRY+7+5
def cell(n): return CELLBASE+CIDX[n]*4
JNE,JE,JB,JAE,JA,JBE=0x85,0x84,0x82,0x83,0x87,0x86

class Asm:
    # lodger's Asm extended with absolute label refs ('A') and deferred fixed-length data ('D').
    def __init__(s): s.items=[]
    def raw(s,*b): s.items.append(('b',bytes(b)))
    def blob(s,b): s.items.append(('b',bytes(b)))
    def lbl(s,n): s.items.append(('L',n))
    def j(s,cc,n): s.items.append(('J',cc,n))
    def absR(s,n,add=0): s.items.append(('A',n,add))
    def defer(s,length,fn): s.items.append(('D',length,fn))
    def _layout(s):
        off=0; pos={}
        for it in s.items:
            t=it[0]
            if t=='b': off+=len(it[1])
            elif t=='L': pos[it[1]]=off
            elif t=='J': off+=(5 if it[1] is None else 6)
            elif t=='A': off+=4
            elif t=='D': off+=it[1]
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
    def shutdown():    # head-local dual-substrate shutdown (lodger's proven sequence)
        a.raw(0x66,0xBA,0xF4,0x00); a.raw(0xEE)
        a.raw(0x66,0xBA,0x00,0x89)
        for ch in b'Shutdown': a.raw(0xB0,ch,0xEE)
        a.raw(0xFA,0xF4,0xEB,0xFD)

    # ===== HEAD (capture + discover + parse-map + bump-alloc + dump) -- transcribed from lodger_ref =====
    a.blob(bytes((0x89,0x1D))+le32(cell('mbinfo')))   # mov [mbinfo],ebx  (byte 0)
    a.j(None,'glue')
    a.blob(b'\x00'*(len(CELLS)*4))
    sd_FAILS=['F1','F2','F3','F4','F5','F8','F9','F10']
    for idx,f in enumerate(sd_FAILS):
        a.lbl(f); a.blob(bytes([176,0x31+idx,0xE6,OUT])); a.j(None,'sdtail')
    a.lbl('sdtail'); shutdown()
    a.lbl('glue')
    a.raw(0x3D); a.blob(le32(0x2BADB002)); a.j(JNE,'F1')          # cmp eax,magic
    a.raw(0xBC); a.blob(le32(kstack))                             # mov esp,kstack
    # NEW (Multiboot-undefined normalize, chosen/CR4-PAE lesson): clear CR4 + EFLAGS before any ring work.
    a.raw(0x31,0xC0); a.raw(0x0F,0x22,0xE0)                       # xor eax,eax ; mov cr4,eax
    a.raw(0x68); a.blob(le32(0x00000002)); a.raw(0x9D)           # push 2 ; popfd (NT=0,IF=0,IOPL=0,DF=0)
    a.raw(0x8B,0x35); a.blob(le32(cell('mbinfo')))               # mov esi,[mbinfo]
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

    # ===== NEW: install ring machinery + iret to CPL3 on the allocated page =====
    a.raw(0x0F,0x01,0x15); a.absR('gdtr')                        # lgdt [gdtr]
    a.raw(0xEA); a.absR('reload'); a.raw(0x08,0x00)              # ljmp KCODE:reload
    a.lbl('reload')
    a.raw(0xB8); a.blob(le32(KDATA))                            # mov eax,KDATA
    a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xD0,0x8E,0xE0,0x8E,0xE8)    # ds,es,ss,fs,gs
    a.raw(0x0F,0x01,0x1D); a.absR('idtr')                       # lidt [idtr]
    a.raw(0x66,0xB8,TSS_SEL,0x00); a.raw(0x0F,0x00,0xD8)        # mov ax,TSS_SEL ; ltr ax
    if mut=='callcpl0':
        # M-callcpl0: skip the ring transition, lodger-style CPL0 call -> hostile op would run undetected.
        a.raw(0x8B,0x25); a.blob(le32(cell('alloc_hi')))        # mov esp,[alloc_hi]
        a.raw(0xFF,0x15); a.blob(le32(cell('modstart')))        # call [modstart]  (CPL0!)
        mme(cell('answer')); a.raw(0xBC); a.blob(le32(kstack)); a.raw(0xFC)
        a.j(None,'body_start')
    else:
        a.raw(0xB8); a.blob(le32(UDATA3))                       # mov eax,UDATA|3
        a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)         # ds,es,fs,gs = udata|3 (user data segs)
        ef = 0x00003002 if mut=='iopl3frame' else 0x00000002    # M-iopl3 sets IOPL=3 (bits12-13) via the frame
        uc = UCODE if mut=='dpl0frame' else UCODE3              # M-dpl0: push ring-0 cs (no privilege change)
        us = UDATA if mut=='dpl0frame' else UDATA3
        a.raw(0x68); a.blob(le32(us))                          # push ss   (udata|3)
        a.raw(0xFF,0x35); a.blob(le32(cell('alloc_hi')))      # push dword [alloc_hi]  (user esp)
        a.raw(0x68); a.blob(le32(ef))                         # push eflags
        a.raw(0x68); a.blob(le32(uc))                         # push cs   (ucode|3)
        a.raw(0xFF,0x35); a.blob(le32(cell('modstart')))      # push dword [modstart]  (user eip)
        a.raw(0xCF)                                            # iretd -> CPL3 at the module

    # ===== exit gate handler (vec 0x30): software int from CPL3, frame = [eip,cs,eflags,useresp,userss] =====
    # FALLS THROUGH to the compiled body (which reads [answer] and the epilogue emits f(answer)).
    a.lbl('exit_handler')
    # ORDER IS LOAD-BEARING (Codex Q1 + completeness-critic B1, both legs): save status off al BEFORE any
    # seg reload (else mov eax,KDATA clobbers al), and reload DS/ES=kdata BEFORE the store/resume (else the
    # resumed body's 0xE9 output is silently DROPPED on Bochs while clean on QEMU -- a real substrate divergence).
    seg = bytes([0xB8])+le32(KDATA)+bytes([0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8])  # mov eax,KDATA; ds,es,fs,gs
    if mut=='resumeorder':
        a.blob(seg); a.raw(0x88,0xC3)                         # M-resumeorder: reload FIRST -> al clobbered -> wrong f
    else:
        a.raw(0x88,0xC3); a.blob(seg)                         # correct: save status off al FIRST, THEN reload data segs
        # (the DS reload is defensive; ds=udata3 is also set before the iret, so the critic's B1-B
        #  "no-ds-reload drops output on Bochs" does NOT manifest here -- confirmed GREEN on both substrates.)
    acell = cell('flags') if mut=='wrongcell' else cell('answer')   # M-wrongcell: store to the wrong cell -> body reads stale 0
    a.raw(0x88,0xD8); a.raw(0xA2); a.blob(le32(acell))           # mov al,bl ; mov [answer],al
    outi(0xE0)                                                # tag E0
    a.raw(0x88,0xD8,0xE6,OUT)                                 # mov al,bl ; out (status)
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                      # cs   = [esp+4]
    a.raw(0x8B,0x04,0x24); dr_eax()                           # eip  = [esp+0]
    a.raw(0x8B,0x44,0x24,0x0C); dr_eax()                      # useresp = [esp+12]
    outi(0xE1)                                                # tag E1
    a.raw(0xBC); a.blob(le32(kstack))                        # mov esp,kstack
    a.raw(0xFC)                                               # cld
    a.j(None,'body_start')                                    # jmp body (sits after the fixed prefix)

    # ===== #GP handler (vec 13): frame = [errcode,eip,cs,eflags,useresp,userss] =====
    a.lbl('gp_handler')
    a.raw(0xB8); a.blob(le32(KDATA)); a.raw(0x8E,0xD8,0x8E,0xC0,0x8E,0xE0,0x8E,0xE8)
    outi(0xF0)                                                # tag F0
    a.raw(0x8B,0x04,0x24); dr_eax()                           # errcode = [esp+0]
    a.raw(0x8B,0x44,0x24,0x04); dr_eax()                      # eip  = [esp+4]
    a.raw(0x8B,0x44,0x24,0x08); dr_eax()                      # cs   = [esp+8]
    a.raw(0x8B,0x44,0x24,0x10); dr_eax()                      # useresp = [esp+16]
    outi(0xF1)                                                # tag F1
    shutdown()

    # ===== panic handler (all other vectors) =====
    a.lbl('panic_handler')
    outi(ord('P')); shutdown()

    # ===== descriptor tables =====
    a.lbl('gdtr'); a.blob(le16(0x2F)); a.absR('gdt')
    a.lbl('idtr'); a.blob(le16(0x31*8-1)); a.absR('idt')
    def gdt_bytes(L):
        b=bytearray()
        b+=gdt_desc(0,0,0,0)
        b+=gdt_desc(0,0xFFFFF,0x9A,0xC)        # kcode DPL0
        b+=gdt_desc(0,0xFFFFF,0x92,0xC)        # kdata DPL0
        b+=gdt_desc(0,0xFFFFF,0xFA,0xC)        # ucode DPL3
        b+=gdt_desc(0,0xFFFFF,0xF2,0xC)        # udata DPL3
        b+=gdt_desc(L['tss'],0x67,0x89,0x0)    # TSS (32-bit avail)
        return bytes(b)
    a.lbl('gdt'); a.defer(6*8, gdt_bytes)
    def idt_bytes(L):
        b=bytearray()
        exit_dpl = 0x8E if mut=='gatedpl0' else 0xEE    # M-gatedpl0: exit gate DPL0 -> CPL3 int 0x30 itself #GPs
        for v in range(0x31):
            if v==13: b+=idt_gate(L['gp_handler'],KCODE,0x8E)
            elif v==0x30: b+=idt_gate(L['exit_handler'],KCODE,exit_dpl)
            else: b+=idt_gate(L['panic_handler'],KCODE,0x8E)
        return bytes(b)
    a.lbl('idt'); a.defer(0x31*8, idt_bytes)
    def tss_bytes(L):
        t=bytearray(104)
        esp0 = 0xF0000000 if mut=='tssesp0' else kstack   # M-tssesp0: unmapped esp0 -> frame push triple-faults
        t[4:8]=le32(esp0); t[8:12]=le32(KDATA)
        t[0x66:0x68]=le16(0x10 if mut=='iomap' else 0x68)   # M-iomap: IOPB inside limit -> grants CPL3 I/O
        return bytes(t)
    a.lbl('tss'); a.defer(104, tss_bytes)
    # body + epilogue live AFTER the fixed prefix (head+handlers+tables), so the prefix is
    # body-INDEPENDENT and byte-pinnable across probes (the lodger pin, extended to the handlers/tables).
    a.lbl('body_start')
    a.blob(echo_body())                                       # compiled "return module_byte()"
    a.blob(EPI)                                               # epilogue: emit DE f(answer) AD ; shutdown
    return a.assemble()

def echo_body(): return bytes([0x0F,0xB6,0x05])+le32(cell('answer'))+bytes([0x50,0x58])
EPI=bytes([136,195, 102,186,233,0, 176,222,238, 136,216,238, 176,173,238,
           136,216, 52,49, 36,127,
           102,186,244,0,238, 102,186,0,137]) \
    + b''.join(bytes([176,c,238]) for c in b'Shutdown') + bytes([250,244,235,253])

def build_elf(mut=None):
    code0,_=build_code(0,0,mut); clen=len(code0)
    # memsz MUST match the compiler driver exactly: 12 + code_len + 16384 (NO pad4 -- pad4 is
    # only added to filesz/shoff, not memsz; lodger coincided because its pad4==0).
    memsz=12+clen+16384
    kstack=LOAD+memsz; kend=LOAD+memsz
    code,labels=build_code(kstack,kend,mut); assert len(code)==clen,(len(code),clen)
    filesz=12+len(code); pad4=(4-(filesz%4))%4
    shoff=4096+filesz+pad4
    ehdr=(b'\x7fELF\x01\x01\x01\x00'+b'\x00'*8+struct.pack('<HHI',2,3,1)+le32(ENTRY)+le32(52)+le32(shoff)+le32(0)
          +struct.pack('<HHHHHH',52,32,1,40,1,0))
    phdr=le32(1)+le32(4096)+le32(LOAD)+le32(LOAD)+le32(filesz)+le32(memsz)+le32(7)+le32(4096)
    mbh=bytes((0x02,0xB0,0xAD,0x1B))+le32(0x00000002)+le32(0xE4524FFC)   # MEMINFO header (flags=2)
    img=ehdr+phdr+b'\x00'*(4096-84)+mbh+code+b'\x00'*pad4+b'\x00'*40
    return img,kend,labels

# ---- CPL3 modules (raw, position-independent). Benign: compute status, int 0x30. Hostile: out -> #GP. ----
# benign entry: status compute = 10 bytes; int 0x30 = 2 bytes -> return eip = mod_start+12.
AX=bytes([0xB8])+le32(0x50)+bytes([0x05])+le32(0x0A)   # mov eax,0x50 ; add eax,0x0A  -> 0x5A
AY=bytes([0xB8])+le32(0x40)+bytes([0x35])+le32(0xE7)   # mov eax,0x40 ; xor eax,0xE7  -> 0xA7
EXIT_EIP_OFF=12          # return eip after int 0x30 in a benign module
def mod_benign(ax, tag, pad=0): return ax+bytes([0xCD,0x30])+tag.encode()+(b'\xCC'*pad)
# hostile: 2-byte compute then out -> faulting eip = mod_start+2.
HOSTILE_OUT_OFF=2
def mod_hostile(tag='HOST'): return bytes([0xB0,0x77, 0xE6,OUT, 0xB0,0xBB,0xE6,OUT])+tag.encode()

GX=0x5A; GY=0xA7

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
    be=re.search(rb'\xE0(.)(.{4})(.{4})(.{4})\xE1', tail, re.S)   # benign exit frame
    if be:
        r['ex_status']=be.group(1)[0]
        r['ex_cs'],r['ex_eip'],r['ex_esp']=[struct.unpack('<I',be.group(k))[0] for k in (2,3,4)]
    gp=re.search(rb'\xF0(.{4})(.{4})(.{4})(.{4})\xF1', tail, re.S)  # hostile #GP frame
    if gp:
        r['gp_err'],r['gp_eip'],r['gp_cs'],r['gp_esp']=[struct.unpack('<I',gp.group(k))[0] for k in (1,2,3,4)]
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

def grade(stream, kend_elf, golden_byte, kind='benign', ram_mb=None):
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
    if kind=='benign':
        if 'ex_status' not in r: errs.append('no benign exit frame (module did not int 0x30 at CPL3)')
        else:
            if r['ex_cs']!=UCODE3: errs.append(f'exit cs 0x{r["ex_cs"]:x} != ucode|3 0x{UCODE3:x} (not from CPL3)')
            if (r['ex_cs']&3)!=3: errs.append('exit cs RPL != 3')
            if r['ex_esp']!=r['ah']: errs.append(f'exit useresp 0x{r["ex_esp"]:x} != alloc_hi 0x{r["ah"]:x} (module ran on a different stack)')
            if r['ex_eip']!=r['ms']+EXIT_EIP_OFF: errs.append(f'exit eip 0x{r["ex_eip"]:x} != mod_start+{EXIT_EIP_OFF}')
        if r.get('answer')!=golden_byte: errs.append(f'answer 0x{r.get("answer")} != golden 0x{golden_byte:x}')
    elif kind=='hostile':
        if 'gp_err' not in r: errs.append('no #GP frame (out did not fault at CPL3)')
        else:
            if r['gp_err']!=0: errs.append(f'#GP errcode 0x{r["gp_err"]:x} != 0 (not a privileged-op/IO fault)')
            if r['gp_cs']!=UCODE3: errs.append(f'#GP cs 0x{r["gp_cs"]:x} != ucode|3 (fault not from CPL3)')
            if r['gp_esp']!=r['ah']: errs.append(f'#GP useresp 0x{r["gp_esp"]:x} != alloc_hi 0x{r["ah"]:x}')
            if r['gp_eip']!=r['ms']+HOSTILE_OUT_OFF: errs.append(f'#GP eip 0x{r["gp_eip"]:x} != mod_start+{HOSTILE_OUT_OFF} (not the out)')
        if r.get('saw_bb'): errs.append('saw 0xBB after the faulting out (the out did NOT fault!)')
    return errs

if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='code':
        et=int(sys.argv[2],16); c,_=build_code(et,et); sys.stdout.write(c.hex())
    elif cmd=='prefix':       # prefix <esp_top_hex> -> EXACT head+handlers+tables hex (the byte-pin)
        et=int(sys.argv[2],16); c,L=build_code(et,et); sys.stdout.write(c[:L['body_start']-ENTRY].hex())
    elif cmd=='epi':          # epi -> EXACT 58-byte epilogue hex (pins the only other 0xE9 emit site)
        sys.stdout.write(EPI.hex())
    elif cmd=='cleanelf':
        img,_,_=build_elf(); open(sys.argv[2],'wb').write(img)
    elif cmd=='mutate':
        img,_,_=build_elf(sys.argv[2]); open(sys.argv[3],'wb').write(img)
    elif cmd=='kend':
        m=None if sys.argv[2]=='-' else sys.argv[2]; _,k,_=build_elf(m); print('%x'%k)
    elif cmd=='module':
        k=sys.argv[2]
        if k=='X': b=mod_benign(AX,'TKGX')
        elif k=='Y': b=mod_benign(AY,'TKGY')
        elif k=='FAT': b=mod_benign(AX,'TKFAT',pad=4*1024*1024)
        elif k=='HOST': b=mod_hostile()
        else: raise SystemExit('module?')
        open(sys.argv[3],'wb').write(b)
    elif cmd=='grade':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); gb=int(sys.argv[4],16)
        kind=sys.argv[5] if len(sys.argv)>5 else 'benign'
        errs=grade(stream,kend,gb,kind=kind)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd=='labels':
        _,_,L=build_elf()
        for n in ('reload','exit_handler','gp_handler','panic_handler','gdt','idt','tss','gdtr','idtr','body_start'):
            print(n, hex(L[n]))
    else: raise SystemExit('usage: code|cleanelf|mutate|kend|module|grade|labels')
