#!/usr/bin/env python3
# mmj_ref.py -- mmj (link 25 / native-codegen Link 41) STEP-0 oracle + BYTE-EXACT emitter target.
#
# mmj = THE UNION: the first compiled ring-3 module that BOTH computes with control-flow/recursion (ouroboros)
# AND emits its OWN multi-byte output (holler's SYS_WRITE, op 48). The gap it closes: ouroboros can recurse/branch
# but its entire output is the ONE implicit SYS_EXIT byte (no op48); holler can SYS_WRITE multi-byte but BANS
# branches+calls, so its output length is COMPILE-TIME FIXED. Neither can emit output whose LENGTH = f(runtime
# input). mmj's forcing program does exactly that:
#
#     func down(k):
#         if k == 0:
#             return 0
#         end
#         return sys_write(k) + down(k - 1)   # writes le32(k), then recurses -> N words out
#     end
#     func main():
#         return down(sys_read())
#     end
#
# down(N) emits N words (N, N-1, ..., 1) = 4N output bytes -> OUTPUT LENGTH = f(input). The exit status is
# CONSTANT 0 (sys_write returns 0, so each level returns 0+0=0); ALL information is carried by the output LENGTH.
# This is UNFAKEABLE: holler's executed sys_write count == its textual statement count (branches/calls banned),
# ouroboros has no op48. Variable output length is the strict intersection-complement of both modes.
#
# TYPE-I: the FROZEN holler kernel (holler_ref.build_elf, ac7df9f) runs the module at ring 3 via the int 0x30 ABI
# unchanged -- it already services SYS_READ(0)/SYS_WRITE(2)/SYS_EXIT(1) and relays do_write bytes between D4..D5
# witness frames. mmj only changes the COMPILER (a new emit mode: a branchy/recursive module that ALSO carries
# op48). This file hand-assembles the EXACT bytes that emit mode must produce, via ouroboros's generic two-pass
# multi-function layout with a SYS_WRITE op added. STEP-0 proves the recursive-write module runs on QEMU+Bochs+KVM
# BEFORE the emitter exists; the gate then proves the emitter byte-identical to target_module(kind) on substrates.
#
# The NEW silicon surface (vs holler): sys_write is reached from INSIDE a recursion frame, so the operand-stack
# TOS (= the do_write ptr the kernel access_ok's) DESCENDS through the User page at runtime-varying depth -- the
# confused-deputy bounds-check is exercised against runtime stack addresses for the first time. STEP-0 pins the
# descending-esp signature per write frame (the recursion proof) + the per-frame relayed bytes + count==N.
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holler_ref as H   # frozen holler kernel (build_elf), parse(), _all_wframes(), recompute_alloc(), UCODE3

SYS_READ = 0; SYS_EXIT = 1; SYS_WRITE = 2
UCODE3 = H.UCODE3
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def s32(v):  return struct.pack('<i', v)

# ---- nc32 op byte-emitters (mirror of nc_ouro_lower_body + the holler op48 arm) ----
def OP_PUSH(imm):   return bytes([0x68]) + le32(imm)
def OP_LOADL(slot): return bytes([0xFF, 0x75, (256 - 4*(slot+1)) & 0xFF])
def OP_STOREL(slot):return bytes([0x8F, 0x45, (256 - 4*(slot+1)) & 0xFF])
OP_ADD   = bytes([0x59,0x58,0x01,0xC8,0x50])
OP_SUB   = bytes([0x59,0x58,0x29,0xC8,0x50])
OP_MUL   = bytes([0x59,0x58,0x0F,0xAF,0xC1,0x50])
OP_EQ    = bytes([0x59,0x58,0x39,0xC8,0x0F,0x94,0xC0,0x0F,0xB6,0xC0,0x50])
OP_SYSREAD = bytes([0xB8])+le32(SYS_READ)+bytes([0xCD,0x30,0x50])
# op48 SYS_WRITE (18 bytes), IDENTICAL to holler_ref._op48_syswrite():
#   lea ecx,[esp]; mov edx,4; mov eax,2; int 0x30; mov [esp],eax   (net stack 0: pop arg, push result(0))
OP_SYSWRITE = bytes([0x8D,0x0C,0x24, 0xBA,0x04,0x00,0x00,0x00, 0xB8,0x02,0x00,0x00,0x00, 0xCD,0x30, 0x89,0x04,0x24])
SW_INT_END  = 3+5+5+2   # offset within OP_SYSWRITE just AFTER its int 0x30 (=15) -> the witness-frame return eip
assert len(OP_SYSWRITE) == 18

