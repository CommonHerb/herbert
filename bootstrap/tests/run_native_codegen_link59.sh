#!/usr/bin/env bash
# native-codegen link59 (kernel-arc link 43) = backfill / mutable-FS PUT FIRST-FREE-SLOT REUSE (pays LEDGER D22).
# A NEW emit mode `multiboot32-backfill`, TYPE-II ADDITIVE on the FROZEN delete (link 42) lineage: SYS_FS_PUT switches
# from append-by-count to FIRST-FREE-SLOT allocation (the lowest valid==0 hole; data_lba = FS_DATA_LO + freeslot), so a
# PUT after a NON-TAIL delete reuses the tombstoned hole instead of colliding with a live entry. fsreuse=False reproduces
# the delete kernel BYTE-FOR-BYTE; the on-disk FS format is UNCHANGED (the 1:1 data_lba==FS_DATA_LO+slot invariant holds).
#
# THE MAKE-OR-BREAK is a CAPACITY-EXHAUSTION + LOWEST-SCAN 4-boot reuse differential on ONE cache=writethrough disk:
#   BOOT-1 filler: PUT FS_D author-unknown records over COM1 -> the directory is FULL (slots 0..7, sectors LO+0..7).
#   BOOT-2 multi-deleter: SYS_FS_DEL THREE records at holes {0, i, j} (slot 0 + two interior) in a SCRAMBLED order
#          [i, j, 0] -> a FIFO free-list (deletion order) AND a LIFO free-list (reverse) BOTH diverge from a genuine
#          lowest-among-ALL scan, and including slot 0 kills a scan-from-slot-1 forge; highest live index stays FS_D-1.
#   BOOT-3 putter: PUT three NEW author-unknown records. GENUINE first-free: D0->slot 0, D1->slot i, D2->slot j (lowest-first),
#          data_lba=LO+slot, survivors UNTOUCHED. Append-by-count (the frozen delete kernel) writes slot count=FS_D-2
#          -> CLOBBERS a live survivor; tail/monotonic forges reject at the D boundary -> the new record is lost.
#   BOOT-4 getter (functional confirm): GET each NEW record by name across the reboot -> emit its payload.
#   HOST (PRIMARY, ground truth): reuseok() reads the on-disk dir + all FS_D data sectors BY POSITION and asserts the FULL
#          first-free expected state -- binds reuse (new records in the freed holes lowest-first, 1:1 data_lba, freed
#          sectors carry the new payloads) AND survivor-immutability (every survivor slot + raw sector UNCHANGED, which
#          also excludes a compaction forge that reuses by shifting survivors). The link-42 raw-oracle lesson carried fwd.
# GATES: (B1) emit multiboot32-backfill == backfill_ref.build_elf(fsreuse=True); (B2) white-box assert_backfill (the
#   first-free scan break cmp;jne + slot-from-scan-index 89 0D fs_nent + freeslot data_lba + NO append-by-count A3 store);
#   (B3) the FROZEN delete kernel FAILS assert_backfill (append-by-count is genuinely replaced); (D) fsreuse=False ==
#   delete byte-for-byte + every frozen emit mode byte-identical + assert_cairn/delete/growheap/larder STILL PASS on the
#   backfill kernel; (C-*) the 4-boot reuse forcing GREEN on QEMU-TCG + KVM + Bochs; THE DELETE DIFFERENTIAL RED (the
#   frozen append-by-count kernel corrupts a survivor / loses the new record -> reuseok RED); the SEED-DIFFERENTIAL RED.
# REQUIRE_EMU fail-closed (the durable/cairn/delete pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and an emulator is missing, FAIL.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/backfill_ref.py"
LB="$script_dir/backfill_latebound.py"
DEL_REF="$script_dir/delete_ref.py"
GH_REF="$script_dir/growheap_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
for f in "$REF" "$LB" "$DEL_REF" "$feeder"; do
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

