#!/usr/bin/env bash
# Native codegen Link 65 (gyre, the 49th kernel-arc link): TAIL-CALL OPTIMIZATION on the
# sovereign x86-64 freestanding long64 target. Herbert has no loops -- tail recursion is the
# language's ONLY iteration form -- and before gyre the taproot call ABI converted it into
# guarded stack overflow: a tail-recursive program deeper than the 2-MiB guard stack #PF'd.
# gyre ports the PROVEN Linux TCO emitter (nc_is_tail_call / nc_emit_tail_call) into the
# nc_tap_* block: an ELIGIBLE tail call (op-20 immediately followed by the function's op-21,
# return not a branch target, NON-main caller, EQUAL argument words -- the Linux-parity rule)
# reuses the current frame and jumps (E9) to the callee ENTRY instead of E8-calling it, so a
# 1,000,000-deep tail recursion COMPLETES at CONSTANT stack. Non-tail calls, unequal-arity
# tail calls, and every call in main stay E8 (correct, just not constant-stack).
#
# THE TAIL TRANSITION (frameful caller; nargs copies; all disp8 -- 14-param cap):
#   4C 8B 5D 08  mov r11,[rbp+8]     save the return address BEFORE any slot is rewritten
#   4C 8B 55 00  mov r10,[rbp]       save the parent rbp
#   { 48 8B 44 24 ib / 48 89 45 ib } x nargs
#                                    PARALLEL-MOVE-SAFE copy: every argument was already
#                                    evaluated onto the OPERAND STACK (the staging area),
#                                    so a swap `return f(b, a)` never reads a clobbered
#                                    slot; src=[rsp+8*(nf-1-k)] -> dst=[rbp+8+8*(nf-k)]
#   4C 89 5D 08  mov [rbp+8],r11     rewrite the return-address slot (parity no-op)
#   48 8D 65 08  lea rsp,[rbp+8]     the STACK RECLAMATION (frame+operands released)
#   4C 89 D5     mov rbp,r10         restore the parent rbp
#   E9 rel32     jmp callee ENTRY    callee's own prologue re-frames at the SAME address
# Frame-zero caller (0 params, 0 locals): rsp already points AT the return address -> the
# transition is the bare E9. The op-21 after a tail site is still emitted (dead, shape-kept).
#
# Oracle (no C; each leg independent):
#  (1) full-image GOLDEN HASH per accepted probe (committed bootstrap/tests/gyre_goldens/);
#  (2) DEEP-TAIL COMPLETES: 1,000,000-deep runs (self / mutual+differing-frames / swap /
#      three-cycle / 14-arg boundary) boot on QEMU and grade the HAND-DERIVED byte -- each
#      paired with a SHALLOW COMPLETING TWIN so completion is attributable to constant stack,
#      plus a >=3-probe distinctness panel. The forcing differential vs the PRE-gyre seed
#      (same deep program: accepted, then NO grading frame) was captured ONE-TIME at
#      authoring; the PERMANENT forcing proof is M-notco + M-reclaim in the mutation harness.
#  (3) SITE-AWARE WHITE-BOX (worklist decode, no raw byte counts): every function is decoded
#      from its own entry (objdump), so every E8/E9 is a REAL instruction with a decoded
#      machine address and direct target. Asserts per probe: exact tail-transition count and
#      full window bytes (preamble + per-arg copy pairs with exact disp8s + reclamation
#      window + E9), each E9 target lands on a callee ENTRY (0x55 push rbp, or the pinned
#      frame-zero entry byte), exact E8 count with entry targets (main's calls ALWAYS E8 --
#      the main-exclusion pin; unequal-arity tail-shaped call stays E8; non-tail recursion
#      keeps its BACKWARD E8), complete E9 accounting (tail windows + internal `58 E9`
#      return-jumps + pinned bare tails and NOTHING else), no far/indirect calls in any
#      decoded instruction, and the guard-PD white-box with the stack size UNCHANGED (the
#      2-MiB stack + guard formula -- no enlarged-stack escape).
#  (4) NON-TAIL STILL OVERFLOWS: a deep NON-tail recursion (result consumed -> stays E8)
#      still produces NO grading frame (the guard still bites) + its shallow twin completes.
#  (5) rejects are inherited: gyre adds NO acceptance change (ineligible sites fall back to
#      E8) -- pinned here by t8 (non-tail), t9 (unequal arity), and every main call site.
# The mutation harness (run_native_codegen_link65_mutation.sh) proves each leg bites RED:
# M-notco, M-reclaim, M-shuffle, M-wrongtarget, M-nontailE9, M-610/M-611/M-604, M-golden.
#
# Honest scope: proves constant-stack tail calls for equal-argument-word, non-main tail
# sites on QEMU-TCG (+ KVM locally) + Bochs -- NOT unequal-arity TCO, not main TCO, not
# device I/O, not literal #PF capture (divergence-plus-guard-white-box is the witness).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/gyre_goldens"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L65_BOCHS_PROBES:-t1d t3d}"

