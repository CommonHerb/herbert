#!/usr/bin/env python3
# coalgate_ref.py -- coalgate (link 22 / native-codegen Link 38) STEP-0 oracle + BYTE-EXACT emitter target.
#
# THE INVERSION (vs every prior kernel link): until now the COMPILER emitted the whole kernel ELF and a
# Python ref hand-assembled the build-unknown MODULE. coalgate flips it: the FROZEN geeking kernel is the
# host (re-emitted byte-for-byte from `-- emit: multiboot32-geeking`), and the COMPILER emits the MODULE --
# a raw, position-independent i386 blob (entry byte 0) the kernel runs at ring 3. This file hand-assembles
# the EXACT bytes that new emit mode must produce, for a set of Herbert-source transforms, so STEP-0 can:
#   (1) prove the FROZEN geeking kernel runs the target module on QEMU + Bochs + KVM and emits DE<T(fed)>AD,
#       BEFORE the emitter exists (the dual_substrate_before_implementing law); and
#   (2) the emitter's output is later proven BYTE-IDENTICAL to target_module(kind) (the gate).
#
# The module byte convention is the named ABI in audits/link22-coalgate/00-module-abi.md, promoted from the
# hand-crafted sitopia/geeking mod_roundtrip. The kernel contract (launch frame, int 0x30 SYS_READ/SYS_EXIT,
# the watchdog) is geeking's, verified byte-identical; we import geeking_ref for the host ELF + stream parse.
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import geeking_ref as G

SYS_READ = 0
SYS_EXIT = 1
UCODE3 = 0x1B          # geeking_ref UCODE|3
def le32(v): return struct.pack('<I', v & 0xFFFFFFFF)

# ---- the nc32 32-bit stack-machine op encodings (mirror of native_compile_fragment.herb nc32_lower_loop;
#      these are exactly what the coalgate emit mode reuses wholesale for the transform body) ----
def OP_PUSH(imm):  return bytes([0x68]) + le32(imm)                 # op 0  push imm32                       (5)
OP_ADD  = bytes([0x59, 0x58, 0x01, 0xC8, 0x50])                     # op 5  pop ecx;pop eax;add eax,ecx;push (5)
OP_SUB  = bytes([0x59, 0x58, 0x29, 0xC8, 0x50])                     # op 6  ...sub eax,ecx;push              (5)
OP_MUL  = bytes([0x59, 0x58, 0x0F, 0xAF, 0xC1, 0x50])              # op 42 ...imul eax,ecx;push             (6)
def OP_LOADL(slot): return bytes([0xFF, 0x75, (256 - 4*(slot+1)) & 0xFF])  # op 3  push [ebp-4*(slot+1)]    (3)
def OP_STOREL(slot):return bytes([0x8F, 0x45, (256 - 4*(slot+1)) & 0xFF])  # op 4  pop  [ebp-4*(slot+1)]    (3)
OP_RET_LAST = bytes([0x58])                                        # op 21 (last)  pop eax -> result in eax  (1)

# ---- the NEW module-side syscall glue (op 47 sys_read, and the implicit sys_exit wrapper) ----
OP_SYSREAD = bytes([0xB8]) + le32(SYS_READ) + bytes([0xCD, 0x30, 0x50])    # op 47 mov eax,0;int 0x30;push eax (8)
EXITSC     = bytes([0x88, 0xC3, 0xB8]) + le32(SYS_EXIT) + bytes([0xCD, 0x30])  # mov bl,al;mov eax,1;int 0x30   (9)
FRAME      = lambda n: bytes([0x89, 0xE5, 0x83, 0xEC, (4*n) & 0xFF])        # mov ebp,esp; sub esp,4*nlocals   (5)

