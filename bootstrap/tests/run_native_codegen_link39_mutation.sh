#!/usr/bin/env bash
# Native codegen Link 39 (ouroboros) MUTATION proof: the held-back proof that the gate's make-or-break checks
# BITE. Control must grade GREEN first (else the grader is vacuous); then each mutation must go RED:
#   M-byteshift : the emitted module differs from the STEP-0 target by one byte -> the white-box BYTE-PIN bites.
#   M-noxform   : main echoes the byte, never calls the recursive helper -> answer == fed != tri(fed) (the
#                 recursion is load-bearing: skipping it is caught by answer-correctness).
#   M-baseflip  : the recursion base case returns 1 instead of 0 -> answer == tri(n)+1, wrong -> bites.
#   M-wrongrel  : the BACKWARD recursive call rel32 is corrupted (target shifted) -> wrong target -> wrong
#                 answer or a CPL3 fault the watchdog/fault->continue names -> bites (the signed backward
#                 call is load-bearing).
#   M-constbake : a module that READS the byte then bakes 0x5A -> answer != host_T AND the X!=Y differential
#                 collapses (answer(fx)==answer(fy)) -> the differential bites.
#   M-ovfcross  : the A11-residual arm (2026-09-01). The gate's overflow leg was SINGLE-ENGINE until
#                 2026-09-01, which is the only reason a QEMU-TCG-specific page-fault error code (0x5,
#                 the load half of a lowered read-modify-write) nearly entered canon as hardware truth
#                 -- KVM reports 0x7 for the WRITE on identical eip/esp/cr2. The gate now diffs the
#                 engines against each other (ouroboros_ref overflow_cross). This arm proves that diff
#                 BITES and, equally, that it does NOT false-RED on the legitimate engine-dependent
#                 errcode: one REAL overflow boot, then three pure checks against it --
#                   (a) EACH of the FOUR CROSS-DISCRIMINATING facts, mutated one at a time, makes
#                       the comparator go RED and NAME that fact (cr2, the fault's offset into the
#                       module, how far below its stack base the descent reached, and the fault
#                       MECHANISM -- the errcode with only its W bit masked). Those four
#                       are the whole discriminating set: grade_overflow already pins the other three
#                       cross fields to constants PER STREAM, so two streams that both graded GREEN
#                       can never disagree on them. Proving only one of the three -- the first
#                       version of this arm -- let a comparator keeping just that one field still
#                       pass (cross-model Codex BLOCK finding 3, 2026-09-01).
#                   (b) ONLY the page-fault errcode changed 0x5<->0x7                            -> GREEN
#                   (c) a SINGLE engine offered to the comparator                                -> RED
#                   (d) the SAME capture handed in twice under two labels                        -> RED
#                       (label uniqueness alone accepted it -- Codex BLOCK finding 1)
#                 (c) is the residual's own tripwire: a future edit that drops the second engine can no
#                 longer leave a silently single-engine leg behind a passing mutation proof.
# Negative controls fed as raw module blobs (ouroboros_ref mutant); the FROZEN geeking kernel runs them and
# the ouroboros grader must reject. Run under KERNEL_CODEGEN_MUTATION=1 (CI) like every prior link.
# Every boot is adjudicated only through the change-7 completion witness (charter 2026-07-17, built
# 2026-08-31): parser-backed + rc-consistent via ouroboros_ref mutwitness -- see boot_witnessed below.
# A dead/corrupt capture can no longer score as a vacuous "bite"; one-shot capture misses re-roll
# boundedly on FRESH boots instead of hard-failing the whole battery (exhaustion stays fail-closed).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/ouroboros_ref.py"
GREF="$script_dir/geeking_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing ouroboros_ref.py $REF)"; exit 1; fi
if [[ ! -f "$GREF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing geeking_ref.py $GREF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"
source "$script_dir/replay_discriminator.sh" || { echo "FAIL: stack/native_compile_fragment.herb (missing replay_discriminator.sh -- boot_qemu runner)"; exit 1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
elf_meta() { local elf="$1" eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n'); echo $(( 1048576 + $(le32_val "$eh" 144) )); }
# tri probe bytes (safe recursion depth, well under the one-page bound): fx=20, fy=42
FX=20; FY=42

# ---- the frozen geeking host kernel (re-emitted from source) ----
KCDIR="$work/kernel.d"; mkdir -p "$KCDIR"
printf -- '-- emit: multiboot32-geeking\nfunc main(): return module_byte() end\n' > "$KCDIR/k.herb"
( cd "$KCDIR" && "$NATIVE_CODEGEN_COMPILER" < k.herb >/dev/null 2>"$KCDIR/err" )
[[ -f "$KCDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (kernel emit failed)"; exit 1; }
KELF="$work/geeking.elf"; cp "$KCDIR/a.out" "$KELF"
# byte-pin the battery's host kernel (2026-07-17, discriminator-sweep tranche 1a / Codex change 1:
# GREF was previously only existence-checked and KELF trusted unpinned -- a silent geeking-emit drift
# would have run the whole mutation battery on an unverified kernel). Mirrors the main gate's L73-74.
python3 "$GREF" cleanelf "$work/geeking_ref.elf"
cmp -s "$KELF" "$work/geeking_ref.elf" || { echo "FAIL: stack/native_compile_fragment.herb (mutation harness: compiled geeking != geeking_ref.build_elf -- refusing to run mutants on an unpinned host kernel)"; exit 1; }
KELF_SHA="$(sha256sum "$KELF" | cut -d' ' -f1)"
KEND="$(printf '%x' "$(elf_meta "$KELF")")"

boot_once() { # modfile byte -> 0 (boot ran: OUT + RC set) / 1 (proven pre-adjudication harness failure: HERR set)
    local mod="$1" byte="$2" W; W="$(mktemp -d "$work/run.XXXX")"
    OUT="$W/e9"; ANSWER=""; RC=""; HERR=""
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$W/feed.log" 2>/dev/null || { HERR="feeder never reached LISTENING (socket-bind failure; QEMU not launched)"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
    boot_qemu 60 "$OUT.bstat" qemu-system-x86_64 -kernel "$KELF" -initrd "$mod" -debugcon file:"$OUT" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$OUT.qerr"
    RC=$?
    wait "$fp" 2>/dev/null
    # A REQUESTED-but-ABSENT status file is a harness class here too, never a witnessed boot -- the
    # eighth boot_qemu call site, and the one that does NOT go through qemu_classify (parent delta
    # refutation panel finding, generalized by the blind Opus 5 refuter, 2026-09-02). boot_qemu does
    # not write the file when the runner is reaped WITH the guest (a sweeping `pkill -f
    # ...qemu-system-x86_64...` matches the python3 runner's own argv) or when python3 raises before
    # the write; the folded rc alone cannot tell that from a completed boot.
    if [[ ! -r "$OUT.bstat" ]]; then
        HERR="boot status file missing or unreadable -- the status-preserving runner recorded no wait status (reaped with the guest, or unable to write); this boot is not a witness"; return 1
    fi
    local bst; bst="$(head -1 "$OUT.bstat" 2>/dev/null)"
    if [[ "$bst" == SIGNAL:* ]]; then   # status-preserving runner (tranche 1b): a signal death is a proven harness class, never adjudicated
        HERR="QEMU died on ${bst} (WIFSIGNALED, status-preserving boot runner)"; return 1
    fi
    if grep -qvE 'terminating on signal' "$OUT.qerr" 2>/dev/null; then   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill is left to the witness/grader
        HERR="QEMU launch error: $(grep -vE 'terminating on signal' "$OUT.qerr" | head -1)"; return 1
    fi
    ANSWER=$(xxd -p "$OUT" 2>/dev/null | tr -d '\n' | grep -oE 'de..ad$' | sed -E 's/^de(..)ad$/\1/')   # TERMINAL frame only
    return 0
}

# completion witness (charter change 7, 2026-08-31 -- replaces the tranche-1a hex-regex minimal witness):
# parser-backed + rc-consistent, via ouroboros_ref mutwitness (OWN table under the frozen-kernel pin; the
# stream ENDS with the aligned terminal DE<answer>AD; rc == that answer's isa-debug-exit encoding; the
# read-witness carries the fed byte; class 'full' = normal mutants must reach SYS_EXIT, class 'faultok' =
# wrongrel may end in a named fault/kill). An UNWITNESSED attempt is a harness class: re-rolled on a FRESH
# boot (bounded, 3 attempts), fail-closed on exhaustion. A WITNESSED completion is graded ONCE and NEVER
# replayed -- a completed mutant RED is the expected bite, and a completed mutant GREEN is a scored FAIL;
# neither is re-rollable (the change-7 rule).
boot_witnessed() { # label modfile byte wclass -> 0 witnessed (OUT/RC/ANSWER/WITNESS set) / 1 exhausted (HVMARK)
    local label="$1" mod="$2" byte="$3" wclass="$4" a w
    for a in 1 2 3; do
        if ! boot_once "$mod" "$byte"; then
            echo "  HARNESS (link39m $label byte=$byte attempt $a/3): $HERR -- re-rolling (proven setup failure; no adjudication)" >&2; continue
        fi
        w="$(python3 "$REF" mutwitness "$OUT" "$KEND" "$(printf '%x' "$byte")" "$wclass" "$RC" 2>&1)"
        if [[ $? -eq 0 ]]; then WITNESS="$w"; return 0; fi
        echo "  HARNESS (link39m $label byte=$byte attempt $a/3): unwitnessed completion: $w -- re-rolling on a FRESH boot (the attempt is discarded whole; a witnessed completion is never replayed)" >&2
    done
    echo "FAIL: link39 harness failure -- $label byte=$byte never produced a witnessed completion in 3 attempts (fail-closed; NOT a mutation bite)" >&2
    : > "$HVMARK"; return 1
}

mutate_red() { # label modfile gradekind byte wclass  -- boot witnessed, grade ONCE as <gradekind>, MUST be RED
    local label="$1" mod="$2" kind="$3" byte="$4" wclass="$5"
    boot_witnessed "M-$label" "$mod" "$byte" "$wclass" || return
    if python3 "$REF" grade "$OUT" "$KEND" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1; then
        fail_test "M-$label: graded GREEN as '$kind' -- NOT load-bearing (answer=0x$ANSWER)"
    else
        pass=$((pass + 1))
    fi
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (qemu required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs an emulator; set KERNEL_CODEGEN_REQUIRE_EMU=1 to force)."
    exit 0
fi

# ===== CONTROL: a clean compiled 'tri' module must grade GREEN on both bytes (else the grader is vacuous) =====
CDIR="$work/ctl.d"; mkdir -p "$CDIR"
printf -- '-- emit: multiboot32-ouroboros\n%s\n' "$(python3 "$REF" src tri)" > "$CDIR/m.herb"
( cd "$CDIR" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$CDIR/err" )
[[ -f "$CDIR/a.out" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control tri did not compile)"; exit 1; }
CTL="$work/ctl.bin"; cp "$CDIR/a.out" "$CTL"
[[ "$(xxd -p "$CTL" | tr -d '\n')" == "$(python3 "$REF" hex tri)" ]] || { echo "FAIL: stack/native_compile_fragment.herb (control tri != target)"; exit 1; }
for b in "$FX" "$FY"; do
    boot_witnessed "CONTROL-tri" "$CTL" "$b" full || continue
    if python3 "$REF" grade "$OUT" "$KEND" "$(printf '%x' "$b")" tri >/dev/null 2>&1; then pass=$((pass + 1)); else fail_test "CONTROL tri byte=$b: clean module not GREEN -- grader vacuous (answer=0x$ANSWER)"; fi
done

# ===== M-byteshift: a one-byte change to the target must break the white-box BYTE-PIN =====
SHIFT="$work/shift.bin"
python3 - "$CTL" "$SHIFT" <<'PY'
import sys
b=bytearray(open(sys.argv[1],'rb').read()); b[6]^=0x01
open(sys.argv[2],'wb').write(b)
PY
if [[ "$(xxd -p "$SHIFT" | tr -d '\n')" != "$(python3 "$REF" hex tri)" ]]; then pass=$((pass + 1)); else fail_test "M-byteshift: byte-pin would not detect a 1-byte module change"; fi

# ===== behavioral make-or-break: recursion + base case + backward call + differential all bite =====
python3 "$REF" mutant noxform   "$work/noxform.bin"
python3 "$REF" mutant baseflip  "$work/baseflip.bin"
python3 "$REF" mutant wrongrel  "$work/wrongrel.bin"
python3 "$REF" mutant constbake "$work/constbake.bin"
mutate_red noxform   "$work/noxform.bin"   tri "$FX" full     # echo: answer==fed != tri(fed) (recursion load-bearing)
mutate_red baseflip  "$work/baseflip.bin"  tri "$FX" full     # base returns 1: answer == tri(n)+1, wrong
mutate_red wrongrel  "$work/wrongrel.bin"  tri "$FX" faultok  # corrupted backward call rel32: wrong target/named fault
mutate_red constbake "$work/constbake.bin" tri "$FX" full     # bakes 0x5A: answer != tri(fed)

# ===== the X!=Y differential bites a const-baker: answer(FX)==answer(FY) for constbake =====
cb_sha="$(sha256sum "$work/constbake.bin" | cut -d' ' -f1)"   # freeze the mutant blob across the two boots (hash-identity, Codex change 1)
ax=""; ay=""
boot_witnessed "M-differential-fx" "$work/constbake.bin" "$FX" full && ax="$ANSWER"
boot_witnessed "M-differential-fy" "$work/constbake.bin" "$FY" full && ay="$ANSWER"
[[ "$(sha256sum "$work/constbake.bin" | cut -d' ' -f1)" == "$cb_sha" ]] || fail_test "M-differential: constbake module changed between the FX and FY boots -- hash-identity violated"
if [[ -n "$ax" && "$ax" == "$ay" ]]; then pass=$((pass + 1)); else fail_test "M-differential: constbake answer(FX)=0x$ax answer(FY)=0x$ay -- expected equal (dead-module signature)"; fi

# ===== M-ovfcross: the cross-ENGINE overflow agreement bites, and does not false-RED on the =====
# =====             engine-dependent page-fault error code (A11 residual arm, 2026-09-01)     =====
OVF_BYTE=250
OVFD="$work/ovf.d"; mkdir -p "$OVFD"
printf -- '-- emit: multiboot32-ouroboros\n%s\n' "$(python3 "$REF" overflowsrc)" > "$OVFD/m.herb"
( cd "$OVFD" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$OVFD/err" )
if [[ ! -f "$OVFD/a.out" ]]; then
    fail_test "M-ovfcross: the overflow probe did not compile ($(head -1 "$OVFD/err" 2>/dev/null))"
else
    OVFM="$work/ovf.bin"; cp "$OVFD/a.out" "$OVFM"
    # ONE real overflow boot (QEMU-TCG). Outcome class 'faultok': the module ends in the named CPL3
    # #PF (answer 0x50), never SYS_EXIT -- the completion witness binds rc to that answer.
    # The base boot is a CONTROL, not a mutant: it must grade GREEN as an overflow. The change-7
    # rule ("a witnessed completion is graded ONCE and never replayed") was written for MUTANTS, where
    # a completed RED is the expected bite. Here a witnessed-but-not-overflow boot is the watchdog-kill
    # flake grade_overflow's own header documents, so give the CONTROL a bounded re-roll instead of
    # turning one flake into a hard CI FAIL (blind Opus 5 finding 8, 2026-09-01). Exhaustion still
    # fail-closes via the fail_test below.
    OVFS="$work/ovf.base.e9"; ovf_base_ok=0
    for _a in 1 2 3; do
        boot_witnessed "M-ovfcross-base" "$OVFM" "$OVF_BYTE" faultok || break
        cp "$OUT" "$OVFS"
        if python3 "$REF" gradeoverflow "$OVFS" "$KEND" "$(printf '%x' "$OVF_BYTE")" >/dev/null 2>&1; then
            ovf_base_ok=1; break
        fi
        echo "  HARNESS (M-ovfcross-base attempt $_a/3): the control boot completed but did not grade as an overflow ($(python3 "$REF" gradeoverflow "$OVFS" "$KEND" "$(printf '%x' "$OVF_BYTE")" 2>&1 | tr '\n' ' ')) -- re-rolling (a CONTROL, not a mutant; the documented watchdog-kill class)" >&2
    done
    if [[ "$ovf_base_ok" -eq 1 ]]; then
        # CONTROL banked above: the captured stream IS a GREEN overflow witness, so the checks
        # below are not vacuous (a comparator fed two ungradable streams would "agree" about garbage).
        pass=$((pass + 1))
        # Patch the #PF witness frame D0<err><eip><cs><cr2><esp>D1 in a COPY of the real stream.
        # 'off' shifts the fault's offset into the module (an ENGINE-INDEPENDENT fact, and one that
        # stays inside the module's User pages so the per-stream grader still passes -- the RED must
        # come from the cross-engine diff, not from a stream that stopped grading).
        # Patch one field of the #PF witness frame D0<err><eip><cs><cr2><esp>D1 in a COPY of the real
        # stream. 'err' takes an ABSOLUTE value; every other field takes a DELTA, chosen so the
        # patched stream STILL grades GREEN on its own (eip stays inside the module's User pages,
        # esp stays below alloc_lo) -- the RED must come from the cross-engine diff, not from a
        # stream that stopped being a valid overflow witness.
        ovf_patch() { # src dst field value   (field: err|eip|cr2|esp)
            python3 - "$1" "$2" "$3" "$4" <<'PY2'
import sys, struct, re
src, dst, field, val = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 0)
d = bytearray(open(src,'rb').read())
ms_ = list(re.finditer(rb'\xD0(.{4})(.{4})(.{4})(.{4})(.{4})\xD1', bytes(d), re.S))
# G.parse reads frames only from the post-OWN-table TAIL, so patching a D0..D1 that lies in the
# table prefix would edit bytes the grader never reads. Require exactly one so the patcher and the
# grader are provably looking at the same frame (blind Opus 5 finding 9, 2026-09-01).
if len(ms_) != 1: sys.exit('expected exactly ONE #PF frame in the capture, found %d' % len(ms_))
m = ms_[0]
gi = {'err': 1, 'eip': 2, 'cs': 3, 'cr2': 4, 'esp': 5}[field]
lo = m.start(gi); cur = struct.unpack('<I', bytes(d[lo:lo+4]))[0]
new = val if field == 'err' else cur + val
d[lo:lo+4] = struct.pack('<I', new & 0xFFFFFFFF)
open(dst,'wb').write(bytes(d))
print('patched %s 0x%x -> 0x%x' % (field, cur, new & 0xFFFFFFFF))
PY2
        }
        FED_HEX="$(printf '%x' "$OVF_BYTE")"
        # (a) MUST BITE, ONCE PER DISCRIMINATING FACT: mutate exactly one, keep the stream a valid
        #     overflow witness, and require the comparator to go RED *and name that fact*.
        #     frame-field : delta : the cross field it must name
        # frame-field : delta : the cross field it must name. 'err' is absolute, not a delta:
        # 0x5 -> 0x6 keeps the U bit but flips P to 0 (a NON-PRESENT fault -- a different mechanism),
        # which the W-bit-only mask must catch (Codex finding 2 / Opus finding 4, 2026-09-01).
        for _spec in "eip:1:pf_off_in_module" "cr2:1:cr2" "esp:-4:esp_below_alloc_lo" "err:6:pf_mechanism"; do
            _fld="${_spec%%:*}"; _rest="${_spec#*:}"; _dlt="${_rest%%:*}"; _name="${_rest#*:}"
            if ! ovf_patch "$OVFS" "$work/ovf.$_fld.e9" "$_fld" "$_dlt" >/dev/null 2>&1; then
                fail_test "M-ovfcross(a/$_name): could not patch the #PF witness frame field '$_fld' (no D0..D1 frame in a stream that graded as an overflow?)"
                continue
            fi
            # the patched stream must STILL grade GREEN alone, else this proves the per-stream
            # grader bites, not the cross-engine diff (the whole point of the arm).
            if ! python3 "$REF" gradeoverflow "$work/ovf.$_fld.e9" "$KEND" "$FED_HEX" >/dev/null 2>&1; then
                fail_test "M-ovfcross(a/$_name): the mutated stream no longer grades GREEN on its own, so a RED below would prove the PER-STREAM grader bites, not the cross-engine diff -- pick a delta that keeps the witness valid"
                continue
            fi
            xo="$(python3 "$REF" ovfcross "$KEND" "$FED_HEX" "tcg:qemu=$OVFS" "kvm:qemu=$work/ovf.$_fld.e9" 2>&1)"; xrc=$?
            if [[ "$xrc" -ne 0 ]] && grep -q "engine disagreement on $_name" <<<"$xo"; then
                pass=$((pass + 1))
            else
                fail_test "M-ovfcross(a/$_name): mutating the ENGINE-INDEPENDENT fact '$_name' (frame field $_fld, delta $_dlt) did NOT go RED with a named disagreement -- that field of the cross-engine diff is not load-bearing (rc=$xrc: $(echo "$xo" | tr '\n' ' '))"
            fi
        done
        # (b) MUST NOT FALSE-RED: only the page-fault ERROR CODE differs (the real TCG 0x5 / KVM 0x7
        #     divergence). Both carry the U bit; every engine-independent fact is untouched.
        cur_err="$(python3 - "$OVFS" <<'PY3'
import sys, struct, re
d = open(sys.argv[1],'rb').read()
m = re.search(rb'\xD0(.{4})(.{4})(.{4})(.{4})(.{4})\xD1', d, re.S)
print('0x%x' % struct.unpack('<I', m.group(1))[0] if m else '')
PY3
)"
        other_err=0x7; [[ "$cur_err" == "0x7" ]] && other_err=0x5
        if ovf_patch "$OVFS" "$work/ovf.errW.e9" err "$other_err" >/dev/null 2>&1; then
            xo="$(python3 "$REF" ovfcross "$KEND" "$FED_HEX" "tcg:qemu=$OVFS" "kvm:qemu=$work/ovf.errW.e9" 2>&1)"; xrc=$?
            if [[ "$xrc" -eq 0 ]]; then
                echo "  M-ovfcross(b): W-bit-only errcode divergence ${cur_err} vs ${other_err} stays GREEN (the ONE bit correct engines may disagree on here; every other errcode bit IS compared -- see (a/pf_mechanism))"
                pass=$((pass + 1))
            else
                fail_test "M-ovfcross(b): an errcode-ONLY divergence (${cur_err} vs ${other_err}, both U-bit set) went RED -- the comparator false-REDs on the documented TCG/KVM disagreement it was built to tolerate ($(echo "$xo" | tr '\n' ' '))"
            fi
        else
            fail_test "M-ovfcross(b): could not patch the #PF errcode"
        fi
        # (c) the residual's tripwire: ONE engine is not two.
        xo="$(python3 "$REF" ovfcross "$KEND" "$FED_HEX" "tcg:qemu=$OVFS" 2>&1)"; xrc=$?
        if [[ "$xrc" -ne 0 ]] && grep -q 'needs >= 2 engines' <<<"$xo"; then
            pass=$((pass + 1))
        else
            fail_test "M-ovfcross(c): a SINGLE-engine cross check was accepted (rc=$xrc) -- the A11 residual could silently reopen ($(echo "$xo" | tr '\n' ' '))"
        fi
        # (d) the same tripwire's forgeable twin: ONE capture FILE handed in twice under two labels
        #     is not two engines either (label uniqueness alone accepted it -- Codex BLOCK finding 1).
        #     Note what this deliberately does NOT do: it does not reject two BYTE-IDENTICAL captures.
        #     tcg and kvm differ only in the page-fault W bit, so rejecting byte-identity would make
        #     this leg depend on the very errcode divergence the oracle refuses to trust, and would
        #     hard-RED the day an engine stops diverging (blind Opus 5 finding 2, 2026-09-01).
        for _dspec in "same-path:$OVFS" "hardlink:$work/ovf.hard.e9"; do
            _dlbl="${_dspec%%:*}"; _dpath="${_dspec#*:}"
            [[ "$_dlbl" == hardlink ]] && { rm -f "$_dpath"; ln "$OVFS" "$_dpath" 2>/dev/null || { echo "  NOTE: M-ovfcross(d/hardlink) skipped -- this filesystem refused a hard link" >&2; continue; }; }
            xo="$(python3 "$REF" ovfcross "$KEND" "$FED_HEX" "tcg:qemu=$OVFS" "kvm:qemu=$_dpath" 2>&1)"; xrc=$?
            if [[ "$xrc" -ne 0 ]] && grep -q 'SAME capture' <<<"$xo"; then
                pass=$((pass + 1))
            else
                fail_test "M-ovfcross(d/$_dlbl): one capture under two labels was accepted as two engines (rc=$xrc) -- the two-engine requirement is forgeable ($(echo "$xo" | tr '\n' ' '))"
            fi
        done
        # (f)/(g) the SAME-LOADER absolute-address check must bite, and must NOT fire across loaders.
        #     A uniform +0x1000 shift of the OWN table's modstart/modend/alloc_lo/alloc_hi AND the #PF
        #     frame's eip/esp moves every ABSOLUTE address while leaving every NORMALIZED fact equal
        #     (offset, depth, span, gap, cr2, mechanism) -- and the shifted stream still grades GREEN
        #     on its own. So it isolates exactly the check under test. Without this the same-loader
        #     comparison was decoration: deleting OVF_SAME_LOADER_FIELDS left every other check passing
        #     (cross-model Codex confirm-leg finding 3, 2026-09-02).
        ovf_shift() { # src dst delta -- shift the module/alloc window and the #PF eip/esp together
            python3 - "$1" "$2" "$3" <<'PY4'
import sys, struct, re
src, dst, delta = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
d = bytearray(open(src,'rb').read())
i = 0
while i < len(d) and d[i] == 0x9C and i + 25 <= len(d): i += 25   # skip the mmap entries, as G.parse does
if i >= len(d) or d[i] != 0x9A: sys.exit('no OWN table marker (0x9A) where G.parse expects one')
CELLBASE = i + 1 + 16                                            # marker + k0,k1,ma,ml
CELLS = ['mbinfo','flags','modstart','modend','str','cmdline','elflo','elfhi',
         'region_lo','region_hi','alloc_lo','alloc_hi','answer',
         'mb_lo','mb_hi','st_lo','st_hi','cm_lo','cm_hi','mm_lo','mm_hi']
for nm in ('modstart','modend','alloc_lo','alloc_hi'):
    o = CELLBASE + CELLS.index(nm)*4
    v = struct.unpack('<I', bytes(d[o:o+4]))[0]
    d[o:o+4] = struct.pack('<I', (v + delta) & 0xFFFFFFFF)
ms_ = list(re.finditer(rb'\xD0(.{4})(.{4})(.{4})(.{4})(.{4})\xD1', bytes(d), re.S))
if len(ms_) != 1: sys.exit('expected exactly ONE #PF frame, found %d' % len(ms_))
m = ms_[0]
for gi in (2, 5):                                                # eip, esp
    o = m.start(gi)
    v = struct.unpack('<I', bytes(d[o:o+4]))[0]
    d[o:o+4] = struct.pack('<I', (v + delta) & 0xFFFFFFFF)
open(dst,'wb').write(bytes(d))
PY4
        }
        if ovf_shift "$OVFS" "$work/ovf.shift.e9" 0x1000 >/dev/null 2>&1 \
           && python3 "$REF" gradeoverflow "$work/ovf.shift.e9" "$KEND" "$FED_HEX" >/dev/null 2>&1; then
            # (f) SAME loader -> the absolute addresses must be compared, so this MUST be RED.
            xo="$(python3 "$REF" ovfcross "$KEND" "$FED_HEX" "tcg:qemu=$OVFS" "kvm:qemu=$work/ovf.shift.e9" 2>&1)"; xrc=$?
            if [[ "$xrc" -ne 0 ]] && grep -q 'same-loader (qemu) disagreement' <<<"$xo"; then
                pass=$((pass + 1))
            else
                fail_test "M-ovfcross(f): two arms of the SAME loader disagreed on every ABSOLUTE address and it was NOT caught (rc=$xrc) -- the same-loader comparison is decoration ($(echo "$xo" | tr '\n' ' '))"
            fi
            # (g) DIFFERENT loaders -> absolute addresses legitimately differ (this is the real Bochs
            #     case: it lands the module a page lower), so this MUST stay GREEN.
            xo="$(python3 "$REF" ovfcross "$KEND" "$FED_HEX" "tcg:qemu=$OVFS" "bochs:grub=$work/ovf.shift.e9" 2>&1)"; xrc=$?
            if [[ "$xrc" -eq 0 ]]; then
                pass=$((pass + 1))
            else
                fail_test "M-ovfcross(g): two arms on DIFFERENT loaders were REDded for differing absolute addresses (rc=$xrc) -- this is the real Bochs placement and must not false-RED ($(echo "$xo" | tr '\n' ' '))"
            fi
        else
            fail_test "M-ovfcross(f/g): could not build the uniform-shift stream, or it stopped grading GREEN on its own -- the same-loader check is left unproven, which is a failure, not a skip"
        fi
        # (e) a byte-identical COPY under a second label must NOT be rejected: two engines that agree
        #     completely is legitimate. This is the anti-false-RED twin of (d).
        cp "$OVFS" "$work/ovf.copy.e9"
        xo="$(python3 "$REF" ovfcross "$KEND" "$FED_HEX" "tcg:qemu=$OVFS" "kvm:qemu=$work/ovf.copy.e9" 2>&1)"; xrc=$?
        if [[ "$xrc" -eq 0 ]]; then
            pass=$((pass + 1))
        else
            fail_test "M-ovfcross(e): two byte-identical captures in DIFFERENT files were rejected (rc=$xrc) -- engines that agree completely must not false-RED ($(echo "$xo" | tr '\n' ' '))"
        fi
    else
        # FAIL CLOSED: no control capture means every check above was SKIPPED. A silently skipped
        # arm that still lets the battery print PASS is the fail-open class this suite exists to
        # refuse -- score it as a failure, never as "nothing to do".
        fail_test "M-ovfcross: no GREEN control overflow capture in 3 attempts -- the whole cross-engine arm was skipped; refusing to score the battery as if it had run"
    fi
fi

# hash-identity: the pinned host kernel must be unchanged across the whole battery (Codex change 1).
[[ "$(sha256sum "$KELF" | cut -d' ' -f1)" == "$KELF_SHA" ]] || fail_test "host kernel hash changed during the battery -- hash-identity violated"
echo "ouroboros mutation proof: pass=$pass fail=$fail"
if [[ -e "$HVMARK" ]]; then echo "FAIL: link39 HARNESS FAILURE -- a harness failure was flagged (feeder never LISTENING, QEMU launch error, or a boot with no completion witness); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
