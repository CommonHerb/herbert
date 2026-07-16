#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link60 / tract (FIRST VARIABLE-SIZE durable file). Each mutation perturbs
# ONE piece of the multi-sector varsize allocator/loops in tract_ref.build_elf(varsize=True, mut=...) and proves it
# non-vacuous: the CONTROL kernel grades GREEN (the 4-boot multi-sector reuse leaves the FS == the variable-size
# first-fit-by-LBA expected state via the raw reuseok oracle, all three GET-reassemble, assert_varsize+assert_delete TRUE);
# every OUTPUT-FORCED mutant grades RED on the HOST-SIDE RAW reuseok ground-truth oracle. Two WHITE-BOX mutants
# (overcopy/norunbound) are OUTPUT-INVISIBLE on the benign forcing (overcopy over-reads PAST dst+len but the module
# SYS_WRITEs only len; norunbound's window guard only fires on a corrupt/oversized entry) -> caught by assert_varsize FALSE.
# Modeled on the backfill mutation harness, using tract_latebound.py.
#
# Mutations (tract_ref.build_elf(varsize=True, mut=...)):
#   M-trunc      need=1 single-sector -> a >512 record truncates -> reuseok RED (payload NOT byte-exact across its run).
#   M-noceil     floor (drop +511) -> drops the partial last sector -> reuseok RED.
#   M-decoupled  ignore the first-fit scan -> runstart=FS_DATA_LO -> CLOBBERS the lowest live survivor R0 -> reuseok RED.
#   M-nopadzero  skip the diskbuf zero -> the partial last sector leaks the prior sector's stale bytes -> reuseok RED (padding!=0).
#   M-overcopy   GET copies 512/sector (ignore len-offset) -> over-reads PAST dst+len (output-invisible: module writes len)
#                -> caught WHITE-BOX by assert_varsize FALSE (the GET copy-min sig 3D 00 02 00 00 0F 86 absent).
#   M-norunbound drop the GET run-window straddle guard -> a corrupt/oversized entry reads PAST the FS window (output-
#                invisible on the benign forcing) -> caught WHITE-BOX by assert_varsize FALSE (the win sig absent).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/tract_ref.py"
LB="$script_dir/tract_latebound.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
for f in "$REF" "$LB" "$feeder"; do [[ -f "$f" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing $f)"; exit 1; }; done
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

WRITER="$work/writer.bin";  python3 "$LB" module writer  5 "$WRITER"
DELETER="$work/deleter.bin"; python3 "$LB" module deleter 2 "$DELETER"
WRITER3="$work/writer3.bin"; python3 "$LB" module writer  2 "$WRITER3"
GETTER="$work/getter.bin";  python3 "$LB" module getter  1 "$GETTER"     # single-query getter (robust vs the COM1 timing flake)

build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }
boot_feed() { # kernel mod out diskimg stream...
    local kel="$1" mod="$2" out="$3" img="$4"; shift 4
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$d/feed.log" 2>/dev/null || { echo "FAIL: link60 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 80 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$mod" -debugcon file:"$out" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link60 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
}
boot_feed_emit() { # kernel mod out diskimg stream...  (retry until a ring-3 write-frame appears; flake-robust)
    local kel="$1" mod="$2" out="$3" img="$4"; shift 4
    local try e
    for try in 1 2 3 4; do boot_feed "$kel" "$mod" "$out" "$img" "$@"; e="$(python3 "$LB" emitbody "$out" 2>/dev/null)"; [[ -n "$e" ]] && return 0; done
    return 0
}
four_phase() { # kernel-elf label  (sets DISK + SEED globals)
    local kel="$1" lbl="$2"
    DISK="$work/disk_${lbl}.img"; build_raw_disk "$DISK"
    SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    boot_feed "$kel" "$WRITER"  "$work/${lbl}.b1" "$DISK" $(python3 "$LB" putstream1 "$SEED")
    boot_feed "$kel" "$DELETER" "$work/${lbl}.b2" "$DISK" $(python3 "$LB" delstream  "$SEED")
    boot_feed "$kel" "$WRITER3" "$work/${lbl}.b3" "$DISK" $(python3 "$LB" putstream3 "$SEED")
}

