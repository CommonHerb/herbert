#!/usr/bin/env python3
# ouroboros_ref.py -- ouroboros (link 23 / native-codegen Link 39) STEP-0 oracle + BYTE-EXACT emitter target.
#
# ouroboros makes the compiled ring-3 module a real ALGORITHM: user CALLS + recursion (+ ungated branches) in
# the position-independent 32-bit module path. The FROZEN geeking kernel (host) runs the module at ring 3 via
# the int 0x30 ABI (audits/link22-coalgate/00-module-abi.md); ouroboros only changes the COMPILER (a new emit
# mode multiboot32-ouroboros). This file hand-assembles the EXACT bytes that emit mode must produce, for a set
# of recursive/branching/multi-function Herbert programs, via a generic TWO-PASS multi-function layout (the
# executable spec). STEP-0 proved a recursive target runs on QEMU+Bochs+KVM BEFORE the emitter existed; the
# gate then proves the emitter byte-identical to target_module(kind) and answer==host_T on the substrates.
#
# Module shape: [main][helper...], entry byte 0 = main. main keeps coalgate's frame (mov ebp,esp; sub esp,4S;
# ends via the implicit SYS_EXIT glue). A callee uses push ebp; mov ebp,esp; sub esp,4S; <copy params to neg
# slots> ... mov esp,ebp; pop ebp; ret. A call (op 20) = E8 rel32 (SIGNED -- the recursive self-call is a
# BACKWARD rel32) + add esp,4*nargs (caller cleanup) + push eax (result).
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import geeking_ref as G
import math

SYS_READ = 0; SYS_EXIT = 1
UCODE3 = 0x1B
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def s32(v):  return struct.pack('<i', v)

