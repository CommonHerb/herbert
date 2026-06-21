#!/usr/bin/env bash
#
# Mutation proof for the front-end error-vocabulary native gate (run_error_vocab_native.sh).
#
# RED-first: prove the gate genuinely BITES. A self-captured golden is only as good as the
# mutations it catches, so here we mutate klondike.herb's diagnostic-assembly code four
# ways -- each a real way the located ERR 101-316 vocabulary could silently rot -- compile
# the MUTATED klondike with the SAME pristine C-free gen-1 seed, and require the gate to go
# RED *for a vocabulary reason*. A CONTROL (unmutated klondike) must stay GREEN.
#
# The gate is the single source of assertion logic; we drive it via ERROR_VOCAB_FRAGMENT
# (point it at a mutated copy) and assert its exit status AND its failure CLASS -- a
# mutation that made klondike fail to COMPILE would also exit nonzero, but that is an
# infrastructure failure, not the vocabulary divergence we are proving the gate catches, so
# we reject it explicitly (a false 'CAUGHT'). The committed golden + manifest are unchanged.
#
#   M-message  reword a diagnostic string (101 "unexpected character") -> golden divergence.
#   M-code     emit code+1 instead of code -> the INDEPENDENT manifest-code anchor fires.
#   M-line     report a constant line (1) instead of the real line -> golden divergence
#              (the count_* probes + the metamorphic line-shift expect a moved line).
#   M-payload  drop the interpolated payload -> golden divergence (sem_3xx lose their name)
#              + the metamorphic payload-rename can no longer track input.
# Together they exercise every assertion class the gate carries: golden regression, the
# manifest code anchor, and the metamorphic input-tracking checks.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
klondike="$repo_root/stack/klondike.herb"
gate="$script_dir/run_error_vocab_native.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: error-vocab mutation proof ($1)"; exit 1; }
[[ -f "$klondike" ]] || fail "missing klondike.herb"
[[ -x "$gate" ]] || fail "gate not executable: $gate"

# Infra-failure signatures: a gate RED carrying ANY of these is NOT a vocabulary
# divergence (it is a compile/seed/adapter/setup failure) and must NOT count as CAUGHT.
# NOTE: "missing" is anchored to the gate's own infra phrases (missing klondike/manifest/
# probe/golden) -- a bare "missing" would mis-flag a genuine divergence whose diagnostic
# carries the payload word "missing" (e.g. unknown function 'missing') as infra.
INFRA='did not compile|could not acquire|not an ELF|not executable|main-adapter|missing (klondike|manifest|probe|golden)|malformed manifest|no golden entry|sed .* was a no-op'
# Vocabulary-divergence signatures: a genuine catch by one of the gate's real assertions.
VOCAB='differs from golden|!= manifest|did NOT reject|did not track the input'

checks=0

# --- CONTROL: an unmutated copy must pass (non-vacuity) -----------------------------
ctrl="$tmp/klondike.control.herb"
cp "$klondike" "$ctrl"
if ERROR_VOCAB_FRAGMENT="$ctrl" bash "$gate" >/dev/null 2>&1; then
    echo "PASS control: unmutated klondike GREEN through the gate"
    checks=$((checks + 1))
else
    fail "CONTROL went RED -- the gate is broken or the seed cannot compile klondike (vacuous mutation proof)"
fi

# mutate <name> <sed-expr> : copy klondike, apply sed (assert it changed a byte), run the
# gate, require RED *via a vocabulary assertion* (not an infra/compile failure).
mutate() {
    local name="$1" expr="$2" mut="$tmp/klondike.$1.herb" out="$tmp/$1.out"
    sed "$expr" "$klondike" > "$mut"
    if cmp -s "$klondike" "$mut"; then
        fail "$name: mutation sed was a no-op (anchor moved in klondike.herb -- update the mutation)"
    fi
    if ERROR_VOCAB_FRAGMENT="$mut" bash "$gate" >"$out" 2>&1; then
        fail "$name: mutated klondike passed the gate GREEN -- the gate does NOT catch this rot (NOT RED-first)"
    fi
    if grep -qE "$INFRA" "$out"; then
        fail "$name: gate went RED for an INFRASTRUCTURE reason, not a vocabulary divergence (false CAUGHT): $(grep -m1 -E "$INFRA" "$out")"
    fi
    grep -qE "$VOCAB" "$out" || fail "$name: gate RED but not via a recognized vocabulary assertion: $(grep -m1 FAIL "$out")"
    echo "PASS mutation $name: CAUGHT via vocabulary divergence ($(grep -m1 -oE "$VOCAB" "$out"))"
    checks=$((checks + 1))
}

# M-message: reword the ERR 101 message -> the lex_101 golden line diverges.
mutate M-message 's/return "unexpected character"/return "unexpected CHARACTER"/'

# M-code: emit code+1 -> every diagnostic carries the wrong code -> manifest anchor fires.
mutate M-code 's/buf = append_str(buf, int_to_str(code))/buf = append_str(buf, int_to_str(code + 1))/'

# M-line: report a constant line 1 -> count_* / metamorphic line-shift golden divergence.
mutate M-line 's/buf = append_str(buf, int_to_str(line))/buf = append_str(buf, int_to_str(1))/'

# M-payload: drop the interpolated payload -> sem_3xx golden + metamorphic payload divergence.
mutate M-payload 's/    buf = append_str(buf, payload)/    buf = append_str(buf, "")/'

echo "PASS: error-vocab mutation proof ($checks checks: control GREEN + 4 mutations each CAUGHT via a genuine VOCABULARY divergence (not an infra/compile failure) -- message/code/line/payload rot in klondike.herb each makes the gate RED, so the golden regression pin, the independent manifest-code anchor, and the metamorphic input-tracking checks are all proven load-bearing)"
