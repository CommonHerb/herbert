#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link56 / larder (the first general-purpose DYNAMIC HEAP ALLOCATOR, via
# SYS_ALLOC eax=9 / SYS_FREE eax=10 / SYS_DUMP eax=11). Each mutation perturbs ONE piece of the allocator in
# larder_ref.build_elf(mut=...) and proves it non-vacuous: the CONTROL kernel grades GREEN (the late-bound author-unknown
# alloc/free witness emits the FIRST-FIT golden AND both confused-deputy hostile legs are clean no-ops/rejects AND
# assert_larder passes); every mutant either grades RED on the witness OUTPUT or (the input-validation surface breaks)
# escapes on a hostile leg. Modeled EXACTLY on run_native_codegen_link55_mutation.sh, using the late-bound forcing harness
# (larder_latebound.py) + the ref's assert_larder + a master structural byte-pin (every mutant kernel differs from genuine).
#
# The witness: a LATE-BOUND, AUTHOR-UNKNOWN op stream over COM1 (the seed -> the alloc SIZES + the SENTINELS, chosen AFTER
# freeze; rejection-sampled so the tight pool fills with NO OOM and the big allocs fit ONLY via coalesce -- forcing
# first-fit + split + prev-coalesce + next-coalesce + non-MRU reuse). The kernel emits each returned ptr + the SYS_DUMP
# live readback (ptr + the sentinel read back through that ptr). The hostile legs craft an interior-ptr free / an alloc(0)
# / a sub-4 alloc so a sandbox-break is OBSERVABLE.
#
# Mutations (larder_ref.build_elf(mut=...)):
#   M-bump          pure bump-pointer, no free-list, no reuse -> the offset trace DIVERGES (frees never reclaim, later
#                   allocs land at a fresh cursor / OOM) -> RED on the witness.
#   M-freenoop      SYS_FREE never reclaims -> later allocs OOM where genuine reuses a freed span -> RED on the witness.
#   M-nosplit       alloc the WHOLE chunk (never split the remainder) -> the remainder is lost, later allocs OOM -> RED.
#   M-nocoalesce    free never merges neighbours -> the coalesce-fed allocs (A5/A6) OOM -> RED.
#   M-noprevmerge   free merges only the NEXT neighbour -> A5 (prev-merge-fed) OOMs -> RED.
#   M-nonextmerge   free merges only the PREV neighbour -> A6 (next-merge-fed) OOMs -> RED.
#   M-nosizewrap    drop the size reject (cmp ebx,4 / cmp ebx,[pool_size]) -> the benign witness is still GREEN (its sizes
#                   are all in [4,pool], OUTPUT-INVISIBLE) -- caught by (a) the alloc0 leg (alloc(0) now returns a NONZERO
#                   ptr to a 0-length chunk -> RED) AND the smallalloc leg (size<4 -> a ptr to a sub-sentinel chunk -> RED)
#                   AND (b) assert_larder FALSE (the size-reject branch-targets are gone).
#   M-nointeriorfree match a chunk by RANGE not EXACT base -> the benign witness is still GREEN (it only frees by exact
#                   base, OUTPUT-INVISIBLE) -- caught by (a) the interior leg (an interior-ptr free now frees the CONTAINING
#                   chunk -> the live readback loses it -> RED) AND (b) assert_larder FALSE (the exact-base match is gone).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/larder_ref.py"
LB="$script_dir/larder_latebound.py"
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
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

DRIVER="$work/driver.bin"; python3 "$LB" driver "$DRIVER"          # the GENERIC ring-3 op-interpreter (kernel-agnostic)
DISK="$work/disk.img"; dd if=/dev/zero of="$DISK" bs=1M count=64 status=none

# boot kernel + the generic driver, feeding a COM1 op stream; capture debugcon to $out (TCG).
boot_feed() { # kernel out stream...
    local kel="$1" out="$2"; shift 2
    local port; port="$(free_port)"; local d="$out.d"; rm -rf "$d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$DRIVER" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}

