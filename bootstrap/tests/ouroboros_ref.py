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
import os, sys, struct, re
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
# overflows the one 4 KiB User stack page at a deep input -> a CPL3 #PF taken mid-overflow, caught by
# geeking's fault->continue (answer = 0x50 'P') -- the KERNEL outlives the descent (module-side the
# descent silently trashes the module's OWN code page first; see grade_overflow's honesty correction).
# The kernel's fault statuses: G=0x47 P=0x50 F=0x46 K=0x4B (kill). Graded by grade_overflow below --
# answer 0x50 + the full witness chain (incl. pf_esp < alloc_lo, the genuine overflowed-its-page
# witness) is the ONLY accepted outcome (the old any-fault-status accept-set was vacuous).
OVERFLOW_SRC = ("func g(n):\n    if n == 0:\n        return 0\n    end\n"
                "    let a = n\n    let b = n\n    let c = n\n    let d = n\n    let e = n\n"
                "    return a + b + c + d + e + g(n - 1)\nend\n"
                "func main():\n    return g(sys_read())\nend")

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

# ===================== overflow grader (tranche-1b grader repair, 2026-08-31) =====================
# The overflow leg's OLD accept-set (any fault status, incl. 0x4B watchdog-KILL) was vacuous: geeking's
# one-shot watchdog re-arms on iret-to-CPL3, so a stall-delayed recursion can be KILLED mid-descent
# BEFORE overflowing -> answer 0x4B -> the old leg passed without ever posing the overflow question
# (audits/discriminator-sweep-2026-07-17/CHARTER.md, Codex change 6 / Q3). This grader accepts ONLY a
# genuine CPL3 #PF taken MID-OVERFLOW, with the full witness chain; K (0x4B), G (0x47) and F (0x46)
# are each a DIFFERENT mechanism (kill / privileged-op / no-handler fault) and all RED, as is normal
# completion.
#
# HONESTY CORRECTION (found BY this grader's first witness capture, 2026-08-31): the charter's drafted
# "#PF at the downward stack-page boundary" witness is structurally UNOBTAINABLE on the frozen geeking
# kernel. The module's stack page sits DIRECTLY ABOVE its code page and both are User+writable (flat
# W+X, no guard page -- the taproot guard is a link-62 long64 invention), so the descent crosses the
# stack base WITHOUT faulting, silently overwrites the module's OWN code page from the top down,
# executes corrupted bytes, and dies on a wild access. The kernel-side claim holds (U/S catches the
# wild access; the kernel names 'P' and keeps grading); the old "clean fault, no silent corruption"
# claim was an OVERCLAIM at the module level and is retired in the gate's leg.
#
# TWO CORRECTIONS to the paragraph above, both found after it shipped (2026-09-01, A11 residual):
#   (a) "observed: cr2=fed-byte" GENERALIZED FROM ONE BOOT and is false. The wild address is the
#       module's own accumulator: cr2 == 5n. MEASURED, both boots on QEMU-TCG 2026-08-31 and
#       recorded in MEWTWO/SITREP.md + audits/discriminator-sweep-2026-07-17/TRANCHE-1B-REMAINDER.md:
#       fed=250 -> cr2=0xfa (250), which merely COINCIDES with the fed byte; fed=249 -> cr2=0xf5
#       (245), not 249. Nothing in this file or the gate pins cr2 to the fed byte -- the coincidence
#       was prose only. HONEST LIMIT on the formula: writing it as "n == fed - 200" fits those two
#       points, but 200 is a MEASURED descent depth (a function of frame size, module length and
#       where the loader put the module), not a pinned constant, and the gate only ever boots
#       OVF_BYTE=250. Treat 5n as the mechanism and 200 as an observation of this build
#       (blind Opus 5 finding 5, 2026-09-01) -- the cross-engine check compares cr2 between engines,
#       which needs no formula at all.
#   (b) "errcode 0x5 -- a user READ of a present Supervisor page" was a QEMU-TCG ARTIFACT read as
#       hardware truth. The smashed pair is 00 00 == `add [eax],al`, a read-modify-WRITE; TCG lowers
#       RMW to load-then-store so the LOAD half faults first (err 0x5), while KVM (real silicon)
#       reports the WRITE (err 0x7) on the SAME eip/esp/cr2. Both are correct for their engine, so
#       the page-fault error code is ENGINE-DEPENDENT here and the ONLY errcode fact this grader
#       pins is the U bit (bit 2), which both engines assert. See overflow_cross below: the leg
#       ran on ONE engine until 2026-09-01, which is the only reason the TCG reading nearly
#       entered canon as hardware truth.
#   (c) the retired sentence also credited "the OWN table witness" for the kernel-survived-the-fault
#       claim. The OWN table cannot carry it: geeking dumps that table BEFORE it launches the
#       module, so it witnesses only the PRE-fault kernel. What proves the kernel outlived the
#       wild access is the TERMINAL DE<0x50>AD frame (plus its isa-debug-exit rc) -- emitted after
#       the #PF was named -- together with the #PF witness frame itself. The k1 pin remains a pin
#       on WHICH kernel booted, not on its post-fault health.
# The honest, unforgeable overflow witness is pf_esp < alloc_lo: at fault time the user stack pointer
# had genuinely descended BELOW its one page -- no kill, completion, or in-page fault can produce it.
def _hx(v): return 'None' if v is None else '0x%x' % v
def grade_overflow(stream, kend_elf, fed):
    errs = []
    r = G.parse(stream)
    if not r: return ['no OWN table parsed (faulted before dump, or kernel RED)']
    if r['k1'] != kend_elf: errs.append(f'dumped k1=0x{r["k1"]:x} != frozen kend=0x{kend_elf:x}')
    al, ah, ms = r.get('al'), r.get('ah'), r.get('ms')
    if 'rd_byte' not in r:
        errs.append('no read-witness frame (SYS_READ never serviced at CPL3 -- the overflow descent was never posed)')
    else:
        if r['rd_cs'] != UCODE3 or (r['rd_cs'] & 3) != 3: errs.append(f'read frame cs 0x{r["rd_cs"]:x} != ucode|3')
        if r['rd_byte'] != fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x}')
    if al is None or ah is None or ah - al != 0x1000:
        errs.append(f'alloc window [{_hx(al)},{_hx(ah)}) is not the ONE 4 KiB stack page the capacity claim is about')
    if 'pf_err' not in r:
        errs.append('no #PF witness frame (the CPU never page-faulted -- the descent was not ended by the MMU)')
    else:
        if r['pf_cs'] != UCODE3 or (r['pf_cs'] & 3) != 3: errs.append(f'#PF frame cs 0x{r["pf_cs"]:x} != ucode|3 (not a CPL3 module fault)')
        if (r['pf_err'] & 4) != 4: errs.append(f'#PF errcode 0x{r["pf_err"]:x} U bit clear (not a user-mode access -- a kernel fault must never grade as module overflow)')
        if al is not None and not (r['pf_esp'] < al):
            errs.append(f'#PF useresp 0x{r["pf_esp"]:x} not BELOW the stack base {_hx(al)} -- the stack never overflowed its page (an in-page fault is not the overflow question)')
        if ms is not None and ah is not None and not ((ms & ~0xFFF) <= r['pf_eip'] < ah):
            errs.append(f'#PF eip 0x{r["pf_eip"]:x} outside the module\'s User pages [{_hx(ms & ~0xFFF if ms is not None else None)},{_hx(ah)})')
    if 'kl_eip' in r: errs.append('watchdog kill-witness frame present (the module was KILLED mid-descent, not overflowed -- the old vacuous-accept class)')
    if 'ex_status' in r: errs.append('exit-witness frame present (the module COMPLETED -- the overflow question was never posed)')
    if 'gp_err' in r: errs.append('#GP witness frame present (a privileged-op fault, not a stack overflow)')
    if 'gf_eip' in r: errs.append('generic-fault witness frame present (#DB/#DE/#UD, not a stack overflow)')
    # TERMINAL-ANSWER PIN (parent delta refutation panel, 2026-09-02; re-cut the same day after the
    # Codex refutation leg broke the first attempt). G.parse keeps only the FIRST DE..AD match, so a
    # stream carrying an early 0x50 and a later 0xD0 graded GREEN here while the sibling mut_witness
    # REFUSED the identical stream, and the leg's rc pin cannot separate them: host_qemu_exit masks
    # bit 7, so host_qemu_exit(0x50) == host_qemu_exit(0xD0) == 195.
    # WHAT THIS PINS: the tail must END with a byte-aligned DE<answer>AD frame, and the answer G.parse
    # bound must BE that terminal answer. Those are two of the three answer pins mut_witness carries
    # (mut_witness lines "stream does not END with the byte-aligned terminal DE<answer>AD frame" and
    # "parser answer ... != terminal answer ...").
    # WHAT IT DELIBERATELY DOES NOT PIN, and why: mut_witness's third pin is a raw overlap-aware
    # OCCURRENCE COUNT (`answer frame count != 1`). A first cut of this fix used exactly that and was
    # REFUTED by the Codex leg with a genuine single-answer stream: a #PF frame whose cr2 is
    # 0x00ad50de puts the bytes DE 50 AD inside the frame's own payload, which the count sees as a
    # second answer -- a deterministic FALSE RED on a CPU-authored value. mut_witness can afford the
    # count because it also partitions the tail into whole frames and cross-checks the two censuses;
    # this grader does not, so it takes the pins that are immune to a payload byte window instead.
    # Two IDENTICAL answer frames still pass -- they cannot forge a different accepted outcome, which
    # is the property being defended.
    if len(stream) < 3 or stream[-3] != 0xDE or stream[-1] != 0xAD:
        errs.append('stream does not END with the byte-aligned terminal DE<answer>AD frame -- no terminal answer to grade (truncated or corrupt capture)')
    elif r.get('answer') != stream[-2]:
        errs.append(f'parser answer {_hx(r.get("answer"))} != terminal answer 0x{stream[-2]:x} -- conflicting DE..AD frames: the grader would read a different boot than the one that ended')
    if r.get('answer') != 0x50:
        errs.append(f'answer {_hx(r.get("answer"))} != 0x50 (P) -- the ONLY accepted overflow outcome is the named CPL3 #PF (K/G/F and normal completion all excluded)')
    return errs