if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }   # local real-silicon leg (links 44..65 KVM-leg pattern)
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

host_proof() { echo $(( ( $1 >> 32 ) & 0xff )); }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

# ---- accepted probes. Deep legs are 1,000,000-level tail recursions that must COMPLETE at
# constant stack; twins are the same shapes shallow. Hand-derived u64 results (independent
# host oracle):
#   t1 self-tail:            down(n,acc)=acc+n*2^32          t1d: 10^6*2^32   t1t: 6*2^32
#   t2 mutual+diff frames:   ping adds 1*2^32, pong 2*2^32,  t2d: 1.5e6*2^32  t2t: 12*2^32
#      (pong carries an extra local -> frame 3 vs ping's 2: differing-frame-size chain)
#   t3 SWAP (parallel move): sw(a,b,n)->sw(b,a,n-1); odd n swaps, even n identity;
#      a=5*2^32,b=3*2^32; result 2a'+b'                      t3d(n=1000001): 11*2^32
#                                                            t3t(n=2):       13*2^32
#   t4 THREE-CYCLE:          rot(a,b,c,n)->rot(c,a,b,n-1); result a'+2b'+4c'; (1,2,3)*2^32
#                            10^6 mod 3 = 1 -> (3,1,2) -> 13*2^32; n=2 -> (2,3,1) -> 12*2^32
#   t5 frame-zero caller AND frame-zero target, zero-arg tail (bare E9): 7*2^32
#   t6 frameFUL caller (local, 0 params) -> frame-zero target, zero-arg tail window
#      + a NON-tail E8 to the same leaf in the same body:    7*2^32
#   t7 14-arg/15-slot boundary self-tail (disp8 extremes: src [rsp+0x68], dst [rbp+0x78]):
#      w counts a down, accumulates n += 3*2^32              t7d: 3e6*2^32    t7t: 6*2^32
#   t8 NON-TAIL deep recursion (nt(n-1)+2*2^32 -- result consumed, stays E8): t8d DIVERGES
#      (would-be completion (10^6+1)*2*2^32 -> byte 0x82/exit 103 must NOT appear);
#      t8t: nt(4)=5*2*2^32=10*2^32 completes.
#   t9 UNEQUAL-ARITY tail-shaped call (two(a,b) -> one(a+b): 2 words -> 1 word) stays E8:
#      one(5) -> 2*2^32.
prog_src() { case "$1" in
  t1d) printf 'func down(n, acc):\n    if n == 0: return acc end\n    return down(n - 1, acc + 4294967296)\nend\nfunc main(): return down(1000000, 0) end\n' ;;
  t1t) printf 'func down(n, acc):\n    if n == 0: return acc end\n    return down(n - 1, acc + 4294967296)\nend\nfunc main(): return down(6, 0) end\n' ;;
  t2d) printf 'func pong(n, acc):\n    let two = 8589934592\n    if n == 0: return acc end\n    return ping(n - 1, acc + two)\nend\nfunc ping(n, acc):\n    if n == 0: return acc end\n    return pong(n - 1, acc + 4294967296)\nend\nfunc main(): return ping(1000000, 0) end\n' ;;
  t2t) printf 'func pong(n, acc):\n    let two = 8589934592\n    if n == 0: return acc end\n    return ping(n - 1, acc + two)\nend\nfunc ping(n, acc):\n    if n == 0: return acc end\n    return pong(n - 1, acc + 4294967296)\nend\nfunc main(): return ping(8, 0) end\n' ;;
  t3d) printf 'func sw(a, b, n):\n    if n == 0: return a + a + b end\n    return sw(b, a, n - 1)\nend\nfunc main(): return sw(21474836480, 12884901888, 1000001) end\n' ;;
  t3t) printf 'func sw(a, b, n):\n    if n == 0: return a + a + b end\n    return sw(b, a, n - 1)\nend\nfunc main(): return sw(21474836480, 12884901888, 2) end\n' ;;
  t4d) printf 'func rot(a, b, c, n):\n    if n == 0: return a + b + b + c + c + c + c end\n    return rot(c, a, b, n - 1)\nend\nfunc main(): return rot(4294967296, 8589934592, 12884901888, 1000000) end\n' ;;
  t4t) printf 'func rot(a, b, c, n):\n    if n == 0: return a + b + b + c + c + c + c end\n    return rot(c, a, b, n - 1)\nend\nfunc main(): return rot(4294967296, 8589934592, 12884901888, 2) end\n' ;;
  t5)  printf 'func leafk(): return 30064771072 end\nfunc mid(): return leafk() end\nfunc main(): return mid() end\n' ;;
  t6)  printf 'func leafk(): return 30064771072 end\nfunc hold():\n    let seven = leafk()\n    if seven == 0: return 0 end\n    return leafk()\nend\nfunc main(): return hold() end\n' ;;
  t7d) printf 'func w(a, b, c, d, e, f, g, h, i, j, k, l, m, n):\n    let one = 1\n    if a == 0: return n end\n    return w(a - one, b, c, d, e, f, g, h, i, j, k, l, m, n + 12884901888)\nend\nfunc main(): return w(1000000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) end\n' ;;
  t7t) printf 'func w(a, b, c, d, e, f, g, h, i, j, k, l, m, n):\n    let one = 1\n    if a == 0: return n end\n    return w(a - one, b, c, d, e, f, g, h, i, j, k, l, m, n + 12884901888)\nend\nfunc main(): return w(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) end\n' ;;
  t8d) printf 'func nt(n):\n    if n == 0: return 8589934592 end\n    return nt(n - 1) + 8589934592\nend\nfunc main(): return nt(1000000) end\n' ;;
  t8t) printf 'func nt(n):\n    if n == 0: return 8589934592 end\n    return nt(n - 1) + 8589934592\nend\nfunc main(): return nt(4) end\n' ;;
  t9)  printf 'func one(x):\n    if x == 0: return 4294967296 end\n    return 8589934592\nend\nfunc two(a, b): return one(a + b) end\nfunc main(): return two(2, 3) end\n' ;;