SZ = {'push':5,'loadl':3,'storel':3,'add':5,'sub':5,'mul':6,'eq':11,'sysread':8,'syswrite':18,
      'br':5,'brf':9,'ret_last':1,'ret_mid':6}

def instr_size(kind, nargs, is_last):
    if kind == 'ret':  return SZ['ret_last'] if is_last else SZ['ret_mid']
    if kind == 'call':
        cl = 0 if nargs == 0 else (3 if 4*nargs <= 127 else 6)
        return 5 + cl + 1
    return SZ[kind]

def frame_size(fn):  # max(nparams, max slot touched)
    nparams = fn[1]; s = nparams
    for (k, a) in fn[2]:
        if k in ('loadl','storel'):
            if a + 1 > s: s = a + 1
    return s

def prologue_len(is_main, nparams, S):
    if S == 0: return 0
    if is_main: return 5
    return 6 + nparams*6
def epilogue_len(is_main, S):
    if is_main: return 9
    return 4 if S > 0 else 1

def callarg(instr): return instr[1][1] if instr[0] == 'call' else 0

def layout(funcs):
    bases = {}; instr_offs = []; epi_off = []; cur = 0
    for fi, fn in enumerate(funcs):
        name = fn[0]; is_main = (fi == 0); S = frame_size(fn)
        bases[name] = cur
        cur += prologue_len(is_main, fn[1], S)
        offs = []; n = len(fn[2])
        for i, instr in enumerate(fn[2]):
            offs.append(cur)
            cur += instr_size(instr[0], callarg(instr), i == n-1)
        instr_offs.append(offs); epi_off.append(cur)
        cur += epilogue_len(is_main, S)
    return bases, instr_offs, epi_off, cur

