#!/usr/bin/env bash
# Held-back MUTATION proof for Link 36 (sitopia, the syscall ROUND TRIP). The GATE
# (run_native_codegen_link36.sh) proves the COMPILER's emitted prefix+epilogue is BYTE-IDENTICAL to the
# silicon+KVM-proven reference (sitopia_ref.py). This harness proves each load-bearing DESIGN CHOICE in that
# reference is non-vacuous: it builds the reference image with ONE design defect injected (sitopia_ref mutate
# <mut>) and asserts the host grader (or the white-box body-scan) goes RED. The CLEAN build is asserted GREEN
# first on every graded path (control), so a vacuous grader is caught.
#
# RED taxonomy (each proves a distinct piece of the round-trip / sandbox is load-bearing):
#  THE NEW ROUND-TRIP MECHANISM:
#    M-noiret     (SYS_READ jmps body instead of iret) -> module never gets the byte / re-entry    (RED benign)
#    M-fakeread   (SYS_READ returns 0x5A literal, no RBR read) -> delivered byte != fed             (RED benign, fed != 0x5A)
#    M-nodispatch (no eax dispatch -> SYS_READ falls into SYS_EXIT) -> no read service              (RED benign)
#    M-iopl3frame+hostin (IOPL=3 grants CPL3 I/O) -> a module `in al,dx` does NOT #GP               (RED hostin)
#  THE TWO-BYTE DIFFERENTIAL (the sole defense vs a dead module) and the DISASM BODY SCAN:
#    M-constbl  (a DEAD module that bakes bl=0x5A, ignoring the delivered byte) -> passes a single
#               0x5A gate but FAILS the two-byte differential (answer != fed for any byte != 0x5A)  (RED benign)
#    M-bodyio   (an `in al,0x3F` injected into the conduit body) -> grades GREEN on the host (answer
#               still correct) but the white-box DISASM body-scan catches the I/O instruction       (RED body-scan)
#  RING ENTRY / SYSCALL GATE / PRIV-OP / U/S ISOLATION (carried from nokta, must still bite):
#    M-nopaging / M-canaryuser / M-nomodflip / M-nostackflip / M-pdesup / M-ptuser / M-dpl0frame /
#    M-callcpl0 / M-gatedpl0 / M-iopl3frame(out) / M-iomap(out) / M-tssesp0 / M-wrongcell           (RED)
#  HONEST ALLOCATION (carried from lodger, D20):
#    M-noexclude / M-noexclbuf / M-hardcodeaddr                                                      (RED)
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/sitopia_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
[[ -f "$REF" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing sitopia_ref.py)"; exit 1; }
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
PTADDR="$(python3 "$REF" ptaddr)"

# grade a (clean or mutated) ELF with a benign round-trip module + the socket feeder.
grade_benign() { # elf module fedbyte kind mutname -> 0 GREEN, 1 RED
    local elf="$1" mod="$2" byte="$3" kind="$4" mn="$5"
    local out="$work/e9.bin"; local k; k=$(python3 "$REF" kend "$mn")
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 >"$work/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$work/feed.log" && break; sleep 0.1; done
    grep -q LISTENING "$work/feed.log" 2>/dev/null || { echo "FAIL: link36 harness failure -- feeder never reached LISTENING (socket/QEMU launch dead; NOT a mutation bite)" >&2; : > "$HVMARK"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link36 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    wait "$fp" 2>/dev/null
    python3 "$REF" grade "$out" "$k" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1
}
grade_hostile() { # elf module kind mutname [cr2] -> 0 GREEN, 1 RED
    local elf="$1" mod="$2" kind="$3" mn="$4" cr2="${5:-}"
    local out="$work/e9.bin"; local k; k=$(python3 "$REF" kend "$mn")
    timeout 60 qemu-system-x86_64 -kernel "$elf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -monitor none -m 64M >/dev/null 2>"$out.qerr"
        grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link36 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # F2a: only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
    python3 "$REF" grade "$out" "$k" 00 "$kind" $cr2 >/dev/null 2>&1
}

if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link36 mutation (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi

# CONTROL: the clean reference must grade GREEN on EVERY graded path (else a vacuous grader).
python3 "$REF" cleanelf "$work/clean.elf"
grade_benign  "$work/clean.elf" "$work/mod_echo.bin" "$FX" echo -        && pass=$((pass+1)) || fail_test "CONTROL benign-echo: clean ref not GREEN -- grader vacuous"
grade_hostile "$work/clean.elf" "$work/mod_hin.bin"  hostin      -       && pass=$((pass+1)) || fail_test "CONTROL hostin: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_h.bin"    hostile     -       && pass=$((pass+1)) || fail_test "CONTROL hostile-out: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_w.bin"    pfault      -       && pass=$((pass+1)) || fail_test "CONTROL hostile-write: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_r.bin"    pfault_read -       && pass=$((pass+1)) || fail_test "CONTROL hostile-read: clean ref not GREEN"
grade_hostile "$work/clean.elf" "$work/mod_pt.bin"   pfault_pt   - "0x$PTADDR" && pass=$((pass+1)) || fail_test "CONTROL hostile-PT: clean ref not GREEN"

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

# --- the NEW round-trip mechanism ---
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
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link36 mutation sub-test(s) failed."; exit 1; fi
if [[ -e "$HVMARK" ]]; then echo "FAIL: link36 HARNESS FAILURE -- a feeder never reached LISTENING (dead socket/QEMU); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link36 mutation / sitopia: control clean build GREEN on benign+hostin+hostile-out+write+read+PT + $((pass)) checks -- the new round-trip (M-noiret/M-fakeread/M-nodispatch/M-iopl3frame+hostin), the two-byte differential vs a dead module (M-constbl) + the disasm body-scan (M-bodyio), the carried ring/gate/priv-op isolation (M-iopl3frame/M-iomap/M-callcpl0/M-dpl0frame/M-gatedpl0/M-tssesp0/M-wrongcell), the paging U/S partition (M-nopaging/M-canaryuser/M-nomodflip/M-nostackflip/M-pdesup/M-ptuser), and honest allocation (M-noexclude/M-noexclbuf/M-hardcodeaddr) each RED on the dual-substrate host grader / white-box scan)"
exit 0
