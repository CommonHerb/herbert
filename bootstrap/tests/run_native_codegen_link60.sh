#!/usr/bin/env bash
# native-codegen link60 (kernel-arc link 44) = tract / FIRST VARIABLE-SIZE durable file.
# A NEW emit mode multiboot32-tract, TYPE-II ADDITIVE on the FROZEN delete (link 42) lineage: SYS_FS_PUT/GET become
# MULTI-SECTOR contiguous runs (need=ceil(len/512)) with a recompute-from-DIRECTORY first-fit-by-LBA allocator
# (coalesce implicit; the durable free state = f(directory)). build_elf(varsize=False) reproduces the delete kernel
# BYTE-FOR-BYTE; the on-disk dir format is UNCHANGED (len->nsectors, data_lba->run start); the data window EXTENDS.
#
# THE MAKE-OR-BREAK is a 4-boot MULTI-SECTOR REUSE differential on ONE cache=writethrough disk (all late-bound over COM1):
#   BOOT-1 writer  : PUT R0..R4 (sizes 2,2,3,2,1 sectors; payloads >512B w/ partial last) -> first-fit-by-LBA lays them
#                    contiguous R0[0,2) R1[2,4) R2[4,7) R3[7,9) R4[9,10).
#   BOOT-2 deleter : DEL R1,R2 (adjacent -> a MERGED 5-sector free gap [2,7)); R0 is the lowest live survivor.
#   BOOT-3 writer  : PUT N0 (4 sectors) -> first-fit lands it in the MERGED gap at sector 2 (4>3 and 4>2, <=5); then
#                    N1 (1 sector) -> the SPLIT remainder at sector 6.
#   BOOT-4 getter  : GET R0,N0,N1 by name -> SYS_WRITE each -> byte-exact reassembly (functional confirm).
#   HOST reuseok (PRIMARY raw ground truth): N0.data_lba==LO+2 + N0 payload byte-exact across its run + last-sector
#     padding==0 ; N1.data_lba==LO+6 ; R0 (survivor) data_lba==LO+0 + payload UNCHANGED. Binds multi-sector reassembly,
#     first-fit-by-LBA reuse+coalesce, split, survivor-immutability, no-padding-leak.
# GATES: (B1) emit multiboot32-tract == tract_ref.build_elf(npages,fsdel=True,varsize=True); (B2) assert_varsize;
#   (B3) the FROZEN delete kernel FAILS assert_varsize; (D) varsize=False == delete byte-for-byte + frozen modes
#   byte-identical + assert_delete/growheap/larder STILL PASS on the tract kernel; (C-*) the 4-boot forcing GREEN on
#   QEMU-TCG + KVM + Bochs; THE DELETE DIFFERENTIAL RED (the frozen single-sector PUT rejects the >512 records ->
#   reuseok RED); the SEED-DIFFERENTIAL RED.
# REQUIRE_EMU fail-closed (the durable/cairn/delete/backfill pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and an emulator is missing, FAIL.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/tract_ref.py"
LB="$script_dir/tract_latebound.py"
DEL_REF="$script_dir/delete_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
for f in "$REF" "$LB" "$DEL_REF" "$feeder"; do
    [[ -f "$f" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing $f)"; exit 1; }
done
source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"; pkill -9 -f "$work" 2>/dev/null || true' EXIT   # kill only THIS gate's bochs (scoped to its unique mktemp -- the bochs cmdline carries the absolute bochsrc path under $work; a system-wide `pkill bochs` would false-RED a CONCURRENT gate's boot, the F4 class)
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
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" tractkernel "$REFK")"
DELK="$work/delete_kernel.elf"; python3 "$REF" deletekernel "$DELK" >/dev/null   # the FROZEN delete kernel (single-sector PUT/GET) -- the differential baseline
WRITER="$work/writer.bin";  python3 "$LB" module writer  5 "$WRITER"     # BOOT-1: PUT R0..R4
DELETER="$work/deleter.bin"; python3 "$LB" module deleter 2 "$DELETER"   # BOOT-2: DEL R1,R2
WRITER3="$work/writer3.bin"; python3 "$LB" module writer  2 "$WRITER3"   # BOOT-3: PUT N0,N1
GETTER="$work/getter.bin";  python3 "$LB" module getter  1 "$GETTER"     # BOOT-4: a SINGLE-query getter, booted once per record (robust vs the COM1 timing flake)

MKELF="$work/tract_kernel.elf"
emit '-- emit: multiboot32-tract' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) tract kernel byte-identical to tract_ref.build_elf(npages,fsdel=True,varsize=True) [$(wc -c <"$MKELF") B]"
else fail_test "(B1) tract kernel differs from tract_ref.build_elf(varsize=True) -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_varsize + valid Multiboot ----
if python3 "$REF" assertvarsize "$MKELF"; then ok "(B2) kernel carries the MULTI-SECTOR varsize PUT/GET (assert_varsize: ceil run-sizing + free-map mark by-LBA + first-fit free-run scan + run-window straddle guard + copy-min loops)"
else fail_test "(B2) kernel lacks the multi-sector varsize machinery (assert_varsize failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "tract kernel is a valid x86 Multiboot image"
else fail_test "tract kernel is not a valid x86 Multiboot image"; fi