# ============== cross-ENGINE overflow agreement (A11 residual, closed 2026-09-01) ==============
# WHY THIS EXISTS. Until 2026-09-01 the overflow leg booted on exactly ONE engine (QEMU-TCG). That
# single-engine posture is the ONLY reason a TCG-specific reading of the fault ("errcode 0x5 -- a
# user READ of a present Supervisor page") reached a canon draft as if it were hardware truth: the
# faulting instruction is the smashed pair 00 00 == `add [eax],al`, a read-modify-WRITE, and TCG
# lowers RMW to load-then-store so the LOAD half faults first. KVM and Bochs both report the WRITE
# (0x7). A11.1 requires the substrates to be diffed AGAINST EACH OTHER, not just each against the
# grader; this comparator is that diff.
#
# WHAT IS COMPARED, AND WHAT IS NOT -- and why none of it is a naive byte-compare:
#  * The page-fault error code is compared on EVERY BIT EXCEPT W (bit 1). The documented, legitimate
#    TCG/KVM disagreement is the W bit and nothing else, so masking exactly that bit keeps the
#    tolerance the leg needs while still catching a DIFFERENT FAULT MECHANISM (P=0 non-present,
#    RSVD, instruction-fetch) masquerading as the same event. The first version of this comparator
#    exempted the whole errcode and accepted 0x5-vs-0x6, 0x5-vs-0x4 and 0x5-vs-0x15 as agreement --
#    found independently by BOTH verifiers (cross-model Codex finding 2; blind Opus 5 finding 4).
#    The full value is still REPORTED per engine so any divergence is visible, never inferred.
#    NAMED RESIDUAL, deliberately NOT fixed here: grade_overflow's PER-STREAM errcode pin is still
#    the U bit alone, so two engines that BOTH report the same wrong mechanism (e.g. both 0x6) still
#    pass -- so what is closed here is the engines-DISAGREE half, not the whole mechanism hole.
#    Tightening it (pin P=1, RSVD=0) is a change to a pin that landed 2026-08-31 under a
#    completed multi-round verification, is outside this packet's fence, and is unproven against
#    CI's Bochs 2.8 -- it is recorded as a residual, not smuggled in on this push.
#  * ABSOLUTE addresses are compared WITHIN a loader family and not across one. QEMU
#    (-kernel/-initrd) and Bochs (GRUB multiboot) place the module at different addresses, so
#    ms/al/ah/pf_eip/pf_esp legitimately differ ACROSS loaders -- but two arms of the SAME loader
#    (tcg and kvm) must agree on them exactly, and throwing that evidence away would be a real loss
#    (blind Opus 5 finding 6). Across loaders only the normalized shape is compared.
#  * The normalized facts are NOT a proven invariant -- they are what all three engines MEASURED
#    identically on 2026-09-01 (tcg/kvm/bochs: pf_off_in_module=0x99, esp_below_alloc_lo=0xf70,
#    cr2=0xfa), each with the module page directly below its stack page (layout_gap=0). geeking's
#    allocator is first-fit around the module, so a loader that placed the module far from the
#    allocator's first free page would change all three -- and would ALSO make grade_overflow's
#    own eip window unreachable, i.e. it is a substrate change that must be adjudicated by a human,
#    not absorbed. layout_gap is therefore REPORTED per engine and called out when it differs, so
#    a placement change announces itself instead of arriving disguised as a fault disagreement
#    (blind Opus 5 finding 1).
# Every stream is FIRST re-graded by grade_overflow (the full witness chain) -- the comparator never
# compares two streams unless each independently proves a genuine mid-overflow CPL3 #PF, so
# "the engines agree" can never mean "the engines agree about garbage".
#
# WHAT THIS CANNOT CHECK, stated plainly: engine identity is CALLER-ASSERTED. The comparator refuses
# a duplicate label and refuses the SAME FILE handed in twice (the realistic accident, and the exact
# forgery cross-model Codex finding 1 demonstrated), but it cannot tell a genuine KVM capture from a
# copy of the TCG one. What makes the labels true is the gate: overflow_arm boots each label with
# its own accelerator flags. Byte-identity between two captures is NOT treated as forgery -- two
# engines agreeing completely is a legitimate outcome, and rejecting it would make this leg depend
# on the very errcode divergence the file refuses to trust (blind Opus 5 finding 2).

