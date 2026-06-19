#!/usr/bin/env bash
#
# Mutation / bite proof for the link11 aggregate (flat int/bool tuple) renderer.
#
# Proves the renderer is LOAD-BEARING and CORRECT: each mutation changes ONE
# render-specific byte in the back end, recompiles the held-back probe, and
# asserts the rendered tuple DIVERGES from the correct canonical form. If any
# mutation left the output unchanged, the gate would be testing nothing.
#
# It compiles via the C interpreter running the (mutated) backend
# (`$HERBERT native_compile_fragment.herb < probe`). That is byte-identical to
# what a gen-1 minted from the mutated backend would emit -- gen-1 IS
# C_interp(backend) cast to an ELF, and both execute the same deterministic
# backend on the probe -- so it needs no multi-minute gen-1 re-mint per mutation.
# The unmutated CONTROL is asserted to render CORRECTLY first (non-vacuity).
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

[[ -x "$HERBERT" ]] || fail "missing C bootstrap $HERBERT"
[[ -f "$backend" ]] || fail "missing backend $backend"

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

# Compile $1 (a backend source) with the C interpreter and run the probe,
# echoing the rendered line (empty if it did not produce an ELF).
render_with_backend() {
    local be="$1" wd; wd="$(mktemp -d "$tmp/r.XXXX")"
    ( cd "$wd" && "$HERBERT" "$be" <"$probe" >/dev/null 2>"$wd/c.err" )
    [[ -f "$wd/a.out" ]] || { echo ""; return 0; }
    chmod +x "$wd/a.out"
    "$wd/a.out" 2>/dev/null | tr -d '\n'
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

# --- CONTROL: unmutated backend renders CORRECTLY (non-vacuity) -----------------
ctl="$(render_with_backend "$backend")"
[[ "$ctl" == "$correct" ]] || fail "CONTROL: unmutated backend did not render the correct tuple (got [$ctl])"

bite() {
    local name="$1" fname="$2" old="$3" new="$4"
    local mb="$tmp/mut.$name.herb"
    mutate_in_func "$backend" "$mb" "$fname" "$old" "$new" || fail "$name: mutation did not apply uniquely in $fname (vacuous)"
    local got; got="$(render_with_backend "$mb")"
    if [[ "$got" == "$correct" ]]; then
        fail "$name: mutated renderer STILL produced the correct tuple -- the byte is not load-bearing (got [$got])"
    fi
    echo "  bite $name: render diverged as required (got [${got:-<no-elf>}])"
}

# M-sep: the ", " separator comma (0x2c=44 -> 0x3b=59 ';').
bite M-sep  nc_emit_render_putsep   "do append(buf, 44)"  "do append(buf, 59)"
# M-bool: the 'f' of "false" (0x66=102 -> 0x78=120 'x') in the bool renderer
# (unique within the function; the false element must render "false", not "xalse").
bite M-bool nc_emit_render_bool_noln "do append(buf, 102)" "do append(buf, 120)"
# M-open: the '(' open-paren literal (40 -> 91 '[') at the tuple-head call site.
bite M-open nc_emit_entry_stub "nc_emit_render_putc(buf, 40," "nc_emit_render_putc(buf, 91,"
# M-base: the decimal divisor 10 (-> 11) in the int renderer corrupts every digit.
bite M-base nc_emit_render_int_noln "do append(buf, 10)" "do append(buf, 11)"

echo "PASS: aggregate-render mutation proof (CONTROL correct; M-sep/M-bool/M-open/M-base each diverge -- the renderer is load-bearing)"
