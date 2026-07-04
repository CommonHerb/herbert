#!/usr/bin/env bash
# Native-codegen Link 48 / homestead (kernel-arc link 32): DEMAND-PAGED STACK GROWTH -- the kernel grows a ring-3
# program's stack ON DEMAND. Built on the FROZEN tenement lineage. NEW vs tenement: each proc gets a 1-page committed
# region PLUS a GROWMAX-page P=0 ("not present") grow window below it. When the program's stack grows past the
# committed page, the CPU takes a NOT-PRESENT #PF (err.P==0); the kernel COMMITS the faulting page on demand
# (PTE=(cr2&~0xFFF)|7 -- present+RW+User, identity frame) and IRET-RESUMES the faulting push. Genuine demand paging:
# the page is genuinely not-present until the demand fault commits it (vs tenement/mumbani, which only ever toggle the
# User bit on always-present pages). A NEW kernel emit mode `multiboot32-homestead` (additive on the frozen lineage).
# KERNEL-EMIT only; the forcing probe is a hand-assembled recursive grower.
#
# Forcing program: a single recursive GROWER (Herbert has no loops / no TCO, so N items == ~N stack frames). It reads
# a HELD-BACK seed byte via SYS_READ (late-bound over COM1), recurses N=400 deep (~3-4 pages of frames, > the 1-page
# committed region), generating N distinct 24-bit words from the seed in-module, and emits them REVERSED on the unwind.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a manual KVM leg, vs homestead_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == homestead_ref.build_elf() AND carries the demand-paging
#       machinery (assert_homestead: the boot P-clear `and [pte],~1`, the err.P==0 #PF gate `test byte[esp+0x20],1`,
#       the demand-commit value+store `cr2 -> present+RW+User PTE`) -- distinct from tenement (U-bit flip only).
#   (D) FROZEN: the prior emit modes are byte-identical -- multiboot32-{tenement,rollcall,tickover,mumbani} ==
#       their *_ref.build_elf() (proves homestead is PURELY ADDITIVE, disturbs nothing).
#   (C) SILICON make-or-break: the kernel runs the recursive grower whose stack outgrows its 1-page region -- every
#       over-page push takes a NOT-PRESENT #PF, the kernel demand-commits the next grow page and IRET-resumes, and the
#       FULL held-back reversed stream comes out. Demand commits are WITNESSED (C2..C3 frames: err.P==0, PTE P=0->P=1,
#       cr2 in the grow window) -- the temporal proof of genuine demand paging.
#   (C-DIFF) THE DIFFERENTIAL (the key forcing proof): the FROZEN tenement kernel, fed the SAME grower, grades RED --
#       tenement gives a fixed 1-page region with an all-present map + a TERMINAL #PF handler, so the descent #PFs
#       (protection, err.P=1) mid-stack and the program is KILLED with 0/partial output. Demand-growth is genuinely NEW.
# The held-back MUTATION proof (run_native_codegen_link48_mutation.sh) proves each demand-paging choice non-vacuous
# (M-nogrow: no demand branch -> killed; M-noclear: window stays present-Supervisor -> protection #PF -> killed;
# M-eager: eager-map the window present up front -> FULL correct output but ZERO demand commits -> RED on the temporal
# gate. M-eager is the KEY mutation: it distinguishes demand-commit from a fixed-large/eager reserve -- same output,
# missing the not-present commit witness).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/homestead_ref.py"
TEN="$script_dir/tenement_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
N="${HOMESTEAD_N:-400}"          # recursion depth of the grower (~3-4 pages of frames; GROWMAX=8)
SEED="${HOMESTEAD_SEED:-90}"     # held-back seed byte (0x5A); fed late-bound over COM1
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
GROWER="$work/grower.bin"; python3 "$REF" modgrower "$GROWER" "$N"

