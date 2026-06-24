#!/usr/bin/env bash
# Native-codegen Link 47 / tenement (kernel-arc link 31): bare-metal MEMORY RECLAMATION -- PHYSICAL PAGE REUSE.
# Built on the FROZEN rollcall lineage (runtime-K process table + run-queue). NEW vs rollcall: the kernel mints only
# M physical region pages (MSLOTS=2, baked) for N>M ring-3 programs; the remaining N-M procs start WAITING
# (alloc_lo==0). On SYS_EXIT a finished proc HANDS its region to the next WAITING proc -- the SAME physical page is
# REUSED over time, so N programs complete inside <=M pages. A NEW kernel emit mode `multiboot32-tenement` (additive
# on the frozen rollcall/tickover lineage). KERNEL-EMIT only; forcing probes are hand-assembled all-worker fixtures.
#
# The canonical config is N=6 workers, M=MSLOTS=2 (M baked into the kernel). All N procs are WORKERS (no spinner);
# each proc i emits its own HELD-BACK random 24-bit token (worker_tokens(N,seed)[i]) WREPS times then SYS_EXIT.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a manual KVM leg, vs tenement_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == tenement_ref.build_elf() AND carries the reclamation
#       machinery (assert_tenement: the cur->waiter region HANDOFF, the scheduler's WAITING-skip, MSLOTS-bounded
#       alloc) -- distinct from rollcall (which mints K pages, one per proc, and never hands one over).
#   (D) FROZEN: the prior emit modes are byte-identical -- multiboot32-rollcall == rollcall_ref.build_elf() AND
#       multiboot32-tickover == tickover_ref.build_elf() (proves tenement is PURELY ADDITIVE, disturbs nothing).
#   (C) SILICON make-or-break: the kernel runs N=6 ring-3 programs inside only M=2 physical pages -- EVERY worker
#       emits its held-back token (it RAN = it was handed a reclaimed page; a no-reclaim kernel starves the waiters),
#       the DISTINCT region pages hosting all N programs number <=M (genuine REUSE), each page reused over time.
#       N>M programs completing inside <=M pages is unfakeable without real physical-page handoff.
#   (C-DIFF) THE DIFFERENTIAL (the key forcing proof): the FROZEN rollcall kernel, fed the SAME 6 tenement workers,
#       grades RED -- rollcall mints 6 DISTINCT pages (one per proc) and CANNOT reclaim, so the <=M-page reuse
#       observable is genuinely NEW to tenement, not incidental to running K programs.
# The held-back MUTATION proof (run_native_codegen_link47_mutation.sh) proves each reclamation choice non-vacuous
# (M-noreclaim / M-noremap / M-noskip), structurally (assert_tenement False) and on silicon (gradeten RED).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/tenement_ref.py"
ROLL="$script_dir/rollcall_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
N="${TENEMENT_N:-6}"          # canonical: 6 workers
M="${TENEMENT_M:-2}"          # MSLOTS baked in the kernel = 2 physical region pages (M<N -> reuse)
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
kernel_substrate_scope() {
    local qemu=SKIPPED bochs=SKIPPED kvm="SKIPPED (/dev/kvm unavailable)"
    have_qemu && qemu=GREEN
    have_bochs && bochs=GREEN
    have_kvm && kvm=GREEN
    printf 'QEMU=%s, Bochs=%s, KVM=%s' "$qemu" "$bochs" "$kvm"
}

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
# build the N all-worker initrd list (proc i = worker i, emitting its own held-back token i)
WLIST=""; for i in $(seq 0 $((N-1))); do w="$work/tw$i.bin"; python3 "$REF" modworker_ten "$w" "$N" "$i"; [[ -z "$WLIST" ]] && WLIST="$w" || WLIST="$WLIST,$w"; done

MKELF="$work/tenement_kernel.elf"
emit '-- emit: multiboot32-tenement' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) tenement kernel byte-identical to tenement_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) tenement kernel differs from tenement_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" tenement "$MKELF"; then ok "(B2) kernel carries the reclamation machinery (cur->waiter region handoff, scheduler WAITING-skip, MSLOTS-bounded alloc)"
else fail_test "(B2) kernel lacks the reclamation construct (assert_tenement failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "tenement kernel is a valid x86 Multiboot image"
else fail_test "tenement kernel is not a valid x86 Multiboot image"; fi

# ---- (D) FROZEN prior modes (purely additive) ----
for lk in rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; tenement is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- tenement disturbed it"; fi
done

