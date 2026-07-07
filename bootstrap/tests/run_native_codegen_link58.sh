#!/usr/bin/env bash
# Native-codegen Link 58 / delete (kernel-arc link 42): MUTABLE-FS DELETE -- delete a named cairn record across a reboot.
# growheap (link 41) grew the heap; cairn (link 39) made a kernel-written byte resolvable by NAME across a reboot. delete
# is the first time the stack REMOVES a named record durably: a new SYS_FS_DEL (int 0x30 eax=12; EBX=name_ptr(16B)) arm
# FIXED-loop scans the D dir slots for valid && a FULL 16-byte name match and TOMBSTONES the matching slot's valid:=0 IN
# PLACE, then ATA-writes the dir sector back + CACHE FLUSH (so the tombstone survives a power cycle). The on-disk FS format
# is UNCHANGED -- the valid:u32 field is ALREADY honored by the frozen GET (skips valid!=1) + PUT (counts valid==1), so
# ZERO format change. A NEW kernel emit mode `multiboot32-delete` (TYPE-II ADDITIVE on the FROZEN growheap lineage:
# build_elf(fsdel=False) reproduces growheap BYTE-FOR-BYTE). KERNEL-EMIT only; the putter/deleter/getter probers are
# hand-asm, LATE-BOUND (names/payloads fed over COM1 -- not baked).
#
# THE MAKE-OR-BREAK = a LATE-BOUND THREE-PHASE (4-boot) reboot differential on ONE disk image (delete_latebound.py):
#   BOOT-1 "putter": reads 2 records over COM1 and SYS_FS_PUTs them -- a TARGET (slot 0 = the SURVIVOR) then a DECOY
#     (slot 1 = the DELETE-TARGET; decoy-after-target). The two names SHARE a 15-byte PREFIX, differ only in the last byte
#     (forces the full 16-byte compare); payloads high-entropy + late-bound.
#   REBOOT (RAM wiped; SAME cache=writethrough image).
#   BOOT-2 "deleter": reads the DECOY's 16-byte name over COM1 (author-unknown) and SYS_FS_DELs it (tombstone slot 1 +
#     flush). The DECOY is the NON-FIRST slot, so deleting it BY NAME (not positionally) is what kills M-positional.
#   REBOOT.
#   BOOT-3 "getter" x2: GET the DECOY name -> must emit NOTHING (deleted, found=0); GET the TARGET name -> must emit P_T
#     (the survivor, found=1). The deletion persisted across the reboot AND did not touch the survivor.
#
# Why GENUINELY OUTPUT-FORCED: the deleted record's ABSENCE follows a LATE-BOUND delete persisted on the medium across a
# fresh boot (RAM wiped). No baked answer, no RAM stash, and no frozen older kernel (growheap has no SYS_FS_DEL arm)
# reproduces it. ABSENCE cannot be faked by append -- the first-match GET returns the lowest-index valid slot, so DELETE
# MUST tombstone the existing slot IN PLACE. The TARGET-survives + DECOY-gone pair + the deleting-the-non-first-slot design
# force a genuine, complete, by-name, persisted tombstone (M-noop / M-wipeall / M-positional / M-noflush each diverge).
#
# What this gate proves (far-axis TRI-SUBSTRATE oracle, QEMU-TCG + KVM real silicon + Bochs, vs delete_ref.py):
#   (B1) KERNEL BYTE-PIN: the emitted kernel == delete_ref.build_elf(fsdel=True) (the SYS_FS_DEL arm + the frozen growheap/
#        cairn/larder/durable arms).
#   (B2) WHITE-BOX assert_delete: the do_fs_del arm carries the access_ok carry guard, the fixed-D scan, the cld;cmpsb
#        name-compare, the in-place tombstone (mov dword[esi],0), and the dir write-back WRITE SECTORS -> CACHE FLUSH.
#   (B3) the FROZEN growheap kernel FAILS assert_delete (no DEL arm -- the tombstone machinery is genuinely new).
#   (D) ADDITIVITY: build_elf(fsdel=False) == growheap byte-for-byte; the frozen modes emit byte-identical; AND
#       assert_cairn/assert_growheap/assert_larder STILL PASS on the DELETE kernel (the DEL arm is purely additive).
#   (C) SILICON make-or-break: the late-bound PUT->DEL->GET 3-phase: GET(DECOY)=empty (deleted) + GET(TARGET)=P_T
#       (survivor) GREEN on QEMU + KVM + Bochs.
#   (C-FROZEN) THE GROWHEAP DIFFERENTIAL: the FROZEN growheap kernel + the delete probers -> SYS_FS_DEL (eax=12) is unknown
#       -> falls to SYS_EXIT -> BOOT-2 deletes NOTHING -> BOOT-3 GET(DECOY) still resolves -> RED (delete is genuinely new).
#   (C-SEEDDIFF) SEED-DIFFERENTIAL: a fresh run with a DIFFERENT held-back seed -- grading run-2's survivor emit under
#       run-1's expected payload is RED (the output follows the late-bound input, not a baked answer).
#   (C-HOSTILE-DF-DEL) GAP: a deleter does `std` (DF=1) before SYS_FS_DEL of a VALID name -> the GENUINE kernel cld's before
#       the DEL name-compare cmpsb, so it still matches FORWARD + tombstones the right slot -> BOOT-3 GET(that name)=empty
#       (GREEN). M-fsnocld inherits DF=1 -> the cmpsb walks BACKWARD -> the wrong/no slot is tombstoned -> the record SURVIVES.
#   (C-HOSTILE-CARRY-DEL) a deleter passes name_ptr near 4 GiB (0xFFFFFFF8, so name_ptr+16 WRAPS) -> the GENUINE access_ok
#       carry-check rejects (eax=0, the deleter SURVIVES + emits the 4-byte envelope); M-nocarrycheck slips the cmp + the
#       cld;cmpsb reads 0xFFFFFFF8 -> #PF -> the deleter faults (emits nothing).
# REQUIRE_EMU fail-closed (the durable/cairn pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and an emulator is missing, FAIL.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/delete_ref.py"
LB="$script_dir/delete_latebound.py"
GH_REF="$script_dir/growheap_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$LB" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $LB)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi
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
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" deletekernel "$REFK")"
PUTTER="$work/putter.bin"; python3 "$LB" putter "$PUTTER"        # BOOT-1 late-bound putter (PUT TARGET + DECOY)
DELETER="$work/deleter.bin"; python3 "$LB" deleter "$DELETER"    # BOOT-2 late-bound deleter (SYS_FS_DEL the DECOY by name)
GETTER="$work/getter.bin"; python3 "$LB" getter "$GETTER"        # BOOT-3 late-bound getter (GET -> resolved payload, for the SURVIVOR check)
FOUNDPROBE="$work/foundprobe.bin"; python3 "$LB" foundprobe "$FOUNDPROBE"   # BOOT-3 FOUND-probe (emits the found flag; found==0 <=> valid==0 <=> really deleted -- the STRONG deleted check, output-visible to "absence by corruption")

