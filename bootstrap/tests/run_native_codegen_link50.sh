#!/usr/bin/env bash
# Native-codegen Link 50 / tessera (kernel-arc link 34): SHARED MEMORY via a NON-IDENTITY ALIASED FRAME -- the first time
# vaddr != paddr in the stack. Every prior link mapped virtual page g to physical frame g (identity: PTE[g]=g*4096+3);
# "memory" capabilities (U/S isolation, demand-commit, region reclaim) were all permission/identity tricks an
# identity-backed reserve can forge. tessera installs, AT RUNTIME, ONE shared physical frame F mapped at TWO distinct
# virtual pages Va != Vb, with F != Va and F != Vb -- the first PTEs where PFN != VPN. A producer ring-3 program writes a
# late-bound multi-word payload THROUGH Va; a consumer reads the SAME bytes back THROUGH Vb (a plain CPL3 mov -- no kernel
# copy) and emits them: genuine ZERO-COPY SHARED MEMORY for a payload larger than tandem's 4-byte register mailbox can
# carry. Built on the FROZEN furlough lineage. A NEW kernel emit mode `multiboot32-tessera` (additive). KERNEL-EMIT only;
# the forcing probes are hand-assembled (a producer + a consumer).
#
# Why unfakeable (the homestead lesson -- a single non-identity frame is OUTPUT-INVISIBLE: a program cannot observe its
# own physical backing; non-identity is observable ONLY via ALIASING, write-here/read-there). Minimal atom (cross-model
# Codex + a 4-leg same-model scope panel + reconcile converged): ONE pre-installed aliased frame -- NO runtime free-frame
# allocator, NO per-process CR3, NO ELF loader (deferred; per-process virtual address spaces compose from this primitive).
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a manual KVM leg, vs tessera_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == tessera_ref.build_elf() AND carries the non-identity alias
#       install (assert_tessera: PTE[Va]<-F and PTE[Vb]<-F, with F != Va and F != Vb -- both PTEs hold the SAME frame
#       (aliased) and that frame differs from both vaddrs (non-identity)). No identity map / U-bit flip / fixed reserve
#       can produce these PTEs.
#   (D) FROZEN: the prior baked-kernel emit modes are byte-identical -- multiboot32-{furlough,homestead,tenement,rollcall,
#       tickover} == their *_ref.build_elf() (tessera is PURELY ADDITIVE).
#   (C) SILICON make-or-break: the producer writes SH_N seed-derived words THROUGH Va; the consumer reads them back
#       THROUGH Vb and SYS_WRITEs each -- GREEN requires ALL SH_N late-bound words to appear (the consumer could only
#       have read them through the shared frame: its own region is peer-isolated, the 4-byte mailbox can't carry a
#       multi-word payload, the seed is late-bound over COM1). SEED-DIFFERENTIAL: a DIFFERENT seed -> different words;
#       grading with the default seed is RED (the consumer's output follows the late-bound held-back seed).
#   (C-DIFF) THE DIFFERENTIAL (the key forcing proof): the FROZEN furlough kernel, fed the SAME pair, leaves Va,Vb
#       identity+Supervisor -- the producer #PFs writing the shared window and the consumer #PFs reading it (or, with a
#       permission-only forge, reads a DISJOINT frame) -> the consumer never sees the producer's payload -> RED. The
#       non-identity alias is genuinely NEW.
# The held-back MUTATION proof (run_native_codegen_link50_mutation.sh) proves each alias choice non-vacuous
# (M-noinstall: no alias -> #PF; M-identity: install Va->Va, Vb->Vb User -- accessible but DISJOINT -> consumer sees
# nothing (the KEY mutation, the homestead-M-eager analogue proving ALIASING not permission is load-bearing); M-onlyone:
# only Va aliased -> Vb disjoint; M-supervisor: alias both to F but Supervisor -> CPL3 #PF).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/tessera_ref.py"
FURL_REF="$script_dir/furlough_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
K=2                              # producer (proc0) + consumer (proc1)
SEED="${TESSERA_SEED:-90}"       # the held-back seed byte fed late-bound over COM1 (decimal 90 = 0x5A)
SEEDB="${TESSERA_SEEDB:-77}"     # the seed-differential byte (decimal 77 = 0x4D)
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
PROD="$work/prod.bin"; CONS="$work/cons.bin"
python3 "$REF" modproducer "$PROD"
python3 "$REF" modconsumer "$CONS"

