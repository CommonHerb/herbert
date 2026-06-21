#!/usr/bin/env bash
#
# Front-end error-vocabulary native gate (sovereignty residue -- the C-free rehome of
# the assurance castoff consciously spent at the switchover).
#
# WHAT THIS RESTORES. castoff (sovereignty link 18) deleted the C bootstrap interpreter
# and, with it, the C-driven `error_probes` differential that exercised klondike.herb's
# located front-end diagnostic vocabulary (ERR 101-316). The old test built each
# "expected" diagnostic from the C bootstrap's own line+payload and required klondike.herb
# (run under the C interpreter, probe on stdin) to match it. With C gone that differential
# is gone; the diagnostic paths still WORK but were left UNTESTED -- the disclosed
# assurance loss. This gate rehomes the coverage onto the C-free gen-1 seed, the same
# C->seed rehome the six metacircular-fragment native gates already received.
#
# THE SURFACE (and an honest scope boundary). klondike.herb is the consolidated front-end
# REFERENCE compiler (lex + parse + semantic check) that owns the located ERR 101-316
# vocabulary -- graceful, line-numbered, value-bearing diagnostics for every malformed
# construct. This is a DISTINCT surface from the production native-codegen seed
# (native_compile_fragment.herb), whose verifier emits its OWN native-subset vocabulary
# (ERR 4xx/5xx, "forbidden construct") and which, on raw front-end-malformed input, may
# fault or accept rather than emit a located front-end diagnostic (verified: the seed
# crashes on lex_101's bare `$` and reports ERR 404 on sem_302). The native-subset
# vocabulary is separately gated by the native-codegen reject battery; THIS gate covers
# klondike.herb's raw-source front-end diagnostics, exactly what `error_probes` covered.
#
# INDEPENDENCE (what keeps this an assurance check and not a self-grading tautology):
#   (A) The hand-authored MANIFEST stack/error_probes.expected (probe -> "ERR <code>") is
#       an INDEPENDENT anchor for the ERR CODE of every one of the 54 probes -- it was
#       authored separately from klondike and is NOT captured from it. The gate extracts
#       the native diagnostic's terminal "(ERR <n>)" and compares <n> to the manifest code.
#   (B) The committed GOLDEN stack/error_probes_native.expected (probe -> full diagnostic)
#       is a REGRESSION pin on line+message+payload, captured once from the native ELF and
#       HUMAN-VERIFIED at capture against the manifest + the probe sources. It proves "no
#       drift from the blessed located vocabulary"; it cannot by itself prove the original
#       line/payload was right (the C oracle that could is gone -- the disclosed,
#       unrestorable half of the loss).
#   (C) METAMORPHIC checks (generated at gate time, never committed): they bind specific
#       diagnostics to a FUNCTION of the input, which a frozen 54-probe lookup cannot fake.
#       SCOPE, stated honestly: they prove input-tracking for the LINE NUMBER (via 201) and
#       for the PAYLOAD-EXTRACTION mechanism at FIVE distinct extraction sites that share
#       one sink (diagnostic_with_payload): a name use (302), a function call (304), a
#       let-binding (301), a parameter (311), and a call-arity name (305). They do NOT
#       cover every payload code -- the remaining payload codes (303/306/307/308/310/312/
#       313/315/316) are REGRESSION-PINNED ONLY, so a klondike that hardcoded one of THOSE
#       payloads would pass; that residue is acceptable-disclosed-scope, not a frozen-lookup
#       defeat for the whole vocabulary.
# The C-faithfulness leg (native == C-interp) is unrestorable -- C is deleted -- and is
# omitted by design.
#
# RED-first: this gate, the golden, and the mutation proof do not exist before this link;
# run_error_vocab_native_mutation.sh proves a message-only / code / payload-drop / line
# mutation of klondike.herb each makes the native diagnostics diverge -> RED (and that the
# RED is a genuine vocabulary divergence, not an infrastructure/compile failure).
#
# Re-bless (intentional vocabulary change only): ERROR_VOCAB_CAPTURE=1 rewrites the golden
# from the current native ELF instead of asserting. Use ONLY when a klondike diagnostic is
# deliberately reworded, and re-verify the diff by eye against the manifest.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

# ERROR_VOCAB_FRAGMENT lets the mutation proof point the gate at a MUTATED klondike copy
# (the gate stays the single source of assertion logic; the committed golden/manifest are
# unchanged, so a mutated vocabulary diverges -> the gate goes RED). Defaults to the real,
# byte-identical klondike.herb.
fragment="${ERROR_VOCAB_FRAGMENT:-$repo_root/stack/klondike.herb}"
manifest="$repo_root/stack/error_probes.expected"
golden="$repo_root/stack/error_probes_native.expected"
probe_dir="$repo_root/stack/error_probes"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: error-vocab native gate ($1)"; exit 1; }