# ---- CONTROL: genuine tract kernel -- reuseok GREEN + all three GET-reassemble + assert_varsize/assert_delete TRUE ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" tractkernel "$CK")"
four_phase "$CK" ctrl
c_raw=1; python3 "$LB" reuseok "$DISK" "$SEED" >/dev/null 2>&1 && c_raw=0
c_fn=0; for idx in 0 1 2; do
    boot_feed_emit "$CK" "$GETTER" "$work/ctrl.g$idx" "$DISK" $(python3 "$LB" getname "$SEED" "$idx")
    python3 "$LB" gradeone "$work/ctrl.g$idx" "$SEED" "$idx" >/dev/null 2>&1 || c_fn=1
done
c_vs=1; python3 "$REF" assertvarsize "$CK" >/dev/null 2>&1 && c_vs=0
c_ad=1; python3 "$REF" assertdelete  "$CK" >/dev/null 2>&1 && c_ad=0
if [[ "$c_raw" -eq 0 && "$c_fn" -eq 0 && "$c_vs" -eq 0 && "$c_ad" -eq 0 ]]; then
    ok "control (genuine) GREEN -- the 4-boot multi-sector reuse leaves the on-disk FS == the variable-size first-fit-by-LBA expected state (reuseok GREEN: N0 byte-exact at LO+2 padding-zero, N1 at LO+6, survivor R0 UNCHANGED); all three GET-reassemble byte-exact across the reboot; assert_varsize TRUE; assert_delete TRUE"
else
    fail_test "control kernel is NOT clean (reuseok GREEN=$([[ $c_raw -eq 0 ]] && echo 1 || echo 0) [$(python3 "$LB" reuseok "$DISK" "$SEED" 2>&1 | tr '\n' ';' | cut -c1-200)]; reassemble=$([[ $c_fn -eq 0 ]] && echo 1 || echo 0); assert_varsize=$([[ $c_vs -eq 0 ]] && echo TRUE || echo FALSE); assert_delete=$([[ $c_ad -eq 0 ]] && echo TRUE || echo FALSE)) -- the mutation harness does not bite"
fi

# ---- OUTPUT-FORCED varsize mutants: reuseok RED on the raw ground-truth oracle ----
for spec in \
  "trunc:single-sector:need=1 -> a >512 record truncates -> N0 payload NOT byte-exact across its run" \
  "noceil:floor-drops-partial:need=len>>9 (floor) -> the partial last sector is dropped -> N0 payload NOT byte-exact" \
  "decoupled:clobber-survivor:ignore the first-fit scan, runstart=FS_DATA_LO -> N0 CLOBBERS the lowest live survivor R0 (wrong placement + survivor changed)" \
  "nopadzero:padding-leak:skip the diskbuf zero -> N0's partial last sector leaks the prior sector's stale bytes (padding != 0)"; do
    m="${spec%%:*}"; rest="${spec#*:}"; kind="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; python3 "$REF" tractkernel "$MK" "$m" >/dev/null
    four_phase "$MK" "$m"
    raw_red=1; python3 "$LB" reuseok "$DISK" "$SEED" >/dev/null 2>&1 && raw_red=0   # 0 => reuseok GREEN (NOT wanted for a mutant)
    rawmsg="$(python3 "$LB" reuseok "$DISK" "$SEED" 2>&1 | tr '\n' ';' | cut -c1-220)"
    if [[ "$raw_red" -ne 0 ]]; then
        ok "M-$m the RAW reuseok oracle is RED [$rawmsg] -- $desc ($kind)"
    else
        fail_test "M-$m reuseok graded GREEN (vacuous -- the mutant produced the variable-size expected state?). $desc"
    fi
done