def emit(funcs):
    bases, instr_offs, epi_off, total = layout(funcs)
    out = b''
    for fi, fn in enumerate(funcs):
        is_main = (fi == 0); S = frame_size(fn); nparams = fn[1]
        if S > 0:
            if is_main:
                out += bytes([0x89,0xE5, 0x83,0xEC, (4*S)&0xFF])
            else:
                out += bytes([0x55, 0x89,0xE5, 0x83,0xEC, (4*S)&0xFF])
                for i in range(nparams):
                    src = 8 + 4*(nparams-1-i)
                    out += bytes([0x8B,0x45, src & 0xFF, 0x89,0x45, (256-4*(i+1)) & 0xFF])
        offs = instr_offs[fi]; n = len(fn[2]); epi = epi_off[fi]
        for i, instr in enumerate(fn[2]):
            kind = instr[0]; is_last = (i == n-1)
            end = offs[i] + instr_size(kind, callarg(instr), is_last)
            if kind == 'push':   out += OP_PUSH(instr[1])
            elif kind == 'loadl':  out += OP_LOADL(instr[1])
            elif kind == 'storel': out += OP_STOREL(instr[1])
            elif kind == 'add':    out += OP_ADD
            elif kind == 'sub':    out += OP_SUB
            elif kind == 'mul':    out += OP_MUL
            elif kind == 'eq':     out += OP_EQ
            elif kind == 'sysread':out += OP_SYSREAD
            elif kind == 'syswrite':out += OP_SYSWRITE
            elif kind == 'br':
                tgt = epi if instr[1] == n else offs[instr[1]]
                out += bytes([0xE9]) + s32(tgt - end)
            elif kind == 'brf':
                tgt = epi if instr[1] == n else offs[instr[1]]
                out += bytes([0x58,0x85,0xC0,0x0F,0x84]) + s32(tgt - end)
            elif kind == 'call':
                callee, nargs = instr[1]
                rel = bases[callee] - (offs[i] + 5)
                out += bytes([0xE8]) + s32(rel)
                if nargs > 0:
                    if 4*nargs <= 127: out += bytes([0x83,0xC4, (4*nargs)&0xFF])
                    else:              out += bytes([0x81,0xC4]) + le32(4*nargs)
                out += bytes([0x50])
            elif kind == 'ret':
                if is_last: out += bytes([0x58])
                else:       out += bytes([0x58,0xE9]) + s32(epi - end)
            else: raise SystemExit('op? '+kind)
        if is_main:
            out += bytes([0x88,0xC3, 0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
        elif S > 0:
            out += bytes([0x89,0xEC, 0x5D, 0xC3])
        else:
            out += bytes([0xC3])
    assert len(out) == total, (len(out), total)
    return out

# ---- the mmj forcing program: down(k) emits k words via recursion+SYS_WRITE -> output LENGTH = f(input) ----
# main: sysread; storel0; loadl0; call down,1; ret    (down's result, 0, becomes the SYS_EXIT byte)
# down(k): if k==0 return 0;  return sys_write(k) + down(k-1)
#   idx: 0 loadl0  1 push0  2 eq  3 brf->6  4 push0  5 ret      (base case)
#        6 loadl0  7 syswrite  8 loadl0  9 push1  10 sub  11 call down,1  12 add  13 ret   (recursive)
DOWN_FUNCS = [
    ('main', 0, [('sysread',0),('storel',0),('loadl',0),('call',('down',1)),('ret',0)]),
    ('down', 1, [('loadl',0),('push',0),('eq',0),('brf',6),('push',0),('ret',0),
                 ('loadl',0),('syswrite',0),('loadl',0),('push',1),('sub',0),('call',('down',1)),('add',0),('ret',0)]),
]
PROGRAMS = {
  'down': dict(
    # main uses `let x = sys_read()` so it compiles to the [sysread,storel0,loadl0,call,ret] IR below (a main
    # frame + store/load) -- byte-identical to target_module('down'). (A bare `return down(sys_read())` lowers
    # WITHOUT the frame/store-load -> a different, also-valid 131 B module; the `let` form is the proven STEP-0 target.)
    src=("func down(k):\n    if k == 0:\n        return 0\n    end\n"
         "    return sys_write(k) + down(k - 1)\nend\n"
         "func main():\n    let x = sys_read()\n    return down(x)\nend"),
    funcs=DOWN_FUNCS, fx=5, fy=8,
    # host output: N words le32(N), le32(N-1), ..., le32(1); host answer (exit status) = 0
    writes=lambda b: [le32(b - i) for i in range(b)], answer=lambda b: 0),
}

# ---- mutant modules (negative controls): each RUNS on the frozen kernel but is BROKEN so the grade must go RED,
#      proving count==fed (variable length), content==le32(N-i), and the descending-esp pin are load-bearing. ----
def mutant_module(mut):
    if mut == 'fixedcount':
        # STRAIGHT-LINE (holler-style, NO recursion): always writes a CONSTANT 2 words regardless of input.
        # This is exactly the "fixed-count selector" fake the synthesis warned about -> grade RED (count != fed).
        # main(): b=sys_read(); sys_write(7); sys_write(9); return 0  -- nlocals=1.
        frame = bytes([0x89,0xE5, 0x83,0xEC,0x04])           # mov ebp,esp; sub esp,4
        op47  = OP_SYSREAD + bytes([0x8F,0x45,0xFC])         # sys_read; pop [ebp-4]
        w7    = OP_PUSH(7) + OP_SYSWRITE + bytes([0x58])     # push 7; sys_write; pop (discard result)
        w9    = OP_PUSH(9) + OP_SYSWRITE + bytes([0x58])     # push 9; sys_write; pop
        ret0  = OP_PUSH(0) + bytes([0x58])                   # push 0; pop eax (answer 0)
        exitsc= bytes([0x88,0xC3, 0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
        return frame+op47+w7+w9+ret0+exitsc
    if mut == 'forge':
        # THE HEADLINE forge (completeness critic, 2026-06-14): a NON-RECURSIVE backward-`jmp` (EB E2) loop --
        # 71 NOPs (pad so int 0x30 lands at down's sys_write eip 0x6b) + sys_read->ebx + a loop doing
        # `sub esp,20`(stride) / `mov [esp+16],ebx` / lea ecx / SYS_WRITE / `dec ebx` / jmp-back. It manufactures
        # EVERY runtime invariant (count==N, content le32(N..1), descending esp stride 20, single eip) and grades
        # GREEN on real silicon -- proving the runtime trace CANNOT witness recursion. But it is byte-DIFFERENT
        # from target_module('down') (no per-function frame, a jmp not a call) and carries ZERO backward E8 calls,
        # so the EMITTER-LAYER gate (byte-pin cmp + assert_backward_call) REJECTS it. A backward `jmp` is
        # UNEMITTABLE from Herbert (no while; ouro branches are forward-only), so the binding is airtight.
        return bytes.fromhex('9090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090b800000000cd3089c385db741a83ec14895c24108d4c2410ba04000000b802000000cd304bebe2b300b801000000cd3046524741')
    if mut == 'content':
        # the REAL recursion (count == fed) but writes a CONSTANT le32(0) each level instead of le32(k): swap the
        # operand pushed before sys_write (loadl0 -> push 0). Count passes, CONTENT pin must catch it -> RED.
        funcs = [list(f) for f in DOWN_FUNCS]
        body  = list(funcs[1][2]); body[6] = ('push', 0)     # idx6 loadl0 -> push 0 (writes le32(0) not le32(k))
        funcs[1] = ('down', 1, body)
        return emit(funcs)
    raise SystemExit('mutant? '+mut)

def target_module(kind='down'): return emit(PROGRAMS[kind]['funcs'])
def host_writes(kind, b):       return PROGRAMS[kind]['writes'](b & 0xFF)
def host_answer(kind, b):       return PROGRAMS[kind]['answer'](b & 0xFF) & 0xFF
def herb_src(kind='down'):      return PROGRAMS[kind]['src']
def fx(kind='down'):            return PROGRAMS[kind]['fx']
def fy(kind='down'):            return PROGRAMS[kind]['fy']

def sw_site_offset(kind='down'):
    """module offset of the byte just AFTER the int 0x30 of down's single sys_write (the write-frame return eip)."""
    funcs = PROGRAMS[kind]['funcs']
    bases, instr_offs, epi_off, total = layout(funcs)
    # find down (func index 1) and its 'syswrite' instr
    for fi, fn in enumerate(funcs):
        for i, instr in enumerate(fn[2]):
            if instr[0] == 'syswrite':
                return instr_offs[fi][i] + SW_INT_END
    raise SystemExit('no syswrite in program')

def down_frame_stride(kind='down'):
    """Per-recursion-level stack stride at the sys_write point (the write-to-write esp drop). Each level adds:
       E8-call return-address(4) + saved ebp(4) + sub esp,4*S(=4) + the NET operands left on the stack from the
       sys_write site to the recursive E8 (down pushes k then k,1->sub->arg = +4 net). For down (S=1): 4+4+4+8=20.
       Verified against silicon (observed 0x14=20). This is the EXPECTED value; the grader ALSO derives the stride
       from the observed frames and requires it CONSTANT -- so a wrong constant here cannot mask a real divergence."""
    S = frame_size(PROGRAMS[kind]['funcs'][1])
    return 4 + 4 + 4*S + 8

# ===================== STEP-0 / gate grader =====================
def grade(stream, kend_elf, fed, kind='down'):
    """RUNTIME grade: the GENUINE down module emits a runtime-data-dependent NUMBER of output words.
       Pins: read delivered==fed; EXACTLY fed write-relay frames (D4..D5) [variable-length]; frame i relays
       le32(fed-i) [content]; descending in-page esp, constant stride [layout]; same eip [single write site];
       exit answer==0.
       IMPORTANT (completeness-critic finding, 2026-06-14): this runtime grade does NOT, by itself, prove
       RECURSION/THE UNION -- recursion is NOT observable in a syscall trace. A non-recursive backward-`jmp`
       loop that does `sub esp,20` per iteration FORGES every invariant here (count, content, descending esp,
       stride, eip) and grades GREEN (proven: /tmp/mmj-forge/forgeA2.bin, 123 B, 0x E8). The UNION claim is
       bound at the EMITTER LAYER by the build gate: (a) byte-exact cmp emitter-output == target_module('down')
       [the genuine 142 B target carries a backward E8 self-call a jmp-loop cannot]; (b) assert_backward_call
       (white-box, by value). A backward `jmp` is UNEMITTABLE from Herbert (no while; forward-only ouro
       branches), so the emitter-layer binding transitively forbids the forge. This grade confirms the REAL
       module RUNS correctly; the gate's byte-cmp + assert_backward_call prove it is the union."""
    errs = []; fed &= 0xFF
    r = H.parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or kernel RED)']
    if r.get('k1') is not None and r['k1'] != kend_elf:
        errs.append(f'dumped k1=0x{r["k1"]:x} != frozen kend=0x{kend_elf:x}')
    ms, ah, al = r.get('ms'), r.get('ah'), r.get('al')
    rec = H.recompute_alloc(r, kend_elf)
    if rec:
        elo, ehi, _ = rec
        if al != elo: errs.append(f'alloc_lo 0x{al:x} != recomputed 0x{elo:x}')
        if ah != ehi: errs.append(f'alloc_hi 0x{ah:x} != recomputed 0x{ehi:x}')
    if 'rd_byte' not in r: errs.append('no read-witness frame (SYS_READ not serviced at CPL3)')
    elif r['rd_byte'] != fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x}')
    # Filter to WELL-FORMED write frames (cs==UCODE3/RPL3, closed by D5, ln==4): a relayed le32 body can itself
    # contain an incidental 0xD4/0xD6 byte (e.g. a written value >= 0xD4), which _all_wframes would mis-open as a
    # spurious frame -- the critic's nice-to-have. The chosen probes (N<=20) never trigger it, but filter for
    # robustness. A genuinely-malformed frame (mutation) drops from the count -> count!=fed -> RED (still caught).
    wfs  = [w for w in H._all_wframes(stream, b'\xD4', b'\xD5', True)
            if w['closed'] and w['ln'] == 4 and w['cs'] == UCODE3 and (w['cs'] & 3) == 3]
    want = host_writes(kind, fed)
    if len(wfs) != fed:
        errs.append(f'{len(wfs)} write-relay frame(s) (D4..D5) != fed={fed} '
                    f'(OUTPUT LENGTH must equal the runtime input -- the variable-length make-or-break)')
    else:
        site = ms + sw_site_offset(kind) if ms is not None else None
        # the descending-esp RECURSION SIGNATURE: derive the stride from the FIRST gap, require it strictly
        # positive, CONSTANT across every consecutive pair, and == the analytical expectation. A straight-line
        # (holler) module's writes share ONE static esp (stride 0); only genuine recursion descends uniformly.
        obs_stride = (wfs[0]['esp'] - wfs[1]['esp']) if len(wfs) >= 2 else None
        exp_stride = down_frame_stride(kind)
        if obs_stride is not None:
            if obs_stride <= 0:
                errs.append(f'esp not descending (stride {obs_stride} <= 0 -- not recursion, a flat/looped fake)')
            elif obs_stride != exp_stride:
                errs.append(f'observed esp stride {obs_stride} != analytical {exp_stride} (frame-size model wrong)')
        prev_esp = None
        for idx, wf in enumerate(wfs):
            if not wf['closed']: errs.append(f'write frame {idx} not closed by D5')
            if wf['ln'] != 4: errs.append(f'write frame {idx} len {wf["ln"]} != 4 (le32 word)')
            if wf['cs'] != UCODE3 or (wf['cs'] & 3) != 3: errs.append(f'write frame {idx} cs 0x{wf["cs"]:x} != UCODE3/RPL3')
            if site is not None and wf['eip'] != site:
                errs.append(f'write frame {idx} eip 0x{wf["eip"]:x} != down sys_write site 0x{site:x} '
                            f'(all writes share ONE code site -- the recursion reuses the same instruction)')
            if al is not None and ah is not None and not (al <= wf['esp'] < ah):
                errs.append(f'write frame {idx} useresp 0x{wf["esp"]:x} not in [alloc_lo 0x{al:x}, alloc_hi 0x{ah:x}) (out of User page)')
            if prev_esp is not None and obs_stride is not None and wf['esp'] != prev_esp - obs_stride:
                errs.append(f'write frame {idx} useresp 0x{wf["esp"]:x} != prev-{obs_stride} 0x{prev_esp - obs_stride:x} '
                            f'(descending-esp recursion signature not CONSTANT)')
            prev_esp = wf['esp']
            if wf['body'] != want[idx]:
                errs.append(f'write frame {idx} relayed {wf["body"].hex()} != {want[idx].hex()} '
                            f'(NOT the module-authored le32(N-i) / wrong lowering)')
    if r.get('answer') != host_answer(kind, fed):
        errs.append(f'answer {r.get("answer")} != {host_answer(kind, fed)} (down returns 0 -- exit status is constant)')
    return errs

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'module':     open(sys.argv[3], 'wb').write(target_module(sys.argv[2]))
    elif cmd == 'mutant':   open(sys.argv[3], 'wb').write(mutant_module(sys.argv[2]))
    elif cmd == 'hex':      sys.stdout.write(target_module(sys.argv[2]).hex())
    elif cmd == 'src':      sys.stdout.write(herb_src(sys.argv[2]))
    elif cmd == 'fx':       print(fx(sys.argv[2]))
    elif cmd == 'fy':       print(fy(sys.argv[2]))
    elif cmd == 'kernelelf': img, kend, _ = H.build_elf(); open(sys.argv[2], 'wb').write(img); print('%x' % kend)
    elif cmd == 'kend':     _, kend, _ = H.build_elf(); print('%x' % kend)
    elif cmd == 'offsets':
        k = sys.argv[2]
        print('sw_site', sw_site_offset(k), 'stride', down_frame_stride(k),
              'len', len(target_module(k)), 'frameS_down', frame_size(PROGRAMS[k]['funcs'][1]))
    elif cmd == 'grade':
        stream = open(sys.argv[2], 'rb').read(); kend = int(sys.argv[3], 16)
        fed = int(sys.argv[4], 16); kind = sys.argv[5] if len(sys.argv) > 5 else 'down'
        errs = grade(stream, kend, fed, kind)
        if errs: print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    else: raise SystemExit('usage: module|hex|src|fx|fy|kernelelf|kend|offsets|grade')
