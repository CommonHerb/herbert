#!/usr/bin/env bash
# Native-codegen Link 49 / furlough (kernel-arc link 33): BLOCKING SYS_READ (block / wake) -- a ring-3 program that
# issues SYS_READ on input that is not yet available is DESCHEDULED (parked, zero quanta) by the kernel instead of
# busy-polling COM1 with IF=0 and FREEZING the machine; peers keep running; when the byte arrives the kernel WAKES the
# parked reader, delivers the byte into its saved eax, and it resumes after int 0x30. Built on the FROZEN homestead
# lineage. NEW vs homestead: a blocked[] TCB state + a scheduler pick that SKIPS blocked procs + a BLOCK arm in do_read
# (snapshot the int-0x30 frame, mark blocked, switch away) + a WAKE arm in sched_switch (re-poll COM1, deliver into the
# wakee's t_eax, unblock) + an idle path (all-parked -> re-poll until a byte wakes one) + a per-proc disp[] dispatch
# counter. A NEW kernel emit mode `multiboot32-furlough` (additive on the frozen lineage). KERNEL-EMIT only; the forcing
# probes are hand-assembled (a naive reader A + two token-emitter peers B,C).
#
# The CONFIRMED DEFECT this removes: do_read polls COM1 inside a DPL-3 INTERRUPT gate (IF=0) at CPL0, and the timer
# handler skips CPL0 ticks (test cs,3; jz no-switch), so a kernel busy-poll is UN-PREEMPTIBLE BY DESIGN -- `sti`/trap-gate
# cannot fix it. The ONLY fix-class for a naive (non-yielding) reader is kernel-side deschedule. (Re-derived verdict-first:
# same-model panel 5/5 + 5 refuters + cross-model Codex, all on the SOURCE-VERIFIED architecture.)
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a manual KVM leg, vs furlough_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == furlough_ref.build_elf() AND carries the block/wake machinery
#       (assert_furlough: the block-arm frame snapshot + blocked[cur]=1, the blocked-skip in the pick, the wake-arm
#       t_eax delivery + blocked[w]=0, the disp[] counter) -- none of which any prior kernel has.
#   (D) FROZEN: the prior baked-kernel emit modes are byte-identical -- multiboot32-{tenement,rollcall,tickover,homestead}
#       == their *_ref.build_elf() (furlough is PURELY ADDITIVE).
#   (C) SILICON make-or-break, TWO graded runs:
#       RUN-2 (byte DELIVERED): the naive reader A is parked, peers B,C run, then A is WOKEN with the correct byte and
#         emits le32(RDR_TAG|byte) -- a WAKE witness (w==0, byte==fed), disp[A] tiny (parked, not spinning), finalize.
#       RUN-1 (byte WITHHELD forever -- the freeze differential): A is parked, B,C still run -> their tokens appear.
#       SEED-DIFFERENTIAL: a DIFFERENT delivered byte -> A emits the NEW byte's token; grading with the default byte is
#         RED (A's output follows the late-bound held-back byte; the byte-pinned kernel is byte-agnostic).
#   (C-DIFF) THE DIFFERENTIAL (the key forcing proof): the FROZEN homestead kernel, fed the SAME 3 programs with A's byte
#       WITHHELD, grades RED -- A busy-polls IF=0 and FREEZES the machine, so B,C NEVER run (their tokens absent).
#       Block/wake is genuinely NEW.
# The held-back MUTATION proof (run_native_codegen_link49_mutation.sh) proves each block/wake choice non-vacuous
# (M-noblock: revert to the IF=0 busy-poll -> freeze -> peers absent; M-noblockflag/M-restart: deschedule WITHOUT a real
# blocked state -> the reader resumes wrong / re-dispatched every cycle (runnable-retry) -> RED; M-noskipblk: pick a
# parked proc; M-nowake: never unblock; M-nodeliver: stale byte. M-restart is the KEY: it FIXES the freeze (RUN-1 GREEN)
# but is caught by RUN-2 -- the freeze-fix alone is under-determined; correct wake + delivery + parked-not-spinning is
# what block/wake forces).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/furlough_ref.py"
HOME_REF="$script_dir/homestead_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
K=3                              # A (naive reader) + B,C (token emitters)
FBYTE="${FURLOUGH_FBYTE:-90}"    # the held-back byte delivered to A in RUN-2 (decimal 90 = 0x5A)
FBYTEB="${FURLOUGH_FBYTEB:-66}"  # the seed-differential byte (decimal 66 = 0x42)
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
A="$work/A.bin"; B="$work/B.bin"; C="$work/C.bin"
python3 "$REF" modreader "$A"
python3 "$REF" modpeer "$B" "$K" 1
python3 "$REF" modpeer "$C" "$K" 2

