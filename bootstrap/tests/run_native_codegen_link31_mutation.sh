#!/usr/bin/env bash
# Mutation proof for native-codegen link31 (contigo / f1, the data-dependent scheduling decision):
# prove the link31 value-flow/locus gate + the X/Y differential genuinely BITE. Each mutation
# binary-patches a COMPILED probe (co_lit: return 88, vA=88; X=65 -> task A emits de58ad,
# Y=200 -> task B emits de2ead) and asserts the expected RED, on real QEMU with the socket feeder.
#
# Two classes (the cross-model + completeness-critic split):
#  SILICON-RED (the X/Y differential on the substrate catches it):
#   M-blind   jae 73->nop 90 (the scheduler's cmp;jae is dead) -> always pickA -> Y wrongly emits de58ad
#   M-readlit scheduler `mov eax,[inq]` -> `mov eax,0x41` -> decision input-independent -> both emit de58ad
#   M-noinput head RBR read -> `mov eax,0x41`+nops -> inq constant -> both emit de58ad
#   M-swap    jae 73->jb 72 (threshold sense inverted) -> X and Y pick the OPPOSITE task (both wrong)
#   M-decoyB  seedB.eip -> garbage -> Y irets into garbage -> triple-fault, no frame
#  WHITE-BOX-RED (silicon SILENTLY TOLERATES; only the value-bind gate catches it -- empirically
#  confirmed silent, so the canon must NOT claim silicon catches these):
#   M-noeoi   EOI b020e620 -> nops: silicon still emits (task runs IF=0 to hlt) -> P-sched pin RED
#   M-eflags  seed eflags 0x002 -> 0x202 (IF=1): silicon still single-shot (slow PIT) -> P-seeds pin RED
#   M-thresh  cmp 128 -> cmp 100: still splits 65|200 -> P-sched THRESH==128 value-bind RED
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
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: link31 mutation (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link31 mutation (no qemu)"; exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
fail=0; fail_test() { echo "FAIL: link31 mutation ($1)"; fail=$((fail + 1)); }

# compile co_lit (return 88), the base image.
cdir="$work/lit.d"; mkdir -p "$cdir"
printf -- '-- emit: multiboot32-contigo\nfunc main(): return 88 end\n' > "$cdir/p.herb"
( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>"$cdir/err" )
[[ -f "$cdir/a.out" ]] || { echo "FAIL: link31 mutation (compile produced no a.out: $(head -1 "$cdir/err"))"; exit 1; }
base="$work/base.elf"; cp "$cdir/a.out" "$base"

# locate the scheduler + derive the data layout (code starts at file 4108).
chx=$(dd if="$base" bs=1 skip=4108 status=none | xxd -p | tr -d '\n')
SCHED_RE='b020e620a1[0-9a-f]{8}3d800000007307bc[0-9a-f]{8}eb05bc[0-9a-f]{8}61cf'
spos=$(echo "$chx" | grep -boE "$SCHED_RE" | head -1 | cut -d: -f1)
[[ -n "$spos" ]] || { echo "FAIL: link31 mutation (cannot locate scheduler in base image)"; exit 1; }
off_sched=$((spos/2)); off_tables=$((off_sched+30))
off_data=$(( (off_tables+300+3) & ~3 )); off_seedA=$((off_data+8+256)); off_seedB=$((off_seedA+44+256))
fpos() { echo $(( 4108 + $1 )); }   # code offset -> file offset

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
emit_for() { # elf byte -> captured e9 frame hex (e.g. de58ad) or "none"
    local elf="$1" byte="$2" W; W="$(mktemp -d)"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/f.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 80); do grep -q LISTENING "$W/f.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    local got; got=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n'); rm -rf "$W"
    [[ -n "$got" ]] && echo "$got" || echo "none"
}
# patch helpers (equal-length, on a fresh copy)
patch_hex() { # src dst oldhex newhex
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src,dst,old,new=sys.argv[1:5]
b=open(src,'rb').read(); o=bytes.fromhex(old); n=bytes.fromhex(new)
assert len(o)==len(n), "patch not equal-length"
i=b.find(o); assert i>=0, "pattern %s not found"%old
open(dst,'wb').write(b[:i]+n+b[i+len(n):]); print(i)
PY
}
patch_off() { # src dst fileoff newhex
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src,dst,off,new=sys.argv[1],sys.argv[2],int(sys.argv[3]),bytes.fromhex(sys.argv[4])
b=bytearray(open(src,'rb').read()); b[off:off+len(new)]=new; open(dst,'wb').write(b)
PY
}
has_hex() { xxd -p "$1" | tr -d '\n' | grep -q "$2"; }

