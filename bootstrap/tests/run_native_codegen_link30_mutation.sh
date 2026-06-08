#!/usr/bin/env bash
# Mutation proof for native-codegen link30 (trukfit / f3 device input): prove the link30
# value-flow gate + the X/Y differential genuinely BITE. Each mutation binary-patches a
# COMPILED probe (f3_inc: return input_byte()+7) and asserts the expected RED, on real QEMU.
#
# The crux (Codex design red-team): because the emitted byte is RUNTIME-input-dependent, the
# defense is whole-image, not a body-only pin. The mutations cover the forge classes:
#  M-bake : EQUAL-LENGTH patch of the 5-byte RBR read window 66 ba f8 03 ec -> b0 KK 90 90 90
#           (mov al,KK; nop*3; the following 0f b6 c0 50 movzx;push stays). The byte is now a
#           build-time literal -> the X/Y differential COLLAPSES (in=X and in=Y emit the SAME
#           byte f(KK)), and the white-box RBR read-site (66 ba f8 03 ec 0f b6 c0 50) is GONE.
#           A 1-byte EC->mov patch would mis-decode (mov al,imm8 is 2 bytes) -- equal-length is
#           mandatory. If patched-X != patched-Y, a hidden input channel exists -> the gate is
#           incomplete (treat as RED, not an ambiguous pass).
#  M-xform: tamper the +7 immediate (push 7 -> push 0) -> body != provenance (gate RED) and the
#           output != host f_inc (still input-dependent, but the WRONG function -- caught by the
#           provenance pin, NOT by collapse).
#  M-poll : remove the poll back-edge (74 f7 jz -> 90 90) -> the LSR poll no longer loops; the
#           white-box poll pin (74 f7) is GONE (gate RED) and the read races the byte.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
feeder="$script_dir/kernel_input_feed.py"
source "$script_dir/native_codegen_oracle.sh"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: link30 mutation (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link30 mutation (no qemu)"; exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
fail=0; fail_test() { echo "FAIL: link30 mutation ($1)"; fail=$((fail + 1)); }

# compile f3_inc (return input_byte()+7).
cdir="$work/inc.d"; mkdir -p "$cdir"
printf -- '-- emit: multiboot32-input\nfunc main(): return input_byte() + 7 end\n' > "$cdir/p.herb"
( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>"$cdir/err" )
[[ -f "$cdir/a.out" ]] || { echo "FAIL: link30 mutation (compile produced no a.out: $(head -1 "$cdir/err"))"; exit 1; }
base="$work/base.elf"; cp "$cdir/a.out" "$base"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
# boot ELF feeding one byte; echo the captured e9 frame hex (e.g. de48ad) or "none".
emit_for() { # elf byte
    local elf="$1" byte="$2" W; W="$(mktemp -d)"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/f.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 40); do grep -q LISTENING "$W/f.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    local got; got=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n'); rm -rf "$W"
    [[ -n "$got" ]] && echo "$got" || echo "none"
}
# patch: replace the first occurrence of hex-pattern OLD with hex NEW (equal length) in a copy.
patch_img() { # src dst oldhex newhex
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src,dst,old,new=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
b=open(src,'rb').read(); o=bytes.fromhex(old); n=bytes.fromhex(new)
assert len(o)==len(n), "patch not equal-length"
i=b.find(o); assert i>=0, "pattern %s not found"%old
b=b[:i]+n+b[i+len(n):]
open(dst,'wb').write(b)
print(i)
PY
}
has_hex() { xxd -p "$1" | tr -d '\n' | grep -q "$2"; }

X=65; Y=254  # f_inc(X)=0x48, f_inc(Y)=0x05

# ---- CONTROL: the unpatched image shows the genuine input differential -----------------
cX=$(emit_for "$base" "$X"); cY=$(emit_for "$base" "$Y")
if [[ "$cX" == "de48ad" && "$cY" == "de05ad" && "$cX" != "$cY" ]]; then
    echo "control OK: in=0x41->$cX  in=0xfe->$cY (genuine input differential)"
else
    fail_test "control: expected de48ad / de05ad differential, got X=$cX Y=$cY"
fi

# ---- M-bake: RBR read -> literal (equal-length); differential must COLLAPSE -------------
mb="$work/bake.elf"
off=$(patch_img "$base" "$mb" "66baf803ec" "b020909090") || fail_test "M-bake: patch failed"
mX=$(emit_for "$mb" "$X"); mY=$(emit_for "$mb" "$Y")
# white-box: the RBR read->movzx->push window is gone.
if has_hex "$mb" "66baf803ec0fb6c050"; then fail_test "M-bake: RBR read-site still present after patch"; fi
# collapse: both inputs now emit f_inc(0x20)=0x27, independent of the fed byte.
if [[ "$mX" == "de27ad" && "$mY" == "de27ad" ]]; then
    echo "M-bake CAUGHT: read baked to literal -> in=0x41->$mX  in=0xfe->$mY (differential COLLAPSED to f(0x20)=0x27; read-site gone)"
elif [[ "$mX" != "$mY" ]]; then
    fail_test "M-bake: patched-X($mX) != patched-Y($mY) -- a HIDDEN input channel survives the bake (gate incomplete)"
else
    fail_test "M-bake: collapsed to $mX (want de27ad = f_inc(0x20))"
fi

# ---- M-xform: tamper the +7 transform (push 7 -> push 0); output != host f_inc ----------
mx="$work/xform.elf"
patch_img "$base" "$mx" "6807000000" "6800000000" >/dev/null || fail_test "M-xform: patch failed"
xX=$(emit_for "$mx" "$X")
# now f becomes echo: in=0x41 -> de41ad, NOT the golden de48ad (provenance/golden RED).
if [[ "$xX" == "de41ad" && "$xX" != "de48ad" ]]; then
    echo "M-xform CAUGHT: transform tampered -> in=0x41 emits $xX != golden de48ad (caught by provenance + golden, not collapse)"
else
    fail_test "M-xform: expected de41ad != golden de48ad, got $xX"
fi
# and the body no longer matches the pinned provenance (push 7 gone).
if has_hex "$mx" "6807000000"; then fail_test "M-xform: push-7 still present after tamper"; fi

# ---- M-poll: remove the poll back-edge (74 f7 -> 90 90); white-box poll pin gone --------
mp="$work/poll.elf"
patch_img "$base" "$mp" "a80174f7" "a8019090" >/dev/null || fail_test "M-poll: patch failed"
if has_hex "$mp" "66bafd03eca80174f7"; then fail_test "M-poll: poll back-edge (74 f7) still present after patch"; fi
echo "M-poll CAUGHT (white-box): poll back-edge 74 f7 removed -> the LSR poll no longer loops (gate's '74f7 exactly once' pin goes RED)"

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link30 mutation leg(s) failed."; exit 1; fi
echo "PASS: link30 mutation proof (trukfit / f3 device input): control shows the genuine input differential (de48ad vs de05ad); M-bake (equal-length RBR-read->literal) COLLAPSES the differential to f(0x20)=0x27 + removes the read-site; M-xform (push 7->0) emits the WRONG function (de41ad != golden de48ad) caught by provenance; M-poll (74 f7 -> nops) removes the LSR poll back-edge -- each forge CAUGHT, so the value-flow gate + differential bite."
exit 0
