#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link51 / cleave (COPY-ON-WRITE). Each mutation perturbs ONE piece of the
# COW machinery in cleave_ref.build_code(mut=...) and proves it non-vacuous: the control kernel grades GREEN (VW
# preserved, VR's private copy diverges only at the written word) AND passes assert_cleave; every mutant grades RED AND
# fails the white-box assert_cleave.
# Mutations:
#   M-noinstall   skip the alias install -> VW,VR stay identity+Supervisor -> the prober's CPL3 store #PFs terminally.
#   M-vrwritable  install VR WRITABLE (F|7) -> the store does NOT fault -> no COW -> it lands in the SHARED F -> VW reads
#                 the marker.
#   M-videntr     install VR -> a DISJOINT identity frame -> the prober reads an empty window, never F's payload.
#   M-cowshare    THE KEY (Codex's forge): the COW arm flips VR writable over the SHARED frame F (no private copy) -> the
#                 store corrupts F -> VW reads the marker. Proves the PRIVATE COPY, not the permission flip, is load-bearing.
#   M-nocopy      allocate F' but skip the rep movsd copy -> VR's copy holds garbage, not the preserved payload.
#   M-shortcopy   copy only the first few words, NOT the full 4 KiB page -> VR's DEEP word (offset 0xFFC, which the prober
#                 fills + reads back) is left uncopied -> RED. Output-forces the FULL-page copy (not just the byte-pin).
#   M-noremap     copy F->F' but don't remap VR -> the resumed store re-faults on the still-read-only VR.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/cleave_ref.py"
SEED="${CLEAVE_SEED:-90}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
PROBER="$work/prober.bin"; python3 "$REF" modcowprober "$PROBER"   # K=1, late-bound seed
qrun() { # kernel out timeout
    local kel="$1" out="$2" to="$3"; local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$SEED" --delay 1 --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    timeout "$to" qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$PROBER" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
gg() { python3 "$REF" gradecleave "$1" "$2" "$SEED" >/dev/null 2>&1; }   # GREEN?

# ---- CONTROL: genuine kernel must be GREEN AND pass assert_cleave (proves the harness bites) ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" kernelelf "$CK" none full)"
qrun "$CK" "$work/c" 40
if gg "$work/c" "$CKEND" && python3 "$REF" cleave "$CK"; then ok "control (genuine) GREEN -- VW preserved, VR's private copy diverges only at the written word + assert_cleave TRUE"
else fail_test "control kernel is NOT green -- the mutation harness does not bite"; fi

# ---- each mutation: RED AND assert_cleave FALSE ----
muts=( "noinstall:20:no alias install -> CPL3 store #PFs terminally"
       "vrwritable:20:VR installed writable -> no fault -> store hits the shared F -> VW reads the marker"
       "videntr:20:VR -> a disjoint identity frame -> reads an empty window"
       "cowshare:20:THE KEY -- flip VR writable over the SHARED F (no private copy) -> VW reads the marker"
       "nocopy:20:alloc F' but skip the copy -> VR's copy is garbage"
       "shortcopy:20:copy only the first words not the full 4 KiB page -> VR's DEEP word (offset 0xFFC) is uncopied"
       "noremap:25:copy but don't remap -> the resumed store re-faults on the read-only VR" )
for spec in "${muts[@]}"; do
    m="${spec%%:*}"; rest="${spec#*:}"; to="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" kernelelf "$MK" "$m" full)"
    if python3 "$REF" cleave "$MK" 2>/dev/null; then fail_test "M-$m: assert_cleave TRUE (mutant kept the COW motif?)"; continue; fi
    qrun "$MK" "$work/$m.o" "$to"
    if gg "$work/$m.o" "$MKEND"; then fail_test "M-$m GREEN (vacuous: $desc)"; else ok "M-$m RED + assert_cleave False ($desc)"; fi
done

echo "native-codegen link51 cleave MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link51 cleave MUTATION proof -- control GREEN; M-noinstall/vrwritable/videntr/cowshare/nocopy/shortcopy/noremap each RED + assert_cleave False; M-cowshare the KEY: the COW arm flips VR writable over the SHARED frame F (no private copy), so the store corrupts F and VW reads the marker -- proving the PRIVATE COPY, not the permission flip, is the load-bearing copy-on-write observable; M-shortcopy: copying only the first words leaves the DEEP word at offset 0xFFC uncopied -> RED, output-forcing the FULL-page copy; the divergence is forced WITHIN one execution on output)"
