#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link61 / highwater (kernel-arc link 45: the RUNTIME FREE-FRAME ALLOCATOR off
# an AUTHOR-UNKNOWN memory map, via SYS_FALLOC eax=13 / SYS_HWDUMP eax=14). Each mutation perturbs ONE piece of the
# allocator in highwater_ref.build_elf(mut=...) and proves it non-vacuous: the CONTROL kernel grades GREEN (the
# author-unknown -m witness emits N top-down frames @ region_hi(-m), each holding its late-bound seed-derived payload, AND
# assert_highwater passes); every mutant grades RED on the witness OUTPUT. A master structural byte-pin confirms every
# mutant kernel differs from genuine, and assert_highwater REJECTS each white-box mutant. Modeled on link56's mutation proof.
#
# Mutations (highwater_ref.build_elf(mut=...)):
#   M-hwnoinvlpg    drop the targeted invlpg [V] in do_falloc/do_hwdump -> the stale V->lastframe TLB entry serves every
#                   SYS_HWDUMP readback -> all readbacks collapse to the last payload -> RED (invlpg is load-bearing).
#   M-hwbumpup      allocate BOTTOM-UP from a baked low base (0x400000) instead of TOP-DOWN from region_hi -> the emitted
#                   frame addresses are author-KNOWN low addresses, not region_hi(-m)-relative -> RED (top-down is forced).
#   M-hwsingleframe map/record a FIXED baked frame (F_FRAME) for every alloc instead of the distinct top-down frame -> every
#                   SYS_HWDUMP readback collapses to the last payload (one shared frame) -> RED (distinctness via aliasing).
#   M-hwbakedaddr   emit a FIXED baked address (0x12340000) instead of the runtime top-down frame -> fails the per-run-random
#                   -m expectation -> RED (the kernel-emit must read the genuine top-down frame).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/highwater_ref.py"
LB="$script_dir/highwater_latebound.py"
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
rand_ram() { echo $((RANDOM % 6)) | awk '{split("24 32 48 64 96 128",a," "); print a[$1+1]}'; }
rand_seed() { echo $(( (RANDOM % 254) + 1 )); }

PROBER="$work/prober.bin"; python3 "$LB" prober "$PROBER" >/dev/null
DISK="$work/disk.img"; dd if=/dev/zero of="$DISK" bs=1M count=64 status=none

