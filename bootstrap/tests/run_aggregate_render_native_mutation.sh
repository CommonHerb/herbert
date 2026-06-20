#!/usr/bin/env bash
#
# Mutation / bite proof for the aggregate (flat int/bool tuple + string/nested)
# renderer (garland/filigree, graded C-free by muster's enduring leg).
#
# Proves the renderer is LOAD-BEARING and CORRECT: each mutation changes ONE
# render-specific byte/immediate in the back end, recompiles the held-back probe,
# and asserts the rendered tuple DIVERGES from the correct canonical form. If any
# mutation left the output unchanged, the gate would be testing nothing.
#
# SOVEREIGNTY (link 15 / assay): this proof is C-FREE. It NO LONGER renders the
# mutated backend through the C interpreter. Instead it runs a genuine TWO-STAGE
# seed compile: the committed C-free gen-1 seed compiles the (mutated) backend
# into a native gen-1' compiler ELF, and THAT compiler emits the probe -- so the
# proof runs the ACTUAL mutated compiler and checks its render diverges, and its
# meaning ("a wrong renderer is caught") survives C's deletion intact. A retireable
# cross-check -- DEFAULT-ON when C is present, opt-OUT via AGGREGATE_RENDER_MUTATION_NO_C=1 --
# also emits each mutation via the C interpreter and asserts the native two-stage
# image is BYTE-IDENTICAL to the C image (substrate faithfulness while C exists);
# it retires WITH C at the switchover. The unmutated CONTROL (the seed itself, the
# gen-1 fixpoint) is asserted to render CORRECTLY first (non-vacuity).
#
# Each mutation is length-preserving (a byte value, or one immediate), so the
# emitted code still passes the ERR-418 layout check and renders -- the failure
# is a WRONG render, not a broken compile. Each mutation is also asserted to have
# actually changed the source (a no-op mutation is a silent blind spot).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: aggregate-render mutation proof ($1)"; exit 1; }

