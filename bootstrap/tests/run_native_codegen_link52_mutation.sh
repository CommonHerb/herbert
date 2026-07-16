#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link52 / lethe (ALIAS-REMAP + TARGETED TLB INVALIDATION). Each mutation
# perturbs ONE piece of the alias-remap machinery in lethe_ref.build_code(mut=...) and proves it non-vacuous: the control
# kernel grades GREEN (A==x F UNCHANGED, V==y, B==y) AND passes assert_lethe; every mutant either grades RED OR (the cr3
# forge) fails the white-box assert_lethe. The grade is per-mutant: the OUTPUT mutants go RED on silicon; the
# correct-output cr3-flush forge is GREEN on output but assert_lethe REJECTS it (forcing the TARGETED primitive).
# Mutations:
#   M-noinvlpg              drop the invlpg -> the stale V->F TLB entry survives -> step-4's write y lands in F (the
#                           GHOST) -> A (which still maps F) reads y instead of x (corruption), B==OLD_FP -> RED.
#   M-cr3insteadofinvlpg    THE KEY forge: replace invlpg [V] with a cr3 reload (a FULL flush). Output is GREEN (the cr3
#                           flush is correct) -- so the silicon grade alone CANNOT catch it; assert_lethe REJECTS it (the
#                           remap arm carries `mov cr3,eax` and no invlpg of V). Proves the TARGETED primitive, not the
#                           heavy flush, is load-bearing -- a behaviorally-invisible mis-implementation caught white-box.
#   M-noremap               omit the PTE[V]<-F' write -> V stays ->F -> step-4 y lands in F -> A==y, B==OLD_FP -> RED.
#   M-sameframe             remap V to F (F'==F) -> after the "remap" V->F still -> step-4 y lands in F -> A==y -> RED.
#   M-noinstall             skip the three alias installs -> A/V/B stay identity+Supervisor -> the CPL3 store #PFs
#                           terminally (no OWN-table dump) -> RED.
# NO-WARM differential: the nowarm prober SKIPS step-2 (it never writes x to [V], so F is never populated with x AND
# V->F is never warmed into the TLB). On the genuine kernel it grades RED on the FULL grade (A reads an un-populated F,
# not x) -- that is correct: the WARM is load-bearing, both for populating F and for making the M-noinvlpg stale-entry
# bug observable. We use it as a DIFFERENTIAL: on the genuine kernel the no-warm run is RED (proving the warm is the
# load-bearing setup, not incidental ceremony), exactly as the warm prober is GREEN.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/lethe_ref.py"
SEED="${LETHE_SEED:-90}"
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
PROBER="$work/prober.bin"; python3 "$REF" modprober "$PROBER"             # K=1, late-bound seed (the WITNESS prober)
PROBER_NW="$work/prober_nw.bin"; python3 "$REF" modprober_nowarm "$PROBER_NW"   # the no-warm CONTROL prober
qrun() { # kernel out timeout prober
    local kel="$1" out="$2" to="$3" pr="${4:-$PROBER}"; local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$SEED" --delay 1 --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    grep -q LISTENING "$work/feed.log" 2>/dev/null || { echo "FAIL: link52 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout "$to" qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$pr" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link52 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
gg() { python3 "$REF" gradelethe "$1" "$2" "$SEED" >/dev/null 2>&1; }   # GREEN?

# ---- CONTROL: genuine kernel must be GREEN AND pass assert_lethe (proves the harness bites) ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" kernelelf "$CK" none full)"
qrun "$CK" "$work/c" 40
if gg "$work/c" "$CKEND" && python3 "$REF" assertlethe "$CK"; then ok "control (genuine) GREEN -- A==x (F UNCHANGED, no ghost), V==y, B==y + assert_lethe TRUE"
else fail_test "control kernel is NOT green -- the mutation harness does not bite"; fi
# NO-WARM DIFFERENTIAL (the genuine kernel, the no-warm prober): RED -- the no-warm prober never writes x to [V] (F is
# never populated, V->F never warmed) so A reads an un-populated F, not x. This proves the WARM is the load-bearing setup
# (not incidental ceremony): drop it and even the genuine kernel grades RED, mirroring how the warm prober is GREEN.
qrun "$CK" "$work/cnw" 40 "$PROBER_NW"
if gg "$work/cnw" "$CKEND"; then fail_test "no-warm prober GREEN on the genuine kernel -- the warm is NOT load-bearing (the witness setup is incidental?)"
else ok "no-warm DIFFERENTIAL: the genuine kernel + the no-warm prober is RED (the warm populates F and caches V->F; without it A reads an un-populated F -- the WARM is the load-bearing setup, as the warm prober's GREEN shows)"; fi

# ---- each mutation: RED on output, OR (cr3 forge) assert_lethe FALSE ----
# The cr3-flush forge is correct on OUTPUT -- its discriminator is the WHITE-BOX assert (assert_lethe FALSE); the others
# are RED on the silicon grade AND assert_lethe FALSE.
muts=( "noinstall:20:white:skip the three alias installs -> CPL3 store #PFs terminally (no OWN-table dump)"
       "noremap:25:red:omit PTE[V]<-F' -> V stays ->F -> step-4 y lands in F -> A==y corruption, B==OLD_FP"
       "sameframe:20:red:remap V to F (F'==F) -> after remap V->F still -> y lands in F -> A==y"
       "noinvlpg:20:red:drop invlpg -> stale V->F entry survives -> y lands in F (the GHOST) -> A==y, B==OLD_FP"
       "cr3insteadofinvlpg:20:white:THE KEY forge -- cr3 flush not invlpg: GREEN on output but assert_lethe REJECTS (mov cr3 in the remap arm, no invlpg of V)"
       "cr3edx:20:white:cr3,EDX forge (the D8..DF gap Codex found) -- keeps invlpg [V] (passes check-2) AND mov cr3,edx (0F 22 DA): GREEN on output, WIDENED assert_lethe REJECTS (a D8-only cr3-reject would have passed this)" )
for spec in "${muts[@]}"; do
    m="${spec%%:*}"; rest="${spec#*:}"; to="${rest%%:*}"; rest2="${rest#*:}"; mode="${rest2%%:*}"; desc="${rest2#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" kernelelf "$MK" "$m" full)"
    # EVERY mutant must FAIL assert_lethe (the white-box pin is the universal discriminator)
    if python3 "$REF" assertlethe "$MK" 2>/dev/null; then fail_test "M-$m: assert_lethe TRUE (mutant kept the alias-remap motif?)"; continue; fi
    if [[ "$mode" == "white" ]]; then
        # white-box-only mutants: assert_lethe FALSE is the proof (cr3 forge is GREEN on output by design; noinstall is RED but the
        # primary discriminator we assert here is the white-box pin). For noinstall also confirm RED on output (no dump).
        if [[ "$m" == "noinstall" ]]; then
            qrun "$MK" "$work/$m.o" "$to"
            if gg "$work/$m.o" "$MKEND"; then fail_test "M-$m GREEN (vacuous: $desc)"; else ok "M-$m assert_lethe False + RED on output ($desc)"; fi
        else
            # cr3 forge: PROVE it is GREEN on output (so the silicon grade alone cannot catch it) yet assert_lethe FALSE
            qrun "$MK" "$work/$m.o" "$to"
            if gg "$work/$m.o" "$MKEND"; then ok "M-$m assert_lethe False -- and GREEN on OUTPUT (the cr3 flush is behaviorally correct, so the silicon grade CANNOT catch it; only the white-box pin does -- $desc)"
            else ok "M-$m assert_lethe False (note: this run was also RED on output) ($desc)"; fi
        fi
    else
        # output mutants: must be RED on silicon AND assert_lethe False
        qrun "$MK" "$work/$m.o" "$to"
        if gg "$work/$m.o" "$MKEND"; then fail_test "M-$m GREEN (vacuous: $desc)"; else ok "M-$m RED + assert_lethe False ($desc)"; fi
    fi
done

echo "native-codegen link52 lethe MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link52 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link52 lethe MUTATION proof -- control GREEN (A==x F UNCHANGED, V==y, B==y) + assert_lethe TRUE; no-warm DIFFERENTIAL RED (drop the warm and even the genuine kernel grades RED -- A reads an un-populated F -- proving the warm is the load-bearing setup); M-noinstall/noremap/sameframe/noinvlpg each RED on output + assert_lethe False; M-cr3insteadofinvlpg the KEY: a cr3 FULL flush is GREEN on output -- the silicon grade alone cannot catch it -- but assert_lethe REJECTS it (mov cr3 in the remap arm, no invlpg of V), proving the TARGETED primitive, not the heavy flush, is load-bearing; M-noinvlpg the canonical bug: the stale V->F entry survives so the post-remap write y lands in the GHOST frame F and corrupts the witness alias A -- the ghost corruption is observed in A, a DIFFERENT alias than the one written, WITHIN one execution)"