# The facts grade_overflow leaves FREE per stream, so a disagreement here means something:
OVF_CROSS_DISCRIMINATING = ('cr2',                 # grade_overflow does not look at cr2 at all
                            'pf_off_in_module',    # grade_overflow only bounds pf_eip to a page range
                            'esp_below_alloc_lo',  # grade_overflow only requires pf_esp < alloc_lo
                            'pf_mechanism')        # errcode minus the W bit; grade_overflow pins only U
# Already pinned to CONSTANTS per stream by grade_overflow (answer==0x50, ah-al==0x1000,
# rd_byte==fed). Two streams that both graded GREEN can never disagree on these, so comparing them
# proves nothing today; kept only as defence in depth if that per-stream pin is ever loosened, and
# never to be cited as this check's teeth:
OVF_CROSS_REDUNDANT = ('answer', 'alloc_span', 'fed_byte')
OVF_CROSS_FIELDS = OVF_CROSS_DISCRIMINATING + OVF_CROSS_REDUNDANT
# Compared only among arms sharing a loader (identical placement is required there):
OVF_SAME_LOADER_FIELDS = ('mod_start', 'alloc_lo', 'alloc_hi', 'pf_eip', 'pf_esp')
PF_ERR_W = 0x2   # the ONE errcode bit two correct engines may legitimately disagree on here
# Loader names are a CLOSED set on purpose: an arbitrary string would let a caller declare the two
# QEMU arms as different loaders and silently skip the same-loader absolute-address comparison
# (cross-model Codex confirm-leg finding 5).
OVF_KNOWN_LOADERS = frozenset(('qemu', 'grub'))
OVF_MEASURED_GAP = 0   # the module page sat directly below its stack page on all 3 engines, 2026-09-01

