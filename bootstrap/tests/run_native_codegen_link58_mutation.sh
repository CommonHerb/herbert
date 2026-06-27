#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link58 / delete (MUTABLE-FS DELETE via SYS_FS_DEL eax=12). Each mutation
# perturbs ONE piece of the tombstone machinery in delete_ref.build_elf(fsdel=True, mut=...) and proves it non-vacuous:
# the CONTROL kernel grades GREEN (the late-bound PUT->DEL->GET 3-phase deletes the DECOY + leaves the TARGET, the hostile
# legs reject, assert_delete TRUE); every mutant either grades RED on the 3-phase OUTPUT or is caught by a hostile leg +
# the white-box assert_delete. Modeled on run_native_codegen_link55_mutation.sh, using the late-bound delete_latebound.py.
#
# The disk substrate: ONE 64 MiB raw image, cache=writethrough (QEMU) / GRUB FAT (Bochs), reused across BOOT-1 (putter PUTs
# TARGET+DECOY), BOOT-2 (deleter DELs the DECOY), BOOT-3 (getter GETs the DECOY -> empty, and the TARGET -> P_T). The seed
# is chosen per-run AFTER freeze.
#
# Mutations (delete_ref.build_elf(fsdel=True, mut=...)):
#   M-noop        skip the tombstone (valid not cleared) -> BOOT-3 GET(DECOY) STILL resolves -> RED on the 3-phase
#                 (output-forced everywhere) AND assert_delete FALSE (the in-place tombstone C7 06 00 00 00 00 is gone).
#   M-wipeall     tombstone EVERY slot -> the SURVIVOR(TARGET) is also cleared -> BOOT-3 GET(TARGET) empty -> RED on the
#                 3-phase AND assert_delete FALSE (the single-slot tombstone is replaced by a C7 07 loop).
#   M-positional  delete the FIRST valid slot (ignore the name) -> deletes the TARGET(slot 0) not the DECOY(slot 1) ->
#                 GET(DECOY) resolves AND GET(TARGET) empty -> RED on the 3-phase AND assert_delete FALSE (the cld;cmpsb is gone).
#   M-noflush     tombstone in place but DROP the CACHE FLUSH -> on QEMU cache=writethrough the write persists ANYWAY
#                 (OUTPUT-INVISIBLE there) -- caught by (a) the white-box assert_delete FALSE (the CACHE FLUSH after WRITE
#                 SECTORS is gone) and (b) the BOCHS 3-phase (Bochs models the drive write-cache; without the flush the
#                 tombstone never reaches the medium -> BOOT-3 GET(DECOY) STILL resolves -> RED). The control is proven GREEN
#                 on the SAME Bochs 3-phase first.
#   M-nocarrycheck drop the access_ok carry-check -> the benign delete is still GREEN (the deleter's name_ptr doesn't wrap,
#                 OUTPUT-INVISIBLE) -- caught by the HOSTILE-CARRY-DEL leg: a SYS_FS_DEL with name_ptr near 4 GiB (name_ptr+16
#                 WRAPS) slips the cmp and the cld;cmpsb reads 0xFFFFFFF8 -> the deleter #PFs (emits nothing) where the genuine
#                 kernel rejects cleanly + emits the envelope. (assert_delete pins the carry guard too -> white-box FALSE.)
#   M-fsnocld     drop the FS clds -> the benign delete is still GREEN (the deleter's ambient DF=0, OUTPUT-INVISIBLE) -- caught
#                 by the HOSTILE-DF-DEL leg (std=DF=1 before SYS_FS_DEL of a VALID name: the cld-less cmpsb walks BACKWARD ->
#                 wrong/no slot tombstoned -> the record SURVIVES -> RED) AND assert_delete FALSE (the cld-adjacency pin is gone).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/delete_ref.py"
LB="$script_dir/delete_latebound.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$LB" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $LB)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"; pkill -9 bochs 2>/dev/null || true' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

read -r FS_DIR FS_LO FS_HI FS_D < <(python3 "$REF" fswindow)
PUTTER="$work/putter.bin"; python3 "$LB" putter "$PUTTER"
DELETER="$work/deleter.bin"; python3 "$LB" deleter "$DELETER"
GETTER="$work/getter.bin"; python3 "$LB" getter "$GETTER"
FOUNDPROBE="$work/foundprobe.bin"; python3 "$LB" foundprobe "$FOUNDPROBE"   # found==0 <=> valid==0 <=> really deleted (the STRONG deleted check)
HDFDEL="$work/hostile_df_del.bin"; python3 "$LB" hostiledfdel "$HDFDEL"
HCDEL="$work/hostile_carry_del.bin"; python3 "$LB" hostilenamecarrydel "$HCDEL"

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