# ---- nc32 op byte-emitters (mirror of nc_ouro_lower_body) ----
def OP_PUSH(imm):   return bytes([0x68]) + le32(imm)
def OP_LOADL(slot): return bytes([0xFF, 0x75, (256 - 4*(slot+1)) & 0xFF])
def OP_STOREL(slot):return bytes([0x8F, 0x45, (256 - 4*(slot+1)) & 0xFF])
OP_ADD   = bytes([0x59,0x58,0x01,0xC8,0x50])
OP_SUB   = bytes([0x59,0x58,0x29,0xC8,0x50])
OP_MUL   = bytes([0x59,0x58,0x0F,0xAF,0xC1,0x50])
OP_EQ    = bytes([0x59,0x58,0x39,0xC8,0x0F,0x94,0xC0,0x0F,0xB6,0xC0,0x50])
OP_SYSREAD = bytes([0xB8])+le32(SYS_READ)+bytes([0xCD,0x30,0x50])
SZ = {'push':5,'loadl':3,'storel':3,'add':5,'sub':5,'mul':6,'eq':11,'sysread':8,'br':5,'brf':9,'ret_last':1,'ret_mid':6}

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
        # prologue
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
        # epilogue
        if is_main:
            out += bytes([0x88,0xC3, 0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
        elif S > 0:
            out += bytes([0x89,0xEC, 0x5D, 0xC3])
        else:
            out += bytes([0xC3])
    assert len(out) == total, (len(out), total)
    return out

# ---- the gate program set. funcs = [main, helpers...]; main is index 0. body instrs: (kind, arg). ----
def fact_mod(b):
    r = 1
    for k in range(2, b+1): r = (r*k) & 0xFF
    return r & 0xFF

PROGRAMS = {
  # tri(n)=n+tri(n-1): triangular number of the input. The canonical recursion probe (backward self-call).
  'tri': dict(
    src="func tri(n):\n    if n == 0:\n        return 0\n    end\n    return n + tri(n - 1)\nend\nfunc main():\n    let x = sys_read()\n    return tri(x)\nend",
    funcs=[('main',0,[('sysread',0),('storel',0),('loadl',0),('call',('tri',1)),('ret',0)]),
           ('tri',1,[('loadl',0),('push',0),('eq',0),('brf',6),('push',0),('ret',0),
                     ('loadl',0),('loadl',0),('push',1),('sub',0),('call',('tri',1)),('add',0),('ret',0)])],
    fx=20, fy=42, hostT=lambda b: (b*(b+1)//2) & 0xFF),
  # d(n)=2+d(n-1): 2*n. DIFFERENT recurrence than tri -> different bytes AND different answer (anti-fixture).
  'dbl': dict(
    src="func d(n):\n    if n == 0:\n        return 0\n    end\n    return 2 + d(n - 1)\nend\nfunc main():\n    let x = sys_read()\n    return d(x)\nend",
    funcs=[('main',0,[('sysread',0),('storel',0),('loadl',0),('call',('d',1)),('ret',0)]),
           ('d',1,[('loadl',0),('push',0),('eq',0),('brf',6),('push',0),('ret',0),
                   ('push',2),('loadl',0),('push',1),('sub',0),('call',('d',1)),('add',0),('ret',0)])],
    fx=20, fy=50, hostT=lambda b: (2*b) & 0xFF),
  # f(n)=n*f(n-1), base 1: factorial mod 256. Exercises mul (op 42) under recursion.
  'fact': dict(
    src="func f(n):\n    if n == 0:\n        return 1\n    end\n    return n * f(n - 1)\nend\nfunc main():\n    let x = sys_read()\n    return f(x)\nend",
    funcs=[('main',0,[('sysread',0),('storel',0),('loadl',0),('call',('f',1)),('ret',0)]),
           ('f',1,[('loadl',0),('push',0),('eq',0),('brf',6),('push',1),('ret',0),
                   ('loadl',0),('loadl',0),('push',1),('sub',0),('call',('f',1)),('mul',0),('ret',0)])],
    fx=5, fy=6, hostT=lambda b: fact_mod(b)),
  # ungated BRANCH in a single function (coalgate rejects this via ERR 585; ouroboros admits it). No call.
  'branch': dict(
    src="func main():\n    let x = sys_read()\n    if x == 5:\n        return 100\n    end\n    return x\nend",
    funcs=[('main',0,[('sysread',0),('storel',0),('loadl',0),('push',5),('eq',0),('brf',8),('push',100),('ret',0),('loadl',0),('ret',0)])],
    fx=5, fy=7, hostT=lambda b: 100 if b == 5 else b),
  # non-recursive call CHAIN main->g->h: 3*n+1. Forward calls + composition across three functions.
  'chain': dict(
    src="func h(n):\n    return n * 3\nend\nfunc g(n):\n    return h(n) + 1\nend\nfunc main():\n    let x = sys_read()\n    return g(x)\nend",
    funcs=[('main',0,[('sysread',0),('storel',0),('loadl',0),('call',('g',1)),('ret',0)]),
           ('g',1,[('loadl',0),('call',('h',1)),('push',1),('add',0),('ret',0)]),
           ('h',1,[('loadl',0),('push',3),('mul',0),('ret',0)])],
    fx=20, fy=10, hostT=lambda b: (3*b+1) & 0xFF),
  # MULTI-PARAM callee sub3(a,b,c)=a-b-c: exercises the param-copy path (3 args at [ebp+8/12/16] copied to
  # neg slots) and the LEFT-to-RIGHT arg order, which a single-param gate set never tested (the disp8
  # param-copy bug the completeness critic found lived exactly here). sub3(x,5,2) = x-7.
  'threearg': dict(
    src="func sub3(a, b, c):\n    return a - b - c\nend\nfunc main():\n    let x = sys_read()\n    return sub3(x, 5, 2)\nend",
    funcs=[('main',0,[('sysread',0),('storel',0),('loadl',0),('push',5),('push',2),('call',('sub3',3)),('ret',0)]),
           ('sub3',3,[('loadl',0),('loadl',1),('sub',0),('loadl',2),('sub',0),('ret',0)])],
    fx=20, fy=100, hostT=lambda b: (b - 7) & 0xFF),
}

# An overflow program (NOT byte-pinned/host_T-graded): a 6-slot recursive frame whose stack genuinely
# overflows the one 4 KiB User stack page at a deep input -> the CPU's own #PF, caught by geeking's
# fault->continue (answer = a fault status, e.g. 0x50 'P'). Proves the one-page recursion bound is a SAFE
# capacity bound (clean fault), NOT a silent-corruption hole. The kernel's fault statuses: G=0x47 P=0x50
# F=0x46 K=0x4B (kill). A normal compiled result is none of these by construction at this depth.
OVERFLOW_SRC = ("func g(n):\n    if n == 0:\n        return 0\n    end\n"
                "    let a = n\n    let b = n\n    let c = n\n    let d = n\n    let e = n\n"
                "    return a + b + c + d + e + g(n - 1)\nend\n"
                "func main():\n    return g(sys_read())\nend")
FAULT_STATUSES = {0x46, 0x47, 0x4B, 0x50}

def target_module(kind): return emit(PROGRAMS[kind]['funcs'])
def host_T(kind, b):     return PROGRAMS[kind]['hostT'](b) & 0xFF
def herb_src(kind):      return PROGRAMS[kind]['src']
def fx(kind):            return PROGRAMS[kind]['fx']
def fy(kind):            return PROGRAMS[kind]['fy']

def main_frameS(kind):   return frame_size(PROGRAMS[kind]['funcs'][0])
def read_exit(kind):
    """SYS_READ-return and SYS_EXIT-return module offsets, for the witness-frame grade (both in main)."""
    funcs = PROGRAMS[kind]['funcs']; main = funcs[0]
    S = frame_size(main); pl = prologue_len(True, 0, S)
    bases, instr_offs, epi_off, total = layout(funcs)
    # sys_read offset in main
    sr = None
    for i, instr in enumerate(main[2]):
        if instr[0] == 'sysread': sr = instr_offs[0][i]
    read_ret = sr + 7                       # past mov eax,0 (5) + int 0x30 (2) -> push eax
    exit_ret = epi_off[0] + 9               # past the SYS_EXIT int 0x30 (88 C3 + B8 imm32 + CD 30)
    return read_ret, exit_ret

# ---- mutant modules (negative controls). Built off the 'tri' shape; each is a runnable blob but BROKEN so
#      the gate must grade it RED, proving answer==host_T + X!=Y + the recursion checks bite. ----
def mutant_module(mut):
    funcs = [list(f) for f in PROGRAMS['tri']['funcs']]
    if mut == 'noxform':       # main echoes the byte, never calls tri -> answer==fed != tri(fed)
        funcs[0] = ('main',0,[('sysread',0),('ret',0)])
        return emit([funcs[0]])
    if mut == 'baseflip':      # tri base case returns 1 instead of 0 -> answer == tri(n)+1, wrong
        t = list(PROGRAMS['tri']['funcs'][1][2]); t[4] = ('push',1)
        return emit([PROGRAMS['tri']['funcs'][0], ('tri',1,t)])
    if mut == 'constbake':     # read the byte, pop it, then bake 0x5A into al AFTER the pop -> X==Y collapses
        return OP_SYSREAD + bytes([0x58]) + bytes([0xB0,0x5A]) + bytes([0x88,0xC3,0xB8])+le32(SYS_EXIT)+bytes([0xCD,0x30])
    if mut == 'wrongrel':      # corrupt the recursive call rel32 (skip the +1 push arg path) -> wrong/fault
        m = bytearray(target_module('tri'))
        # find the backward call E8 with negative rel (FF in the high byte) inside tri and bump it +1
        for i in range(len(m)-5):
            if m[i] == 0xE8 and m[i+4] == 0xFF and m[i+3] == 0xFF:
                m[i+1] = (m[i+1] + 4) & 0xFF   # shift the call target by 4 bytes -> mid-instruction
                break
        return bytes(m)
    raise SystemExit('mutant? '+mut)

# ===================== STEP-0 / gate grader (modeled on coalgate_ref.grade) =====================
def grade(stream, kend_elf, fed, kind):
    errs = []
    r = G.parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or kernel RED)']
    if r['k1'] != kend_elf: errs.append(f'dumped k1=0x{r["k1"]:x} != frozen kend=0x{kend_elf:x}')
    ms, ah = r.get('ms'), r.get('ah')
    rr, xr = read_exit(kind)
    fb = ah - 4 * main_frameS(kind)
    if 'rd_byte' not in r:
        errs.append('no read-witness frame (kernel did not service SYS_READ at CPL3)')
    else:
        if r['rd_cs'] != UCODE3 or (r['rd_cs'] & 3) != 3: errs.append(f'read frame cs 0x{r["rd_cs"]:x} != ucode|3')
        if r['rd_esp'] != fb: errs.append(f'read frame useresp 0x{r["rd_esp"]:x} != frame_base 0x{fb:x}')
        if r['rd_eip'] != ms + rr: errs.append(f'read frame eip 0x{r["rd_eip"]:x} != mod_start+{rr}')
        if r['rd_byte'] != fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x}')
    if 'ex_status' not in r:
        errs.append('no exit-witness frame (module did not SYS_EXIT at CPL3)')
    else:
        if r['ex_cs'] != UCODE3 or (r['ex_cs'] & 3) != 3: errs.append(f'exit frame cs 0x{r["ex_cs"]:x} != ucode|3')
        if r['ex_esp'] != fb: errs.append(f'exit frame useresp 0x{r["ex_esp"]:x} != frame_base 0x{fb:x}')
        if r['ex_eip'] != ms + xr: errs.append(f'exit frame eip 0x{r["ex_eip"]:x} != mod_start+{xr}')
    want = host_T(kind, fed)
    if r.get('answer') != want:
        errs.append(f'answer 0x{r.get("answer")} != T_{kind}(0x{fed:x})=0x{want:x}')
    if 'kl_eip' in r: errs.append('benign module was KILLED by the watchdog (kill-witness present)')
    if r.get('answer') == 0x4B and want != 0x4B: errs.append("answer==KILL_STATUS 0x4B (module killed)")
    return errs

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'module':   open(sys.argv[3], 'wb').write(target_module(sys.argv[2]))
    elif cmd == 'mutant': open(sys.argv[3], 'wb').write(mutant_module(sys.argv[2]))
    elif cmd == 'hex':    sys.stdout.write(target_module(sys.argv[2]).hex())
    elif cmd == 'src':    sys.stdout.write(herb_src(sys.argv[2]))
    elif cmd == 'hostT':  print(host_T(sys.argv[2], int(sys.argv[3], 0)))
    elif cmd == 'fx':     print(fx(sys.argv[2]))
    elif cmd == 'fy':     print(fy(sys.argv[2]))
    elif cmd == 'offsets':
        k = sys.argv[2]; rr, xr = read_exit(k)
        print('read_ret', rr, 'exit_ret', xr, 'len', len(target_module(k)), 'frameS', main_frameS(k))
    elif cmd == 'kernelelf':
        img, kend, _ = G.build_elf(); open(sys.argv[2],'wb').write(img); print('%x' % kend)
    elif cmd == 'overflowsrc': sys.stdout.write(OVERFLOW_SRC)
    elif cmd == 'isfault':     sys.exit(0 if int(sys.argv[2], 16) in FAULT_STATUSES else 1)
    elif cmd == 'kend':
        _, kend, _ = G.build_elf(); print('%x' % kend)
    elif cmd == 'grade':
        stream = open(sys.argv[2],'rb').read(); kend = int(sys.argv[3],16)
        fed = int(sys.argv[4],16); kind = sys.argv[5]
        errs = grade(stream, kend, fed, kind)
        if errs: print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    else: raise SystemExit('usage: module|mutant|hex|src|hostT|fx|fy|offsets|kernelelf|kend|grade')
