#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link55 / cairn (FILESYSTEM CAIRN -- a PERSISTENT NAMED LOOKUP, via
# SYS_FS_PUT eax=7 / SYS_FS_GET eax=8). Each mutation perturbs ONE piece of the name-resolution machinery in
# cairn_ref.build_elf(mut=...) and proves it non-vacuous: the CONTROL kernel grades GREEN (the late-bound two-boot
# two-query named lookup resolves both names correctly AND rejects both hostile requests AND passes assert_cairn);
# every mutant either grades RED on the two-query output OR (the access_ok / data_lba bound breaks) leaks / faults on a
# hostile leg. Modeled EXACTLY on run_native_codegen_link54_mutation.sh, using the LATE-BOUND probers (cairn_latebound.py).
#
# The disk substrate: ONE 64 MiB raw image, cache=writethrough, reused across BOOT-1 (putter PUTs a TARGET + a DECOY,
# names + payloads fed over COM1) and the two BOOT-2 (getter GETs each name). The seed (-> names/payloads/query) is
# chosen per-run AFTER freeze. For the hostile legs the harness crafts a hostile dir / a near-4GiB dst so an escape is
# OBSERVABLE.
#
# Mutations (cairn_ref.build_elf(mut=...)):
#   M-returnfirst   ignore the query name, return the FIRST valid slot (positional, not by-name) -> querying the DECOY
#                   emits the TARGET's payload -> RED on the DECOY query (the two-query design catches it; the decoy-after-
#                   target ordering makes "first valid" = the target). assert_cairn stays TRUE (the data_lba bound + scan
#                   bound are intact) -> this is an OUTPUT-only discriminator.
#   M-fixedlba      ignore the matched entry's stored data_lba, always read FS_DATA_LO (the first data sector) -> querying
#                   the DECOY (whose data sector is FS_DATA_LO+1) reads the TARGET's sector -> wrong payload -> RED on the
#                   DECOY query. assert_cairn stays TRUE -> OUTPUT-only.
#   M-nolbabound    drop the data_lba BY-VALUE bound -> the benign two-query is still GREEN (the records' data_lba are
#                   in-window, OUTPUT-INVISIBLE) -- caught by (a) the HOSTILE-data_lba leg: a crafted dir entry naming
#                   data_lba=0 (the MBR) is now READ + LEAKED (the seeded MBR sentinel comes back) AND (b) assert_cairn FALSE
#                   (the cmp eax,FS_DATA_LO/HI bound on the loaded data_lba is gone).
#   M-nocarrycheck  drop the access_ok +len/+16 carry-checks -> the benign two-query is still GREEN (the records' pointers
#                   don't wrap, OUTPUT-INVISIBLE) -- caught by the HOSTILE-CARRY leg: a GET of a VALID (matching) name with
#                   a dst_ptr near 4 GiB (dst_ptr+len WRAPS) now slips the cmp edx,hi and `rep movsb`'s into 0xFFFFFFF8 (an
#                   out-of-region kernel write) -> the getter #PFs (emits nothing), whereas the genuine kernel rejects
#                   cleanly (the getter survives + emits the found/len envelope). assert_cairn stays TRUE (it does not pin
#                   the carry-check) -> the HOSTILE-CARRY OUTPUT leg is the discriminator.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/cairn_ref.py"
LB="$script_dir/cairn_latebound.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$LB" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $LB)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

read -r FS_DIR FS_LO FS_HI FS_D < <(python3 "$REF" fswindow)
PUTTER="$work/putter.bin"; python3 "$LB" putter "$PUTTER"
GETTER="$work/getter.bin"; python3 "$LB" getter "$GETTER"
HCARRY="$work/hostile_carry.bin"; python3 "$LB" hostilecarry "$HCARRY"
HDF="$work/hostile_df.bin"; python3 "$LB" hostiledf "$HDF"        # the hostile-DF getter (std=DF=1 before SYS_FS_GET)

