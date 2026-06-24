#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link49 / furlough (BLOCKING SYS_READ block/wake). Each mutation perturbs
# ONE block/wake choice in furlough_ref.build_code(mut=...) and proves it non-vacuous: the control kernel grades GREEN,
# every mutant grades RED on the appropriate run AND fails the white-box assert_furlough. Two graded runs:
#   RUN-2 (byte delivered): the reader must be WOKEN with the correct byte (wake witness, byte-correct, parked-not-spinning).
#   RUN-1 (byte withheld):  peers must still run (the freeze is fixed).
# Mutations:
#   M-noblock     revert do_read to the FROZEN IF=0 busy-poll -> a naive reader freezes the machine -> RUN-1 peers ABSENT.
#   M-noblockflag the block arm snapshots the frame but does NOT set blocked[cur] -> the reader stays runnable, resumes
#                 after int 0x30 with a STALE t_eax -> RUN-2 wrong byte (and never truly parked).
#   M-restart     deschedule WITHOUT a blocked state AND rewind eip to re-execute int 0x30 (the runnable-retry forge):
#                 it FIXES the freeze (RUN-1 GREEN) but re-dispatches the reader every cycle (disp >> bound) with NO wake
#                 witness -> RUN-2 RED. THE KEY mutation: the freeze-fix alone is under-determined; only correct wake +
#                 parked-not-spinning is block/wake.
#   M-noskipblk   INVERT the pick's blocked-skip (jne->je) -> the scheduler picks a PARKED proc -> wedges -> RED.
#   M-nowake      the wake arm reads+witnesses but never clears blocked[w] -> the reader never resumes -> RUN-2 absent.
#   M-nodeliver   the wake arm clears blocked but never stores the byte into t_eax[w] -> the reader resumes with a stale
#                 (garbage) byte -> RUN-2 wrong output (byte-correctness).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/furlough_ref.py"
K=3; FBYTE="${FURLOUGH_FBYTE:-90}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
A="$work/A.bin"; B="$work/B.bin"; C="$work/C.bin"
python3 "$REF" modreader "$A"; python3 "$REF" modpeer "$B" "$K" 1; python3 "$REF" modpeer "$C" "$K" 2
qrun() { # kernel out delay timeout
    local kel="$1" out="$2" delay="$3" to="$4"; local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$FBYTE" --delay "$delay" --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    timeout "$to" qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$A,$B,$C" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
g2() { python3 "$REF" gradefurl "$1" "$2" "$K" run2 "$FBYTE" >/dev/null 2>&1; }   # RUN-2 GREEN?
g1() { python3 "$REF" gradefurl "$1" "$2" "$K" run1 "$FBYTE" >/dev/null 2>&1; }   # RUN-1 GREEN?

# ---- CONTROL: genuine kernel must be GREEN on both runs (proves the harness bites) ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" kernelelf "$CK" none full)"
qrun "$CK" "$work/c2" 1 25; qrun "$CK" "$work/c1" 60 12
if g2 "$work/c2" "$CKEND" && g1 "$work/c1" "$CKEND" && python3 "$REF" furlough "$CK"; then ok "control (genuine) GREEN on RUN-2 + RUN-1 + assert_furlough TRUE"
else fail_test "control kernel is NOT green -- the mutation harness does not bite"; fi

# ---- each mutation: RED on the relevant run AND assert_furlough FALSE ----
# mut | which run must go RED ("run1"|"run2") | description
muts=( "noblock:run1:revert to IF=0 busy-poll -> freeze -> peers absent"
       "noblockflag:run2:deschedule but stay runnable -> reader resumes with stale byte"
       "restart:run2:runnable-retry (re-exec int 0x30) -> re-dispatched every cycle, no wake (the KEY forge)"
       "noskipblk:run2:pick picks a PARKED proc -> wedges"
       "nowake:run2:never unblock the reader -> never resumes"
       "nodeliver:run2:never deliver the byte -> reader resumes with garbage" )
for spec in "${muts[@]}"; do
    m="${spec%%:*}"; rest="${spec#*:}"; redrun="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" kernelelf "$MK" "$m" full)"
    # assert must be FALSE (the mutant lacks the structural motif)
    if python3 "$REF" furlough "$MK" 2>/dev/null; then fail_test "M-$m: assert_furlough TRUE (mutant kept the motif?)"; continue; fi
    if [[ "$redrun" == run1 ]]; then
        qrun "$MK" "$work/$m.o" 60 12
        if g1 "$work/$m.o" "$MKEND"; then fail_test "M-$m GREEN on RUN-1 (vacuous: $desc)"; else ok "M-$m RED on RUN-1 + assert False ($desc)"; fi
    else
        qrun "$MK" "$work/$m.o" 1 25
        if g2 "$work/$m.o" "$MKEND"; then fail_test "M-$m GREEN on RUN-2 (vacuous: $desc)"; else ok "M-$m RED on RUN-2 + assert False ($desc)"; fi
    fi
done

echo "native-codegen link49 furlough MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link49 furlough MUTATION proof -- control GREEN; M-noblock/noblockflag/restart/noskipblk/nowake/nodeliver each RED + assert_furlough False; M-restart the KEY: fixes the freeze (RUN-1) but caught by RUN-2 -- the freeze-fix is under-determined, correct wake+delivery+parked-not-spinning is what block/wake forces)"
