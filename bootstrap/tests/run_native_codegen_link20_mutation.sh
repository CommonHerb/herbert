#!/usr/bin/env bash
# chosen (Link 20) MUTATION proof -- the "prove the paging / #PF-catch gate bites"
# forcing function. The link20 dual-substrate gate is only meaningful if a WRONG
# compiler would fail it. We prove that by mutating the compiler SOURCE at a unique
# anchor and re-emitting a green probe: each mutation must be CAUGHT (a wrong/absent
# byte under QEMU, a broken page-table hole, or a changed structural head).
#
# chosen's central claim is "the byte was produced by the CPU vectoring a genuine #PF
# (on the deliberately-unmapped neighbor) to my installed handler, after I really
# turned paging on." Mutations attack exactly that path. Most are BLACK-BOX (boot)
# caught -- a broken page-table hole or an un-enabled CR0.PG falls through to the 0xBB
# sentinel (wrong byte); a too-small IDT triple-faults (no byte). One (the CR4 clear)
# is BEHAVIORALLY INVISIBLE on both tested emulators (they hand off CR4.PAE=0) and is
# caught ONLY by the exact-head white-box gate -- the case that proves the head pin is
# load-bearing, mirroring the cr2-forge gap the cross-model review surfaced.
#
# SOVEREIGNTY (link 16): this proof is C-FREE. It NO LONGER re-emits through the C
# interpreter. Instead it runs each mutation through a genuine TWO-STAGE seed
# compile (the assay/link18 template): the committed C-free gen-1 seed compiles the
# (mutated) backend into a native gen-1' compiler ELF, and THAT compiler emits the
# probe. This is strictly MORE faithful than the prior C path: it runs the ACTUAL
# mutated compiler and checks the gate catches ITS output, so the proof's meaning
# ("a wrong compiler is caught") survives C's deletion intact. A retireable
# cross-check -- DEFAULT-ON when C is present, opt-OUT via LINK20_MUTATION_NO_C=1 --
# also re-emits each mutation via the C interpreter and asserts the native two-stage
# image is BYTE-IDENTICAL to the C image (substrate faithfulness, while C still
# exists); it retires WITH C at the switchover.
#
# QEMU-only (no losetup/sudo), gated behind KERNEL_CODEGEN_MUTATION=1 (or
# REQUIRE_EMU=1). Each anchor is asserted to occur EXACTLY ONCE, so a drifted anchor
# fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link20 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link20 mutation proof (no qemu)"; exit 0
fi

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK20_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link20-mutation ($1)"; fail=$((fail + 1)); }

# A branching handler: x=6*7=42 (==42 true) -> return 88. Exercises the paging-enable,
# the unmapped-neighbor #PF, the CR2/err/EIP wrapper, and a real compiled branch.
PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88
# the exact 118-byte structural head (only the 5 le32 address fields vary)
HRE='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}0f20e0254fffffff0f22e0b8[0-9a-f]{8}0f22d80f20c00d000000800f22c0eb008b0500f02f008b0500003000b0bbe9[0-9a-f]{8}0f20d03d0000300075ef833c240075e9817c24045b00100075df$'