boot_feed() { # kernel out ram seed [prober]
    local kel="$1" out="$2" ram="$3" seed="$4" prb="${5:-$PROBER}"
    local port; port="$(free_port)"; local d="$out.d"; rm -rf "$d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$seed" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$prb" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m "${ram}M" >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
is_struct_flake() { echo "$1" | grep -qiE 'MAGIC banner not found|truncated|no HWDUMP|alloc entries|hwdump entries'; }
# a REAL divergence = any RED that is NOT a struct flake (a materialized value-mismatch). Credits every value-RED reason.
has_real_divergence() { echo "$1" | grep -q '^RED' && ! is_struct_flake "$1"; }
build_kernel() { python3 "$LB" kernel "$1" "$2" >/dev/null; }   # out mut|none

run_witness() { # kel ram seed genuine -> grade
    local kel="$1" ram="$2" seed="$3" genuine="${4:-}" out="$work/w.out" try g
    if [[ "$genuine" == 1 ]]; then
        for try in 1 2 3 4; do boot_feed "$kel" "$out" "$ram" "$seed"; g="$(python3 "$LB" grade "$out" "$ram" "$seed" 2>&1)"; is_struct_flake "$g" || break; done
    else
        boot_feed "$kel" "$out" "$ram" "$seed"; g="$(python3 "$LB" grade "$out" "$ram" "$seed" 2>&1)"
    fi
    echo "$g"
}
mutant_verdict() { # mut ram seed -> DIVERGE|CONSISTENT|EQUIVALENT (flake-discriminated deterministic bite)
    local mut="$1" ram="$2" seed="$3" kel="$work/km.elf" n=4 i g
    build_kernel "$kel" "$mut"
    for i in $(seq 1 "$n"); do
        g="$(run_witness "$kel" "$ram" "$seed")"
        echo "$g" | grep -q '^GREEN' && { echo EQUIVALENT; return; }
        has_real_divergence "$g" && { echo DIVERGE; return; }
    done
    echo CONSISTENT
}

# ---- master structural byte-pin: every mutant kernel differs from genuine + assert_highwater rejects each ----
if HW_TDIR="$script_dir" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ['HW_TDIR'])
import highwater_ref as H
NP=H.GROWHEAP_NPAGES
a,_,_=H.build_elf(npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=True)
muts=['hwnoinvlpg','hwbumpup','hwsingleframe','hwbakedaddr','hwnocap']
differ=all(H.build_elf(mut=m,npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=True)[0]!=a for m in muts)
rej=all(not H.assert_highwater(H.build_elf(mut=m,npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=True)[0]) for m in muts)
print('all_mutant_kernels_differ',differ,'assert_rejects_all',rej)
sys.exit(0 if (differ and rej) else 1)
PY
then ok "master byte-pin: every mutant kernel (hwnoinvlpg/hwbumpup/hwsingleframe/hwbakedaddr/hwnocap) differs from highwater_ref.build_elf(highwater=True) AND assert_highwater REJECTS each (the white-box co-pin discriminates every mutation)"
else fail_test "master byte-pin: a mutant kernel was byte-identical to genuine OR assert_highwater accepted a mutant (vacuous)"; fi

# ---- SINGLE SHARED -m + seed: the control AND every mutant run on the EXACT SAME author-unknown witness ----
RAM="$(rand_ram)"; SEED="$(rand_seed)"

# ---- CONTROL: genuine kernel GREEN on the author-unknown witness AND assert_highwater TRUE ----
CK="$work/ctrl.elf"; build_kernel "$CK" none
C_W="$(run_witness "$CK" "$RAM" "$SEED" 1)"
c_wb=1; python3 "$REF" asserthighwater "$CK" >/dev/null 2>&1 && c_wb=0
if echo "$C_W" | grep -q '^GREEN' && [[ "$c_wb" -eq 0 ]]; then
    ok "control (genuine, -m ${RAM}M seed=$SEED) GREEN -- the author-unknown -m witness emits N top-down frames @ region_hi(${RAM}M), each holding its late-bound seed-derived payload; assert_highwater TRUE"
else
    fail_test "control kernel NOT clean (witness=$(echo "$C_W"|grep -oE '^(GREEN|RED)'); assert_highwater=$([[ $c_wb -eq 0 ]] && echo TRUE || echo FALSE)) -- the mutation harness does not bite"
fi

# ---- the OUTPUT-FORGE mutants: the witness must DIVERGE (RED), SAME -m + seed as the control ----
for spec in \
  "hwnoinvlpg:drop the targeted invlpg [V] -> the stale V->lastframe TLB entry serves every readback -> all readbacks collapse to the last payload -> RED" \
  "hwbumpup:allocate BOTTOM-UP from a baked low base instead of TOP-DOWN from region_hi -> author-KNOWN low addresses != region_hi(-m) -> RED" \
  "hwsingleframe:map/record a FIXED baked frame for every alloc -> every readback collapses to the last payload (one shared frame) -> RED" \
  "hwbakedaddr:emit a FIXED baked address instead of the runtime top-down frame -> fails the per-run-random -m expectation -> RED"; do
    m="${spec%%:*}"; desc="${spec#*:}"
    V="$(mutant_verdict "$m" "$RAM" "$SEED")"
    case "$V" in
      DIVERGE)    ok "M-$m witness RED (deterministic DIVERGENCE) -- $desc" ;;
      CONSISTENT) ok "M-$m witness RED (deterministic break: RED on every attempt, never GREEN) -- $desc" ;;
      *)          fail_test "M-$m did NOT deterministically bite -- a GREEN appeared across retries (vacuous / flake-masked): $desc" ;;
    esac
