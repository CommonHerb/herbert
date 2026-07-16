#!/usr/bin/env bash
# Native-codegen Link 44 / tandem -- HELD-BACK MUTATION PROOF. Each mutant KERNEL is built from tandem_ref.py
# (negative controls, NOT the compiler, which only emits the correct two-program kernel + modules), runs on real
# silicon, but is BROKEN so the grade must go RED -- proving every design choice of the two-program make-or-break
# is load-bearing, not vacuous. Requires QEMU (set KERNEL_CODEGEN_REQUIRE_EMU=1 to force).
#
#   M-singleslot : the kernel reverts the mods_count gate to ==1. With TWO modules delivered, the check fails ->
#                  the kernel shuts down before running anything -> 0 output -> RED. Proves the mods_count==2 gate
#                  (running TWO loaded programs, not one) is load-bearing.
#   M-noflip     : the kernel flips BOTH programs' pages to User at boot (no per-program isolation). The hostile-peer
#                  write into B's region then SUCCEEDS (no #PF) -> the hostile grade goes RED (no #PF witness).
#                  Proves the per-program User/Supervisor PTE-flip (PEER isolation) is load-bearing.
#   M-noswap     : SYS_YIELD does NOT switch programs (iret back to the same program). A runs to exit before B ever
#                  runs -> no ping-pong -> B writes 0, the interleave is A* not ABAB -> RED. Proves the context
#                  switch (kernel-scheduled interleave + the cross-yield mailbox) is load-bearing.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
REF="$script_dir/tandem_ref.py"; feeder="$script_dir/kernel_input_feed.py"
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
python3 "$REF" kernelelf "$work/k_ss.elf"  singleslot full >/dev/null
python3 "$REF" kernelelf "$work/k_nf.elf"  noflip     full >/dev/null
python3 "$REF" kernelelf "$work/k_nsw.elf" noswap     full >/dev/null

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then bad "QEMU required but not found"; exit 1; fi
    echo "  SKIP: qemu not found (mutation proof needs silicon)"; echo "mutation: pass=$pass fail=$fail"; exit 0
fi

feed_run(){ # kelf modA modB kind out
    local kelf="$1" ma="$2" mb="$3" kind="$4" out="$5"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" $stream --hold 12 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$d/feed.log" 2>/dev/null || { echo "FAIL: link44 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 120 qemu-system-x86_64 -kernel "$kelf" -initrd "$ma,$mb" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link44 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
}
host_run(){ # kelf hostileA modB out
    timeout 60 qemu-system-x86_64 -kernel "$1" -initrd "$2,$3" -debugcon file:"$4" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -monitor none -m 64M >/dev/null 2>"$4.qerr"
        grep -qvE 'terminating on signal' "$4.qerr" 2>/dev/null && { echo "FAIL: link44 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$4.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
}

# control: genuine kernel + genuine modules is GREEN (the mutations are the only RED)
feed_run "$work/k.elf" "$work/A.bin" "$work/B.bin" gx "$work/ctl.out"
if python3 "$REF" grade "$work/ctl.out" "$KEND" gx >/dev/null 2>&1; then ok "control: two programs on the genuine kernel run interleaved GREEN"
else bad "control: genuine two-program run is RED (harness broken) -- $(python3 "$REF" grade "$work/ctl.out" "$KEND" gx 2>&1 | sed -n 2p)"; fi

# M-singleslot: gx must be RED (kernel rejects mods_count==2)
feed_run "$work/k_ss.elf" "$work/A.bin" "$work/B.bin" gx "$work/ss.out"
if python3 "$REF" grade "$work/ss.out" "$KEND" gx >/dev/null 2>&1; then bad "M-singleslot graded GREEN (the mods_count==2 gate is NOT load-bearing)"
else ok "M-singleslot is RED ($(python3 "$REF" grade "$work/ss.out" "$KEND" gx 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi

# M-noflip: the hostile-peer probe must be RED (no #PF -- B's pages are User)
host_run "$work/k_nf.elf" "$work/H.bin" "$work/B.bin" "$work/nf.out"
if python3 "$REF" gradehostile "$work/nf.out" "$KEND" >/dev/null 2>&1; then bad "M-noflip hostile graded GREEN (the per-program PTE-flip is NOT load-bearing -- no isolation)"
else ok "M-noflip hostile is RED ($(python3 "$REF" gradehostile "$work/nf.out" "$KEND" 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi
# control for noflip: the genuine kernel + hostile probe must still #PF GREEN
host_run "$work/k.elf" "$work/H.bin" "$work/B.bin" "$work/nf_ctl.out"
if python3 "$REF" gradehostile "$work/nf_ctl.out" "$KEND" >/dev/null 2>&1; then ok "control: hostile-peer #PF fires on the genuine kernel (M-noflip is specific)"
else bad "control: hostile-peer #PF did NOT fire on the genuine kernel (harness broken)"; fi

# M-noswap: gx must be RED (no ping-pong -> B writes 0, interleave A* not ABAB)
feed_run "$work/k_nsw.elf" "$work/A.bin" "$work/B.bin" gx "$work/nsw.out"
if python3 "$REF" grade "$work/nsw.out" "$KEND" gx >/dev/null 2>&1; then bad "M-noswap graded GREEN (the context switch / interleave is NOT load-bearing)"
else ok "M-noswap is RED ($(python3 "$REF" grade "$work/nsw.out" "$KEND" gx 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi

echo "mutation: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link44 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link44 tandem mutation proof)"
