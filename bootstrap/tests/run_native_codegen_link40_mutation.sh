#!/usr/bin/env bash
# Native-codegen Link 40 / holler (link 24) MUTATION proof (held-back; CI-only, not in `make test`). Proves
# every do_write design choice is NON-VACUOUS: each mutation of the SYS_WRITE bounds-check / relay either makes
# the kernel LEAK (the confused-deputy is real) or fails a grader, AND the master prefix BYTE-PIN (link40 gate A,
# cmp emitted-kernel vs holler_ref.build_elf()) catches it structurally. Mutations are KERNEL-side (the do_write
# arm lives in the byte-pinned prefix); the modules are hand-crafted (the COMPILED module is always in-bounds).
#
#   M-nobounds  + HOWR  -> kernel LEAKS code[0:8] (gradeleak GREEN) AND gradehostwrite FLIPS RED   [whole check]
#   M-noptrlo   + HOWR  -> ptr<alloc_lo branch dropped -> ENTRY leaks (gradeleak GREEN)            [ptr<lo jb]
#   M-noendhi   + STRD  -> ptr+len>alloc_hi branch dropped -> straddle relays past page (gradenoleak RED) [end>hi ja]
#   M-fakewrite + WRITE -> relay emits a CONST not [ecx] -> gradewrite RED                         [relay source; subsumes srcswap]
#   M-norelay   + WRITE -> relay loop dropped -> gradewrite RED                                    [relay loop; subsumes loopguard]
#   M-bakebounds+ HOWR  -> bounds baked as VACUOUS immediates (esi=0,edi=0xFFFFFFFF) not loaded BY VALUE -> the
#                          kernel-ptr write passes the broken check -> LEAK (gradeleak GREEN); proves the
#                          mov esi,[alloc_lo]/mov edi,[alloc_hi] BY-VALUE load is load-bearing.
#   M-nocarry           -> a wrapping ptr+len lands unmapped -> CPL0 #PF -> RPL0 panic (a DoS, NOT a clean leak);
#                          the carry check is KEPT and pinned by the byte-pin (a crash, not exfil -- documented).
#   STRUCTURAL BYTE-PIN: every mutated kernel differs from holler_ref.build_elf() -> link40 gate A is RED. This
#     is what catches the byte-only mutations the behavioral knobs subsume: M-signedjcc (jb/ja -> jl/jg; for the
#     <2 GiB alloc addresses this is behaviorally VACUOUS, so byte-pin-only by construction), and the
#     reorder/off-by-one class. signedjcc/srcswap/loopguard are do_write byte changes -> all caught here.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
REF="$script_dir/holler_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing holler_ref.py $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
no() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
FXD=60; FXH=3c

# reference (benign) kernel + the master byte-pin oracle
REFK="$work/ref.elf"; python3 "$REF" cleanelf "$REFK"
# hand-crafted modules
MHOWR="$work/howr.bin"; python3 "$REF" module HOWR "$MHOWR"
MSTRD="$work/strd.bin"; python3 "$REF" module STRD "$MSTRD"
MWRITE="$work/write.bin"; python3 "$REF" module WRITE "$MWRITE"

# build every mutated kernel + its kend
for m in nobounds noptrlo noendhi fakewrite norelay bakebounds nocarry; do
    python3 "$REF" mutate "$m" "$work/k_$m.elf"
    eval "KEND_$m=\$(python3 \"\$REF\" kend $m)"
done
KEND_ben="$(python3 "$REF" kend -)"

# ---- STRUCTURAL BYTE-PIN: every do_write mutation changes the prefix -> differs from build_elf() ----
echo "=== master byte-pin (link40 gate A) catches every do_write mutation structurally ==="
for m in nobounds noptrlo noendhi fakewrite norelay bakebounds nocarry; do
    if cmp -s "$work/k_$m.elf" "$REFK"; then no "M-$m kernel is byte-IDENTICAL to build_elf() (byte-pin would MISS it)"
    else ok "M-$m kernel differs from build_elf() (master byte-pin RED)"; fi
done

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then no "QEMU required (KERNEL_CODEGEN_REQUIRE_EMU=1) but not found"; else echo "  SKIP behavioral mutation boots: qemu-system-x86_64 not found"; fi
    echo "native-codegen link40 mutation: pass=$pass fail=$fail"
    [[ "$fail" -eq 0 ]] || exit 1
    echo "PASS: stack/native_compile_fragment.herb (native-codegen link40 mutation, byte-pin only)"
    exit 0
fi

