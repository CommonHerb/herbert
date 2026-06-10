#!/usr/bin/env python3
# lodger_ref.py -- COMMITTED reference for the link33 gate + mutation harness.
# build_head = the byte-exact white-box head template (silicon-proven, audits/link17-lifecycle/step0).
# grade/recompute = the host ownership-recompute + module-witness authority. CLI at the bottom.
import struct, sys, re

#!/usr/bin/env python3
# lodger PROTOTYPE — the full emitted head, hand-assembled, proven on silicon BEFORE
# transcription into the Herbert emitter. Layout (entry 0x10000C, load 0x100000):
#   [mbheader 12][ HEAD: ebx-capture@0 ; jmp over CELLS ; CELLS ; glue ][ echo-body ][ epilogue ]
# mmap entry (size-prefixed): +0 size; +4 base_lo; +8 base_hi; +12 len_lo; +16 len_hi; +20 type.

OUT=0xE9; LOAD=0x100000; ENTRY=0x10000C
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
CELLS=['mbinfo','flags','modstart','modend','str','cmdline','elflo','elfhi',
       'region_lo','region_hi','alloc_lo','alloc_hi','answer',
       'mb_lo','mb_hi','st_lo','st_hi','cm_lo','cm_hi','mm_lo','mm_hi']
CIDX={n:i for i,n in enumerate(CELLS)}
CELLBASE=ENTRY+7+5
def cell(n): return CELLBASE+CIDX[n]*4
JNE,JE,JB,JAE,JA,JBE=0x85,0x84,0x82,0x83,0x87,0x86

class Asm:
    def __init__(s): s.items=[]
    def raw(s,*b): s.items.append(bytes(b))
    def blob(s,b): s.items.append(b)
    def lbl(s,n): s.items.append(('L',n))
    def j(s,cc,n): s.items.append(('J',cc,n))
    def assemble(s):
        off=0; pos={}; sized=[]
        for it in s.items:
            if isinstance(it,bytes): sized.append((it,off)); off+=len(it)
            elif it[0]=='L': pos[it[1]]=off; sized.append((it,off))
            else: sized.append((it,off)); off+=(5 if it[1] is None else 6)
        out=bytearray()
        for it,at in sized:
            if isinstance(it,bytes): out+=it
            elif it[0]=='L': pass
            else:
                cc,n=it[1],it[2]
                if cc is None: out+=b'\xE9'+struct.pack('<i',pos[n]-(at+5))
                else: out+=bytes((0x0F,cc))+struct.pack('<i',pos[n]-(at+6))
        return bytes(out)

