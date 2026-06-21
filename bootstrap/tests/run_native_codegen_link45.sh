#!/usr/bin/env bash
# Native-codegen Link 45 / tickover (kernel-arc link 29): FAIR TIMER-PREEMPTION BETWEEN TWO PROGRAMS -- a program
# that NEVER yields cannot starve its peer. The step from tandem's COOPERATIVE two-program scheduler to genuine
# PREEMPTIVE multitasking (bluefield's ring-0 full-GP switch lifted to ring-3 across tandem's two paging-isolated
# programs -- the "full architectural context switch" bluefield deferred). A NEW kernel emit mode
# `multiboot32-tickover` (additive on the frozen tandem lineage): periodic PIT + IRQ0 unmasked + IF=1 module frames
# + a vec-0x20 PREEMPTIVE handler that saves/restores the FULL preempted context (GP set + eflags + eip + useresp --
# a WIDENED TCB vs tandem's cooperative {eip,esp,ebp}) + a per-program User/Supervisor PTE-flip. KERNEL-EMIT only;
# the forcing probes are hand-assembled ref fixtures (a stack-machine COMPILED module holds no live reg to lose, so
# only a hand-asm probe can EXERCISE full-GP+eflags survival -- geeking's fixture-probe pattern).
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a manual KVM leg, vs tickover_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == tickover_ref.build_elf() AND carries the preemptive
#       machinery (assert_tickover: mods==2 + periodic-PIT mode-2 arm + IF=1 frame + pusha vec-0x20 handler +
#       a per-program eflags TCB cell) -- distinct from tandem's cooperative kernel.
#   (C) SILICON: A (register-carry SPINNER, never yields) + B (WORKER, N held-back random words). B emits all N
#       words (it RAN despite A never yielding = no starvation -> preemption happened); A emits le32(VA) (its edx +
#       DF survived EVERY preempt = full-context save/restore); switch counter >= 2. gx vs gy differ; gx-as-gy RED.
#   (C-PEER) HOSTILE-PEER #PF: a variant A that writes B's region #PFs (err 7), a reader #PFs (err 5), CR2 in B's
#       window, RPL3 -- the un-fakeable PEER-isolation proof, caught by geeking fault->continue. KVM-load-bearing
#       (iret-into-a-different-ring-3-frame + the PTE-flip on real silicon).
#   (D) FROZEN: tandem kernel + module-tandem/mmj/mumbani + multiboot32-mumbani still byte-identical (purely additive).
# The held-back MUTATION proof (run_native_codegen_link45_mutation.sh) proves every design choice non-vacuous
# (M-coop / M-noswitch / M-minimal / M-noeflags / M-noflip).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
REF="$script_dir/tickover_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi

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

# ---- reference artifacts (the oracle) ----
REFA="$work/ref_A.bin"; python3 "$REF" modA "$REFA"
REFB="$work/ref_B.bin"; python3 "$REF" modB "$REFB"
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK" none full)"
REFH="$work/ref_hostile.bin"; python3 "$REF" modhostile "$REFH"
REFHR="$work/ref_hostile_read.bin"; python3 "$REF" modhostileread "$REFHR"

emit() { # marker prog outfile label -> writes outfile on accept; fail on reject
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

MKELF="$work/tickover_kernel.elf"
emit '-- emit: multiboot32-tickover' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) tickover kernel byte-identical to tickover_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) tickover kernel differs from tickover_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" tickover "$MKELF"; then ok "(B2) kernel carries the preemptive machinery (mods==2 + periodic PIT + IF=1 + pusha vec-0x20 handler + eflags TCB)"
else fail_test "(B2) kernel lacks the preemptive construct (assert_tickover failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "tickover kernel is a valid x86 Multiboot image"
else fail_test "tickover kernel is not a valid x86 Multiboot image"; fi

# ---- (D) FROZEN prior modes (purely additive) ----
TANREF="$script_dir/tandem_ref.py"; MUMREF="$script_dir/mumbani_ref.py"; MMJREF="$script_dir/mmj_ref.py"
python3 "$TANREF" kernelelf "$work/tan.refk" none full >/dev/null 2>&1
if emit '-- emit: multiboot32-tandem' 'func main(): return 0 end' "$work/tan.k" tank && cmp -s "$work/tan.k" "$work/tan.refk"; then ok "(D1) multiboot32-tandem kernel byte-identical (frozen; tickover is additive)"
else fail_test "(D1) multiboot32-tandem kernel drifted -- tickover disturbed it"; fi
python3 "$TANREF" modA "$work/tanA.ref" 2>/dev/null
if emit '-- emit: module-tandem' "$(python3 "$TANREF" srcA)" "$work/tanA.bin" tanA && cmp -s "$work/tanA.bin" "$work/tanA.ref"; then ok "(D2) module-tandem (program A) byte-identical (frozen)"
else fail_test "(D2) module-tandem drifted"; fi
python3 "$MUMREF" module "$work/mum.ref" 2>/dev/null
if emit '-- emit: module-mumbani' "$(python3 "$MUMREF" src)" "$work/mum.bin" mumd && cmp -s "$work/mum.bin" "$work/mum.ref"; then ok "(D3) module-mumbani byte-identical (frozen)"
else fail_test "(D3) module-mumbani drifted"; fi
python3 "$MUMREF" kernelelf "$work/mumk.ref" >/dev/null 2>&1
if emit '-- emit: multiboot32-mumbani' 'func main(): return module_byte() end' "$work/mumk.bin" mumkd && cmp -s "$work/mumk.bin" "$work/mumk.ref"; then ok "(D4) multiboot32-mumbani kernel byte-identical (frozen)"
else fail_test "(D4) multiboot32-mumbani kernel drifted"; fi