esac; }
prog_v() { python3 - "$1" <<'PY'
import sys
k=sys.argv[1]
V={'t1d':1000000*(2**32),'t1t':6*(2**32),
   't2d':1500000*(2**32),'t2t':12*(2**32),
   't3d':11*(2**32),'t3t':13*(2**32),
   't4d':13*(2**32),'t4t':12*(2**32),
   't5':7*(2**32),'t6':7*(2**32),
   't7d':3000000*(2**32),'t7t':6*(2**32),
   't8t':10*(2**32),'t9':2*(2**32)}
print(V[k] % (2**64))
PY
}
ACCEPTED="t1d t1t t2d t2t t3d t3t t4d t4t t5 t6 t7d t7t t8d t8t t9"
COMPLETING="t1d t1t t2d t2t t3d t3t t4d t4t t5 t6 t7d t7t t8t t9"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '-- emit: multiboot32-long64\n'; prog_src "$label"; } > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- static: multiboot header valid + syscall-free code window (link62 pattern) ----
static_ok() { # label elf
    local label="$1" elf="$2"
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; return 1; }
    local code="$tmp/$label.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    echo "$chx" | grep -q '0f05' && { fail_test "$label static: 0F05 syscall present"; return 1; }
    echo "$chx" | grep -q 'cd80' && { fail_test "$label static: CD80 present"; return 1; }
    return 0
}

# ---- SITE-AWARE white-box: worklist decode from function entries (change-7 discipline).
# Per-probe EXPECTATIONS are derived from the SOURCE (commented at prog_src) and pinned:
#   e8=<count>:<dir><entrybyte>,...   every decoded E8 (dir f/b, target entry byte)
#   tail=<count>:<dir><nargs>,...     full frameful tail windows (exact bytes incl. disp8s)
#   bare=<count>                      frame-zero bare-E9 tails (pinned entry-byte targets)
# plus: complete E9 accounting, no far/indirect calls, guard PD + stack-size pin.
# GATE-TEETH hardening (A1-A3): function entries are DERIVED INDEPENDENTLY from the image's
# own layout (the emitter's own callee_block_start = main_epi_abs + 4 + 58 formula, then a
# CONTIGUOUS decode of the whole callee block split at DECODED ret instructions) rather than
# seeded from the decoded call/jmp targets themselves (the old circularity: a tail jmp into a
# wrong-but-decodable prologue used to be silently accepted as "a discovered function"). Every
# call/jmp target is then checked for EXACT membership in that independently-derived entry set
# (A1). Function boundaries come from a DECODED ret at an instruction boundary, never a raw
# code.find(b'\xc3') byte search that a 0xC3 inside an immediate could fool (A3), and the
# decoder's coverage of both the main region and the callee block is asserted CONTIGUOUS (no
# gap/overlap -- so no byte, including a stray forged E9, can hide outside a decoded region).
# Every decoded E9 is partitioned into {tail-window, bare-tail, internal return-jump} and the
# per-region total is cross-checked against an independently-counted raw E9 tally, so "every
# E9 accounted, nothing else" is an enforced assertion, not just an incremented-and-ignored
# counter (A2).
WB="$tmp/wb65.py"
cat > "$WB" <<'PY'
import sys,struct,subprocess,re

elf=open(sys.argv[1],'rb').read(); label=sys.argv[2]
V0=0x10000c
filesz=struct.unpack('<I',elf[68:72])[0]
code_len=filesz-12
code=elf[4108:4108+code_len]

