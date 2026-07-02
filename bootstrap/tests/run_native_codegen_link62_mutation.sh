#!/usr/bin/env bash
# Mutation proof for native-codegen link 62 (taproot): each gate leg must BITE (go RED) when the
# capability it guards is broken. We mutate the EMITTED image (not the compiler) to forge a break the
# gate must catch, and assert the corresponding white-box/runtime leg fails. Proves the link62 gate is
# not vacuous. Mutations (each RED-first):
#   M-noguard   : make the guard PDE PRESENT (identity 2-MiB) -> the guard white-box + runtime fault legs
#                 must fail (overflow would no longer fault -> silent corruption).
#   M-fwdcall   : flip the recursive BACKWARD E8 rel32 to a forward/zero rel -> the backward-call value-pin
#                 must fail (recursion provenance gone).
#   M-farcall   : inject a 0x9A far-call byte into the code window -> the E8-only whitelist must fail.
#   M-golden    : perturb one image byte -> the golden-hash pin must fail.
#   M-value     : perturb the graded body so the boot proof byte changes -> the QEMU runtime leg must fail.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: link62-mutation ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then echo "NOTE: no QEMU; link62-mutation skipped locally (authoritative in CI)."; [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]] && { echo "FAIL: REQUIRE_EMU=1 but no QEMU"; exit 1; }; exit 0; fi

# emit p1 (a recursive probe) as the mutation base
base="$tmp/p1.elf"; cdir="$tmp/p1.d"; mkdir -p "$cdir"
printf -- '-- emit: multiboot32-long64\nfunc rec(n, acc):\n    if n == 0: return acc end\n    return rec(n - 1, acc + 1073741824)\nend\nfunc main(): return rec(6, 0) end\n' > "$cdir/p.herb"
( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>/dev/null )
[[ -f "$cdir/a.out" ]] || { echo "FAIL: link62-mutation (base p1 did not compile)"; exit 1; }
cp "$cdir/a.out" "$base"

WB="$script_dir/../../bootstrap/tests"  # not used; reuse the gate's WB inline
PY="$tmp/wb.py"
cat > "$PY" <<'PYEOF'
import sys,struct
elf=bytearray(open(sys.argv[1],'rb').read()); mode=sys.argv[2]
filesz=struct.unpack('<I',elf[68:72])[0]; code_off=4108; code=elf[code_off:code_off+filesz-12]
code_len=len(code)
if mode=='guard':
    pd=code[code_len-4096:code_len]; esp=struct.unpack('<I',code[57:61])[0]
    entries=[struct.unpack('<Q',pd[i*8:i*8+8])[0] for i in range(512)]
    npres=[i for i,e in enumerate(entries) if (e&1)==0]; gidx=(esp-0x400000)//0x200000
    ok=(len(npres)==1 and npres[0]==gidx and all(entries[i]==i*0x200000+0x83 for i in range(512) if i not in npres))
    sys.exit(0 if ok else 1)
if mode=='backward':
    found=False
    for i in range(len(code)-5):
        if code[i]==0xE8:
            rel=struct.unpack('<i',code[i+1:i+5])[0]; tgt=i+5+rel
            if rel<0 and 0<=tgt<len(code) and code[tgt]==0x55: found=True
    sys.exit(0 if found else 1)
if mode=='callwhitelist':
    sig=b'\xff\xff\x00\x00\x00\x9a\xaf\x00'; pos=code.find(sig)
    if pos<8: sys.exit(2)
    scan=code[56:pos-8]
    if b'\x9a' in scan: sys.exit(1)
    bad=any(scan[i]==0xFF and ((scan[i+1]>>3)&7) in (2,3) for i in range(len(scan)-1))
    sys.exit(0 if (b'\xe8' in scan and not bad) else 1)
