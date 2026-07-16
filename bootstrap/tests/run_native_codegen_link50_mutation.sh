#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link50 / tessera (SHARED MEMORY via a non-identity aliased frame). Each
# mutation perturbs ONE alias-install choice in tessera_ref.build_code(mut=...) and proves it non-vacuous: the control
# kernel grades GREEN (the consumer reads the producer's late-bound words through the shared frame), every mutant grades
# RED AND fails the white-box assert_tessera.
# Mutations:
#   M-noinstall   skip the alias install entirely -> Va,Vb stay identity+Supervisor -> the producer #PFs writing the
#                 shared window and the consumer #PFs reading it -> the words never appear.
#   M-identity    install Va->Va and Vb->Vb (still User): the windows are ACCESSIBLE but the frames are DISJOINT -- the
#                 consumer reads its OWN window, never the producer's. THE KEY mutation (the homestead-M-eager analogue):
#                 it proves the NON-IDENTITY ALIASING, not the User permission, is the load-bearing observable.
#   M-onlyone     alias only Va->F; leave Vb->Vb identity -> the consumer reads a disjoint frame -> never the payload.
#   M-supervisor  alias both Va,Vb -> F but WITHOUT the User bit (|3) -> a CPL3 access to the shared window #PFs.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/tessera_ref.py"
K=2; SEED="${TESSERA_SEED:-90}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
PROD="$work/prod.bin"; CONS="$work/cons.bin"
python3 "$REF" modproducer "$PROD"; python3 "$REF" modconsumer "$CONS"
qrun() { # kernel out timeout
    local kel="$1" out="$2" to="$3"; local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$SEED" --delay 1 --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    grep -q LISTENING "$work/feed.log" 2>/dev/null || { echo "FAIL: link50 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout "$to" qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$PROD,$CONS" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link50 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
gg() { python3 "$REF" gradetess "$1" "$2" "$K" "$SEED" >/dev/null 2>&1; }   # GREEN?

# ---- CONTROL: genuine kernel must be GREEN AND pass assert_tessera (proves the harness bites) ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" kernelelf "$CK" none full)"
qrun "$CK" "$work/c" 40
if gg "$work/c" "$CKEND" && python3 "$REF" tessera "$CK"; then ok "control (genuine) GREEN -- consumer reads the producer's late-bound words through the shared frame + assert_tessera TRUE"
else fail_test "control kernel is NOT green -- the mutation harness does not bite"; fi

# ---- each mutation: RED AND assert_tessera FALSE ----
# mut | timeout | description  (identity/onlyone leave the windows accessible-but-disjoint -> the consumer spins to the
# timeout; noinstall/supervisor #PF and die fast)
muts=( "noinstall:20:no alias install -> shared window identity+Supervisor -> #PF"
       "identity:20:install identity (Va->Va,Vb->Vb User) -> accessible but DISJOINT -> consumer sees nothing (THE KEY: aliasing, not permission)"
       "onlyone:20:alias only Va -> Vb identity-disjoint -> consumer never sees the payload"
       "supervisor:20:alias both to F but Supervisor -> CPL3 #PF on the shared window" )
for spec in "${muts[@]}"; do
    m="${spec%%:*}"; rest="${spec#*:}"; to="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" kernelelf "$MK" "$m" full)"
    if python3 "$REF" tessera "$MK" 2>/dev/null; then fail_test "M-$m: assert_tessera TRUE (mutant kept the non-identity alias motif?)"; continue; fi
    qrun "$MK" "$work/$m.o" "$to"
    if gg "$work/$m.o" "$MKEND"; then fail_test "M-$m GREEN (vacuous: $desc)"; else ok "M-$m RED + assert_tessera False ($desc)"; fi
done

echo "native-codegen link50 tessera MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link50 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link50 tessera MUTATION proof -- control GREEN; M-noinstall/identity/onlyone/supervisor each RED + assert_tessera False; M-identity the KEY: the shared window is accessible (User) but the frames are DISJOINT, so the consumer reads its own window and never the producer's payload -- proving the NON-IDENTITY ALIASING, not the User permission, is the load-bearing observable, the homestead-M-eager analogue)"
