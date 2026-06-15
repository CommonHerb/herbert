#!/usr/bin/env python3
# mumbani_ref.py -- mumbani (link 27 / native-codegen Link 43) STEP-0 oracle + BYTE-EXACT emitter target.
#
# mumbani = MULTI-PAGE WORKING MEMORY: the kernel hands the compiled ring-3 module a working set LARGER THAN ONE
# PAGE. Every prior kernel (lodger..chiefturbo) bump-allocated and User-mapped EXACTLY ONE 4 KiB frame, so a module
# could compute (ouroboros), emit (holler/mmj) and index a buffer (chiefturbo) -- but only within ~4096 bytes; a
# working set beyond one page #PFs (the page wall). mumbani's kernel allocates K=4 CONTIGUOUS frames and User-maps
# all of them (D20's SECOND installment: lodger's one-page bump widened to a multi-page region). This is a KERNEL
# capability (the bare-metal allocator + paging-U/S map), NOT a new module-ISA op -- the module ISA is unchanged.
#
# TYPE-II: a NEW kernel emit mode (`multiboot32-mumbani`) = the holler kernel with npages=4 (3 alloc-size immediates
# 0x1000->0x4000 + the alloc_lo User-flip widened from 1 PTE to 4). The do_write access_ok bound and the module
# entry esp both read alloc_hi BY VALUE, so they auto-widen to the 4-page span. The frozen geeking/holler kernels
# are byte-IDENTICAL at npages=1 (verified). The MODULE reuses the EXISTING `module-mumbani` mode (= module-mmj
# with sys_read relaxed from ==1 to >=1, since reverse reads N+1 words) -- recursion + multi sys_read + sys_write,
# NO new op. So build_elf() below is H.build_elf(npages=4); the reverse module is M.emit(REV_FUNCS) (mmj's emitter).
#
# THE FORCING PROGRAM -- recursive REVERSE of N held-back random 24-bit words (write-on-unwind):
#     func readword(): let b0=sys_read() let b1=sys_read() let b2=sys_read() return b0+256*(b1+256*b2) end
#     func rev(k):
#         if k == 0: return 0 end
#         let w = readword()          # read THIS level's word on the way DOWN
#         let r = rev(k - 1)          # recurse to read+emit the REST first
#         return sys_write(w) + r     # emit w on the way back UP -> REVERSE order
#     end
#     func main(): let n = readword()  return rev(n) end
#
# rev(N) descends N deep (one frame per word, words held in the recursion stack) reading w_0..w_{N-1}, then on the
# way UP emits w_{N-1},...,w_0 -- the input stream REVERSED. THE MAKE-OR-BREAK: with N chosen so N*frame > 4096,
# the recursion stack EXCEEDS one page, so on the FROZEN 1-page holler kernel the descent #PFs BEFORE any write
# (0 output words, answer 'P'); on the mumbani 4-page kernel it descends fully and emits all N words reversed. The
# reversed HELD-BACK RANDOM stream is the un-fakeable witness (gx vs gy differ; no closed form / compression /
# single-pass-stream reproduces a reverse). The make-or-break is bound at BOTH layers: (1) RUNTIME differential
# (mumbani GREEN / frozen-holler RED on the SAME module) + the write esps SPAN >1 page (multi-page witness);
# (2) the EMITTER layer -- the kernel is byte-pinned to build_elf() (carrying the 4-page alloc + 4-PTE flip, which
# a white-box gate asserts), and the module byte-pinned to target_module() -- the ultimate binding, mmj's pattern.
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holler_ref as H      # kernel build_elf(npages=), parse(), recompute_alloc(), UCODE3
import mmj_ref as M         # the plain recursive multi-function emitter (emit/layout/frame_size) -- module-mmj/mumbani

NPAGES = 4                  # mumbani: K=4 contiguous User pages (16 KiB working set; cap moved 4 KiB -> 16 KiB)
UCODE3 = H.UCODE3
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)