emit_seq=0
# emit_via(compiler, outdir): the given native compiler ELF emits the PROBE. Sets
# $EMIT_IMG to the emitted image path, or "" if the compiler refused to emit.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-page\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >emit.out 2>&1 )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}
# assess(compiler) -> "GREEN" (valid image: exact head + single page-table hole at
# the neighbor + boot emits the golden byte) or "CAUGHT:<why>". The given native
# compiler ELF emits the probe; the #PF fault path is judged by the emitted byte on
# QEMU + the exact-head white-box gate + the page-table-hole grep.
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] && cp "$EMIT_IMG" "$compiler.graded" 2>/dev/null
    [[ -z "$EMIT_IMG" ]] && cp "$d/emit.out" "$compiler.emiterr" 2>/dev/null
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    # exact-head white-box gate (pins straight-line paging-enable -> unmapped touch ->
    # wrapper; catches boot-invisible head changes incl. the CR4 clear).
    local head; head=$(dd if="$EMIT_IMG" bs=1 skip=4108 count=118 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$head" =~ $HRE ]] || { echo "CAUGHT:head"; return; }
    # single page-table hole at the neighbor B (mapped 0x2ff003, hole 0, mapped 0x301003)
    local chx; chx=$(dd if="$EMIT_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    echo "$chx" | grep -q '03f02f000000000003103000' || { echo "CAUGHT:hole"; return; }
    : > "$d/e9"
    timeout 30 qemu-system-x86_64 -kernel "$EMIT_IMG" -debugcon file:"$d/e9" -display none \
        -no-reboot -serial none -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -cpu qemu64 -m 64M >/dev/null 2>&1
    local hx; hx=$(xxd -p "$d/e9" 2>/dev/null | tr -d '\n')
    if [[ "$hx" =~ ^de([0-9a-f][0-9a-f])ad$ ]]; then
        local b=$((16#${BASH_REMATCH[1]}))
        [[ "$b" == "$GOLDEN" ]] && { echo "GREEN"; return; }
        echo "CAUGHT:boot($b)"; return
    fi
    echo "CAUGHT:boot(noframe:$hx)"
}

# seed_compile(backend_src, outpath): the C-free seed compiles a (mutated) backend
# into a native gen-1' compiler ELF. Echoes "" if the backend did not compile.
seed_compile() {
    local src="$1" out="$2" d; d="$(mktemp -d "$tmp/sc.XXXX")"
    ( cd "$d" && "$SEED" < "$src" >/dev/null 2>/dev/null )
    # require a real ELF (magic 7f454c46), not merely a present a.out -- a truncated or
    # partial stage-1 output must not be accepted as a compiler (Codex link16 review).
    if [[ -f "$d/a.out" && "$(head -c4 "$d/a.out" | xxd -p | tr -d '\n')" == "7f454c46" ]]; then
        cp "$d/a.out" "$out"; chmod +x "$out"; echo "$out"; else echo ""; fi
}

# c_emit(backend_src, outdir): the RETIREABLE C path -- the C interpreter runs the
# (mutated) backend to emit the probe. Sets $C_IMG (or "" if no image).
C_IMG=""
c_emit() {
    local src="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-page\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$src" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then C_IMG="$d/a.out"; else C_IMG=""; fi
}

# control: the unmutated compiler is the SEED itself (the gen-1 fixpoint); it must
# pass head + hole + boot via the #PF fault path C-FREE.
ctrl=$(assess "$SEED")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated seed compiler emits golden=$GOLDEN via the #PF fault path C-free"; pass=$((pass+1));
else echo "FAIL control: unmutated seed compiler did not pass cleanly: $ctrl"; fail=$((fail+1)); fi
[[ "$XCHECK" == "1" ]] && echo "  (retireable C cross-check ON: each mutation's native two-stage image is asserted byte-identical to the C image)"

# mutate(name, old, new [, expect_no_image_diag]): old must occur exactly once; the
# mutant must be CAUGHT. The C-free seed compiles the mutated backend -> gen1'
# compiler, which emits the probe (two-stage). Optionally cross-checked byte-identical
# to the C image. If expect_no_image_diag is given, a "no-image" verdict is only a
# genuine catch when the mutated compiler emits THAT reject diagnostic (its own
# layout invariant), NOT any incidental empty image -- closing the no-image catch-all.
mutate() {
    local name="$1" old="$2" new="$3" expect_no_image_diag="${4:-}"
    local n; n=$(python3 - "$backend" "$old" <<'PY'
import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))
PY
)
    if [[ "$n" != "1" ]]; then fail_test "$name: anchor occurs $n times (want 1) -- anchor drifted"; return; fi
    local mut="$tmp/mut.$name.herb"
    python3 - "$backend" "$old" "$new" "$mut" <<'PY'
import sys
open(sys.argv[4],"w").write(open(sys.argv[1]).read().replace(sys.argv[2],sys.argv[3],1))
PY
    # two-stage: seed compiles the mutated backend into a native gen1' compiler.
    local gen1x; gen1x=$(seed_compile "$mut" "$tmp/gen1x.$name")
    if [[ -z "$gen1x" ]]; then fail_test "$name: seed could not compile the mutated backend (two-stage stage-1 failed)"; return; fi
    local v; v=$(assess "$gen1x")
    if [[ "$v" != CAUGHT:* ]]; then
        fail_test "$name: mutant escaped ALL gates (verdict=$v) -- the gate does NOT bite"; return
    fi
    # no-image pin: a "no-image" catch must be the mutated compiler's OWN reject
    # diagnostic, not an incidental empty image.
    if [[ -n "$expect_no_image_diag" ]]; then
        if [[ "$v" != "CAUGHT:no-image" ]]; then
            fail_test "$name: expected a no-image catch ($expect_no_image_diag) but got $v -- a layout-invariant mutation must refuse to emit"; return
        fi
        # bind the diagnostic to the SAME run assess() graded as no-image (its captured
        # output, saved to $gen1x.emiterr) -- NOT a re-run (Codex link16 review).
        local diag=""; [[ -f "$gen1x.emiterr" ]] && diag="$(cat "$gen1x.emiterr")"
        if [[ "$diag" != *"$expect_no_image_diag"* ]]; then
            fail_test "$name: no-image but NOT the expected reject '$expect_no_image_diag' (got: $(echo "$diag" | tr '\n' ' ')) -- a non-load-bearing empty image"; return
        fi
    elif [[ "$v" == "CAUGHT:no-image" ]]; then
        fail_test "$name: unexpected no-image catch for a mutation that should emit a wrong image"; return
    fi
    # retireable faithfulness: the native two-stage image == the C image, byte-for-byte
    # (or both produce no image). Confirms the C->seed substrate swap is loss-free.
    if [[ "$XCHECK" == "1" ]]; then
        # compare the EXACT image assess() graded (saved as $gen1x.graded), not a re-emit, so a
        # stateful/nondeterministic compiler cannot grade image A then compare a clean image B
        # (Codex link16 review -- bind the assessed artifact itself).
        local nimg=""; [[ -f "$gen1x.graded" ]] && nimg="$gen1x.graded"
        c_emit "$mut" "$tmp/c.$name"; local cimg="$C_IMG"
        if [[ -z "$nimg" && -z "$cimg" ]]; then :   # both no-image -- faithful
        elif [[ -n "$nimg" && -n "$cimg" ]] && cmp -s "$nimg" "$cimg"; then :   # byte-identical -- faithful
        else fail_test "$name: native two-stage image != C image (substrate faithfulness broken: nat=${nimg:-<none>} c=${cimg:-<none>})"; return; fi
    fi
    echo "PASS mutation $name: $v"; pass=$((pass+1))
}

# M1: move the page-table hole off the neighbor B (768 -> 769). B (0x300000) is now
# MAPPED, so TOUCH-B does not fault -> falls through to the 0xBB SENTINEL -> wrong byte.
# Caught by the hole grep AND by boot. Proves the hole-at-B is load-bearing.
mutate hole_off_neighbor \
'    if i == 768:' \
'    if i == 769:'

# M2: do not enable CR0.PG (the 0x80 high byte of `or eax,0x80000000` -> 0). Paging never
# turns on, neither touch faults -> SENTINEL -> wrong byte. Caught by the head gate AND
# boot. Proves the paging-enable is load-bearing (not the bootloader's state).
# (Anchor extended through mov cr0,eax + jmp $+2 + TOUCH-A's `139`=8b so it stays unique:
# the multiboot32-store head shares this CR0.PG-enable block but is followed by `187`=mov ebx.)
mutate no_paging_enable \
'    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 128)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 192)
    do append(buf, 235)
    do append(buf, 0)
    do append(buf, 139)' \
'    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 192)
    do append(buf, 235)
    do append(buf, 0)
    do append(buf, 139)'

