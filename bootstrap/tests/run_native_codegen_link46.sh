#!/usr/bin/env bash
# Native-codegen Link 46 / rollcall (kernel-arc link 30): RUNTIME-K PROCESS TABLE + RUN-QUEUE -- the scheduler becomes
# a DATA STRUCTURE. The SAME kernel binary runs an author-unknown number K of ring-3 programs (K read from mods_count
# at RUNTIME), generalizing tickover's hardcoded-TWO (two TCBs UNROLLED, cur^=1) to a TCB ARRAY indexed by a
# round-robin run-queue loop. tickover is the K=2 case. A NEW kernel emit mode `multiboot32-rollcall` (additive on the
# frozen tickover lineage). KERNEL-EMIT only; forcing probes are hand-assembled ref fixtures (1 spinner + K-1 workers).
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a manual KVM leg, vs rollcall_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == rollcall_ref.build_elf() AND carries the runtime-K
#       process-table machinery (assert_rollcall: mods_count+MAXPROC bound, NO ==const hard-assert, indexed
#       module-table store + indexed run-queue read + indexed TCB store) -- distinct from tickover's hardcoded-2.
#   (C) SILICON make-or-break: the SAME kernel binary, fed K=3 / K=5 / K=7 module images (1 spinner + K-1 workers),
#       runs ALL K -- every worker emits its held-back token (it RAN = preemption got the CPU off the non-yielding
#       spinner; a cooperative kernel hangs), the spinner emits le32(VA) (full GP+eflags survived the indexed-TCB
#       restore), no phantom (K+1)th program. An author-unknown K is unfakeable by a finite-unrolled kernel.
#   (C-PEER) HOSTILE-PEER #PF: a variant proc0 writing/reading a PEER region #PFs (err 7/5), CR2 in a peer window,
#       RPL3 -- peer isolation under the runtime-K flip, caught by geeking fault->continue. KVM-load-bearing.
#   (D) FROZEN: tickover/tandem/mumbani/holler kernels + their modules still byte-identical (purely additive).
# The held-back MUTATION proof (run_native_codegen_link46_mutation.sh) proves every choice non-vacuous
# (M-cap2 / M-norobin / M-nowake / M-coop / M-noswitch / M-noflip / M-noflip0 / M-minimal / M-noeflags).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/rollcall_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
KRANGE="${ROLLCALL_KRANGE:-2 3 5 7 8}"   # 2=tickover-parity, 3/5/7=the author-unknown make-or-break, 8=MAXPROC edge
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm() { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

emit() { # marker prog outfile label
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- reference artifacts ----
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK" none full)"
SP="$work/sp.bin"; python3 "$REF" modspinner "$SP"
HW="$work/hw.bin"; python3 "$REF" modhostile "$HW"
HR="$work/hr.bin"; python3 "$REF" modhostileread "$HR"
# build the K-module initrd list (1 spinner + K-1 workers) for a given K
klist() { local K="$1" l="$SP" i; for i in $(seq 1 $((K-1))); do local w="$work/w_${K}_$i.bin"; python3 "$REF" modworker "$w" "$K" "$i"; l="$l,$w"; done; echo "$l"; }

MKELF="$work/rollcall_kernel.elf"
emit '-- emit: multiboot32-rollcall' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) rollcall kernel byte-identical to rollcall_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) rollcall kernel differs from rollcall_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" rollcall "$MKELF"; then ok "(B2) kernel carries the runtime-K process-table machinery (mods_count+MAXPROC bound, no ==const assert, indexed module-table/run-queue/TCB ops)"
else fail_test "(B2) kernel lacks the process-table construct (assert_rollcall failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "rollcall kernel is a valid x86 Multiboot image"
else fail_test "rollcall kernel is not a valid x86 Multiboot image"; fi

# ---- (D) FROZEN prior modes (purely additive) ----
fr_main() { case "$1" in mumbani) echo 'func main(): return module_byte() end';; *) echo 'func main(): return 0 end';; esac; }
for lk in tickover tandem mumbani; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || continue
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" "$(fr_main "$lk")" "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; rollcall is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- rollcall disturbed it"; fi
done