# ---------- guard PD white-box + stack-size pin (no enlarged-stack escape) ----------
if code[56]!=0xBC: print("ERR no mov esp at head end"); sys.exit(2)
esp=struct.unpack('<I',code[57:61])[0]
pd=code[code_len-4096:code_len]
entries_pd=[struct.unpack('<Q',pd[i*8:i*8+8])[0] for i in range(512)]
nonpresent=[i for i,e in enumerate(entries_pd) if (e & 1)==0]
present_ok=all((entries_pd[i]==i*0x200000+0x83) for i in range(512) if i not in nonpresent)
gidx=(esp-0x400000)//0x200000
guard_ok=(len(nonpresent)==1 and nonpresent[0]==gidx and present_ok and (esp-0x400000)%0x200000==0)
# stack size UNCHANGED: esp sits exactly 2 MiB above the stack page base, which sits exactly
# 2 MiB above the guard page -- the (esp - 0x400000) formula IS the 2-MiB-stack pin.
if not guard_ok:
    print(f"guard-PD/stack-size white-box FAILED (nonpresent={nonpresent} gidx={gidx} esp={esp:#x})"); sys.exit(1)

# ---------- locate the executable region ----------
sig=b'\xff\xff\x00\x00\x00\x9a\xaf\x00'
pos=code.find(sig)
if pos<8: print("cannot locate GDT"); sys.exit(2)
gdt=pos-8

# ---------- main body base: after the 56-byte head + mov esp (5) + optional main frame (7) ----------
mb=61
if code[61:64]==b'\x48\x89\xe5' and code[64:67]==b'\x48\x83\xec': mb=68

RECL=bytes.fromhex('4c895d08488d65084c89d5')
PRE =bytes.fromhex('4c8b5d084c8b5500')

def copy_pairs(nargs):
    b=bytearray()
    for k in range(nargs):
        b+=bytes([0x48,0x8B,0x44,0x24,8*(nargs-1-k),0x48,0x89,0x45,8+8*(nargs-k)])
    return bytes(b)

def decode(start,end):
    """objdump from a KNOWN instruction boundary; returns [(addr,bytes,mnemonic,rest)].
    objdump wraps any instruction whose opcode bytes exceed 7 (e.g. the 10-byte
    `movabs rax,imm64` t5/t6 use) onto a mnemonic-less CONTINUATION line; those trailing
    bytes must be folded back into the instruction they belong to, or byte-length
    bookkeeping (and therefore any contiguity check) silently undercounts them and a
    real gap/overlap could go undetected."""
    open('/tmp/wb65.bin','wb').write(code[start:end])
    out=subprocess.run(['objdump','-D','-b','binary','-m','i386:x86-64','-M','intel',
                        f'--adjust-vma={start}','/tmp/wb65.bin'],capture_output=True,text=True).stdout
    ins=[]
    for ln in out.splitlines():
        mc=re.match(r'^\s*[0-9a-f]+:\s*((?:[0-9a-f]{2}\s+)+)$',ln)
        if mc:
            if ins: ins[-1]=(ins[-1][0],ins[-1][1]+mc.group(1).split(),ins[-1][2],ins[-1][3])
            continue
        m=re.match(r'\s*([0-9a-f]+):\s*((?:[0-9a-f]{2} )+)\s*(\S+)\s*(.*)$',ln)
        if m: ins.append((int(m.group(1),16),m.group(2).split(),m.group(3),m.group(4).strip()))
    return ins

def assert_contiguous(ins,start,end,region_name):
    """A3: the decoder must consume the region byte-for-byte, with no gap or overlap --
    proves no byte (incl. a forged/stray E9) can hide between what got scanned."""
    cur=start
    for (a,byts,mn,rest) in ins:
        if a!=cur:
            print(f"{region_name}: decode gap/overlap at {a:#x} (expected {cur:#x})"); sys.exit(1)
        cur=a+len(byts)
    if cur!=end:
        print(f"{region_name}: decode did not fully cover the region (stopped at {cur:#x}, want {end:#x})"); sys.exit(1)

# decode main body up to the grading tail (48 C1 E8 20)
gt=code.find(b'\x48\xc1\xe8\x20',mb)
if gt<0: print("no grading tail"); sys.exit(2)

# ---------- A1: INDEPENDENTLY-DERIVED callee function entries ----------
# cb_start is the emitter's OWN fixed-offset layout formula (nc_tap_emit_program:
# callee_block_start = main_epi_abs + 4 + 58 -- the 4-byte grading tail plus the 58-byte
# isa-debug-exit halt epilogue immediately after main's body), NOT anything read off a
# decoded call/jmp target. This is the de-circularization: the old code seeded candidate
# "functions" directly from decoded targets (funcs[tgt]=None), so a tail jmp into a
# different-but-still-decodable 0x55 prologue was silently accepted as a legitimate
# discovery. Here the entry set is built FIRST, from layout alone, and call/jmp targets
# are checked against it afterward.
cb_start=gt+4+58

main_ins=decode(mb,cb_start)
assert_contiguous(main_ins,mb,cb_start,"main region")
if not any(a==gt for (a,_,_,_) in main_ins):
    print(f"grading-tail anchor {gt:#x} is not a real decoded instruction boundary"); sys.exit(1)

callee_ins=decode(cb_start,gdt)
assert_contiguous(callee_ins,cb_start,gdt,"callee block")