def build_head(kstack, kend, mut=None):
    a=Asm()
    def mmi(addr,imm): a.raw(0xC7,0x05); a.blob(le32(addr)); a.blob(le32(imm))
    def mme(addr): a.raw(0xA3); a.blob(le32(addr))
    def mem(addr): a.raw(0xA1); a.blob(le32(addr))
    def outi(v): a.raw(0xB0,v,0xE6,OUT)
    def outs(s_):
        for ch in s_.encode(): outi(ch)
    def dr_eax():   # out eax as 4 raw bytes LE (clobbers eax)
        a.raw(0xE6,OUT)
        for _ in range(3): a.raw(0xC1,0xE8,0x08,0xE6,OUT)   # shr eax,8 ; out
    def dr_cell(addr): mem(addr); dr_eax()
    def alignup_eax(): a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000))

    a.blob(bytes((0x89,0x1D))+le32(cell('mbinfo')))   # mov [mbinfo],ebx  (byte 0)
    a.j(None,'glue')
    a.blob(b'\x00'*(len(CELLS)*4))
    # fail frames (reached by backward jumps from the glue) + a head-local shutdown tail.
    sd=bytes([102,186,244,0,238, 102,186,0,137]) + b''.join(bytes([176,c,238]) for c in b'Shutdown') + bytes([250,244,235,253])
    FAILS=['F1','F2','F3','F4','F5','F8','F9','F10']
    for idx,f in enumerate(FAILS):
        a.lbl(f); a.blob(bytes([176,0x31+idx,0xE6,OUT])); a.j(None,'sdtail')   # mov al,'1'+idx; out; jmp sdtail
    a.lbl('sdtail'); a.blob(sd)
    a.lbl('glue')
    a.raw(0x3D); a.blob(le32(0x2BADB002)); a.j(JNE,'F1')          # cmp eax,magic
    a.raw(0xBC); a.blob(le32(kstack))                             # mov esp,kstack
    a.raw(0x8B,0x35); a.blob(le32(cell('mbinfo')))               # mov esi,[mbinfo]
    a.raw(0x8B,0x06); mme(cell('flags'))                         # mov eax,[esi]
    a.raw(0xA8,0x08); a.j(JE,'F2')
    a.raw(0xA8,0x40); a.j(JE,'F3')
    a.raw(0xA8,0x04); a.j(JE,'no_cmd')                           # cmdline bit2
    a.raw(0x8B,0x46,16); mme(cell('cmdline')); a.j(None,'cmd_done')
    a.lbl('no_cmd'); mmi(cell('cmdline'),0); a.lbl('cmd_done')
    a.raw(0xF7,0x06); a.blob(le32(0x20)); a.j(JE,'no_elf')       # elf bit5
    a.raw(0x8B,0x46,36); mme(cell('elflo'))
    a.raw(0x8B,0x46,28); a.raw(0x0F,0xAF,0x46,32); a.raw(0x03,0x46,36); mme(cell('elfhi'))
    a.j(None,'elf_done'); a.lbl('no_elf'); mmi(cell('elflo'),0); mmi(cell('elfhi'),0); a.lbl('elf_done')
    a.raw(0x8B,0x46,20); a.raw(0x83,0xF8,0x01); a.j(JNE,'F4')     # mods_count==1
    a.raw(0x8B,0x6E,24)                                          # ebp=mods_addr
    a.raw(0x8B,0x45,0x00); mme(cell('modstart'))
    a.raw(0x8B,0x45,0x04); mme(cell('modend'))
    a.raw(0x8B,0x45,0x08); mme(cell('str'))
    mem(cell('modstart')); a.raw(0x3B,0x05); a.blob(le32(cell('modend'))); a.j(JAE,'F5')

    # compute page-rounded exclusion bounds for the loader-pointed buffers (0 -> absent).
    a._ctr=getattr(a,'_ctr',0)
    def excl_ptr(srccell, locell, hicell):
        a._ctr+=1; z=f'exz{a._ctr}'; d=f'exd{a._ctr}'
        mem(srccell); a.raw(0x85,0xC0); a.j(JE,z)        # test eax,eax; jz zero
        a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(locell)  # and eax,~0xFFF
        a.raw(0x05); a.blob(le32(0x2000)); mme(hicell)      # +0x2000
        a.j(None,d); a.lbl(z); mmi(locell,0); mmi(hicell,0); a.lbl(d)
    excl_ptr(cell('mbinfo'), cell('mb_lo'), cell('mb_hi'))
    excl_ptr(cell('str'),    cell('st_lo'), cell('st_hi'))
    excl_ptr(cell('cmdline'),cell('cm_lo'), cell('cm_hi'))
    # mmap buffer [mmap_addr, mmap_addr+mmap_length) page-rounded
    a.raw(0x8B,0x46,48); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_lo'))   # eax=mmap_addr&~0xFFF
    a.raw(0x8B,0x46,48); a.raw(0x03,0x46,44); a.raw(0x05); a.blob(le32(0xFFF)); a.raw(0x25); a.blob(le32(0xFFFFF000)); mme(cell('mm_hi'))

    mmi(cell('region_lo'),0); mmi(cell('region_hi'),0)
    a.raw(0x8B,0x4E,48)                                          # ecx=mmap_addr
    a.raw(0x8B,0x56,44); a.raw(0x01,0xCA)                        # edx=end
    a.raw(0xBF); a.blob(le32(64))                                # edi=fuse
    a.lbl('mloop')
    a.raw(0x39,0xD1); a.j(JAE,'mdone')
    a.raw(0x4F); a.j(JE,'F8')
    # binary entry dump: 0x9C tag + 6 raw u32 (size,base_lo,base_hi,len_lo,len_hi,type)
    outi(0x9C)
    for d in (0,4,8,12,16,20):
        a.raw(0x8B,0x01) if d==0 else a.raw(0x8B,0x41,d)
        dr_eax()
    mem(cell('region_hi')); a.raw(0x85,0xC0); a.j(JNE,'madv')    # already chosen?
    a.raw(0x8B,0x41,20); a.raw(0x83,0xF8,0x01); a.j(JNE,'madv')  # type@20==1?
    a.raw(0x8B,0x41,8); a.raw(0x85,0xC0); a.j(JNE,'madv')        # base_hi@8==0?
    a.raw(0x8B,0x41,4)                                           # eax=base_lo
    a.raw(0x8B,0x59,12); a.raw(0x01,0xD8)                        # ebx=len_lo; eax+=ebx
    a.raw(0x8B,0x59,16); a.raw(0x85,0xDB); a.j(JE,'no_clamp')    # len_hi@16 !=0 -> clamp
    a.raw(0xB8); a.blob(le32(0xFFFFF000)); a.lbl('no_clamp')
    a.raw(0x3D); a.blob(le32(0x100000)); a.j(JBE,'madv')         # end>0x100000?
    mme(cell('region_hi')); a.raw(0x8B,0x41,4); mme(cell('region_lo'))
    a.lbl('madv')
    a.raw(0x8B,0x01); a.raw(0x83,0xC0,0x04); a.raw(0x01,0xC1); a.j(None,'mloop')
    a.lbl('mdone')
    mem(cell('region_hi')); a.raw(0x85,0xC0); a.j(JE,'F9')

    # bump alloc: cursor=align_up(max(region_lo,0x100000))
    mem(cell('region_lo')); a.raw(0x3D); a.blob(le32(0x100000)); a.j(JAE,'have_floor')
    a.raw(0xB8); a.blob(le32(0x100000)); a.lbl('have_floor')
    alignup_eax(); a.raw(0x89,0xC1)                             # ecx=cursor
    a.raw(0xBF); a.blob(le32(16))                             # edi=pass fuse
    a.lbl('rescan')
    a.raw(0x4F); a.j(JE,'F10')
    a.raw(0x31,0xDB)                                           # xor ebx,ebx moved
    def excl(lo, hi):
        a._ctr+=1; sk=f'sk{a._ctr}'
        if hi[0]=='lit': a.raw(0x81,0xF9); a.blob(le32(hi[1]))      # cmp ecx,hi
        else: a.raw(0x3B,0x0D); a.blob(le32(hi[1]))                 # cmp ecx,[hi]
        a.j(JAE,sk)
        a.raw(0x8D,0x81); a.blob(le32(0x1000))                      # lea eax,[ecx+0x1000]
        if lo[0]=='lit': a.raw(0x3D); a.blob(le32(lo[1]))
        else: a.raw(0x3B,0x05); a.blob(le32(lo[1]))
        a.j(JBE,sk)                                                 # cursor_hi<=lo -> no overlap
        if hi[0]=='lit': a.raw(0xB8); a.blob(le32(hi[1]))
        else: mem(hi[1])
        alignup_eax(); a.raw(0x89,0xC1); a.raw(0xBB); a.blob(le32(1))
        a.lbl(sk)
    if mut!='noexclude':
        excl(('lit',0x100000), ('lit',kend))                       # kernel
        excl(('cell',cell('modstart')), ('cell',cell('modend')))   # module
        if mut!='noexclbuf':                                        # the loader-pointed buffers
            excl(('cell',cell('mb_lo')), ('cell',cell('mb_hi')))   # mbinfo
            excl(('cell',cell('st_lo')), ('cell',cell('st_hi')))   # module string
            excl(('cell',cell('cm_lo')), ('cell',cell('cm_hi')))   # cmdline
            excl(('cell',cell('elflo')), ('cell',cell('elfhi')))   # elf shdr
            excl(('cell',cell('mm_lo')), ('cell',cell('mm_hi')))   # mmap buffer
    a.raw(0x85,0xDB); a.j(JNE,'rescan')
    a.raw(0x8D,0x81); a.blob(le32(0x1000))                       # lea eax,[ecx+0x1000]
    a.raw(0x3B,0x05); a.blob(le32(cell('region_hi'))); a.j(JA,'F10')
    if mut=='hardcodeaddr':
        a.raw(0xB9); a.blob(le32(0x300000))                      # ecx=0x300000 (inside FAT span)
    a.raw(0x89,0x0D); a.blob(le32(cell('alloc_lo')))
    a.raw(0x8D,0x81); a.blob(le32(0x1000)); mme(cell('alloc_hi'))

    # binary named block: 0x9A tag + k0,k1,ma,ml + the whole contiguous cell array (NCELLS u32) via a loop
    outi(0x9A)
    a.raw(0xB8); a.blob(le32(LOAD)); dr_eax()                    # k0
    a.raw(0xB8); a.blob(le32(kend)); dr_eax()                    # k1
    a.raw(0x8B,0x46,48); dr_eax()                                # mmap_addr
    a.raw(0x8B,0x46,44); dr_eax()                                # mmap_length
    # dump cells[0..NCELLS): mov esi,CELLBASE ; mov ecx,NCELLS ; loop {out 4 bytes of [esi]; add esi,4}
    a.raw(0xBE); a.blob(le32(CELLBASE))                          # mov esi,CELLBASE
    a.raw(0xB9); a.blob(le32(len(CELLS)))                        # mov ecx,NCELLS
    a.lbl('dumpcell')
    a.raw(0x8A,0x06,0xE6,OUT)                                    # mov al,[esi]; out
    a.raw(0x8A,0x46,0x01,0xE6,OUT)                               # mov al,[esi+1]; out
    a.raw(0x8A,0x46,0x02,0xE6,OUT)                               # mov al,[esi+2]; out
    a.raw(0x8A,0x46,0x03,0xE6,OUT)                               # mov al,[esi+3]; out
    a.raw(0x83,0xC6,0x04)                                        # add esi,4
    a.raw(0x49); a.raw(0x85,0xC9); a.j(JNE,'dumpcell')           # dec ecx; test; jnz
    outi(0x9B)

    if mut=='provlit':
        mmi(cell('alloc_lo'),0x900000); mmi(cell('alloc_hi'),0x901000)
    if mut=='aliasframe':
        a.raw(0xBC); a.blob(le32(ENTRY+0x40))                    # esp into kernel code page
    else:
        a.raw(0x8B,0x25); a.blob(le32(cell('alloc_hi')))         # mov esp,[alloc_hi]
    if mut=='modaddr':
        a.raw(0xFF,0x15); a.blob(le32(cell('mbinfo')))           # call [mbinfo] -- a non-code pointer (robust RED)
    elif mut=='skipcall':
        a.raw(0xB8); a.blob(le32(0x5A))                          # bake answer, no call
    else:
        a.raw(0xFF,0x15); a.blob(le32(cell('modstart')))         # call [modstart]
    mme(cell('answer'))
    a.raw(0xBC); a.blob(le32(kstack))                            # mov esp,kstack
    a.raw(0xFC)                                                  # cld -- END OF HEAD; falls through to body
    return a.assemble()