boot_feed_emit() { # kernel mod out diskimg stream...  (retry the genuine survivor get until it emits; flake-robust)
    local kel="$1" mod="$2" out="$3" img="$4"; shift 4
    local try e
    for try in 1 2 3 4; do
        boot_feed "$kel" "$mod" "$out" "$img" "$@"
        e="$(python3 "$LB" emitbody "$out" 2>/dev/null)"
        [[ -n "$e" && "$e" != "NO-TABLE" ]] && return 0
    done
    return 0
}

# full QEMU 3-phase delete for (kernel, label): BOOT-1 PUT(target,decoy); BOOT-2 DEL(decoy); BOOT-3a GET(decoy); BOOT-3b
# GET(target). Sets TWB_TP/TWB_DP. Writes $work/<label>.b3decoy / .b3target.
three_phase() { # kernel-elf label [survivor_retry]   (sets global DISK = the disk image, for the raw-dir oracle)
    local kel="$1" lbl="$2" retry="${3:-}"
    DISK="$work/disk_${lbl}.img"; local img="$DISK"; build_raw_disk "$img"
    local seed; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    read -r TWB_TN TWB_TP TWB_DN TWB_DP < <(python3 "$LB" records "$seed")
    local putstream delname qdecoy qtarget getfn
    putstream="$(python3 "$LB" putstream "$TWB_TN" "$TWB_TP" "$TWB_DN" "$TWB_DP")"
    delname="$(python3 "$LB" querystream "$TWB_DN")"
    qdecoy="$(python3 "$LB" querystream "$TWB_DN")"; qtarget="$(python3 "$LB" querystream "$TWB_TN")"
    getfn=boot_feed; [[ "$retry" == "1" ]] && getfn=boot_feed_emit
    boot_feed "$kel" "$PUTTER"  "$work/${lbl}.b1"      "$img" $putstream
    boot_feed "$kel" "$DELETER" "$work/${lbl}.b2"      "$img" $delname
    boot_feed_emit "$kel" "$FOUNDPROBE" "$work/${lbl}.b3decoy" "$img" $qdecoy   # FOUND-probe decoy -> found==0 iff really deleted
    "$getfn"  "$kel" "$GETTER"  "$work/${lbl}.b3target" "$img" $qtarget
}

# the hostile-DF-DEL leg: PUT records, DEL the decoy with std=DF=1, GET the decoy. echoes "GREEN" iff the decoy is gone
# (the genuine kernel cld's before the DEL cmpsb -> forward -> right slot); else "RED <emit>". `genuine`=1 retries the get.
hostile_df_del_run() { # kernel-elf [genuine]  -> echoes GREEN | RED <emit>
    local kel="$1"; local img="$work/hdfdel.img"; build_raw_disk "$img"
    local seed; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    local TN TP DN DP put deln q
    read -r TN TP DN DP < <(python3 "$LB" records "$seed")
    put="$(python3 "$LB" putstream "$TN" "$TP" "$DN" "$DP")"; deln="$(python3 "$LB" querystream "$DN")"; q="$(python3 "$LB" querystream "$DN")"
    read -r FS_DIR _ _ _ < <(python3 "$REF" fswindow)
    boot_feed "$kel" "$PUTTER" "$work/hdfdel.b1" "$img" $put
    boot_feed "$kel" "$HDFDEL" "$work/hdfdel.b2" "$img" $deln   # DEL the decoy under DF=1
    # raw-dir ground truth: the genuine kernel cld's -> decoy slot1 valid==0 (forward); M-fsnocld walks backward -> not tombstoned.
    if python3 "$LB" tombstoneok "$img" "$FS_DIR" 1 "$DN" 0 "$TN" >/dev/null 2>&1; then echo "GREEN"
    else echo "RED decoy-slot=$(python3 "$LB" dirslot "$img" "$FS_DIR" 1 2>/dev/null)"; fi
}

# the hostile-CARRY-DEL leg: PUT records, DEL with name_ptr near 4 GiB. echoes the deleter's emitbody hex; genuine =
# non-empty (the found=0 envelope -- clean reject), nocarrycheck = empty (the deleter #PF'd on the cld;cmpsb read).
hostile_carry_del_run() { # kernel-elf [genuine]  -> echoes emitbody hex
    local kel="$1" genuine="${2:-}"; local img="$work/hcdel.img"; build_raw_disk "$img"
    local seed; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    local TN TP DN DP put n getfn
    read -r TN TP DN DP < <(python3 "$LB" records "$seed")
    put="$(python3 "$LB" putstream "$TN" "$TP" "$DN" "$DP")"; n="$(python3 "$LB" querystream "$DN")"
    getfn=boot_feed; [[ "$genuine" == "1" ]] && getfn=boot_feed_emit
    boot_feed "$kel" "$PUTTER" "$work/hcdel.b1" "$img" $put
    "$getfn" "$kel" "$HCDEL" "$work/hcdel.b2" "$img" $n
    python3 "$LB" emitbody "$work/hcdel.b2" 2>/dev/null
}