build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }

# boot kernel+mod feeding a COM1 byte stream; capture debugcon to $out.
boot_feed() { # kernel mod out diskimg stream...
    local kel="$1" mod="$2" out="$3" img="$4"; shift 4
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$d/feed.log" 2>/dev/null || { echo "FAIL: link55 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 70 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$mod" -debugcon file:"$out" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link55 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
}

# boot_feed for a GENUINE getter that MUST emit -- retry up to 4x until the debugcon carries a closed UCODE3 write-frame.
# A rare EMPTY on the genuine path is a wall-clock/emulator timing flake (the COM1-serial / debugcon-flush class; the
# table dumps fine but the final SYS_WRITE frame doesn't materialise under host contention; diagnosed via local repro).
# Retrying is SAFE for MUTANT discrimination: it is used ONLY on the genuine kernel (control + the genuine arm of each
# hostile helper); a MUTANT's empty/wrong is a DETERMINISTIC #PF/mis-walk that recurs every attempt -- the mutant legs
# run their hostile probe SINGLE-SHOT (no retry), so their RED stands.
boot_feed_emit() { # kernel mod out diskimg stream...
    local kel="$1" mod="$2" out="$3" img="$4"; shift 4
    local try e
    for try in 1 2 3 4; do
        boot_feed "$kel" "$mod" "$out" "$img" "$@"
        e="$(python3 "$LB" emitbody "$out" 2>/dev/null)"
        [[ -n "$e" && "$e" != "NO-TABLE" ]] && return 0
    done
    return 0   # fall through; the caller's grade reports the (still-empty) result honestly
}

# full late-bound two-boot two-query for (kernel, label): BOOT-1 putter, then GET TARGET + GET DECOY. Sets globals
# TWB_TP TWB_DP (expected payloads) + writes $work/<label>.b2t / .b2d. Returns the seed used (echoed).
two_boot_two_query() { # kernel-elf label [emit_retry]
    local kel="$1" lbl="$2" emit_retry="${3:-}"
    local img="$work/disk_${lbl}.img"; build_raw_disk "$img"
    local seed getfn; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    read -r TWB_TN TWB_TP TWB_DN TWB_DP < <(python3 "$LB" records "$seed")
    local putstream qt qd
    putstream="$(python3 "$LB" putstream "$TWB_TN" "$TWB_TP" "$TWB_DN" "$TWB_DP")"
    qt="$(python3 "$LB" querystream "$TWB_TN")"; qd="$(python3 "$LB" querystream "$TWB_DN")"
    # the genuine two-query (emit_retry=1) retries the GETs until they emit (flake-robust). Mutant decoyred/lbaleak/etc.
    # legs pass emit_retry="" -- but their benign two-query is EXPECTED green, so a flake there is just cosmetic note noise;
    # the catching is the hostile leg. (We still retry for the genuine control where the two-query GREEN is load-bearing.)
    getfn=boot_feed; [[ "$emit_retry" == "1" ]] && getfn=boot_feed_emit
    boot_feed "$kel" "$PUTTER" "$work/${lbl}.b1" "$img" $putstream
    "$getfn" "$kel" "$GETTER" "$work/${lbl}.b2t" "$img" $qt
    "$getfn" "$kel" "$GETTER" "$work/${lbl}.b2d" "$img" $qd
}