# a witness grade is a STRUCTURAL flake (retry-safe) iff its only error is a missing/truncated trace (the COM1-serial /
# debugcon-flush flake class). Used on the GENUINE arms (control + the genuine arm of each hostile helper).
is_struct_flake() { echo "$1" | grep -qE 'no parseable kernel cell-dump|MAGIC banner not found|truncated|missing 0xE'; }
# a grade shows a REAL DIVERGENCE iff the grader reports a VALUE mismatch (a wrong/escaping emitted value), as opposed to
# a mere missing/truncated trace. These are the deterministic-bite signals (larder_latebound.grade): an emitted ptr or
# sentinel != expected, the magic appearing twice, or more live chunks emitted than golden.
has_real_divergence() { echo "$1" | grep -qE '!= expected|appears MORE THAN ONCE|emitted MORE live chunks'; }
# mutant_verdict: classify a mutant's RED as a DETERMINISTIC bite, not a transient structural flake (link-verify rigor).
#   DIVERGE    = a real value mismatch on some attempt -> a deterministic wrong/escaping trace -> a genuine bite.
#   CONSISTENT = RED on ALL N attempts, never GREEN, never a value mismatch (only missing/truncated trace) -> a
#                deterministic BREAK (the mutant reliably produces no/partial trace, e.g. a deterministic fault).
#   EQUIVALENT = a GREEN appeared on some attempt -> the mutation is behaviorally VACUOUS and the earlier RED was a flake
#                masking it -> NOT a bite (the caller FAILs). Runs the given grade-producing command up to N times.
mutant_verdict() { # cmd...  -> echoes DIVERGE|CONSISTENT|EQUIVALENT
    local n=4 i g
    for i in $(seq 1 "$n"); do
        g="$("$@")"
        echo "$g" | grep -q '^GREEN' && { echo EQUIVALENT; return; }   # a GREEN ever -> vacuous mutant (flake-masked RED)
        has_real_divergence "$g" && { echo DIVERGE; return; }          # a value mismatch -> deterministic bite, accept now
    done
    echo CONSISTENT                                                    # RED every attempt, structural-only -> deterministic break
}
build_kernel() { python3 "$LB" kernel "$1" "$2" >/dev/null; }     # out mut

run_witness() { # kel seed genuine  -> echoes grade
    local kel="$1" seed="$2" genuine="${3:-}"
    local stream; stream="$(python3 "$LB" stream "$seed")"
    local out="$work/w.out" try g
    if [[ "$genuine" == 1 ]]; then
        for try in 1 2 3 4; do boot_feed "$kel" "$out" $stream; g="$(python3 "$LB" grade "$out" "$seed" 2>&1)"; is_struct_flake "$g" || break; done
    else
        boot_feed "$kel" "$out" $stream; g="$(python3 "$LB" grade "$out" "$seed" 2>&1)"
    fi
    echo "$g"
}
run_hostile() { # kel seed leg genuine  -> echoes hostile_grade
    local kel="$1" seed="$2" leg="$3" genuine="${4:-}"
    local stream; stream="$(python3 "$LB" hostile_stream "$seed" "$leg")"
    local out="$work/h.out" try g
    if [[ "$genuine" == 1 ]]; then
        for try in 1 2 3 4; do boot_feed "$kel" "$out" $stream; g="$(python3 "$LB" hostile_grade "$out" "$seed" "$leg" 2>&1)"; is_struct_flake "$g" || break; done
    else
        boot_feed "$kel" "$out" $stream; g="$(python3 "$LB" hostile_grade "$out" "$seed" "$leg" 2>&1)"
    fi
    echo "$g"
}

# ---- master structural byte-pin: every mutant kernel differs from the genuine build_elf() ----
if LARDER_TDIR="$script_dir" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ['LARDER_TDIR'])
import larder_ref as L
a,_,_ = L.build_elf()
muts = ['bump','freenoop','nosplit','nocoalesce','noprevmerge','nonextmerge','nosizewrap','nointeriorfree',
        'bestfit','badsplit','badsplitlen','baddelete','nomaxchunks']
ok = all(L.build_elf(mut=m)[0] != a for m in muts)
print('all_mutant_kernels_differ', ok)
sys.exit(0 if ok else 1)
PY
then ok "master byte-pin: every mutant kernel (bump/freenoop/nosplit/nocoalesce/noprevmerge/nonextmerge/nosizewrap/nointeriorfree/bestfit/badsplit/badsplitlen/baddelete/nomaxchunks -- all 13) differs from larder_ref.build_elf() -- each mutation actually perturbs the emitted kernel"
else fail_test "master byte-pin: a mutant kernel was byte-identical to genuine (a mutation is a no-op -- vacuous)"; fi