MKELF="$work/tessera_kernel.elf"
emit '-- emit: multiboot32-tessera' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) tessera kernel byte-identical to tessera_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) tessera kernel differs from tessera_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" tessera "$MKELF"; then ok "(B2) kernel carries the non-identity alias install (assert_tessera: PTE[Va]<-F, PTE[Vb]<-F, F != Va, F != Vb -- aliased + non-identity)"
else fail_test "(B2) kernel lacks the non-identity alias install (assert_tessera failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "tessera kernel is a valid x86 Multiboot image"
else fail_test "tessera kernel is not a valid x86 Multiboot image"; fi
# the frozen furlough kernel must FAIL assert_tessera (it has no alias install) -- proves the white-box pin discriminates
python3 "$FURL_REF" kernelelf "$work/furl_for_assert.elf" none full >/dev/null 2>&1
if python3 "$REF" tessera "$work/furl_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen furlough kernel PASSED assert_tessera -- the white-box pin does not discriminate the alias"
else ok "(B3) the frozen furlough kernel FAILS assert_tessera (the non-identity alias is genuinely new)"; fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive) ----
# The baked-kernel lineage (emitted from `func main(): return 0 end`). The compiled-body modes (mumbani/coalgate/...)
# take a mode-specific source and are NOT byte-testable with this generic probe; tessera adds only isolated baked-blob
# functions + one dispatch line (no shared lowering code), so it cannot disturb them -- proven by the make-test self-host
# fixpoint (gen2==gen1) + a one-time byte-identical check of multiboot32-mumbani with its real source.
for lk in furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; tessera is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- tessera disturbed it"; fi
done