# the compiled body for "return module_byte()": op46 (movzx eax,byte[answer]; push eax) + op21-last (pop eax)
def echo_body(): return bytes([0x0F,0xB6,0x05])+le32(cell('answer'))+bytes([0x50,0x58])
EPI=bytes([136,195, 102,186,233,0, 176,222,238, 136,216,238, 176,173,238,
           136,216, 52,49, 36,127,
           102,186,244,0,238, 102,186,0,137]) \
    + b''.join(bytes([176,c,238]) for c in b'Shutdown') + bytes([250,244,235,253])

def build_elf(mut=None):
    head0=build_head(0,0,mut); head_len=len(head0)
    body=echo_body(); code_len=head_len+len(body)+len(EPI)
    filesz0=12+code_len; pad4=(4-(filesz0%4))%4; memsz=filesz0+pad4+16384
    kstack=LOAD+memsz; kend=LOAD+memsz
    head=build_head(kstack,kend,mut); assert len(head)==head_len,(len(head),head_len)
    code=head+body+EPI
    filesz=12+len(code); pad4=(4-(filesz%4))%4
    shoff=4096+filesz+pad4
    ehdr=(b'\x7fELF\x01\x01\x01\x00'+b'\x00'*8+struct.pack('<HHI',2,3,1)+le32(ENTRY)+le32(52)+le32(shoff)+le32(0)
          +struct.pack('<HHHHHH',52,32,1,40,1,0))
    phdr=le32(1)+le32(4096)+le32(LOAD)+le32(LOAD)+le32(filesz)+le32(memsz)+le32(7)+le32(4096)
    mbh=bytes((0x02,0xB0,0xAD,0x1B))+le32(0x00000002)+le32(0xE4524FFC)   # MEMINFO header (flags=2)
    img=ehdr+phdr+b'\x00'*(4096-84)+mbh+code+b'\x00'*pad4+b'\x00'*40
    return img,kend