# the hostile-data_lba leg: craft a hostile dir entry naming data_lba=0 (the MBR), seed an MBR sentinel, GET "EVIL".
# echoes the emitted body (hex); genuine = empty (reject), nolbabound = the MBR sentinel (deadbeef).
hostile_lba_run() { # kernel-elf  -> echoes emitbody hex
    local kel="$1"; local img="$work/hlba.img"; build_raw_disk "$img"
    printf '\xDE\xAD\xBE\xEF' | dd of="$img" bs=1 seek=0 conv=notrunc status=none 2>/dev/null
    python3 - "$img" "$FS_DIR" <<'PY'
import sys, struct
img=sys.argv[1]; dir_lba=int(sys.argv[2])
ent=struct.pack('<II',1,4)+(b'EVIL'+b'\x00'*12)+struct.pack('<I',0)   # valid=1,len=4,name=EVIL,data_lba=0 (MBR)
with open(img,'r+b') as f: f.seek(dir_lba*512); f.write(ent+b'\x00'*(512-len(ent)))
PY
    local q; q="$(python3 "$LB" querystream "$(python3 -c "print((b'EVIL'+b'\x00'*12).hex())")")"
    boot_feed "$kel" "$GETTER" "$work/hlba.b2" "$img" $q
    python3 "$LB" emitbody "$work/hlba.b2" 2>/dev/null
}

# the hostile-CARRY leg: PUT valid records, then GET a VALID (matching) name with a near-4GiB dst_ptr. echoes the
# emitbody hex; genuine = non-empty (the (found,len)=(0,0) envelope), nocarrycheck = empty (the getter #PF'd on rep movsb).
# `genuine`=1 retries the getter until it emits (the genuine reject-and-survive is deterministic; a rare empty is a flush
# flake). For a MUTANT (genuine="") the getter runs SINGLE-SHOT -- its empty is the deterministic #PF signal, not a flake.
hostile_carry_run() { # kernel-elf [genuine]  -> echoes emitbody hex
    local kel="$1" genuine="${2:-}"; local img="$work/hc.img"; build_raw_disk "$img"
    local seed getfn; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    read -r TN TP DN DP < <(python3 "$LB" records "$seed")
    local put q
    put="$(python3 "$LB" putstream "$TN" "$TP" "$DN" "$DP")"; q="$(python3 "$LB" querystream "$TN")"
    getfn=boot_feed; [[ "$genuine" == "1" ]] && getfn=boot_feed_emit
    boot_feed "$kel" "$PUTTER" "$work/hc.b1" "$img" $put
    "$getfn" "$kel" "$HCARRY" "$work/hc.b2" "$img" $q
    python3 "$LB" emitbody "$work/hc.b2" 2>/dev/null
}

# the hostile-DF (GAP-2) leg: PUT valid records, then GET a VALID (matching) name with a getter that does std (DF=1)
# before SYS_FS_GET. echoes "GREEN" iff the emitted payload == the target's expected payload (the genuine kernel cld's
# before every FS rep so it resolves FORWARD despite the module's DF); else "RED <emitbody>". A genuine kernel -> GREEN;
# M-fsnocld inherits DF=1 -> the FS reps walk BACKWARD -> wrong resolution / empty -> RED. `genuine`=1 retries until it
# emits (the genuine forward-resolve is deterministic; a rare empty is a flush flake). MUTANT runs SINGLE-SHOT.
hostile_df_run() { # kernel-elf kend [genuine]  -> echoes GREEN | RED <emit>
    local kel="$1" kend="$2" genuine="${3:-}"; local img="$work/hdf.img"; build_raw_disk "$img"
    local seed getfn; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    local TN TP DN DP
    read -r TN TP DN DP < <(python3 "$LB" records "$seed")
    local put q
    put="$(python3 "$LB" putstream "$TN" "$TP" "$DN" "$DP")"; q="$(python3 "$LB" querystream "$TN")"
    getfn=boot_feed; [[ "$genuine" == "1" ]] && getfn=boot_feed_emit
    boot_feed "$kel" "$PUTTER" "$work/hdf.b1" "$img" $put
    "$getfn" "$kel" "$HDF" "$work/hdf.b2" "$img" $q
    if python3 "$LB" gradefs "$work/hdf.b2" "$kend" "$TP" >/dev/null 2>&1; then echo "GREEN"
    else echo "RED $(python3 "$LB" emitbody "$work/hdf.b2" 2>/dev/null)"; fi
}