# ---- the v1 transform set. Each: (herb source, body-ops-after-the-leading-sys_read, nlocals, host T). The
#      body is always [OP_SYSREAD] + <ops> + [OP_RET_LAST]; the module is [FRAME if nlocals>0] + body + EXITSC
#      + tag. (Tags are 4 ASCII bytes -- a harmless trailing marker, never executed; the module SYS_EXITs.) ----
XF = {
  'echo': ("func main(): return sys_read() end",
           b'', 0, lambda b: b & 0xFF),
  'add7': ("func main(): return sys_read() + 7 end",
           OP_PUSH(7) + OP_ADD, 0, lambda b: (b + 7) & 0xFF),
  'mul3': ("func main(): return sys_read() * 3 end",
           OP_PUSH(3) + OP_MUL, 0, lambda b: (b * 3) & 0xFF),
  'sub5': ("func main(): return sys_read() - 5 end",
           OP_PUSH(5) + OP_SUB, 0, lambda b: (b - 5) & 0xFF),
  # a local variant -- exercises the frame prologue (mov ebp,esp; sub esp,4). Source:
  #   func main(): let x = sys_read()  return x + 3 end
  # lowering: op47, store-local0, load-local0, push 3, add, ret. nlocals=1.
  'local': ("func main(): let x = sys_read()  return x + 3 end",
            OP_STOREL(0) + OP_LOADL(0) + OP_PUSH(3) + OP_ADD, 1, lambda b: (b + 3) & 0xFF),
}
def target_module(kind):
    """The EXACT bytes the coalgate emit mode must produce for this kind's .herb source.
    No trailing tag: the module is [frame] + body + EXITSC and execution never returns past SYS_EXIT."""
    _, ops, nlocals, _ = XF[kind]
    prologue = FRAME(nlocals) if nlocals > 0 else b''
    body = OP_SYSREAD + ops + OP_RET_LAST
    return prologue + body + EXITSC

def host_T(kind, b):  return XF[kind][3](b)
def herb_src(kind):   return XF[kind][0]

# ---- mutant modules (negative controls for the mutation harness). Each is a raw blob shaped like a
#      module but BROKEN; the gate must grade it RED, proving the answer==host_T + X!=Y checks bite. ----
def mutant_module(mut):
    if mut == 'constbake':   # reads the byte, then IGNORES it and bakes 0x5A -> constant answer -> X!=Y RED
        return OP_SYSREAD + OP_RET_LAST + bytes([0xB0, 0x5A]) + EXITSC      # mov al,0x5A after the read
    if mut == 'wrongadd':    # +8 where the add7 transform expects +7 -> answer != host_T(add7) RED
        return OP_SYSREAD + OP_PUSH(8) + OP_ADD + OP_RET_LAST + EXITSC
    if mut == 'noxform':     # echo where add7 expected -> answer == fed != fed+7 RED
        return OP_SYSREAD + OP_RET_LAST + EXITSC
    raise SystemExit('mutant?')

def read_ret(kind):
    """Module offset the SYS_READ int 0x30 returns to (the push eax of op 47) -- the read-witness eip - modstart."""
    _, _, nlocals, _ = XF[kind]
    plen = 5 if nlocals > 0 else 0
    return plen + 7                                  # 7 = len(mov eax,0)+len(int 0x30) within OP_SYSREAD
def exit_ret(kind):
    """Module offset just past the SYS_EXIT int 0x30 -- the exit-witness eip - modstart."""
    _, ops, nlocals, _ = XF[kind]
    plen = 5 if nlocals > 0 else 0
    body = len(OP_SYSREAD) + len(ops) + len(OP_RET_LAST)
    return plen + body + len(EXITSC)