# ---- witness modules (raw, position-independent; emit CA CA <esp+4> <eip> FE FE then ret) ----
def witness(answer_code, tag, pad=0, stack_words=0):
    a=Asm()
    a.raw(0x89,0xE6)                       # mov esi,esp (entry esp = alloc_hi-4)
    a.raw(0x83,0xC6,0x04)                  # add esi,4   (= alloc_hi)
    a.raw(0xE8,0,0,0,0)                    # call .pc
    a.raw(0x5F)                            # pop edi (= &.pc, in [mstart,mend))
    if stack_words:                        # optional deep-stack spray (M-aliasframe/noexclude bite)
        a.raw(0xB9); a.blob(le32(stack_words)); a.lbl('spray'); a.raw(0x57); a.raw(0xE2,0xFD)  # push edi loop
        a.raw(0xB9); a.blob(le32(stack_words)); a.lbl('unspray'); a.raw(0x5B); a.raw(0xE2,0xFD)
    a.raw(0xB0,0xCA,0xE6,OUT,0xE6,OUT)     # CA CA
    a.raw(0x89,0xF0)                       # mov eax,esi (alloc_hi)
    for _ in range(4): a.raw(0xE6,OUT,0xC1,0xE8,0x08)   # out al; shr eax,8  x4
    a.raw(0x89,0xF8)                       # mov eax,edi (eip)
    for _ in range(4): a.raw(0xE6,OUT,0xC1,0xE8,0x08)
    a.raw(0xB0,0xFE,0xE6,OUT,0xE6,OUT)     # FE FE
    a.blob(answer_code)                    # compute EAX (no single immediate)
    a.raw(0xC3)
    code=a.assemble()
    return code+tag.encode()+(b'\xCC'*pad)