# A3: split the callee block into functions at each DECODED ret (0xC3 at an instruction
# boundary) -- never a raw code.find(b'\xc3') byte search, which a 0xC3 inside an
# immediate/rel32 could fool into truncating a function's coverage early.
derived_funcs=[]   # (entry,end) exclusive, in image layout order
seg_start=cb_start
for (a,byts,mn,rest) in callee_ins:
    if mn=='ret':
        fend=a+len(byts)
        derived_funcs.append((seg_start,fend))
        seg_start=fend
if seg_start!=gdt:
    print(f"callee block did not end on a function ret (leftover [{seg_start:#x},{gdt:#x}))"); sys.exit(1)
if not derived_funcs:
    print("no callee functions derived from layout"); sys.exit(1)
ENTRIES=set(e for (e,_) in derived_funcs)

def harvest(name,ins,start,end):
    """Classify every decoded call/jmp in an already-decoded instruction slice (no
    per-site re-dump, no raw byte search)."""
    out=[]
    for (a,byts,mn,rest) in ins:
        b0=int(byts[0],16)
        if mn in ('call','jmp') and b0 in (0xE8,0xE9):
            tgt=int(rest.split()[0],16)
            if b0==0xE9 and code[a-len(RECL):a]==RECL:
                # a tail's E9 targets SOME callee entry (self or other) -- the reclamation
                # window immediately preceding it identifies the tail transition first
                out.append((name,a,'E9',tgt,'tailwin'))
            elif b0==0xE9 and start<=tgt<end:
                # A2: an intra-function E9 is legitimate ONLY as a `58 E9` return-jump (pop the
                # result into rax, then jmp to the shared epilogue). There is NO permissive
                # 'internal' bucket: any intra-function E9 NOT immediately preceded by 0x58 is an
                # unexpected transfer and is REJECTED, so an injected arbitrary internal E9 cannot
                # be silently accepted (the old code classified every intra-function E9 as an
                # accepted 'internal', making the accounting tautological).
                if a>0 and code[a-1]==0x58:
                    out.append((name,a,'E9',tgt,'ret-jmp'))
                else:
                    print(f"unexpected internal E9 at {a:#x} (target {tgt:#x}) is not a 0x58-preceded return-jump"); sys.exit(1)
            elif b0==0xE9:
                out.append((name,a,'E9',tgt,'bare'))
            else:
                out.append((name,a,'E8',tgt,'call'))
        elif mn=='jmp' and b0==0xEB:
            # B1: the ONLY legitimate EB in the tap path is the fixed epilogue halt loop
            # `F4 EB FD` (hlt; jmp $-1) -- EMPIRICALLY VERIFIED across every gyre probe (each has
            # exactly one EB, always `eb fd` preceded by 0xF4; real control flow lowers to Jcc/E9,
            # never a variable EB). Pin EB to that halt form; any other EB is rejected.
            r=int(byts[1],16); rel=r-256 if r>=128 else r; tgt=a+2+rel
            if not (a>=1 and code[a-1]==0xF4 and tgt==a-1):
                print(f"EB short jmp at {a:#x} is not the fixed F4-preceded halt-loop (bytes {byts}, target {tgt:#x})"); sys.exit(1)
        elif mn in ('call','lcall','callf') or (mn=='jmp' and b0 not in (0xE9,0xEB)):
            print(f"forbidden call/jmp form at {a:#x}: {mn} {rest}"); sys.exit(1)
        elif b0==0x9A:
            print(f"far-call opcode at {a:#x}"); sys.exit(1)
        elif mn=='(bad)':
            print(f"undecodable instruction at {a:#x} (decode desync or forged bytes)"); sys.exit(1)
    return out

# A2: per-region E9 accounting -- every decoded E9 must land in EXACTLY one of {tailwin,
# bare, internal}, cross-checked against an INDEPENDENTLY-counted raw E9 tally for that
# region (not merely incremented and left unchecked), so no E9 can go unaccounted.
def check_e9_accounting(name,ins,region_sites):
    raw_e9=sum(1 for (a,byts,mn,rest) in ins if mn=='jmp' and byts[0]=='e9')
    tw=sum(1 for s in region_sites if s[4]=='tailwin')
    br=sum(1 for s in region_sites if s[4]=='bare')
    it=sum(1 for s in region_sites if s[4]=='ret-jmp')
    if raw_e9!=tw+br+it:
        print(f"{name}: E9 accounting mismatch: raw={raw_e9} tailwin={tw} bare={br} internal={it}"); sys.exit(1)

sites=[]   # (caller, addr, opcode, target, sub)
main_body_ins=[x for x in main_ins if x[0]<gt]
main_sites=harvest('main',main_body_ins,mb,gt)
check_e9_accounting('main',main_body_ins,main_sites)
sites+=main_sites

