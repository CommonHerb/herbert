#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link57 / growheap (GROW THE HEAP -- a MULTI-PAGE heap with cross-page
# coalesce). Each mutation perturbs ONE piece of the multi-page allocator in growheap_ref.build_elf(mut=..., npages=N) and
# proves it non-vacuous against the LATE-BOUND cross-page witness: the CONTROL kernel grades GREEN (the author-unknown
# alloc/free witness emits the FIRST-FIT golden with the make-or-break alloc landing in the cross-page-coalesced hole, AND
# assert_growheap passes); every forge mutant OOMs the make-or-break alloc -> the emitted trace DIVERGES (RED). Modeled on
# run_native_codegen_link56_mutation.sh, using growheap_latebound.py's forge interface + assert_growheap + a master
# structural byte-pin (every mutant kernel differs from genuine).
#
# The witness: a LATE-BOUND, AUTHOR-UNKNOWN op stream over COM1 (the seed -> the chunk SIZES + SENTINELS, chosen AFTER
# freeze; rejection-sampled so the peak live-set spans 2 pages and the make-or-break alloc fits ONLY a hole formed by
# coalescing two freed spans that STRADDLE the page boundary). The kernel emits each returned ptr + the SYS_DUMP live
# readback (the same KERNEL-EMIT machinery as larder).
#
# Mutations (growheap_ref.build_elf(mut=..., npages=N), exercised via growheap_latebound FORGE_LEGS):
#   M-singlepage          the pool is capped to ONE page -> the witness's page-2 alloc OOMs -> the trace DIVERGES -> RED.
#   M-nocrosspagecoalesce the free-arm coalesce REFUSES to merge across a page boundary -> the straddling make-or-break
#                         hole never forms -> that alloc OOMs -> RED.
#   M-freenoop (nofree)   SYS_FREE never reclaims -> the hole never forms -> the make-or-break alloc OOMs -> RED.
#   M-bump (staticarena)  pure bump-pointer, no reuse -> the make-or-break alloc OOMs -> RED.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/growheap_ref.py"
LB="$script_dir/growheap_latebound.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
for f in "$REF" "$LB" "$feeder"; do [[ -f "$f" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing $f)"; exit 1; }; done
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

DRIVER="$work/driver.bin"; python3 "$LB" driver "$DRIVER"
DISK="$work/disk.img"; dd if=/dev/zero of="$DISK" bs=1M count=64 status=none

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
is_struct_flake() { echo "$1" | grep -qE 'no parseable kernel cell-dump|MAGIC banner not found|truncated|missing 0xE'; }
# a GENUINE divergence = a VALUE mismatch ('alloc N: emitted 0x0 != expected'), NOT the broad
# 'OOM|ptr 0|0x0' -- grade prints `pool_base=0x0` on an unparseable boot, so '0x0' would misread a
# dead/hung mutant as a valid forge DIVERGE (cross-model gate-audit). Only an emitted-value mismatch.
has_real_divergence() { echo "$1" | grep -qE '!= expected|appears MORE THAN ONCE|emitted MORE live chunks'; }
mutant_verdict() { # cmd...  -> DIVERGE|CONSISTENT|EQUIVALENT
    local n=4 i g
    for i in $(seq 1 "$n"); do
        g="$("$@")"
        echo "$g" | grep -q '^GREEN' && { echo EQUIVALENT; return; }
        has_real_divergence "$g" && { echo DIVERGE; return; }
    done
    echo CONSISTENT
}
build_kernel() { python3 "$LB" kernel "$1" "$2" >/dev/null; }
run_witness() { # kel seed genuine
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
run_forge_leg() { # leg seed  -> grade the leg's biting mutant kernel on the forge stream vs the GENUINE golden
    local leg="$1" seed="$2"
    local mut; mut="$(python3 "$LB" forge_mutant "$leg")"
    local kel="$work/forge_$leg.elf"; build_kernel "$kel" "$mut"
    local stream; stream="$(python3 "$LB" forge_stream "$seed" "$leg")"
    local out="$work/forge_$leg.out"; boot_feed "$kel" "$out" $stream
    python3 "$LB" forge_grade "$out" "$seed" "$leg" 2>&1
}

# ---- master structural byte-pin: every growheap mutant kernel differs from the genuine build_elf(npages=N) ----
if GROWHEAP_TDIR="$script_dir" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ['GROWHEAP_TDIR'])
import growheap_ref as G
NP = G.GROWHEAP_NPAGES
a,_,_ = G.build_elf(npages=NP)
muts = ['singlepage','nocrosspagecoalesce','freenoop','bump']
ok = all(G.build_elf(mut=m, npages=NP)[0] != a for m in muts)
print('all_mutant_kernels_differ', ok)
sys.exit(0 if ok else 1)
PY
then ok "master byte-pin: every growheap mutant kernel (singlepage/nocrosspagecoalesce/freenoop/bump) differs from growheap_ref.build_elf(npages=N) -- each mutation actually perturbs the emitted kernel"
else fail_test "master byte-pin: a mutant kernel was byte-identical to genuine (a mutation is a no-op -- vacuous)"; fi

# ---- SINGLE SHARED SEED: control + every forge mutant run on the EXACT SAME late-bound cross-page witness ----
SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"

# ---- CONTROL: genuine kernel -- GREEN on the cross-page witness AND assert_growheap TRUE ----
CK="$work/ctrl.elf"; build_kernel "$CK" none
C_W="$(run_witness "$CK" "$SEED" 1)"
c_wb=1; python3 "$REF" assertgrowheap "$CK" >/dev/null 2>&1 && c_wb=0
if echo "$C_W" | grep -q '^GREEN' && [[ "$c_wb" -eq 0 ]]; then
    ok "control (genuine, seed=$SEED) GREEN -- the late-bound author-unknown cross-page witness emits the FIRST-FIT golden (peak live-set spans 2 pages; the make-or-break alloc fits the hole formed by coalescing two freed spans that STRADDLE the page boundary; sentinels intact); assert_growheap TRUE"
else
    fail_test "control kernel is NOT clean (witness=$(echo "$C_W"|grep -oE '^(GREEN|RED)'); assert_growheap=$([[ $c_wb -eq 0 ]] && echo TRUE || echo FALSE)) -- the mutation harness does not bite"
fi

# ---- the FORGE mutants: the make-or-break alloc must OOM -> the trace DIVERGES (RED), same shared seed as the control ----
for spec in \
  "singlepage:the pool is capped to ONE page -> the witness's page-2 alloc OOMs -> the cross-page trace diverges -> RED" \
  "nocrosspagecoalesce:the free-arm coalesce REFUSES to merge across a page boundary -> the straddling make-or-break hole never forms -> that alloc OOMs -> RED" \
  "nofree:SYS_FREE never reclaims (M-freenoop) -> the hole never forms -> the make-or-break alloc OOMs -> RED" \
  "staticarena:pure bump-pointer (M-bump), no reuse -> the make-or-break alloc OOMs -> RED"; do
    leg="${spec%%:*}"; desc="${spec#*:}"
    V="$(mutant_verdict run_forge_leg "$leg" "$SEED")"   # flake-discriminated: a RED must be a DETERMINISTIC bite, SAME seed as the control
    case "$V" in
      DIVERGE)    ok "FORGE-$leg witness RED via a genuine VALUE mismatch (the make-or-break alloc emits ptr 0x0 != expected) -- $desc" ;;
      *)          fail_test "FORGE-$leg did NOT produce a genuine value-mismatch divergence (verdict=$V) -- a forge must OOM the make-or-break alloc (ptr != expected), not crash/hang/go-green (cross-model gate-audit: CONSISTENT could be a dead mutant): $desc" ;;
    esac
done

echo "native-codegen link57 growheap MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link57 growheap MUTATION proof -- control GREEN (the late-bound author-unknown cross-page witness emits the FIRST-FIT golden: peak live-set spans 2 pages, the make-or-break alloc fits the cross-page-coalesced hole, sentinels intact; assert_growheap TRUE); M-singlepage: the pool capped to ONE page -> the page-2 alloc OOMs -> RED; M-nocrosspagecoalesce: the coalesce refuses to merge across the page boundary -> the straddling make-or-break hole never forms -> that alloc OOMs -> RED; M-freenoop: SYS_FREE never reclaims -> the hole never forms -> RED; M-bump: pure bump-pointer, no reuse -> RED; the control is proven GREEN on the SAME witness first so each mutant's RED is attributable to the mutation; a master structural byte-pin confirms every mutant kernel differs from genuine build_elf(npages=N).)"