def _ovf_facts(stream, kend_elf, fed):
    errs = grade_overflow(stream, kend_elf, fed)
    if errs: return None, None, errs
    r = G.parse(stream)
    # grade_overflow guarantees every field below EXCEPT mod_start: its eip-range check is written
    # `if ms is not None and ...`, so a table with no ms SKIPS that check instead of failing it. Do
    # not let that turn into a TypeError here -- fail CLOSED with a named error.
    if r.get('ms') is None:
        return None, None, ['OWN table carries no mod_start -- the module-relative facts this '
                            'comparator compares cannot be computed; failing closed']
    mp = r['ms'] & ~0xFFF
    facts = {'answer':             r['answer'],
             'cr2':                r['pf_cr2'],
             'pf_off_in_module':   r['pf_eip'] - r['ms'],
             'esp_below_alloc_lo': r['al'] - r['pf_esp'],
             'pf_mechanism':       r['pf_err'] & ~PF_ERR_W,
             'alloc_span':         r['ah'] - r['al'],
             'fed_byte':           r['rd_byte'],
             'mod_start':          r['ms'], 'alloc_lo': r['al'], 'alloc_hi': r['ah'],
             'pf_eip':             r['pf_eip'], 'pf_esp': r['pf_esp']}
    raw = {'pf_err': r['pf_err'], 'layout_gap': r['al'] - (mp + 0x1000)}
    return facts, raw, []