# B1 (epilogue coverage): the fixed [gt,cb_start) grading-tail + halt epilogue is decoded for
# contiguity (A3) but its TRANSFERS were previously outside harvest -- a forged call/jmp there
# went unvalidated. EMPIRICALLY the epilogue holds exactly ONE transfer: the `F4 EB FD` halt
# loop (verified across probes). Validate every transfer in the slice: no call, no far-call, no
# non-EB jmp, and the sole EB must be the F4-preceded halt self-loop; anything else is rejected.
epi_ins=[x for x in main_ins if gt<=x[0]<cb_start]
epi_eb=0
for (a,byts,mn,rest) in epi_ins:
    b0=int(byts[0],16)
    if mn=='(bad)':
        print(f"undecodable instruction in epilogue at {a:#x}"); sys.exit(1)
    if b0==0x9A:
        print(f"far-call opcode in epilogue at {a:#x}"); sys.exit(1)
    if mn in ('call','lcall','callf'):
        print(f"unexpected call in epilogue at {a:#x}: {mn} {rest}"); sys.exit(1)
    if mn=='jmp':
        if b0!=0xEB:
            print(f"unexpected non-EB jmp in epilogue at {a:#x}: {mn} {rest}"); sys.exit(1)
        r=int(byts[1],16); rel=r-256 if r>=128 else r; tgt=a+2+rel
        if not (a>=1 and code[a-1]==0xF4 and tgt==a-1):
            print(f"epilogue EB at {a:#x} is not the F4-preceded halt loop (bytes {byts}, target {tgt:#x})"); sys.exit(1)
        epi_eb+=1
if epi_eb!=1:
    print(f"epilogue must contain exactly one halt-loop EB, found {epi_eb}"); sys.exit(1)

for (fstart,fend) in derived_funcs:
    fname=f'f{fstart:#x}'
    fins=[x for x in callee_ins if fstart<=x[0]<fend]
    fsites=harvest(fname,fins,fstart,fend)
    check_e9_accounting(fname,fins,fsites)
    sites+=fsites

# A1: every call/jmp TARGET that invokes a function (E8 calls, tail-window E9s, bare-tail
# E9s) must equal an INDEPENDENTLY-derived entry EXACTLY -- not "some byte 0x55 somewhere",
# and not a target trusted merely because it happened to decode as a plausible prologue.
for (name,a,op,tgt,sub) in sites:
    if sub in ('tailwin','bare') or op=='E8':
        if tgt not in ENTRIES:
            print(f"site {name}@{a:#x} ({op}/{sub}) targets {tgt:#x}, which is NOT an independently-derived function entry"); sys.exit(1)

# ---------- canonicalize + verify tail windows byte-exactly ----------
e8=[];tails=[];bares=[];internals=0
for (name,a,op,tgt,sub) in sites:
    d='f' if tgt>a else 'b'
    tb=code[tgt]
    if op=='E8':
        e8.append((name,a,d,tb,tgt))
    elif sub=='tailwin':
        # recover nargs from the window: preamble at a-11-9k-8 for some k; try all 0..14
        nargs=None
        for k in range(15):
            w=a-len(RECL)-9*k-len(PRE)
            if w>=0 and code[w:w+len(PRE)]==PRE and code[w+len(PRE):w+len(PRE)+9*k]==copy_pairs(k):
                nargs=k; break
        if nargs is None:
            print(f"tail E9 at {a:#x} lacks an exact window"); sys.exit(1)
        tails.append((name,a,d,nargs,tb,tgt))
    elif sub=='bare':
        bares.append((name,a,d,tb,tgt))
    else:
        internals+=1