read -r FS_DIR FS_LO FS_HI FS_D < <(python3 "$REF" fswindow)

# ---- reference artifacts ----
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" backfillkernel "$REFK")"
DELK="$work/delete_kernel.elf"; python3 "$REF" deletekernel "$DELK" >/dev/null    # the FROZEN delete kernel (append-by-count) -- the differential baseline
FILLER="$work/filler.bin"; python3 "$LB" filler "$FILLER"            # BOOT-1: PUT FS_D records (fill the directory)
MULTIDEL="$work/multidel.bin"; python3 "$LB" multideleter "$MULTIDEL" 3   # BOOT-2: DEL three names (slot 0 + two interior) in scrambled order
PUTTER2="$work/putter2.bin"; python3 "$LB" putter2 "$PUTTER2"        # BOOT-3: PUT three NEW records
GETTER="$work/getter.bin"; python3 "$LB" getter "$GETTER"            # BOOT-4: GET one record -> emit payload (functional confirm)
PUT1="$work/put1.bin"; python3 "$LB" put1 "$PUT1"                    # the 9th PUT into a FULL directory (must be rejected -- C-FULLREJECT)

MKELF="$work/backfill_kernel.elf"
emit '-- emit: multiboot32-backfill' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) backfill kernel byte-identical to backfill_ref.build_elf(fsreuse=True) [$(wc -c <"$MKELF") B]"
else fail_test "(B1) backfill kernel differs from backfill_ref.build_elf(fsreuse=True) -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_backfill ----
if python3 "$REF" assertbackfill "$MKELF"; then ok "(B2) kernel carries the FIRST-FREE-SLOT PUT (assert_backfill: the scan break cmp dword[esi],1;jne + slot-from-scan-index mov[fs_nent],ecx + the freeslot data_lba mov eax,ecx;add FS_DATA_LO;mov[fs_lba] + NO append-by-count A3 fs_nent store)"
else fail_test "(B2) kernel lacks the FIRST-FREE-SLOT PUT (assert_backfill failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "backfill kernel is a valid x86 Multiboot image"
else fail_test "backfill kernel is not a valid x86 Multiboot image"; fi

# ---- (B3) the frozen DELETE kernel must FAIL assert_backfill (append-by-count is genuinely replaced) ----
if python3 "$REF" assertbackfill "$DELK" >/dev/null 2>&1; then fail_test "(B3) the frozen DELETE kernel PASSED assert_backfill -- the white-box pin does not discriminate the first-free PUT"
else ok "(B3) the frozen DELETE kernel (append-by-count PUT) FAILS assert_backfill -- the FIRST-FREE-SLOT allocator is genuinely new"; fi

# ---- (D) ADDITIVITY: fsreuse=False == delete byte-for-byte + frozen prior modes byte-identical + frozen asserts STILL PASS ----
if cmp -s "$DELK" <(python3 "$DEL_REF" deletekernel /dev/stdout 2>/dev/null); then ok "(D) backfill_ref deletekernel (fsreuse=False) byte-identical to delete_ref.build_elf(fsdel=True) -- the first-free PUT is purely additive (the parametrize-frozen-ref default)"
else
  python3 "$DEL_REF" deletekernel "$work/del_ref.elf" >/dev/null
  if cmp -s "$DELK" "$work/del_ref.elf"; then ok "(D) backfill_ref deletekernel (fsreuse=False) byte-identical to delete_ref.build_elf(fsdel=True) -- the first-free PUT is purely additive"
  else fail_test "(D) backfill_ref(fsreuse=False) != delete kernel -- additivity (byte-identical default) BROKEN"; fi