[[ -f "$fragment" ]] || fail "missing klondike.herb $fragment"
[[ -f "$manifest" ]] || fail "missing manifest $manifest"
[[ -d "$probe_dir" ]] || fail "missing probe dir $probe_dir"

capture="${ERROR_VOCAB_CAPTURE:-0}"
[[ "$capture" == "1" ]] || [[ -f "$golden" ]] || fail "missing golden $golden (run with ERROR_VOCAB_CAPTURE=1 to mint it)"

# --- 1. Acquire the C-free gen-1 production compiler (the committed seed) -----------
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || fail "could not acquire gen-1 compiler"
GEN1="$NATIVE_CODEGEN_COMPILER"
[[ -x "$GEN1" ]] || fail "gen-1 compiler not executable: $GEN1"

# --- 2. Gate-time main adapter (klondike.herb stays byte-identical on disk) ---------
# klondike's real main does `return serialize_value(...)` (a STRING) -- the native subset
# requires main:int/bool, so the verifier would unify serialize_value's return to int and
# collide with its string body (ERR 430). Replacing that one line with `do flogger(...);
# return 0` makes the ~3800-line toolchain compile clean under the PRISTINE seed -- the
# same one-line I/O adapter run_klondike_native.sh uses; it is NOT on any error path (a
# malformed probe never reaches serialize_value). The anchor is asserted unique so a
# future klondike rename fails LOUD rather than silently mis-adapting.
adapter="$tmp/klondike_native.herb"
python3 - "$fragment" "$adapter" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "    return serialize_value(result, pools)\n"
new = ("    do flogger(serialize_value(result, pools))\n"
       "    do flogger(\"\\n\")\n"
       "    return 0\n")
n = src.count(old)
if n != 1:
    sys.stderr.write("main-adapter anchor count %d (want 1)\n" % n)
    sys.exit(9)
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PY
[[ $? -eq 0 ]] || fail "main-adapter transform failed (anchor missing or not unique -- klondike main changed?)"

# --- 3. Compile the adapted klondike with gen-1 (once) -----------------------------
# The gen-1 emitter writes ./a.out without the execute bit; chmod +x before running (a
# missing chmod looks exactly like a divergence -- it is not).
bwd="$(mktemp -d "$tmp/build.XXXX")"
( cd "$bwd" && "$GEN1" <"$adapter" >compile.log 2>compile.err )
[[ -f "$bwd/a.out" ]] || fail "gen-1 did not compile adapted klondike: $(head -1 "$bwd/compile.err" 2>/dev/null)"
[[ "$(head -c4 "$bwd/a.out" | xxd -p)" == "7f454c46" ]] || fail "gen-1 output is not an ELF (klondike did not compile to native code)"
chmod +x "$bwd/a.out" || fail "could not chmod the native ELF"
elf="$bwd/a.out"

# --- helper: run the ELF on a source file (raw on stdin); echo the located diagnostic.
# klondike's transcript for a malformed program is EXACTLY two lines: `line N: <msg> (ERR
# NNN)` then a `0` return-marker. We require EXACTLY those two lines -- no extra stdout
# between the diagnostic and the marker (which a forge could hide junk in) and the marker
# present (ran to completion, not a mid-run crash). Echoes line 1 (the diagnostic).
run_diag() { # $1=source-file -> prints the diagnostic line; returns 1 on any shape error
    local src="$1" of="$tmp/diag.out"
    timeout 60s "$elf" <"$src" >"$of" 2>/dev/null || { echo "    (native ELF exited nonzero/timed out)"; return 1; }
    # Read from the FILE (not a stripped "$(...)") so TRAILING blank lines survive as array
    # elements: the transcript must be EXACTLY <diagnostic>\n0, and a forge appending blank
    # lines after the 0 marker (which command-substitution would silently strip) is then
    # caught here as ">2 lines" rather than passing.
    local lines; mapfile -t lines < "$of"
    [[ "${#lines[@]}" -eq 2 ]] || { echo "    (transcript not exactly <diagnostic>+<0>: ${#lines[@]} line(s))"; return 1; }
    [[ "${lines[1]}" == "0" ]] || { echo "    (second line is not the return-0 marker: [${lines[1]}])"; return 1; }
    printf '%s' "${lines[0]}"
}

# --- 4. CAPTURE mode: re-mint the golden (intentional re-bless only) ----------------
if [[ "$capture" == "1" ]]; then
    : > "$golden"
    while read -r name word code; do
        [[ -n "$name" ]] || continue
        diag="$(run_diag "$probe_dir/$name.herb")" || fail "capture: $name did not reject cleanly"
        printf '%s\t%s\n' "$name" "$diag" >> "$golden"
    done < "$manifest"
    echo "PASS: error-vocab golden re-minted to $golden ($(wc -l < "$golden") probes) -- VERIFY THE DIFF BY EYE"
    exit 0