# ---------- per-probe expectations (derived from each probe's SOURCE, see prog_src) ----------
# fields: E8 sites as (dir,entrybyte) multiset; tail windows as (dir,nargs,entrybyte);
# bare tails as (dir,entrybyte); main site rule: EVERY site attributed to 'main' must be E8.
# retjmps = the EXACT number of legitimate `58 E9` internal return-jumps expected for the
# probe (empirically derived per probe, then pinned): an extra/missing internal return-jump
# now fails, so `internals` is CHECKED against a pinned total, not merely printed.
EXP={
 't1d':dict(e8=[('f',0x55)],tails=[('b',2,0x55)],bares=[],retjmps=1),
 't1t':dict(e8=[('f',0x55)],tails=[('b',2,0x55)],bares=[],retjmps=1),
 't2d':dict(e8=[('f',0x55)],tails=[('f',2,0x55),('b',2,0x55)],bares=[],retjmps=2),
 't2t':dict(e8=[('f',0x55)],tails=[('f',2,0x55),('b',2,0x55)],bares=[],retjmps=2),
 't3d':dict(e8=[('f',0x55)],tails=[('b',3,0x55)],bares=[],retjmps=1),
 't3t':dict(e8=[('f',0x55)],tails=[('b',3,0x55)],bares=[],retjmps=1),
 't4d':dict(e8=[('f',0x55)],tails=[('b',4,0x55)],bares=[],retjmps=1),
 't4t':dict(e8=[('f',0x55)],tails=[('b',4,0x55)],bares=[],retjmps=1),
 't5' :dict(e8=[('f',0xE9)],tails=[],bares=[('f',0x48)],retjmps=0),
 't6' :dict(e8=[('f',0x55),('f',0x48)],tails=[('f',0,0x48)],bares=[],retjmps=1),
 't7d':dict(e8=[('f',0x55)],tails=[('b',14,0x55)],bares=[],retjmps=1),
 't7t':dict(e8=[('f',0x55)],tails=[('b',14,0x55)],bares=[],retjmps=1),
 't8d':dict(e8=[('f',0x55),('b',0x55)],tails=[],bares=[],retjmps=1),
 't8t':dict(e8=[('f',0x55),('b',0x55)],tails=[],bares=[],retjmps=1),
 't9' :dict(e8=[('f',0x55),('f',0x55)],tails=[],bares=[],retjmps=1),
}
exp=EXP[label]
got_e8=sorted((d,tb) for (_,_,d,tb,_) in e8)
got_tails=sorted((d,n,tb) for (_,_,d,n,tb,_) in tails)
got_bares=sorted((d,tb) for (_,_,d,tb,_) in bares)
ok=True
if got_e8!=sorted(exp['e8']): print(f"E8 sites {got_e8} != expected {sorted(exp['e8'])}"); ok=False
if got_tails!=sorted(exp['tails']): print(f"tail windows {got_tails} != expected {sorted(exp['tails'])}"); ok=False
if got_bares!=sorted(exp['bares']): print(f"bare tails {got_bares} != expected {sorted(exp['bares'])}"); ok=False
if internals!=exp['retjmps']: print(f"internal return-jumps {internals} != expected {exp['retjmps']}"); ok=False
# main-exclusion pin: no tail transition may originate in main (its calls stay E8)
for (name,a,op,tgt,sub) in sites:
    if name=='main' and op=='E9' and sub in ('tailwin','bare'):
        print(f"main-exclusion violated: tail E9 at {a:#x} inside main"); ok=False
if not ok: sys.exit(1)
for (name,a,d,n,tb,tgt) in tails:
    print(f"  site {name}@{a:#x}: TAIL E9 nargs={n} dir={d} -> entry {tgt:#x} (byte {tb:#04x}) [window exact]")
for (name,a,d,tb,tgt) in e8:
    print(f"  site {name}@{a:#x}: E8 dir={d} -> entry {tgt:#x} (byte {tb:#04x})")
for (name,a,d,tb,tgt) in bares:
    print(f"  site {name}@{a:#x}: BARE tail E9 dir={d} -> entry {tgt:#x} (byte {tb:#04x})")
print(f"  E9 accounting: internal return-jumps={internals}; independently-derived entries={len(ENTRIES)} (layout-derived, not call-target-seeded)")
sys.exit(0)
PY
whitebox() { python3 "$WB" "$1" "$2"; }

# ---- QEMU runtime: boot, expect one de<byte>ad frame + result-dependent isa-debug-exit ----
qemu_run() { # label elf v [kvm]
    local label="$1" elf="$2" v="$3" kvm="${4:-}"
    local p ex ph; p=$(host_proof "$v"); ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.q"; mkdir -p "$W"
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    printf "\\xde\\x${ph}\\xad" > "$W/golden.bin"
    timeout 120 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none "${acc[@]}" -m 64M
    local rc=$?
    local nf; nf=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n' | grep -o "de${ph}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && cmp -s "$W/e9.bin" "$W/golden.bin" && [[ "$nf" -eq 1 ]]; then return 0; fi
    fail_test "$label QEMU: exit=$rc(want $ex) e9=$(xxd -p "$W/e9.bin" 2>/dev/null) want=de${ph}ad nframes=$nf"; return 1
}