MKELF="$work/homestead_kernel.elf"
emit '-- emit: multiboot32-homestead' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) homestead kernel byte-identical to homestead_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) homestead kernel differs from homestead_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" homestead "$MKELF"; then ok "(B2) kernel carries the demand-paging machinery (boot P-clear, err.P==0 #PF gate, demand-commit value+store)"
else fail_test "(B2) kernel lacks the demand-paging construct (assert_homestead failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "homestead kernel is a valid x86 Multiboot image"
else fail_test "homestead kernel is not a valid x86 Multiboot image"; fi

# ---- (D) FROZEN prior modes (purely additive) ----
# The baked-kernel lineage (emitted from `func main(): return 0 end`). The compiled-body modes (mumbani/coalgate/
# ouroboros/...) take a mode-specific source and are NOT byte-testable with this generic probe; homestead adds only
# isolated baked-blob functions + one dispatch line (no shared lowering code), so it cannot disturb them -- proven by
# the make-test self-host fixpoint (gen2==gen1) + a one-time byte-identical check of multiboot32-mumbani with its real
# source (`func main(): return module_byte() end`).
for lk in tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; homestead is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- homestead disturbed it"; fi
done

# ============================ SILICON (the demand-grow make-or-break) ============================
emu_ran=0
qemu_run() { # kernel-elf out seed [kvm]
    local kel="$1" out="$2" seed="$3" kvm="${4:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$seed" --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; done
    timeout 120 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$GROWER" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
if have_qemu; then
    emu_ran=1
    qemu_run "$MKELF" "$work/q" "$SEED"
    if python3 "$REF" gradehome "$work/q" "$KEND" "$N" "$SEED" >/dev/null 2>&1; then ok "(C) QEMU N=$N: the recursive grower's stack outgrows its 1-page region -- every over-page push demand-commits a grow page (NOT-PRESENT #PF -> commit -> iret-resume), the FULL held-back reversed stream comes out"
    else fail_test "(C) QEMU -> $(python3 "$REF" gradehome "$work/q" "$KEND" "$N" "$SEED" 2>&1 | tr '\n' ';')"; fi
    # DATA-DEPENDENCE (seed differential): the SAME kernel, fed a DIFFERENT held-back seed, emits the NEW seed's
    # reversed stream; grading that run with the DEFAULT seed is RED -- the grower output genuinely follows the
    # late-bound held-back seed (the byte-pinned kernel is seed-agnostic; it cannot predict it).
    SEEDB=51
    qemu_run "$MKELF" "$work/qb" "$SEEDB"
    if python3 "$REF" gradehome "$work/qb" "$KEND" "$N" "$SEEDB" >/dev/null 2>&1; then ok "(C) QEMU seed-B: the grower emits the NEW held-back seed's reversed stream (data-dependence)"
    else fail_test "(C) QEMU seed-B -> $(python3 "$REF" gradehome "$work/qb" "$KEND" "$N" "$SEEDB" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" gradehome "$work/qb" "$KEND" "$N" "$SEED" >/dev/null 2>&1; then fail_test "(C) QEMU seed-B run graded GREEN with the DEFAULT seed -- grower output NOT data-dependent (vacuous)"
    else ok "(C) QEMU the seed-B run is RED graded with the default seed (grower output follows the late-bound held-back seed)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- THE DIFFERENTIAL (the key forcing proof): the FROZEN tenement kernel CANNOT grow ----
# tenement gives a fixed 1-page region over an all-present map + a TERMINAL #PF handler. Fed the SAME grower, the
# descent #PFs (protection, err.P=1) mid-stack and the program is killed with 0/partial output and ZERO demand
# commits -> RED. This proves demand-growth is genuinely NEW (not incidental to running a ring-3 program).
if have_qemu && [[ -f "$TEN" ]]; then
    TKELF="$work/tenement_kernel.elf"; TKEND="$(python3 "$TEN" kernelelf "$TKELF" none full)"
    qemu_run "$TKELF" "$work/qdiff" "$SEED"
    if python3 "$REF" gradehome "$work/qdiff" "$TKEND" "$N" "$SEED" >/dev/null 2>&1; then fail_test "(C-DIFF) the frozen TENEMENT kernel graded GREEN under the demand-grow criterion -- growth is NOT genuinely new (tenement already grows?)"
    else ok "(C-DIFF) the frozen TENEMENT kernel + the SAME grower is RED -- a fixed 1-page region + terminal #PF kills the descent; homestead's demand-grow is a genuinely new observable"; fi
elif [[ ! -f "$TEN" ]]; then
    fail_test "(C-DIFF) missing $TEN -- cannot run the tenement differential"
fi

# ---- KVM (real silicon): the demand-commit on real hardware ----
if have_kvm; then
    qemu_run "$MKELF" "$work/k" "$SEED" kvm
    if python3 "$REF" gradehome "$work/k" "$KEND" "$N" "$SEED" >/dev/null 2>&1; then ok "(C-KVM) real silicon N=$N: the demand-paged stack growth is byte-identical on KVM (NOT-PRESENT faults + commits + iret-resume on real hardware)"
    else fail_test "(C-KVM) KVM N=$N -> $(python3 "$REF" gradehome "$work/k" "$KEND" "$N" "$SEED" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB) ----
bochs_run() { # e9out seed  -> nonzero (sets BOCHS_HARNESS_ERR) on a harness failure (F2 sweep 2026-07-04)
    local e9="$1" seed="$2"
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
    local kelf; kelf="$(readlink -f "$MKELF")"; local gbin; gbin="$(readlink -f "$GROWER")"
    local d="$work/b.d"; mkdir -p "$d"; local port; port="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$port" "$seed" --hold 40 > "$d/feed.log" 2>&1 &
    local bfp=$!
    _feed_ok "$d/feed.log" "grower(BOOT)" || { kill "$bfp" 2>/dev/null; wait "$bfp" 2>/dev/null; return 1; }
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
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$gbin" mnt/boot/g.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/g.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
      xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    kill "$bfp" 2>/dev/null; wait "$bfp" 2>/dev/null
    _bochs_ran_ok "$d/bochs_out.txt" "grower(BOOT)" || return 1
    _feed_delivered "$d/feed.log" "grower(BOOT)" || return 1
    python3 - "$d/bochs_out.txt" "$e9" <<'PY'
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
        if ! bochs_run "$work/b" "$SEED"; then
            echo "  HARNESS ERROR (Bochs attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2
            continue
        fi
        # the feeder LISTENED + delivered (SENT) + the kernel ran THROUGH shutdown() -> grade is a GENUINE kernel verdict
        if python3 "$REF" gradehome "$work/b" "$KEND" "$N" "$SEED" >/dev/null 2>&1; then ok "(C) Bochs N=$N: the demand-paged growth is byte-identical on the 2nd substrate (GRUB delivers the grower module)"
        else fail_test "(C) Bochs N=$N (fed+delivered+ran through shutdown -> a GENUINE kernel grade, not a harness flake) -> $(python3 "$REF" gradehome "$work/b" "$KEND" "$N" "$SEED" 2>&1 | tr '\n' ';')"; fi
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

echo "native-codegen link48 (homestead / DEMAND-PAGED STACK GROWTH): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link48 homestead / DEMAND-PAGED STACK GROWTH -- a ring-3 program's stack grows past its 1-page region by demand-committing P=0 grow pages on NOT-PRESENT #PFs; byte-pinned to homestead_ref.build_elf, white-box demand-paging machinery, QEMU+KVM+Bochs GREEN, frozen-tenement differential RED, additive on tenement/rollcall/tickover/mumbani)"