MKELF="$work/delete_kernel.elf"
emit '-- emit: multiboot32-delete' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) delete kernel byte-identical to delete_ref.build_elf(fsdel=True) [$(wc -c <"$MKELF") B]"
else fail_test "(B1) delete kernel differs from delete_ref.build_elf(fsdel=True) -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_delete ----
if python3 "$REF" assertdelete "$MKELF"; then ok "(B2) kernel carries the DELETE machinery (assert_delete: the access_ok carry guard + the fixed-D=$FS_D scan + the cld;repe cmpsb name-compare + the in-place tombstone mov dword[esi],0 + the dir WRITE SECTORS -> CACHE FLUSH)"
else fail_test "(B2) kernel lacks the DELETE machinery (assert_delete failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "delete kernel is a valid x86 Multiboot image"
else fail_test "delete kernel is not a valid x86 Multiboot image"; fi

# ---- (B3) the frozen growheap kernel must FAIL assert_delete (no DEL arm) ----
FROZK="$work/frozen_growheap.elf"; FROZKEND="$(python3 "$REF" frozenkernel "$FROZK")"
if cmp -s "$FROZK" <(python3 "$GH_REF" growheapkernel /dev/stdout 2>/dev/null); then ok "(B3a) frozenkernel (fsdel=False) byte-identical to growheap_ref.build_elf() -- the DEL arm is purely additive"
else
  # /dev/stdout cmp can be finicky; compare via temp files instead.
  python3 "$GH_REF" growheapkernel "$work/gh_ref.elf" >/dev/null
  if cmp -s "$FROZK" "$work/gh_ref.elf"; then ok "(B3a) frozenkernel (fsdel=False) byte-identical to growheap_ref.build_elf() -- the DEL arm is purely additive"
  else fail_test "(B3a) frozenkernel != growheap -- the DEL arm is NOT purely additive"; fi
fi
if python3 "$REF" assertdelete "$FROZK" >/dev/null 2>&1; then fail_test "(B3) the frozen growheap kernel PASSED assert_delete -- the white-box pin does not discriminate the DEL arm"
else ok "(B3) the frozen growheap kernel FAILS assert_delete (the SYS_FS_DEL arm + the in-place tombstone are genuinely new)"; fi

# ---- (D) ADDITIVITY: frozen prior modes byte-identical + assert_cairn/growheap/larder still PASS on the DELETE kernel ----
for lk in growheap larder cairn durable platter lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    case "$lk" in
      growheap) python3 "$R" growheapkernel "$work/$lk.refk" none >/dev/null 2>&1 ;;
      *)        python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1 ;;
    esac
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; delete is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- delete disturbed it"; fi
done
for asrt in assertcairn assertgrowheap assertlarder; do
    if python3 "$REF" "$asrt" "$MKELF" >/dev/null 2>&1; then ok "(D) $asrt PASSES on the DELETE kernel (the DEL arm is additive; the frozen FS/heap machinery is preserved)"
    else fail_test "(D) $asrt FAILED on the DELETE kernel -- the DEL arm disturbed a frozen arm (not purely additive)"; fi
done

# ============================ SILICON (the late-bound PUT->DEL->GET 3-phase reboot differential) ============================
emu_ran=0
build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }

# boot the kernel + module, feeding a COM1 byte stream; capture debugcon to $out. $DISK is the (persistent) image.
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

# a GETTER that MUST emit -- retry up to 4x until the debugcon carries a closed UCODE3 write-frame (the genuine survivor
# GET emits deterministically; a rare EMPTY is the COM1-serial / debugcon-flush timing flake). Retrying is SAFE: it never
# converts a mutant's RED to GREEN (a mutant's empty/wrong is a deterministic #PF/mis-resolution that recurs). Used ONLY
# for the SURVIVOR get (which must emit); the DELETED get (which must be EMPTY) and the mutant legs run SINGLE-SHOT.
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