# M3: neuter the CR4 clear (`and eax,0xFFFFFF4F` -> `and eax,0xFFFFFFFF`, a no-op AND).
# BEHAVIORALLY INVISIBLE on both tested emulators (they hand off CR4.PAE=0, so paging
# still works and the golden byte still emits) -- caught ONLY by the exact-head white-box
# gate. This is the boot-invisible case that proves the head pin (and the CR4-clear
# robustness against an undefined-CR4 substrate) is load-bearing, not dead defensive code.
# (Anchor extended from the `and 0xFFFFFF4F` through the shared paging-enable block to
# TOUCH-A's `139`=8b so it stays unique vs the multiboot32-store head, which shares the
# identical CR4-clear + CR3 + CR0.PG block but is followed by `187`=mov ebx, not TOUCH-A.)
mutate cr4_clear_noop \
'    do append(buf, 37)
    do append(buf, 79)
    do append(buf, 255)
    do append(buf, 255)
    do append(buf, 255)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 224)
    do append(buf, 184)
    buf = nc_append_le32(buf, pd_vaddr)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 216)
    do append(buf, 15)
    do append(buf, 32)
    do append(buf, 192)
    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 128)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 192)
    do append(buf, 235)
    do append(buf, 0)
    do append(buf, 139)' \
'    do append(buf, 37)
    do append(buf, 255)
    do append(buf, 255)
    do append(buf, 255)
    do append(buf, 255)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 224)
    do append(buf, 184)
    buf = nc_append_le32(buf, pd_vaddr)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 216)
    do append(buf, 15)
    do append(buf, 32)
    do append(buf, 192)
    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 128)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 192)
    do append(buf, 235)
    do append(buf, 0)
    do append(buf, 139)'

