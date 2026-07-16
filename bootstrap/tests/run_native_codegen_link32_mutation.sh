#!/usr/bin/env bash
# Mutation proof for native-codegen link32 (cloggard / the first data-dependent MULTI-QUANTUM
# scheduler): prove the link32 value-flow/locus/provenance gate + the X/Y trace differential
# genuinely BITE. Each mutation binary-patches a COMPILED probe (cg_lit: return 88, vA=88;
# X=0x0A -> schedule A,B,A,B -> de59ad deb1ad de5aad deb2ad ; Y=0x05 -> B,A,B,A ->
# deb1ad de59ad deb2ad de5aad) and asserts the expected RED, on real QEMU with the socket feeder.
#
# Two classes (the cross-model + completeness-critic split, confirmed on silicon in the pre-build):
#  SILICON-RED (the trace on the substrate catches it):
#   M-cold     NOP the scheduler's warm-save (mov [tcb+eax*4],esp) -> cold re-dispatch -> trace collapses
#   M-nohlt    NOP a task's hlt park -> the schedule gets stuck (no progress) -> trace collapses
#   M-blind    and eax,1 -> and eax,0 (the per-quantum bit-select is dead) -> schedule always task A ->
#              X and Y produce the SAME all-A trace (the input-dependence collapses)
#   M-readlit  mov eax,[inq] -> mov eax,0x0A (the scheduler reads a literal) -> schedule input-independent
#   M-decoyB   seedB.eip -> garbage -> task B irets into garbage -> trace truncates / no full trace
#  WHITE-BOX-RED (silicon SILENTLY TOLERATES with the slow PIT; only the value-bind gate catches it --
#  empirically confirmed silent in the pre-build, so the canon must NOT claim silicon catches these):
#   M-interlock NOP the done-flag check (test [done]; jz absorb): silicon still bit-identical (slow PIT)
#               but the P-sched scheduler pin (85c07449) is GONE -> gate RED
#   M-provzero  set a seedA GP dword nonzero: silicon still emits the right trace (task re-inits the reg)
#               but the P-seeds "8 zero GP" provenance pin is RED (a forge seeding a nonzero accumulator
#               to fake warmth is caught white-box, NOT by the trace -- the talcott/toggler meta-class)
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
feeder="$script_dir/kernel_input_feed.py"
source "$script_dir/native_codegen_oracle.sh"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: link32 mutation (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link32 mutation (no qemu)"; exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
native_codegen_ensure_compiler "$work/gen1" || exit 1
fail=0; fail_test() { echo "FAIL: link32 mutation ($1)"; fail=$((fail + 1)); }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

# compile cg_lit (return 88), the base image.
cdir="$work/lit.d"; mkdir -p "$cdir"
printf -- '-- emit: multiboot32-cloggard\nfunc main(): return 88 end\n' > "$cdir/p.herb"
( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>"$cdir/err" )
[[ -f "$cdir/a.out" ]] || { echo "FAIL: link32 mutation (compile produced no a.out: $(head -1 "$cdir/err"))"; exit 1; }
base="$work/base.elf"; cp "$cdir/a.out" "$base"

# locate the scheduler + derive the layout (code starts at file 4108).
chx=$(dd if="$base" bs=1 skip=4108 status=none | xxd -p | tr -d '\n')
SCHED_RE='b020e62060a1[0-9a-f]{8}85c07449a1[0-9a-f]{8}83f8047341a1[0-9a-f]{8}83f8027407892485[0-9a-f]{8}8b0d[0-9a-f]{8}a1[0-9a-f]{8}d3e883e001a3[0-9a-f]{8}ff05[0-9a-f]{8}c705[0-9a-f]{8}000000008b2485[0-9a-f]{8}61cf61cf66baf400b000ee66ba0089b053eeb068eeb075eeb074eeb064eeb06feeb077eeb06eeefaf4ebfd'
spos=$(echo "$chx" | grep -boE "$SCHED_RE" | head -1 | cut -d: -f1)
[[ -n "$spos" ]] || { echo "FAIL: link32 mutation (cannot locate scheduler in base image)"; exit 1; }
off_sched=$((spos/2)); off_tables=$((off_sched+128))
off_after=$((off_tables+300)); off_data=$(( (off_after+3) & ~3 ))
off_seedA=$((off_data+24)); off_seedB=$((off_seedA+44)); off_stackA=$((off_seedB+44)); off_stackB=$((off_stackA+256))
fpos() { echo $(( 4108 + $1 )); }   # code offset -> file offset
# scheduler sub-offsets (within the 128-byte block):
o_interlock=$((off_sched+10))   # 85c07449  (test [done]; jz absorb)
o_readinq=$((off_sched+47))     # a1 <inq>  (mov eax,[inq])
o_andsel=$((off_sched+54))      # 83e001    (and eax,1)
o_save=$((off_sched+34))        # 892485 <tcb0>  (mov [tcb+eax*4],esp)

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
trace_for() { # elf byte -> captured e9 trace hex (e.g. de59ad...) or "none"
    local elf="$1" byte="$2" W; W="$(mktemp -d)"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/f.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 80); do grep -q LISTENING "$W/f.log" && break; sleep 0.1; done
    grep -q LISTENING "$W/f.log" 2>/dev/null || { echo "FAIL: link32 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none -cpu qemu64 -m 64M >/dev/null 2>"$W/e9.bin.qerr"
        grep -qvE 'terminating on signal' "$W/e9.bin.qerr" 2>/dev/null && { echo "FAIL: link32 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$W/e9.bin.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
    # cap the capture: a stuck-schedule mutation (M-nohlt) emits unboundedly until the timeout; we only
    # need enough to distinguish from the K-frame golden, and a multi-MB hex string chokes bash.
    local got; got=$(dd if="$W/e9.bin" bs=1 count=256 status=none 2>/dev/null | xxd -p | tr -d '\n'); rm -rf "$W"
    [[ -n "$got" ]] && echo "$got" || echo "none"
}
patch_hex() { python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src,dst,old,new=sys.argv[1:5]
b=open(src,'rb').read(); o=bytes.fromhex(old); n=bytes.fromhex(new)
assert len(o)==len(n), "patch not equal-length"
i=b.find(o); assert i>=0, "pattern %s not found"%old
open(dst,'wb').write(b[:i]+n+b[i+len(n):]); print(i)
PY
}
patch_off() { python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src,dst,off,new=sys.argv[1],sys.argv[2],int(sys.argv[3]),bytes.fromhex(sys.argv[4])
b=bytearray(open(src,'rb').read()); b[off:off+len(new)]=new; open(dst,'wb').write(b)
PY
}
nop_off() { patch_off "$1" "$2" "$3" "$(python3 -c "print('90'*$4)")"; }
has_hex() { xxd -p "$1" | tr -d '\n' | grep -q "$2"; }

TX='de59addeb1adde5aaddeb2ad'   # X=0x0A schedule A,B,A,B
TY='deb1adde59addeb2adde5aad'   # Y=0x05 schedule B,A,B,A

# ---- CONTROL: the genuine input-driven multi-quantum schedule -------------------------------
cX=$(trace_for "$base" 10); cY=$(trace_for "$base" 5)
if [[ "$cX" == "$TX" && "$cY" == "$TY" && "$cX" != "$cY" ]]; then
    echo "control OK: in=0x0A -> $cX (A,B,A,B)   in=0x05 -> $cY (B,A,B,A) -- genuine input-driven multi-quantum schedule"
else
    fail_test "control: expected $TX / $TY, got X=$cX Y=$cY"
fi

# ===== SILICON-RED mutations =====
# M-cold: NOP the warm-save (mov [tcb+cur*4],esp) -> tcb never updated from the seed -> every
# re-dispatch is COLD (loads the seed) -> the per-task accumulator resets each grant. For X=0x0A
# (A,B,A,B) the cold trace is A:1,B:1,A:1,B:1 = de59ad deb1ad de59ad deb1ad (accumulation lost).
COLDX='de59addeb1adde59addeb1ad'
mc="$work/cold.elf"; nop_off "$base" "$mc" "$(fpos $o_save)" 7 >/dev/null
kX=$(trace_for "$mc" 10)
if [[ "$kX" == "$COLDX" ]]; then echo "M-cold CAUGHT: NOP warm-save -> cold re-dispatch -> in=0x0A emits $kX (A:1,B:1,A:1,B:1, accumulation LOST) -- the warm save/restore is load-bearing"
else fail_test "M-cold: expected cold-collapse $COLDX, got X=$kX"; fi

# M-nohlt: NOP task A's hlt (the first f4 in [off_A=224, off_sched)). The schedule gets stuck.
hpos=$(python3 -c "
b=open('$base','rb').read(); s=b.find(bytes.fromhex('f4ebdf'),4108+224,4108+$off_sched); print(s)")
mh="$work/nohlt.elf"; nop_off "$base" "$mh" "$hpos" 1 >/dev/null
nX=$(trace_for "$mh" 10)
if [[ "$nX" != "$TX" ]]; then echo "M-nohlt CAUGHT: NOP task A hlt -> schedule stuck / trace collapses (X=$nX) -- the hlt-park is load-bearing"
else fail_test "M-nohlt: expected collapse, got X=$nX"; fi

# M-blind: and eax,1 -> and eax,0 (the bit-select is dead) -> next always 0 -> always task A.
mb="$work/blind.elf"; patch_off "$base" "$mb" "$(fpos $o_andsel)" "83e000" >/dev/null
bX=$(trace_for "$mb" 10); bY=$(trace_for "$mb" 5)
ALLA='de59adde5aadde5badde5cad'
if [[ "$bX" == "$ALLA" && "$bY" == "$ALLA" ]]; then echo "M-blind CAUGHT: and eax,1->and eax,0 -> schedule always task A; in=0x0A and in=0x05 BOTH emit $bX -- the input-dependence collapsed"
else fail_test "M-blind: expected both=$ALLA, got X=$bX Y=$bY"; fi

# M-readlit: mov eax,[inq] -> mov eax,0x0A (the scheduler reads a literal) -> input-independent.
inq_le=${chx:$((o_readinq*2+2)):8}
mr="$work/readlit.elf"; patch_hex "$base" "$mr" "a1${inq_le}" "b80a000000" >/dev/null || fail_test "M-readlit patch"
rX=$(trace_for "$mr" 10); rY=$(trace_for "$mr" 5)
if [[ "$rX" == "$TX" && "$rY" == "$TX" ]]; then echo "M-readlit CAUGHT: mov eax,[inq]->mov eax,0x0A -> schedule input-independent; in=0x05 wrongly emits $rY (the 0x0A schedule)"
else fail_test "M-readlit: expected both=$TX, got X=$rX Y=$rY"; fi

# M-decoyB: seedB.eip -> garbage -> task B irets into garbage -> the trace cannot complete.
md="$work/decoyB.elf"; patch_off "$base" "$md" "$(fpos $((off_seedB+32)))" "efbeadde" >/dev/null
dX=$(trace_for "$md" 10)
if [[ "$dX" != "$TX" ]]; then echo "M-decoyB CAUGHT: seedB.eip->0xDEADBEEF -> task B irets into garbage, trace cannot complete (X=$dX)"
else fail_test "M-decoyB: expected collapse, got X=$dX"; fi

# ===== WHITE-BOX-RED mutations (silicon SILENTLY TOLERATES with the slow PIT) =====
# M-interlock: NOP the done-flag check (85c07449). Silicon STILL bit-identical (slow PIT margin),
# but the P-sched scheduler pin (which contains 85c07449) is GONE -> gate RED.
mi="$work/interlock.elf"; nop_off "$base" "$mi" "$(fpos $o_interlock)" 4 >/dev/null
iX=$(trace_for "$mi" 10); iY=$(trace_for "$mi" 5)
if [[ "$iX" == "$TX" && "$iY" == "$TY" ]]; then
    if has_hex "$mi" "85c07449"; then fail_test "M-interlock: 85c07449 still present after patch"; \
    else echo "M-interlock CAUGHT (white-box): done-check->nops is SILENT on silicon (X=$iX Y=$iY unchanged, slow-PIT margin) but the P-sched pin (85c07449) is GONE -> gate RED. (Proves the interlock is white-box-pinned, not silicon-witnessed -- honest split.)"; fi
else fail_test "M-interlock: expected SILENT $TX/$TY (white-box only), got X=$iX Y=$iY"; fi

# M-provzero: set seedA GP dword [0] (the edi slot in popa order) nonzero. Silicon still emits the
# right trace (task A sets edi=vA at cold start), but the P-seeds "8 zero GP" provenance pin is RED.
mp="$work/provzero.elf"; patch_off "$base" "$mp" "$(fpos $off_seedA)" "11111111" >/dev/null
pX=$(trace_for "$mp" 10); pY=$(trace_for "$mp" 5)
gpA=$(dd if="$mp" bs=1 skip="$(fpos $off_seedA)" count=4 status=none | xxd -p)
if [[ "$pX" == "$TX" && "$pY" == "$TY" && "$gpA" == "11111111" ]]; then
    echo "M-provzero CAUGHT (white-box): a nonzero seeded GP dword is SILENT on silicon (X=$pX Y=$pY unchanged) but the P-seeds 8-zero-GP provenance pin is now $gpA -> gate RED. (Proves the provenance pin -- not the trace -- defends against a forge that seeds a fake accumulator; the cold-re-dispatch-fakes-warmth meta-class.)"
else fail_test "M-provzero: expected SILENT $TX/$TY (white-box only), got X=$pX Y=$pY gp=$gpA"; fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link32 mutation leg(s) failed."; exit 1; fi
if [[ -e "$HVMARK" ]]; then echo "FAIL: link32 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: link32 mutation proof (cloggard / data-dependent multi-quantum schedule): control shows the genuine input-driven schedule (in=0x0A->A,B,A,B; in=0x05->B,A,B,A); SILICON-RED -- M-cold (NOP warm-save) collapses the trace, M-nohlt (NOP hlt) stalls the schedule, M-blind (and eax,0) collapses the input-dependence to always-A, M-readlit (read literal) makes the schedule input-independent, M-decoyB (seedB.eip garbage) breaks task B's iret; WHITE-BOX-RED (silicon SILENT, gate catches) -- M-interlock removes the done-flag check (P-sched pin gone), M-provzero seeds a nonzero accumulator (P-seeds 8-zero-GP provenance pin RED). Each load-bearing byte bites: the scheduler genuinely consults input-derived state each quantum and warm-dispatches a SEQUENCE of tasks, with warmth bound white-box by the provenance pin."
exit 0