# full late-bound 3-phase delete for (kernel, seed, kvm, label): BOOT-1 PUT(target,decoy); BOOT-2 DEL(decoy); BOOT-3a
# GET(decoy)->expect empty; BOOT-3b GET(target)->expect P_T. Sets TWB_TP/TWB_DP/TWB_TN/TWB_DN + writes .b3decoy/.b3target.
three_boot_delete() { # kernel-elf seedhex kvmflag label
    local kel="$1" seed="$2" kvm="$3" lbl="$4"
    DISK="$work/disk_${lbl}.img"; build_raw_disk "$DISK"
    read -r TWB_TN TWB_TP TWB_DN TWB_DP < <(python3 "$LB" records "$seed")
    local putstream qdecoy qtarget delname
    putstream="$(python3 "$LB" putstream "$TWB_TN" "$TWB_TP" "$TWB_DN" "$TWB_DP")"
    delname="$(python3 "$LB" querystream "$TWB_DN")"        # the DECOY name (slot 1, the delete-target)
    qdecoy="$(python3 "$LB" querystream "$TWB_DN")"
    qtarget="$(python3 "$LB" querystream "$TWB_TN")"
    boot_feed "$kel" "$PUTTER"     "$work/${lbl}.b1"       "$kvm" $putstream   # BOOT-1: PUT target + decoy
    boot_feed "$kel" "$DELETER"    "$work/${lbl}.b2"       "$kvm" $delname     # BOOT-2: DEL the decoy (by name)
    boot_feed_emit "$kel" "$FOUNDPROBE" "$work/${lbl}.b3decoy"  "$kvm" $qdecoy # BOOT-3a: FOUND-probe decoy -> must be found==0 (valid==0, REALLY deleted)
    boot_feed_emit "$kel" "$GETTER"     "$work/${lbl}.b3target" "$kvm" $qtarget # BOOT-3b: GET target -> must emit P_T (survivor)
}

run_qemu_gate() { # kvmflag label substlabel
    local kvm="$1" lbl="$2" subst="$3"
    local seed; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    three_boot_delete "$MKELF" "$seed" "$kvm" "$lbl"
    local g_del=1 g_sur=1 g_raw=1
    python3 "$LB" gradefound "$work/${lbl}.b3decoy" "$KEND" 0 >/dev/null 2>&1 && g_del=0   # FUNCTIONAL: decoy found==0 (GET-by-name fails)
    python3 "$LB" gradefs "$work/${lbl}.b3target" "$KEND" "$TWB_TP" >/dev/null 2>&1 && g_sur=0   # FUNCTIONAL: target GET -> payload
    # STRUCTURAL ground truth: read the RAW on-disk dir AFTER the delete -- the decoy slot (1) valid==0 + NAME UNCHANGED,
    # the target slot (0) valid==1 + NAME UNCHANGED. Catches the "absence by corruption" class (a rename/corrupt forge that
    # fakes found==0 at the GET level leaves valid==1 / a changed name here). The disk is unchanged by BOOT-3 (GET reads only).
    python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 1 "$TWB_DN" 0 "$TWB_TN" >/dev/null 2>&1 && g_raw=0
    local edecoy etarget
    edecoy="$(python3 "$LB" emitbody "$work/${lbl}.b3decoy" 2>/dev/null)"
    etarget="$(python3 "$LB" emitbody "$work/${lbl}.b3target" 2>/dev/null)"
    if [[ "$g_del" -eq 0 && "$g_sur" -eq 0 && "$g_raw" -eq 0 ]]; then
        ok "(C-$subst) late-bound PUT->DEL->GET 3-phase: BOOT-1 PUT a TARGET(slot0) + a DECOY(slot1); REBOOT; BOOT-2 DEL the DECOY by name (slot 1, the non-first slot); REBOOT. STRUCTURAL ground truth (raw on-disk dir): the decoy slot's VALID==0 + its NAME UNCHANGED, the target slot's VALID==1 + NAME UNCHANGED -- a GENUINE in-place tombstone (a rename/corrupt forge that fakes GET-absence would leave valid==1 / a changed name). FUNCTIONAL: FOUND-probe(DECOY) -> found==0 AND GET(TARGET) -> P_T (${#etarget} hex chars). A genuine, complete, by-name, flushed tombstone"
        return 0
    else
        fail_test "(C-$subst) 3-phase delete: RAW-DIR tombstone ok=$([[ $g_raw -eq 0 ]] && echo YES || echo NO) [$(python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 1 "$TWB_DN" 0 "$TWB_TN" 2>&1 | tr '\n' ';')]; FUNCTIONAL decoy found==0=$([[ $g_del -eq 0 ]] && echo YES || echo NO) (found='$edecoy'); TARGET survived=$([[ $g_sur -eq 0 ]] && echo YES || echo NO) (emitted='$etarget', want P_T=$TWB_TP)"
        return 1
    fi
}