# ---- CONTROL: genuine kernel -- GREEN on the two-query lookup AND rejects both hostile legs AND passes assert_cairn ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" kernelelf "$CK" none full)"
two_boot_two_query "$CK" ctrl 1                  # emit_retry=1 (genuine two-query must emit; flake-robust)
c_gt=1; c_gd=1
python3 "$LB" gradefs "$work/ctrl.b2t" "$CKEND" "$TWB_TP" >/dev/null 2>&1 && c_gt=0
python3 "$LB" gradefs "$work/ctrl.b2d" "$CKEND" "$TWB_DP" >/dev/null 2>&1 && c_gd=0
C_HLBA="$(hostile_lba_run "$CK")"           # genuine: empty (data_lba=0 rejected -- empty is CORRECT, no retry)
C_HCARRY="$(hostile_carry_run "$CK" 1)"     # genuine=1: non-empty envelope (the dst carry rejected cleanly; retry-until-emit)
C_HDF="$(hostile_df_run "$CK" "$CKEND" 1)"  # genuine=1: GREEN (the kernel cld's before every FS rep -> forward; retry-until-emit)
c_wb=1; python3 "$REF" assertcairn "$CK" >/dev/null 2>&1 && c_wb=0
if [[ "$c_gt" -eq 0 && "$c_gd" -eq 0 && -z "$C_HLBA" && -n "$C_HCARRY" && "$C_HCARRY" != "NO-TABLE" && "$C_HDF" == "GREEN" && "$c_wb" -eq 0 ]]; then
    ok "control (genuine) GREEN -- the late-bound two-query named lookup resolves the TARGET -> P_T AND the DECOY -> P_D (per-name correct, the full 16-byte compare + per-entry data_lba); the hostile data_lba=0 (MBR) GET is REJECTED (ZERO bytes emitted, no MBR leak); the hostile near-4GiB dst_ptr GET is REJECTED cleanly (the getter survives + emits the found/len envelope = '$C_HCARRY'); the hostile std=DF=1 GET STILL resolves correctly (the kernel cld's before every FS rep -> forward, $C_HDF); assert_cairn TRUE"
else
    fail_test "control kernel is NOT clean (TARGET GREEN=$([[ $c_gt -eq 0 ]] && echo 1 || echo 0); DECOY GREEN=$([[ $c_gd -eq 0 ]] && echo 1 || echo 0); hostile-LBA emit='$C_HLBA' (want empty); hostile-CARRY emit='$C_HCARRY' (want non-empty envelope); hostile-DF=$C_HDF (want GREEN); assert_cairn=$([[ $c_wb -eq 0 ]] && echo TRUE || echo FALSE)) -- the mutation harness does not bite"
fi