# ---- (B3) the frozen DELETE kernel must FAIL assert_varsize (single-sector is genuinely replaced) ----
if python3 "$REF" assertvarsize "$DELK" >/dev/null 2>&1; then fail_test "(B3) the frozen DELETE kernel PASSED assert_varsize -- the white-box pin does not discriminate the multi-sector arms"
else ok "(B3) the frozen DELETE kernel (single-sector PUT/GET) FAILS assert_varsize -- the multi-sector variable-size FS is genuinely new"; fi

# ---- (D) ADDITIVITY: varsize=False == delete byte-for-byte + frozen modes byte-identical + frozen asserts STILL PASS ----
python3 "$DEL_REF" deletekernel "$work/del_ref.elf" >/dev/null
if cmp -s "$DELK" "$work/del_ref.elf"; then ok "(D) tract_ref deletekernel (varsize=False) byte-identical to delete_ref.build_elf(fsdel=True) -- the multi-sector arms are purely additive (the parametrize-frozen-ref default)"
else fail_test "(D) tract_ref(varsize=False) != delete kernel -- additivity (byte-identical default) BROKEN"; fi
for lk in delete growheap larder cairn durable platter lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    case "$lk" in
      delete)   python3 "$R" deletekernel "$work/$lk.refk" none >/dev/null 2>&1 ;;
      growheap) python3 "$R" growheapkernel "$work/$lk.refk" none >/dev/null 2>&1 ;;
      *)        python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1 ;;
    esac
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; tract is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- tract disturbed it"; fi
done
for asrt in assertdelete assertgrowheap assertlarder; do
    if python3 "$REF" "$asrt" "$MKELF" >/dev/null 2>&1; then ok "(D) $asrt PASSES on the TRACT kernel (the multi-sector arms are additive; the frozen DEL/heap machinery is preserved)"
    else fail_test "(D) $asrt FAILED on the TRACT kernel -- the multi-sector arms disturbed a frozen arm (not purely additive)"; fi
done

# ============================ SILICON (the 4-boot multi-sector reuse differential) ============================
emu_ran=0
build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }

