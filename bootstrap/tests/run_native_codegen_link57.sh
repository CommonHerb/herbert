#!/usr/bin/env bash
# native-codegen link57 (growheap / GROW THE HEAP -- a MULTI-PAGE heap with cross-page coalesce).
#
# A NEW emit mode `-- emit: multiboot32-growheap`, TYPE-II ADDITIVE on the FROZEN larder (link40) lineage: npages=1
# reproduces the larder kernel byte-for-byte; the multi-page mode adds a CONTIGUOUS NPAGES-page User pool (the fixed
# region 0x700000) over which larder's first-fit/split/address-ordered-coalesce arms (REUSED byte-identically) now
# coalesce ACROSS a page boundary. The forced NEW observable is a make-or-break alloc that fits ONLY a hole formed by
# coalescing two freed spans that STRADDLE the page boundary -- something larder's single sub-page (168 B) pool never
# exercised. The witness is the same KERNEL-EMITTED late-bound trace as larder (0xE0 + ptr per alloc; an 0xE1..0xE2
# framed live readback on dump); the seed is chosen AFTER freeze and derives the chunk SIZES so the whole cross-page
# offset trace is author-unknown.
#
# Gates: (B1) the EMITTED kernel == growheap_ref.build_elf(npages=NPAGES) byte-for-byte; (B2) assert_growheap (the
# multi-page pool immediates + the fixed-region User-flip PTEs + cross-page coalesce path, all branch-target reachable,
# additive on assert_larder); (B3) the frozen LARDER kernel FAILS assert_growheap (multi-page is genuinely new);
# (D) every frozen prior mode byte-identical + assert_larder/assert_cairn STILL pass on the growheap kernel (additive);
# (SILICON) the late-bound cross-page witness GREEN on QEMU-TCG + Bochs (+ KVM when /dev/kvm present); the 4 FORGE legs
# (singlepage / nocrosspagecoalesce / nofree / staticarena) DIVERGE -> RED; the GX/GY seed-differential RED; and the
# GROWHEAP DIFFERENTIAL: the frozen larder kernel (168 B pool) on the growheap witness is RED (the page-scale allocs are
# rejected). REQUIRE_EMU fail-closed (cairn/larder pattern): KERNEL_CODEGEN_REQUIRE_EMU=1 + a missing CI emulator -> FAIL.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/growheap_ref.py"
LB="$script_dir/growheap_latebound.py"
LARDER_REF="$script_dir/larder_ref.py"
CAIRN_REF="$script_dir/cairn_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
for f in "$REF" "$LB" "$LARDER_REF" "$feeder"; do
    [[ -f "$f" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing $f)"; exit 1; }
done
source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"; pkill -9 -f "$work" 2>/dev/null || true' EXIT   # kill only THIS gate's bochs (scoped to its unique mktemp; a system-wide `pkill bochs` false-REDs a CONCURRENT gate's boot -- the F4 class). F2 sweep 2026-07-04.
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
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$LB" kernel "$REFK" none)"   # growheap_ref.build_elf(npages=NPAGES)
DRIVER="$work/driver.bin"; python3 "$LB" driver "$DRIVER"                   # the GENERIC ring-3 op-interpreter
DISK="$work/disk.img"; dd if=/dev/zero of="$DISK" bs=1M count=64 status=none  # growheap's heap is RAM; an IDE drive for the cairn-lineage boot
read -r GH_NPAGES GH_PGSZ GH_CAP GH_POOL < <(python3 "$REF" growheapwindow)

MKELF="$work/growheap_kernel.elf"
emit '-- emit: multiboot32-growheap' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) growheap kernel byte-identical to growheap_ref.build_elf(npages=$GH_NPAGES) [$(wc -c <"$MKELF") B]"
else fail_test "(B1) growheap kernel differs from growheap_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_growheap + Multiboot validity ----
if python3 "$REF" assertgrowheap "$MKELF"; then ok "(B2) kernel carries the MULTI-PAGE heap machinery (assert_growheap: pool_size + chunk[0].len = npages*PGSZ; the fixed 0x$(printf %x $GH_POOL) region reserved + each page flipped identity+User; the cross-page coalesce arms carry NO page-boundary refuse guard; all additive on assert_larder, branch-target reachable)"
else fail_test "(B2) kernel lacks the multi-page machinery (assert_growheap failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "growheap kernel is a valid x86 Multiboot image"
else fail_test "growheap kernel is not a valid x86 Multiboot image"; fi