# ---- each mutation ----
#   returnfirst/fixedlba : the DECOY query goes RED (wrong payload) on the OUTPUT; assert_cairn stays TRUE (output-only).
#   nolbabound           : the benign two-query is GREEN (output-invisible) -- the HOSTILE-data_lba leg LEAKS the MBR AND
#                          assert_cairn FALSE.
#   nocarrycheck         : the benign two-query is GREEN (output-invisible) -- the HOSTILE-CARRY leg FAULTS (empty) where
#                          the genuine kernel emits the envelope; assert_cairn TRUE (not pinned -> the output leg discriminates).
#   fsnocld (GAP-2)      : the benign two-query is GREEN (the probers' ambient DF=0, output-invisible) -- the HOSTILE-DF leg
#                          (std=DF=1 before GET) goes RED (the cld-less FS reps walk BACKWARD -> wrong resolution / leak)
#                          AND assert_cairn FALSE (the FS cld-adjacency pin is gone). The control is proven GREEN on the
#                          SAME hostile-DF leg first (cld present -> forward -> correct), so the mutant isn't RED for an
#                          unrelated reason.
muts=( "returnfirst:decoyred:ignore the query name, return the FIRST valid slot (positional) -> querying the DECOY emits the TARGET's payload (decoy-after-target makes 'first valid' = the target) -> RED on the DECOY query. assert_cairn stays TRUE (the data_lba + scan bounds are intact) -> OUTPUT-only discriminator"
       "fixedlba:decoyred:ignore the matched entry's stored data_lba, always read FS_DATA_LO -> querying the DECOY (data sector FS_DATA_LO+1) reads the TARGET's sector -> wrong payload -> RED on the DECOY query. assert_cairn stays TRUE -> OUTPUT-only"
       "nolbabound:lbaleak:drop the data_lba BY-VALUE bound -> the benign two-query is still GREEN (records' data_lba in-window, OUTPUT-INVISIBLE) but a crafted dir entry naming data_lba=0 (the MBR) is now READ + LEAKED (the seeded MBR sentinel comes back) AND assert_cairn FALSE (the cmp eax,FS_DATA_LO/HI bound is gone)"
       "nocarrycheck:carryfault:drop the access_ok +len/+16 carry-checks -> the benign two-query is still GREEN (records' pointers don't wrap, OUTPUT-INVISIBLE) but a GET with a near-4GiB dst_ptr (dst+len WRAPS) slips cmp edx,hi and rep movsb's into 0xFFFFFFF8 (an out-of-region kernel write) -> the getter #PFs (emits nothing) where the genuine kernel rejects cleanly + emits the envelope"
       "fsnocld:dffault:drop the FS string-op clds (GET name-compare cmpsb, GET/PUT movsb's, PUT stosd, FS sector insw/outsw) -> the benign two-query is still GREEN (the probers' ambient DF=0, OUTPUT-INVISIBLE) but the HOSTILE-DF leg (std=DF=1 before GET of a VALID name) makes the cld-less FS reps walk BACKWARD off diskbuf/dirbuf into the page tables -> wrong resolution / kernel-memory leak -> RED, AND assert_cairn FALSE (the FC F3 A6 / FC F3 A4 / FC F3 AB cld-adjacency pin is gone)" )
