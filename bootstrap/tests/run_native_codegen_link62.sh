#!/usr/bin/env bash
# Native codegen Link 62 (taproot, the 46th kernel-arc link): USER CALLS + RECURSION on the
# sovereign x86-64 freestanding target. Widens multiboot32-long64 from a single graded main() to a
# MULTI-FUNCTION program with recursion -- ouroboros's proven 32-bit call ABI widened to 8-byte
# slots + REX.W (push args; push rbp/mov rbp,rsp/sub rsp; param-copy [rbp+16+8k]->[rbp-8(k+1)];
# add rsp cleanup; push rax result; forward+BACKWARD E8 rel32). Herbert has no loops and this target
# has no TCO, so recursion-via-call is the only iteration -- without it no freestanding program of
# substance exists. The single-function path is UNTOUCHED (dispatch on count(funcs)); its byte-identity
# is guarded by run_native_codegen_link26/29 (and re-proven here: a single-function image has the FULL
# identity map, ZERO guard PDEs).
#
# SAFETY (the load-bearing invariant, per the design red-team): the stack is relocated to its OWN
# 2-MiB identity page with the 2-MiB page BELOW it NON-PRESENT in the PD, so a recursion that overflows
# the stack takes a #PF -> triple-fault (a deterministic, observable divergence) instead of SILENTLY
# CORRUPTING the page tables. Proven both WHITE-BOX (exactly one non-present PDE at the guard index) and
# at RUNTIME (a 1,000,000-deep recursion produces NO clean grading frame).
#
# Oracle (no C; defense-in-depth, so a byte-pin blind to a shared bug is still caught by an independent
# leg): (1) full-image GOLDEN HASH per accepted probe (byte-pins head/body/calls/guard/tables); (2) an
# INDEPENDENT host-computed u64 result (hand-derived from each recurrence, NOT from the emitter) booted
# on QEMU + Bochs and graded byte-for-byte; (3) a BACKWARD-call value-pin (E8 + negative rel32 reaching a
# callee's own entry -- the recursion provenance, defeating an unrolled/constant-fold forge); (4) a >=3
# program DISTINCTNESS panel (distinct recurrences -> distinct proof bytes, defeating a movabs/echo forge);
# (5) an E8-ONLY call whitelist (no 9A far-call, no FF/2 indirect, no FF/3 far-indirect); (6) the guard
# white-box + runtime fault; (7) rejects+twins (arity mismatch, call-main, >14 params, out-of-subset
# callee op). The mutation harness (run_native_codegen_link62_mutation.sh) proves each leg bites RED.
#
# Honest scope: proves "the sovereign x86-64 freestanding target runs genuine recursive user calls whose
# graded byte is the 64-bit high dword of the recursion's own result, as a Multiboot image on QEMU +
# Bochs+GRUB (+ KVM locally)" -- NOT device I/O (next link), heap, privileged ops from source, TCO, or
# real firmware. The proof byte is compile-time-determined (no late-bound input this link, by design).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/taproot_goldens"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L62_BOCHS_PROBES:-p1 p2}"

if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }   # local real-silicon leg (links 44..62 KVM-leg pattern)
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

# proof byte = high dword of the u64 result V: (V >> 32) & 0xff. isa-debug-exit = link26's formula.
host_proof() { echo $(( ( $1 >> 32 ) & 0xff )); }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

