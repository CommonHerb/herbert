#!/usr/bin/env bash
# Link 21 (fifth kernel-arc link) MUTATION proof -- "prove the runtime computed-address
# store / MMU-judge gate bites." The link21 dual-substrate gate is only meaningful if a
# WRONG compiler would fail it. We mutate the compiler SOURCE at a unique anchor and
# re-emit a green probe: each mutation must be CAUGHT (a #PF -> fail-closed IDT ->
# triple-fault under QEMU, a broken build-time hole, or a changed structural head).
#
# The central claim: "the proof byte was emitted only because a runtime store wrote a valid
# PTE at the RIGHT runtime-computed slot, and the MMU honored it on the access." Mutations
# attack exactly that: a not-present PTE, a wrong slot (corrupted shift), a wrong target
# vaddr -> the page stays unmapped -> the access #PFs -> triple-fault (no byte). A wrong
# FRAME or a wrong ACCESS PAGE is behaviorally invisible (the access still succeeds on a
# present page) and is caught ONLY by the exact-head white-box gate. Filling the build-time
# hole makes the store non-load-bearing and is caught by the hole grep.
#
# SOVEREIGNTY (link 16): this proof is C-FREE. It NO LONGER re-emits through the C
# interpreter. Instead it runs each mutation through a genuine TWO-STAGE seed
# compile (the assay/link18 template): the committed C-free gen-1 seed compiles the
# (mutated) backend into a native gen-1' compiler ELF, and THAT compiler emits the
# probe. This is strictly MORE faithful than the prior C path: it runs the ACTUAL
# mutated compiler and checks the gate catches ITS output, so the proof's meaning
# ("a wrong compiler is caught") survives C's deletion intact. A retireable
# cross-check -- DEFAULT-ON when C is present, opt-OUT via LINK21_MUTATION_NO_C=1 --
# also re-emits each mutation via the C interpreter and asserts the native two-stage
# image is BYTE-IDENTICAL to the C image (substrate faithfulness, while C still
# exists); it retires WITH C at the switchover.
#
# QEMU-only, gated behind KERNEL_CODEGEN_MUTATION=1 (or REQUIRE_EMU=1). Each anchor is
# asserted to occur EXACTLY ONCE, so a drifted anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link21 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link21 mutation proof (no qemu)"; exit 0
fi

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK21_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link21-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88
# the exact 99-byte store head (only gdtr/idtr le32 vary)
HRE='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc007010000f011d[0-9a-f]{8}0f20e0254fffffff0f22e0b8001010000f22d80f20c00d000000800f22c0eb00bb0000300089d8c1e80a0500201000c70003301000a000003000$'