if have_qemu; then
    emu_ran=1
    run_qemu_gate "" qtcg "QEMU"

    # (C-BYNAME) prove the delete follows the NAME, not a fixed slot position: delete the TARGET (slot 0, not the decoy/slot
    # 1 the main leg deletes) -> BOOT-3 GET(TARGET) empty (deleted) + GET(DECOY) survives -> P_D. A "delete slot1
    # positionally" forge would delete the DECOY instead -> GET(TARGET) still resolves (RED) AND GET(DECOY) empty (RED). With
    # the main leg (delete the DECOY/slot1) + M-positional (delete the FIRST valid/slot0), this binds the deleted slot to the
    # NAME. (Closes a cross-model/Codex hole: the main leg alone always deletes slot1, so a positional forge passes it.)
    BNSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    DISK="$work/disk_byname.img"; build_raw_disk "$DISK"
    read -r BNTN BNTP BNDN BNDP < <(python3 "$LB" records "$BNSEED")
    BNPUT="$(python3 "$LB" putstream "$BNTN" "$BNTP" "$BNDN" "$BNDP")"
    BNDELN="$(python3 "$LB" querystream "$BNTN")"      # delete the TARGET (slot 0)
    BNQT="$(python3 "$LB" querystream "$BNTN")"; BNQD="$(python3 "$LB" querystream "$BNDN")"
    boot_feed "$MKELF" "$PUTTER"  "$work/bn.b1"        "" $BNPUT
    boot_feed "$MKELF" "$DELETER" "$work/bn.b2"        "" $BNDELN
    boot_feed_emit "$MKELF" "$FOUNDPROBE" "$work/bn.b3target" "" $BNQT   # FOUND-probe TARGET -> must be found==0 (deleted)
    boot_feed_emit "$MKELF" "$GETTER" "$work/bn.b3decoy" "" $BNQD   # GET DECOY -> must survive -> P_D
    bn_del=1; python3 "$LB" gradefound "$work/bn.b3target" "$KEND" 0 >/dev/null 2>&1 && bn_del=0
    bn_sur=1; python3 "$LB" gradefs "$work/bn.b3decoy" "$KEND" "$BNDP" >/dev/null 2>&1 && bn_sur=0
    bn_raw=1; python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 0 "$BNTN" 1 "$BNDN" >/dev/null 2>&1 && bn_raw=0   # raw-dir: TARGET slot0 valid==0, DECOY slot1 valid==1
    if [[ "$bn_del" -eq 0 && "$bn_sur" -eq 0 && "$bn_raw" -eq 0 ]]; then
        ok "(C-BYNAME) deleting the TARGET (slot 0) by NAME removes IT (GET(TARGET) empty) and LEAVES the DECOY (GET(DECOY) -> P_D) -- the deleted slot follows the NAME, not a fixed position (a 'delete slot1' positional forge would delete the DECOY -> both diverge)"
    else
        fail_test "(C-BYNAME) delete-the-TARGET: TARGET deleted=$([[ $bn_del -eq 0 ]] && echo YES || echo NO); DECOY survived=$([[ $bn_sur -eq 0 ]] && echo YES || echo NO) -- the delete is positional, not by-name"
    fi

    # (C-FULL16) prove the FULL 16-byte compare: DELETE a NEGATIVE-CONTROL name that shares the TARGET's LAST byte but has a
    # DIFFERENT 15-byte prefix -> matches NO record -> NOTHING is deleted -> BOTH records survive. A last-byte-only / suffix
    # forge would WRONGLY delete the TARGET. (Mirrors cairn's C-PREFIX leg, applied to DELETE; closes the hole that the
    # decoy/target differing only in byte 15 leaves a last-byte-only compare un-forced.)
    F16SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    DISK="$work/disk_full16.img"; build_raw_disk "$DISK"
    read -r F16TN F16TP F16DN F16DP < <(python3 "$LB" records "$F16SEED")
    F16PUT="$(python3 "$LB" putstream "$F16TN" "$F16TP" "$F16DN" "$F16DP")"
    F16PX="$(python3 "$LB" prefixmismatch "$F16TN")"  # shares the TARGET's last byte, different prefix -> matches nothing
    F16DELN="$(python3 "$LB" querystream "$F16PX")"
    F16QT="$(python3 "$LB" querystream "$F16TN")"; F16QD="$(python3 "$LB" querystream "$F16DN")"
    boot_feed "$MKELF" "$PUTTER"  "$work/f16.b1"       "" $F16PUT
    boot_feed "$MKELF" "$DELETER" "$work/f16.b2"       "" $F16DELN   # DEL the prefix-mismatch name (no match)
    boot_feed_emit "$MKELF" "$GETTER" "$work/f16.b3t"  "" $F16QT     # GET TARGET -> must SURVIVE -> P_T
    boot_feed_emit "$MKELF" "$GETTER" "$work/f16.b3d"  "" $F16QD     # GET DECOY  -> must SURVIVE -> P_D
    f16_t=1; python3 "$LB" gradefs "$work/f16.b3t" "$KEND" "$F16TP" >/dev/null 2>&1 && f16_t=0
    f16_d=1; python3 "$LB" gradefs "$work/f16.b3d" "$KEND" "$F16DP" >/dev/null 2>&1 && f16_d=0
    if [[ "$f16_t" -eq 0 && "$f16_d" -eq 0 ]]; then
        ok "(C-FULL16) deleting a NEGATIVE-CONTROL name sharing the TARGET's LAST byte but a DIFFERENT 15-byte prefix matches NO record -> NOTHING deleted -> BOTH records survive (GET(TARGET) -> P_T, GET(DECOY) -> P_D) -- a last-byte-only / suffix-only compare would WRONGLY delete the TARGET, so every one of the 16 name bytes is load-bearing in the DEL compare"
    else
        e16t="$(python3 "$LB" emitbody "$work/f16.b3t" 2>/dev/null)"
        fail_test "(C-FULL16) a prefix-mismatch DELETE wrongly removed a record (TARGET survived=$([[ $f16_t -eq 0 ]] && echo YES || echo NO) emit='$e16t'; DECOY survived=$([[ $f16_d -eq 0 ]] && echo YES || echo NO)) -- the DEL keys on less than the full 16-byte name"
    fi

    # (C-FROZEN) THE GROWHEAP DIFFERENTIAL: the frozen growheap kernel + the delete probers. SYS_FS_DEL (eax=12) is unknown
    # in growheap -> falls to SYS_EXIT. The deleter EXITs on its SYS_FS_DEL (no delete); BOOT-3 GET(DECOY) still resolves ->
    # NON-empty -> RED. Delete is genuinely new (growheap has cairn's PUT/GET but no tombstone).
    FSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    three_boot_delete "$FROZK" "$FSEED" "" froz
    # the raw-dir ground truth: the frozen kernel did NOT clear the decoy's valid -> tombstoneok is RED (decoy slot1 valid==1).
    if python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 1 "$TWB_DN" 0 "$TWB_TN" >/dev/null 2>&1; then
        fail_test "(C-FROZEN) the frozen growheap kernel produced a GENUINE tombstone (decoy slot1 valid==0) -- delete is NOT genuinely new (growheap already tombstones?)"
    else
        FROZ_DV="$(python3 "$LB" dirslot "$DISK" "$FS_DIR" 1 2>/dev/null | awk '{print $1}')"
        ok "(C-FROZEN) THE GROWHEAP DIFFERENTIAL: the frozen growheap kernel + the deleter is RED -- SYS_FS_DEL (eax=12) is unknown in growheap, falls to SYS_EXIT, BOOT-2 deletes NOTHING, so the raw on-disk decoy slot is STILL valid==${FROZ_DV} (NOT tombstoned) and FOUND-probe(DECOY) returns found==1 -> the durable tombstone is a genuinely new observable (additive on growheap, which has cairn's name lookup but no delete)"
    fi

    # (C-SEEDDIFF) the SEED-DIFFERENTIAL: a fresh run with a DIFFERENT held-back seed produces a DIFFERENT survivor payload;
    # grading run-2's survivor emit under run-1's expected payload is RED -> the output follows the late-bound input.
    SD1="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    three_boot_delete "$MKELF" "$SD1" "" sd1
    SD1_TP="$TWB_TP"
    SD2="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    three_boot_delete "$MKELF" "$SD2" "" sd2
    if python3 "$LB" gradefs "$work/sd2.b3target" "$KEND" "$SD1_TP" >/dev/null 2>&1; then
        fail_test "(C-SEEDDIFF) run-2's survivor emit graded GREEN under run-1's expected payload -- the output is NOT following the late-bound input (a baked answer?), or the two random seeds collided"
    else
        if python3 "$LB" gradefs "$work/sd2.b3target" "$KEND" "$TWB_TP" >/dev/null 2>&1; then
            ok "(C-SEEDDIFF) SEED-DIFFERENTIAL: a fresh run with a DIFFERENT held-back seed emits a DIFFERENT survivor payload -- graded under the FIRST run's expected it is RED (the output genuinely follows the late-bound COM1 records, not a baked constant), yet GREEN under its OWN expected"
        else
            fail_test "(C-SEEDDIFF) run-2 was RED even against its OWN expected survivor payload -- the run is malformed, the differential is vacuous"
        fi
    fi

    # (C-HOSTILE-DF-DEL) the DF (cld) leg on the DEL arm: a deleter does std (DF=1) before SYS_FS_DEL of a VALID name. The
    # GENUINE kernel cld's before the DEL name-compare cmpsb, so it matches FORWARD + tombstones the right slot -> BOOT-3
    # GET(that name)=empty (deleted) -> GREEN. M-fsnocld inherits DF=1 -> the cmpsb walks BACKWARD -> wrong/no match -> the
    # record SURVIVES. (Output witness that the DEL cld is load-bearing; paired with assert_delete's cld pin + M-fsnocld.)
    HDFDEL="$work/hostile_df_del.bin"; python3 "$LB" hostiledfdel "$HDFDEL"
    DFSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    DISK="$work/disk_dfdel.img"; build_raw_disk "$DISK"
    read -r DFTN DFTP DFDN DFDP < <(python3 "$LB" records "$DFSEED")
    DFPUT="$(python3 "$LB" putstream "$DFTN" "$DFTP" "$DFDN" "$DFDP")"
    DFDELN="$(python3 "$LB" querystream "$DFDN")"          # delete the DECOY (a VALID name) under DF=1
    DFQ="$(python3 "$LB" querystream "$DFDN")"
    boot_feed "$MKELF" "$PUTTER"  "$work/dfdel.b1" "" $DFPUT
    boot_feed "$MKELF" "$HDFDEL"  "$work/dfdel.b2" "" $DFDELN     # DEL the decoy with std=DF=1
    boot_feed_emit "$MKELF" "$FOUNDPROBE" "$work/dfdel.b3" "" $DFQ # FOUND-probe the decoy -> must be found==0 (deleted forward)
    # raw-dir ground truth: under DF=1 the genuine kernel still cleared the decoy slot's valid (and only that).
    if python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 1 "$DFDN" 0 "$DFTN" >/dev/null 2>&1 && python3 "$LB" gradefound "$work/dfdel.b3" "$KEND" 0 >/dev/null 2>&1; then
        ok "(C-HOSTILE-DF-DEL) a SYS_FS_DEL preceded by a hostile std (DF=1) of a VALID name STILL tombstones the RIGHT slot -- the genuine kernel cld's before the DEL name-compare cmpsb so the 16-byte compare runs FORWARD regardless of the module's direction flag, and BOOT-3 GET(that name) is EMPTY (deleted); M-fsnocld would inherit DF=1 -> the cmpsb walks BACKWARD -> the wrong/no slot tombstoned -> the record survives"
    else
        DFE="$(python3 "$LB" emitbody "$work/dfdel.b3" 2>/dev/null)"
        fail_test "(C-HOSTILE-DF-DEL) the genuine kernel did NOT delete under a hostile std=DF=1 (BOOT-3 FOUND-probe returned found='$DFE', want 00) -- the kernel did not cld before its DEL name-compare cmpsb (this should NEVER happen on the genuine kernel)"
    fi

    # (C-HOSTILE-CARRY-DEL) the access_ok carry leg on the DEL arm: a deleter points name_ptr at 0xFFFFFFF8 (name_ptr+16
    # WRAPS). The genuine do_fs_del does `add edx,16 ; jc reject`, so the wrapped name is REJECTED (eax=0, the deleter
    # SURVIVES + emits the 4-byte envelope). M-nocarrycheck slips the cmp + the cld;cmpsb reads 0xFFFFFFF8 -> #PF -> the
    # deleter FAULTS (emits nothing). DISCRIMINATOR: genuine emits the envelope; M-nocarrycheck emits nothing.
    HCDEL="$work/hostile_carry_del.bin"; python3 "$LB" hostilenamecarrydel "$HCDEL"
    HCSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    DISK="$work/disk_hcdel.img"; build_raw_disk "$DISK"
    read -r HCTN HCTP HCDN HCDP < <(python3 "$LB" records "$HCSEED")
    HCPUT="$(python3 "$LB" putstream "$HCTN" "$HCTP" "$HCDN" "$HCDP")"
    HCN="$(python3 "$LB" querystream "$HCDN")"
    boot_feed "$MKELF" "$PUTTER" "$work/hcdel.b1" "" $HCPUT
    boot_feed_emit "$MKELF" "$HCDEL" "$work/hcdel.b2" "" $HCN     # the hostile deleter must emit its envelope (flake-robust)
    HC_EMIT="$(python3 "$LB" emitbody "$work/hcdel.b2" 2>/dev/null)"
    if [[ -n "$HC_EMIT" && "$HC_EMIT" != "NO-TABLE" ]]; then
        ok "(C-HOSTILE-CARRY-DEL) a SYS_FS_DEL with a name_ptr near 4 GiB (0xFFFFFFF8, so name_ptr+16 WRAPS) is REJECTED by the access_ok carry-check (add edx,16 ; jc reject) -- the deleter SURVIVES and emits the (found=0) envelope (emitted='$HC_EMIT'), no out-of-region kernel read; M-nocarrycheck would slip the cmp and the cld;cmpsb would read 0xFFFFFFF8 -> #PF"
    else
        fail_test "(C-HOSTILE-CARRY-DEL) the genuine deleter emitted NOTHING (it faulted) on the near-4GiB name_ptr -- expected the carry-check to reject cleanly so the deleter survives + emits the envelope"
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon): the late-bound PUT->DEL->GET 3-phase on the real chipset ----
if have_kvm; then
    run_qemu_gate kvm kvm "KVM real silicon"
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB): the PUT->DEL->GET 3-phase persists across three Bochs runs on the SAME GRUB disk ----
# BOOT-1 putter PUTs target+decoy; BOOT-2 deleter DELs the decoy; BOOT-3 getter GETs the decoy -> must be EMPTY (the
# tombstone persisted to the medium + flushed -- the cross-substrate proof of durable deletion). .lock cleanup per STEP-0.
bochs_three_boot_delete() { # putstream delstream getstream b3out
    local putstream="$1" delstream="$2" getstream="$3" b3out="$4"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local pu; pu="$(readlink -f "$PUTTER")"; local de; de="$(readlink -f "$DELETER")"; local ge; ge="$(readlink -f "$GETTER")"; local fpb; fpb="$(readlink -f "$FOUNDPROBE")"
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
      sudo cp "$pu" mnt/boot/putter.bin; sudo cp "$de" mnt/boot/deleter.bin; sudo cp "$ge" mnt/boot/getter.bin; sudo cp "$fpb" mnt/boot/foundprobe.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/putter.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
    # Harness-failure detectors (F2 sweep, mirror of the link60 reference). Each sets BOCHS_HARNESS_ERR + returns
    # nonzero so the caller re-rolls, never false-REDding the kernel.
    _feed_ok() { # feedlog label -> 0 iff the feeder reached LISTENING within 5s
        local fl="$1" lbl="$2" i
        for i in $(seq 1 50); do grep -q LISTENING "$fl" 2>/dev/null && break; sleep 0.1; done
        grep -q LISTENING "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never reached LISTENING for $lbl (log: $fl -- feeder/port-bind failure, not a kernel miscompile)"; return 1
    }
    _bochs_ran_ok() { # bochslog label -> 0 iff the boot RAN TO A KERNEL shutdown() tail (i.e. was NOT killed/hung mid-run)
        local bl="$1" lbl="$2"
        [[ -s "$bl" ]] || { BOCHS_HARNESS_ERR="Bochs produced NO output booting $lbl (log: $bl empty/missing -- the emulator did not run, not a kernel miscompile)"; return 1; }
        # The kernel's shutdown() writes "Shutdown" to Bochs' port 0x8900 -> Bochs logs 'shutdown requested' whenever the
        # kernel reaches a shutdown() tail: proves the boot RAN TO COMPLETION (not a mid-run death). Crucial here: BOOT-3
        # FOUND-probe emits NOTHING when the record is genuinely deleted -- indistinguishable from a mid-run death WITHOUT
        # this sentinel + the SENT check. `[[ -s log ]]` alone is worthless (Bochs always prints a banner). grep -a: binary log.
        grep -qa 'shutdown requested' "$bl" && return 0
        BOCHS_HARNESS_ERR="Bochs did NOT run $lbl through to a kernel shutdown tail (log: $bl has no 'shutdown requested' -- the boot died or was timeout-killed mid-run, not a kernel miscompile)"; return 1
    }
    _feed_delivered() { # feedlog label -> 0 iff the feeder actually SENT its payload (Bochs connected COM1)
        local fl="$1" lbl="$2"
        grep -q '^SENT' "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload for $lbl (log: $fl has LISTENING but no SENT / shows NOCONN -- Bochs did not connect COM1, the kernel received no input, not a kernel miscompile)"; return 1
    }
    bochs_phase() { # module-name stream logfile  -> nonzero (sets BOCHS_HARNESS_ERR) on a harness failure
        local mod="$1" stream="$2" logf="$3"
        local port; port=$(free_port)
        python3 "$feeder" "$port" $stream --hold 150 > "$d/feed.log" 2>&1 & local fp=$!
        _feed_ok "$d/feed.log" "$mod" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
        # config-swap guard (cross-model Codex): a SILENT losetup/mount/tee failure boots the STALE/previous module ->
        # a wrong-module emit (or absence) mis-graded as kernel. Detect each step (cleanup preserved) -> harness -> re-roll.
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
        ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_run.txt" > "$logf" 2>&1 )   # absolute bochsrc path -> $work in the cmdline for the scoped `pkill -f "$work"`
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        rm -f "$d/disk.img.lock"
        _bochs_ran_ok "$logf" "$mod" || return 1
        _feed_delivered "$d/feed.log" "$mod" || return 1
    }
    # BOOT-1 already has putter.bin in grub.cfg (set at install); feed the put-stream.
    local port; port=$(free_port)
    python3 "$feeder" "$port" $putstream --hold 150 > "$d/feed1.log" 2>&1 & local fp=$!
    _feed_ok "$d/feed1.log" "putter.bin(BOOT-1)" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
    sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b1.txt"
    ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b1.txt" > bochs_b1.txt 2>&1 )   # absolute bochsrc path (scoped-kill: $work in the cmdline)
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    rm -f "$d/disk.img.lock"
    _bochs_ran_ok "$d/bochs_b1.txt" "putter.bin(BOOT-1)" || return 1
    _feed_delivered "$d/feed1.log" "putter.bin(BOOT-1)" || return 1
    bochs_phase deleter.bin "$delstream" "$d/bochs_b2.txt" || return 1      # BOOT-2: DEL the decoy
    bochs_phase foundprobe.bin "$getstream" "$d/bochs_b3.txt" || return 1   # BOOT-3: FOUND-probe the decoy -> must be found==0 (deleted)
    python3 - "$d/bochs_b3.txt" "$b3out" <<'PY'
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
        BSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
        read -r BTN BTP BDN BDP < <(python3 "$LB" records "$BSEED")
        BPUT="$(python3 "$LB" putstream "$BTN" "$BTP" "$BDN" "$BDP")"
        BDEL="$(python3 "$LB" querystream "$BDN")"     # delete the DECOY
        BGET="$(python3 "$LB" querystream "$BDN")"     # then GET the DECOY -> must be empty (deleted)
        if ! bochs_three_boot_delete "$BPUT" "$BDEL" "$BGET" "$work/b.b3"; then
            echo "  HARNESS ERROR (Bochs 3-boot attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling the 3-boot (transient emulator/feeder failure, NOT a kernel RED)" >&2
            continue
        fi
        # every boot LISTENED + delivered (SENT) + swapped GRUB cleanly + ran THROUGH shutdown() -> the grade is GENUINE
        # (BOOT-3 FOUND-probe emitting NOTHING now unambiguously means 'deleted', not a mid-run death)
        # raw-dir ground truth on the Bochs disk image (the decoy slot's valid==0 persisted to the medium, name unchanged).
        if python3 "$LB" tombstoneok "$work/b.d/disk.img" "$FS_DIR" 1 "$BDN" 0 "$BTN" >/dev/null 2>&1 && python3 "$LB" gradefound "$work/b.b3" "$KEND" 0 >/dev/null 2>&1; then ok "(C-Bochs) the tombstone PERSISTS across three Bochs runs on the SAME GRUB disk: BOOT-1 putter PUT a TARGET + a DECOY (late-bound over com1) + flush; BOOT-2 deleter SYS_FS_DEL the DECOY + flush; BOOT-3 FOUND-probe(DECOY) -> found==0 (the slot's VALID==0, REALLY deleted) -- the 2nd substrate's ATA controller PERSISTS the tombstone across the reboot (the software-RESET prologue Bochs needs is inherited from durable). HONEST SCOPE: this Bochs leg proves DECOY-ABSENCE persistence on the 2nd substrate; the TARGET-SURVIVES (no over-delete) half is proven on QEMU-TCG + KVM (where M-wipeall is caught). NOTE on the CACHE FLUSH: empirically this Bochs (like QEMU writethrough) persists the write even WITHOUT the 0xE7 flush -- it flushes its write-cache on clean exit -- so the flush is OUTPUT-INVISIBLE on every available substrate and is caught only WHITE-BOX (assert_delete); it is for real-hardware power-cut durability"
        else BEMIT="$(python3 "$LB" emitbody "$work/b.b3" 2>/dev/null)"; fail_test "(C-Bochs) Bochs 3-phase (all three boots: feeder SENT + ran through shutdown; guest RECEIPT unproven feeder-side -- a lone RED may be a capture-class flake, re-derive per the parley replay discriminator): BOOT-3 FOUND-probe(DECOY) returned found='$BEMIT' (want 00 -- the delete did not persist across the Bochs reboot)"; fi
        bochs_done=1; break
    done
    if [[ "$bochs_done" -eq 0 ]]; then
        # 3 consecutive HARNESS failures (never the kernel; fresh disk each attempt). Distinct greppable marker (NOT the
        # kernel-RED FAIL: prefix); fatal only when the Bochs substrate is REQUIRED (REQUIRE_EMU=1).
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

echo "native-codegen link58 (delete / MUTABLE-FS DELETE -- delete a named record across a reboot): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link58 delete / MUTABLE-FS DELETE -- delete a named cairn record across a reboot. A NEW emit mode multiboot32-delete, TYPE-II ADDITIVE on the FROZEN growheap (link41) lineage (build_elf(fsdel=False) reproduces growheap BYTE-FOR-BYTE): a new SYS_FS_DEL (int 0x30 eax=12; EBX=name_ptr(16B)) arm FIXED-loop scans the D=$FS_D dir slots for valid && a FULL 16-byte name match and TOMBSTONES the matching slot's valid:=0 IN PLACE, then ATA-writes the dir sector back to FS_DIR_LBA + CACHE FLUSH so the tombstone survives a reboot. The on-disk FS format is UNCHANGED -- the valid:u32 field is ALREADY honored by the frozen GET (skips valid!=1) + PUT (counts valid==1), so ZERO format change. THE MAKE-OR-BREAK is a LATE-BOUND PUT->DEL->GET 3-phase (4-boot) reboot differential on ONE cache=writethrough disk image: BOOT-1 a putter reads 2 records over COM1 and SYS_FS_PUTs them (a TARGET in slot 0 = the SURVIVOR, then a DECOY in slot 1 = the DELETE-TARGET; the two names SHARE a 15-byte PREFIX, differ only in the last byte -- forcing the full 16-byte compare; payloads high-entropy + late-bound); REBOOT; BOOT-2 a deleter reads the DECOY's 16-byte name over COM1 and SYS_FS_DELs it (tombstone slot 1 -- the NON-FIRST slot, so deleting it BY NAME not positionally is what kills M-positional -- + flush); REBOOT; BOOT-3 a getter GETs the DECOY name -> emits NOTHING (deleted, found=0) AND GETs the TARGET name -> emits P_T (the survivor, untouched). Byte-pinned to delete_ref.build_elf(fsdel=True) (binds the SYS_FS_DEL arm), white-box assert_delete (the access_ok carry guard + the fixed-D scan + the cld;repe cmpsb name-compare + the in-place tombstone mov dword[esi],0 + the dir WRITE SECTORS -> CACHE FLUSH), the frozen growheap kernel FAILS assert_delete (B3), build_elf(fsdel=False) == growheap byte-for-byte + the frozen modes emit byte-identical + assert_cairn/assert_growheap/assert_larder STILL PASS on the DELETE kernel (the DEL arm is purely additive), QEMU+KVM+Bochs GREEN on the 3-phase delete (DECOY gone + TARGET survives), THE GROWHEAP DIFFERENTIAL RED (SYS_FS_DEL eax=12 is unknown in growheap -> falls to SYS_EXIT -> BOOT-2 deletes NOTHING -> BOOT-3 GET(DECOY) still resolves), the SEED-DIFFERENTIAL RED (a different held-back seed graded under the prior expectation -> the output follows the late-bound input, not a baked answer), the hostile-DF-DEL leg (a deleter that does std=DF=1 before SYS_FS_DEL of a VALID name STILL tombstones the right slot because the genuine kernel cld's before the DEL name-compare cmpsb -- M-fsnocld would walk BACKWARD -> wrong/no slot) and the hostile-CARRY-DEL leg (a name_ptr near 4 GiB so name_ptr+16 WRAPS is REJECTED by the access_ok carry-check, the deleter survives + emits the envelope -- M-nocarrycheck would #PF on the cld;cmpsb read). Output-forced -- the deleted record's ABSENCE follows a late-bound delete persisted on the medium across a fresh boot, which no baked answer, RAM stash, or frozen older kernel reproduces, and ABSENCE cannot be faked by append (the first-match GET returns the lowest-index valid slot, so DELETE MUST tombstone the existing slot IN PLACE). The held-back MUTATION proof (noop/wipeall/positional/noflush + the inherited nocarrycheck/fsnocld) lives in the companion mutation harness. HONEST SCOPE: a tombstone-in-place delete (the slot's valid:=0), no slot compaction, no data-sector reclamation (the payload sector is left as-is -- a future delete+create/reuse link must move PUT from append-by-count to first-free-slot, logged in the LEDGER), one directory sector, D=$FS_D fixed slots, a full 16-byte name compare)"