# accepted probes: 3 DISTINCT recurrences (distinctness panel) + 2 migrated from link26 (single forward
# call) + p4/p5 (param+local coexistence, mutual recursion) + p6/p7 coverage probes pinning the two emit
# paths no other probe reaches (cross-model review): p6 = a FRAMEFUL main (main_frame>0 prologue) that
# calls; p7 = the 14-param/15-slot BOUNDARY (disp8 extremes: src [rbp+120], dst [rbp-120]).
# The u64 result is HAND-DERIVED from the recurrence math -- the INDEPENDENT host oracle.
prog_src() { case "$1" in
  p1) printf 'func rec(n, acc):\n    if n == 0: return acc end\n    return rec(n - 1, acc + 1073741824)\nend\nfunc main(): return rec(6, 0) end\n' ;;
  p2) printf 'func prod(n):\n    if n == 0: return 1 end\n    return n * prod(n - 1)\nend\nfunc main(): return prod(9) * 1073741824 end\n' ;;
  p3) printf 'func rec(n, acc):\n    if n == 0: return acc end\n    return rec(n - 1, acc + n * 536870912)\nend\nfunc main(): return rec(10, 0) end\n' ;;
  call)      printf 'func h(): return 1000000 end\nfunc main(): return h() * 1000000 end\n' ;;
  call_twin) printf 'func g(): return 2000000 end\nfunc main(): return g() * 1000000 end\n' ;;
  p4) printf 'func f(n, acc):\n    let bump = 1073741824\n    if n == 0: return acc end\n    return f(n - 1, acc + bump)\nend\nfunc main(): return f(4, 0) end\n' ;;
  p5) printf 'func pong(n, acc):\n    if n == 0: return acc end\n    return ping(n - 1, acc + 268435456)\nend\nfunc ping(n, acc):\n    if n == 0: return acc end\n    return pong(n - 1, acc + 268435456)\nend\nfunc main(): return ping(16, 0) end\n' ;;
  p6) printf 'func h(k):\n    return k * 4294967296\nend\nfunc main():\n    let base = h(3)\n    return base + h(2)\nend\n' ;;
  p7) printf 'func wide(a, b, c, d, e, f, g, h, i, j, k, l, m, n):\n    let x = a + b + c + d + e + f + g\n    return x + h + i + j + k + l + m + n\nend\nfunc main():\n    return wide(4294967296, 8589934592, 12884901888, 17179869184, 21474836480, 25769803776, 30064771072, 34359738368, 38654705664, 42949672960, 47244640256, 51539607552, 55834574848, 60129542144)\nend\n' ;;
esac; }
# V mod 2^64 (Python bignum -> mask), hand-derived: p1=6*2^30; p2=9!*2^30; p3=(sum 1..10)*2^29;
# call=10^6*10^6; call_twin=2*10^6*10^6; p6=(3+2)*2^32; p7=(1+..+14)*2^32.
prog_v() { python3 - "$1" <<'PY'
import sys
k=sys.argv[1]
if   k=='p1': v=6*(2**30)
elif k=='p2':
    f=1
    for i in range(1,10): f*=i
    v=f*(2**30)
elif k=='p3':
    v=sum(range(1,11))*(2**29)
elif k=='call':      v=1000000*1000000
elif k=='call_twin': v=2*1000000*1000000
elif k=='p4':        v=4*(2**30)                       # params + a local (no slot collision)
elif k=='p5':        v=16*(2**28)                      # mutual recursion ping<->pong
elif k=='p6':        v=5*(2**32)                       # frameful main (local + two calls)
elif k=='p7':        v=105*(2**32)                     # 14-param/15-slot boundary, distinct weights
else: v=0
print(v % (2**64))
PY
}
ACCEPTED="p1 p2 p3 call call_twin p4 p5 p6 p7"
RECURSIVE="p1 p2 p3 p4 p5"

compile_probe() { # label outfile   (multi-function)
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '-- emit: multiboot32-long64\n'; prog_src "$label"; } > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- static: multiboot header valid + syscall-free code window (reused from link26) ----
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

# ---- white-box (Python): guard PD, backward call, E8-only call whitelist, single-func no-guard ----
WB="$tmp/wb.py"
cat > "$WB" <<'PY'
import sys,struct
elf=open(sys.argv[1],'rb').read(); mode=sys.argv[2]
V0=0x10000c
# ELF32 phdr at e_phoff=52; p_filesz at phdr+16 -> file 68. code region = file[4108:4108+filesz-12].
filesz=struct.unpack('<I',elf[68:72])[0]
code_len=filesz-12
code=elf[4108:4108+code_len]
# transition head starts at code[0]; mov esp imm32 is at code[56] = BC <le32>.
if code[56]!=0xBC:
    print("ERR no mov esp at head end"); sys.exit(2)
esp_val=struct.unpack('<I',code[57:61])[0]
# PD = last 4096 bytes of the code region (512 8-byte entries).
pd=code[code_len-4096:code_len]
entries=[struct.unpack('<Q',pd[i*8:i*8+8])[0] for i in range(512)]
nonpresent=[i for i,e in enumerate(entries) if (e & 1)==0]
present_ok=all((entries[i]==i*0x200000+0x83) for i in range(512) if i not in nonpresent)