fi

# --- 5. GATE mode: per-probe manifest-code (independent) + golden (regression) ------
n_probes=0
while read -r name word code; do
    [[ -n "$name" ]] || continue
    [[ "$code" =~ ^[0-9][0-9][0-9]$ ]] || fail "$name: manifest code '$code' is not three digits (malformed manifest)"
    probe="$probe_dir/$name.herb"
    [[ -f "$probe" ]] || fail "$name: missing probe file"
    diag="$(run_diag "$probe")" || fail "$name: native klondike did not emit a clean located diagnostic"
    # (A) INDEPENDENT manifest anchor: extract the diagnostic's terminal (ERR <n>) and
    #     compare <n> LITERALLY to the manifest code. A non-ERR diagnostic (a clean compile
    #     leaking through, or a crash echo) has no terminal (ERR <n>) -> must-reject fires.
    [[ "$diag" =~ \(ERR\ ([0-9]+)\)$ ]] || fail "$name: native did NOT reject with a located ERR diagnostic -> [$diag]"
    emitted="${BASH_REMATCH[1]}"
    [[ "$emitted" == "$code" ]] || fail "$name: native ERR code $emitted != manifest $code -> [$diag]"
    # (B) REGRESSION pin: full diagnostic == committed golden line (field-aware lookup,
    #     $1==name, so a prefix/suffix name cannot mis-match).
    gline="$(awk -F'\t' -v n="$name" '$1==n{sub(/^[^\t]*\t/,""); print; exit}' "$golden")"
    [[ -n "$gline" ]] || fail "$name: no golden entry (golden out of sync with manifest -- re-bless?)"
    [[ "$diag" == "$gline" ]] || fail "$name: native diagnostic differs from golden
       native=[$diag]
       golden=[$gline]"
    n_probes=$((n_probes + 1))
done < "$manifest"
[[ "$n_probes" -ge 54 ]] || fail "only $n_probes probes checked (manifest shrank? expected >=54)"

# --- 6. METAMORPHIC checks: the diagnostic is a FUNCTION of input, not a frozen lookup.
# A gate-generated transform of a probe must produce the correspondingly-transformed
# diagnostic EXACTLY (no substring slack). Defeats a compiler that special-cased the fixed
# probes -- for the line number and the five sampled payload-extraction sites.
metamorphic() { # $1=probe-name  $2=sed-expr  $3=EXACT expected diagnostic
    local mm="$tmp/mm.$1.herb"
    sed "$2" "$probe_dir/$1.herb" > "$mm"
    cmp -s "$probe_dir/$1.herb" "$mm" && fail "metamorphic $1: sed '$2' was a no-op (probe shape changed?)"
    local d; d="$(run_diag "$mm")" || fail "metamorphic $1: native did not reject the transformed probe"
    [[ "$d" == "$3" ]] || fail "metamorphic $1: diagnostic did not track the input transform
       want=[$3]
       got =[$d]"
}

# PAYLOAD-RENAME across five distinct extraction sites (all through diagnostic_with_payload):
metamorphic sem_302_undefined_name  's/return x/return zq_use_unique/'   "line 2: undefined name 'zq_use_unique' (ERR 302)"
metamorphic sem_304_unknown_function 's/missing/zq_call_unique/'         "line 2: unknown function 'zq_call_unique' (ERR 304)"
metamorphic sem_301_duplicate_let    's/\bx\b/zq_let_unique/g'           "line 3: duplicate let 'zq_let_unique' in this scope (ERR 301)"
metamorphic sem_311_duplicate_param  's/\bx\b/zq_param_unique/g'         "line 1: duplicate parameter 'zq_param_unique' (ERR 311)"
metamorphic sem_305_user_arity       's/\bf\b/zq_fn_arity/g'             "line 6: wrong number of arguments to 'zq_fn_arity' (ERR 305)"

# LINE-SHIFT: prepend K blank lines to a line-1 error; the reported line must move by K.
mmL="$tmp/mm_line.herb"; K=5
{ for ((i=0;i<K;i++)); do echo ""; done; cat "$probe_dir/parse_201_top_level.herb"; } > "$mmL"
dL="$(run_diag "$mmL")" || fail "metamorphic line-shift: native did not reject"
[[ "$dL" == "line $((1+K)): expected 'func' at top level (ERR 201)" ]] || fail "metamorphic line-shift: reported line did not move to $((1+K)) -> [$dL]"

echo "PASS: error-vocab native gate (gen-1-compiled klondike rejects all $n_probes malformed probes C-FREE with located ERR 101-316 diagnostics: terminal ERR code == hand-authored manifest, full diagnostic == committed golden; metamorphic input-tracking proven for the line number (201) and five payload-extraction sites (302/304/301/311/305); remaining payload codes regression-pinned -- disclosed)"