# answer 0x5A computed: mov eax,0x50; add eax,0x0A   ; 0xA7: mov eax,0x40; xor eax,0xE7
AX=bytes([0xB8])+le32(0x50)+bytes([0x05])+le32(0x0A)
AY=bytes([0xB8])+le32(0x40)+bytes([0x35])+le32(0xE7)



# ===== host grader (from grade.py) =====
#!/usr/bin/env python3
# Host grader: parse the 0xE9 stream (ownership ASCII table + binary CA/FE witness + DE??AD answer),
# recompute the allocator policy from the dumped+golden mmap, assert equality + witness + answer.

CELL_NAMES=['mbinfo','flags','modstart','modend','str','cmdline','elflo','elfhi',
            'region_lo','region_hi','alloc_lo','alloc_hi','answer_cell',
            'mb_lo','mb_hi','st_lo','st_hi','cm_lo','cm_hi','mm_lo','mm_hi']
CK={'mbinfo':'mb','modstart':'ms','modend':'me','str':'st','cmdline':'cm','elflo':'el','elfhi':'eh',
    'region_lo':'rl','region_hi':'rh','alloc_lo':'al','alloc_hi':'ah'}

def parse(stream: bytes):
    # binary stream: [0x9C + 6 u32]* entries ; 0x9A + k0,k1,ma,ml + NCELLS u32 + 0x9B ; CA CA esp eip FE FE ; DE b AD
    r={}; i=0; entries=[]
    n=len(stream)
    while i<n and stream[i]==0x9C and i+1+24<=n:
        vals=struct.unpack('<6I', stream[i+1:i+25]); i+=25
        entries.append(dict(size=vals[0],blo=vals[1],bhi=vals[2],llo=vals[3],lhi=vals[4],ty=vals[5]))
    r['entries']=entries
    if i<n and stream[i]==0x9A:
        i+=1
        k0,k1,ma,ml=struct.unpack('<4I', stream[i:i+16]); i+=16
        r['k0'],r['k1'],r['ma'],r['ml']=k0,k1,ma,ml
        ncell=len(CELL_NAMES)
        cells=struct.unpack('<%dI'%ncell, stream[i:i+4*ncell]); i+=4*ncell
        for nm,v in zip(CELL_NAMES,cells):
            if nm in CK: r[CK[nm]]=v
            else: r[nm]=v
        # block terminator 0x9B expected at i
        r['block_ok'] = (i<n and stream[i]==0x9B); i+=1
    else:
        return None
    w=re.search(rb'\xCA\xCA(.{4})(.{4})\xFE\xFE', stream[i:], re.S)
    if w:
        r['w_esp']=struct.unpack('<I',w.group(1))[0]; r['w_eip']=struct.unpack('<I',w.group(2))[0]
    an=re.search(rb'\xDE(.)\xAD', stream[i:], re.S)
    if an: r['answer']=an.group(1)[0]
    return r