# ===================== STEP-0 / gate grader =====================
def grade(stream, kend_elf, fed, kind):
    """Benign round trip on the FROZEN geeking kernel: the compiled module ran at CPL3, did the SYS_READ
    round trip, SYS_EXITed its transform of the fed byte, and the kernel emitted DE<T(fed)>AD. Pins the
    read/exit witness frames BY VALUE (cs==UCODE3, useresp==alloc_hi, eips at the module's own offsets) and
    answer == host_T(fed). Reuses geeking_ref.parse (the frozen kernel's own dump format)."""
    errs = []
    r = G.parse(stream)
    if not r:
        return ['no OWN table parsed (faulted before dump, or kernel RED)']
    if r['k1'] != kend_elf: errs.append(f'dumped k1=0x{r["k1"]:x} != frozen-kernel kend=0x{kend_elf:x}')
    ms, ah = r.get('ms'), r.get('ah')
    rr, xr = read_ret(kind), exit_ret(kind)
    # frame base: at the SYS_READ (sys_read is the leftmost leaf -> empty operand stack) and at the SYS_EXIT
    # (op21-last popped the single result into eax) the user esp is alloc_hi minus the locals the prologue
    # reserved. For nlocals==0 this is alloc_hi; for the local variant it is alloc_hi-4.
    fb = ah - 4 * XF[kind][2]
    # ---- read-witness: kernel serviced SYS_READ for a CPL3 module on its own User stack ----
    if 'rd_byte' not in r:
        errs.append('no read-witness frame (kernel did not service SYS_READ at CPL3 -- module never SYS_READ?)')
    else:
        if r['rd_cs'] != UCODE3 or (r['rd_cs'] & 3) != 3: errs.append(f'read frame cs 0x{r["rd_cs"]:x} != ucode|3')
        if r['rd_esp'] != fb: errs.append(f'read frame useresp 0x{r["rd_esp"]:x} != frame_base 0x{fb:x} (alloc_hi-4*nlocals)')
        if r['rd_eip'] != ms + rr: errs.append(f'read frame eip 0x{r["rd_eip"]:x} != mod_start+{rr} (module layout)')
        if r['rd_byte'] != fed: errs.append(f'delivered byte 0x{r["rd_byte"]:x} != fed 0x{fed:x}')
    # ---- exit-witness: the module RESUMED, transformed, and SYS_EXITed ----
    if 'ex_status' not in r:
        errs.append('no exit-witness frame (module did not SYS_EXIT at CPL3 after re-entry)')
    else:
        if r['ex_cs'] != UCODE3 or (r['ex_cs'] & 3) != 3: errs.append(f'exit frame cs 0x{r["ex_cs"]:x} != ucode|3')
        if r['ex_esp'] != fb: errs.append(f'exit frame useresp 0x{r["ex_esp"]:x} != frame_base 0x{fb:x} (alloc_hi-4*nlocals)')
        if r['ex_eip'] != ms + xr: errs.append(f'exit frame eip 0x{r["ex_eip"]:x} != mod_start+{xr} (module layout)')
    if 'rd_eip' in r and 'ex_eip' in r and (r['ex_eip'] - r['rd_eip']) != (xr - rr):
        errs.append(f'inter-frame eip distance 0x{r["ex_eip"]-r["rd_eip"]:x} != module transform len 0x{xr-rr:x}')
    # ---- the answer: the COMPILED transform of the kernel-delivered byte ----
    want = host_T(kind, fed)
    if r.get('answer') != want:
        errs.append(f'answer 0x{r.get("answer")} != T_{kind}(0x{fed:x})=0x{want:x}')
    # ---- a killed/faulted module is never GREEN ----
    if 'kl_eip' in r: errs.append('benign module was KILLED by the watchdog (kill-witness present)')
    if r.get('answer') == 0x4B and want != 0x4B: errs.append("answer==KILL_STATUS 0x4B (module killed)")
    return errs

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'module':                       # module <kind> <out>   -- the byte-exact target module blob
        open(sys.argv[3], 'wb').write(target_module(sys.argv[2]))
    elif cmd == 'mutant':                      # mutant <mut> <out>    -- a broken module (negative control)
        open(sys.argv[3], 'wb').write(mutant_module(sys.argv[2]))
    elif cmd == 'hex':                        # hex <kind>            -- target module bytes as hex (for diff)
        sys.stdout.write(target_module(sys.argv[2]).hex())
    elif cmd == 'src':                         # src <kind>            -- the .herb source for this kind
        sys.stdout.write(herb_src(sys.argv[2]))
    elif cmd == 'hostT':                       # hostT <kind> <byte>   -- expected transform (decimal)
        print(host_T(sys.argv[2], int(sys.argv[3], 0)))
    elif cmd == 'offsets':                     # offsets <kind>        -- read_ret/exit_ret for the gate
        k = sys.argv[2]; print('read_ret', read_ret(k), 'exit_ret', exit_ret(k), 'len', len(target_module(k)))
    elif cmd == 'kernelelf':                   # kernelelf <out>       -- the FROZEN geeking host kernel ELF
        img, kend, _ = G.build_elf()
        open(sys.argv[2], 'wb').write(img); print('%x' % kend)
    elif cmd == 'kend':                        # kend                  -- the frozen kernel's kend (0x100000+memsz)
        _, kend, _ = G.build_elf(); print('%x' % kend)
    elif cmd == 'grade':                       # grade <stream> <kend> <fedbyte_hex> <kind>
        stream = open(sys.argv[2], 'rb').read(); kend = int(sys.argv[3], 16)
        fed = int(sys.argv[4], 16); kind = sys.argv[5]
        errs = grade(stream, kend, fed, kind)
        if errs: print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    else:
        raise SystemExit('usage: module|hex|src|hostT|offsets|kernelelf|kend|grade')