if mode=='guard':
    # exactly ONE non-present PDE, at the guard index = (esp_val - 0x400000)/0x200000, and every other
    # PDE is the identity 2-MiB present mapping. stack top esp_val = guard_2m + 2*2MiB.
    gidx=(esp_val-0x400000)//0x200000
    ok = (len(nonpresent)==1 and nonpresent[0]==gidx and present_ok
          and (esp_val-0x400000)%0x200000==0)
    sys.exit(0 if ok else 1)

if mode=='noguard':
    # single-function image: FULL identity map, ZERO non-present PDEs (proves the single-func path is
    # untouched by taproot -- it still uses nc32_long_emit_pd_loop).
    sys.exit(0 if (len(nonpresent)==0 and present_ok) else 1)

if mode=='backward':
    # at least one BACKWARD E8 rel32 whose target is a function entry (a callee prologue 0x55 push rbp,
    # or a leaf entry). Pins recursion to the VALUE: target must be < the call site (backward) and land
    # on a real instruction boundary that is an entry. We accept target==any callee-base where the byte
    # there is 0x55 (push rbp) OR the target is reached by >=1 backward E8 (recursion/self or mutual).
    found=False
    for i in range(len(code)-5):
        if code[i]==0xE8:
            rel=struct.unpack('<i',code[i+1:i+5])[0]
            tgt=i+5+rel
            if rel<0 and 0<=tgt<len(code) and code[tgt]==0x55:
                found=True
    sys.exit(0 if found else 1)

if mode=='callwhitelist':
    # scan the EXECUTABLE region only ([56, gdt_start)): the GDT code descriptor 0x00AF9A000000FFFF and
    # the identity PDEs contain data bytes (0x9A, 0xFF) that are not instructions, so we must stop at the
    # GDT. Locate the GDT by its code-descriptor signature (LE of 0x00AF9A000000FFFF) and set gdt_start to
    # the preceding null descriptor (8 zero bytes). Assert in [56,gdt_start): >=1 E8 (call present); NO 0x9A
    # far-call opcode; NO FF /2 (indirect call) or FF /3 (far-indirect call).
    sig=b'\xff\xff\x00\x00\x00\x9a\xaf\x00'
    pos=code.find(sig)
    if pos<8:
        print("cannot locate GDT code descriptor"); sys.exit(2)
    gdt_start=pos-8
    scan=code[56:gdt_start]
    if b'\x9a' in scan:
        print("far-call byte 0x9A in executable region"); sys.exit(1)
    has_e8=(b'\xe8' in scan)
    bad_ff=any(scan[i]==0xFF and ((scan[i+1]>>3)&7) in (2,3) for i in range(len(scan)-1))
    sys.exit(0 if (has_e8 and not bad_ff) else 1)

print("unknown mode"); sys.exit(3)
PY
whitebox() { python3 "$WB" "$1" "$2"; }

# ---- QEMU runtime: boot, expect one de<byte>ad frame + result-dependent isa-debug-exit ----
qemu_run() { # label elf v [kvm]
    local label="$1" elf="$2" v="$3" kvm="${4:-}"
    local p ex ph; p=$(host_proof "$v"); ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.q"; mkdir -p "$W"
    # acceleration: QEMU-TCG by default; -enable-kvm -cpu host for the real-silicon leg (links 44..62 KVM-leg pattern).
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    printf "\\xde\\x${ph}\\xad" > "$W/golden.bin"
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none "${acc[@]}" -m 64M
    local rc=$?
    local nf; nf=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n' | grep -o "de${ph}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && cmp -s "$W/e9.bin" "$W/golden.bin" && [[ "$nf" -eq 1 ]]; then return 0; fi
    fail_test "$label QEMU: exit=$rc(want $ex) e9=$(xxd -p "$W/e9.bin" 2>/dev/null) want=de${ph}ad nframes=$nf"; return 1
}