fi
for lk in delete growheap larder cairn durable platter lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    case "$lk" in
      delete)   python3 "$R" deletekernel "$work/$lk.refk" none >/dev/null 2>&1 ;;
      growheap) python3 "$R" growheapkernel "$work/$lk.refk" none >/dev/null 2>&1 ;;
      *)        python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1 ;;
    esac
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; backfill is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- backfill disturbed it"; fi
done
for asrt in assertcairn assertdelete assertgrowheap assertlarder; do
    if python3 "$REF" "$asrt" "$MKELF" >/dev/null 2>&1; then ok "(D) $asrt PASSES on the BACKFILL kernel (the first-free PUT is additive; the frozen FS/heap/DEL machinery is preserved)"
    else fail_test "(D) $asrt FAILED on the BACKFILL kernel -- the first-free PUT disturbed a frozen arm (not purely additive)"; fi
done

# ============================ SILICON (the 4-boot capacity-exhaustion reuse differential) ============================
emu_ran=0
build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }   # 64 MiB: the cairn FS lives at LBA ~120064 (~58.6 MiB)

boot_feed() { # kernel mod out kvm stream...
    local kel="$1" mod="$2" out="$3" kvm="$4"; shift 4
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$mod" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
# a GETTER that MUST emit -- retry up to 4x until the debugcon carries a closed UCODE3 write-frame (a rare EMPTY is the
# COM1/debugcon timing flake; retrying never converts a mutant's deterministic RED to GREEN). Used ONLY for the survivor/new GET.
boot_feed_emit() { # kernel mod out kvm stream...
    local kel="$1" mod="$2" out="$3" kvm="$4"; shift 4
    local try e
    for try in 1 2 3 4; do
        boot_feed "$kel" "$mod" "$out" "$kvm" "$@"
        e="$(python3 "$LB" emitbody "$out" 2>/dev/null)"
        [[ -n "$e" && "$e" != "NO-TABLE" ]] && return 0
    done
    return 0
}

# full 4-boot reuse for (kernel, fillseed, newseed, kvm, label). Leaves the final disk at $DISK for reuseok().
four_boot_reuse() { # kernel-elf fillseed newseed kvmflag label
    local kel="$1" fseed="$2" nseed="$3" kvm="$4" lbl="$5"
    DISK="$work/disk_${lbl}.img"; build_raw_disk "$DISK"
    local fillstream delstream newstream
    fillstream="$(python3 "$LB" fillstream "$fseed")"     # FS_D records -> fill the directory
    delstream="$(python3 "$LB" delstream "$fseed")"       # three names {0,i,j} in scrambled del-order
    newstream="$(python3 "$LB" newstream "$nseed")"       # three NEW records
    boot_feed "$kel" "$FILLER"   "$work/${lbl}.b1" "$kvm" $fillstream   # BOOT-1: fill (slots 0..FS_D-1)
    boot_feed "$kel" "$MULTIDEL" "$work/${lbl}.b2" "$kvm" $delstream    # BOOT-2: DEL three holes {0,i,j} (scrambled order)
    boot_feed "$kel" "$PUTTER2"  "$work/${lbl}.b3" "$kvm" $newstream    # BOOT-3: PUT three NEW records (reuse the holes)
}

run_reuse_gate() { # kvmflag label substlabel
    local kvm="$1" lbl="$2" subst="$3"
    local fseed nseed; fseed="$(python3 -c 'import os;print(os.urandom(8).hex())')"; nseed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    four_boot_reuse "$MKELF" "$fseed" "$nseed" "$kvm" "$lbl"
    local g_raw=1; python3 "$LB" reuseok "$DISK" "$fseed" "$nseed" >/dev/null 2>&1 && g_raw=0
    # FUNCTIONAL confirm: BOOT-4 GET each NEW record by name across a reboot -> its payload (the reuse produced findable records).
    local g_fn=0 idx nm pay q em
    for idx in 0 1 2; do
        read -r nm pay < <(python3 "$LB" newrec "$nseed" "$idx")
        q="$(python3 "$LB" querystream "$nm")"
        boot_feed_emit "$MKELF" "$GETTER" "$work/${lbl}.g$idx" "$kvm" $q
        python3 "$LB" gradefs "$work/${lbl}.g$idx" "$KEND" "$pay" >/dev/null 2>&1 || g_fn=1
    done
    if [[ "$g_raw" -eq 0 && "$g_fn" -eq 0 ]]; then
        ok "(C-$subst) 4-boot capacity-exhaustion reuse: BOOT-1 fill FS_D=$FS_D slots; REBOOT; BOOT-2 DEL three holes {0,i,j} (slot 0 + two interior) in a SCRAMBLED order; REBOOT; BOOT-3 PUT three NEW records. RAW ground truth (reuseok): the three new records occupy the freed holes LOWEST-among-ALL-FIRST (D0->slot0, D1->i, D2->j) with 1:1 data_lba + the freed data sectors carry the new payloads, and EVERY survivor slot + raw sector is UNCHANGED. FUNCTIONAL: all NEW records GET-resolve by name across the reboot. Genuine first-free-slot REUSE -- append-by-count clobbers a live survivor, scan-from-1 skips slot 0, FIFO/LIFO free-lists pick the wrong hole"
        return 0
    else
        fail_test "(C-$subst) 4-boot reuse: RAW reuseok=$([[ $g_raw -eq 0 ]] && echo GREEN || echo RED) [$(python3 "$LB" reuseok "$DISK" "$fseed" "$nseed" 2>&1 | tr '\n' ';' | cut -c1-300)]; FUNCTIONAL new-records-resolve=$([[ $g_fn -eq 0 ]] && echo YES || echo NO)"
        return 1
    fi
}

if have_qemu; then
    emu_ran=1
    run_reuse_gate "" qtcg "QEMU"

    # (C-DELETE-DIFF) THE DELETE DIFFERENTIAL: the FROZEN delete kernel (append-by-count PUT) on the SAME 4-boot forcing.
    # After fill+DEL three holes {0,i,j}, count(valid==1)=FS_D-3; the BOOT-3 PUT writes slot FS_D-3 (a LIVE survivor) ->
    # clobbers it, then the 2nd PUT recomputes the same count -> clobbers again; the freed holes stay empty -> reuseok RED.
    DFSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"; DNSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    four_boot_reuse "$DELK" "$DFSEED" "$DNSEED" "" ddiff
    if python3 "$LB" reuseok "$work/disk_ddiff.img" "$DFSEED" "$DNSEED" >/dev/null 2>&1; then
        fail_test "(C-DELETE-DIFF) the frozen delete kernel (append-by-count) produced the first-free expected state -- reuse is NOT genuinely new (the differential does not bite)"
    else
        ok "(C-DELETE-DIFF) THE DELETE DIFFERENTIAL: the frozen delete kernel's append-by-count PUT on the SAME forcing is RED -- after DELeting three holes {0,i,j} it allocates slot count(valid==1) (a LIVE survivor) and clobbers it while the freed holes stay empty, so the on-disk FS DIVERGES from the first-free expected state -> first-free-slot reuse is a genuinely new observable (additive on delete, which has the tombstone but the old append-by-count PUT)"
    fi

    # (C-SEEDDIFF) the SEED-DIFFERENTIAL: a fresh run with a DIFFERENT held-back newseed -> different new records;
    # grading run-2's disk under run-1's (fillseed,newseed) is RED -> the on-disk state follows the late-bound input.
    SF1="$(python3 -c 'import os;print(os.urandom(8).hex())')"; SN1="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    four_boot_reuse "$MKELF" "$SF1" "$SN1" "" sd1
    cp "$work/disk_sd1.img" "$work/disk_sd1_saved.img"
    SF2="$SF1"; SN2="$(python3 -c 'import os;print(os.urandom(8).hex())')"   # SAME fill, DIFFERENT new records
    four_boot_reuse "$MKELF" "$SF2" "$SN2" "" sd2
    if python3 "$LB" reuseok "$work/disk_sd2.img" "$SF1" "$SN1" >/dev/null 2>&1; then
        fail_test "(C-SEEDDIFF) run-2's disk graded GREEN under run-1's new-records -- the on-disk state is NOT following the late-bound input (a baked answer?), or the seeds collided"
    elif python3 "$LB" reuseok "$work/disk_sd2.img" "$SF2" "$SN2" >/dev/null 2>&1; then
        ok "(C-SEEDDIFF) SEED-DIFFERENTIAL: a fresh run with DIFFERENT held-back new records writes a DIFFERENT on-disk FS -- graded under the FIRST run's new records it is RED (the reuse genuinely follows the late-bound COM1 input, not a baked constant), yet GREEN under its OWN"
    else
        fail_test "(C-SEEDDIFF) run-2 was RED even against its OWN seeds -- the run is malformed, the differential is vacuous"
    fi

    # (C-FULLREJECT) the first-free no-free-slot path (otherwise UNEXERCISED by the reuse forcing, which never PUTs into a
    # full dir): BOOT-1 fill all FS_D slots; BOOT-2 PUT a 9th record into the FULL directory -> the scan finds NO free slot
    # (ecx reaches FS_D -> jae fs_put_reject) and must REJECT with NO write. fulldirok asserts the directory is UNDISTURBED
    # (FS_D live slots, all the original names, the 9th name ABSENT) AND the sector ONE PAST the data window is ALL-ZERO
    # (the first-free PUT does not bound fs_lba, so this proves slot<FS_D actually gates the write -- no out-of-window PUT).
    FRF="$(python3 -c 'import os;print(os.urandom(8).hex())')"; FRN="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    DISK="$work/disk_fullrej.img"; build_raw_disk "$DISK"
    boot_feed "$MKELF" "$FILLER" "$work/fr.b1" "" $(python3 "$LB" fillstream "$FRF")     # fill all FS_D slots
    boot_feed "$MKELF" "$PUT1"   "$work/fr.b2" "" $(python3 "$LB" put1stream "$FRN")     # PUT a 9th record into the FULL dir
    if python3 "$LB" fulldirok "$DISK" "$FRF" "$FRN" >/dev/null 2>&1; then
        ok "(C-FULLREJECT) a PUT into a FULL directory (all FS_D slots valid) is REJECTED by the first-free scan (no free slot -> jae fs_put_reject), with NO write: the directory is UNDISTURBED (FS_D live slots, original names, the 9th name absent) and the sector one PAST the data window (FS_DATA_LO+FS_D) is ALL-ZERO -- the slot<FS_D bound is the sole guard against an out-of-window PUT write, and it holds"
    else
        fail_test "(C-FULLREJECT) a full-directory PUT was NOT cleanly rejected: [$(python3 "$LB" fulldirok "$DISK" "$FRF" "$FRN" 2>&1 | tr '\n' ';' | cut -c1-220)]"
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon): the 4-boot reuse on the real chipset ----
if have_kvm; then
    run_reuse_gate kvm kvm "KVM real silicon"
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB): the reuse persists across THREE Bochs runs on the SAME GRUB disk ----
# (three boots: BOOT-1 filler / BOOT-2 multi-deleter / BOOT-3 putter; the reuseok grade reads the on-disk FS BY
#  POSITION, so the BOOT-4 getter -- which exists only on QEMU/KVM -- is not needed here.) HARNESS-vs-KERNEL
#  hardening ported from the link60 reference (F2 sweep 2026-07-04): every boot must LISTEN + deliver (SENT) +
#  swap-GRUB cleanly + run THROUGH the kernel's shutdown() tail, else it is a re-rollable HARNESS failure, never
#  a false kernel RED.
bochs_three_boot_reuse() { # fillstream delstream newstream  -> nonzero (sets BOCHS_HARNESS_ERR) on a harness failure
    local fillstream="$1" delstream="$2" newstream="$3"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local fi; fi="$(readlink -f "$FILLER")"; local md; md="$(readlink -f "$MULTIDEL")"; local p2; p2="$(readlink -f "$PUTTER2")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    pkill -9 -f "$work" 2>/dev/null || true   # scoped to THIS gate (own process), not system-wide (would kill a concurrent gate's Bochs)
    rm -f "$d/disk.img.lock" 2>/dev/null || true
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf
      sudo cp "$fi" mnt/boot/filler.bin; sudo cp "$md" mnt/boot/multidel.bin; sudo cp "$p2" mnt/boot/putter2.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/filler.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
    # Harness-failure detectors (F2 sweep, mirror of the link60 reference). Each sets the GLOBAL BOCHS_HARNESS_ERR
    # (naming the offending file) and returns nonzero so the caller re-rolls, never false-REDding the kernel.
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
        # The kernel's own shutdown() writes "Shutdown" to Bochs' shutdown port 0x8900, so Bochs logs 'shutdown
        # requested' whenever the kernel reaches a shutdown() tail -- a kernel-AUTHORED marker that the boot RAN TO
        # COMPLETION (not a mid-run death; `[[ -s log ]]` alone is worthless, Bochs always prints a BIOS banner). The
        # SENT check + the on-disk reuseok grade carry FS-correctness. grep -a: the Bochs log is binary.
        grep -qa 'shutdown requested' "$bl" && return 0
        BOCHS_HARNESS_ERR="Bochs did NOT run $lbl through to a kernel shutdown tail (log: $bl has no 'shutdown requested' -- the boot died or was timeout-killed mid-run, not a kernel miscompile)"
        return 1
    }
    _feed_delivered() { # feedlog label -> 0 iff the feeder actually SENT its payload (Bochs connected COM1)
        local fl="$1" lbl="$2"
        grep -q '^SENT' "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload for $lbl (log: $fl has LISTENING but no SENT / shows NOCONN -- Bochs did not connect COM1, the kernel received no input, not a kernel miscompile)"
        return 1
    }
    bochs_phase() { # module-name stream logfile  -> nonzero (sets BOCHS_HARNESS_ERR) on a harness failure
        local mod="$1" stream="$2" logf="$3"
        local port; port=$(free_port)
        python3 "$feeder" "$port" $stream --hold 150 > "$d/feed.log" 2>&1 & local fp=$!
        _feed_ok "$d/feed.log" "$mod" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
        # Swap the GRUB config to boot $mod on the SAME persistent disk. HARNESS guard (cross-model Codex): a SILENT
        # swap failure (losetup/mount/tee/umount) boots the STALE/previous module -- which still SENTs + reaches
        # shutdown() -- so a wrong-module reuseok RED would be mis-attributed to the kernel. Detect each step (cleanup
        # preserved on every path) -> harness error -> re-roll.
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
        ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_run.txt" > "$logf" 2>&1 )   # absolute bochsrc path -> $work in the cmdline so the scoped `pkill -f "$work"` matches only THIS gate's bochs
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        rm -f "$d/disk.img.lock"
        _bochs_ran_ok "$logf" "$mod" || return 1
        _feed_delivered "$d/feed.log" "$mod" || return 1
    }
    # BOOT-1: filler.bin already in grub.cfg (set at install); feed the fill-stream.
    local port; port=$(free_port)
    python3 "$feeder" "$port" $fillstream --hold 150 > "$d/feed1.log" 2>&1 & local fp=$!
    _feed_ok "$d/feed1.log" "filler.bin(BOOT-1)" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
    sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b1.txt"
    ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b1.txt" > bochs_b1.txt 2>&1 )   # absolute bochsrc path (scoped-kill: $work in the cmdline)
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    rm -f "$d/disk.img.lock"
    _bochs_ran_ok "$d/bochs_b1.txt" "filler.bin(BOOT-1)" || return 1
    _feed_delivered "$d/feed1.log" "filler.bin(BOOT-1)" || return 1
    bochs_phase multidel.bin "$delstream" "$d/bochs_b2.txt" || return 1   # BOOT-2: DEL three holes {0,i,j} (scrambled order)
    bochs_phase putter2.bin  "$newstream" "$d/bochs_b3.txt" || return 1   # BOOT-3: PUT three NEW records (reuse)
}
if have_bochs; then
    emu_ran=1
    bochs_done=0
    for attempt in 1 2 3; do
        BOCHS_HARNESS_ERR=""
        BF="$(python3 -c 'import os;print(os.urandom(8).hex())')"; BN="$(python3 -c 'import os;print(os.urandom(8).hex())')"
        BFILL="$(python3 "$LB" fillstream "$BF")"; BDEL="$(python3 "$LB" delstream "$BF")"; BNEW="$(python3 "$LB" newstream "$BN")"
        if ! bochs_three_boot_reuse "$BFILL" "$BDEL" "$BNEW"; then
            echo "  HARNESS ERROR (Bochs 3-boot attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling the 3-boot (transient emulator/feeder failure, NOT a kernel RED)" >&2
            continue
        fi
        # every boot LISTENED + delivered (SENT) + swapped GRUB cleanly + ran THROUGH shutdown() -> reuseok is a GENUINE kernel grade
        if python3 "$LB" reuseok "$work/b.d/disk.img" "$BF" "$BN" >/dev/null 2>&1; then
            ok "(C-Bochs) the REUSE PERSISTS across three Bochs runs on the SAME GRUB disk: BOOT-1 filler PUT FS_D records (late-bound over com1) + flush; BOOT-2 multi-deleter DEL three holes {0,i,j} (scrambled order) + flush; BOOT-3 putter PUT three NEW records into the freed holes + flush. The raw on-disk FS == the first-free expected state (new records in the holes lowest-first, 1:1 data_lba, freed sectors carry the new payloads, survivors UNCHANGED) -- the 2nd substrate's ATA controller persists the reuse across the reboots (the software-RESET prologue Bochs needs is inherited from durable). NOTE on the CACHE FLUSH: empirically this Bochs (like QEMU writethrough) persists writes even WITHOUT the 0xE7 flush, so the flush is OUTPUT-INVISIBLE on every available substrate and is caught only WHITE-BOX (inherited assert_delete); it is for real-hardware power-cut durability"
        else
            fail_test "(C-Bochs) Bochs 3-boot reuse RED (all three boots fed+delivered+ran through shutdown -> a GENUINE kernel grade, not a harness flake): [$(python3 "$LB" reuseok "$work/b.d/disk.img" "$BF" "$BN" 2>&1 | tr '\n' ';' | cut -c1-300)]"
        fi
        bochs_done=1; break
    done
    if [[ "$bochs_done" -eq 0 ]]; then
        # 3 consecutive HARNESS failures (never the kernel; a fresh disk each attempt). Distinct greppable marker (NOT
        # the 'FAIL: stack/native_compile_fragment.herb' kernel-RED prefix) so a FAIL-line scanner does not miscount a
        # harness/emulator failure as a kernel miscompile; fail the gate ONLY when the Bochs substrate is REQUIRED
        # (REQUIRE_EMU=1, e.g. CI), matching the have_bochs=false branch -- a transient flake must not RED a best-effort local run.
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