# ---- SINGLE SHARED SEED: the control AND every mutant run on the EXACT SAME late-bound witness + hostile legs, so each
#      mutant's RED is strictly attributable to the mutation (not to a different rejection-sampled seed). (Codex nit D.) ----
SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"

# ---- CONTROL: genuine kernel -- GREEN on the witness AND clean on all four hostile legs AND passes assert_larder ----
CK="$work/ctrl.elf"; build_kernel "$CK" none
C_W="$(run_witness "$CK" "$SEED" 1)"
C_INT="$(run_hostile "$CK" "$SEED" interior 1)"
C_A0="$(run_hostile "$CK" "$SEED" alloc0 1)"
C_SM="$(run_hostile "$CK" "$SEED" smallalloc 1)"
C_TF="$(run_hostile "$CK" "$SEED" tablefill 1)"
c_wb=1; python3 "$REF" assertlarder "$CK" >/dev/null 2>&1 && c_wb=0
if echo "$C_W" | grep -q '^GREEN' && echo "$C_INT" | grep -q '^GREEN' && echo "$C_A0" | grep -q '^GREEN' && echo "$C_SM" | grep -q '^GREEN' && echo "$C_TF" | grep -q '^GREEN' && [[ "$c_wb" -eq 0 ]]; then
    ok "control (genuine, seed=$SEED) GREEN -- the late-bound author-unknown alloc/free witness emits the FIRST-FIT golden (split + prev-coalesce + next-coalesce + non-MRU reuse; sentinels intact); the interior-ptr free is a clean no-op (both chunks survive); alloc(0) + sub-4 sizes are rejected (ptr 0, no degenerate chunk); the over-cap (table-full) alloc is rejected (ptr 0, no array overrun); assert_larder TRUE"
else
    fail_test "control kernel is NOT clean (witness=$(echo "$C_W"|grep -oE '^(GREEN|RED)'); interior=$(echo "$C_INT"|grep -oE '^(GREEN|RED)'); alloc0=$(echo "$C_A0"|grep -oE '^(GREEN|RED)'); smallalloc=$(echo "$C_SM"|grep -oE '^(GREEN|RED)'); tablefill=$(echo "$C_TF"|grep -oE '^(GREEN|RED)'); assert_larder=$([[ $c_wb -eq 0 ]] && echo TRUE || echo FALSE)) -- the mutation harness does not bite"
fi

# ---- the OUTPUT FORGE mutants: the witness must DIVERGE (RED), graded against the SAME control witness (single seed). ----
for spec in \
  "bump:pure bump-pointer (no free-list / no reuse) -> the offset trace diverges -> RED on the witness" \
  "freenoop:SYS_FREE never reclaims -> later allocs OOM where genuine reuses a freed span -> RED on the witness" \
  "nosplit:alloc the WHOLE chunk (never split the remainder) -> the remainder is lost, later allocs OOM -> RED" \
  "nocoalesce:free never merges neighbours -> the coalesce-fed allocs OOM -> RED" \
  "noprevmerge:free merges only the NEXT neighbour -> the prev-merge-fed alloc OOMs -> RED" \
  "nonextmerge:free merges only the PREV neighbour -> the next-merge-fed alloc OOMs -> RED" \
  "bestfit:BEST-fit not FIRST-fit -> on the witness's two-hole state (a big hole @low + a small hole @high, an alloc fits both) it picks the smaller (higher-address) hole -> a DIFFERENT returned ptr than first-fit -> the emitted offset trace diverges -> RED" \
  "badsplit:the split remainder is given a WRONG base (base_i+size off by +4) -> the next alloc on the remainder returns the wrong offset -> the emitted trace diverges -> RED" \
  "badsplitlen:the split remainder is given a WRONG len (len_i-size off by -4) -> a later exact-fit alloc OOMs where genuine fits -> the emitted trace diverges -> RED" \
  "baddelete:the coalesce array-delete shift is off-by-one-dword in the dest (rep movsd writes every struct field one dword high) -> the gap-free address-sorted array is malformed -> a later alloc/free reads a corrupted chunk -> the emitted trace diverges -> RED"; do
    m="${spec%%:*}"; desc="${spec#*:}"
    MK="$work/$m.elf"; build_kernel "$MK" "$m"
    V="$(mutant_verdict run_witness "$MK" "$SEED")"   # flake-discriminated: a RED must be a DETERMINISTIC bite, SAME seed as the control
    case "$V" in
      DIVERGE)    ok "M-$m witness RED (deterministic DIVERGENCE) -- $desc" ;;
      CONSISTENT) ok "M-$m witness RED (deterministic break: RED on every attempt, never GREEN, no value-mismatch -- consistently no/partial trace) -- $desc" ;;
      *)          fail_test "M-$m did NOT deterministically bite -- a GREEN appeared across retries (the mutation is behaviorally vacuous / its RED was a structural flake): $desc" ;;
    esac