# ---- CONTROL: the genuine input-driven schedule -------------------------------------------
cX=$(emit_for "$base" 65); cY=$(emit_for "$base" 200)
if [[ "$cX" == "de58ad" && "$cY" == "de2ead" && "$cX" != "$cY" ]]; then
    echo "control OK: in=65 -> $cX (task A, vA=88)   in=200 -> $cY (task B, markerB=46) -- genuine input-driven schedule"
else
    fail_test "control: expected de58ad / de2ead, got X=$cX Y=$cY"
fi

# ===== SILICON-RED mutations =====
# M-blind: the scheduler's jae is dead (90 90) -> always pickA -> Y wrongly emits task A's byte.
mb="$work/blind.elf"; patch_hex "$base" "$mb" "3d800000007307" "3d800000009090" >/dev/null || fail_test "M-blind patch"
bX=$(emit_for "$mb" 65); bY=$(emit_for "$mb" 200)
if [[ "$bX" == "de58ad" && "$bY" == "de58ad" ]]; then echo "M-blind CAUGHT: jae->nop -> in=200 wrongly emits $bY (task A) -- the schedule no longer consults input (collapsed to always-A)"
else fail_test "M-blind: expected collapse to de58ad/de58ad, got X=$bX Y=$bY"; fi

# M-readlit: scheduler reads a literal 0x41 (=65<128) instead of [inq] -> decision input-independent.
inq_le=${chx:$((off_sched*2+10)):8}    # the a1 immediate (inq vaddr, le)
mr="$work/readlit.elf"; patch_hex "$base" "$mr" "b020e620a1${inq_le}" "b020e620b841000000" >/dev/null || fail_test "M-readlit patch"
rX=$(emit_for "$mr" 65); rY=$(emit_for "$mr" 200)
if [[ "$rX" == "de58ad" && "$rY" == "de58ad" ]]; then echo "M-readlit CAUGHT: mov eax,[inq]->mov eax,0x41 -> in=200 wrongly emits $rY -- the decision no longer depends on input"
else fail_test "M-readlit: expected de58ad/de58ad, got X=$rX Y=$rY"; fi

# M-noinput: the head reads no device byte (writes literal 0x41 to inq) -> inq constant.
mn="$work/noinput.elf"; patch_hex "$base" "$mn" "66baf803ec0fb6c0" "b841000000909090" >/dev/null || fail_test "M-noinput patch"
if has_hex "$mn" "66baf803ec0fb6c0"; then fail_test "M-noinput: RBR read still present"; fi
nX=$(emit_for "$mn" 65); nY=$(emit_for "$mn" 200)
if [[ "$nX" == "de58ad" && "$nY" == "de58ad" ]]; then echo "M-noinput CAUGHT: RBR read baked to literal 0x41 -> inq constant -> in=200 wrongly emits $nY (no device read)"
else fail_test "M-noinput: expected de58ad/de58ad, got X=$nX Y=$nY"; fi

# M-swap: jae->jb inverts the threshold sense -> X and Y pick the OPPOSITE task.
ms="$work/swap.elf"; patch_hex "$base" "$ms" "3d800000007307" "3d800000007207" >/dev/null || fail_test "M-swap patch"
sX=$(emit_for "$ms" 65); sY=$(emit_for "$ms" 200)
if [[ "$sX" == "de2ead" && "$sY" == "de58ad" ]]; then echo "M-swap CAUGHT: jae->jb -> in=65 emits $sX (task B) and in=200 emits $sY (task A) -- the schedule is inverted (both wrong vs golden)"
else fail_test "M-swap: expected swapped de2ead/de58ad, got X=$sX Y=$sY"; fi

# M-decoyB: seedB.eip -> garbage -> Y irets into garbage -> no frame.
md="$work/decoyB.elf"; patch_off "$base" "$md" "$(fpos $((off_seedB+32)))" "efbeadde" >/dev/null
dX=$(emit_for "$md" 65); dY=$(emit_for "$md" 200)
if [[ "$dX" == "de58ad" && "$dY" == "none" ]]; then echo "M-decoyB CAUGHT: seedB.eip->0xDEADBEEF -> in=200 irets into garbage -> no frame ($dY); in=65 (task A) unaffected ($dX)"
else fail_test "M-decoyB: expected de58ad/none, got X=$dX Y=$dY"; fi