def overflow_cross(named_streams, kend_elf, fed):
    """named_streams: [(label, loader, path, stream_bytes), ...]. -> (report_lines, errs)"""
    if len(named_streams) < 2:
        return ([], ['cross-engine agreement needs >= 2 engines, got %d -- a SINGLE-engine overflow '
                     'leg is exactly the A11 residual this check exists to close' % len(named_streams)])
    seen = set()
    for label, _lo, _p, _d in named_streams:
        if label in seen:
            return ([], ['duplicate engine label %r -- two arms of the same engine are not two engines' % label])
        seen.add(label)
    # Identity is the capture's device+inode, so a symlink, a HARDLINK and a bind-mounted alias of
    # one file are all caught; a plain `cp` is not, and is named as a limit in the header above.
    for i in range(len(named_streams)):
        for j in range(i + 1, len(named_streams)):
            if named_streams[i][2] and named_streams[i][2] == named_streams[j][2]:
                return ([], ['engines %r and %r were handed the SAME capture (one file, device:inode %s) '
                             '-- one boot is not two engines'
                             % (named_streams[i][0], named_streams[j][0], named_streams[i][2])])
    facts = {}; raws = {}; errs = []
    for label, _lo, _p, data in named_streams:
        f, raw, e = _ovf_facts(data, kend_elf, fed)
        if e: errs += ['[%s] %s' % (label, x) for x in e]
        else: facts[label] = f; raws[label] = raw
    if errs: return ([], errs)
    lines = []
    for label, loader, _p, _d in named_streams:
        f, raw = facts[label], raws[label]
        lines.append('  %-5s loader=%-5s pf_err=0x%x (W bit ENGINE-DEPENDENT, masked; the rest IS compared) '
                     'cr2=0x%x pf_eip=0x%x pf_esp=0x%x mod_start=0x%x alloc=[0x%x,0x%x) layout_gap=%d'
                     % (label, loader, raw['pf_err'], f['cr2'], f['pf_eip'], f['pf_esp'],
                        f['mod_start'], f['alloc_lo'], f['alloc_hi'], raw['layout_gap']))
    base = named_streams[0][0]
    for label, _lo, _p, _d in named_streams[1:]:
        for k in OVF_CROSS_FIELDS:   # the REDUNDANT half cannot fire; see the list's own comment
            if facts[label][k] != facts[base][k]:
                errs.append('engine disagreement on %s: %s=%s vs %s=%s -- a fact both engines must '
                            'report identically' % (k, base, _hx(facts[base][k]), label, _hx(facts[label][k])))
    # same-loader arms must additionally agree on the ABSOLUTE addresses (identical placement).
    byloader = {}
    for label, loader, _p, _d in named_streams: byloader.setdefault(loader, []).append(label)
    for loader, labels in byloader.items():
        for label in labels[1:]:
            for k in OVF_SAME_LOADER_FIELDS:
                if facts[label][k] != facts[labels[0]][k]:
                    errs.append('same-loader (%s) disagreement on %s: %s=%s vs %s=%s -- arms sharing a '
                                'loader must land the module at the SAME address'
                                % (loader, k, labels[0], _hx(facts[labels[0]][k]), label, _hx(facts[label][k])))
    pf_errs = sorted({raws[l]['pf_err'] for l, _lo, _p, _d in named_streams})
    if len(pf_errs) > 1:
        lines.append('  NOTE: the engines report DIFFERENT page-fault error codes (%s) for the SAME '
                     'fault -- expected and tolerated ONLY in the W bit: the faulting instruction is a '
                     'read-modify-write and engines may fault on either half. Every other errcode bit IS '
                     'compared.' % ', '.join('0x%x' % e for e in pf_errs))
    gaps = sorted({raws[l]['layout_gap'] for l, _lo, _p, _d in named_streams})
    if len(gaps) == 1 and gaps[0] != OVF_MEASURED_GAP:
        lines.append('  NOTE: every engine placed the module %d bytes from its stack page, not the %d this '
                     'leg was validated against on 2026-09-01. The engines still AGREE, so nothing here is '
                     'RED -- but the layout the normalization was justified on has moved, and that is a '
                     'SUBSTRATE CHANGE to adjudicate by hand.' % (gaps[0], OVF_MEASURED_GAP))
    if len(gaps) > 1:
        lines.append('  NOTE: the engines placed the module at DIFFERENT distances from its stack page '
                     '(layout_gap %s). The normalized facts above were measured on 2026-09-01 with gap=0 '
                     'on all three engines; a nonzero or differing gap is a SUBSTRATE CHANGE to adjudicate '
                     'by hand, not to absorb.' % ', '.join(str(g) for g in gaps))
    if len(named_streams) == 2 and len(byloader) == 1:
        lines.append('  NOTE: both arms share the %s loader, so this run compares two EXECUTION engines, '
                     'not two independent loaders. The cross-loader half of the check needs a Bochs arm.'
                     % next(iter(byloader)))
    return (lines, errs)