# ---- Bochs runtime (independent second decoder): GRUB multiboot ----
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
      xvfb-run -a bash -c "yes c | timeout -s KILL 90 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nf sd
    nf=$(grep -o "de${ph}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    sd=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null || echo 0)
    if [[ "$nf" -eq 1 ]] && [[ "$sd" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs: frames(de${ph}ad)=$nf shutdown=$sd"; return 1
}

# ---- reject probes (+ twins): still-out-of-subset multi-function sources must NOT emit an image ----
reject_probe() { # label src
    local label="$1" src="$2"; local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '-- emit: multiboot32-long64\n'; printf '%b\n' "$src"; } > "$cdir/r.herb"
    ( cd "$cdir" && rm -f a.out; "$NATIVE_CODEGEN_COMPILER" < r.herb >/dev/null 2>"$cdir/err" )
    if [[ -s "$cdir/a.out" ]]; then fail_test "reject $label: out-of-subset source emitted an image"; else pass=$((pass + 1)); fi
}

# ---- guard-page RUNTIME fault: a 1,000,000-deep recursion overflows the 2-MiB stack -> #PF -> no clean
#      grading frame. NOTE (cross-model review): this leg ALONE proves only "deep overflow never grades
#      clean"; guard PRESENCE is pinned by the white-box PD leg + the M-noguard mutation -- the
#      COMBINATION is the no-silent-corruption proof. ----
guard_faults() {
    local cdir="$tmp/deep.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '-- emit: multiboot32-long64\n'
      printf 'func rec(n, acc):\n    if n == 0: return acc end\n    return rec(n - 1, acc + 1073741824)\nend\nfunc main(): return rec(1000000, 0) end\n'; } > "$cdir/deep.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < deep.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "guard: deep probe did not compile"; return 1; fi
    local W="$tmp/deep.run"; mkdir -p "$W"
    timeout 60 qemu-system-x86_64 -kernel "$cdir/a.out" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M
    local rc=$?
    # a healthy run exits 97 with a de01ad frame; an overflow that FAULTS produces neither.
    local frames; frames=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n' | grep -o 'de01ad' | wc -l | tr -d ' ')
    if [[ "$rc" -ne 97 ]] && [[ "$frames" -eq 0 ]]; then
        echo "taproot: 1,000,000-deep recursion overflows the 2-MiB stack -> no grading frame (rc=$rc); guard presence pinned by the PD white-box + M-noguard"
        pass=$((pass + 1))
    else
        fail_test "guard: deep recursion did NOT fault (rc=$rc frames=$frames) -- overflow may silently corrupt"
    fi
}

# ===================== run =====================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but no QEMU)"; exit 1; fi
    echo "NOTE: QEMU absent; link62 skipped locally. Authoritative in kernel-codegen CI."; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi
run_kvm=0; have_kvm && run_kvm=1
if [[ "$run_kvm" -eq 1 ]]; then
    echo "link62: /dev/kvm present -- the KVM real-silicon leg runs on the accepted-probe value witness (links 44..62 KVM-leg pattern)."
else
    echo "NOTE: /dev/kvm absent -- KVM real-silicon leg skipped (a local pre-push leg; QEMU-TCG + Bochs are the fail-closed CI substrates)."
fi

declare -A BYTE
for label in $ACCEPTED; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    v=$(prog_v "$label"); BYTE[$label]=$(host_proof "$v")
    # (1) full-image golden hash (byte-pin)
    if [[ -f "$goldens_dir/$label.sha256" ]]; then
        want=$(cat "$goldens_dir/$label.sha256"); got=$(sha256sum "$elf" | cut -d' ' -f1)
        if [[ "$want" == "$got" ]]; then pass=$((pass + 1)); else fail_test "$label: image != committed golden ($got != $want)"; fi
    else
        fail_test "$label: missing committed golden $goldens_dir/$label.sha256"
    fi
    # (2) static + (5) E8-only call whitelist + guard white-box
    static_ok "$label" "$elf" && pass=$((pass + 1))
    whitebox "$elf" callwhitelist && pass=$((pass + 1)) || fail_test "$label: call-form whitelist (E8-only) violated"
    whitebox "$elf" guard && pass=$((pass + 1)) || fail_test "$label: guard PD not exactly-one-nonpresent-at-guard-index"
    # (3) backward-call value-pin (recursive probes only)
    if [[ " $RECURSIVE " == *" $label "* ]]; then
        whitebox "$elf" backward && pass=$((pass + 1)) || fail_test "$label: no BACKWARD recursive call rel32 to a callee entry"
    fi
    # (2) runtime QEMU-TCG
    qemu_run "$label" "$elf" "$v" && pass=$((pass + 1))
    # (2b) KVM real-silicon leg on the SAME value witness (links 44..62 KVM-leg pattern): runs when /dev/kvm is
    # present (kernel-verify REQUIRES it locally); skipped-with-note in CI (GitHub runners have no /dev/kvm).
    if [[ "$run_kvm" -eq 1 ]]; then
        qemu_run "${label}.kvm" "$elf" "$v" kvm && pass=$((pass + 1))
    fi
    # runtime Bochs (subset)
    if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
        bochs_run "$label" "$elf" "$v" && pass=$((pass + 1))
    fi