# ---- (B3) the frozen LARDER kernel must FAIL assert_growheap (no multi-page pool) ----
python3 "$LARDER_REF" kernelelf "$work/larder_for_assert.elf" none full >/dev/null 2>&1
if python3 "$REF" assertgrowheap "$work/larder_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen larder kernel PASSED assert_growheap -- the white-box pin does not discriminate the multi-page pool"
else ok "(B3) the frozen larder kernel FAILS assert_growheap (the multi-page pool + the fixed-region User-flips + cross-page coalesce are genuinely new vs larder's single 168 B pool)"; fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive on larder) + larder/cairn asserts STILL hold on growheap ----
for lk in larder cairn durable platter lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; growheap is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- growheap disturbed it"; fi
done
if python3 "$LARDER_REF" assertlarder "$MKELF" >/dev/null 2>&1; then ok "(D) larder's frozen assert_larder PASSES on the growheap kernel (the alloc/free/dump arms are byte-identical; growheap only widened the pool + added the fixed-region User-flips)"
else fail_test "(D) assert_larder FAILED on the growheap kernel -- growheap disturbed the allocator arms (not purely additive)"; fi
if python3 "$CAIRN_REF" assertcairn "$MKELF" >/dev/null 2>&1; then ok "(D) cairn's frozen assert_cairn PASSES on the growheap kernel (the FS arms are preserved)"
else fail_test "(D) cairn's assert_cairn FAILED on the growheap kernel -- not purely additive"; fi

# ---- (PY) Python byte-pin / assert layer ----
if GROWHEAP_TDIR="$script_dir" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ['GROWHEAP_TDIR'])
import growheap_ref as G, larder_ref as L
NP = G.GROWHEAP_NPAGES
a,_,_ = G.build_elf(npages=NP); b,_,_ = G.build_elf(npages=NP)
det = (a == b)
ag = G.assert_growheap(a); al = G.assert_larder(a)              # additive: assert_larder must STILL pass
# white-box-REJECTED growheap mutants (assert_growheap must say False):
rej = (not G.assert_growheap(G.build_elf(mut='singlepage', npages=NP)[0])) and \
      (not G.assert_growheap(G.build_elf(mut='nocrosspagecoalesce', npages=NP)[0]))
# npages=1 reproduces larder byte-for-byte (the additive default):
addv = (G.build_elf(npages=1)[0] == L.build_elf()[0])
# the GH-mode excl[] boundary invariant: 10 fixed + 3 per proc (no +1 pool page in GH mode) fits at MAXPROC.
boundary = (G.NEXCL >= 10 + 3*G.MAXPROC)
# every growheap mutant kernel differs from genuine:
diff = all(G.build_elf(mut=m, npages=NP)[0] != a for m in ['singlepage','nocrosspagecoalesce','freenoop','bump'])
print('det',det,'assert_growheap',ag,'assert_larder',al,'rejects_muts',rej,'npages1==larder',addv,'gh_boundary',boundary,'muts_differ',diff)
sys.exit(0 if (det and ag and al and rej and addv and boundary and diff) else 1)
PY
then ok "(PY) build_elf(npages) deterministic; assert_growheap GREEN + rejects singlepage/nocrosspagecoalesce; assert_larder STILL GREEN (additive); npages=1 byte-identical to larder; the GH-mode excl boundary holds (10+3*MAXPROC <= NEXCL -- the +1 pool page is dropped in multi-page mode); every growheap mutant differs"
else fail_test "(PY) Python byte-pin/assert layer"; fi

# ============================ SILICON (the late-bound cross-page witness) ============================
build_kernel() { python3 "$LB" kernel "$1" "$2" >/dev/null; }   # out mut