# --- mutators (write a forged image to argv[3]) ---
if mode=='mk_noguard':
    pds=code_off+code_len-4096; esp=struct.unpack('<I',code[57:61])[0]; gidx=(esp-0x400000)//0x200000
    struct.pack_into('<Q',elf,pds+gidx*8,gidx*0x200000+0x83)   # make guard PDE present
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_fwdcall':
    # zero the first backward E8 rel32 -> target becomes the next instr (no recursion edge)
    for i in range(len(code)-5):
        if code[i]==0xE8:
            rel=struct.unpack('<i',code[i+1:i+5])[0]
            if rel<0:
                struct.pack_into('<i',elf,code_off+i+1,0); break
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_farcall':
    # overwrite a benign NOP-equivalent? inject 0x9A at a safe spot in the code stream (first push rax 0x50)
    for i in range(len(code)):
        if code[i]==0x50: elf[code_off+i]=0x9A; break
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_value':
    # perturb the first movabs imm64 operand (change the computed result -> different proof byte)
    idx=code.find(b'\x48\xb8')
    if idx>=0: elf[code_off+idx+2]^=0xFF
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
sys.exit(3)
PYEOF

expect_red() { # name  cond(0=leg-passed-BAD)
    if [[ "$1" -ne 0 ]]; then pass=$((pass + 1)); else fail_test "$2 did not bite (leg still passed on the forged image)"; fi
}

# M-noguard: forge guard present -> guard white-box must fail
python3 "$PY" "$base" mk_noguard "$tmp/m_noguard.elf"
python3 "$PY" "$tmp/m_noguard.elf" guard; expect_red $? "M-noguard (guard white-box)"

# M-fwdcall: zero the backward rel -> backward-call value-pin must fail
python3 "$PY" "$base" mk_fwdcall "$tmp/m_fwd.elf"
python3 "$PY" "$tmp/m_fwd.elf" backward; expect_red $? "M-fwdcall (backward-call pin)"

# M-farcall: inject 0x9A -> E8-only whitelist must fail
python3 "$PY" "$base" mk_farcall "$tmp/m_far.elf"
python3 "$PY" "$tmp/m_far.elf" callwhitelist; expect_red $? "M-farcall (E8-only whitelist)"

# M-golden: the gate's golden-hash leg must bite (cross-model review: cmp-vs-base was near-vacuous).
# Control: the freshly-emitted base MATCHES the committed p1 golden; forged: a one-byte perturb
# MISMATCHES it -- the exact sha256-vs-committed comparison the gate performs.
goldens_dir="$script_dir/taproot_goldens"
want_g=$(cat "$goldens_dir/p1.sha256" 2>/dev/null || echo MISSING)
got_base=$(sha256sum "$base" | cut -d' ' -f1)
cp "$base" "$tmp/m_gold.elf"; printf '\xff' | dd of="$tmp/m_gold.elf" bs=1 seek=5000 count=1 conv=notrunc status=none 2>/dev/null
got_forged=$(sha256sum "$tmp/m_gold.elf" | cut -d' ' -f1)
if [[ "$got_base" == "$want_g" && "$got_forged" != "$want_g" ]]; then pass=$((pass + 1)); else fail_test "M-golden: golden-hash leg vacuous (base==golden:$([[ "$got_base" == "$want_g" ]] && echo yes || echo NO) forged!=golden:$([[ "$got_forged" != "$want_g" ]] && echo yes || echo NO))"; fi

# M-value: perturb the graded result -> QEMU proof byte changes (boot must NOT produce de01ad/exit97)
python3 "$PY" "$base" mk_value "$tmp/m_val.elf"
timeout 60 qemu-system-x86_64 -kernel "$tmp/m_val.elf" -debugcon file:"$tmp/mv.bin" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1
rc=$?; frames=$(xxd -p "$tmp/mv.bin" 2>/dev/null | tr -d '\n' | grep -o 'de01ad' | wc -l | tr -d ' ')
if [[ "$rc" -ne 97 || "$frames" -eq 0 ]]; then pass=$((pass + 1)); else fail_test "M-value: forged result still graded as the golden byte (rc=$rc frames=$frames)"; fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link62-mutation sub-test(s) failed."; exit 1; fi
echo "PASS: link62-mutation ($pass mutations each bit RED: guard white-box, backward-call pin, E8-only whitelist, golden hash, runtime value)"
exit 0