done

# ---- M-nosizewrap: OUTPUT-INVISIBLE on the benign witness (PROVE GREEN, informational) -> caught by the alloc0 +
#      smallalloc hostile legs (a NONZERO degenerate-chunk ptr) AND assert_larder FALSE. ----
MK="$work/nosizewrap.elf"; build_kernel "$MK" nosizewrap
NS_W="$(run_witness "$MK" "$SEED" 1)"; ns_benign=0; echo "$NS_W" | grep -q '^GREEN' && ns_benign=1
NS_A0="$(mutant_verdict run_hostile "$MK" "$SEED" alloc0)"; ns_a0_red=0; [[ "$NS_A0" != EQUIVALENT ]] && ns_a0_red=1
NS_SM="$(mutant_verdict run_hostile "$MK" "$SEED" smallalloc)"; ns_sm_red=0; [[ "$NS_SM" != EQUIVALENT ]] && ns_sm_red=1
ns_wb=1; python3 "$REF" assertlarder "$MK" >/dev/null 2>&1 && ns_wb=0   # ns_wb=1 means assert_larder FALSE (rejected)
if [[ "$ns_a0_red" -eq 1 && "$ns_sm_red" -eq 1 && "$ns_wb" -eq 1 ]]; then
    note=""; [[ "$ns_benign" -eq 1 ]] && note="OUTPUT-INVISIBLE on the benign witness (GREEN) yet " || note="(this run's benign witness was also non-GREEN) "
    ok "M-nosizewrap the size-reject drop is ${note}the alloc0 leg now returns a NONZERO ptr to a 0-length chunk -> RED ($NS_A0) AND the smallalloc leg returns a ptr to a sub-4 chunk -> RED ($NS_SM) (the SYS_DUMP cross-boundary edge) AND assert_larder FALSE (the cmp ebx,4 / cmp ebx,[pool_size] -> la_oom branch-targets are gone)"
else
    fail_test "M-nosizewrap did not deterministically bite (alloc0 verdict=$NS_A0; smallalloc verdict=$NS_SM; assert_larder FALSE=$ns_wb) -- EQUIVALENT means a GREEN appeared (vacuous / flake-masked)"
fi

# ---- M-nointeriorfree: OUTPUT-INVISIBLE on the benign witness (PROVE GREEN, informational) -> caught by the interior
#      hostile leg (a range-match frees the CONTAINING chunk) AND assert_larder FALSE. ----
MK="$work/nointeriorfree.elf"; build_kernel "$MK" nointeriorfree
NI_W="$(run_witness "$MK" "$SEED" 1)"; ni_benign=0; echo "$NI_W" | grep -q '^GREEN' && ni_benign=1
NI_INT="$(mutant_verdict run_hostile "$MK" "$SEED" interior)"; ni_int_red=0; [[ "$NI_INT" != EQUIVALENT ]] && ni_int_red=1
ni_wb=1; python3 "$REF" assertlarder "$MK" >/dev/null 2>&1 && ni_wb=0
if [[ "$ni_int_red" -eq 1 && "$ni_wb" -eq 1 ]]; then
    note=""; [[ "$ni_benign" -eq 1 ]] && note="OUTPUT-INVISIBLE on the benign witness (GREEN) yet " || note="(this run's benign witness was also non-GREEN) "
    ok "M-nointeriorfree the exact-base-match drop is ${note}the interior leg's interior-ptr free now range-matches + frees the CONTAINING chunk -> the live readback loses it -> RED ($NI_INT) AND assert_larder FALSE (the mov eax,[esi] ; cmp eax,[al_ptr] ; jne exact-base match is gone)"
else
    fail_test "M-nointeriorfree did not deterministically bite (interior verdict=$NI_INT; assert_larder FALSE=$ni_wb) -- EQUIVALENT means a GREEN appeared (vacuous / flake-masked)"