# ============================ SILICON (the reclamation make-or-break) ============================
emu_ran=0
qemu_run() { # initrd-list out [kvm]
    local list="$1" out="$2" kvm="${3:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    timeout 120 qemu-system-x86_64 "${acc[@]}" -kernel "$MKELF" -initrd "$list" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -monitor none -m 64M >/dev/null 2>&1
}
if have_qemu; then
    emu_ran=1
    qemu_run "$WLIST" "$work/q"
    if python3 "$REF" gradeten "$work/q" "$KEND" "$N" "$M" >/dev/null 2>&1; then ok "(C) QEMU N=$N M=$M: all $N programs run inside only $M physical pages -- every worker emits its held-back token (handed a reclaimed page), distinct region pages <=$M (genuine REUSE over time)"
    else fail_test "(C) QEMU N=$N -> $(python3 "$REF" gradeten "$work/q" "$KEND" "$N" "$M" 2>&1 | tr '\n' ';')"; fi
    # DATA-DEPENDENCE (seed differential): the SAME kernel, fed N workers baked with a DIFFERENT held-back seed,
    # emits the NEW seed's tokens; grading that run with the DEFAULT seed is RED -- so the worker output genuinely
    # follows the held-back BAKED tokens (the byte-pinned kernel is seed-agnostic; it cannot predict them).
    SEEDB=0x0BEEF1; lb=""; for i in $(seq 0 $((N-1))); do python3 "$REF" modworker_ten "$work/wb$i.bin" "$N" "$i" "$SEEDB"; [[ -z "$lb" ]] && lb="$work/wb$i.bin" || lb="$lb,$work/wb$i.bin"; done
    qemu_run "$lb" "$work/qb"
    if python3 "$REF" gradeten "$work/qb" "$KEND" "$N" "$M" "$SEEDB" >/dev/null 2>&1; then ok "(C) QEMU seed-B: every worker emits the NEW held-back token set (data-dependence)"
    else fail_test "(C) QEMU seed-B -> $(python3 "$REF" gradeten "$work/qb" "$KEND" "$N" "$M" "$SEEDB" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" gradeten "$work/qb" "$KEND" "$N" "$M" >/dev/null 2>&1; then fail_test "(C) QEMU seed-B run graded GREEN with the DEFAULT seed -- worker output NOT data-dependent (vacuous)"
    else ok "(C) QEMU the seed-B run is RED graded with the default seed (worker output follows the held-back baked tokens)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- THE DIFFERENTIAL (the key forcing proof): the FROZEN rollcall kernel cannot reclaim ----
# rollcall mints K=N DISTINCT region pages (one per proc) -- fed the SAME 6 tenement workers it grades RED under the
# tenement <=M-page reuse criterion. This proves the reclamation observable is genuinely NEW (not incidental to
# running K ring-3 programs, which rollcall already does).
if have_qemu && [[ -f "$ROLL" ]]; then
    RKELF="$work/rollcall_kernel.elf"; RKEND="$(python3 "$ROLL" kernelelf "$RKELF" none full)"
    timeout 120 qemu-system-x86_64 -cpu qemu64 -kernel "$RKELF" -initrd "$WLIST" -debugcon file:"$work/qdiff" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -monitor none -m 64M >/dev/null 2>&1
    if python3 "$REF" gradeten "$work/qdiff" "$RKEND" "$N" "$M" >/dev/null 2>&1; then fail_test "(C-DIFF) the frozen ROLLCALL kernel graded GREEN under the reclamation criterion -- reuse is NOT genuinely new (rollcall already reclaims?)"
    else ok "(C-DIFF) the frozen ROLLCALL kernel + the SAME $N tenement workers is RED -- rollcall mints $N distinct pages, CANNOT reclaim; tenement's <=$M-page reuse is a genuinely new observable"; fi
elif [[ ! -f "$ROLL" ]]; then
    fail_test "(C-DIFF) missing $ROLL -- cannot run the rollcall differential"
fi

# ---- KVM (real silicon): the reclaimed-page reuse on real hardware ----
if have_kvm; then
    qemu_run "$WLIST" "$work/k" kvm
    if python3 "$REF" gradeten "$work/k" "$KEND" "$N" "$M" >/dev/null 2>&1; then ok "(C-KVM) real silicon N=$N M=$M: the reclaimed-page reuse is byte-identical on KVM ($N programs inside $M physical pages on real hardware)"
    else fail_test "(C-KVM) KVM N=$N -> $(python3 "$REF" gradeten "$work/k" "$KEND" "$N" "$M" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; N `module` lines) ----
bochs_run() { # e9out
    local e9="$1"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local d="$work/b.d"; mkdir -p "$d"
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    local i; local cfg=" multiboot /boot/kernel.elf"
    for i in $(seq 0 $((N-1))); do cp "$work/tw$i.bin" "$d/w$i.bin"; cfg="$cfg
 module /boot/w$i.bin"; done
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf
      for i in $(seq 0 $((N-1))); do sudo cp "w$i.bin" "mnt/boot/w$i.bin"; done
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
    bochs_run "$work/b"
    if python3 "$REF" gradeten "$work/b" "$KEND" "$N" "$M" >/dev/null 2>&1; then ok "(C) Bochs N=$N M=$M: the reclamation is byte-identical on the 2nd substrate ($N programs inside $M physical pages; GRUB delivers $N module lines)"
    else fail_test "(C) Bochs N=$N -> $(python3 "$REF" gradeten "$work/b" "$KEND" "$N" "$M" 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link47 (tenement / MEMORY RECLAMATION): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
scope="$(kernel_substrate_scope)"
echo "PASS: stack/native_compile_fragment.herb (native-codegen link47 tenement / MEMORY RECLAMATION -- $N programs reuse $M physical pages; byte-pinned to tenement_ref.build_elf, white-box reclamation machinery, substrate scope: $scope, frozen-rollcall differential RED, additive on rollcall/tickover)"