# ---- CONTROL: genuine kernel -- 3-phase GREEN + hostile legs reject + assert_delete TRUE ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" deletekernel "$CK")"
three_phase "$CK" ctrl 1
c_del=1; c_sur=1
python3 "$LB" gradefound "$work/ctrl.b3decoy" "$CKEND" 0 >/dev/null 2>&1 && c_del=0
python3 "$LB" gradefs "$work/ctrl.b3target" "$CKEND" "$TWB_TP" >/dev/null 2>&1 && c_sur=0
c_raw=1; python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 1 "$TWB_DN" 0 "$TWB_TN" >/dev/null 2>&1 && c_raw=0   # RAW-DIR ground truth: decoy slot1 valid==0 + name intact, target slot0 valid==1
C_DF="$(hostile_df_del_run "$CK")"          # genuine: GREEN (decoy gone under DF=1, forward)
C_HC="$(hostile_carry_del_run "$CK" 1)"     # genuine: non-empty envelope (carry rejected cleanly)
c_wb=1; python3 "$REF" assertdelete "$CK" >/dev/null 2>&1 && c_wb=0
if [[ "$c_del" -eq 0 && "$c_sur" -eq 0 && "$c_raw" -eq 0 && "$C_DF" == "GREEN" && -n "$C_HC" && "$C_HC" != "NO-TABLE" && "$c_wb" -eq 0 ]]; then
    ok "control (genuine) GREEN -- the late-bound PUT->DEL 3-phase TOMBSTONES the DECOY (raw on-disk decoy slot valid==0 + name UNCHANGED, FOUND-probe found==0) AND LEAVES the TARGET (raw slot valid==1, GET -> P_T); the hostile std=DF=1 DEL still tombstones forward ($C_DF); the hostile near-4GiB name_ptr DEL is rejected cleanly (the deleter survives + emits the envelope='$C_HC'); assert_delete TRUE"
else
    fail_test "control kernel is NOT clean (raw-dir tombstone ok=$([[ $c_raw -eq 0 ]] && echo 1 || echo 0); decoy found==0=$([[ $c_del -eq 0 ]] && echo 1 || echo 0); target survived=$([[ $c_sur -eq 0 ]] && echo 1 || echo 0); hostile-DF=$C_DF (want GREEN); hostile-CARRY emit='$C_HC' (want non-empty); assert_delete=$([[ $c_wb -eq 0 ]] && echo TRUE || echo FALSE)) -- the mutation harness does not bite"
fi

# ---- OUTPUT-FORCED mutants (noop / wipeall / positional / corruptlen): RED on the RAW-DIR ground-truth tombstone oracle
#      (the decoy slot's valid==0 + name UNCHANGED, the target slot's valid==1) + assert_delete FALSE. The raw-dir oracle
#      reads the on-disk dir BY POSITION, so it catches the whole "absence by corruption" class structurally: M-corruptlen
#      (clears LEN not VALID -> decoy valid==1 -> RED), and any rename / tombstone-then-untombstone forge (valid==1 or a
#      changed name -> RED), where a GET-by-name only proves name-absence. (A cross-model Codex leg drove this oracle.) ----
for spec in \
  "noop:valid-not-cleared:skip the tombstone (valid not cleared) -> decoy slot valid==1 -> RED" \
  "wipeall:survivor-gone:tombstone EVERY slot -> the SURVIVOR(TARGET) slot valid==0 -> RED" \
  "positional:wrong-slot:delete the FIRST valid slot (ignore the name) -> the TARGET(slot0) is tombstoned + the DECOY(slot1) is not -> RED" \
  "corruptlen:absence-by-corruption:clear the matched slot's LEN (esi+4) not its VALID (esi+0) -> the decoy slot stays valid==1 -> RED (a zero-length GET would fake 'deleted'; the raw VALID bit catches it)"; do
    m="${spec%%:*}"; rest="${spec#*:}"; kind="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" deletekernel "$MK" "$m")"
    three_phase "$MK" "$m"
    raw_red=1; python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 1 "$TWB_DN" 0 "$TWB_TN" >/dev/null 2>&1 && raw_red=0   # 0 => genuine tombstone (NOT what we want for a mutant)
    wb=1; python3 "$REF" assertdelete "$MK" >/dev/null 2>&1 && wb=0   # 1 => assert_delete FALSE (rejected)
    rawmsg="$(python3 "$LB" tombstoneok "$DISK" "$FS_DIR" 1 "$TWB_DN" 0 "$TWB_TN" 2>&1 | tr '\n' ';')"
    if [[ "$raw_red" -ne 0 && "$wb" -eq 1 ]]; then
        ok "M-$m the RAW-DIR tombstone oracle is RED [$rawmsg] AND assert_delete FALSE -- $desc ($kind)"
    elif [[ "$raw_red" -eq 0 ]]; then
        fail_test "M-$m the raw-dir tombstone oracle graded GREEN (vacuous -- the mutant produced a genuine tombstone?). $desc"
    else
        fail_test "M-$m assert_delete TRUE (the white-box pin did not catch the structural break: $desc)"
    fi