echo "native-codegen link59 (backfill / mutable-FS PUT FIRST-FREE-SLOT REUSE -- pays D22): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link59 backfill / mutable-FS PUT FIRST-FREE-SLOT REUSE -- pays LEDGER D22. A NEW emit mode multiboot32-backfill, TYPE-II ADDITIVE on the FROZEN delete (link42) lineage (build_elf(fsreuse=False) reproduces the delete kernel BYTE-FOR-BYTE): SYS_FS_PUT switches from append-by-count to FIRST-FREE-SLOT allocation (the lowest valid==0 hole; data_lba = FS_DATA_LO + freeslot), so a PUT after a NON-TAIL delete reuses the tombstoned hole instead of colliding with a live entry. The on-disk FS format is UNCHANGED (the 1:1 data_lba==FS_DATA_LO+slot invariant holds). THE MAKE-OR-BREAK is a CAPACITY-EXHAUSTION + LOWEST-SCAN 4-boot reuse differential on ONE cache=writethrough disk image: BOOT-1 a filler reads FS_D=$FS_D author-unknown records over COM1 and SYS_FS_PUTs them (the directory is FULL: slots 0..FS_D-1, data sectors FS_DATA_LO+0..FS_D-1; payloads high-entropy + late-bound); REBOOT; BOOT-2 a multi-deleter reads THREE record names (holes {0,i,j} = slot 0 + two interior) over COM1 and SYS_FS_DELs them in a SCRAMBLED order [i,j,0], so a FIFO free-list (deletion order) AND a LIFO free-list (reverse) BOTH diverge from a genuine lowest-among-ALL scan, and including slot 0 kills a scan-from-slot-1 forge; exactly three holes {0,i,j} remain, highest live index stays FS_D-1; REBOOT; BOOT-3 a putter reads THREE NEW author-unknown records over COM1 and SYS_FS_PUTs them -- GENUINE first-free writes D0 into slot 0, D1 into hole i, D2 into hole j (lowest-among-ALL first), data_lba=FS_DATA_LO+slot, survivors UNTOUCHED. The PRIMARY grade is a HOST-SIDE RAW ground-truth oracle (reuseok) that reads the on-disk directory + all FS_D data sectors BY POSITION and asserts the FULL first-free expected state -- it binds REUSE (the new records occupy the freed holes lowest-first, 1:1 data_lba, the freed data sectors carry the new payloads) AND survivor-immutability (every survivor slot {valid,name,len,data_lba} + raw data sector UNCHANGED, which also excludes a compaction forge that reuses by shifting survivors). FUNCTIONAL: BOOT-4 GETs each NEW record by name across the reboot -> emits its payload. Byte-pinned to backfill_ref.build_elf(fsreuse=True) (binds the first-free PUT), white-box assert_backfill (the scan break cmp dword[esi],1;jne + the slot-from-scan-index mov[fs_nent],ecx + the freeslot data_lba mov eax,ecx;add FS_DATA_LO;mov[fs_lba] + NO append-by-count A3 store), the frozen DELETE kernel FAILS assert_backfill (B3), build_elf(fsreuse=False) == delete byte-for-byte + the frozen modes (delete/growheap/larder/cairn/...) emit byte-identical + assert_cairn/assertdelete/assertgrowheap/assertlarder STILL PASS on the BACKFILL kernel (the first-free PUT is purely additive), QEMU+KVM+Bochs GREEN on the 4-boot reuse (raw + functional), THE DELETE DIFFERENTIAL RED (the frozen append-by-count PUT clobbers a live survivor / loses the new record -> the on-disk FS diverges from the first-free expected state), the SEED-DIFFERENTIAL RED (a different held-back new-record seed graded under the prior expectation -> the on-disk state follows the late-bound input, not a baked answer). Output-forced -- first-free-slot REUSE is the ONLY allocation that stores both new records AND keeps every survivor across the reboots under capacity exhaustion (a tail/monotonic forge rejects at the D boundary; append-by-count clobbers a survivor; scan-from-1 skips slot 0; FIFO/LIFO free-lists pick the wrong hole; a compaction forge moves survivors -- each caught by the raw position oracle). The held-back MUTATION proof (scanfrom1/append/tailappend/decoupled/wrongscan + the inherited nocarrycheck/fsnocld) lives in the companion mutation harness. HONEST SCOPE: dir-slot reuse + the 1:1 data-sector reuse corollary (observed physically by the raw-sector oracle); a genuinely DECOUPLED data-sector reclaimer (independent free-list, variable-size / multi-sector files) is a SEPARATE future link; one directory sector, D=$FS_D fixed slots, a full 16-byte name compare)"