# ============================ SILICON (the runtime-K make-or-break) ============================
emu_ran=0
qemu_run() { # initrd-list out [kvm]
    local list="$1" out="$2" kvm="${3:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    timeout 120 qemu-system-x86_64 "${acc[@]}" -kernel "$MKELF" -initrd "$list" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -monitor none -m 64M >/dev/null 2>&1
}
if have_qemu; then
    emu_ran=1
    for K in $KRANGE; do
        qemu_run "$(klist "$K")" "$work/q$K"
        if python3 "$REF" grade "$work/q$K" "$KEND" "$K" >/dev/null 2>&1; then ok "(C) QEMU K=$K: the SAME kernel runs all $K programs -- every worker emits its held-back token (preemption + run-queue), the spinner emits le32(VA) (full-ctx survived)"
        else fail_test "(C) QEMU K=$K -> $(python3 "$REF" grade "$work/q$K" "$KEND" "$K" 2>&1 | tr '\n' ';')"; fi
    done
    # K>MAXPROC reject: a 9-module image is rejected at FOVER (no valid OWN-table dump -> grade RED)
    l9="$SP"; for i in $(seq 1 8); do python3 "$REF" modworker "$work/w9_$i.bin" 9 "$i"; l9="$l9,$work/w9_$i.bin"; done
    qemu_run "$l9" "$work/q9"
    if python3 "$REF" grade "$work/q9" "$KEND" 9 >/dev/null 2>&1; then fail_test "(C) QEMU K=9 (>MAXPROC) was NOT rejected -- the honest process-table cap is not enforced"
    else ok "(C) QEMU K=9 (>MAXPROC=8) is rejected at FOVER (no OWN-table dump) -- the honest table cap holds"; fi
    # DATA-DEPENDENCE (seed differential): the SAME kernel, fed K=5 workers baked with a DIFFERENT held-back seed,
    # emits the NEW seed's tokens; grading that run with the DEFAULT seed is RED -- so the worker output genuinely
    # follows the held-back BAKED tokens (the byte-pinned kernel is seed-agnostic; it cannot predict them), not the
    # echoed program count. (Closes the completeness-critic's "cross-K differential rode the echoed nprocs cell" gap.)
    SEEDB=0x0BEEF1; lb="$SP"; for i in 1 2 3 4; do python3 "$REF" modworker "$work/wb_$i.bin" 5 "$i" "$SEEDB"; lb="$lb,$work/wb_$i.bin"; done
    qemu_run "$lb" "$work/q5b"
    if python3 "$REF" grade "$work/q5b" "$KEND" 5 "$SEEDB" >/dev/null 2>&1; then ok "(C) QEMU K=5 seed-B: every worker emits the NEW held-back token set (data-dependence)"
    else fail_test "(C) QEMU K=5 seed-B -> $(python3 "$REF" grade "$work/q5b" "$KEND" 5 "$SEEDB" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" grade "$work/q5b" "$KEND" 5 >/dev/null 2>&1; then fail_test "(C) QEMU seed-B run graded GREEN with the DEFAULT seed -- worker output NOT data-dependent (vacuous)"
    else ok "(C) QEMU the seed-B run is RED graded with the default seed (worker output follows the held-back baked tokens)"; fi
    # hostile-peer
    qemu_run "$HW,$(klist 3 | cut -d, -f2-)" "$work/q.hw"
    if python3 "$REF" gradehostile "$work/q.hw" "$KEND" write >/dev/null 2>&1; then ok "(C-PEER) QEMU: hostile proc0 WRITING a peer region #PFs (err 7, CR2 in a peer window, RPL3)"
    else fail_test "(C-PEER) QEMU hostile-write -> $(python3 "$REF" gradehostile "$work/q.hw" "$KEND" write 2>&1 | tr '\n' ';')"; fi
    qemu_run "$HR,$(klist 3 | cut -d, -f2-)" "$work/q.hr"
    if python3 "$REF" gradehostile "$work/q.hr" "$KEND" read >/dev/null 2>&1; then ok "(C-PEER) QEMU: hostile proc0 READING a peer region #PFs (err 5)"
    else fail_test "(C-PEER) QEMU hostile-read -> $(python3 "$REF" gradehostile "$work/q.hr" "$KEND" read 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon): full-context indexed-TCB restore + iret-into-arbitrary-ring3-frame + per-proc flip ----
if have_kvm; then
    for K in $KRANGE; do
        qemu_run "$(klist "$K")" "$work/k$K" kvm
        if python3 "$REF" grade "$work/k$K" "$KEND" "$K" >/dev/null 2>&1; then ok "(C-KVM) real silicon K=$K: the runtime-K scheduler runs byte-identical on KVM"
        else fail_test "(C-KVM) KVM K=$K -> $(python3 "$REF" grade "$work/k$K" "$KEND" "$K" 2>&1 | tr '\n' ';')"; fi
    done
    qemu_run "$HW,$(klist 3 | cut -d, -f2-)" "$work/k.hw" kvm
    if python3 "$REF" gradehostile "$work/k.hw" "$KEND" write >/dev/null 2>&1; then ok "(C-PEER-KVM) real silicon: the hostile-peer WRITE #PF fires on KVM (err 7)"
    else fail_test "(C-PEER-KVM) KVM hostile-write -> $(python3 "$REF" gradehostile "$work/k.hw" "$KEND" write 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; K `module` lines) ----
bochs_run() { # K e9out
    local K="$1" e9="$2"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local d="$work/b.$K.d"; mkdir -p "$d"
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    # build the module list + grub.cfg module lines
    local modlines="" i; local cfg=" multiboot /boot/kernel.elf"
    cp "$SP" "$d/sp.bin"; cfg="$cfg
 module /boot/sp.bin"
    for i in $(seq 1 $((K-1))); do local w="$work/w_${K}_$i.bin"; cp "$w" "$d/w$i.bin"; cfg="$cfg
 module /boot/w$i.bin"; done
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp sp.bin mnt/boot/sp.bin
      for i in $(seq 1 $((K-1))); do sudo cp "w$i.bin" "mnt/boot/w$i.bin"; done
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n%s\n boot\n}\n' "$cfg" | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
      xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    python3 - "$d/bochs_out.txt" "$e9" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_run 3 "$work/b3"
    if python3 "$REF" grade "$work/b3" "$KEND" 3 >/dev/null 2>&1; then ok "(C) Bochs K=3: the runtime-K scheduler is byte-identical on the 2nd substrate (GRUB delivers 3 module lines)"
    else fail_test "(C) Bochs K=3 -> $(python3 "$REF" grade "$work/b3" "$KEND" 3 2>&1 | tr '\n' ';')"; fi
    bochs_run 5 "$work/b5"
    if python3 "$REF" grade "$work/b5" "$KEND" 5 >/dev/null 2>&1; then ok "(C) Bochs K=5: the SAME kernel runs a DIFFERENT program count on the 2nd substrate (5 module lines)"
    else fail_test "(C) Bochs K=5 -> $(python3 "$REF" grade "$work/b5" "$KEND" 5 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link46 (rollcall / RUNTIME-K PROCESS TABLE): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link46 rollcall / RUNTIME-K PROCESS TABLE)"
