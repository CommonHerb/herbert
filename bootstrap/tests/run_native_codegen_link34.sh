#!/usr/bin/env bash
# Native codegen Link 34 (trikonderoga / the EIGHTEENTH kernel-arc link): the RING-3 PRIVILEGE BOUNDARY
# applied to the build-unknown MODULE. The kernel reuses lodger's discover+allocate machinery, then runs
# the discovered Multiboot MODULE at CPL 3 on the bump-allocated page: a BENIGN module EXITS via `int 0x30`
# (the first syscall -- it cannot `ret` to CPL0 and cannot `out` at IOPL=0), the kernel collects its status
# and the compiled body emits f(status); a HOSTILE module's privileged `out 0xE9` faults #GP(0) at CPL3 and
# the kernel dumps the CPU-AUTHORED ring-cross frame. Selected by "-- emit: multiboot32-trikon". Graded on
# the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs) vs the silicon-proven reference (trikon_ref.py).
#
# WHY GENUINELY NEW: across 17 links the kernel ran code at CPL 0 (it BECAME the program); trikonderoga runs
# the build-unknown module UNPRIVILEGED behind a kernel-controlled entry/exit/fault boundary. The gate proves:
#  (1) RING ENTRY -- the module runs at CPL 3 via inter-privilege iretd (the exit/#GP frame's saved CS has
#      RPL==3, written BY THE CPU, not the module). M-dpl0frame/M-callcpl0 (run at CPL0) -> RED.
#  (2) THE SYSCALL EXIT GATE -- a benign module's status is deliverable ONLY through the DPL-3 int 0x30 gate
#      (ret can't lower CPL, out is dead at IOPL=0). M-gatedpl0 (exit gate DPL0) -> RED.
#  (3) PRIVILEGED-OP ISOLATION -- a hostile `out 0xE9` faults #GP(0) at CPL3/IOPL=0 (errcode==0, eip at the
#      out, no post-fault byte). M-iopl3frame/M-iomap (grant I/O) -> RED.
#  (4) X != Y differential, same sha kernel -- the module CARRIES its answer (benign f(X)=0x5A != f(Y)=0xA7).
#  (5) HONEST ALLOCATION (inherited from lodger, D20) -- the host re-derives the bump-allocator policy from
#      the emitted ownership table and demands EQUALITY; the exit/#GP frame's useresp==alloc_hi binds the
#      module to the allocated page. M-noexclude/M-noexclbuf/M-hardcodeaddr -> RED.
#
# HONEST SCOPE / RESIDUE (audited-assertion, named): PRIVILEGED-OP isolation only, NOT memory isolation
# (flat DPL-3 segs + no paging U/S -> a CPL3 module can still read/write kernel RAM; graded class is
# misbehaving-not-adversarial; memory isolation is a later paging-U/S link). ONE page. CANONICAL-CODEGEN
# proof for the fixed probes. Emulator-graded (versions CI-pinned). The CPU-authored frame is in-band
# forgeable by a hypothetical malicious KERNEL -- closed exactly as lodger: the EXACT prefix (head+handlers+
# tables) + EXACT epilogue byte-pin + the no-`out` straight-line body subset account for EVERY 0xE9 emit
# site, so a kernel != reference is rejected.
#
# The white-box pin is an EXACT byte cmp against the silicon-proven reference (bootstrap/tests/trikon_ref.py
# = audits/link18-whether/step0). ANY prefix/epilogue drift REDs. The held-back MUTATION proof
# (run_native_codegen_link34_mutation.sh) builds reference variants with one design defect each and asserts
# each grades RED, control GREEN.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/trikon_ref.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing trikon_ref.py $REF)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

# build-unknown modules (host-built): X->0x5A, Y->0xA7 (computed, not baked literals); HOST (hostile out
# -> #GP); FAT (X + 4 MiB junk, stresses the allocator). PREFIX=2410, EPI=58.
MODX="$work/mod_x.bin"; MODY="$work/mod_y.bin"; MODH="$work/mod_h.bin"; MODFAT="$work/mod_fat.bin"
python3 "$REF" module X "$MODX"; python3 "$REF" module Y "$MODY"
python3 "$REF" module HOST "$MODH"; python3 "$REF" module FAT "$MODFAT"
GX=0x5A; GY=0xA7
PREFIX_LEN=2410

