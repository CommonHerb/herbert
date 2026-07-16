#!/usr/bin/env bash
# Held-back MUTATION proof for Link 37 (geeking, THE KERNEL OUTLIVES ITS MODULE). The GATE
# (run_native_codegen_link37.sh) proves the COMPILER's emitted prefix+epilogue is BYTE-IDENTICAL to the
# silicon+KVM-proven reference (geeking_ref.py). This harness proves each load-bearing DESIGN CHOICE in that
# reference is non-vacuous: it builds the reference image with ONE design defect injected (geeking_ref mutate
# <mut>, or elf <design>) and asserts the host grader (or the white-box prefix-pin) goes RED. The CLEAN build
# is asserted GREEN first on every graded path (control: benign + hostiles fault-continue + KILL + #DB), so a
# vacuous grader is caught.
#
# RED taxonomy (each proves a distinct piece of the watchdog / fault-continue / carried sandbox is load-bearing):
#  THE ASYNC WATCHDOG-KILL (the new mechanism):
#    M-naive / M-oneshot_nodrain (timer DESIGNS): with a SLOW feeder the IF=0 COM1 poll latches a stale tick;
#       a free-running periodic PIT / a one-shot WITHOUT the stale-IRR drain delivers it into the benign's
#       resume -> the BENIGN is KILLED -> the drain is load-bearing                                  (SILICON-RED)
#    M-ifzero  (seed EFLAGS IF=0)  -> no tick at CPL3 -> the runaway is NEVER killed (hangs)          (SILICON-RED)
#    M-nokill  (RPL3 path iret-back instead of kill) -> the runaway resumes, never dies               (SILICON-RED)
#    M-wrongkillcell (kill status to the wrong cell) -> body reads stale [answer], not 'K'            (SILICON-RED)
#    M-rplkey  (drop the vec-0x20 RPL test) -> a CPL0 drain-window tick KILLS the benign too          (SILICON-RED, slow feeder)
#    M-killnoeoi (kill path skips EOI) -> perturbs the byte-pinned prefix (gate's EXACT-prefix pin REDs);
#       silicon-silent (post-kill IF=0 -> no further delivery) -- the honest white-box/silicon split  (WHITE-BOX-RED)
#  FAULT->CONTINUE (the survivable half, incl. the Codex-gift generalization):
#    M-panicshutdown (panic path reverts to shutdown) -> a CPL3 #DB/#DE/#UD HALTS the machine        (SILICON-RED)
#    M-shutdowngp / M-shutdownpf (#GP/#PF tail reverts to shutdown) -> hostile fault not named+continued (RED)
#  THE TWO-BYTE DIFFERENTIAL (carried, sole defense vs a dead module) + the DISASM BODY SCAN:
#    M-constbl (dead module bakes bl=0x5A) -> fails the two-byte differential                         (RED benign)
#    M-bodyio  (an `in` injected into the conduit body) -> host GREEN but the disasm body-scan catches it (RED scan)
#  CARRIED sitopia ROUND-TRIP + nokta RING/GATE/PRIV-OP/U-S + lodger ALLOCATION (must still bite under geeking):
#    M-noiret / M-fakeread / M-nodispatch / M-iopl3frame+hostin ; M-nopaging / M-canaryuser / M-nomodflip /
#    M-nostackflip / M-pdesup / M-ptuser / M-dpl0frame / M-callcpl0 / M-gatedpl0 / M-iopl3frame(out) /
#    M-iomap(out) / M-tssesp0 / M-wrongcell ; M-noexclude / M-noexclbuf / M-hardcodeaddr               (RED)
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/geeking_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
[[ -f "$REF" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing geeking_ref.py)"; exit 1; }
[[ -f "$feeder" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing feeder)"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead feeder/QEMU run trips this -> hard fail at end
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
host_T() { python3 -c "v=$2
print({'echo':v,'inc':(v+7)&0xFF,'xor':v^0x5A}['$1'])"; }
FX=60   # 0x3C (the differential's X; != the 0x5A fakeread/constbl baked literal)

python3 "$REF" module echo "$work/mod_echo.bin"
python3 "$REF" module HOIN "$work/mod_hin.bin"
python3 "$REF" module HOST "$work/mod_h.bin"
python3 "$REF" module HOSW "$work/mod_w.bin"
python3 "$REF" module HOSR "$work/mod_r.bin"
python3 "$REF" module HOSPT "$work/mod_pt.bin"
python3 "$REF" module ECHOFAT "$work/mod_fat.bin"
python3 "$REF" module CONSTBL "$work/mod_cb.bin"
python3 "$REF" module VICTIM "$work/mod_vict.bin"
python3 "$REF" module RTHV "$work/mod_rthv.bin"
python3 "$REF" module TF "$work/mod_tf.bin"
PTADDR="$(python3 "$REF" ptaddr)"

# grade a (clean or mutated) ELF with a benign round-trip module + the socket feeder.
grade_benign() { # elf module fedbyte kind mutname -> 0 GREEN, 1 RED
    local elf="$1" mod="$2" byte="$3" kind="$4" mn="$5"
    local out="$work/e9.bin"; local k; k=$(python3 "$REF" kend "$mn")
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 >"$work/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$work/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$work/feed.log" 2>/dev/null || { echo "FAIL: link37 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link37 harness failure -- QEMU launch error (socket run): $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure
    wait "$fp" 2>/dev/null
    python3 "$REF" grade "$out" "$k" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1
}
# geeking: a hostile probe now FAULTS *and continues* -> graded by gradefaultcont (witness BY VALUE + answer
# 'G'/'P' + no breach). A mutation that lets the hostile op LAND (no fault) -> no fault frame -> RED.
grade_hostile() { # elf module faultkind mutname [cr2] -> 0 GREEN, 1 RED
    local elf="$1" mod="$2" kind="$3" mn="$4" cr2="${5:-}"
    local out="$work/e9.bin"; local k; k=$(python3 "$REF" kend "$mn")
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -monitor none -m 64M >/dev/null 2>"$out.qerr"
    # fail-closed: a QEMU LAUNCH failure writes to stderr, while a clean run -- even a guest fault -- leaves
    # stderr EMPTY. Non-empty stderr is an unambiguous HARNESS failure, NOT a bite. (rc is NOT usable:
    # isa-debug-exit yields arbitrary odd exit codes >124 on legit completions.)
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link37 harness failure -- QEMU launch error in grade_hostile: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # only a NON-timeout stderr line is a launch failure
    python3 "$REF" gradefaultcont "$out" "$k" "$kind" $cr2 >/dev/null 2>&1
}
# geeking: the runaway victim (EB FE) must be ASYNC-KILLED at CPL3. No feeder (never syscalls). RED = not killed.
grade_victim() { # elf mutname -> 0 GREEN(killed), 1 RED(not killed / wrong frame)
    local elf="$1" mn="$2"; local out="$work/e9.bin"; local k; k=$(python3 "$REF" kend "$mn")
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$work/mod_vict.bin" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -serial null -monitor none -m 64M >/dev/null 2>"$out.qerr"
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link37 harness failure -- QEMU launch error in grade_victim: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure
    python3 "$REF" gradevictim "$out" "$k" >/dev/null 2>&1
}
# geeking: a generalized CPL3 fault (TF/#DB) must be NAMED+continued. RED = halted (panic+shutdown).
grade_generic() { # elf module mutname -> 0 GREEN(continued), 1 RED(halted)
    local elf="$1" mod="$2" mn="$3"; local out="$work/e9.bin"; local k; k=$(python3 "$REF" kend "$mn")
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -serial null -monitor none -m 64M >/dev/null 2>"$out.qerr"
    # fail-closed: a QEMU LAUNCH failure writes to stderr, while a clean run -- even a guest fault -- leaves
    # stderr EMPTY. Non-empty stderr is an unambiguous HARNESS failure, NOT a bite. (rc is NOT usable:
    # isa-debug-exit yields arbitrary odd exit codes >124 on legit completions.)
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link37 harness failure -- QEMU launch error in grade_generic: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # only a NON-timeout stderr line is a launch failure
    python3 "$REF" gradegeneric "$out" "$k" >/dev/null 2>&1
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link37 mutation (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi

# CONTROL: the clean reference must grade GREEN on EVERY graded path (else a vacuous grader).
python3 "$REF" cleanelf "$work/clean.elf"
grade_benign  "$work/clean.elf" "$work/mod_echo.bin" "$FX" echo -        && pass=$((pass+1)) || fail_test "CONTROL benign-echo: clean ref not GREEN -- grader vacuous"
grade_hostile "$work/clean.elf" "$work/mod_hin.bin"  hostin      -       && pass=$((pass+1)) || fail_test "CONTROL hostin: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_h.bin"    hostile     -       && pass=$((pass+1)) || fail_test "CONTROL hostile-out: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_w.bin"    pfault      -       && pass=$((pass+1)) || fail_test "CONTROL hostile-write: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_r.bin"    pfault_read -       && pass=$((pass+1)) || fail_test "CONTROL hostile-read: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_pt.bin"   pfault_pt   - "0x$PTADDR" && pass=$((pass+1)) || fail_test "CONTROL hostile-PT: clean ref not GREEN"
# geeking NEW controls: the clean kernel KILLS the runaway victim and CONTINUES past a generalized CPL3 fault.
grade_victim  "$work/clean.elf" -                                && pass=$((pass+1)) || fail_test "CONTROL victim: clean ref does not async-kill the EB FE spinner -- grader vacuous"
grade_generic "$work/clean.elf" "$work/mod_tf.bin" -             && pass=$((pass+1)) || fail_test "CONTROL generic-fault: clean ref does not name+continue a CPL3 #DB -- grader vacuous"

# M-constbl is a MODULE forge graded on the CLEAN kernel. It proves the TWO-BYTE differential is load-bearing:
# fed 0x5A it would PASS a (broken) single-0x5A gate; fed FX != 0x5A it FAILS -> the second byte catches it.
grade_benign "$work/clean.elf" "$work/mod_cb.bin" 90 echo - \
    && { echo "  (note: M-constbl fed 0x5A is GREEN -- exactly the single-byte hole the differential closes)"; pass=$((pass+1)); } \
    || fail_test "M-constbl baseline: const-0x5A module not GREEN at its own baked byte (test wiring broken)"
if grade_benign "$work/clean.elf" "$work/mod_cb.bin" "$FX" echo -; then
    fail_test "M-constbl (dead module): graded GREEN at fed=$FX != 0x5A -- the two-byte differential is NOT load-bearing"
else
    pass=$((pass+1))
fi

# M-bodyio is a BODY forge caught by the white-box DISASM body-scan (it grades GREEN on the host, so only the
# scan catches it). Build the mutated ELF, decode the body span, assert it contains an I/O instruction.
python3 "$REF" mutate bodyio "$work/bodyio.elf"
bio_filesz=$(python3 -c "import struct;print(struct.unpack('<I',open('$work/bodyio.elf','rb').read()[68:72])[0])")
bio_codelen=$((bio_filesz-12)); bio_bodylen=$((bio_codelen-24564-58))
dd if="$work/bodyio.elf" of="$work/bodyio.body" bs=1 skip=$((4108+24564)) count="$bio_bodylen" status=none 2>/dev/null
bio_io=$(objdump -D -b binary -m i386 -M att "$work/bodyio.body" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}' | grep -cE '^(in|inb|inl|out|outb|outl|ins|insb|insl|insw|outs|outsb|outsl|outsw)\b')
if [[ "$bio_io" -ge 1 ]]; then
    # confirm it ALSO grades GREEN on the host (proving the disasm scan -- not the host grader -- is the
    # load-bearing control for the no-body-I/O property).
    if grade_benign "$work/bodyio.elf" "$work/mod_echo.bin" "$FX" echo bodyio; then
        echo "  (M-bodyio: in al,0x3F in the body -> host grader GREEN but the disasm body-scan catches it, io_count=$bio_io)"
    fi
    pass=$((pass+1))
else
    fail_test "M-bodyio: injected body I/O not detected by the disasm scan (io_count=$bio_io) -- the body-scan does NOT bite"
fi

mutate_benign_red() { # mut module fedbyte kind label
    local mut="$1" mod="$2" byte="$3" kind="$4" label="$5"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    if grade_benign "$work/$mut.elf" "$mod" "$byte" "$kind" "$mut"; then
        fail_test "M-$mut ($label): mutation graded GREEN -- NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
}
mutate_hostile_red() { # mut module kind label [cr2]
    local mut="$1" mod="$2" kind="$3" label="$4" cr2="${5:-}"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    if grade_hostile "$work/$mut.elf" "$mod" "$kind" "$mut" "$cr2"; then
        fail_test "M-$mut ($label): mutation graded GREEN -- NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
}

mutate_victim_red() { # mut label
    local mut="$1" label="$2"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    if grade_victim "$work/$mut.elf" "$mut"; then
        fail_test "M-$mut ($label): runaway victim still GREEN (killed) -- mutation NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
}
mutate_generic_red() { # mut module label
    local mut="$1" mod="$2" label="$3"
    python3 "$REF" mutate "$mut" "$work/$mut.elf"
    if grade_generic "$work/$mut.elf" "$mod" "$mut"; then
        fail_test "M-$mut ($label): generalized CPL3 fault still GREEN (named+continued) -- mutation NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
}
# M-naive / M-oneshot_nodrain are TIMER DESIGNS (not mut knobs). With a SLOW feeder (--delay 2 > the ~55ms
# one-shot period), the benign's IF=0 COM1 poll latches a stale tick; a periodic free-running PIT (naive) or
# a one-shot WITHOUT the stale-IRR drain (oneshot_nodrain) then delivers it 0-1 instructions into the benign's
# resume -> the BENIGN round-trip module is KILLED (answer 'K') -> RED. (Proven in step-0; the drain is the fix.)
design_kills_benign_red() { # design label
    local design="$1" label="$2"
    python3 "$REF" elf "$design" "$work/$design.elf"
    local k; k=$(python3 "$REF" kend2 "$design")
    local out="$work/e9.bin"; local port; port=$(free_port)
    python3 "$feeder" "$port" "$FX" --delay 2 --hold 6 >"$work/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$work/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$work/feed.log" 2>/dev/null || { echo "FAIL: link37 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 60 qemu-system-x86_64 -kernel "$work/$design.elf" -initrd "$work/mod_echo.bin" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link37 harness failure -- QEMU launch error (socket run): $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure
    wait "$fp" 2>/dev/null
    if python3 "$REF" gradebenign "$out" "$k" "$(printf '%x' "$FX")" echo >/dev/null 2>&1; then
        fail_test "M-$design ($label): SLOW-fed benign SURVIVED -- the drain/one-shot is NOT load-bearing (no stale-tick kill)"
    else
        pass=$((pass + 1))
    fi
}

# CONTROL (completeness-critic gift): a CORRECT kernel must SURVIVE the --delay 2 SLOW feeder -- the drain
# absorbs the stale one-shot tick. This pins the slow-feeder regime as survivable-by-a-correct-kernel, so the
# naive/oneshot_nodrain/rplkey RED mutations below cannot go VACUOUSLY red (a future change that made the slow
# feeder kill EVERYTHING, clean included, would be caught HERE, not silently pass as "the mutation bit").
slow_benign_clean_green() {
    local out="$work/e9.bin"; local k; k=$(python3 "$REF" kend -); local port; port=$(free_port)
    python3 "$feeder" "$port" "$FX" --delay 2 --hold 6 >"$work/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$work/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$work/feed.log" 2>/dev/null || { echo "FAIL: link37 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 60 qemu-system-x86_64 -kernel "$work/clean.elf" -initrd "$work/mod_echo.bin" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link37 harness failure -- QEMU launch error (socket run): $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure
    wait "$fp" 2>/dev/null
    python3 "$REF" gradebenign "$out" "$k" "$(printf '%x' "$FX")" echo >/dev/null 2>&1
}
slow_benign_clean_green && pass=$((pass+1)) || fail_test "CONTROL slow-benign: the CLEAN kernel does NOT survive the --delay 2 feeder -- the slow-feeder mutations would be VACUOUS (drain attribution lost)"

# --- geeking NEW: THE KERNEL OUTLIVES ITS MODULE (each proves a distinct piece of the watchdog/continue) ---
design_kills_benign_red naive          "free-running periodic PIT, no drain -> stale tick kills the SLOW-fed benign"
design_kills_benign_red oneshot_nodrain "one-shot WITHOUT the stale-IRR drain -> latched poll-tick kills the benign"
mutate_victim_red  ifzero      "seed EFLAGS IF=0 (0x002) -> no timer at CPL3 -> runaway NEVER killed (hangs)"
mutate_victim_red  nokill      "vec-0x20 RPL3 path EOI+iret back instead of kill -> runaway resumes, never dies"
mutate_victim_red  wrongkillcell "kill status to the flags cell -> body reads stale [answer], not 'K'"
mutate_generic_red panicshutdown "$work/mod_tf.bin" "panic path reverts to unconditional shutdown -> a CPL3 #DB HALTS the machine"
mutate_hostile_red shutdowngp  "$work/mod_h.bin"  hostile "#GP tail reverts to shutdown -> hostile out is NOT named+continued"
mutate_hostile_red shutdownpf  "$work/mod_w.bin"  pfault  "#PF tail reverts to shutdown -> hostile write is NOT named+continued"
# M-rplkey: drop the vec-0x20 RPL test -> a CPL0 drain-window tick now takes the KILL path too; with the SLOW
# feeder the stale poll-tick delivered in the drain window kills the BENIGN (CPL0 frame) -> answer 'K' -> RED.
python3 "$REF" mutate rplkey "$work/rplkey.elf"
rk_k=$(python3 "$REF" kend rplkey); rk_out="$work/e9.bin"; rk_port=$(free_port)
python3 "$feeder" "$rk_port" "$FX" --delay 2 --hold 6 >"$work/feed.log" 2>&1 & rk_fp=$!
for i in $(seq 1 40); do grep -q LISTENING "$work/feed.log" && break; sleep 0.1; done
if ! grep -q LISTENING "$work/feed.log" 2>/dev/null; then
    echo "FAIL: link37 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$rk_fp" 2>/dev/null; wait "$rk_fp" 2>/dev/null   # F2c: kill+reap the feeder and SKIP QEMU/wait (never mark-and-continue -- hang risk)
else
    timeout 60 qemu-system-x86_64 -kernel "$work/rplkey.elf" -initrd "$work/mod_echo.bin" -debugcon file:"$rk_out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$rk_port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$rk_out.qerr"
    grep -qvE 'terminating on signal' "$rk_out.qerr" 2>/dev/null && { echo "FAIL: link37 harness failure -- QEMU launch error (rplkey run): $(grep -vE 'terminating on signal' "$rk_out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure
    wait "$rk_fp" 2>/dev/null
    if python3 "$REF" gradebenign "$rk_out" "$rk_k" "$(printf '%x' "$FX")" echo >/dev/null 2>&1; then
        fail_test "M-rplkey (drop RPL-key): SLOW-fed benign SURVIVED -- the RPL discard of a CPL0 tick is NOT load-bearing"
    else
        pass=$((pass + 1))
    fi
fi
# M-killnoeoi: WHITE-BOX-RED, silicon-silent (post-kill IF=0 -> no further delivery, so the missing EOI is
# invisible on silicon -- the honest split). The proof is that it perturbs the byte-pinned prefix, so the
# gate's EXACT-prefix pin would RED it: assert the mutated ref prefix != the clean ref prefix.
kne_dirty=$(python3 "$REF" mutate killnoeoi "$work/kne.elf" >/dev/null 2>&1; python3 -c "
import struct
def pfx(p):
    d=open(p,'rb').read(); return d[4108:4108+24564]
import sys
print('DIFF' if pfx('$work/kne.elf')!=pfx('$work/clean.elf') else 'SAME')")
if [[ "$kne_dirty" == "DIFF" ]]; then pass=$((pass+1)); else fail_test "M-killnoeoi: mutated prefix == clean prefix -- the EXACT-prefix gate would NOT catch a missing kill-EOI"; fi

# --- the carried sitopia round-trip mechanism (still bites under geeking) ---
mutate_benign_red  noiret     "$work/mod_echo.bin" "$FX"  echo   "SYS_READ jmps body instead of iret -> no re-entry"
mutate_benign_red  fakeread    "$work/mod_echo.bin" 167   echo   "SYS_READ returns 0x5A literal -> delivered byte != fed (fed 0xA7 != baked 0x5A)"
mutate_benign_red  nodispatch  "$work/mod_echo.bin" "$FX"  echo   "no eax dispatch -> SYS_READ falls into SYS_EXIT"
mutate_hostile_red iopl3frame  "$work/mod_hin.bin"  hostin "IOPL=3 -> a module in al,dx does NOT #GP"
# --- ring boundary / syscall gate / priv-op (carried from nokta, must still bite under the round trip) ---
mutate_hostile_red iopl3frame  "$work/mod_h.bin"    hostile "IOPL=3 -> hostile out permitted"
mutate_hostile_red iomap       "$work/mod_h.bin"    hostile "TSS IOPB grants port 0xE9 -> hostile out permitted"
mutate_hostile_red callcpl0    "$work/mod_h.bin"    hostile "CPL0 call instead of iret -> hostile out undetected"
mutate_benign_red  dpl0frame   "$work/mod_echo.bin" "$FX"  echo   "iret pushes ring-0 cs -> no CPL3 entry"
mutate_benign_red  gatedpl0    "$work/mod_echo.bin" "$FX"  echo   "exit gate DPL0 -> benign int 0x30 #GPs"
mutate_benign_red  tssesp0     "$work/mod_echo.bin" "$FX"  echo   "unmapped esp0 -> frame push triple-faults"
mutate_benign_red  wrongcell   "$work/mod_echo.bin" "$FX"  echo   "store status to wrong cell -> stale body read"
# --- paging U/S partition (carried from nokta) ---
mutate_hostile_red nopaging    "$work/mod_w.bin"    pfault  "flat PM -> hostile write lands"
mutate_hostile_red canaryuser  "$work/mod_w.bin"    pfault  "kernel target page User -> write lands"
mutate_benign_red  nomodflip   "$work/mod_echo.bin" "$FX"  echo   "module code page Supervisor -> CPL3 fetch #PF"
mutate_benign_red  nostackflip "$work/mod_echo.bin" "$FX"  echo   "module stack page Supervisor -> own-write #PF"
mutate_benign_red  pdesup      "$work/mod_echo.bin" "$FX"  echo   "PDEs Supervisor -> module pages effective-Supervisor"
mutate_hostile_red ptuser      "$work/mod_pt.bin"   pfault_pt "PT page User -> CPL3 patches its own PTE" "0x$PTADDR"
# --- honest allocation (carried from lodger, D20) ---
mutate_benign_red  noexclude   "$work/mod_echo.bin" "$FX"  echo   "skip all exclusions -> alloc==kernel; recompute mismatch"
mutate_benign_red  noexclbuf   "$work/mod_echo.bin" "$FX"  echo   "exclude only kernel+module -> overlaps loader buffers"
mutate_benign_red  hardcodeaddr "$work/mod_fat.bin" "$FX"  echo   "fixed alloc literal -> recompute mismatch; overlaps FAT"

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link37 mutation sub-test(s) failed."; exit 1; fi
if [[ -e "$HVMARK" ]]; then echo "FAIL: link37 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link37 mutation / geeking: control clean build GREEN on benign+hostin+hostile-out/write/read/PT (fault-continue) + the runaway KILL + a generalized #DB continue + $((pass)) checks -- THE KERNEL OUTLIVES ITS MODULE: M-naive/M-oneshot_nodrain (stale tick kills the slow-fed benign -> the drain is load-bearing), M-ifzero/M-nokill/M-wrongkillcell (runaway not killed / wrong status), M-rplkey (a CPL0 tick kills the benign -> the RPL discard is load-bearing), M-panicshutdown (a CPL3 #DB halts the box -> the generalized fault->continue is load-bearing), M-shutdowngp/M-shutdownpf (#GP/#PF not named+continued), M-killnoeoi (white-box-RED: perturbs the byte-pinned prefix; silicon-silent honest split); PLUS the carried sitopia round-trip (M-noiret/M-fakeread/M-nodispatch/M-iopl3frame+hostin), the two-byte differential (M-constbl) + disasm body-scan (M-bodyio), the ring/gate/priv-op isolation (M-iopl3frame/M-iomap/M-callcpl0/M-dpl0frame/M-gatedpl0/M-tssesp0/M-wrongcell), the paging U/S partition (M-nopaging/M-canaryuser/M-nomodflip/M-nostackflip/M-pdesup/M-ptuser), and honest allocation (M-noexclude/M-noexclbuf/M-hardcodeaddr) each RED on the dual-substrate host grader / white-box scan)"
exit 0