for spec in "${muts[@]}"; do
    m="${spec%%:*}"; rest="${spec#*:}"; mode="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" kernelelf "$MK" "$m" full)"
    case "$mode" in
      decoyred)
        # OUTPUT-only: the TARGET query may still be GREEN, but the DECOY query MUST be RED (wrong payload).
        two_boot_two_query "$MK" "$m"
        red_d=1; python3 "$LB" gradefs "$work/$m.b2d" "$MKEND" "$TWB_DP" >/dev/null 2>&1 && red_d=0
        # confirm the DECOY query actually emitted the TARGET's payload (the wrong, positional answer) where applicable.
        emitted_d="$(python3 "$LB" emitbody "$work/$m.b2d" 2>/dev/null)"
        if [[ "$red_d" -eq 1 ]]; then
            wrong_is_target=""
            python3 "$LB" gradefs "$work/$m.b2d" "$MKEND" "$TWB_TP" >/dev/null 2>&1 && wrong_is_target=" (it emitted the TARGET's payload -- the wrong, positional answer)"
            ok "M-$m DECOY query RED -- emitted '$emitted_d' != the DECOY's payload '$TWB_DP'$wrong_is_target ($desc)"
        else
            fail_test "M-$m DECOY query GREEN (vacuous -- the mutant resolved the decoy correctly?: $desc)"
        fi
        ;;
      lbaleak)
        # output-invisible on the benign two-query (PROVE GREEN), then the HOSTILE-data_lba leg LEAKS the MBR + assert_cairn FALSE.
        two_boot_two_query "$MK" "$m"
        benign_green=0; { python3 "$LB" gradefs "$work/$m.b2t" "$MKEND" "$TWB_TP" >/dev/null 2>&1 && python3 "$LB" gradefs "$work/$m.b2d" "$MKEND" "$TWB_DP" >/dev/null 2>&1; } && benign_green=1
        LEAK="$(hostile_lba_run "$MK")"
        leaked=0; [[ -n "$LEAK" && "$LEAK" != "NO-TABLE" ]] && leaked=1
        wb=1; python3 "$REF" assertcairn "$MK" >/dev/null 2>&1 && wb=0
        if [[ "$leaked" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the data_lba bound break is OUTPUT-INVISIBLE on the benign two-query (GREEN) yet the HOSTILE data_lba=0 (MBR) GET now LEAKS bytes (emitted '$LEAK' -- the seeded MBR sentinel) + assert_cairn FALSE ($desc)"
            else
                ok "M-$m hostile data_lba=0 GET LEAKED (emitted '$LEAK') + assert_cairn FALSE (note: this run's benign two-query was also RED) ($desc)"
            fi
        elif [[ "$leaked" -ne 1 ]]; then
            fail_test "M-$m hostile data_lba=0 GET did NOT leak (emitted '$LEAK' -- the data_lba bound was NOT actually dropped) ($desc)"
        else
            fail_test "M-$m assert_cairn TRUE (the data_lba BY-VALUE bound survived? $desc)"
        fi
        ;;
      carryfault)
        # output-invisible on the benign two-query (PROVE GREEN), then the HOSTILE-CARRY leg FAULTS (empty) where the
        # genuine kernel emits the envelope. (assert_cairn does NOT pin the carry-check -> the output leg is the discriminator.)
        two_boot_two_query "$MK" "$m"
        benign_green=0; { python3 "$LB" gradefs "$work/$m.b2t" "$MKEND" "$TWB_TP" >/dev/null 2>&1 && python3 "$LB" gradefs "$work/$m.b2d" "$MKEND" "$TWB_DP" >/dev/null 2>&1; } && benign_green=1
        CEMIT="$(hostile_carry_run "$MK")"
        faulted=0; [[ -z "$CEMIT" || "$CEMIT" == "NO-TABLE" ]] && faulted=1
        if [[ "$faulted" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the carry-check break is OUTPUT-INVISIBLE on the benign two-query (GREEN) yet the HOSTILE near-4GiB dst_ptr GET now slips the cmp edx,hi and rep movsb's into 0xFFFFFFF8 (an out-of-region kernel write) -> the getter FAULTED (emitted '$CEMIT'), where the genuine kernel rejects cleanly + emits the found/len envelope ($desc)"
            else
                ok "M-$m hostile near-4GiB dst_ptr GET FAULTED (emitted '$CEMIT') (note: this run's benign two-query was also RED) ($desc)"
            fi
        else
            fail_test "M-$m hostile near-4GiB dst_ptr GET did NOT fault (emitted '$CEMIT' -- the carry-check was NOT actually dropped / the wrapped write did not escape) ($desc)"
        fi
        ;;
      dffault)
        # GAP-2: output-invisible on the benign two-query (PROVE GREEN), then the HOSTILE-DF leg goes RED (the cld-less FS
        # reps walk BACKWARD under std=DF=1) AND assert_cairn FALSE (the cld-adjacency pin is gone). The CONTROL was proven
        # GREEN on the SAME hostile-DF leg above, so this RED is attributable to the dropped clds, not an unrelated cause.
        two_boot_two_query "$MK" "$m"
        benign_green=0; { python3 "$LB" gradefs "$work/$m.b2t" "$MKEND" "$TWB_TP" >/dev/null 2>&1 && python3 "$LB" gradefs "$work/$m.b2d" "$MKEND" "$TWB_DP" >/dev/null 2>&1; } && benign_green=1
        DFRES="$(hostile_df_run "$MK" "$MKEND")"
        df_red=0; [[ "$DFRES" != GREEN* ]] && df_red=1
        wb=1; python3 "$REF" assertcairn "$MK" >/dev/null 2>&1 && wb=0
        if [[ "$df_red" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the dropped FS clds are OUTPUT-INVISIBLE on the benign two-query (GREEN, the probers' ambient DF=0) yet the HOSTILE-DF leg (std=DF=1 before GET of a VALID name) is RED ($DFRES) -- the cld-less FS reps inherited DF=1 and walked BACKWARD off diskbuf/dirbuf into the page tables (wrong resolution / kernel-memory leak) AND assert_cairn FALSE (the cld-adjacency pin is gone) ($desc)"
            else
                ok "M-$m hostile-DF leg RED ($DFRES) + assert_cairn FALSE (note: this run's benign two-query was also RED) ($desc)"
            fi
        elif [[ "$df_red" -ne 1 ]]; then
            fail_test "M-$m hostile-DF leg was GREEN (the cld-less FS reps still resolved correctly under std=DF=1 -- the clds were NOT actually dropped / DF did not reach the reps): $DFRES ($desc)"
        else
            fail_test "M-$m assert_cairn TRUE (the FS cld-adjacency pin survived? $desc)"
        fi
        ;;
    esac
done

echo "native-codegen link55 cairn MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link55 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link55 cairn MUTATION proof -- control GREEN (the late-bound two-boot two-query named lookup resolves the TARGET -> P_T AND the DECOY -> P_D per-name correctly, forcing the full 16-byte compare + the per-entry data_lba; the hostile data_lba=0 (MBR) GET is REJECTED with no leak; the hostile near-4GiB dst_ptr GET is REJECTED cleanly so the getter survives + emits the found/len envelope; assert_cairn TRUE); M-returnfirst: ignore the query name, return the FIRST valid slot -> querying the DECOY emits the TARGET's payload (decoy-after-target makes 'first valid' = the target) -> RED on the DECOY query (the two-query design is what catches it -- a single TARGET query would be GREEN); M-fixedlba: ignore the matched entry's stored data_lba, always read FS_DATA_LO -> querying the DECOY reads the TARGET's sector -> wrong payload -> RED on the DECOY query; M-nolbabound: drop the data_lba BY-VALUE bound -- OUTPUT-INVISIBLE on the benign two-query (still GREEN, the records' data_lba are in-window) -- caught by the HOSTILE-data_lba leg (a crafted dir entry naming data_lba=0, the MBR, is now READ + LEAKED -- the seeded MBR sentinel comes back) AND by the white-box assert_cairn FALSE (the cmp eax,FS_DATA_LO/HI bound on the loaded data_lba is gone); M-nocarrycheck: drop the access_ok +len/+16 carry-checks -- OUTPUT-INVISIBLE on the benign two-query (still GREEN, the records' pointers don't wrap) -- caught by the HOSTILE-CARRY leg (a GET of a VALID name with a dst_ptr near 4 GiB, so dst_ptr+len WRAPS, slips the cmp edx,hi and rep movsb's into 0xFFFFFFF8, an out-of-region kernel write -> the getter #PFs and emits nothing, where the genuine kernel rejects cleanly + emits the found/len envelope); M-fsnocld (GAP-2): drop the FS string-op clds (the GET name-compare cmpsb, the GET/PUT movsb's, the PUT stosd, the FS sector insw/outsw) -- OUTPUT-INVISIBLE on the benign two-query (still GREEN, the probers' ambient DF=0) -- caught by the HOSTILE-DF leg (a getter that does std=DF=1 before SYS_FS_GET of a VALID name: the cld-less FS reps inherit DF=1 and walk BACKWARD off diskbuf/dirbuf into the page tables -> wrong resolution / a kernel-memory leak -> RED, where the genuine kernel cld's before every FS rep so it STILL resolves correctly FORWARD) AND by the white-box assert_cairn FALSE (the FC F3 A6 / FC F3 A4 / FC F3 AB cld-adjacency pin is gone); the control is proven GREEN on the SAME hostile-DF leg first so M-fsnocld's RED is attributable to the dropped clds. The hostile MBR is seeded with a known sentinel per-run so a leak is observable.)"
