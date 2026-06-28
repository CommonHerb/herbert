#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link59 / backfill (mutable-FS PUT FIRST-FREE-SLOT REUSE, pays D22). Each
# mutation perturbs ONE piece of the first-free allocator in backfill_ref.build_elf(fsreuse=True, mut=...) and proves it
# non-vacuous: the CONTROL kernel grades GREEN (the 4-boot capacity-exhaustion reuse leaves the FS == the first-free
# expected state, assert_backfill TRUE); every output-forced mutant grades RED on the HOST-SIDE RAW reuseok ground-truth
# oracle (the on-disk dir + data sectors diverge from the first-free expected) AND assert_backfill FALSE. The two inherited
# FS-guard mutants (nocarrycheck/fsnocld) are OUTPUT-INVISIBLE on the benign reuse and are caught WHITE-BOX (assert_delete
# FALSE -- those guards are shared across PUT/GET/DEL and assert_delete pins both in the DEL arm; their hostile output legs
# live in the frozen cairn/delete gates, which run on every CI). Modeled on the delete mutation harness, using backfill_latebound.py.
#
# The disk substrate: ONE 64 MiB raw image, cache=writethrough (QEMU), reused across BOOT-1 (filler PUTs FS_D records),
# BOOT-2 (multi-deleter DELs THREE slots {0,i,j} in a scrambled order), BOOT-3 (putter PUTs three NEW records). The PRIMARY
# grade is reuseok, which reads the on-disk dir + all data sectors BY POSITION. Seeds are chosen per-run AFTER freeze.
#
# Mutations (backfill_ref.build_elf(fsreuse=True, mut=...)):
#   M-scanfrom1   the first-free scan starts at slot 1 (mov ecx,1) -> the slot-0 hole is NEVER reused -> reuseok RED +
#                 assert_backfill FALSE (the cross-model Codex leg found this; the slot-0 hole + the 31 C9 scan-from-0 pin catch it).
#   M-append      allocate by count(valid==1) (the D22 BUG): after DELeting three slots, PUT writes slot count=FS_D-3
#                 (a LIVE survivor) -> clobbers it -> reuseok RED + assert_backfill FALSE (the count store A3 fs_nent is
#                 present / the first-free 89 0D fs_nent + freeslot data_lba are absent).
#   M-tailappend  slot = (highest valid index)+1: tail = FS_D under capacity exhaustion -> reject -> the new record is not
#                 stored -> reuseok RED (the holes stay empty) + assert_backfill FALSE.
#   M-decoupled   first-free slot but data_lba FIXED at FS_DATA_LO: the new payload overwrites a LIVE survivor's data
#                 sector (and the reused slot's data_lba != FS_DATA_LO+slot) -> reuseok RED + assert_backfill FALSE.
#   M-wrongscan   pick the FIRST valid==1 slot (inverted scan) -> overwrite a live survivor -> reuseok RED + assert_backfill FALSE.
#   M-nocarrycheck drop the FS access_ok carry-check (inherited, shared PUT/GET/DEL guard) -> OUTPUT-INVISIBLE on the benign
#                 reuse -- caught WHITE-BOX by assert_delete FALSE (its hostile near-4GiB-ptr output leg lives in the cairn/delete gates).
#   M-fsnocld     drop the FS clds (inherited, shared guard) -> OUTPUT-INVISIBLE on the benign reuse -- caught WHITE-BOX by
#                 assert_delete FALSE (its hostile std=DF=1 output leg lives in the cairn/delete gates).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/backfill_ref.py"
LB="$script_dir/backfill_latebound.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
for f in "$REF" "$LB" "$feeder"; do [[ -f "$f" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing $f)"; exit 1; }; done
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

read -r FS_DIR FS_LO FS_HI FS_D < <(python3 "$REF" fswindow)
FILLER="$work/filler.bin"; python3 "$LB" filler "$FILLER"
MULTIDEL="$work/multidel.bin"; python3 "$LB" multideleter "$MULTIDEL" 3
PUTTER2="$work/putter2.bin"; python3 "$LB" putter2 "$PUTTER2"
GETTER="$work/getter.bin"; python3 "$LB" getter "$GETTER"

build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }

