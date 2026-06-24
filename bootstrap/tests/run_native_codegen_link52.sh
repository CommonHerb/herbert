#!/usr/bin/env bash
# Native-codegen Link 52 / lethe (kernel-arc link 36): ALIAS-REMAP + TARGETED TLB INVALIDATION -- the first time the
# kernel must INVALIDATE a stale TLB entry. tessera (link 34) gave non-identity ALIASING; cleave (link 35) gave on-
# demand COPY-ON-WRITE. Both reload cr3 (a FULL flush) after every page-table edit, so a STALE per-page TLB entry was
# never reasoned about. lethe is the first observable that forces the TARGETED primitive: the kernel REMAPS a LIVE alias
# whose translation the CPU has CACHED; a cr3 flush is correct but heavy, the surgical fix is `invlpg [V]` (evict EXACTLY
# the one stale entry). WITHOUT it the CPU keeps the GHOST of the old frame -> a store through the remapped alias lands in
# the OLD frame and CORRUPTS a second alias that still maps it. ONE ring-3 prober (K=1, timer DISARMED via IF=0 so no cr3-
# reloading preempt masks the bug): three non-identity aliases A(0x600000),V(0x800000)->F, B(0xC00000)->F'; the prober
# WARMS V->F into the TLB, SYS_REMAP (int 0x30, eax=4) sets PTE[V]<-F'|7 + invlpg [V], the prober writes y to V then
# reads A,V,B. GENUINE: A==x (F untouched), V==y (fresh walk -> F'), B==y. A NEW kernel emit mode `multiboot32-lethe`
# (additive). KERNEL-EMIT only; the forcing prober is hand-assembled.
#
# Why GENUINELY OUTPUT-FORCED (within ONE execution; the cleave/homestead lesson -- a bare PTE edit is output-invisible,
# observable only via ALIASING): the corruption is observed in A, a DIFFERENT alias than the one written. With the stale
# entry, step-4's write y lands in F, so A (which still maps F) reads y instead of x -- A is CORRUPTED by the ghost. The
# cr3-flush forge (M-cr3insteadofinvlpg) is GREEN on output but the white-box assert_lethe REJECTS it (the remap arm must
# carry invlpg of V, NOT mov cr3), forcing the TARGETED primitive, not the heavy full flush.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a KVM real-silicon leg, vs lethe_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == lethe_ref.build_elf() AND carries the alias-remap machinery
#       (assert_lethe: the THREE non-identity alias installs PTE[A]<-F|7, PTE[V]<-F|7, PTE[B]<-F'|7 (A,V share F ->
#       ALIASED, F!=A,F!=V -> NON-IDENTITY, F'!=F -> a NEW frame); the SYS_REMAP arm PTE[V]<-F'|7 THEN `invlpg [V]`
#       (0F 01 3D <le32(V)>), contiguous; and NO `mov cr3,eax` (0F 22 D8) in the remap arm -- the TARGETED primitive).
#   (B3) the FROZEN tessera kernel FAILS assert_lethe (it installs two aliases of one F, no third alias, no remap arm).
#   (D) FROZEN: the prior baked-kernel modes are byte-identical (lethe is PURELY ADDITIVE).
#   (C) SILICON make-or-break: the prober warms V->F, the kernel remaps V->F' + invlpg [V], the prober writes y to V and
#       emits A,V,B. GREEN requires A==x (F untouched -- the remap moved V to a NEW frame, the write y did NOT corrupt F),
#       V==y (the post-remap write reached F' via a fresh walk), B==y (F''s second alias sees y).
#       SEED-DIFFERENTIAL: a DIFFERENT late-bound seed -> different x,y; grading with the default seed is RED.
#   (C-DIFF) THE DIFFERENTIAL: the FROZEN tessera kernel, fed the SAME prober, has NO remap arm + no SYS_REMAP -> RED.
# The held-back MUTATION proof (run_native_codegen_link52_mutation.sh) proves each piece non-vacuous (M-noinvlpg: drop
# the invlpg -> stale V->F -> A==y corruption, B==OLD_FP; M-cr3insteadofinvlpg: cr3 flush -> GREEN output but assert_lethe
# REJECT; M-noremap: drop the PTE[V]<-F' write -> A==y, B==OLD_FP; M-sameframe: remap V to F (F'==F) -> A==y; M-noinstall:
# no aliases -> the CPL3 store #PFs terminally).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/lethe_ref.py"
PRIOR_REF="$script_dir/tessera_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
SEED="${LETHE_SEED:-90}"         # the held-back seed byte fed late-bound over COM1 (decimal 90 = 0x5A)
SEEDB="${LETHE_SEEDB:-77}"       # the seed-differential byte (decimal 77 = 0x4D)
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
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

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
PROBER="$work/prober.bin"; python3 "$REF" modprober "$PROBER"   # K=1, LATE-BOUND seed (SYS_READ over COM1)