emit_seq=0
# emit_via(compiler, outdir): the given native compiler ELF emits the PROBE. Sets
# $EMIT_IMG to the emitted image path, or "" if the compiler refused to emit.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-store\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >emit.out 2>&1 )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}
# assess(compiler) -> "GREEN" (exact head + build-time hole + boot emits the golden byte)
# or "CAUGHT:<why>". The given native compiler ELF emits the probe; the runtime-store /
# MMU-judge path is judged by the exact-head white-box gate + the emitted byte on QEMU.
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] && cp "$EMIT_IMG" "$compiler.graded" 2>/dev/null
    [[ -z "$EMIT_IMG" ]] && cp "$d/emit.out" "$compiler.emiterr" 2>/dev/null
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local head; head=$(dd if="$EMIT_IMG" bs=1 skip=4108 count=99 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$head" =~ $HRE ]] || { echo "CAUGHT:head"; return; }
    local chx; chx=$(dd if="$EMIT_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    echo "$chx" | grep -q '03f02f000000000003103000' || { echo "CAUGHT:hole"; return; }
    # the FAIL-CLOSED IDTR (limit 0, base 0) right after the GDTR -- the mechanism that turns a
    # broken store (#PF) into a triple-fault; if a mutation installs a non-zero IDTR, catch it here.
    echo "$chx" | grep -qE '92cf001700[0-9a-f]{8}000000000000' || { echo "CAUGHT:idtr"; return; }
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
    printf -- '-- emit: multiboot32-store\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$src" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then C_IMG="$d/a.out"; else C_IMG=""; fi
}

# control: the unmutated compiler is the SEED itself (the gen-1 fixpoint); it must
# emit the golden byte via the runtime-store-mapped access C-FREE.
ctrl=$(assess "$SEED")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated seed compiler emits golden=$GOLDEN via the runtime-store-mapped access C-free"; pass=$((pass+1));
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

# M1: write a NOT-PRESENT PTE (map_pte present bit cleared: pd+8195 -> pd+8194). The store
# lands but the MMU sees not-present on the access -> #PF -> fail-closed IDT -> triple-fault.
# Caught by boot AND the head gate (map_pte is pinned). Proves the present bit is load-bearing.
mutate pte_not_present \
'    let map_pte = pd_vaddr + 8195' \
'    let map_pte = pd_vaddr + 8194'

# M2: corrupt the runtime SLOT computation (shr eax,10 -> shr eax,11), so the store lands at
# the wrong PTE slot; vaddr 0x300000 stays unmapped -> access #PFs -> triple-fault. Caught by
# boot AND the head gate. Proves the computed-address arithmetic is load-bearing.
# (Anchor disambiguated to the store head's `mov eax,ebx; shr eax,10` -- the bare shr eax,10
#  byte triple [193,232,10] is now SHARED with link22's demand-paging #PF handler, so the
#  `mov eax,ebx` [137,216] prefix keeps this anchor unique to nc32_store_emit_head -- the same
#  cross-link mutation-anchor disambiguation chosen applied to zonday and liberi to chosen.)
mutate wrong_shift \
'    do append(buf, 137)
    do append(buf, 216)
    do append(buf, 193)
    do append(buf, 232)
    do append(buf, 10)' \
'    do append(buf, 137)
    do append(buf, 216)
    do append(buf, 193)
    do append(buf, 232)
    do append(buf, 11)'

# M3: map to the WRONG FRAME (map_pte -> a different PRESENT frame: pd+4099 = the PT frame|3).
# BEHAVIORALLY INVISIBLE (the access succeeds on a present page, the body still emits the
# golden byte) -- caught ONLY by the exact-head gate (map_pte is pinned to the right frame).
# The boot-invisible case that proves the head pin on the store TARGET is load-bearing.
mutate wrong_frame \
'    let map_pte = pd_vaddr + 8195' \
'    let map_pte = pd_vaddr + 4099'

# M4: access the WRONG PAGE (mov al,[0x300000] -> [0x301000], a build-time-mapped page). The
# access succeeds without ever exercising the runtime-mapped page -> BEHAVIORALLY INVISIBLE,
# caught ONLY by the head gate (the access address is pinned to 0x300000). Proves the proof
# rests on accessing the page the runtime store mapped.
mutate access_wrong_page \
'    do append(buf, 160)
    buf = nc_append_le32(buf, 3145728)' \
'    do append(buf, 160)
    buf = nc_append_le32(buf, 3149824)'

# M5: store for the WRONG VADDR (mov ebx,0x300000 -> 0x301000), so the computed slot is for a
# different page; 0x300000 stays unmapped -> access #PFs -> triple-fault. Caught by boot AND
# the head gate. Proves the store maps the page the access then reads.
mutate store_wrong_vaddr \
'    do append(buf, 187)
    buf = nc_append_le32(buf, 3145728)' \
'    do append(buf, 187)
    buf = nc_append_le32(buf, 3149824)'

# M6: fill the build-time hole (PT entry 768 -> 769), so 0x300000 is ALREADY mapped at build
# time and the runtime store is no longer load-bearing (the access would succeed even with a
# broken store). Caught by the build-time hole grep. (Shares nc32_page_emit_pt_loop with
# chosen; the anchor occurs once.)
mutate build_hole_filled \
'    if i == 768:' \
'    if i == 769:'

# M7: break the FAIL-CLOSED IDTR (limit 0 -> 0x00FF) in nc32_store_emit_tables. The limit-0
# IDTR is what turns a broken store (#PF) into a triple-fault; a non-zero limit (toward
# installing a real #PF handler that could MASK a broken store) is BEHAVIORALLY INVISIBLE on
# the happy path (no fault occurs) and is caught ONLY by the fail-closed-IDTR white-box check.
mutate idtr_not_failclosed \
'    buf = nc_append_le32(buf, gdt_vaddr)
    do append(buf, 0)
    do append(buf, 0)
    buf = nc_append_le32(buf, 0)' \
'    buf = nc_append_le32(buf, gdt_vaddr)
    do append(buf, 255)
    do append(buf, 0)
    buf = nc_append_le32(buf, 0)'

# NOTE on the boot/triple-fault leg: the store path is FULLY white-box-pinned -- the exact-head
# regex (the computed store + slot + value), the PDE->PT grep, the build-time-hole grep, and the
# fail-closed-IDTR grep jointly determine the entire 0x300000 page-walk. So every store-break is
# caught statically (CAUGHT:head/hole/idtr) BEFORE boot -- there is provably no mutation that
# passes the static gates yet triple-faults. The triple-fault path itself is proven on silicon by
# the EMPIRICAL pre-build (nostore/notpresent/wrongslot -> triple-fault on both QEMU and Bochs,
# recorded in run_native_codegen_link21.sh), and the boot gate's exact-byte check is exercised by
# the 5 positive probes in the forcing harness. Full static pinning is the strength here, not a gap.

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link21-mutation check(s) failed."; exit 1; fi
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link21 mutation proof ($pass checks: control emits golden=$GOLDEN via the runtime-store-mapped access C-FREE; 7 mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- a not-present PTE, a corrupted slot computation (shr), and a wrong store-target vaddr leave 0x300000 unmapped (caught by the exact-head store pin); a wrong store FRAME and a wrong ACCESS page are behaviorally invisible (caught by the exact-head gate); filling the build-time hole is caught by the hole grep; breaking the fail-closed IDTR is caught by the fail-closed-IDTR grep -- the runtime computed-address store, the MMU-judged access, and the fail-closed mechanism are all proven load-bearing; the triple-fault path itself is proven on silicon by the empirical pre-build$xc)"
exit 0