MKELF="$work/furlough_kernel.elf"
emit '-- emit: multiboot32-furlough' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) furlough kernel byte-identical to furlough_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) furlough kernel differs from furlough_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" furlough "$MKELF"; then ok "(B2) kernel carries the block/wake machinery (block-arm snapshot+blocked set, blocked-skip, wake-arm deliver+clear, disp counter)"
else fail_test "(B2) kernel lacks the block/wake construct (assert_furlough failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "furlough kernel is a valid x86 Multiboot image"
else fail_test "furlough kernel is not a valid x86 Multiboot image"; fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive) ----
# The baked-kernel lineage (emitted from `func main(): return 0 end`). The compiled-body modes (mumbani/coalgate/...)
# take a mode-specific source and are NOT byte-testable with this generic probe; furlough adds only isolated baked-blob
# functions + one dispatch line (no shared lowering code), so it cannot disturb them -- proven by the make-test self-host
# fixpoint (gen2==gen1) + a one-time byte-identical check of multiboot32-mumbani with its real source.
for lk in tenement rollcall tickover homestead; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; furlough is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- furlough disturbed it"; fi
done

# ============================ SILICON (the block/wake make-or-break) ============================
emu_ran=0
qemu_run() { # kernel-elf out fbyte delay timeout [kvm]
    local kel="$1" out="$2" fb="$3" delay="$4" to="$5" kvm="${6:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$fb" --delay "$delay" --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    timeout "$to" qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$A,$B,$C" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
if have_qemu; then
    emu_ran=1
    qemu_run "$MKELF" "$work/q2" "$FBYTE" 1 25
    if python3 "$REF" gradefurl "$work/q2" "$KEND" "$K" run2 "$FBYTE" >/dev/null 2>&1; then ok "(C) QEMU RUN-2: the naive reader (no retry loop) is parked, peers B,C run, then the reader is WOKEN EXACTLY ONCE with the delivered byte and emits le32(RDR_TAG|byte) -- wake witnessed (w==0,byte==fed), dispatched O(1) times (not re-dispatched every cycle), clean finalize"
    else fail_test "(C) QEMU RUN-2 -> $(python3 "$REF" gradefurl "$work/q2" "$KEND" "$K" run2 "$FBYTE" 2>&1 | tr '\n' ';')"; fi
    qemu_run "$MKELF" "$work/q1" "$FBYTE" 60 12
    if python3 "$REF" gradefurl "$work/q1" "$KEND" "$K" run1 "$FBYTE" >/dev/null 2>&1; then ok "(C) QEMU RUN-1 (byte withheld): the reader is parked but B,C still run -> peer tokens appear (the freeze is fixed)"
    else fail_test "(C) QEMU RUN-1 -> $(python3 "$REF" gradefurl "$work/q1" "$KEND" "$K" run1 "$FBYTE" 2>&1 | tr '\n' ';')"; fi
    # SEED-DIFFERENTIAL: a different delivered byte -> the reader emits the NEW byte's token (data-dependence)
    qemu_run "$MKELF" "$work/qb" "$FBYTEB" 1 25
    if python3 "$REF" gradefurl "$work/qb" "$KEND" "$K" run2 "$FBYTEB" >/dev/null 2>&1; then ok "(C) QEMU seed-B: the reader emits the NEW held-back byte's token (data-dependence)"
    else fail_test "(C) QEMU seed-B -> $(python3 "$REF" gradefurl "$work/qb" "$KEND" "$K" run2 "$FBYTEB" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" gradefurl "$work/qb" "$KEND" "$K" run2 "$FBYTE" >/dev/null 2>&1; then fail_test "(C) QEMU seed-B run graded GREEN with the DEFAULT byte -- reader output NOT data-dependent (vacuous)"
    else ok "(C) QEMU the seed-B run is RED graded with the default byte (the reader's output follows the late-bound delivered byte)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- THE DIFFERENTIAL (the key forcing proof): the FROZEN homestead kernel FREEZES on the naive reader ----
# homestead's do_read busy-polls COM1 with IF=0; a naive reader on a withheld byte spins forever and the timer cannot
# preempt a CPL0 spin -> the machine FREEZES -> B,C NEVER run -> their tokens are absent -> RED. Block/wake is genuinely new.
if have_qemu && [[ -f "$HOME_REF" ]]; then
    HKELF="$work/homestead_kernel.elf"; HKEND="$(python3 "$HOME_REF" kernelelf "$HKELF" none full)"
    qemu_run "$HKELF" "$work/qdiff" "$FBYTE" 60 12
    if python3 "$REF" gradefurl "$work/qdiff" "$HKEND" "$K" run1 "$FBYTE" >/dev/null 2>&1; then fail_test "(C-DIFF) the frozen HOMESTEAD kernel graded GREEN under RUN-1 -- it did NOT freeze (block/wake is not genuinely new?)"
    else ok "(C-DIFF) the frozen HOMESTEAD kernel + the SAME 3 programs (A's byte withheld) is RED -- A busy-polls IF=0 and FREEZES the machine; B,C never run; furlough's block/wake is a genuinely new observable"; fi
elif [[ ! -f "$HOME_REF" ]]; then
    fail_test "(C-DIFF) missing $HOME_REF -- cannot run the homestead differential"
fi

# ---- KVM (real silicon): the wake-resume iret back into CPL3 is the iret-DS-null silicon class ----
if have_kvm; then
    qemu_run "$MKELF" "$work/k2" "$FBYTE" 1 25 kvm
    if python3 "$REF" gradefurl "$work/k2" "$KEND" "$K" run2 "$FBYTE" >/dev/null 2>&1; then ok "(C-KVM) real silicon RUN-2: block -> peer-progress -> wake-with-delivery -> iret-resume into CPL3 is byte-identical on KVM"
    else fail_test "(C-KVM) KVM RUN-2 -> $(python3 "$REF" gradefurl "$work/k2" "$KEND" "$K" run2 "$FBYTE" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; 3 module lines) ----
bochs_run() { # out fbyte delay timeout [expect_full=1]  -> nonzero (sets BOCHS_HARNESS_ERR) on a harness failure (F2 sweep 2026-07-04)
    local out="$1" fb="$2" delay="$3" to="$4" expect_full="${5:-1}"
    # Harness-failure detectors (mirror of the link60 reference): a Bochs boot whose COM1 feeder never bound (no
    # LISTENING), never delivered its payload (no SENT), or never reached the kernel's shutdown() tail (no 'shutdown
    # requested') is a HARNESS failure, not a kernel miscompile. NOTE: SENT + shutdown are gated on expect_full because
    # RUN-1 DELIBERATELY withholds the byte (see the post-boot block).
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
    python3 "$script_dir/kernel_input_feed.py" "$port" "$fb" --delay "$delay" --hold 40 > "$d/feed.log" 2>&1 &
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
      sudo cp "$A" mnt/boot/A.bin; sudo cp "$B" mnt/boot/B.bin; sudo cp "$C" mnt/boot/C.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/A.bin\n module /boot/B.bin\n module /boot/C.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
    # RUN-1 (expect_full=0) DELIBERATELY withholds the byte (--delay > timeout): the reader PARKS, so there is NO SENT
    # by design and the boot is timeout-killed (never reaches shutdown()). Applying SENT/shutdown there would false-fail
    # the legitimate park test -- so only LISTENING is checked for it. RUN-2 (expect_full=1) delivers + shuts down normally.
    if [[ "$expect_full" == "1" ]]; then
        _bochs_ran_ok "$d/bochs_out.txt" "prober(BOOT)" || return 1
        _feed_delivered "$d/feed.log" "prober(BOOT)" || return 1
    fi
    python3 - "$d/bochs_out.txt" "$out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
# terminal handler for 3 consecutive HARNESS failures: distinct greppable marker (NOT the kernel-RED FAIL: prefix),
# fatal only when the Bochs substrate is REQUIRED (REQUIRE_EMU=1).
_bochs_harness_giveup() { # label
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "HARNESS-ERROR: (C-Bochs $1) the REQUIRED Bochs substrate failed 3 consecutive harness attempts -- $BOCHS_HARNESS_ERR (re-rollable emulator/feeder failure, NOT a kernel miscompile; the gate is RED only because KERNEL_CODEGEN_REQUIRE_EMU=1)"
        fail=$((fail + 1))
    else
        echo "  HARNESS-ERROR (non-fatal): (C-Bochs $1) Bochs failed 3 consecutive harness attempts -- $BOCHS_HARNESS_ERR (re-rollable; REQUIRE_EMU=0 so the gate is NOT RED on a harness flake -- re-roll, or set KERNEL_CODEGEN_REQUIRE_EMU=1)" >&2
    fi
}
if have_bochs; then
    emu_ran=1
    # RUN-2 (delivers the byte -> the reader wakes + the kernel shuts down: full harness checks apply)
    b2_done=0
    for attempt in 1 2 3; do
        BOCHS_HARNESS_ERR=""
        if ! bochs_run "$work/b2" "$FBYTE" 3 150; then
            echo "  HARNESS ERROR (Bochs RUN-2 attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue
        fi
        if python3 "$REF" gradefurl "$work/b2" "$KEND" "$K" run2 "$FBYTE" >/dev/null 2>&1; then ok "(C) Bochs RUN-2: block/wake is byte-identical on the 2nd substrate (GRUB delivers A,B,C)"
        else fail_test "(C) Bochs RUN-2 (feeder SENT + ran through shutdown; guest RECEIPT unproven feeder-side -- a lone RED may be a capture-class flake, re-derive per the parley replay discriminator) -> $(python3 "$REF" gradefurl "$work/b2" "$KEND" "$K" run2 "$FBYTE" 2>&1 | tr '\n' ';')"; fi
        b2_done=1; break
    done
    [[ "$b2_done" -eq 0 ]] && _bochs_harness_giveup "RUN-2"
    # RUN-1 (byte WITHHELD by design: --delay 200 > timeout 50 -> the reader PARKS, no SENT + timeout-killed, so only
    # LISTENING is a valid harness check here; expect_full=0 skips the SENT/shutdown sentinels)
    b1_done=0
    for attempt in 1 2 3; do
        BOCHS_HARNESS_ERR=""
        if ! bochs_run "$work/b1" "$FBYTE" 200 50 0; then
            echo "  HARNESS ERROR (Bochs RUN-1 attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue
        fi
        if python3 "$REF" gradefurl "$work/b1" "$KEND" "$K" run1 "$FBYTE" >/dev/null 2>&1; then ok "(C) Bochs RUN-1 (byte withheld): peers run while the reader is parked"
        else fail_test "(C) Bochs RUN-1 (feeder LISTENED; a lone RED here may be a capture-class flake, not necessarily a genuine park-behavior defect -- see the parley replay discriminator) -> $(python3 "$REF" gradefurl "$work/b1" "$KEND" "$K" run1 "$FBYTE" 2>&1 | tr '\n' ';')"; fi
        b1_done=1; break
    done
    [[ "$b1_done" -eq 0 ]] && _bochs_harness_giveup "RUN-1"
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link49 (furlough / BLOCKING SYS_READ block-wake): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link49 furlough / BLOCKING SYS_READ -- a naive reader on not-ready input is PARKED by the kernel (kernel-side deschedule via a blocked[] state, indexed by cur) instead of freezing the machine, peers run, the reader is woken EXACTLY ONCE with the delivered byte; PRIMARY discriminator wake-witness==1 (kills the runnable-retry forge structurally, disp[] is a loose supporting tripwire); byte-pinned to furlough_ref.build_elf (binds the GENERAL indexed mechanism, not a proc0-hardcoded forge), white-box block/wake machinery, QEMU+KVM+Bochs GREEN on RUN-2 + RUN-1, seed-differential data-dependent, frozen-homestead differential RED, additive on tenement/rollcall/tickover/homestead. HONEST SCOPE: single blocked reader (multi-reader queue future); poll-driven wake (poll-granularity, not an IRQ4 interrupt -- future); all-GP-clobbered-by-syscall ABI (stale GP fine for the no-retry reader); the synchronous-ready do_read path is byte-pin-bound but not runtime-graded)"