# ---- Bochs runtime (independent second decoder): GRUB multiboot (link62 pattern) ----
bochs_run() { # label elf v
    local label="$1" elf="$2" v="$3"
    local p ph; p=$(host_proof "$v"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.b"; mkdir -p "$W"; local kelf; kelf="$(readlink -f "$elf")"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS missing"; return 1; fi
    ( cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf
      printf 'set timeout=0\nset default=0\nmenuentry "s" {\n multiboot /boot/kernel.elf\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 120 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nf sd
    nf=$(grep -o "de${ph}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    sd=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null || echo 0)
    if [[ "$nf" -eq 1 ]] && [[ "$sd" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs: frames(de${ph}ad)=$nf shutdown=$sd"; return 1
}

# ===================== run =====================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but no QEMU)"; exit 1; fi
    echo "NOTE: QEMU absent; link65 skipped locally. Authoritative in kernel-codegen CI."; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi
run_kvm=0; have_kvm && run_kvm=1
if [[ "$run_kvm" -eq 1 ]]; then
    echo "link65: /dev/kvm present -- the KVM real-silicon leg runs on the accepted-probe value witness (links 44..65 KVM-leg pattern)."
else
    echo "NOTE: /dev/kvm absent or unusable -- KVM real-silicon leg skipped (a standalone-gate local pre-push leg, skip-if-unavailable by design; kernel_verify.sh is the fail-closed enforcer that REQUIRES a present+usable /dev/kvm; QEMU-TCG + Bochs are the fail-closed CI substrates)."
fi

declare -A BYTE
for label in $ACCEPTED; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    # (1) full-image golden hash (byte-pin)
    if [[ -f "$goldens_dir/$label.sha256" ]]; then
        want=$(cat "$goldens_dir/$label.sha256"); got=$(sha256sum "$elf" | cut -d' ' -f1)
        if [[ "$want" == "$got" ]]; then pass=$((pass + 1)); else fail_test "$label: image != committed golden ($got != $want)"; fi
    else
        fail_test "$label: missing committed golden $goldens_dir/$label.sha256"
    fi
    # statics + (3) site-aware white-box (tail windows, E8/E9 accounting, guard+stack pin)
    static_ok "$label" "$elf" && pass=$((pass + 1))
    if whitebox "$elf" "$label" > "$tmp/$label.wb"; then pass=$((pass + 1)); else
        fail_test "$label: site-aware white-box FAILED: $(tail -2 "$tmp/$label.wb" | tr '\n' ' ')"
    fi
    # (2)/(4) runtime QEMU-TCG (+ KVM when present)
    if [[ " $COMPLETING " == *" $label "* ]]; then
        v=$(prog_v "$label"); BYTE[$label]=$(host_proof "$v")
        qemu_run "$label" "$elf" "$v" && pass=$((pass + 1))
        if [[ "$run_kvm" -eq 1 ]]; then
            qemu_run "${label}.kvm" "$elf" "$v" kvm && pass=$((pass + 1))
        fi
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
            bochs_run "$label" "$elf" "$v" && pass=$((pass + 1))
        fi
    fi
done

# (4) t8d: deep NON-TAIL recursion must DIVERGE (no grading frame; the guard still bites).
# Would-be completion: (10^6+1)*2*2^32 -> byte 0x82 -> exit 103 -- must NOT appear.
if [[ -f "$tmp/t8d.elf" ]]; then
    W="$tmp/t8d.run"; mkdir -p "$W"
    timeout 120 qemu-system-x86_64 -kernel "$tmp/t8d.elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M
    rc=$?
    got=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    frames=$(echo "$got" | grep -Eo 'de[0-9a-f]{2}ad' | wc -l | tr -d ' ')
    if [[ "$rc" -ne 103 && "$frames" -eq 0 ]]; then
        echo "gyre: deep NON-TAIL recursion still overflows the guard stack -> no grading frame (rc=$rc, e9='$got'); its shallow twin t8t completed -- the guard survives TCO"
        pass=$((pass + 1))
    else
        fail_test "t8d: deep NON-TAIL recursion did NOT diverge (rc=$rc frames=$frames e9=$got) -- TCO may have leaked into a non-tail site or the guard is gone"
    fi
fi

# (2) distinctness panel across the deep completing runs
if [[ "${BYTE[t1d]:-x}" != "${BYTE[t2d]:-y}" && "${BYTE[t1d]:-x}" != "${BYTE[t3d]:-z}" && "${BYTE[t2d]:-y}" != "${BYTE[t3d]:-z}" ]]; then
    pass=$((pass + 1))
else
    fail_test "distinctness vacuous: t1d=${BYTE[t1d]:-?} t2d=${BYTE[t2d]:-?} t3d=${BYTE[t3d]:-?}"
fi

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link65 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link65 / gyre / 49th kernel-arc link: TAIL-CALL OPTIMIZATION on the sovereign x86-64 freestanding target -- eligible tail calls (equal argument words, non-main) reuse the frame and E9-jump to the callee entry, so the language's only iteration form runs at CONSTANT STACK: 1,000,000-deep self / mutual+differing-frame / SWAP (parallel-move) / THREE-CYCLE / 14-arg-boundary tail recursions all COMPLETE and grade hand-derived bytes (distinct-bytes panel), each with a shallow completing twin; $pass checks: full-image golden hash + static + SITE-AWARE white-box (worklist decode: exact tail-window bytes incl. per-arg disp8 copy pairs + reclamation window, every E9/E8 accounted with decoded machine addresses + entry targets, main-exclusion pin, no far/indirect calls, guard-PD + 2-MiB stack-size pin) per accepted probe, frame-zero bare-E9 + frameful-to-frame-zero coverage, non-tail deep recursion STILL diverges (guard survives TCO) + unequal-arity tail-shaped call stays E8, QEMU-TCG substrate + Bochs substrate ($BOCHS_PROBES) + KVM real-silicon leg (when /dev/kvm present; links 44..65 KVM-leg pattern); the pre-gyre seed differential was one-time authoring evidence -- the PERMANENT forcing proof is the M-notco/M-reclaim mutation pair; no C)"
exit 0
