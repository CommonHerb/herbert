#!/usr/bin/env bash
# Native-codegen Link 43 / mumbani -- HELD-BACK MUTATION PROOF. Each mutant RUNS on real silicon but is BROKEN,
# so the grade must go RED -- proving every design choice of the multi-page make-or-break is load-bearing, not
# vacuous. Mutant artifacts are built from mumbani_ref.py (negative controls), NOT the compiler (which only emits
# the correct 4-page kernel + reverse module). Requires QEMU (set KERNEL_CODEGEN_REQUIRE_EMU=1 to force).
#
#   M-onepage  : the kernel allocates ONE page (npages=1, = the frozen holler shape). The reverse(N=400) descent
#                #PFs mid-way -> 0 output words -> RED. Proves the MULTI-PAGE ALLOCATION is load-bearing.
#   M-flip1    : the kernel allocates 4 pages but User-flips only the TOP PTE (flip_pages=1). The descent runs in
#                page 3 then crosses into an unmapped (Supervisor) lower page -> CPL3 #PF -> RED. Proves the
#                4-PTE USER-MAP (not merely the alloc size) is load-bearing.
#   M-forward  : a forge module that emits each word on the way DOWN (FORWARD order, not reversed). It runs on the
#                real 4-page kernel (it too needs multi-page recursion) but the CONTENT/reversal pin catches the
#                wrong order -> RED; AND it is byte-DIFFERENT from target_module() (the emitter byte-pin catches it).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
REF="$script_dir/mumbani_ref.py"; feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail+1)); }
have_qemu(){ command -v qemu-system-x86_64 >/dev/null 2>&1; }
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

python3 "$REF" module "$work/mod.bin"
python3 "$REF" forge  "$work/forge.bin"
python3 "$REF" kernelelf "$work/k4.elf" > "$work/kend"; KEND=$(cat "$work/kend")
python3 "$REF" kernelelf "$work/k1.elf" onepage > /dev/null
python3 "$REF" kernelelf "$work/kf.elf" flip1   > /dev/null

# byte-pin: the forge is a DIFFERENT module than target_module() (the emitter-layer binding)
python3 "$REF" module "$work/ref.bin"
if cmp -s "$work/forge.bin" "$work/ref.bin"; then bad "M-forward forge is byte-identical to target_module() (byte-pin vacuous)"
else ok "M-forward forge is byte-DIFFERENT from target_module() -- the emitter byte-pin (A) catches it"; fi

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then bad "QEMU required but not found"; exit 1; fi
    echo "  SKIP: qemu not found (byte-pin mutation only)"; echo "mutation: pass=$pass fail=$fail"; [[ $fail -eq 0 ]] || exit 1; exit 0
fi

run(){ # kernel module kind out
    local kelf="$1" mod="$2" kind="$3" out="$4"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" $stream --hold 10 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$d/feed.log" 2>/dev/null || { echo "FAIL: link43 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 120 qemu-system-x86_64 -kernel "$kelf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link43 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
}
expect_red(){ # label kernel module
    local label="$1" kelf="$2" mod="$3"
    run "$kelf" "$mod" gx "$work/$label.out"
    if python3 "$REF" grade "$work/$label.out" "$KEND" gx >/dev/null 2>&1; then bad "$label graded GREEN (mutation vacuous -- the design choice is NOT load-bearing)"
    else ok "$label is RED on silicon ($(python3 "$REF" grade "$work/$label.out" "$KEND" gx 2>&1 | sed -n 2p | sed 's/^ *- //'))"; fi
}
# sanity: the GENUINE module on the GENUINE 4-page kernel is GREEN (the mutations are the only RED)
run "$work/k4.elf" "$work/mod.bin" gx "$work/genuine.out"
if python3 "$REF" grade "$work/genuine.out" "$KEND" gx >/dev/null 2>&1; then ok "control: genuine reverse on the genuine 4-page kernel is GREEN"
else bad "control: genuine reverse on the genuine 4-page kernel is RED (harness broken)"; fi

expect_red M-onepage "$work/k1.elf" "$work/mod.bin"
expect_red M-flip1   "$work/kf.elf" "$work/mod.bin"
expect_red M-forward "$work/k4.elf" "$work/forge.bin"

echo "mutation: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link43 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link43 mumbani mutation proof)"