boot_feed() { # kernel mod out diskimg stream...
    local kel="$1" mod="$2" out="$3" img="$4"; shift 4
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$mod" -debugcon file:"$out" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
boot_feed_emit() { # kernel mod out diskimg stream...  (retry the genuine get until it emits; flake-robust)
    local kel="$1" mod="$2" out="$3" img="$4"; shift 4
    local try e
    for try in 1 2 3 4; do
        boot_feed "$kel" "$mod" "$out" "$img" "$@"
        e="$(python3 "$LB" emitbody "$out" 2>/dev/null)"
        [[ -n "$e" && "$e" != "NO-TABLE" ]] && return 0
    done
    return 0
}

# 4-boot reuse for (kernel, label) on a fresh disk; sets DISK + FSEED/NSEED globals for reuseok.
four_phase() { # kernel-elf label
    local kel="$1" lbl="$2"
    DISK="$work/disk_${lbl}.img"; build_raw_disk "$DISK"
    FSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"; NSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    local fillstream delstream newstream
    fillstream="$(python3 "$LB" fillstream "$FSEED")"; delstream="$(python3 "$LB" delstream "$FSEED")"; newstream="$(python3 "$LB" newstream "$NSEED")"
    boot_feed "$kel" "$FILLER"   "$work/${lbl}.b1" "$DISK" $fillstream
    boot_feed "$kel" "$MULTIDEL" "$work/${lbl}.b2" "$DISK" $delstream
    boot_feed "$kel" "$PUTTER2"  "$work/${lbl}.b3" "$DISK" $newstream
}

# ---- CONTROL: genuine backfill kernel -- reuseok GREEN + both NEW records GET-resolve + assert_backfill/cairn TRUE ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" backfillkernel "$CK")"
four_phase "$CK" ctrl
c_raw=1; python3 "$LB" reuseok "$DISK" "$FSEED" "$NSEED" >/dev/null 2>&1 && c_raw=0
c_fn=0; for idx in 0 1 2; do
    read -r nm pay < <(python3 "$LB" newrec "$NSEED" "$idx"); q="$(python3 "$LB" querystream "$nm")"
    boot_feed_emit "$CK" "$GETTER" "$work/ctrl.g$idx" "$DISK" $q
    python3 "$LB" gradefs "$work/ctrl.g$idx" "$CKEND" "$pay" >/dev/null 2>&1 || c_fn=1
done
c_wb=1; python3 "$REF" assertbackfill "$CK" >/dev/null 2>&1 && c_wb=0
c_ad=1; python3 "$REF" assertdelete "$CK" >/dev/null 2>&1 && c_ad=0
if [[ "$c_raw" -eq 0 && "$c_fn" -eq 0 && "$c_wb" -eq 0 && "$c_ad" -eq 0 ]]; then
    ok "control (genuine) GREEN -- the 4-boot capacity-exhaustion reuse leaves the on-disk FS == the first-free expected state (reuseok GREEN: the three NEW records occupy the freed holes {0,i,j} lowest-first, 1:1 data_lba, freed sectors carry the new payloads, every survivor UNCHANGED); all NEW records GET-resolve by name across the reboot; assert_backfill TRUE; assert_delete TRUE"
else
    fail_test "control kernel is NOT clean (reuseok GREEN=$([[ $c_raw -eq 0 ]] && echo 1 || echo 0) [$(python3 "$LB" reuseok "$DISK" "$FSEED" "$NSEED" 2>&1 | tr '\n' ';' | cut -c1-200)]; new-resolve=$([[ $c_fn -eq 0 ]] && echo 1 || echo 0); assert_backfill=$([[ $c_wb -eq 0 ]] && echo TRUE || echo FALSE); assert_delete=$([[ $c_ad -eq 0 ]] && echo TRUE || echo FALSE)) -- the mutation harness does not bite"
fi

# ---- OUTPUT-FORCED first-free mutants: reuseok RED + assert_backfill FALSE ----
for spec in \
  "scanfrom1:scan-skips-slot-0:the first-free scan starts at slot 1 (mov ecx,1) -> the slot-0 hole is NEVER reused -> slot 0 stays empty and the new records shift -> reuseok RED (the cross-model leg found this forge; the slot-0 forcing leg + the assert_backfill 31 C9 scan-from-0 pin catch it)" \
  "append:the-D22-bug:allocate by count(valid==1) -> after DELeting three slots, PUT writes slot count=FS_D-3 (a LIVE survivor) and clobbers it; the freed holes stay empty" \
  "tailappend:tail-overflow:slot=(highest valid index)+1 -> tail=FS_D under capacity exhaustion -> reject -> the new record is not stored; the holes stay empty" \
  "decoupled:wrong-data-sector:first-free slot but data_lba FIXED at FS_DATA_LO -> the new payload overwrites a LIVE survivor's data sector + the reused slot's data_lba != FS_DATA_LO+slot" \
  "wrongscan:inverted-scan:pick the FIRST valid==1 slot -> overwrite a live survivor (the holes stay empty)"; do
    m="${spec%%:*}"; rest="${spec#*:}"; kind="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; python3 "$REF" backfillkernel "$MK" "$m" >/dev/null
    four_phase "$MK" "$m"
    raw_red=1; python3 "$LB" reuseok "$DISK" "$FSEED" "$NSEED" >/dev/null 2>&1 && raw_red=0   # 0 => reuseok GREEN (NOT what we want for a mutant)
    wb=1; python3 "$REF" assertbackfill "$MK" >/dev/null 2>&1 && wb=0                          # 1 => assert_backfill FALSE (rejected)
    rawmsg="$(python3 "$LB" reuseok "$DISK" "$FSEED" "$NSEED" 2>&1 | tr '\n' ';' | cut -c1-220)"
    if [[ "$raw_red" -ne 0 && "$wb" -eq 1 ]]; then
        ok "M-$m the RAW reuseok oracle is RED [$rawmsg] AND assert_backfill FALSE -- $desc ($kind)"
    elif [[ "$raw_red" -eq 0 ]]; then
        fail_test "M-$m reuseok graded GREEN (vacuous -- the mutant produced the first-free expected state?). $desc"
    else
        fail_test "M-$m assert_backfill TRUE (the white-box pin did not catch the structural break: $desc)"
    fi
done

# ---- INHERITED FS-guard mutants (OUTPUT-INVISIBLE on the benign reuse): caught WHITE-BOX by assert_delete FALSE.
#      The access_ok carry-check + the FS clds are SHARED across the PUT/GET/DEL arms; assert_delete pins both in the DEL
#      arm (its D2 carry guard `add edx,16 ; jb` + its D3 cld-led name-compare `mov ecx,16 ; cld ; repe cmpsb`), so
#      dropping either trips assert_delete. Their hostile OUTPUT legs (near-4GiB name_ptr / std=DF=1) live in the frozen
#      cairn + delete gates (run on every CI); backfill does NOT change the access_ok/cld, so re-driving them here would
#      only re-test cairn/delete. (assert_cairn catches fsnocld but NOT nocarrycheck, so assert_delete is the right pin.) ----
for m in nocarrycheck fsnocld; do
    MK="$work/$m.elf"; python3 "$REF" backfillkernel "$MK" "$m" >/dev/null
    bf=1; python3 "$REF" assertbackfill "$MK" >/dev/null 2>&1 && bf=0    # the first-free structure is intact (1 => still TRUE)
    ad=1; python3 "$REF" assertdelete "$MK" >/dev/null 2>&1 && ad=0      # 1 => assert_delete FALSE (the inherited guard is gone)
    if [[ "$ad" -eq 1 ]]; then
        ok "M-$m the inherited FS $([[ "$m" == nocarrycheck ]] && echo 'access_ok carry-check' || echo 'clds') is dropped -> assert_delete FALSE (OUTPUT-INVISIBLE on the benign reuse; its hostile $([[ "$m" == nocarrycheck ]] && echo 'near-4GiB name_ptr' || echo 'std=DF=1') output leg lives in the frozen cairn/delete gates). assert_backfill is $([[ $bf -eq 0 ]] && echo TRUE || echo FALSE) (the first-free structure is untouched by this guard mutation)"
    else
        fail_test "M-$m assert_delete TRUE (the inherited FS guard was not actually dropped, or the pin does not catch it)"
    fi
done

echo "native-codegen link59 backfill MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link59 backfill MUTATION proof -- control GREEN (the 4-boot capacity-exhaustion reuse leaves the on-disk FS == the first-free expected state via the raw reuseok oracle: the three NEW records occupy the freed holes {0,i,j} lowest-first with 1:1 data_lba + the freed sectors carry the new payloads + every survivor UNCHANGED; all NEW records GET-resolve by name across the reboot; assert_backfill + assert_delete TRUE); M-scanfrom1: the first-free scan starts at slot 1 (mov ecx,1) -> the slot-0 hole is NEVER reused -> reuseok RED + assert_backfill FALSE (the cross-model leg found this forge; the slot-0 forcing leg + the assert_backfill 31 C9 scan-from-0 pin catch it); M-append: allocate by count(valid==1) (the D22 bug) -> after DELeting three slots PUT writes slot count=FS_D-3 (a LIVE survivor) and clobbers it -> reuseok RED + assert_backfill FALSE; M-tailappend: slot=(highest valid index)+1 -> tail=FS_D under capacity exhaustion -> reject -> the new record is not stored -> reuseok RED + assert_backfill FALSE; M-decoupled: first-free slot but data_lba FIXED at FS_DATA_LO -> the new payload overwrites a LIVE survivor's data sector + the reused slot's data_lba != FS_DATA_LO+slot -> reuseok RED + assert_backfill FALSE; M-wrongscan: pick the FIRST valid==1 slot -> overwrite a live survivor -> reuseok RED + assert_backfill FALSE; M-nocarrycheck + M-fsnocld: the inherited FS access_ok carry-check / clds dropped -> OUTPUT-INVISIBLE on the benign reuse -> caught WHITE-BOX by assert_delete FALSE (its D2 carry guard / D3 cld-led name-compare in the DEL arm; their hostile near-4GiB-name_ptr / std=DF=1 output legs live in the frozen cairn + delete gates, which run on every CI; backfill does not change the access_ok/cld).)"