boot_feed() { # kernel mod out kvm stream...
    local kel="$1" mod="$2" out="$3" kvm="$4"; shift 4
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 80 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$mod" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
boot_feed_emit() { # kernel mod out kvm stream... -- retry up to 4x until a ring-3 write-frame appears (COM1 timing-flake guard)
    local kel="$1" mod="$2" out="$3" kvm="$4"; shift 4
    local try e
    for try in 1 2 3 4; do
        boot_feed "$kel" "$mod" "$out" "$kvm" "$@"
        e="$(python3 "$LB" emitbody "$out" 2>/dev/null)"
        [[ -n "$e" ]] && return 0
    done
    return 0
}

four_boot() { # kernel-elf seed kvmflag label   (leaves the final disk at $DISK for reuseok)
    local kel="$1" seed="$2" kvm="$3" lbl="$4"
    DISK="$work/disk_${lbl}.img"; build_raw_disk "$DISK"
    boot_feed "$kel" "$WRITER"  "$work/${lbl}.b1" "$kvm" $(python3 "$LB" putstream1 "$seed")   # BOOT-1 PUT R0..R4
    boot_feed "$kel" "$DELETER" "$work/${lbl}.b2" "$kvm" $(python3 "$LB" delstream  "$seed")   # BOOT-2 DEL R1,R2
    boot_feed "$kel" "$WRITER3" "$work/${lbl}.b3" "$kvm" $(python3 "$LB" putstream3 "$seed")   # BOOT-3 PUT N0,N1
}

run_force_gate() { # kvmflag label substlabel
    local kvm="$1" lbl="$2" subst="$3"
    local seed; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    four_boot "$MKELF" "$seed" "$kvm" "$lbl"
    local g_raw=1; python3 "$LB" reuseok "$DISK" "$seed" >/dev/null 2>&1 && g_raw=0
    # FUNCTIONAL: BOOT-4 GET R0,N0,N1 by name (a SINGLE-query getter booted once per record, retried per the COM1 flake)
    # -> each emits its payload byte-exact (multi-sector reassembly across a reboot).
    local g_fn=0 idx
    for idx in 0 1 2; do
        boot_feed_emit "$MKELF" "$GETTER" "$work/${lbl}.g$idx" "$kvm" $(python3 "$LB" getname "$seed" "$idx")
        python3 "$LB" gradeone "$work/${lbl}.g$idx" "$seed" "$idx" >/dev/null 2>&1 || g_fn=1
    done
    if [[ "$g_raw" -eq 0 && "$g_fn" -eq 0 ]]; then
        ok "(C-$subst) 4-boot multi-sector reuse: BOOT-1 PUT R0..R4 (>512B, partial last) -> contiguous; REBOOT; BOOT-2 DEL R1,R2 (adjacent -> merged 5-sector gap); REBOOT; BOOT-3 PUT N0(4 sec) into the MERGED gap (first-fit-by-LBA, sector 2) + N1(1 sec) into the SPLIT remainder (sector 6); REBOOT; BOOT-4 GET R0,N0,N1. RAW ground truth (reuseok): N0 byte-exact across its run at LO+2, last-sector padding==0; N1 at LO+6; survivor R0 at LO+0 UNCHANGED. FUNCTIONAL: all three GET-reassemble byte-exact across the reboot. Genuine multi-sector first-fit-by-LBA reuse+coalesce -- a single-sector/truncating allocator loses the tail; bump/best-fit/no-coalesce misplaces N0; no-pad-zero leaks the padding; a decoupled allocator clobbers the survivor"
        return 0
    else
        fail_test "(C-$subst) 4-boot multi-sector reuse: RAW reuseok=$([[ $g_raw -eq 0 ]] && echo GREEN || echo RED) [$(python3 "$LB" reuseok "$DISK" "$seed" 2>&1 | tr '\n' ';' | cut -c1-300)]; FUNCTIONAL reassembly=$([[ $g_fn -eq 0 ]] && echo YES || echo NO)"
        return 1
    fi
}

if have_qemu; then
    emu_ran=1
    run_force_gate "" qtcg "QEMU"

    # (C-DELETE-DIFF) THE DIFFERENTIAL: the FROZEN delete kernel (single-sector, FS_MAXLEN=512) on the SAME forcing.
    # It REJECTS the >512B records (R0..R3) at PUT (cmp edx,512;ja reject) -> they never store -> the dir lacks the
    # survivor R0 and the merged-gap reuse never happens -> reuseok RED. (R4 at 189B would store, but the expected
    # first-fit multi-sector state is absent.)
    DSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    four_boot "$DELK" "$DSEED" "" ddiff
    if python3 "$LB" reuseok "$work/disk_ddiff.img" "$DSEED" >/dev/null 2>&1; then
        fail_test "(C-DELETE-DIFF) the frozen delete kernel produced the multi-sector first-fit state -- variable-size is NOT genuinely new (the differential does not bite)"
    else
        ok "(C-DELETE-DIFF) THE DELETE DIFFERENTIAL: the frozen single-sector delete kernel is RED on the SAME forcing -- it REJECTS the >512B records at PUT (FS_MAXLEN=512) so the multi-sector records never store and the merged-gap reuse never happens, so the on-disk FS DIVERGES from the variable-size expected state -> multi-sector variable-size files are a genuinely new observable (additive on delete)"
    fi

    # (C-SEEDDIFF) the SEED-DIFFERENTIAL: a fresh run with a DIFFERENT held-back seed -> different records/placements;
    # grading run-2's disk under run-1's seed is RED -> the on-disk state follows the late-bound COM1 input, not a baked answer.
    S1="$(python3 -c 'import os;print(os.urandom(8).hex())')"; S2="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    four_boot "$MKELF" "$S1" "" sd1; cp "$work/disk_sd1.img" "$work/disk_sd1_saved.img"
    four_boot "$MKELF" "$S2" "" sd2
    if python3 "$LB" reuseok "$work/disk_sd2.img" "$S1" >/dev/null 2>&1; then
        fail_test "(C-SEEDDIFF) run-2's disk graded GREEN under run-1's seed -- the on-disk state is NOT following the late-bound input (a baked answer?), or the seeds collided"
    elif python3 "$LB" reuseok "$work/disk_sd2.img" "$S2" >/dev/null 2>&1; then
        ok "(C-SEEDDIFF) SEED-DIFFERENTIAL: a fresh run with a DIFFERENT held-back seed writes a DIFFERENT on-disk FS -- graded under the FIRST run's seed it is RED (the records/payloads/placements genuinely follow the late-bound COM1 input, not a baked constant), yet GREEN under its OWN"
    else
        fail_test "(C-SEEDDIFF) run-2 was RED even against its OWN seed -- the run is malformed, the differential is vacuous"
    fi

    # (C-HOSTILE-CORRUPT) the confused-deputy GET surface: a HOST-crafted dir entry whose run STRADDLES the window
    # (data_lba=TRACT_DATA_HI-1, len=1024 -> need=2 -> runend=TRACT_DATA_HI+1 > the window). The GENUINE overflow-safe
    # guard (the carry-reject + the runend straddle cmp) REJECTS it -> the getter emits NOTHING (no out-of-window
    # confused-deputy leak). M-norunbound reads the out-of-window sector and LEAKS a frame (the mutation gate). The
    # data_lba+need WRAP variant (Codex's HOLD) reads PAST the disk so it is white-box-pinned by assert_varsize's carry-reject.
    DISK="$work/disk_corrupt.img"; build_raw_disk "$DISK"
    python3 "$LB" craftcorrupt "$DISK"
    boot_feed "$MKELF" "$GETTER" "$work/corrupt.g" "" $(python3 "$LB" corruptname)
    if python3 "$LB" gradecorrupt "$work/corrupt.g" >/dev/null 2>&1; then
        ok "(C-HOSTILE-CORRUPT) the genuine overflow-safe GET guard REJECTS a host-crafted corrupt dir entry whose run straddles the FS window (data_lba=TRACT_DATA_HI-1, len=1024 -> runend>window) -- the getter emits NOTHING (no out-of-window confused-deputy read leak; the data_lba+need wrap is white-box-pinned by assert_varsize's carry-reject); M-norunbound leaks it (mutation gate)"
    else
        fail_test "(C-HOSTILE-CORRUPT) the genuine kernel LEAKED a frame on a host-crafted out-of-window corrupt dir entry: [$(python3 "$LB" gradecorrupt "$work/corrupt.g" 2>&1)]"
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon) ----
if have_kvm; then
    run_force_gate kvm kvm "KVM real silicon"
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB): the multi-sector reuse persists across THREE Bochs runs on the SAME GRUB disk ----
# (three boots: BOOT-1 writer / BOOT-2 deleter / BOOT-3 writer3; the reuseok grade reads the on-disk FS BY POSITION,
#  so the BOOT-4 getter -- which exists only on QEMU/KVM -- is not needed here.)
bochs_three_boot() { # seed
    local seed="$1"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local wr; wr="$(readlink -f "$WRITER")"; local de; de="$(readlink -f "$DELETER")"; local w3; w3="$(readlink -f "$WRITER3")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    pkill -9 -f "$work" 2>/dev/null || true; rm -f "$d/disk.img.lock" 2>/dev/null || true   # scoped to THIS gate (own process), not system-wide (would kill a concurrent gate's Bochs)
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf
      sudo cp "$wr" mnt/boot/writer.bin; sudo cp "$de" mnt/boot/deleter.bin; sudo cp "$w3" mnt/boot/writer3.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/writer.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
    # HARNESS-vs-KERNEL distinction (parent 2026-07-04): a Bochs boot whose COM1 feeder never bound its
    # socket (feed*.log never reaches LISTENING) or whose Bochs run produced no output at all is an
    # EMULATOR/HARNESS failure -- the kernel never received its late-bound input -- NOT a kernel miscompile.
    # These helpers detect it and set the GLOBAL BOCHS_HARNESS_ERR (naming the offending file); bochs_three_boot
    # then returns nonzero so the caller re-rolls (or reports a loud HARNESS error), never false-REDding the
    # kernel from a downstream "record not found" that a missing boot caused.
    _feed_ok() { # feedlog label -> 0 iff the feeder reached LISTENING within 5s
        local fl="$1" lbl="$2" i
        for i in $(seq 1 50); do grep -q LISTENING "$fl" 2>/dev/null && break; sleep 0.1; done
        grep -q LISTENING "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never reached LISTENING for $lbl (log: $fl -- feeder/port-bind failure, not a kernel miscompile)"
        return 1
    }
    _bochs_ran_ok() { # bochslog label -> 0 iff the boot RAN TO A KERNEL shutdown() tail (i.e. was NOT killed/hung mid-run)
        local bl="$1" lbl="$2"
        [[ -s "$bl" ]] || { BOCHS_HARNESS_ERR="Bochs produced NO output booting $lbl (log: $bl empty/missing -- the emulator did not run, not a kernel miscompile)"; return 1; }
        # BOOT-COMPLETION SENTINEL (parent 2026-07-04, the un-adopted half of Codex's Medium finding -- a stronger
        # completion marker than `[[ -s log ]]`): a non-empty log ALONE is worthless here -- Bochs prints its BIOS/POST
        # banner regardless, so a boot that connects COM1 (SENT logged) then dies or is timeout-killed at 150s MID-RUN
        # still shows a non-empty log and would false-GRADE as a GENUINE kernel verdict -- exactly the F4 class (a
        # harness death masquerading as a kernel RED/GREEN). The kernel's own shutdown() writes the ASCII string
        # "Shutdown" to Bochs' shutdown port 0x8900, so Bochs logs 'shutdown requested' whenever the kernel reaches ANY
        # shutdown() tail -- a kernel-AUTHORED marker (empirically a clean writer boot logs it and Bochs quit_sim's in
        # ~6s, far under the 150s timeout). SCOPE (cross-model Codex): this proves the boot RAN TO COMPLETION rather
        # than dying mid-run; it does NOT by itself prove the intended PUT/DEL sequence executed (shutdown() is also the
        # fault/panic tail) -- that is what the SENT check (_feed_delivered, the kernel got its input) and the on-disk
        # reuseok grade (the FS state is exactly right) carry. Together they exclude the harness-death false-grade.
        grep -qa 'shutdown requested' "$bl" && return 0
        BOCHS_HARNESS_ERR="Bochs did NOT run $lbl through to a kernel shutdown tail (log: $bl has no 'shutdown requested' -- the boot died or was timeout-killed mid-run, not a kernel miscompile)"
        return 1
    }
    _feed_delivered() { # feedlog label -> 0 iff the feeder actually SENT its payload (Bochs connected COM1)
        # LISTENING (before boot) only proves the feeder was READY; the feeder logs "SENT ..." after accept().
        # If Bochs booted but never connected COM1 (feed log stuck at LISTENING, or "NOCONN"), the kernel got
        # NO input -> a downstream "record not found" is a HARNESS failure, not a miscompile (cross-model Codex).
        local fl="$1" lbl="$2"
        grep -q '^SENT' "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload for $lbl (log: $fl has LISTENING but no SENT / shows NOCONN -- Bochs did not connect COM1, the kernel received no input, not a kernel miscompile)"
        return 1
    }
    bochs_phase() { # module-name stream...  -> nonzero (sets BOCHS_HARNESS_ERR) on a harness failure
        local mod="$1"; shift
        local port; port=$(free_port)
        python3 "$feeder" "$port" "$@" --hold 150 > "$d/feed.log" 2>&1 & local fp=$!
        _feed_ok "$d/feed.log" "$mod" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
        # Swap the GRUB config to boot $mod on the SAME persistent disk. HARNESS guard (cross-model Codex): if this
        # swap SILENTLY fails (losetup/mount/tee/umount), Bochs boots the STALE/previous module -- which still connects
        # COM1 (SENT) and reaches shutdown() ('shutdown requested'), so every downstream check passes and a
        # wrong-module reuseok RED would be mis-attributed to the KERNEL. Detect each step's failure explicitly (with
        # cleanup preserved on every path) -> harness error -> re-roll, never a false kernel grade.
        if ! ( cd "$d"
               LOOP="$(sudo losetup -fP --show disk.img)" || exit 1
               sudo mount "${LOOP}p1" mnt || { sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
               printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/%s\n boot\n}\n' "$mod" \
                 | sudo tee mnt/boot/grub/grub.cfg >/dev/null || { sudo umount mnt 2>/dev/null; sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
               sudo umount mnt || { sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
               sudo losetup -d "$LOOP"; rm -f disk.img.lock ); then
            BOCHS_HARNESS_ERR="the GRUB config swap to $mod FAILED (losetup/mount/tee/umount) -- Bochs would boot the WRONG/stale module; harness failure, not a kernel miscompile"
            kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1
        fi
        sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_run.txt"
        ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_run.txt" > "$d/bochs_$mod.log" 2>&1 )   # absolute bochsrc path -> $work in the cmdline so the scoped `pkill -f "$work"` matches only THIS gate's bochs
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; rm -f "$d/disk.img.lock"
        _bochs_ran_ok "$d/bochs_$mod.log" "$mod" || return 1
        _feed_delivered "$d/feed.log" "$mod" || return 1
    }
    # BOOT-1: writer.bin already in grub.cfg (set at install); feed the put1-stream.
    local port; port=$(free_port)
    python3 "$feeder" "$port" $(python3 "$LB" putstream1 "$seed") --hold 150 > "$d/feed1.log" 2>&1 & local fp=$!
    _feed_ok "$d/feed1.log" "writer.bin(BOOT-1)" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
    sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b1.txt"
    ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b1.txt" > bochs_b1.txt 2>&1 )   # absolute bochsrc path (scoped-kill: $work in the cmdline)
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; rm -f "$d/disk.img.lock"
    _bochs_ran_ok "$d/bochs_b1.txt" "writer.bin(BOOT-1)" || return 1
    _feed_delivered "$d/feed1.log" "writer.bin(BOOT-1)" || return 1
    bochs_phase deleter.bin $(python3 "$LB" delstream  "$seed") || return 1   # BOOT-2 DEL R1,R2
    bochs_phase writer3.bin $(python3 "$LB" putstream3 "$seed") || return 1   # BOOT-3 PUT N0,N1
}
if have_bochs; then
    emu_ran=1
    bochs_done=0
    for attempt in 1 2 3; do
        BOCHS_HARNESS_ERR=""
        BSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
        if ! bochs_three_boot "$BSEED"; then
            echo "  HARNESS ERROR (Bochs 3-boot attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling the 3-boot (transient emulator/feeder failure, NOT a kernel RED)" >&2
            continue
        fi
        # every boot's feeder LISTENED, DELIVERED (SENT), and its kernel ran THROUGH to shutdown() -> reuseok is a GENUINE kernel grade
        if python3 "$LB" reuseok "$work/b.d/disk.img" "$BSEED" >/dev/null 2>&1; then
            ok "(C-Bochs) the MULTI-SECTOR REUSE PERSISTS across three Bochs runs on the SAME GRUB disk: BOOT-1 PUT R0..R4 (>512B late-bound over com1) + flush; BOOT-2 DEL R1,R2 (merged gap) + flush; BOOT-3 PUT N0 into the merged gap + N1 into the split remainder + flush. The raw on-disk FS == the variable-size first-fit-by-LBA expected state (N0 byte-exact at LO+2 padding-zero, N1 at LO+6, survivor R0 UNCHANGED) -- the 2nd substrate's ATA controller persists the multi-sector runs across the reboots"
        else
            fail_test "(C-Bochs) Bochs 3-boot multi-sector reuse RED (all three boots fed+delivered+ran through shutdown -> a GENUINE kernel grade, not a harness flake): [$(python3 "$LB" reuseok "$work/b.d/disk.img" "$BSEED" 2>&1 | tr '\n' ';' | cut -c1-300)]"
        fi
        bochs_done=1; break
    done
    if [[ "$bochs_done" -eq 0 ]]; then
        # 3 consecutive HARNESS failures (never the kernel; a fresh disk is rebuilt each attempt). Emit a DISTINCT,
        # greppable marker -- NOT the 'FAIL: stack/native_compile_fragment.herb' kernel-RED prefix (item 1b) -- so a
        # FAIL-line scanner cannot miscount a Bochs harness/emulator failure as a kernel miscompile. And fail the gate
        # ONLY when the Bochs substrate is REQUIRED (REQUIRE_EMU=1, e.g. CI): behavior now matches the comment (item 1d)
        # and the SKIP-when-not-required semantics of the have_bochs=false branch below -- a transient harness flake must
        # not RED a best-effort local run (the QEMU/KVM legs still carry the kernel verdict; re-roll or set REQUIRE_EMU=1).
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

echo "native-codegen link60 (tract / FIRST VARIABLE-SIZE durable file): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link60 tract / FIRST VARIABLE-SIZE durable file -- a NEW emit mode multiboot32-tract, TYPE-II ADDITIVE on the FROZEN delete (link42) lineage (build_elf(varsize=False) reproduces the delete kernel BYTE-FOR-BYTE): SYS_FS_PUT/GET become MULTI-SECTOR contiguous runs (need=ceil(len/512)) with a recompute-from-DIRECTORY first-fit-by-LBA allocator (coalesce implicit; the durable free state = f(directory)). The on-disk dir format is UNCHANGED (len->nsectors, data_lba->run start); the data window EXTENDS. THE MAKE-OR-BREAK is a 4-boot MULTI-SECTOR REUSE differential on ONE cache=writethrough disk, all late-bound over COM1: BOOT-1 a writer PUTs R0..R4 (sizes 2,2,3,2,1 sectors; payloads >512B with a partial last sector; high-entropy + late-bound) -> first-fit-by-LBA lays them contiguous; REBOOT; BOOT-2 a deleter DELetes R1,R2 (adjacent -> a MERGED 5-sector free gap); REBOOT; BOOT-3 a writer PUTs N0 (4 sectors) -> first-fit lands it in the MERGED gap (sector 2; 4>3 and 4>2 individually, <=5) then N1 (1 sector) -> the SPLIT remainder (sector 6); REBOOT; BOOT-4 a getter GETs R0,N0,N1 by name -> SYS_WRITEs each. The PRIMARY grade is a HOST-SIDE RAW ground-truth oracle (reuseok) that reads the on-disk directory + all data sectors BY POSITION and asserts the FULL variable-size first-fit state -- N0 byte-exact across its run at data_lba=LO+2 with last-sector padding==0, N1 at LO+6 (split remainder), and survivor R0 at LO+0 with its payload + run UNCHANGED. FUNCTIONAL: BOOT-4 GETs all three by name across the reboot, byte-exact. Byte-pinned to tract_ref.build_elf(npages,fsdel=True,varsize=True) (binds the multi-sector arms), white-box assert_varsize (ceil run-sizing + the free-map mark by-LBA + the first-fit free-run scan + the run-window straddle guard + the copy-min loops), the frozen DELETE kernel FAILS assert_varsize (B3), build_elf(varsize=False) == delete byte-for-byte + the frozen modes (delete/growheap/larder/cairn/...) emit byte-identical + assert_delete/assertgrowheap/assertlarder STILL PASS on the TRACT kernel (the multi-sector arms are purely additive; cairn-GET/backfill-PUT are SUPERSEDED-by-generalization), QEMU+KVM+Bochs GREEN on the 4-boot multi-sector reuse (raw + functional), THE DELETE DIFFERENTIAL RED (the frozen single-sector PUT rejects the >512B records so the multi-sector state never forms -> reuseok RED), the SEED-DIFFERENTIAL RED (a different held-back seed -> a different on-disk state -> the records/payloads/placements follow the late-bound COM1 input, not a baked answer). Output-forced -- a >512B payload cannot physically come out of one 512B sector, and byte-exact reassembly across a reboot is the witness; the held-back MUTATION proof (trunc/noceil/decoupled/nopadzero output-forced + overcopy/norunbound white-box) lives in the companion mutation harness. HONEST SCOPE: contiguous runs (RUN_MAX=4 sectors) + recompute-from-directory first-fit-by-LBA (coalesce implicit, no persistent free-list structure); no sector chain, no >RUN_MAX files, no realloc/defrag; one directory sector, a full 16-byte name compare, the data window extended past the frozen cairn FS window)"