prog_src() {
    case "$1" in
      tk_echo)  echo 'func main(): return module_byte() end' ;;
      tk_xform) echo 'func main(): return module_byte() * 3 end' ;;
      tk_local) echo 'func main(): let x = module_byte()  let y = 7  return x + y end' ;;
    esac
}
host_byte() { python3 -c "v=$2
print({'tk_echo':v,'tk_xform':(v*3)&0xFF,'tk_local':(v+7)&0xFF}['$1'])"; }
ALL_PROBES="tk_echo tk_xform tk_local"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-trikon\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

elf_meta() { # elf -> esp_top (decimal) = 0x100000 + p_memsz
    local elf="$1"
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local memsz; memsz=$(le32_val "$eh" 144)
    echo $(( 1048576 + memsz ))
}

static_gates() { # label elf
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx; hx=$(xxd -p "$elf" | tr -d '\n')
    local mb_o mb_valid_count=0 mb_valid_off=-1 mb_f mb_c
    for (( mb_o=0; mb_o+12 <= 8192 && mb_o*2+24 <= ${#hx}; mb_o+=4 )); do
        [[ "${hx:$(( mb_o*2 )):8}" == "02b0ad1b" ]] || continue
        mb_f=$(le32_val "$hx" $(( mb_o*2 + 8 ))); mb_c=$(le32_val "$hx" $(( mb_o*2 + 16 )))
        if [[ $(( (16#1BADB002 + mb_f + mb_c) % (1 << 32) )) -eq 0 ]]; then
            mb_valid_count=$(( mb_valid_count + 1 )); mb_valid_off=$mb_o
        fi
    done
    [[ "$mb_valid_count" -eq 1 ]] || { fail_test "$label static: $mb_valid_count checksum-valid Multiboot headers (want 1)"; ok=0; }
    [[ "$mb_valid_off" -eq 4096 ]] || { fail_test "$label static: valid MB header at off $mb_valid_off (want 4096)"; ok=0; }
    mb_f=$(le32_val "$hx" $(( 4096*2 + 8 )))
    [[ $(( mb_f & 2 )) -eq 2 ]] || { fail_test "$label static: MB header flags ($mb_f) lacks MEMINFO bit"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

elf_gates() { # label elf  (P12: e_entry==V0, single PT_LOAD, sizes by value)
    local label="$1" elf="$2" ok=1
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(le32_val "$eh" 48)" -eq 1048588 ]] || { fail_test "$label elf(P12): e_entry != 1048588"; ok=0; }
    [[ "$(le32_val "$eh" 56)" -eq 52 ]] || { fail_test "$label elf(P12): e_phoff != 52"; ok=0; }
    [[ "$(( 16#${eh:90:2}${eh:88:2} ))" -eq 1 ]] || { fail_test "$label elf(P12): e_phnum != 1"; ok=0; }
    [[ "$(le32_val "$eh" 104)" -eq 1 ]] || { fail_test "$label elf(P12): PT_LOAD type != 1"; ok=0; }
    [[ "$(le32_val "$eh" 112)" -eq 4096 ]] || { fail_test "$label elf(P12): p_offset != 4096"; ok=0; }
    [[ "$(le32_val "$eh" 120)" -eq 1048576 ]] || { fail_test "$label elf(P12): p_vaddr != 1048576"; ok=0; }
    [[ "$(le32_val "$eh" 152)" -eq 7 ]] || { fail_test "$label elf(P12): p_flags != 7"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox() { # label elf  (EXACT 2410-byte prefix + EXACT 58-byte epilogue == silicon-proven reference)
    local label="$1" elf="$2" ok=1
    local esp_top; esp_top=$(elf_meta "$elf")
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local filesz; filesz=$(le32_val "$eh" 136); local code_len=$(( filesz - 12 ))
    local got want
    got=$(dd if="$elf" bs=1 skip=4108 count="$PREFIX_LEN" status=none 2>/dev/null | xxd -p | tr -d '\n')
    want=$(python3 "$REF" prefix "$(printf '%x' "$esp_top")")
    [[ "$got" == "$want" ]] || { fail_test "$label wb(prefix): head+handlers+tables != EXACT ${PREFIX_LEN}-byte trikon_ref (esp_top=0x$(printf '%x' "$esp_top"))"; ok=0; }
    local epigot epiwant
    epigot=$(dd if="$elf" bs=1 skip=$(( 4108 + code_len - 58 )) count=58 status=none 2>/dev/null | xxd -p | tr -d '\n')
    epiwant=$(python3 "$REF" epi)
    [[ "$epigot" == "$epiwant" ]] || { fail_test "$label wb(epi): epilogue != EXACT 58-byte reference (a stray 0xE9 emit site?)"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

qemu_run() { # elf mod mem outfile
    timeout 60 qemu-system-x86_64 -kernel "$1" -initrd "$2" -debugcon file:"$4" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -monitor none -cpu qemu64 -m "$3" >/dev/null 2>&1 || true
}

bochs_run() { # elf mod outfile  -> sets shutdown count in $work/.bsd
    local elf; elf="$(readlink -f "$1")"; local mod; mod="$(readlink -f "$2")"; local outfile="$3"
    local W; W="$(mktemp -d)"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then echo "0" > "$work/.bsd"; : > "$outfile"; rm -rf "$W"; return; fi
    ( cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$elf" mnt/boot/kernel.elf; sudo cp "$mod" mnt/boot/app.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/app.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 32
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 90 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null > "$work/.bsd"
    # extract the binary 0xE9 stream: first 0x9C entry tag through the benign DE??AD answer OR the hostile F0..F1 frame.
    python3 - "$W/bochs_out.txt" "$outfile" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    m=re.search(rb'\xde.\xad', d[i:], re.S)
    g=re.search(rb'\xf0.{4}.{4}.{4}.{4}\xf1', d[i:], re.S)
    if m: end=max(end, i+m.end())
    if g: end=max(end, i+g.end())
open(sys.argv[2],'wb').write(d[i:end] if (i>=0 and end>i) else b'')
PY
    rm -rf "$W"
}

reject_probe() { # label directive "<body>"
    local label="$1" directive="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "%s\n%b\n" "$directive" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset program emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link34 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

for label in $ALL_PROBES; do
    elf="$work/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox "$label" "$elf" || continue
    kend=$(elf_meta "$elf"); kh=$(printf '%x' "$kend")
    bx=$(host_byte "$label" 90)          # f(0x5A)
    by=$(host_byte "$label" 167)         # f(0xA7)
    [[ "$bx" != "$by" ]] || { fail_test "$label: host bytes X==Y -- probe not module-distinguishing"; continue; }
    sha_before=$(sha256sum "$elf" | cut -d' ' -f1)
    ok=1
    # QEMU benign: X at 64M/256M/6G (placement divergence) + Y at 64M + FAT at 64M
    qemu_run "$elf" "$MODX" 64M "$work/$label.q64x.bin"; python3 "$REF" grade "$work/$label.q64x.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 64M X: $(python3 "$REF" grade "$work/$label.q64x.bin" "$kh" "$(printf '%x' "$bx")" benign 2>&1 | tr '\n' ' ')"; ok=0; }
    qemu_run "$elf" "$MODX" 256M "$work/$label.q256x.bin"; python3 "$REF" grade "$work/$label.q256x.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 256M X"; ok=0; }
    qemu_run "$elf" "$MODX" 6G "$work/$label.q6gx.bin"; python3 "$REF" grade "$work/$label.q6gx.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 6G X"; ok=0; }
    qemu_run "$elf" "$MODY" 64M "$work/$label.q64y.bin"; python3 "$REF" grade "$work/$label.q64y.bin" "$kh" "$(printf '%x' "$by")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 64M Y"; ok=0; }
    qemu_run "$elf" "$MODFAT" 64M "$work/$label.qfat.bin"; python3 "$REF" grade "$work/$label.qfat.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 64M FAT"; ok=0; }
    # QEMU hostile: out 0xE9 at CPL3 -> #GP(0); host grades the CPU-authored frame.
    qemu_run "$elf" "$MODH" 64M "$work/$label.qh.bin"; python3 "$REF" grade "$work/$label.qh.bin" "$kh" 00 hostile >/dev/null 2>&1 || { fail_test "$label QEMU 64M HOSTILE: $(python3 "$REF" grade "$work/$label.qh.bin" "$kh" 00 hostile 2>&1 | tr '\n' ' ')"; ok=0; }
    if [[ "$run_bochs" -eq 1 ]]; then
        bochs_run "$elf" "$MODX" "$work/$label.bx.bin"; bsd=$(cat "$work/.bsd" 2>/dev/null || echo 0)
        { python3 "$REF" grade "$work/$label.bx.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 && [[ "$bsd" -ge 1 ]]; } || { fail_test "$label Bochs X (shutdown=$bsd): $(python3 "$REF" grade "$work/$label.bx.bin" "$kh" "$(printf '%x' "$bx")" benign 2>&1 | tr '\n' ' ')"; ok=0; }
        bochs_run "$elf" "$MODH" "$work/$label.bh.bin"; bsd=$(cat "$work/.bsd" 2>/dev/null || echo 0)
        { python3 "$REF" grade "$work/$label.bh.bin" "$kh" 00 hostile >/dev/null 2>&1 && [[ "$bsd" -ge 1 ]]; } || { fail_test "$label Bochs HOSTILE (shutdown=$bsd)"; ok=0; }
    fi
    sha_after=$(sha256sum "$elf" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || { fail_test "$label: image changed between runs"; ok=0; }
    [[ "$ok" -eq 1 ]] && pass=$((pass + 1))
done

# ---- reject probes (+ twins): the trikon body subset is straight-line, one module_byte, no calls ----
reject_probe call          '-- emit: multiboot32-trikon'  'func h(): return 2 end\nfunc main(): return h() + module_byte() end'
reject_probe call_twin     '-- emit: multiboot32-trikon'  'func g(): return 4 end\nfunc main(): return g() + module_byte() end'
reject_probe branch        '-- emit: multiboot32-trikon'  'func main(): let x = module_byte()  if x == 5: return 1 else: return 2 end end'
reject_probe branch_twin   '-- emit: multiboot32-trikon'  'func main(): let y = module_byte()  if y == 9: return 3 else: return 4 end end'
reject_probe nomodule      '-- emit: multiboot32-trikon'  'func main(): return 7 end'
reject_probe nomodule_twin '-- emit: multiboot32-trikon'  'func main(): return 9 end'
reject_probe twomodule     '-- emit: multiboot32-trikon'  'func main(): return module_byte() + module_byte() end'
reject_probe twomodule_twin '-- emit: multiboot32-trikon' 'func main(): return module_byte() * module_byte() end'
reject_probe mainarg       '-- emit: multiboot32-trikon'  'func main(p): return p + module_byte() end'
reject_probe mainarg_twin  '-- emit: multiboot32-trikon'  'func main(k): return k - module_byte() end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 10))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link34 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link34 / trikonderoga / eighteenth kernel-arc link: the RING-3 PRIVILEGE BOUNDARY on the build-unknown module -- the kernel runs the discovered Multiboot MODULE at CPL 3 on the bump-allocated page; a BENIGN module exits via the DPL-3 int 0x30 syscall gate (status -> compiled body emits f(status)); a HOSTILE out 0xE9 faults #GP(0) at CPL3/IOPL=0 -> the kernel dumps the CPU-authored ring-cross frame. SAME kernel ELF fed X (0x5A) vs Y (0xA7) -> f(X) != f(Y). $pass checks: static MB+MEMINFO, ELF-P12, white-box EXACT-2410-byte-prefix + EXACT-58-byte-epilogue vs the silicon-proven trikon_ref, QEMU substrate (benign X 64M/256M/6G + Y + FAT; hostile #GP), Bochs substrate (GRUB module; benign + hostile; clean shutdown), 10 rejects with twins; graded vs the host benign-exit/hostile-#GP frame witness + lodger allocator-recompute on the dual-substrate oracle -- privileged-op isolation, memory isolation deferred to a paging-U/S link)"
exit 0