# ---- the reverse forcing program, in BFS-reachability func order from main = [main, readword, rev] ----
# (the compiler hoists main to index 0 then visits callees breadth-first: main -> readword, rev). The IR mirrors
# the compiler's left-operand-first lowering; readword is BYTE-IDENTICAL to chiefturbo's (same source line).
REV_FUNCS = [
  ('main', 0, [('call',('readword',0)),('storel',0),('loadl',0),('call',('rev',1)),('ret',0)]),
  ('readword', 0, [('sysread',0),('storel',0),('sysread',0),('storel',1),('sysread',0),('storel',2),
                   ('loadl',0),('push',256),('loadl',1),('push',256),('loadl',2),
                   ('mul',0),('add',0),('mul',0),('add',0),('ret',0)]),
  ('rev', 1, [('loadl',0),('push',0),('eq',0),('brf',6),('push',0),('ret',0),
              ('call',('readword',0)),('storel',1),('loadl',0),('push',1),('sub',0),('call',('rev',1)),('storel',2),
              ('loadl',1),('syswrite',0),('loadl',2),('add',0),('ret',0)]),
]

def target_module(kind='gx'): return M.emit(REV_FUNCS)     # data-INDEPENDENT: ONE module for all probes

# FORWARD-emit forge (module mutation): emits each word on the way DOWN (before recursing) -> the input in FORWARD
# order, NOT reversed. It STILL needs N-deep recursion (Herbert has no loops; the lowering does not TCO), so it
# ALSO #PFs on a 1-page kernel and runs only on the 4-page kernel -- but the CONTENT pin (body[j]==word[N-1-j])
# catches the wrong order, and it is byte-DIFFERENT from target_module() (the emitter byte-pin catches it too).
FWD_FUNCS = [
  ('main', 0, [('call',('readword',0)),('storel',0),('loadl',0),('call',('rev',1)),('ret',0)]),
  ('readword', 0, [('sysread',0),('storel',0),('sysread',0),('storel',1),('sysread',0),('storel',2),
                   ('loadl',0),('push',256),('loadl',1),('push',256),('loadl',2),
                   ('mul',0),('add',0),('mul',0),('add',0),('ret',0)]),
  ('rev', 1, [('loadl',0),('push',0),('eq',0),('brf',6),('push',0),('ret',0),
              ('call',('readword',0)),('storel',1),('loadl',1),('syswrite',0),('storel',2),
              ('loadl',0),('push',1),('sub',0),('call',('rev',1)),('storel',3),
              ('loadl',2),('loadl',3),('add',0),('ret',0)]),
]
def forge_module(kind='gx'): return M.emit(FWD_FUNCS)       # forward-emit (wrong order) -- caught by content + byte-pin
def herb_src(kind='gx'):
    return ("func readword():\n    let b0 = sys_read()\n    let b1 = sys_read()\n    let b2 = sys_read()\n"
            "    return b0 + 256 * (b1 + 256 * b2)\nend\n"
            "func rev(k):\n    if k == 0:\n        return 0\n    end\n"
            "    let w = readword()\n    let r = rev(k - 1)\n    return sys_write(w) + r\nend\n"
            "func main():\n    let n = readword()\n    return rev(n)\nend")

import random
# gate feeds FRESH held-back seeds; these named probes are the STEP-0 oracle. N must satisfy N*frame > 4096 (fail
# on the 1-page holler kernel) AND N*frame < 4*4096 (fit the mumbani 4-page kernel). frame ~= 24 B (S=3) -> the
# one-page wall is ~170 levels; N=400 (~9.6 KiB) clears it with margin and spans ~3 pages (multi-page witness),
# well under the 16 KiB cap. n is delivered via readword (3 bytes), so N is not limited to one byte.
NDEF = 400
SEEDS = {'gx': 0x3E7A10, 'gy': 0x3E7A11}
def _resolve(arg):
    if arg in SEEDS: return SEEDS[arg], NDEF
    return int(arg) & 0xFFFFFFFF, NDEF
def _words(seed, N):
    """N random 24-bit words, each byte in [1,0x7F] so le32(word)=[b0,b1,b2,0] carries NO witness-marker byte.
       RANDOM + HELD-BACK by a fresh gate seed -> the reversed output cannot be baked, recomputed, or streamed."""
    rng = random.Random(seed)
    return [rng.randint(1,0x7F) | (rng.randint(1,0x7F) << 8) | (rng.randint(1,0x7F) << 16) for _ in range(N)]
def fed_stream(arg='gx'):
    seed, N = _resolve(arg); words = _words(seed, N)
    out = bytes([N & 0xFF, (N >> 8) & 0xFF, (N >> 16) & 0xFF])     # n via readword (3 bytes)
    for w in words: out += bytes([w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF])
    return out
def host_writes(arg='gx'):
    seed, N = _resolve(arg); words = _words(seed, N)
    return [le32(words[N-1-j]) for j in range(N)]                 # output = input REVERSED