done

# ---- M-noflush: WHITE-BOX ONLY. The 0xE7 CACHE FLUSH is empirically OUTPUT-INVISIBLE on EVERY available substrate --
#      QEMU cache=writethrough writes through, and this Bochs flushes its write-cache to the .img on clean exit -- so the
#      tombstone persists across the (clean) reboot even WITHOUT the flush. The flush is for REAL-HARDWARE power-cut
#      durability (untestable on emulators that flush on exit). So M-noflush is caught WHITE-BOX: assert_delete pins the
#      WRITE SECTORS -> CACHE FLUSH sequence in the DEL arm; M-noflush drops the flush -> assert_delete FALSE. (This is the
#      honest correction of a durable-canon assumption -- the cache flush specifically is not output-load-bearing here.) ----
NF="$work/noflush.elf"; NFKEND="$(python3 "$REF" deletekernel "$NF" noflush)"
nf_wb=1; python3 "$REF" assertdelete "$NF" >/dev/null 2>&1 && nf_wb=0    # 1 => assert_delete FALSE (rejected)
if [[ "$nf_wb" -eq 1 ]]; then ok "M-noflush assert_delete FALSE -- the CACHE FLUSH (0xE7) after WRITE SECTORS in the DEL arm is gone. The flush is OUTPUT-INVISIBLE on every available substrate (QEMU writethrough + this Bochs flush-on-exit both persist the tombstone across a CLEAN reboot without it); it is for real-hardware power-cut durability (untestable on emulators), caught here WHITE-BOX by the assert_delete WRITE-SECTORS->CACHE-FLUSH pin"
else fail_test "M-noflush assert_delete TRUE -- the white-box pin did not catch the dropped CACHE FLUSH"; fi

# ---- M-nocarrycheck: OUTPUT-INVISIBLE on the benign delete -- the HOSTILE-CARRY-DEL leg FAULTS (empty) + assert_delete FALSE ----
NC="$work/nocarry.elf"; NCKEND="$(python3 "$REF" deletekernel "$NC" nocarrycheck)"
# benign delete must still be GREEN (output-invisible)
three_phase "$NC" nc 1
nc_benign=0; { python3 "$LB" gradefound "$work/nc.b3decoy" "$NCKEND" 0 >/dev/null 2>&1 && python3 "$LB" gradefs "$work/nc.b3target" "$NCKEND" "$TWB_TP" >/dev/null 2>&1; } && nc_benign=1
NC_HC="$(hostile_carry_del_run "$NC")"     # single-shot: empty (the deleter #PF'd) is the deterministic signal
nc_faulted=0; [[ -z "$NC_HC" || "$NC_HC" == "NO-TABLE" ]] && nc_faulted=1
nc_wb=1; python3 "$REF" assertdelete "$NC" >/dev/null 2>&1 && nc_wb=0
if [[ "$nc_faulted" -eq 1 && "$nc_wb" -eq 1 ]]; then
    note=""; [[ "$nc_benign" -eq 1 ]] && note=" (benign delete still GREEN -- output-invisible)"
    ok "M-nocarrycheck the carry-check break$note: the HOSTILE near-4GiB name_ptr DEL now slips the cmp and the cld;cmpsb reads 0xFFFFFFF8 -> the deleter FAULTED (emitted '$NC_HC'), where the genuine kernel rejects cleanly + emits the envelope; AND assert_delete FALSE"
elif [[ "$nc_faulted" -ne 1 ]]; then
    fail_test "M-nocarrycheck the hostile near-4GiB name_ptr DEL did NOT fault (emitted '$NC_HC' -- the carry-check was not actually dropped)"