done

# (4) distinctness: the 3 recurrences produce 3 DISTINCT proof bytes
if [[ "${BYTE[p1]:-x}" != "${BYTE[p2]:-y}" && "${BYTE[p1]:-x}" != "${BYTE[p3]:-z}" && "${BYTE[p2]:-y}" != "${BYTE[p3]:-z}" ]]; then
    pass=$((pass + 1))
else
    fail_test "distinctness vacuous: p1=${BYTE[p1]:-?} p2=${BYTE[p2]:-?} p3=${BYTE[p3]:-?}"
fi

# single-function byte-identity dispatch: a main-only long64 image has the FULL identity map (no guard),
# proving taproot leaves the single-function path untouched.
sf="$tmp/sf.d"; mkdir -p "$sf"
printf -- '-- emit: multiboot32-long64\nfunc main(): return 70000 * 70000 + 126 end\n' > "$sf/sf.herb"
( cd "$sf" && "$NATIVE_CODEGEN_COMPILER" < sf.herb >/dev/null 2>/dev/null )
if [[ -f "$sf/a.out" ]]; then
    whitebox "$sf/a.out" noguard && pass=$((pass + 1)) || fail_test "single-func: image is NOT full-identity-map (dispatch touched the single-func path)"
else
    fail_test "single-func: main-only probe did not compile"
fi

# (6) guard runtime fault
guard_faults

# (7) rejects + twins (still out of subset)
reject_probe arity      'func h(x): return x * 1000000 end\nfunc main(): return h() end'
reject_probe arity_twin 'func k(y): return y * 2000000 end\nfunc main(): return k() end'
reject_probe callmain      'func h(): return main() end\nfunc main(): return h() end'
reject_probe callmain_twin 'func j(): return main() end\nfunc main(): return j() end'
reject_probe manyparams      'func h(a,b,c,d,e,f,g,i,j,k,l,m,n,o,p): return a end\nfunc main(): return h(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) end'
reject_probe manyparams_twin 'func q(a,b,c,d,e,f,g,i,j,k,l,m,n,o,p): return b end\nfunc main(): return q(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) end'
reject_probe divcallee      'func h(): return 1000000 / 3 end\nfunc main(): return h() * 1000000 end'
reject_probe divcallee_twin 'func g(): return 2000000 % 7 end\nfunc main(): return g() * 1000000 end'

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link62 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link62 / taproot / 46th kernel-arc link: USER CALLS + RECURSION on the sovereign x86-64 freestanding target -- multi-function programs with forward+BACKWARD E8 rel32, the ouroboros 8-byte-slot pure-stack ABI, a relocated GUARD-PAGE stack (overflow faults, not corrupts); $pass checks: full-image golden hash + static + E8-only call whitelist + guard-PD white-box (exactly one non-present PDE at the guard index) + BACKWARD-call value-pin (recursion provenance) per accepted probe, a >=3-program distinctness panel (distinct recurrences -> distinct proof bytes), QEMU substrate (9 probes incl. param+local coexistence, mutual recursion, a FRAMEFUL main with calls, and the 14-param/15-slot boundary) + Bochs substrate ($BOCHS_PROBES) + KVM real-silicon leg on the accepted-probe value witness (when /dev/kvm present; links 44..62 KVM-leg pattern), single-function byte-identity dispatch (full identity map, no guard), a 1,000,000-deep guard-fault runtime proof, and 8 rejects+twins (arity/call-main/>14-params/out-of-subset-callee); graded vs an independent hand-derived host golden on the dual-substrate oracle, no C)"
exit 0