def host_answer(arg='gx'): return 0                              # rev returns 0 (sys_write returns 0, +0 = 0)
def expect_reads(arg='gx'):
    seed, N = _resolve(arg); return 3*(N+1)                      # readword(n): 3 + N words * 3 each

# ---- the 4-page allocation recompute (mumbani grader): mirror of H.recompute_alloc with npages*0x1000 ----
def recompute_alloc_mb(r, kend, npages=NPAGES):
    region=None
    for e in r['entries']:
        if region: break
        if e['ty']!=1 or e['bhi']!=0: continue
        hi=0xFFFFF000 if e['lhi'] else (e['blo']+e['llo'])
        if hi>0x100000: region=(e['blo'],hi)
    if not region: return None
    rlo,rhi=region
    span=npages*0x1000
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
            if cur<hi and lo<cur+span: cur=(hi+0xFFF)&~0xFFF; moved=True
        if not moved: break
    if cur+span>rhi: return None
    return cur,cur+span,region

def _read_frames(stream):
    out=[]; i=0; n=len(stream)
    while i<n:
        i=stream.find(b'\xC0', i)
        if i<0: break
        if i+15<=n:
            cs,eip,esp=struct.unpack('<3I', stream[i+2:i+14])
            if cs==UCODE3 and stream[i+14]==0xC1:
                out.append(dict(byte=stream[i+1],eip=eip,esp=esp)); i+=15; continue
        i+=1
    return out
def _write_frames(stream):
    out=[]; i=0; n=len(stream)
    while i<n:
        i=stream.find(b'\xD4', i)
        if i<0: break
        if i+22<=n:
            ln,cs,eip,esp=struct.unpack('<4I', stream[i+1:i+17]); body=stream[i+17:i+21]
            if ln==4 and cs==UCODE3 and stream[i+21]==0xD5:
                out.append(dict(cs=cs,eip=eip,esp=esp,body=body)); i+=22; continue
        i+=1
    return out

# ===================== STEP-0 / gate grader =====================
def grade(stream, kend_elf, arg='gx', npages=NPAGES):
    """RUNTIME grade for the mumbani reverse. The GENUINE multi-page run emits the N held-back words REVERSED:
       pins delivered n==N (read-frame count == 3*(N+1)); EXACTLY N write frames; frame j relays le32(word[N-1-j])
       [the reversal content witness, random+held-back]; every write esp in the 4-page region [alloc_lo,alloc_hi);
       and the write esps SPAN MORE THAN ONE PAGE (max-min > 4096 -- the multi-page-working-set witness that a
       1-page kernel cannot produce); answer == 0. On the FROZEN 1-page holler kernel the descent #PFs before any
       write -> 0 write frames -> RED (the make-or-break differential). The make-or-break is ALSO bound at the
       EMITTER layer (kernel byte-pin to build_elf() + the 4-page-alloc/4-PTE-flip white-box assert; module byte-pin
       to target_module()) -- a kernel that fakes more memory another way, or a non-reverse module, is a DIFFERENT
       binary caught there."""
    errs=[]; seed,N=_resolve(arg)
    r=H.parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or kernel RED)']
    if r.get('k1') is not None and r['k1']!=kend_elf:
        errs.append(f'dumped k1=0x{r["k1"]:x} != kend=0x{kend_elf:x}')
    ah,al=r.get('ah'),r.get('al')
    rec=recompute_alloc_mb(r, kend_elf, npages)
    if rec:
        elo,ehi,_=rec
        if al!=elo: errs.append(f'alloc_lo 0x{al:x} != recomputed 0x{elo:x}')
        if ah!=ehi: errs.append(f'alloc_hi 0x{ah:x} != recomputed 0x{ehi:x} (4-page span = alloc_lo+{npages}*0x1000)')
    rfs=_read_frames(stream)
    if not rfs: errs.append('no read-witness frame (SYS_READ not serviced at CPL3)')
    elif len(rfs)!=expect_reads(arg):
        errs.append(f'{len(rfs)} read frames != expected {expect_reads(arg)} (=3*(N+1)) -- module skipped input')
    wfs=_write_frames(stream); want=host_writes(arg)
    if len(wfs)!=N:
        errs.append(f'{len(wfs)} write-relay frame(s) != N={N} (reverse must emit exactly N words; a 1-page kernel '
                    f'#PFs mid-descent and emits 0 -- the multi-page make-or-break differential)')
    else:
        esps=[w['esp'] for w in wfs]
        for j,wf in enumerate(wfs):
            if wf['cs']!=UCODE3 or (wf['cs']&3)!=3: errs.append(f'write frame {j} cs 0x{wf["cs"]:x} != UCODE3/RPL3')
            if al is not None and ah is not None and not (al<=wf['esp']<ah):
                errs.append(f'write frame {j} useresp 0x{wf["esp"]:x} not in [alloc_lo 0x{al:x}, alloc_hi 0x{ah:x})')
            if wf['body']!=want[j]:
                errs.append(f'write frame {j} relayed {wf["body"].hex()} != {want[j].hex()} (NOT word[N-1-{j}] -- '
                            f'wrong reversal/content, the held-back random witness)')
        span=max(esps)-min(esps)
        if span<=4096:
            errs.append(f'write esp span {span} <= 4096 -- the working set fit ONE page (multi-page witness FAILED; '
                        f'mumbani must use a >1-page recursion stack)')
    if r.get('answer')!=host_answer(arg):
        errs.append(f'answer {r.get("answer")} != {host_answer(arg)} (rev returns 0)')
    return errs