qemu_feed() { # kelf mod out fedbyte
    local kelf="$1" mod="$2" out="$3" byte="$4"
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$byte" --hold 6 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
qemu_noin() { # kelf mod out
    timeout 60 qemu-system-x86_64 -kernel "$1" -initrd "$2" -debugcon file:"$3" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -serial null -monitor none -m 64M >/dev/null 2>&1 || true
}

echo "=== behavioral mutation bites (each must go RED / LEAK) ==="
# M-nobounds: the make-or-break leak (whole check dropped)
qemu_noin "$work/k_nobounds.elf" "$MHOWR" "$work/nb.bin"
if python3 "$REF" gradeleak "$work/nb.bin" "$KEND_nobounds" >/dev/null 2>&1; then ok "M-nobounds LEAKS kernel code[0:8] (confused-deputy is REAL)"; else no "M-nobounds should LEAK -> $(python3 "$REF" gradeleak "$work/nb.bin" "$KEND_nobounds" 2>&1 | tr '\n' ';')"; fi
if python3 "$REF" gradehostwrite "$work/nb.bin" "$KEND_nobounds" >/dev/null 2>&1; then no "M-nobounds should FLIP gradehostwrite RED but it passed"; else ok "M-nobounds FLIPS gradehostwrite RED (the benign-reject expectation bites)"; fi
# M-noptrlo: ptr<alloc_lo branch dropped -> ENTRY (kernel code) leaks
qemu_noin "$work/k_noptrlo.elf" "$MHOWR" "$work/np.bin"
if python3 "$REF" gradeleak "$work/np.bin" "$KEND_noptrlo" >/dev/null 2>&1; then ok "M-noptrlo LEAKS via the ptr<alloc_lo arm (the jb is load-bearing)"; else no "M-noptrlo should LEAK -> $(python3 "$REF" gradeleak "$work/np.bin" "$KEND_noptrlo" 2>&1 | tr '\n' ';')"; fi
# M-noendhi: ptr+len>alloc_hi branch dropped -> straddle relays past the page
qemu_noin "$work/k_noendhi.elf" "$MSTRD" "$work/ne.bin"
if python3 "$REF" gradenoleak "$work/ne.bin" "$KEND_noendhi" >/dev/null 2>&1; then no "M-noendhi should LEAK past the page (gradenoleak RED) but it passed"; else ok "M-noendhi relays past alloc_hi (the end>hi ja is load-bearing; gradenoleak RED)"; fi
# M-fakewrite / M-norelay / M-bakebounds: against the benign hand-crafted WRITE module -> gradewrite RED
qemu_feed "$work/k_fakewrite.elf" "$MWRITE" "$work/fw.bin" "$FXD"
if python3 "$REF" gradewrite "$work/fw.bin" "$KEND_fakewrite" "$FXH" >/dev/null 2>&1; then no "M-fakewrite should be RED but passed"; else ok "M-fakewrite -> gradewrite RED (relays a const, not [ecx]; subsumes srcswap)"; fi
qemu_feed "$work/k_norelay.elf" "$MWRITE" "$work/nr.bin" "$FXD"
if python3 "$REF" gradewrite "$work/nr.bin" "$KEND_norelay" "$FXH" >/dev/null 2>&1; then no "M-norelay should be RED but passed"; else ok "M-norelay -> gradewrite RED (no bytes relayed; subsumes loopguard)"; fi
# M-bakebounds bakes VACUOUS bounds (esi=0, edi=0xFFFFFFFF) -> the check always passes -> a HOSTILE kernel-ptr
# write LEAKS (proving the by-value [alloc_lo]/[alloc_hi] load is load-bearing; a benign in-page write would
# wrongly pass too, so the leak on HOWR is the genuine bite).
qemu_noin "$work/k_bakebounds.elf" "$MHOWR" "$work/bb.bin"
if python3 "$REF" gradeleak "$work/bb.bin" "$KEND_bakebounds" >/dev/null 2>&1; then ok "M-bakebounds LEAKS via vacuous baked bounds on HOWR (the BY-VALUE alloc_lo/alloc_hi load is load-bearing)"; else no "M-bakebounds should LEAK (vacuous baked bounds) -> $(python3 "$REF" gradeleak "$work/bb.bin" "$KEND_bakebounds" 2>&1 | tr '\n' ';')"; fi
# M-nocarry: documented -- a wrapping ptr+len is a CPL0 #PF DoS, not a clean leak; benign still works + byte-pinned.
qemu_feed "$work/k_nocarry.elf" "$MWRITE" "$work/nc.bin" "$FXD"
if python3 "$REF" gradewrite "$work/nc.bin" "$KEND_nocarry" "$FXH" >/dev/null 2>&1; then ok "M-nocarry: benign WRITE still GREEN (carry arm only matters on a wrapping ptr+len -> #PF DoS, byte-pinned not exfil)"; else ok "M-nocarry benign WRITE altered (carry arm change is byte-pinned regardless)"; fi

echo "native-codegen link40 mutation: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link40 mutation)"