def _ptr_excl(p):
    # page-rounded exclusion bound for a loader pointer (kernel uses [floor, floor+0x2000); 0 -> absent)
    if not p: return None
    lo=p & ~0xFFF; return (lo, lo+0x2000)

def recompute_alloc(r, kend):
    # mirror the kernel EXACTLY: first type-1 region with bhi==0 and end>0x100000; floor 0x100000;
    # align_up; rescan-to-fixpoint over the FULL exclusion set with identical rounding.
    region=None
    for e in r['entries']:
        if region: break
        if e['ty']!=1 or e['bhi']!=0: continue
        hi = 0xFFFFF000 if e['lhi'] else (e['blo']+e['llo'])
        if hi>0x100000: region=(e['blo'],hi)
    if not region: return None
    rlo,rhi=region
    excl=[(0x100000,kend), (r['ms'],r['me'])]
    for p in ('mb','st','cm'):
        e=_ptr_excl(r[p]);  excl.append(e) if e else None
    if r['el'] and r['eh']: excl.append((r['el'],r['eh']))
    if r['ma'] is not None and r['ml']:
        mlo=r['ma']&~0xFFF; mhi=(r['ma']+r['ml']+0xFFF)&~0xFFF; excl.append((mlo,mhi))
    cur=(max(rlo,0x100000)+0xFFF)&~0xFFF
    for _ in range(16):
        moved=False
        for lo,hi in excl:
            if cur<hi and lo<cur+0x1000:
                cur=(hi+0xFFF)&~0xFFF; moved=True
        if not moved: break
    if cur+0x1000>rhi: return None
    return cur, cur+0x1000, region

WITNESS_EIP_OFF=10   # witness module: mov esi,esp(2)+add esi,4(3)+call .pc(5) -> .pc(pop) at +10