MKELF="$work/lethe_kernel.elf"
emit '-- emit: multiboot32-lethe' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) lethe kernel byte-identical to lethe_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) lethe kernel differs from lethe_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" assertlethe "$MKELF"; then ok "(B2) kernel carries the alias-remap machinery (assert_lethe: THREE non-identity alias installs PTE[A]<-F|7 + PTE[V]<-F|7 + PTE[B]<-F'|7 -- A,V ALIASED, F non-identity, F' a NEW frame; the SYS_REMAP arm PTE[V]<-F'|7 THEN invlpg [V] contiguous; NO mov cr3 in the remap arm -- the TARGETED primitive)"
else fail_test "(B2) kernel lacks the alias-remap machinery (assert_lethe failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "lethe kernel is a valid x86 Multiboot image"
else fail_test "lethe kernel is not a valid x86 Multiboot image"; fi
# the frozen tessera kernel must FAIL assert_lethe (it installs two aliases of one F, no third alias, no remap arm) -- the pin discriminates
python3 "$PRIOR_REF" kernelelf "$work/tess_for_assert.elf" none full >/dev/null 2>&1
if python3 "$REF" assertlethe "$work/tess_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen tessera kernel PASSED assert_lethe -- the white-box pin does not discriminate the alias-remap + invlpg"
else ok "(B3) the frozen tessera kernel FAILS assert_lethe (the third alias + the SYS_REMAP arm with invlpg are genuinely new)"; fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive) ----
for lk in cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; lethe is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- lethe disturbed it"; fi
done