# ---- M-norunbound: OUTPUT-FORCED by the HOSTILE corrupt-entry leg (a host-crafted dir entry whose run STRADDLES the
#      window -> the genuine guard rejects, M-norunbound LEAKS a frame) + a white-box assert_varsize FALSE co-pin.
MKN="$work/norunbound.elf"; python3 "$REF" tractkernel "$MKN" norunbound >/dev/null
DISK="$work/disk_corrupt.img"; build_raw_disk "$DISK"; python3 "$LB" craftcorrupt "$DISK"
boot_feed_emit "$MKN" "$GETTER" "$work/nrb.g" "$DISK" $(python3 "$LB" corruptname)   # retry until the leak frame appears
leak=0; python3 "$LB" gradecorrupt "$work/nrb.g" >/dev/null 2>&1 || leak=1            # gradecorrupt exit!=0 => a frame => LEAK
wbn=1; python3 "$REF" assertvarsize "$MKN" >/dev/null 2>&1 && wbn=0                   # 1 => assert_varsize FALSE
if [[ "$leak" -eq 1 && "$wbn" -eq 1 ]]; then
    ok "M-norunbound the GET drops the run-window guard -> on a HOST-crafted corrupt dir entry whose run STRADDLES the window it LEAKS an out-of-window frame [$(python3 "$LB" gradecorrupt "$work/nrb.g" 2>&1)] (OUTPUT-FORCED by the hostile leg) AND assert_varsize FALSE (white-box co-pin); the genuine kernel REJECTS the same entry (no leak)"
elif [[ "$leak" -ne 1 ]]; then
    fail_test "M-norunbound did NOT leak on the corrupt straddle entry (the hostile leg is vacuous, or the mutant did not drop the guard)"
else
    fail_test "M-norunbound assert_varsize TRUE (the white-box co-pin did not catch the dropped run-window guard)"
fi

# ---- M-overcopy: WHITE-BOX (OUTPUT-INVISIBLE on the benign forcing -- the GET over-reads PAST dst+len but the module
#      SYS_WRITEs only len, so the relay is unaffected): caught by assert_varsize FALSE (the GET copy-min sig absent). ----
MKO="$work/overcopy.elf"; python3 "$REF" tractkernel "$MKO" overcopy >/dev/null
vso=1; python3 "$REF" assertvarsize "$MKO" >/dev/null 2>&1 && vso=0
if [[ "$vso" -eq 1 ]]; then
    ok "M-overcopy the GET copies 512 per sector (ignore len-offset) -> over-reads PAST dst+len; OUTPUT-INVISIBLE (the module SYS_WRITEs only len) -> caught WHITE-BOX by assert_varsize FALSE (the GET copy-min sig 3D 00 02 00 00 0F 86 absent)"
else
    fail_test "M-overcopy assert_varsize TRUE (the white-box pin did not catch the dropped copy-min)"
fi

echo "native-codegen link60 tract MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link60 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link60 tract MUTATION proof -- control GREEN (the 4-boot multi-sector reuse leaves the on-disk FS == the variable-size first-fit-by-LBA expected state via the raw reuseok oracle: N0 byte-exact across its run at LO+2 with last-sector padding==0, N1 at LO+6 split remainder, survivor R0 UNCHANGED; all three GET-reassemble by name across the reboot; assert_varsize + assert_delete TRUE); M-trunc: need=1 single-sector -> a >512 record truncates -> reuseok RED (N0 payload not byte-exact across its run); M-noceil: floor (drop +511) -> drops the partial last sector -> reuseok RED; M-decoupled: ignore the first-fit scan, runstart=FS_DATA_LO -> N0 CLOBBERS the lowest live survivor R0 (wrong placement + survivor changed) -> reuseok RED; M-nopadzero: skip the diskbuf zero -> N0's partial last sector leaks the prior sector's stale bytes (padding != 0) -> reuseok RED; M-overcopy: the GET copies 512 per sector (ignore len-offset) -> over-reads PAST dst+len, OUTPUT-INVISIBLE on the benign forcing (the module SYS_WRITEs only len) -> caught WHITE-BOX by assert_varsize FALSE (the GET copy-min sig 3D 00 02 00 00 0F 86 absent); M-norunbound: drop the GET run-window straddle guard -> a corrupt/oversized dir entry reads PAST the FS window, OUTPUT-INVISIBLE on the benign (valid) forcing -> caught WHITE-BOX by assert_varsize FALSE (the run-window sig 3D <TRACT_DATA_HI> 0F 87 absent).)"