def grade(stream, kend_elf, golden_byte, golden_map=None, label='', strict_map=True, ram_mb=None):
    errs=[]
    r=parse(stream)
    if not r: return ['no OWN table parsed (run faulted before dump or RED)']
    # kernel extent: host trusts the ELF, not the dump
    if r['k1']!=kend_elf: errs.append(f'dumped k1=0x{r["k1"]:x} != ELF kend=0x{kend_elf:x}')
    if r['k0']!=0x100000: errs.append(f'k0 != 0x100000')
    # ANTI-FABRICATION (version-robust, replaces the brittle exact golden-map pin): the kernel
    # demonstrably runs at 0x100000, so [0x100000, kend) MUST lie inside a dumped type-1 region.
    # A kernel that fabricates a map (to forge ownership) omits the real RAM and fails this. The
    # exact-map pin is intentionally NOT used (it false-REDs across emulator versions); map-fabrication
    # is further bounded by the witness + recompute-equality + cross-substrate placement divergence.
    in_t1=any(e['ty']==1 and e['bhi']==0 and e['blo']<=0x100000 and kend_elf<=e['blo']+e['llo'] for e in r['entries'])
    if not in_t1: errs.append('kernel [0x100000,kend) not inside any dumped type-1 region (fabricated map?)')
    # RAM-total sanity (bounds the synthetic-map forge, version-robustly): the dumped type-1 bytes
    # must be a believable fraction of the real -m size. A map that omits real RAM or invents regions
    # to forge ownership mismatches this. (Cross-substrate placement divergence + witness eip also bound it.)
    if ram_mb is not None:
        # LOWER bound only, capped at 3 GiB (a 32-bit kernel sums only the low base_hi==0 type-1
        # regions; >4 GiB RAM has a high region it correctly skips, so an exact match is wrong).
        t1=sum(e['llo'] for e in r['entries'] if e['ty']==1 and e['bhi']==0)
        floor=int(0.5*min(ram_mb*1024*1024, 0xC0000000))
        if t1 < floor:
            errs.append(f'dumped low type-1 RAM 0x{t1:x} < 0.5*min(-m {ram_mb}M, 3GiB) = 0x{floor:x} (fabricated map omitting real RAM?)')
    # mbinfo pointer must be a real (nonzero) loader pointer -- a fully-zeroed fabricated dump fails.
    if not r['mb']: errs.append('dumped mbinfo pointer is 0 (fabricated ownership table?)')
    if golden_map is not None:   # optional exact pin (used only when a per-leg golden is committed)
        got=[(e['blo'],e['bhi'],e['llo'],e['lhi'],e['ty']) for e in r['entries']]
        if got!=golden_map:
            errs.append(f'dumped mmap != golden map ({len(got)} vs {len(golden_map)} entries)')
    # recompute allocator and demand equality
    rec=recompute_alloc(r,kend_elf)
    if not rec: errs.append('host could not recompute a fit')
    else:
        elo,ehi,reg=rec
        if r['al']!=elo: errs.append(f'alloc_lo 0x{r["al"]:x} != recomputed 0x{elo:x}')
        if r['ah']!=ehi: errs.append(f'alloc_hi 0x{r["ah"]:x} != recomputed 0x{ehi:x}')
        if (r['rl'],r['rh'])!=reg: errs.append(f'region ({r["rl"]:x},{r["rh"]:x}) != recomputed ({reg[0]:x},{reg[1]:x})')
    # overlap: alloc must overlap nothing in the full exclusion set
    al,ah=r['al'],r['ah']
    def ov(lo,hi): return lo is not None and hi is not None and al<hi and lo<ah
    if ov(0x100000,kend_elf): errs.append('alloc overlaps kernel')
    if ov(r['ms'],r['me']): errs.append('alloc overlaps module')
    if r['mb'] and ov(r['mb'],r['mb']+0x1000): errs.append('alloc overlaps mbinfo page')
    if r['st'] and ov(r['st'],r['st']+0x1000): errs.append('alloc overlaps string page')
    if r['cm'] and ov(r['cm'],r['cm']+0x1000): errs.append('alloc overlaps cmdline page')
    if r['el'] and r['eh'] and ov(r['el'],r['eh']): errs.append('alloc overlaps elf-shdr')
    # witness
    if 'w_esp' not in r: errs.append('no module witness frame (module did not run / wrong stack)')
    else:
        if r['w_esp']!=r['ah']: errs.append(f'witness esp 0x{r["w_esp"]:x} != alloc_hi 0x{r["ah"]:x} (module ran on a different stack)')
        # EXACT eip pin (Codex: '..in [ms,me)' is weak): the witness .pc is at mod_start+WITNESS_EIP_OFF.
        if r['w_eip']!=r['ms']+WITNESS_EIP_OFF: errs.append(f'witness eip 0x{r["w_eip"]:x} != mod_start+{WITNESS_EIP_OFF} (0x{r["ms"]+WITNESS_EIP_OFF:x}) -- module did not run from its loader-placed entry')
    # answer
    if r.get('answer')!=golden_byte: errs.append(f'answer 0x{r.get("answer")} != golden 0x{golden_byte:x}')
    return errs


