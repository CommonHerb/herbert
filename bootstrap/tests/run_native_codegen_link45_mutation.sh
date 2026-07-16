#!/usr/bin/env bash
# Native-codegen Link 45 / tickover -- HELD-BACK MUTATION PROOF. Each mutant KERNEL is built from tickover_ref.py
# (negative controls, NOT the compiler, which only emits the correct preemptive kernel), runs on real silicon, but
# is BROKEN so the grade must go RED -- proving every design choice of the timer-preemption make-or-break is
# load-bearing, not vacuous. Requires QEMU (set KERNEL_CODEGEN_REQUIRE_EMU=1 to force).
#
#   M-coop     : iret-into-module frames use IF=0 (eflags 0x002) -- the timer can't preempt a CPL3 module, so the
#                non-yielding spinner A runs FOREVER and the worker B never runs (STARVES) -> hang/RED. Proves IF=1
#                preemptibility is load-bearing. (NOTE: NOT "don't arm the PIT" -- that is VACUOUS, the 8254
#                free-runs ~18.2Hz from BIOS regardless; only IF=0 / IRQ0-mask actually stops preemption.)
#   M-noswitch : the vec-0x20 handler EOIs+irets WITHOUT a context switch -- A keeps running, B STARVES -> RED.
#                Proves the preemptive context switch in the handler is load-bearing.
#   M-minimal  : the handler saves only the tandem cooperative TCB {eip,esp,ebp} -- A's edx (and DF) are LOST across
#                the preempt, so A emits 0/sentinel != le32(VA) -> RED. Proves the WIDENED full-GP TCB is load-bearing.
#   M-noeflags : the handler saves the full GP set but NOT eflags -- A's DF (set before the spin) is LOST, so A emits
#                the sentinel != le32(VA) -> RED. Proves saving eflags is load-bearing (beyond the GP set).
#   M-noflip   : the kernel flips BOTH programs' pages User at boot (no per-program isolation) -- the hostile-peer
#                write into B's region SUCCEEDS (no #PF) -> the hostile grade goes RED. Proves the PTE-flip isolation.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
REF="$script_dir/tickover_ref.py"; feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail+1)); }
have_qemu(){ command -v qemu-system-x86_64 >/dev/null 2>&1; }
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

python3 "$REF" modA "$work/A.bin"
python3 "$REF" modB "$work/B.bin"
python3 "$REF" modhostile "$work/H.bin"
KEND="$(python3 "$REF" kernelelf "$work/k.elf" none full)"
python3 "$REF" kernelelf "$work/k_coop.elf" coop     full >/dev/null
python3 "$REF" kernelelf "$work/k_nsw.elf"  noswitch full >/dev/null
python3 "$REF" kernelelf "$work/k_min.elf"  minimal  full >/dev/null
python3 "$REF" kernelelf "$work/k_nef.elf"  noeflags full >/dev/null
python3 "$REF" kernelelf "$work/k_nf.elf"   noflip   full >/dev/null

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then bad "QEMU required but not found"; exit 1; fi
    echo "  SKIP: qemu not found (mutation proof needs silicon)"; echo "mutation: pass=$pass fail=$fail"; exit 0
fi

feed_run(){ # kelf kind out [timeout]
    local kelf="$1" kind="$2" out="$3" to="${4:-120}"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" $stream --hold 12 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$d/feed.log" 2>/dev/null || { echo "FAIL: link45 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout "$to" qemu-system-x86_64 -kernel "$kelf" -initrd "$work/A.bin,$work/B.bin" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link45 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
}
host_run(){ # kelf hostileA out
    timeout 60 qemu-system-x86_64 -kernel "$1" -initrd "$2,$work/B.bin" -debugcon file:"$3" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -monitor none -m 64M >/dev/null 2>"$3.qerr"
        grep -qvE 'terminating on signal' "$3.qerr" 2>/dev/null && { echo "FAIL: link45 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$3.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
}

# control: genuine kernel + genuine probes is GREEN (the mutations are the only RED)
feed_run "$work/k.elf" gx "$work/ctl.out"
if python3 "$REF" grade "$work/ctl.out" "$KEND" gx >/dev/null 2>&1; then ok "control: the genuine preemptive kernel runs GREEN (A survives + B not starved)"
else bad "control: genuine preemptive run is RED (harness broken) -- $(python3 "$REF" grade "$work/ctl.out" "$KEND" gx 2>&1 | sed -n 2p)"; fi

# M-coop: B starves (A spins forever with IF=0) -> RED (short timeout: the mutant hangs, that IS the starvation)
feed_run "$work/k_coop.elf" gx "$work/coop.out" 14
if python3 "$REF" grade "$work/coop.out" "$KEND" gx >/dev/null 2>&1; then bad "M-coop graded GREEN (IF=1 preemptibility is NOT load-bearing)"
else ok "M-coop is RED ($(python3 "$REF" grade "$work/coop.out" "$KEND" gx 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi

# M-noswitch: handler never switches -> A keeps running, B starves -> RED
feed_run "$work/k_nsw.elf" gx "$work/nsw.out" 14
if python3 "$REF" grade "$work/nsw.out" "$KEND" gx >/dev/null 2>&1; then bad "M-noswitch graded GREEN (the preemptive switch is NOT load-bearing)"
else ok "M-noswitch is RED ($(python3 "$REF" grade "$work/nsw.out" "$KEND" gx 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi

# M-minimal: minimal {eip,esp,ebp} TCB -> A's edx lost -> RED
feed_run "$work/k_min.elf" gx "$work/min.out"
if python3 "$REF" grade "$work/min.out" "$KEND" gx >/dev/null 2>&1; then bad "M-minimal graded GREEN (the widened full-GP TCB is NOT load-bearing)"
else ok "M-minimal is RED ($(python3 "$REF" grade "$work/min.out" "$KEND" gx 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi

# M-noeflags: GP saved but eflags dropped -> A's DF lost -> RED
feed_run "$work/k_nef.elf" gx "$work/nef.out"
if python3 "$REF" grade "$work/nef.out" "$KEND" gx >/dev/null 2>&1; then bad "M-noeflags graded GREEN (saving eflags is NOT load-bearing)"
else ok "M-noeflags is RED ($(python3 "$REF" grade "$work/nef.out" "$KEND" gx 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi

# M-noflip: the hostile-peer probe must be RED (no #PF -- B's pages are User)
host_run "$work/k_nf.elf" "$work/H.bin" "$work/nf.out"
if python3 "$REF" gradehostile "$work/nf.out" "$KEND" write >/dev/null 2>&1; then bad "M-noflip hostile graded GREEN (the per-program PTE-flip is NOT load-bearing -- no isolation)"
else ok "M-noflip hostile is RED ($(python3 "$REF" gradehostile "$work/nf.out" "$KEND" write 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi
# control for noflip: the genuine kernel + hostile probe must still #PF GREEN
host_run "$work/k.elf" "$work/H.bin" "$work/nf_ctl.out"
if python3 "$REF" gradehostile "$work/nf_ctl.out" "$KEND" write >/dev/null 2>&1; then ok "control: hostile-peer #PF fires on the genuine kernel (M-noflip is specific)"
else bad "control: hostile-peer #PF did NOT fire on the genuine kernel (harness broken)"; fi

echo "mutation: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link45 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link45 tickover mutation proof)"