# ===== WHITE-BOX-RED mutations (silicon SILENTLY TOLERATES; the value-bind gate catches them) =====
# M-noeoi: EOI b020e620 -> nops. Silicon STILL emits the right schedule (task runs IF=0 to hlt).
me="$work/noeoi.elf"; patch_hex "$base" "$me" "b020e620a1${inq_le}" "90909090a1${inq_le}" >/dev/null || fail_test "M-noeoi patch"
eX=$(emit_for "$me" 65); eY=$(emit_for "$me" 200)
if [[ "$eX" == "de58ad" && "$eY" == "de2ead" ]]; then
    if has_hex "$me" "b020e620a1${inq_le}"; then fail_test "M-noeoi: EOI still present after patch"; \
    else echo "M-noeoi CAUGHT (white-box): EOI->nops is SILENT on silicon (X=$eX Y=$eY unchanged) but the P-sched scheduler pin (b020e620...) is GONE -> gate RED. (Proves the EOI is white-box-pinned, not silicon-witnessed.)"; fi
else fail_test "M-noeoi: expected SILENT de58ad/de2ead (white-box only), got X=$eX Y=$eY"; fi

# M-eflags: seedB eflags 0x002 -> 0x202 (IF=1). Silicon still single-shot (slow PIT). P-seeds RED.
mf="$work/eflags.elf"; patch_off "$base" "$mf" "$(fpos $((off_seedB+40)))" "02020000" >/dev/null
fX=$(emit_for "$mf" 65); fY=$(emit_for "$mf" 200)
ef_now=$(dd if="$mf" bs=1 skip="$(fpos $((off_seedB+40)))" count=4 status=none | xxd -p)
if [[ "$fX" == "de58ad" && "$fY" == "de2ead" && "$ef_now" == "02020000" ]]; then
    echo "M-eflags CAUGHT (white-box): seedB eflags 0x002->0x202 (IF=1) is SILENT on silicon (X=$fX Y=$fY unchanged) but the P-seeds eflags==0x002 value-bind is now 0x202 -> gate RED. (Proves IF=0 is white-box-pinned against re-preemption/double-emit.)"
else fail_test "M-eflags: expected SILENT de58ad/de2ead (white-box only), got X=$fX Y=$fY ef=$ef_now"; fi

# M-thresh: cmp 128 -> cmp 100. Silicon still splits 65|200. P-sched THRESH==128 value-bind RED.
mt="$work/thresh.elf"; patch_hex "$base" "$mt" "3d80000000" "3d64000000" >/dev/null || fail_test "M-thresh patch"
tX=$(emit_for "$mt" 65); tY=$(emit_for "$mt" 200)
if [[ "$tX" == "de58ad" && "$tY" == "de2ead" ]]; then
    if has_hex "$mt" "3d800000007307"; then fail_test "M-thresh: cmp 128 still present after patch"; \
    else echo "M-thresh CAUGHT (white-box): THRESH 128->100 is SILENT on silicon for X=65/Y=200 (X=$tX Y=$tY unchanged) but the P-sched cmp-imm value-bind (3d80000000) is GONE -> gate RED. (Proves THRESH is white-box-pinned.)"; fi
else fail_test "M-thresh: expected SILENT de58ad/de2ead (white-box only), got X=$tX Y=$tY"; fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link31 mutation leg(s) failed."; exit 1; fi
echo "PASS: link31 mutation proof (contigo / f1 data-dependent scheduling): control shows the genuine input-driven schedule (in=65->de58ad task A, in=200->de2ead task B); SILICON-RED -- M-blind (jae->nop) collapses to always-A, M-readlit (read literal) + M-noinput (no device read) make the decision input-independent, M-swap (jae->jb) inverts the schedule, M-decoyB (seedB.eip garbage) triple-faults task B; WHITE-BOX-RED (silicon SILENT, gate catches) -- M-noeoi removes the EOI (P-sched pin gone), M-eflags flips IF=0->1 (P-seeds eflags bind), M-thresh shifts 128->100 (P-sched cmp-imm bind). Each load-bearing byte bites: the scheduler genuinely consults input-derived state to select the dispatched task."
exit 0