# ============================ SILICON (dual substrate + KVM) ============================
emu_ran=0
qemu_feed() { # kernel kind out [kvm]
    local kelf="$1" kind="$2" out="$3" kvm="${4:-}"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" $stream --hold 12 > "$d/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    local acc=(); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host) || acc=(-cpu qemu64)
    timeout 120 qemu-system-x86_64 "${acc[@]}" -kernel "$kelf" -initrd "$REFA,$REFB" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
qemu_hostile() { # kernel hostileA out [kvm]
    local kelf="$1" ha="$2" out="$3" kvm="${4:-}"
    local acc=(); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host) || acc=(-cpu qemu64)
    timeout 60 qemu-system-x86_64 "${acc[@]}" -kernel "$kelf" -initrd "$ha,$REFB" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -monitor none -m 64M >/dev/null 2>&1
}

if have_qemu; then
    emu_ran=1
    qemu_feed "$MKELF" gx "$work/q.gx"
    if python3 "$REF" grade "$work/q.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C) QEMU: the spinner is PREEMPTED + the worker runs to completion -- A emits le32(VA) (GP+eflags survived), B emits N held-back words (no starvation) (gx)"
    else fail_test "(C) QEMU gx -> $(python3 "$REF" grade "$work/q.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
    qemu_feed "$MKELF" gy "$work/q.gy"
    if python3 "$REF" grade "$work/q.gy" "$KEND" gy >/dev/null 2>&1; then ok "(C) QEMU: a DIFFERENT held-back stream (gy) -- the X!=Y differential"
    else fail_test "(C) QEMU gy -> $(python3 "$REF" grade "$work/q.gy" "$KEND" gy 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" grade "$work/q.gx" "$KEND" gy >/dev/null 2>&1; then fail_test "(C) QEMU gx graded GREEN as gy -- B output NOT data-dependent (make-or-break vacuous)"
    else ok "(C) QEMU gx is RED graded as gy (the worker's output genuinely follows the held-back data)"; fi
    qemu_hostile "$MKELF" "$REFH" "$work/q.hw"
    if python3 "$REF" gradehostile "$work/q.hw" "$KEND" write >/dev/null 2>&1; then ok "(C-PEER) QEMU: hostile A WRITING B's region #PFs (exact err 7, CR2 in B's window, RPL3) -- integrity isolation under preemption"
    else fail_test "(C-PEER) QEMU hostile-write -> $(python3 "$REF" gradehostile "$work/q.hw" "$KEND" write 2>&1 | tr '\n' ';')"; fi
    qemu_hostile "$MKELF" "$REFHR" "$work/q.hr"
    if python3 "$REF" gradehostile "$work/q.hr" "$KEND" read >/dev/null 2>&1; then ok "(C-PEER) QEMU: hostile A READING B's region #PFs (exact err 5) -- confidentiality isolation under preemption"
    else fail_test "(C-PEER) QEMU hostile-read -> $(python3 "$REF" gradehostile "$work/q.hr" "$KEND" read 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon): full-context save/restore + iret-into-a-different-ring3-frame + PTE-flip ----
if have_kvm; then
    qemu_feed "$MKELF" gx "$work/k.gx" kvm
    if python3 "$REF" grade "$work/k.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C-KVM) real silicon: the preemptive full-context switch runs byte-identical on KVM (gx)"
    else fail_test "(C-KVM) KVM gx -> $(python3 "$REF" grade "$work/k.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
    qemu_hostile "$MKELF" "$REFH" "$work/k.hw" kvm
    if python3 "$REF" gradehostile "$work/k.hw" "$KEND" write >/dev/null 2>&1; then ok "(C-PEER-KVM) real silicon: the hostile-peer WRITE #PF fires on KVM (err 7)"
    else fail_test "(C-PEER-KVM) KVM hostile-write -> $(python3 "$REF" gradehostile "$work/k.hw" "$KEND" write 2>&1 | tr '\n' ';')"; fi
    qemu_hostile "$MKELF" "$REFHR" "$work/k.hr" kvm
    if python3 "$REF" gradehostile "$work/k.hr" "$KEND" read >/dev/null 2>&1; then ok "(C-PEER-KVM) real silicon: the hostile-peer READ #PF fires on KVM (err 5)"
    else fail_test "(C-PEER-KVM) KVM hostile-read -> $(python3 "$REF" gradehostile "$work/k.hr" "$KEND" read 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; two `module` lines) ----
bochs_run() { # kind e9out
    local kind="$1"; local e9="$2"
    local ma; ma="$(readlink -f "$REFA")"; local mb; mb="$(readlink -f "$REFB")"; local kelf; kelf="$(readlink -f "$MKELF")"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local d="$work/b.$kind.d"; mkdir -p "$d"
    local port; port=$(free_port)
    python3 "$feeder" "$port" $stream --hold 40 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
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
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$ma" mnt/boot/a.bin; sudo cp "$mb" mnt/boot/b.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/a.bin\n module /boot/b.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 32
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    python3 - "$d/bochs_out.txt" "$e9" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_run gx "$work/b.gx"
    if python3 "$REF" grade "$work/b.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C) Bochs: the preemptive run is byte-identical on the 2nd substrate (gx; GRUB delivers two module lines)"
    else fail_test "(C) Bochs gx -> $(python3 "$REF" grade "$work/b.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link45 (tickover / FAIR TIMER-PREEMPTION): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link45 tickover / TIMER-PREEMPTION)"