# ===================== CLI =====================
def _modkind(kind):
    if kind=='X': return witness(AX,'LODGX')
    if kind=='Y': return witness(AY,'LODGY')
    if kind=='FAT': return witness(AX,'LODGFAT',pad=4*1024*1024,stack_words=512)
    if kind=='STACK': return witness(AX,'LODGSTK',stack_words=512)
    if kind=='CLOB': return witness(bytes([0xBB])+le32(0xDEAD)+bytes([0xFD,0xB8])+le32(0x5A),'LODGCLB')
    raise SystemExit('unknown module kind '+kind)

if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='head':           # head <esp_top_hex> -> head bytes hex (white-box reference)
        et=int(sys.argv[2],16); sys.stdout.write(build_head(et,et).hex())
    elif cmd=='module':       # module <X|Y|FAT|STACK|CLOB> <outfile>
        open(sys.argv[3],'wb').write(_modkind(sys.argv[2]))
    elif cmd=='cleanelf':     # cleanelf <outfile> -> the reference echo image (== compiler output)
        img,_=build_elf(); open(sys.argv[2],'wb').write(img)
    elif cmd=='mutate':       # mutate <mut> <outfile> -> the reference echo image with one design defect
        img,_=build_elf(sys.argv[2]); open(sys.argv[3],'wb').write(img)
    elif cmd=='kend':         # kend <mut|-> -> esp_top hex for that variant
        m=None if sys.argv[2]=='-' else sys.argv[2]; _,k=build_elf(m); print('%x'%k)
    elif cmd=='epi':          # epi -> the exact epilogue bytes hex (pins the only other 0xE9 emit site)
        sys.stdout.write(EPI.hex())
    elif cmd=='genmap':       # genmap <e9.bin> -> golden map (one entry/line: blo bhi llo lhi ty)
        r=parse(open(sys.argv[2],'rb').read())
        for e in r['entries']: print('%08x %08x %08x %08x %d'%(e['blo'],e['bhi'],e['llo'],e['lhi'],e['ty']))
    elif cmd=='grade':        # grade <e9.bin> <kend_hex> <golden_byte_hex> [goldenmapfile|-] [ram_mb]
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16); gb=int(sys.argv[4],16)
        gmap=None
        if len(sys.argv)>5 and sys.argv[5]!='-':
            gmap=[tuple(int(x,16) if i<4 else int(x) for i,x in enumerate(line.split())) for line in open(sys.argv[5]) if line.strip()]
        ram=int(sys.argv[6]) if len(sys.argv)>6 else None
        errs=grade(stream,kend,gb,golden_map=gmap,ram_mb=ram)
        if errs:
            print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    else:
        raise SystemExit('usage: head|module|genmap|grade')