done

# ---- M-hwnocap: OUTPUT-INVISIBLE on the benign N=6 witness (6 < the cap, PROVE GREEN informational) -> caught by a HOSTILE
#      over-cap prober (the genuine kernel caps at HW_MAXFRAMES; M-hwnocap lets the over-cap allocs proceed). ----
HPROBER="$work/hprober.bin"; python3 "$LB" hostileprober "$HPROBER" >/dev/null
# genuine control: the cap holds on the hostile (over-cap) prober -> hostilegrade GREEN
for try in 1 2 3 4; do boot_feed "$CK" "$work/hc.out" "$RAM" "$SEED" "$HPROBER"; HC="$(python3 "$LB" hostilegrade "$work/hc.out" "$RAM" 2>&1)"; is_struct_flake "$HC" || break; done
# M-hwnocap: the benign N=6 witness stays GREEN (6 < cap, OUTPUT-INVISIBLE), so prove it informational; the BITE is the hostile leg.
build_kernel "$work/nocap.elf" hwnocap
NB="$(run_witness "$work/nocap.elf" "$RAM" "$SEED" 1)"; nb_benign=0; echo "$NB" | grep -q '^GREEN' && nb_benign=1
nc_v=EQUIVALENT
for i in 1 2 3 4; do
    boot_feed "$work/nocap.elf" "$work/nch.out" "$RAM" "$SEED" "$HPROBER"
    g="$(python3 "$LB" hostilegrade "$work/nch.out" "$RAM" 2>&1)"
    echo "$g" | grep -q '^GREEN' && { nc_v=EQUIVALENT; break; }
    echo "$g" | grep -qE 'NOT enforced|> HW_MAXFRAMES' && { nc_v=DIVERGE; break; }
    nc_v=CONSISTENT
done
if echo "$HC" | grep -q '^GREEN' && [[ "$nc_v" != EQUIVALENT ]]; then
    note=""; [[ "$nb_benign" -eq 1 ]] && note="OUTPUT-INVISIBLE on the benign N=6 witness (still GREEN, 6<cap) yet " || note="(this run's benign witness was also non-GREEN) "
    ok "M-hwnocap the per-boot-cap drop is ${note}a hostile over-cap prober's allocs now proceed past HW_MAXFRAMES -> MORE than HW_MAXFRAMES non-zero FALLOC frames (the hw_frames[] overrun / kernel-descent path) -> RED ($nc_v); the genuine kernel CAPS (control hostile GREEN)"
else
    fail_test "M-hwnocap did not deterministically bite (control hostile=$(echo "$HC"|grep -oE '^(GREEN|RED)'); M-hwnocap verdict=$nc_v) -- EQUIVALENT means a GREEN appeared (vacuous / flake-masked)"
fi

echo "native-codegen link61 highwater MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link61 highwater MUTATION proof -- control GREEN (the author-unknown -m witness emits N top-down frames @ region_hi(-m), each holding its late-bound seed-derived payload; assert_highwater TRUE); M-hwnoinvlpg: drop the targeted invlpg -> the stale V->lastframe TLB entry serves every SYS_HWDUMP readback -> all collapse to the last payload -> RED (invlpg is load-bearing); M-hwbumpup: allocate bottom-up from a baked low base -> author-KNOWN addresses != region_hi(-m) top-down -> RED; M-hwsingleframe: one baked frame for every alloc -> every readback collapses (one shared frame, not distinct RAM) -> RED; M-hwbakedaddr: emit a fixed baked address -> fails a per-run-random -m -> RED; a master structural byte-pin confirms every mutant kernel differs from genuine build_elf() AND assert_highwater rejects each; the control is proven GREEN on the SAME author-unknown witness first so each mutant's RED is attributable to the mutation.)"