# M4: shrink the IDTR limit (0x77=119 -> 100), so vector 14 (#PF, bytes 112..119) is no
# longer covered. The #PF cannot be delivered -> #GP -> double -> triple fault -> no byte.
# Caught by boot. Proves the 15-entry IDT (vs zonday's 1-entry) is load-bearing.
mutate idtr_limit_too_small \
'    do append(buf, 119)
    do append(buf, 0)
    buf = nc_append_le32(buf, idt_vaddr)' \
'    do append(buf, 100)
    do append(buf, 0)
    buf = nc_append_le32(buf, idt_vaddr)'

# M5: corrupt the wrapper CR2 check (expect B+1). A genuine #PF on B sets CR2=0x300000,
# so the check now MISMATCHES -> jne sentinel -> 0xBB. Caught by the head gate AND boot.
# Proves "the byte came via a fault on THE RIGHT page" is load-bearing.
mutate wrapper_cr2_check \
'    do append(buf, 61)
    buf = nc_append_le32(buf, 3145728)' \
'    do append(buf, 61)
    buf = nc_append_le32(buf, 3145729)'

# M6: corrupt the wrapper faulting-EIP check (expect TOUCH-B EIP+1). A genuine #PF pushes
# the real TOUCH-B EIP (0x10005b), so the check MISMATCHES -> jne sentinel -> 0xBB. Caught
# by the head gate AND boot. Proves the fault originated at the intended instruction.
mutate wrapper_eip_check \
'    buf = nc_append_le32(buf, 1048667)' \
'    buf = nc_append_le32(buf, 1048668)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link20-mutation check(s) failed."; exit 1; fi
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link20 mutation proof ($pass checks: control emits golden=$GOLDEN via the #PF fault path C-FREE; 6 mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- page-table-hole-off-neighbor and CR0.PG-not-enabled fall to the 0xBB sentinel; the IDTR-limit shrink triple-faults (no byte); the CR2 and faulting-EIP wrapper-check corruptions fall to the sentinel; and the boot-INVISIBLE CR4-clear neutering is caught by the exact-head template gate, which pins straight-line paging-enable -> unmapped-neighbor touch -> #PF wrapper$xc)"
exit 0