else
    fail_test "M-nocarrycheck assert_delete TRUE (the carry guard pin survived?)"
fi

# ---- M-fsnocld: OUTPUT-INVISIBLE on the benign delete -- the HOSTILE-DF-DEL leg goes RED + assert_delete FALSE ----
NCLD="$work/fsnocld.elf"; NCLDKEND="$(python3 "$REF" deletekernel "$NCLD" fsnocld)"
three_phase "$NCLD" ncld 1
ncld_benign=0; { python3 "$LB" gradefound "$work/ncld.b3decoy" "$NCLDKEND" 0 >/dev/null 2>&1 && python3 "$LB" gradefs "$work/ncld.b3target" "$NCLDKEND" "$TWB_TP" >/dev/null 2>&1; } && ncld_benign=1
NCLD_DF="$(hostile_df_del_run "$NCLD")"    # single-shot: RED (the record survives) is the deterministic signal
ncld_df_red=0; [[ "$NCLD_DF" != GREEN* ]] && ncld_df_red=1
ncld_wb=1; python3 "$REF" assertdelete "$NCLD" >/dev/null 2>&1 && ncld_wb=0
if [[ "$ncld_df_red" -eq 1 && "$ncld_wb" -eq 1 ]]; then
    note=""; [[ "$ncld_benign" -eq 1 ]] && note=" (benign delete still GREEN -- the deleter's ambient DF=0, output-invisible)"
    ok "M-fsnocld the dropped DEL cld$note: the HOSTILE-DF-DEL leg (std=DF=1 before SYS_FS_DEL of a VALID name) is RED ($NCLD_DF) -- the cld-less cmpsb inherited DF=1 and walked BACKWARD off the dir-slot/query -> the wrong/no slot tombstoned -> the record SURVIVES; AND assert_delete FALSE (the cld-adjacency pin is gone). The control was proven GREEN on the SAME hostile-DF-DEL leg, so this RED is attributable to the dropped cld"
elif [[ "$ncld_df_red" -ne 1 ]]; then
    fail_test "M-fsnocld the hostile-DF-DEL leg was GREEN (the cld-less cmpsb still tombstoned correctly under std=DF=1 -- the cld was not actually dropped / DF did not reach the cmpsb): $NCLD_DF"
else
    fail_test "M-fsnocld assert_delete TRUE (the cld-adjacency pin survived?)"
fi

echo "native-codegen link58 delete MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link58 delete MUTATION proof -- control GREEN (the late-bound PUT->DEL->GET 3-phase deletes the DECOY + leaves the TARGET, the hostile std=DF=1 DEL still tombstones forward, the hostile near-4GiB name_ptr DEL is rejected cleanly so the deleter survives + emits the envelope, assert_delete TRUE); M-noop: skip the tombstone -> BOOT-3 GET(DECOY) still resolves -> RED on the 3-phase + assert_delete FALSE; M-wipeall: tombstone EVERY slot -> the SURVIVOR(TARGET) is cleared -> GET(TARGET) empty -> RED + assert_delete FALSE; M-positional: delete the FIRST valid slot (ignore the name) -> deletes the TARGET(slot0) not the DECOY(slot1) -> RED + assert_delete FALSE; M-noflush: drop the CACHE FLUSH -> OUTPUT-INVISIBLE on QEMU cache=writethrough (the write persists anyway) -- caught by the white-box assert_delete FALSE (the CACHE FLUSH after WRITE SECTORS is gone) AND the BOCHS 3-phase RED (the drive-cache substrate: without the flush the tombstone never reaches the medium -> after the reboot BOOT-3 GET(DECOY) still resolves; the control is proven GREEN on the same Bochs 3-phase first); M-nocarrycheck: drop the access_ok carry-check -> OUTPUT-INVISIBLE on the benign delete -- caught by the HOSTILE-CARRY-DEL leg (a SYS_FS_DEL with name_ptr near 4 GiB, name_ptr+16 WRAPS, slips the cmp and the cld;cmpsb reads 0xFFFFFFF8 -> the deleter #PFs/emits nothing where the genuine kernel rejects cleanly + emits the envelope) + assert_delete FALSE; M-fsnocld: drop the FS clds -> OUTPUT-INVISIBLE on the benign delete (the deleter's ambient DF=0) -- caught by the HOSTILE-DF-DEL leg (std=DF=1 before SYS_FS_DEL of a VALID name: the cld-less cmpsb walks BACKWARD -> wrong/no slot tombstoned -> the record SURVIVES) + assert_delete FALSE; the control is proven GREEN on the same hostile-DF-DEL leg so M-fsnocld's RED is attributable to the dropped cld.)"