# ============== mutation-battery completion witness (charter change 7, 2026-08-31) ==============
# The tranche-1a MINIMAL witness (a hex-regex "stream ends with DE..AD") left the mutation battery
# forgeable by capture accidents: rc was never bound, and a corrupt stream that kept its terminal
# frame could still score a "bite" with the mutant question never posed. This witness is parser-backed
# and rc-consistent: the OWN table must parse under the frozen-kernel pin, the stream must END with
# the byte-aligned terminal DE<answer>AD frame, the process rc must be EXACTLY the isa-debug-exit
# encoding of that terminal answer (((answer^0x31)&0x7f)<<1|1), the read-witness frame must carry
# the fed byte (the mutant question was posed), and the outcome must be EXACTLY ONE named path with
# its frame VALUE-BOUND to the answer (exit status == answer; pf/gp/gf/kill => 0x50/0x47/0x46/0x4b
# -- the rc encoding drops the answer's high bit, so the frame bind, not rc, is the answer's
# integrity check; Codex change 1 2026-08-31). Signal deaths are excluded UPSTREAM by the
# status-preserving boot_qemu runner (boot_once refuses SIGNAL:* boots before this witness runs).
# Class 'full' (normal mutants) requires the SYS_EXIT outcome; class 'faultok' (wrongrel: a
# corrupted call target) accepts exit OR a named fault/kill outcome. A witnessed completion is
# graded ONCE and never replayed; an unwitnessed attempt is a harness class (re-rolled boundedly
# by the battery, fail-closed on exhaustion).
# Frame regexes (byte-identical to G.parse's) + the OWN-table tail walk, for the CARDINALITY pin:
# G.parse keeps only the FIRST match of each frame type, so a corrupt capture carrying a second,
# contradictory frame (two exit frames; an early conflicting DE..AD before the terminal one) would
# be invisible to a presence/type check (Codex confirm-leg BLOCK, 2026-08-31). mut_witness counts
# ACTUAL frame occurrences on the tail (measured exactly-1 on every genuine stream) and requires
# the parser's first-match answer to EQUAL the terminal answer, so the witness and the grader are
# reading the same boot.
MW_FRAME_PATS = {'rd': rb'\xC0(.)(.{4})(.{4})(.{4})\xC1', 'ex': rb'\xE0(.)(.{4})(.{4})(.{4})\xE1',
                 'gp': rb'\xF0(.{4})(.{4})(.{4})(.{4})\xF1', 'pf': rb'\xD0(.{4})(.{4})(.{4})(.{4})(.{4})\xD1',
                 'kill': rb'\xCA(.{4})(.{4})(.{4})(.{4})\xCB', 'gf': rb'\xE2(.{4})(.{4})\xE3',
                 'an': rb'\xDE(.)\xAD'}
def _own_tail(stream):
    # mirror of G.parse's table walk: 9C mmap entries, then 9A + k0/k1/ma/ml + the CELLS dump +
    # the block-ok byte; the frame tail is everything after.
    i = 0; n = len(stream)
    while i < n and stream[i] == 0x9C and i + 25 <= n: i += 25
    if not (i < n and stream[i] == 0x9A): return None
    i += 1 + 16 + 4*len(G.CELLS) + 1
    return stream[i:]