fi

# ---- M-nomaxchunks: the chunk-table-full guard. OUTPUT-INVISIBLE on the benign witness (peak ~4 chunks << MAX 16, PROVE
#      GREEN, informational) -> caught by the TABLE-FILL hostile leg (the over-cap alloc now proceeds, emit_larder_split
#      overruns chunk[MAX] past the 16-entry descriptor array -> a NONZERO over-cap ptr + corrupted state) AND assert_larder
#      FALSE (the cmp nchunks,MAX -> la_oom branch-target is gone). (Completeness-critic catch B.) ----
MK="$work/nomaxchunks.elf"; build_kernel "$MK" nomaxchunks
NM_W="$(run_witness "$MK" "$SEED" 1)"; nm_benign=0; echo "$NM_W" | grep -q '^GREEN' && nm_benign=1
NM_TF="$(mutant_verdict run_hostile "$MK" "$SEED" tablefill)"; nm_tf_red=0; [[ "$NM_TF" != EQUIVALENT ]] && nm_tf_red=1
nm_wb=1; python3 "$REF" assertlarder "$MK" >/dev/null 2>&1 && nm_wb=0
if [[ "$nm_tf_red" -eq 1 && "$nm_wb" -eq 1 ]]; then
    note=""; [[ "$nm_benign" -eq 1 ]] && note="OUTPUT-INVISIBLE on the benign witness (GREEN, peak chunks << MAX) yet " || note="(this run's benign witness was also non-GREEN) "
    ok "M-nomaxchunks the chunk-table-full guard drop is ${note}the table-fill leg's over-cap alloc now proceeds -> emit_larder_split overruns chunk[MAX] past the 16-entry array (NONZERO over-cap ptr + corrupted state) -> RED ($NM_TF) AND assert_larder FALSE (the cmp nchunks,LARDER_MAXCHUNKS -> la_oom branch-target is gone)"
else
    fail_test "M-nomaxchunks did not deterministically bite (tablefill verdict=$NM_TF; assert_larder FALSE=$nm_wb) -- EQUIVALENT means a GREEN appeared (vacuous / flake-masked)"
fi

echo "native-codegen link56 larder MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link56 larder MUTATION proof -- control GREEN (the late-bound author-unknown alloc/free witness emits the FIRST-FIT golden -- split + prev-coalesce + next-coalesce + non-MRU reuse, sentinels intact; the interior-ptr free is a clean no-op; alloc(0)/sub-4 sizes are rejected; assert_larder TRUE); M-bump: pure bump-pointer (no free-list / reuse) -> the offset trace diverges -> RED on the witness; M-freenoop: SYS_FREE never reclaims -> later allocs OOM where genuine reuses a freed span -> RED; M-nosplit: alloc the WHOLE chunk (never split) -> the remainder is lost, later allocs OOM -> RED; M-nocoalesce: free never merges -> the coalesce-fed allocs OOM -> RED; M-noprevmerge: merge only the NEXT neighbour -> the prev-merge-fed alloc OOMs -> RED; M-nonextmerge: merge only the PREV neighbour -> the next-merge-fed alloc OOMs -> RED; M-nosizewrap: drop the size reject -- OUTPUT-INVISIBLE on the benign witness (still GREEN, the sizes are in [4,pool]) -- caught by the alloc0 leg (alloc(0) now returns a NONZERO ptr to a 0-length chunk -> RED) AND the smallalloc leg (size<4 -> a ptr to a sub-sentinel chunk shorter than the 4-byte SYS_DUMP readback -> RED) AND the white-box assert_larder FALSE (the cmp ebx,4 / cmp ebx,[pool_size] -> la_oom branch-targets are gone); M-nointeriorfree: match a chunk by RANGE not EXACT base -- OUTPUT-INVISIBLE on the benign witness (still GREEN, it only frees by exact base) -- caught by the interior leg (an interior-ptr free now frees the CONTAINING chunk -> the live readback loses it -> RED) AND the white-box assert_larder FALSE (the mov eax,[esi] ; cmp eax,[al_ptr] ; jne exact-base match is gone); the control is proven GREEN on the SAME witness + hostile legs first so each mutant's RED is attributable to the mutation; a master structural byte-pin confirms every mutant kernel differs from genuine build_elf().)"