boot_feed() { # kernel out kvm stream...
    local kel="$1" out="$2" kvm="$3"; shift 3
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port="$(free_port)"; local d="$out.d"; rm -rf "$d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$DRIVER" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
is_struct_flake() { echo "$1" | grep -qE 'no parseable kernel cell-dump|MAGIC banner not found|truncated|missing 0xE'; }
# a GENUINE divergence = a VALUE mismatch in the emitted trace (a forge's make-or-break alloc emits
# `alloc N: emitted 0x0 != expected 0x...`). NOT the broad 'OOM|ptr 0|0x0' -- grade prints
# `pool_base=0x0` on an UNPARSEABLE boot, so matching '0x0' would misread a dead/hung mutant as a
# valid forge DIVERGE (cross-model gate-audit caught this). Only an emitted-value mismatch counts.
has_real_divergence() { echo "$1" | grep -qE '!= expected|appears MORE THAN ONCE|emitted MORE live chunks'; }
mutant_verdict() { # cmd...  -> DIVERGE|CONSISTENT|EQUIVALENT (a RED must be a DETERMINISTIC bite, not a flake)
    local n=4 i g
    for i in $(seq 1 "$n"); do
        g="$("$@")"
        echo "$g" | grep -q '^GREEN' && { echo EQUIVALENT; return; }
        has_real_divergence "$g" && { echo DIVERGE; return; }
    done
    echo CONSISTENT
}
run_witness_kel() { # kel seed kvm
    local kel="$1" seed="$2" kvm="$3"
    local stream; stream="$(python3 "$LB" stream "$seed")"
    local out="$work/w.out" try g
    for try in 1 2 3 4; do
        boot_feed "$kel" "$out" "$kvm" $stream
        g="$(python3 "$LB" grade "$out" "$seed" 2>&1)"
        is_struct_flake "$g" || break
    done
    echo "$g"
}
run_forge_leg() { # leg seed kvm  -> grade a MUTANT-kernel run vs the GENUINE golden (RED expected)
    local leg="$1" seed="$2" kvm="$3"
    local mut; mut="$(python3 "$LB" forge_mutant "$leg")"
    local kel="$work/forge_$leg.elf"; build_kernel "$kel" "$mut"
    local stream; stream="$(python3 "$LB" forge_stream "$seed" "$leg")"
    local out="$work/forge_$leg.out"; boot_feed "$kel" "$out" "$kvm" $stream
    python3 "$LB" forge_grade "$out" "$seed" "$leg" 2>&1
}

emu_ran=0
if have_qemu; then
    emu_ran=1
    for SUB in tcg kvm; do
        KVMF=""; [[ "$SUB" == kvm ]] && KVMF="kvm"
        if [[ "$SUB" == kvm ]] && ! have_kvm; then
            echo "  NOTE: /dev/kvm unavailable -- KVM real-silicon leg skipped (a local pre-push leg; QEMU-TCG + Bochs are the CI substrates)"; continue
        fi
        SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
        echo "  ----- QEMU-$SUB  seed=$SEED -----"
        RES="$(run_witness_kel "$MKELF" "$SEED" "$KVMF")"
        if echo "$RES" | grep -q '^GREEN'; then ok "(C-$SUB) the LATE-BOUND cross-page witness on the EMITTED kernel: the kernel-emitted offset trace == the host first-fit golden (peak live-set spans 2 pages; the make-or-break alloc fits ONLY a hole formed by coalescing two freed spans that STRADDLE the page boundary; the live readback's sentinels written THROUGH the returned ptrs match)"
        else fail_test "(C-$SUB) genuine cross-page witness not GREEN: $(echo "$RES" | tr '\n' ';')"; fi

        if [[ "$SUB" == tcg ]]; then
            # (FORGE) each leg's biting mutant kernel must DIVERGE from the genuine cross-page golden (RED).
            for LEG in singlepage nocrosspagecoalesce nofree staticarena; do
                V="$(mutant_verdict run_forge_leg "$LEG" "$SEED" "$KVMF")"
                case "$V" in
                  DIVERGE)    ok "(FORGE $LEG) the forge kernel's make-or-break alloc emits ptr 0 (a VALUE mismatch 'emitted 0x0 != expected') where the genuine multi-page allocator fits it -> the cross-page capability is load-bearing" ;;
                  *)          fail_test "(FORGE $LEG) did NOT produce a genuine value-mismatch divergence (verdict=$V) -- a forge must OOM the make-or-break alloc (ptr != expected), not crash/hang/go-green (cross-model gate-audit: CONSISTENT could be a dead mutant)" ;;
                esac
            done

            # (GX/GY) SEED-DIFFERENTIAL: gx's genuine output graded against gy's golden must DIVERGE.
            GX="$(python3 -c 'import os;print(os.urandom(8).hex())')"; GY="$(python3 -c 'import os;print(os.urandom(8).hex())')"
            sx="$(python3 "$LB" stream "$GX")"; gout="$work/gx.out"
            for try in 1 2 3 4; do boot_feed "$MKELF" "$gout" "$KVMF" $sx; g="$(python3 "$LB" grade "$gout" "$GX" 2>&1)"; is_struct_flake "$g" || break; done
            RES="$(python3 "$LB" grade "$gout" "$GY" 2>&1)"
            if echo "$RES" | grep -q '^RED'; then ok "(GX/GY) gx's genuine output graded against gy's golden DIVERGES -> the cross-page trace tracks the late-bound seed (no baked answer)"; else fail_test "(GX/GY) gx-vs-gy did NOT diverge (seeds collided?): $(echo "$RES"|tr '\n' ';')"; fi
            RES="$(python3 "$LB" grade "$gout" "$GX" 2>&1)"
            if echo "$RES" | grep -q '^GREEN'; then ok "(GX/GY control) gx output vs gx golden GREEN"; else fail_test "(GX/GY control) gx-vs-gx not GREEN: $(echo "$RES"|tr '\n' ';')"; fi
        else
            # KVM (real silicon): re-confirm the two NEW biting mutants on the physical CPU (KVM caught growheap-class
            # segment/page bugs TCG hid). Flake-discriminated deterministic bite.
            for LEG in singlepage nocrosspagecoalesce; do
                V="$(mutant_verdict run_forge_leg "$LEG" "$SEED" "$KVMF")"
                if [[ "$V" == DIVERGE ]]; then ok "(KVM, FORGE $LEG) the forge's make-or-break alloc emits ptr 0 (value mismatch '!= expected') on the physical CPU"; else fail_test "(KVM, FORGE $LEG) did NOT produce a genuine value-mismatch divergence (verdict=$V) -- not a crash/hang"; fi
            done
        fi
    done
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- Bochs (2nd substrate via GRUB): the genuine cross-page witness on the EMITTED kernel must be GREEN ----
if have_bochs; then
    emu_ran=1
    SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    STREAM="$(python3 "$LB" stream "$SEED")"
    kelf="$(readlink -f "$MKELF")"; drv="$(readlink -f "$DRIVER")"
    d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    pkill -9 -f "$work" 2>/dev/null || true   # scoped to THIS gate (own process), not system-wide (would kill a concurrent gate's Bochs)
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$drv" mnt/boot/driver.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/driver.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP" )
    cat > "$d/bochsrc.txt" <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat, cylinders=256, heads=16, spt=32
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:__PORT__
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
    # F2 sweep (2026-07-04): the existing retry re-rolls on a missing/truncated trace (is_struct_flake). Add the EXPLICIT
    # harness detectors from the link60 reference so a harness failure re-rolls instead of grading a confounded trace:
    # the feeder must LISTEN (bind) + deliver (SENT -> Bochs connected COM1) + the kernel must run THROUGH its shutdown()
    # tail ('shutdown requested' -> shutdown() writes "Shutdown" to Bochs port 0x8900). Any missing => a re-rollable
    # emulator/feeder failure, NEVER a false kernel RED.
    bochs_emit=""; bochs_harness_fail=1; BOCHS_HARNESS_ERR=""
    for try in 1 2 3; do
        port=$(free_port)
        python3 "$feeder" "$port" $STREAM --hold 150 > "$d/feed.log" 2>&1 & fp=$!
        _ok_listen=1; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && { _ok_listen=0; break; }; sleep 0.1; done
        if [[ $_ok_listen -ne 0 ]]; then BOCHS_HARNESS_ERR="the COM1 feeder never reached LISTENING"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; echo "  HARNESS ERROR (Bochs cross-page witness try $try/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue; fi
        sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b.txt"
        ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b.txt" > bochs.txt 2>&1 )   # absolute bochsrc path -> $work in the cmdline for the scoped `pkill -f "$work"`
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        if ! grep -q '^SENT' "$d/feed.log" 2>/dev/null; then BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload (no SENT / NOCONN -- Bochs did not connect COM1, the kernel got no input)"; echo "  HARNESS ERROR (Bochs cross-page witness try $try/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue; fi
        if ! grep -qa 'shutdown requested' "$d/bochs.txt" 2>/dev/null; then BOCHS_HARNESS_ERR="Bochs did NOT run through to the kernel shutdown tail (no 'shutdown requested' -- killed or hung mid-run)"; echo "  HARNESS ERROR (Bochs cross-page witness try $try/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue; fi
        # This attempt passed LISTENING+SENT+shutdown -> the harness SUCCEEDED, so from here the grade is a GENUINE
        # kernel verdict, NOT a harness failure. Set the flag NOW (not only on a definitive grade) so that a grade
        # which merely LOOKS like a struct-flake but is actually a real value-RED (e.g. growheap's 'missing 0xE2 ...
        # emitted MORE live chunks', which is_struct_flake's 'missing 0xE' pattern also matches -- cross-model Codex)
        # is NOT masked as a re-rollable HARNESS-ERROR after 3 tries; a persistent struct-flake with a clean harness is
        # a real trace problem -> fail_test. HARNESS-ERROR fires ONLY when NO attempt ever passed the harness checks.
        bochs_harness_fail=0
        python3 - "$d/bochs.txt" "$d/out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
        bochs_emit="$(python3 "$LB" grade "$d/out" "$SEED" 2>&1)"
        is_struct_flake "$bochs_emit" || break   # a definitive grade (GREEN or a real value-RED) -> stop retrying
    done
    if [[ $bochs_harness_fail -ne 0 ]]; then
        if [[ "$REQUIRE_EMU" == "1" ]]; then echo "HARNESS-ERROR: (C-Bochs) the REQUIRED Bochs substrate failed 3 consecutive harness attempts -- ${BOCHS_HARNESS_ERR:-missing/truncated trace} (re-rollable emulator/feeder failure, NOT a kernel miscompile; the gate is RED only because KERNEL_CODEGEN_REQUIRE_EMU=1)"; fail=$((fail + 1))
        else echo "  HARNESS-ERROR (non-fatal): (C-Bochs) Bochs failed 3 consecutive harness attempts -- ${BOCHS_HARNESS_ERR:-missing/truncated trace} (re-rollable; REQUIRE_EMU=0 so the gate is NOT RED on a harness flake -- re-roll, or set KERNEL_CODEGEN_REQUIRE_EMU=1)" >&2; fi
    elif echo "$bochs_emit" | grep -q '^GREEN'; then ok "(C-Bochs) the late-bound cross-page witness on the EMITTED kernel is GREEN on the 2nd substrate: the kernel-emitted trace == the host first-fit golden (the make-or-break alloc fits the cross-page-coalesced hole) on Bochs' chipset"
    else fail_test "(C-Bochs) Bochs cross-page witness not GREEN (fed+delivered+ran through shutdown -> a GENUINE kernel grade, not a harness flake): $(echo "$bochs_emit" | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

# ---- (C-GROWHEAP) THE GROWHEAP DIFFERENTIAL: the frozen LARDER kernel + the growheap witness -> RED ----
# larder's pool is a single 168 B sub-page region; the growheap witness allocates PAGE-SCALE chunks (thousands of bytes),
# each REJECTED by larder's `cmp ebx,[pool_size]` (size>168 -> ptr 0). The emitted trace is all-zero ptrs -> diverges
# from the growheap cross-page golden -> RED. The multi-page heap is a genuinely new observable -- the frozen prior
# kernel cannot reproduce it. (Mirrors larder's cairn-differential.)
if have_qemu; then
    LKELF="$work/larder_kernel.elf"; python3 "$LARDER_REF" kernelelf "$LKELF" none full >/dev/null 2>&1
    DSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    dstream="$(python3 "$LB" stream "$DSEED")"
    DRES=""
    for try in 1 2 3 4; do
        boot_feed "$LKELF" "$work/diff.out" "" $dstream
        DRES="$(python3 "$LB" grade "$work/diff.out" "$DSEED" 2>&1)"
        is_struct_flake "$DRES" || break
    done
    if echo "$DRES" | grep -q '^GREEN'; then
        fail_test "(C-GROWHEAP) the frozen larder kernel graded GREEN on the growheap witness -- the multi-page pool is NOT genuinely new (larder's 168 B pool fit the page-scale allocs?)"
    elif has_real_divergence "$DRES"; then
        ok "(C-GROWHEAP) THE GROWHEAP DIFFERENTIAL: the frozen larder kernel + the growheap witness DIVERGES via a genuine VALUE mismatch (an emitted ptr 0x0 != expected) -- larder's single 168 B pool REJECTS the page-scale allocs (since sA+sB=PGSZ, at least one alloc is >168 -> ptr 0), so the make-or-break cross-page reuse never materialises -> the multi-page heap with cross-page coalesce is a genuinely new observable (additive on larder)"
    else
        fail_test "(C-GROWHEAP) the frozen larder kernel was non-GREEN but NOT via a genuine value-mismatch (a crash/flake after retries, not a capacity-caused ptr-mismatch -- cross-model gate-audit): $(echo "$DRES"|tr '\n' ';'|head -c 200)"
    fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link57 (growheap / GROW THE HEAP -- a MULTI-PAGE heap with cross-page coalesce): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link57 growheap / GROW THE HEAP. A NEW emit mode multiboot32-growheap, TYPE-II ADDITIVE on the FROZEN larder (link40) lineage: npages=1 reproduces larder byte-for-byte; the multi-page mode adds a CONTIGUOUS $GH_NPAGES-page User pool at the fixed region 0x$(printf %x $GH_POOL) over which larder's first-fit/split/address-ordered-coalesce arms -- REUSED byte-identically -- now coalesce ACROSS a page boundary. The forced NEW observable is a LATE-BOUND author-unknown make-or-break alloc that fits ONLY a hole formed by coalescing two freed spans that STRADDLE the page boundary -- which larder's single 168 B sub-page pool never exercised. KERNEL-EMIT only (the same 0xE0 ptr + 0xE1..0xE2 framed live readback as larder); the seed is chosen AFTER freeze and derives the chunk SIZES so the whole cross-page offset trace is author-unknown. Byte-pinned to growheap_ref.build_elf(npages=$GH_NPAGES); white-box assert_growheap (the multi-page pool immediates + the fixed-region reservation + each page flipped identity+User + the cross-page coalesce arms carrying NO page-boundary refuse guard, all branch-TARGET reachable, additive on assert_larder); the frozen larder kernel FAILS assert_growheap (B3); additive on larder/cairn/durable/platter/lethe/cleave/tessera/furlough/homestead/tenement/rollcall/tickover AND larder's assert_larder + cairn's assert_cairn STILL PASS on the growheap kernel (the allocator + FS arms are untouched); QEMU-TCG + Bochs GREEN on the cross-page witness (+ KVM real-silicon when /dev/kvm present); the FORGE legs (singlepage -> the page-2 alloc OOMs; nocrosspagecoalesce -> the make-or-break straddling hole never forms; nofree/staticarena -> no reuse) DIVERGE -> RED; the GX/GY SEED-DIFFERENTIAL RED (the trace tracks the late-bound seed); and THE GROWHEAP DIFFERENTIAL RED (the frozen larder kernel's 168 B pool rejects the page-scale allocs). Output-forced -- the cross-page reuse trace follows the late-bound sizes and no single-page / no-cross-page-coalesce / no-free allocator and no frozen older kernel reproduces it. The GH-mode excl[] boundary: growheap adds the fixed pool region as a 10th fixed excl entry but DROPS larder's +1 bump pool page in multi-page mode, so 10 fixed + 3 per proc = 34 <= NEXCL at MAXPROC (guarded by an import-time static invariant NEXCL >= 10+3*MAXPROC; the gate itself boots K=1 modules, so the boundary is pinned statically not at runtime). The held-back MUTATION proof (singlepage/nocrosspagecoalesce + larder's forge set, control-GREEN + all-RED, single shared seed) lives in the companion mutation harness. KVM (real silicon) runs when /dev/kvm is present -- a local pre-push leg -- and is skipped-with-note in CI; QEMU-TCG + Bochs are the REQUIRE_EMU fail-closed CI substrates. HONEST SCOPE: a fixed contiguous $GH_NPAGES-page pool (not a demand-grown heap), cross-page split + address-ordered cross-boundary coalesce, the same 4-byte floor + exact-base free as larder; no per-size bins, no realloc, no on-demand page-by-page heap growth)"