[[ -f "$backend" ]] || fail "missing backend $backend"

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/gen1" || fail "could not acquire the C-free gen-1 seed"
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${AGGREGATE_RENDER_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

probe="$tmp/probe.herb"
cat >"$probe" <<'HERB'
func main():
    let a = 6 * 7
    let big = 0 - 1
    let lt = a < 10
    let gt = a > 10
    return (a, big, lt, gt, 0, 255)
end
HERB
correct='(42, 18446744073709551615, false, true, 0, 255)'

# link12: a STRING (carrying a newline -> the \n escape) followed by a trailing int,
# so a wrong quote/escape OR a wrong string width (the int would then read the
# string's length word) makes the render diverge.
sprobe="$tmp/sprobe.herb"
cat >"$sprobe" <<'HERB'
func main():
    let b = new_buffer()
    do append(b, 10)
    let s = freeze(b)
    return (s, 99)
end
HERB
scorrect='("\n", 99)'

# emit_with(compiler, probe, out_image): the given native compiler ELF emits the
# probe; copies the emitted image to out_image (empty file if it did not emit).
emit_with() {
    local compiler="$1" pr="$2" out="$3" wd; wd="$(mktemp -d "$tmp/e.XXXX")"
    ( cd "$wd" && "$compiler" <"$pr" >/dev/null 2>/dev/null )
    if [[ -f "$wd/a.out" ]]; then cp "$wd/a.out" "$out"; chmod +x "$out"; else : >"$out"; fi
}

# render_of(image): runs the emitted image and echoes its rendered line (empty if
# the image is empty / did not run).
render_of() {
    local img="$1"
    [[ -s "$img" ]] || { echo ""; return 0; }
    chmod +x "$img"
    "$img" 2>/dev/null | tr -d '\n'
}

# seed_compile(backend_src, out_compiler): the C-free seed compiles a (mutated)
# backend into a native gen-1' compiler ELF. Echoes "" if it did not compile.
seed_compile() {
    local src="$1" out="$2" wd; wd="$(mktemp -d "$tmp/sc.XXXX")"
    ( cd "$wd" && "$SEED" <"$src" >/dev/null 2>/dev/null )
    if [[ -f "$wd/a.out" ]]; then cp "$wd/a.out" "$out"; chmod +x "$out"; echo "$out"; else echo ""; fi
}

# render_with_compiler(compiler, probe): emit the probe with the compiler, echo render.
render_with_compiler() {
    local compiler="$1" pr="$2" img; img="$(mktemp "$tmp/img.XXXX")"
    emit_with "$compiler" "$pr" "$img"
    render_of "$img"
}

# Replace the FIRST `old` with `new` strictly INSIDE `func fname(...)` (up to its
# closing `end`), so a render byte that also appears elsewhere is mutated only at
# the intended render site. Asserts exactly-one replacement happened.
mutate_in_func() {
    local src="$1" dst="$2" fname="$3" old="$4" new="$5"
    awk -v fn="$fname" -v old="$old" -v new="$new" '
        BEGIN { infn=0; done=0; changed=0 }
        {
            if (!infn && $0 ~ ("^func " fn "\\(")) { infn=1 }
            if (infn && !done) {
                p = index($0, old)
                if (p > 0) {
                    $0 = substr($0, 1, p-1) new substr($0, p+length(old))
                    done=1; changed=1
                }
            }
            if (infn && $0 ~ /^end$/) { infn=0 }
            print
        }
        END { if (!changed) exit 3 }
    ' "$src" >"$dst" || return 1
    cmp -s "$src" "$dst" && return 1   # no change == vacuous
    return 0
}

# --- CONTROL: the unmutated seed compiler renders BOTH probes CORRECTLY (C-free) -
ctl="$(render_with_compiler "$SEED" "$probe")"
[[ "$ctl" == "$correct" ]] || fail "CONTROL: unmutated seed did not render the correct flat tuple (got [$ctl])"
sctl="$(render_with_compiler "$SEED" "$sprobe")"
[[ "$sctl" == "$scorrect" ]] || fail "CONTROL: unmutated seed did not render the correct string tuple (got [$sctl])"
[[ "$XCHECK" == "1" ]] && echo "  (retireable C cross-check ON: each mutation's native two-stage image is asserted byte-identical to the C image)"

# bite NAME FNAME OLD NEW PROBE CORRECT : mutate one byte/immediate in FNAME, build a
# native gen-1' compiler from the mutated backend (two-stage, C-free), render PROBE
# with it, assert the output DIVERGES from CORRECT. Optionally assert the native
# two-stage image is byte-identical to the C image (retireable faithfulness).
# bite NAME FNAME OLD NEW PROBE CORRECT [EXPECT_WRONG] : if EXPECT_WRONG is given, the
# mutated render must equal it EXACTLY (pins a mutation whose source anchor is not
# unique-in-func -- e.g. M-strq, whose `append(buf, 34)` opening quote is the first of
# several 34s -- so a future refactor that shifted first-match to a different site is
# caught, not silently testing the wrong byte).
bite() {
    local name="$1" fname="$2" old="$3" new="$4" pr="$5" want="$6" expect_wrong="${7:-}"
    local mb="$tmp/mut.$name.herb"
    mutate_in_func "$backend" "$mb" "$fname" "$old" "$new" || fail "$name: mutation did not apply uniquely in $fname (vacuous)"
    local gen1x; gen1x=$(seed_compile "$mb" "$tmp/gen1x.$name")
    [[ -n "$gen1x" ]] || fail "$name: seed could not compile the mutated backend (two-stage stage-1 failed)"
    local nimg="$tmp/nat.$name.img"; emit_with "$gen1x" "$pr" "$nimg"
    # these mutations are length-preserving -- the mutated compiler MUST still emit a
    # (wrong) image; a NO-image / empty render is a broken compile, NOT a valid
    # divergence, and must FAIL rather than vacuously count as "diverged".
    [[ -s "$nimg" ]] || fail "$name: mutated compiler emitted NO image -- a broken compile, not a wrong render (a length-preserving mutation must still emit)"
    local got; got="$(render_of "$nimg")"
    [[ -n "$got" ]] || fail "$name: mutated image produced an EMPTY render -- not a valid divergence"
    if [[ "$got" == "$want" ]]; then
        fail "$name: mutated renderer STILL produced the correct output -- the byte is not load-bearing (got [$got])"
    fi
    if [[ -n "$expect_wrong" && "$got" != "$expect_wrong" ]]; then
        fail "$name: divergence is not the expected one (anchor may have shifted off-site): want wrong=[$expect_wrong] got=[$got]"
    fi
    # retireable faithfulness: native two-stage image == C image, byte-for-byte.
    if [[ "$XCHECK" == "1" ]]; then
        local cimg="$tmp/c.$name.img"
        local cwd; cwd="$(mktemp -d "$tmp/cw.XXXX")"
        ( cd "$cwd" && "$HERBERT" "$mb" <"$pr" >/dev/null 2>/dev/null )
        if [[ -f "$cwd/a.out" ]]; then cp "$cwd/a.out" "$cimg"; else : >"$cimg"; fi
        cmp -s "$nimg" "$cimg" || fail "$name: native two-stage image != C image (substrate faithfulness broken)"
    fi
    echo "  bite $name: render diverged as required (got [${got:-<no-elf>}])"
}

# --- link11 flat-tuple mutations (on the flat probe) ----------------------------
# M-sep: the ", " separator comma (0x2c=44 -> 0x3b=59 ';').
bite M-sep  nc_emit_render_putsep   "do append(buf, 44)"  "do append(buf, 59)"  "$probe" "$correct"
# M-bool: the 'f' of "false" (0x66=102 -> 0x78=120 'x') in the bool renderer
# (unique within the function; the false element must render "false", not "xalse").
bite M-bool nc_emit_render_bool_noln "do append(buf, 102)" "do append(buf, 120)" "$probe" "$correct"
# M-open: the '(' open-paren byte (40 -> 91 '[') is now emitted from the render PLAN
# (nc_build_plan_rec's tuple token), not the entry stub. Renders '[42, ...'.
bite M-open nc_build_plan_rec "do add(out, (0, 40))" "do add(out, (0, 91))" "$probe" "$correct"
# M-base: the decimal divisor 10 (-> 11) in the int renderer corrupts every digit.
bite M-base nc_emit_render_int_noln "do append(buf, 10)" "do append(buf, 11)" "$probe" "$correct"

# --- link12 string + nested mutations (on the string probe) ---------------------
# M-strq: the OPENING quote byte of a rendered string (the first 34 in str_noln ->
# 63 '?'); the string must render "...", not ?...". Proves the string render emits.
bite M-strq  nc_emit_render_str_noln "do append(buf, 34)"  "do append(buf, 63)"  "$sprobe" "$scorrect" '(?\n", 99)'
# M-strn: the 'n' of the \n escape (0x6e=110 -> 0x6d=109 'm', unique in str_noln);
# the newline byte must render as \n, not \m. Proves the escaping is byte-exact.
bite M-strn  nc_emit_render_str_noln "do append(buf, 110)" "do append(buf, 109)" "$sprobe" "$scorrect"
# M-strwidth: a string consumes TWO result words (ptr, length). Shrinking that to one
# (word + 2 -> word + 1, unique in nc_build_plan_rec) makes the trailing 99 read the
# string's length word instead -> the tuple's last element renders wrong. Proves the
# mixed-width word-offset accumulation (the nested/string core) is load-bearing.
bite M-strwidth nc_build_plan_rec "word + 2" "word + 1" "$sprobe" "$scorrect"

xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: aggregate-render mutation proof (CONTROL correct C-FREE; flat M-sep/M-bool/M-open/M-base + string M-strq/M-strn/M-strwidth each diverge via a real two-stage seed compile of the mutated backend -- the flat AND string/nested renderers are load-bearing$xc)"