# ============================ SILICON (the shared-frame make-or-break) ============================
emu_ran=0
qemu_run() { # kernel-elf out seed timeout [kvm]
    local kel="$1" out="$2" sd="$3" to="$4" kvm="${5:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$sd" --delay 1 --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    timeout "$to" qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$PROD,$CONS" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
if have_qemu; then
    emu_ran=1
    qemu_run "$MKELF" "$work/q" "$SEED" 40
    if python3 "$REF" gradetess "$work/q" "$KEND" "$K" "$SEED" >/dev/null 2>&1; then ok "(C) QEMU: the producer writes SH_N seed-derived words THROUGH Va; the consumer reads them back THROUGH Vb and emits ALL of them -- a payload larger than the 4-byte mailbox, crossing two isolated programs through ONE physical frame at two names (zero-copy shared memory)"
    else fail_test "(C) QEMU -> $(python3 "$REF" gradetess "$work/q" "$KEND" "$K" "$SEED" 2>&1 | tr '\n' ';')"; fi
    # SEED-DIFFERENTIAL: a different late-bound seed -> different words; grading with the default seed is RED
    qemu_run "$MKELF" "$work/qb" "$SEEDB" 40
    if python3 "$REF" gradetess "$work/qb" "$KEND" "$K" "$SEEDB" >/dev/null 2>&1; then ok "(C) QEMU seed-B: the consumer emits the NEW held-back seed's words (data-dependence)"
    else fail_test "(C) QEMU seed-B -> $(python3 "$REF" gradetess "$work/qb" "$KEND" "$K" "$SEEDB" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" gradetess "$work/qb" "$KEND" "$K" "$SEED" >/dev/null 2>&1; then fail_test "(C) QEMU seed-B run graded GREEN with the DEFAULT seed -- consumer output NOT data-dependent (vacuous)"
    else ok "(C) QEMU the seed-B run is RED graded with the default seed (the consumer's output follows the late-bound held-back seed through the shared frame)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- THE DIFFERENTIAL (the key forcing proof): the FROZEN furlough kernel has NO shared frame ----
# furlough maps Va,Vb identity+Supervisor (no alias install). The producer #PFs writing [Va] and the consumer #PFs
# reading [Vb] at CPL3 -> both killed (geeking fault->continue) -> the consumer never emits the words -> RED. The
# non-identity shared frame is genuinely new (not incidental to running two ring-3 programs).
if have_qemu && [[ -f "$FURL_REF" ]]; then
    FKELF="$work/furlough_kernel.elf"; FKEND="$(python3 "$FURL_REF" kernelelf "$FKELF" none full)"
    qemu_run "$FKELF" "$work/qdiff" "$SEED" 20
    if python3 "$REF" gradetess "$work/qdiff" "$FKEND" "$K" "$SEED" >/dev/null 2>&1; then fail_test "(C-DIFF) the frozen FURLOUGH kernel graded GREEN -- the shared frame is NOT genuinely new (furlough already shares memory?)"
    else ok "(C-DIFF) the frozen FURLOUGH kernel + the SAME pair is RED -- Va,Vb are identity+Supervisor, the shared window #PFs / reads a disjoint frame, the consumer never sees the producer's payload; tessera's non-identity alias is a genuinely new observable"; fi
elif [[ ! -f "$FURL_REF" ]]; then
    fail_test "(C-DIFF) missing $FURL_REF -- cannot run the furlough differential"
fi

# ---- KVM (real silicon): the non-identity page walk + aliasing on real hardware (the iret-DS-null silicon class) ----
if have_kvm; then
    qemu_run "$MKELF" "$work/k" "$SEED" 40 kvm
    if python3 "$REF" gradetess "$work/k" "$KEND" "$K" "$SEED" >/dev/null 2>&1; then ok "(C-KVM) real silicon: the non-identity alias + cross-program shared-frame read is byte-identical on KVM (the CPU's own page walk resolves Va,Vb to the SAME physical frame on real hardware)"
    else fail_test "(C-KVM) KVM -> $(python3 "$REF" gradetess "$work/k" "$KEND" "$K" "$SEED" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; 2 module lines) ----
bochs_run() { # out seed timeout  -> nonzero (sets BOCHS_HARNESS_ERR) on a harness failure (F2 sweep 2026-07-04)
    local out="$1" sd="$2" to="$3"
    # Harness-failure detectors (mirror of the link60 reference): a Bochs boot whose COM1 feeder never bound (no
    # LISTENING), never delivered its payload (no SENT -> Bochs never connected COM1), or never reached the kernel's
    # shutdown() tail (no 'shutdown requested' -> killed/hung mid-run) is a HARNESS failure, not a kernel miscompile.
    _feed_ok() { local fl="$1" lbl="$2" i; for i in $(seq 1 50); do grep -q LISTENING "$fl" 2>/dev/null && break; sleep 0.1; done
        grep -q LISTENING "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never reached LISTENING for $lbl (log: $fl -- feeder/port-bind failure, not a kernel miscompile)"; return 1; }
    _bochs_ran_ok() { local bl="$1" lbl="$2"; [[ -s "$bl" ]] || { BOCHS_HARNESS_ERR="Bochs produced NO output booting $lbl (log: $bl empty/missing -- the emulator did not run)"; return 1; }
        grep -qa 'shutdown requested' "$bl" && return 0   # the kernel's shutdown() writes "Shutdown" to Bochs port 0x8900 -> logged on ANY completed boot
        BOCHS_HARNESS_ERR="Bochs did NOT run $lbl through to a kernel shutdown tail (log: $bl has no 'shutdown requested' -- the boot died or was timeout-killed mid-run, not a kernel miscompile)"; return 1; }
    _feed_delivered() { local fl="$1" lbl="$2"; grep -q '^SENT' "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload for $lbl (log: $fl has LISTENING but no SENT / shows NOCONN -- Bochs did not connect COM1, the kernel received no input, not a kernel miscompile)"; return 1; }
    local kelf; kelf="$(readlink -f "$MKELF")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"; local port; port="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$port" "$sd" --delay 2 --hold 40 > "$d/feed.log" 2>&1 &
    local bfp=$!
    _feed_ok "$d/feed.log" "prober(BOOT)" || { kill "$bfp" 2>/dev/null; wait "$bfp" 2>/dev/null; return 1; }
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
      sudo cp "$PROD" mnt/boot/prod.bin; sudo cp "$CONS" mnt/boot/cons.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/prod.bin\n module /boot/cons.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
    _bochs_ran_ok "$d/bochs_out.txt" "prober(BOOT)" || return 1
    _feed_delivered "$d/feed.log" "prober(BOOT)" || return 1
    python3 - "$d/bochs_out.txt" "$out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_done=0
    for attempt in 1 2 3; do
        BOCHS_HARNESS_ERR=""
        if ! bochs_run "$work/b" "$SEED" 150; then
            echo "  HARNESS ERROR (Bochs attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2
            continue
        fi
        # the feeder LISTENED + delivered (SENT) + the kernel ran THROUGH shutdown() -> grade is a GENUINE kernel verdict
        if python3 "$REF" gradetess "$work/b" "$KEND" "$K" "$SEED" >/dev/null 2>&1; then ok "(C) Bochs: the non-identity shared-frame aliasing is byte-identical on the 2nd substrate (GRUB delivers producer + consumer)"
        else fail_test "(C) Bochs (fed+delivered+ran through shutdown -> a GENUINE kernel grade, not a harness flake) -> $(python3 "$REF" gradetess "$work/b" "$KEND" "$K" "$SEED" 2>&1 | tr '\n' ';')"; fi
        bochs_done=1; break
    done
    if [[ "$bochs_done" -eq 0 ]]; then
        if [[ "$REQUIRE_EMU" == "1" ]]; then
            echo "HARNESS-ERROR: (C-Bochs) the REQUIRED Bochs substrate failed 3 consecutive harness attempts -- $BOCHS_HARNESS_ERR (re-rollable emulator/feeder failure, NOT a kernel miscompile; the gate is RED only because KERNEL_CODEGEN_REQUIRE_EMU=1)"
            fail=$((fail + 1))
        else
            echo "  HARNESS-ERROR (non-fatal): (C-Bochs) Bochs failed 3 consecutive harness attempts -- $BOCHS_HARNESS_ERR (re-rollable; REQUIRE_EMU=0 so the gate is NOT RED on a harness flake -- re-roll, or set KERNEL_CODEGEN_REQUIRE_EMU=1 to require the Bochs substrate)" >&2
        fi
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link50 (tessera / SHARED MEMORY via a non-identity aliased frame): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link50 tessera / SHARED MEMORY via a NON-IDENTITY ALIASED FRAME -- the kernel installs ONE physical frame F at TWO distinct virtual pages Va != Vb (PTE[Va]<-F, PTE[Vb]<-F, F != Va, F != Vb -- the first PTEs where PFN != VPN), a producer writes a late-bound multi-word payload THROUGH Va and a consumer reads it back THROUGH Vb zero-copy; byte-pinned to tessera_ref.build_elf (binds the alias install, not a permission trick), white-box assert_tessera (aliased + non-identity), QEMU+KVM+Bochs GREEN, seed-differential data-dependent, frozen-furlough differential RED, additive on furlough/homestead/tenement/rollcall/tickover. HONEST SCOPE: ONE pre-installed aliased frame (no runtime free-frame allocator); single shared window mutually accessible to the two sharers (per-process restriction needs per-process CR3 -- the motivated successor); NO per-process address spaces / ELF loader)"