def mut_witness(stream, kend_elf, fed, wclass, rc):
    r = G.parse(stream)
    if not r: return (1, 'no OWN table parsed (dead boot / capture failure)')
    if r['k1'] != kend_elf: return (1, f'dumped k1=0x{r["k1"]:x} != frozen kend=0x{kend_elf:x} (wrong/corrupt kernel image)')
    if len(stream) < 3 or stream[-3] != 0xDE or stream[-1] != 0xAD:
        return (1, 'stream does not END with the byte-aligned terminal DE<answer>AD frame')
    ans = stream[-2]
    if not r.get('block_ok'):
        return (1, 'OWN-table 0x9B terminator missing (block_ok false) -- torn table dump (corrupt capture)')
    tail = _own_tail(stream)
    if tail is None: return (1, 'no OWN-table tail (capture failure)')
    # Overlap-AWARE cardinality (Opus refutation round 1, 2026-08-31): re.findall is
    # non-overlapping, so a second well-formed frame starting INSIDE the first (torn/restarted
    # capture) went uncounted and two contradictory frames still witnessed. Anchoring a match
    # attempt at EVERY offset counts true frame cardinality; exactly-1 then proves the counted
    # frame IS the leftmost one G.parse binds -- witness and grader provably read the same frame.
    comp = {k: re.compile(p, re.S) for k, p in MW_FRAME_PATS.items()}
    mwc = {k: sum(1 for i in range(len(tail)) if pc.match(tail, i)) for k, pc in comp.items()}
    # Structural pins (Opus refutation round 2, 2026-08-31 -- the counts alone were blind to the
    # PRE-tail bytes, which _own_tail skips without inspection):
    # 1. stream-vs-tail count equality: no frame may START before the tail -- a frame hidden in
    #    the mmap/table prefix, or straddling the tail boundary, raises the stream count only.
    swc = {k: sum(1 for i in range(len(stream)) if pc.match(stream, i)) for k, pc in comp.items()}
    if swc != mwc:
        return (1, f'frame(s) start outside the parsed tail (stream counts {swc} != tail counts {mwc}) -- frames hidden in the mmap/table prefix or straddling the boundary (corrupt capture)')
    # 2. tail tokenization: the tail must be EXACTLY a concatenation of well-formed frames (all
    #    magic bytes are distinct, all lengths fixed -- the walk is deterministic). A stitched
    #    second boot's mmap/table bytes are a gap, refused -- this is what pins the k1 check and
    #    the graded frames to the SAME boot. (-no-reboot on every boot site already makes a
    #    reboot-append capture unreachable in-harness; this pays the crafted-stream class too.)
    toks = []
    i = 0
    while i < len(tail):
        for k, pc in comp.items():
            m = pc.match(tail, i)
            if m: break
        else:
            return (1, f'tail offset {i} (byte 0x{tail[i]:02x}) is not the start of a well-formed frame -- non-frame bytes in the frame tail (stitched/corrupt capture)')
        toks.append(k)
        i = m.end()
    # 3. partition-vs-occurrence cross-check (Opus refutation round 3, 2026-08-31): occurrence
    #    counts alone admit PHANTOM frames -- a frame-shaped byte pattern lying wholly inside
    #    another frame's payload, which the partition walk never visits (e.g. an E0..E1 conjured
    #    inside the rd frame's cs/eip/esp bytes satisfied outcome==1 with NO outcome frame in
    #    the tail). Every counted occurrence must BE a partitioned frame: the two censuses must
    #    agree exactly. (The last token is forcibly the terminal an: gapless tokenization + the
    #    ends-with pin, and only the an pattern ends in 0xAD.)
    tkc = {k: 0 for k in comp}
    for k in toks: tkc[k] += 1
    if tkc != mwc:
        return (1, f'occurrence counts {mwc} != tail partition counts {tkc} -- phantom frame pattern inside another frame payload (corrupt capture)')
    # 4. order pin: a real boot services SYS_READ before it can exit/fault -- the rd frame must
    #    precede the outcome frame (outcome-first is unreachable from any boot of the pinned
    #    kernel).
    oidx = [j for j, k in enumerate(toks) if k in ('ex', 'pf', 'gp', 'gf', 'kill')]
    if 'rd' in toks and oidx and oidx[0] < toks.index('rd'):
        return (1, 'outcome frame precedes the read-witness frame -- impossible boot order (corrupt capture)')
    if mwc['an'] != 1:
        return (1, f'answer frame count {mwc["an"]} != 1 -- duplicate/conflicting DE..AD frames (corrupt capture)')
    if r.get('answer') != ans:
        return (1, f'parser answer 0x{r.get("answer"):x} != terminal answer 0x{ans:x} -- conflicting answer frames (the grader would read a different boot than the witness)')
    outcome_frames = mwc['ex'] + mwc['pf'] + mwc['gp'] + mwc['gf'] + mwc['kill']
    if outcome_frames != 1:
        return (1, f'outcome frame count {outcome_frames} != 1 (ex={mwc["ex"]} pf={mwc["pf"]} gp={mwc["gp"]} gf={mwc["gf"]} kill={mwc["kill"]}) -- contradictory or outcome-less stream (corrupt capture)')
    if mwc['rd'] > 1:
        return (1, f'read-witness frame count {mwc["rd"]} != 1 -- duplicate frames (corrupt capture)')
    # rc binds the terminal answer to a NORMAL qemu exit. The encoding drops the answer's high bit
    # (rc(a) == rc(a^0x80)), so rc alone is NOT the answer's integrity check -- the outcome-frame
    # value-bind below carries that (Codex change 1, 2026-08-31). A signal-death rc collision is
    # excluded UPSTREAM, not here: the battery boots through the status-preserving boot_qemu runner
    # (replay_discriminator.sh) and boot_once refuses any SIGNAL:* boot before this witness runs.
    want_rc = (((ans ^ 0x31) & 0x7f) << 1) | 1
    if rc != want_rc:
        return (1, f'rc={rc} inconsistent with terminal answer 0x{ans:x} (want isa-debug-exit rc {want_rc}) -- not a witnessed completion')
    if 'rd_byte' not in r: return (1, 'no read-witness frame (SYS_READ never serviced -- the mutant question was never posed)')
    if r['rd_byte'] != fed: return (1, f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x}')
    named = [nm for key, nm in (('ex_status','exit'), ('pf_err','pf'), ('gp_err','gp'), ('gf_eip','gf'), ('kl_eip','kill')) if key in r]
    if len(named) != 1:
        return (1, f'expected exactly ONE named outcome frame, got {"+".join(named) or "none"} -- a contradictory or outcome-less stream is not a witnessed completion')
    kind = named[0]
    # value-bind the outcome frame to the terminal answer (Codex change 1): a genuine boot's answer
    # IS its outcome -- exit relays the SYS_EXIT status; each fault/kill path stores its own status
    # byte. A high-bit-corrupted answer (rc-invisible) now fails the bind instead of witnessing.
    if kind == 'exit':
        if r['ex_status'] != ans:
            return (1, f'exit-witness status 0x{r["ex_status"]:x} != terminal answer 0x{ans:x} -- outcome frame not bound to the answer')
    else:
        want_ans = {'pf': 0x50, 'gp': 0x47, 'gf': 0x46, 'kill': 0x4B}[kind]
        if ans != want_ans:
            return (1, f'{kind} outcome frame requires answer 0x{want_ans:x}, got 0x{ans:x} -- outcome frame not bound to the answer')
    if wclass == 'full':
        if kind != 'exit':
            return (1, f'outcome {kind} != exit -- a normal mutant must run to SYS_EXIT')
    elif wclass != 'faultok':
        return (1, f'unknown witness class {wclass!r}')
    return (0, f'WITNESSED class={wclass} outcome={kind} answer=0x{ans:x} rc={rc}')

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
    elif cmd == 'kend':
        _, kend, _ = G.build_elf(); print('%x' % kend)
    elif cmd == 'grade':
        stream = open(sys.argv[2],'rb').read(); kend = int(sys.argv[3],16)
        fed = int(sys.argv[4],16); kind = sys.argv[5]
        errs = grade(stream, kend, fed, kind)
        if errs: print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'gradeoverflow':
        stream = open(sys.argv[2],'rb').read(); kend = int(sys.argv[3],16)
        fed = int(sys.argv[4],16)
        errs = grade_overflow(stream, kend, fed)
        if errs: print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'ovfcross':
        kend = int(sys.argv[2],16); fed = int(sys.argv[3],16)
        named = []
        for a in sys.argv[4:]:
            head, sep, path = a.partition('=')
            if not sep: raise SystemExit('ovfcross args are LABEL:LOADER=path (got %r)' % a)
            lbl, _c, loader = head.partition(':')
            if not loader: raise SystemExit('ovfcross args are LABEL:LOADER=path (got %r)' % a)
            if not lbl: raise SystemExit('ovfcross: empty engine label in %r' % a)
            if loader not in OVF_KNOWN_LOADERS:
                raise SystemExit('ovfcross: unknown loader %r for engine %r (known: %s) -- an arbitrary '
                                 'loader name would silently bypass the same-loader absolute-address '
                                 'comparison' % (loader, lbl, ', '.join(sorted(OVF_KNOWN_LOADERS))))
            try:
                # Identity comes from the OPEN FD, and the bytes are read from that SAME fd: deriving
                # it from the path after reading is TOCTOU, and a path compare misses a hardlink or a
                # bind-mounted alias of one inode (cross-model Codex confirm-leg finding 1).
                with open(path, 'rb') as fh:
                    st = os.fstat(fh.fileno())
                    ident = '%d:%d' % (st.st_dev, st.st_ino)
                    data = fh.read()
            except OSError as ex:   # a missing/unreadable capture is a HARNESS class, not a kernel grade
                raise SystemExit('ovfcross: cannot read the %s capture at %s (%s) -- harness failure, '
                                 'not an engine disagreement' % (lbl, path, ex))
            named.append((lbl, loader, ident, data))
        lines, errs = overflow_cross(named, kend, fed)
        for l in lines: print(l)
        if errs: print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'mutwitness':
        stream = open(sys.argv[2],'rb').read(); kend = int(sys.argv[3],16)
        fed = int(sys.argv[4],16); wclass = sys.argv[5]; rc = int(sys.argv[6])
        code, msg = mut_witness(stream, kend, fed, wclass, rc)
        print(msg); sys.exit(code)
    else: raise SystemExit('usage: module|mutant|hex|src|hostT|fx|fy|offsets|kernelelf|kend|grade|gradeoverflow|ovfcross|mutwitness')