# ============================ SILICON (the alias-remap + targeted-TLB-invalidation make-or-break) ============================
emu_ran=0
qemu_run() { # kernel-elf out seed timeout [kvm]
    local kel="$1" out="$2" sd="$3" to="$4" kvm="${5:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$sd" --delay 1 --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    timeout "$to" qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$PROBER" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
if have_qemu; then
    emu_ran=1
    qemu_run "$MKELF" "$work/q" "$SEED" 40
    if python3 "$REF" gradelethe "$work/q" "$KEND" "$SEED" >/dev/null 2>&1; then ok "(C) QEMU: the prober warms V->F, the kernel remaps V->F' + invlpg [V] (the targeted invalidation), the prober writes y to V and reads back A==x (F UNCHANGED -- no ghost corruption), V==y (fresh walk -> F'), B==y (F''s second alias sees y) -- alias-remap with targeted TLB invalidation"
    else fail_test "(C) QEMU -> $(python3 "$REF" gradelethe "$work/q" "$KEND" "$SEED" 2>&1 | tr '\n' ';')"; fi
    # SEED-DIFFERENTIAL: a different late-bound seed -> different x,y; grading with the default seed is RED
    qemu_run "$MKELF" "$work/qb" "$SEEDB" 40
    if python3 "$REF" gradelethe "$work/qb" "$KEND" "$SEEDB" >/dev/null 2>&1; then ok "(C) QEMU seed-B: A,V,B follow the NEW held-back seed's x,y (data-dependence)"
    else fail_test "(C) QEMU seed-B -> $(python3 "$REF" gradelethe "$work/qb" "$KEND" "$SEEDB" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" gradelethe "$work/qb" "$KEND" "$SEED" >/dev/null 2>&1; then fail_test "(C) QEMU seed-B run graded GREEN with the DEFAULT seed -- the words are NOT data-dependent (vacuous)"
    else ok "(C) QEMU the seed-B run is RED graded with the default seed (A,V,B follow the late-bound held-back seed)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- THE DIFFERENTIAL (the key forcing proof): the FROZEN tessera kernel has NO remap arm + no SYS_REMAP -> RED ----
# tessera installs two aliases of ONE frame F and has no SYS_REMAP handler. Fed the lethe prober, the prober's SYS_REMAP
# (int 0x30, eax=4) is an UNKNOWN syscall -> no remap occurs (V stays ->F) -> step-4's write y lands in F -> A==y
# (the witness frame corrupted), B never sees F' -> RED. The alias-remap + invlpg is genuinely new (not incidental to aliasing).
if have_qemu && [[ -f "$PRIOR_REF" ]]; then
    TKELF="$work/tessera_kernel.elf"; TKEND="$(python3 "$PRIOR_REF" kernelelf "$TKELF" none full)"
    qemu_run "$TKELF" "$work/qdiff" "$SEED" 20
    if python3 "$REF" gradelethe "$work/qdiff" "$TKEND" "$SEED" >/dev/null 2>&1; then fail_test "(C-DIFF) the frozen TESSERA kernel graded GREEN -- the alias-remap + invlpg is NOT genuinely new (tessera already remaps + invalidates?)"
    else ok "(C-DIFF) the frozen TESSERA kernel + the SAME prober is RED -- tessera has no SYS_REMAP / no remap arm, so V stays ->F, the post-remap write y lands in F and corrupts the witness A; lethe's alias-remap + targeted invalidation is a genuinely new observable"; fi
elif [[ ! -f "$PRIOR_REF" ]]; then
    fail_test "(C-DIFF) missing $PRIOR_REF -- cannot run the tessera differential"
fi

# ---- KVM (real silicon): the targeted invlpg on the real MMU (the iret-DS-null silicon class) ----
if have_kvm; then
    qemu_run "$MKELF" "$work/k" "$SEED" 40 kvm
    if python3 "$REF" gradelethe "$work/k" "$KEND" "$SEED" >/dev/null 2>&1; then ok "(C-KVM) real silicon: the alias remap + invlpg [V] is byte-identical on KVM (the CPU's own MMU evicts EXACTLY the one stale V->F entry so the post-remap write does a fresh walk to F', no ghost corruption of A)"
    else fail_test "(C-KVM) KVM -> $(python3 "$REF" gradelethe "$work/k" "$KEND" "$SEED" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; 1 module line) ----
bochs_run() { # out seed timeout
    local out="$1" sd="$2" to="$3"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"; local port; port="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$port" "$sd" --delay 2 --hold 40 > "$d/feed.log" 2>&1 &
    local bfp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" 2>/dev/null && break; sleep 0.05; done
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf
      sudo cp "$PROBER" mnt/boot/prober.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/prober.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL $to bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    kill "$bfp" 2>/dev/null; wait "$bfp" 2>/dev/null
    python3 - "$d/bochs_out.txt" "$out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_run "$work/b" "$SEED" 150
    if python3 "$REF" gradelethe "$work/b" "$KEND" "$SEED" >/dev/null 2>&1; then ok "(C) Bochs: the alias-remap + targeted invlpg is byte-identical on the 2nd substrate (GRUB delivers the prober; the remap V->F' + invlpg [V] + fresh-walk write reproduce)"
    else fail_test "(C) Bochs -> $(python3 "$REF" gradelethe "$work/b" "$KEND" "$SEED" 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link52 (lethe / ALIAS-REMAP + TARGETED TLB INVALIDATION): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link52 lethe / ALIAS-REMAP + TARGETED TLB INVALIDATION -- one ring-3 prober installs three non-identity aliases A,V->F and B->F', WARMS V->F into the TLB, then a SYS_REMAP (int 0x30) sets PTE[V]<-F'|7 and -- the link -- invlpg [V] (evict EXACTLY the one stale entry, NOT a heavy cr3 flush); the prober writes y to V (a fresh walk -> F') and reads A==x (F UNCHANGED -- no ghost corruption), V==y, B==y; the first time the kernel invalidates a stale TLB entry. Byte-pinned to lethe_ref.build_elf (binds the three alias installs + the remap arm's PTE[V]<-F'|7 THEN invlpg [V] contiguous + NO mov cr3 in the arm, not a permission flip), white-box assert_lethe, QEMU+KVM+Bochs GREEN, seed-differential data-dependent, frozen-tessera differential RED (no remap arm -> V stays ->F -> the write corrupts the witness A), additive on cleave/tessera/furlough/homestead/tenement/rollcall/tickover. Output-forced WITHIN one execution -- the corruption is observed in A, a DIFFERENT alias than the one written. HONEST SCOPE: ONE remapped alias + two witness aliases + two fixed frames (no general TLB shootdown, no SMP, no per-process address spaces / ELF loader))"