# ---- white-box assert (build-phase): the mumbani kernel carries the 4-page alloc-size immediate (0x4000, le32)
# AND >= NPAGES alloc_lo-specific User-flip blocks. Each per-page flip starts with `mov eax,[alloc_lo]`
# (A1 + le32(cell('alloc_lo'))) -- the module-code flip uses [modstart] (a DIFFERENT cell), so this counts
# EXACTLY the stack-region User-flips: 4 for the genuine kernel, 1 for the frozen 1-page holler, and < 4 for any
# flip_pages<4 forge (so it is alloc_lo-semantic, not a generic flip-pattern smoke test -- closes the
# completeness-critic finding that a `25 FC FF FF FF` count of >=4 could be met by 1 module + 3 stack flips).
def assert_fourpage(kelf):
    if bytes([0x00,0x40,0x00,0x00]) not in kelf: return False     # le32(0x4000) = NPAGES*0x1000 alloc span
    flip = bytes([0xA1]) + le32(H.cell('alloc_lo'))              # `mov eax,[alloc_lo]` -- 1st insn of each flip block
    return kelf.count(flip) >= NPAGES

# ---- kernel builders: the mumbani 4-page kernel + mutant kernels ----
def kernel_elf(mut=None):
    if mut=='flip1':   img,kend,_=H.build_elf(npages=NPAGES, flip_pages=1)      # M-flip1: 4-page alloc, flip 1 PTE
    elif mut=='onepage': img,kend,_=H.build_elf(npages=1)                       # M-onepage: revert to 1-page (= holler-ish)
    else:              img,kend,_=H.build_elf(npages=NPAGES)
    return img,kend

if __name__ == '__main__':
    cmd=sys.argv[1]
    if cmd=='module':       open(sys.argv[2],'wb').write(target_module())
    elif cmd=='forge':      open(sys.argv[2],'wb').write(forge_module())
    elif cmd=='hex':        sys.stdout.write(target_module().hex())
    elif cmd=='src':        sys.stdout.write(herb_src())
    elif cmd=='stream':     sys.stdout.write(' '.join(str(b) for b in fed_stream(sys.argv[2] if len(sys.argv)>2 else 'gx')))
    elif cmd=='kernelelf':  mut=sys.argv[3] if len(sys.argv)>3 else None; img,kend=kernel_elf(mut); open(sys.argv[2],'wb').write(img); print('%x'%kend)
    elif cmd=='kend':       _,kend=kernel_elf(); print('%x'%kend)
    elif cmd=='fourpage':   sys.exit(0 if assert_fourpage(open(sys.argv[2],'rb').read()) else 1)
    elif cmd=='offsets':
        b,io,eo,tot=M.layout(REV_FUNCS)
        print('len',len(target_module()),'bases',b,'total',tot,'N',NDEF)
    elif cmd=='grade':
        stream=open(sys.argv[2],'rb').read(); kend=int(sys.argv[3],16)
        arg=sys.argv[4] if len(sys.argv)>4 else 'gx'
        errs=grade(stream,kend,arg)
        if errs: print('RED'); [print('  -',e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    else: raise SystemExit('usage: module|hex|src|stream|kernelelf|kend|fourpage|offsets|grade')
