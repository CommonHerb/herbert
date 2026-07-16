#!/usr/bin/env bash
# Mutation proof for native-codegen link 65 (gyre): each gate leg that guards CONSTANT-STACK
# TAIL CALLS must BITE (go RED) when the capability is broken. COMPILER mutations (the seed
# mints a mutant compiler from a mutated fragment -- C-free) prove the detection + sizing
# invariants; IMAGE forges prove the runtime/white-box legs. Per the charter, M-notco alone
# does not prove constant stack (an emitter could keep E9 yet leak) -- M-reclaim closes that.
#   M-notco       : COMPILER -- nc_tap_is_tco forced false -> every tail site lowers E8
#                   (consistent sizing; compiles fine) -> the 1,000,000-deep tail run
#                   OVERFLOWS (no de40ad frame / exit 227) -> the deep-completes leg RED.
#   M-reclaim     : IMAGE -- leave the E9, NOP the 4-byte `lea rsp,[rbp+8]` reclamation
#                   inside the tail window -> the deep run must produce ZERO well-formed
#                   grading frames (e9=='', the SPECIFIC constant-stack failure -- not
#                   merely "not the genuine de40ad/227", which could also be satisfied by
#                   a wrong-but-still-completed frame) AND the site-aware white-box rejects
#                   the broken window. Non-completion is distinguished from an emulator/
#                   harness error by requiring the debugcon device to have attached and
#                   QEMU's stderr to be empty (GATE-TEETH A4).
#   M-shuffle     : IMAGE -- naive-ORDER shuffle: swap the two copy-loop source disp8s in
#                   the SWAP probe's tail window (args delivered un-permuted) -> the swap
#                   probe must complete with the EXACT predicted wrong outcome (e9=='de0dad'
#                   AND exit 121 -- the hand-derived un-swapped result; genuine is
#                   de0bad/117), not merely "any non-genuine outcome" incl. a timeout or
#                   crash (GATE-TEETH A5).
#   M-wrongtarget : IMAGE -- tail E9 rel32 +1 (jmp lands INSIDE the callee prologue, not at
#                   its entry) -> white-box RED (target is not an entry) + runtime RED.
#   M-nontailE9   : IMAGE -- flip the NON-tail backward recursive E8 opcode to E9 -> the
#                   site accounting RED (non-tail must STAY E8; an unaccounted bare E9
#                   appears where a backward-E8-to-entry was pinned).
#   M-610         : COMPILER -- non-tail op-20 size +1 -> the MAIN-block length invariant
#                   fires (ERR 610), the probe does NOT compile.
#   M-611         : COMPILER -- nc_tap_tail_len 24->23 (tail windows undersized; main has
#                   no tail sites so ERR 610 passes) -> the CALLEE-block length invariant
#                   fires (ERR 611), the probe does NOT compile.
#   M-604         : COMPILER -- PD loop 512->511 -> the final code-length invariant fires
#                   (ERR 604), the probe does NOT compile.
#   M-golden      : IMAGE -- perturb one byte -> the committed-golden hash pin RED.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/gyre_goldens"
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: link65-mutation ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then echo "NOTE: no QEMU; link65-mutation skipped locally (authoritative in CI)."; [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]] && { echo "FAIL: REQUIRE_EMU=1 but no QEMU"; exit 1; }; exit 0; fi
expect_red() { if [[ "$1" -ne 0 ]]; then pass=$((pass + 1)); else fail_test "$2 did not bite"; fi; }

# ---- probe sources (identical to the gate's) ----
T1D_SRC='func down(n, acc):\n    if n == 0: return acc end\n    return down(n - 1, acc + 4294967296)\nend\nfunc main(): return down(1000000, 0) end\n'
T1T_SRC='func down(n, acc):\n    if n == 0: return acc end\n    return down(n - 1, acc + 4294967296)\nend\nfunc main(): return down(6, 0) end\n'
T3D_SRC='func sw(a, b, n):\n    if n == 0: return a + a + b end\n    return sw(b, a, n - 1)\nend\nfunc main(): return sw(21474836480, 12884901888, 1000001) end\n'
T8T_SRC='func nt(n):\n    if n == 0: return 8589934592 end\n    return nt(n - 1) + 8589934592\nend\nfunc main(): return nt(4) end\n'
compile_with() { # compiler src out
    local cc="$1" src="$2" out="$3"
    local cdir="$tmp/c.$RANDOM"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-long64\n%b' "$src" > "$cdir/p.herb"
    ( cd "$cdir" && "$cc" < p.herb > "$cdir/out.txt" 2>&1 )
    LAST_MSG="$(head -1 "$cdir/out.txt" 2>/dev/null)"
    [[ -f "$cdir/a.out" ]] || return 1
    cp "$cdir/a.out" "$out"
}
boot() { # elf -> sets GOT_RC GOT_E9 GOT_ERR GOT_DEBUGCON
    local elf="$1"; local W="$tmp/b.$RANDOM"; mkdir -p "$W"
    timeout 120 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M \
        2>"$W/err.txt"
    GOT_RC=$?; GOT_E9=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    GOT_ERR="$(cat "$W/err.txt" 2>/dev/null)"
    GOT_DEBUGCON=0; [[ -f "$W/e9.bin" ]] && GOT_DEBUGCON=1
}
# genuine QEMU/harness launch: the debugcon device attached and QEMU printed nothing to
# stderr -- distinguishes a guest-side non-completion (the divergence under test) from an
# emulator/harness error that would ALSO show e9=='' for the wrong reason (GATE-TEETH A4).
boot_launched_cleanly() { [[ "$GOT_DEBUGCON" -eq 1 && -z "$GOT_ERR" ]]; }
mint_mutant() { # mutated-fragment out-compiler
    local frag="$1" out="$2"; local md="$tmp/m.$RANDOM"; mkdir -p "$md"
    ( cd "$md" && "$NATIVE_CODEGEN_COMPILER" < "$frag" >/dev/null 2>mint.err )
    [[ -f "$md/a.out" ]] || { fail_test "mutant compiler did not mint ($(head -1 "$md/mint.err"))"; return 1; }
    cp "$md/a.out" "$out"; chmod +x "$out"
}

# ---- base images (genuine compiler = the committed seed) ----
base_t1d="$tmp/t1d.elf"; compile_with "$NATIVE_CODEGEN_COMPILER" "$T1D_SRC" "$base_t1d" || { echo "FAIL: link65-mutation (base t1d did not compile)"; exit 1; }
base_t1t="$tmp/t1t.elf"; compile_with "$NATIVE_CODEGEN_COMPILER" "$T1T_SRC" "$base_t1t" || { echo "FAIL: link65-mutation (base t1t did not compile)"; exit 1; }
base_t3d="$tmp/t3d.elf"; compile_with "$NATIVE_CODEGEN_COMPILER" "$T3D_SRC" "$base_t3d" || { echo "FAIL: link65-mutation (base t3d did not compile)"; exit 1; }
base_t8t="$tmp/t8t.elf"; compile_with "$NATIVE_CODEGEN_COMPILER" "$T8T_SRC" "$base_t8t" || { echo "FAIL: link65-mutation (base t8t did not compile)"; exit 1; }

# ---- image forger ----
PY="$tmp/forge.py"; cat > "$PY" <<'PYEOF'
import sys,struct
elf=bytearray(open(sys.argv[1],'rb').read()); mode=sys.argv[2]
co=4108
filesz=struct.unpack('<I',elf[68:72])[0]; code=bytes(elf[co:co+filesz-12])
RECL=bytes.fromhex('4c895d08488d65084c89d5')
def tail_e9s():
    out=[]
    i=code.find(RECL)
    while i>=0:
        out.append(i+len(RECL))   # offset of the E9 opcode
        i=code.find(RECL,i+1)
    return out
if mode=='reclaim':
    # NOP the lea rsp,[rbp+8] (bytes 4..7 of RECL) before the FIRST tail E9; E9 stays.
    i=code.find(RECL); assert i>=0, "no tail window"
    elf[co+i+4:co+i+8]=b'\x90\x90\x90\x90'
elif mode=='shuffle':
    # naive-order shuffle on the SWAP probe (3-arg window): swap the src disp8 of the
    # first two copy pairs (loads at window+8 and window+17; disp at +12 / +21).
    PRE=bytes.fromhex('4c8b5d084c8b5500')
    i=code.find(PRE); assert i>=0, "no tail preamble"
    a,b=co+i+12,co+i+21
    assert elf[a]==0x10 and elf[b]==0x08, (hex(elf[a]),hex(elf[b]))
    elf[a],elf[b]=0x08,0x10
elif mode=='wrongtarget':
    e9=tail_e9s(); assert e9, "no tail E9"
    o=co+e9[0]+1
    rel=struct.unpack('<i',bytes(elf[o:o+4]))[0]
    struct.pack_into('<i',elf,o,rel+1)
elif mode=='nontailE9':
    # flip the backward NON-tail recursive E8 to E9 (find backward E8 to an 0x55 entry)
    done=False
    for i in range(56,len(code)-5):
        if code[i]==0xE8:
            rel=struct.unpack('<i',code[i+1:i+5])[0]; t=i+5+rel
            if rel<0 and 0<=t<len(code) and code[t]==0x55:
                elf[co+i]=0xE9; done=True; break
    assert done, "no backward E8"
elif mode=='golden':
    elf[5000]^=0xFF
open(sys.argv[3],'wb').write(bytes(elf))
PYEOF
forge() { python3 "$PY" "$2" "$1" "$3" && [[ -f "$3" ]] || { fail_test "forge $1 failed"; return 1; }; }

# ---- the gate's site-aware white-box, reused verbatim on forged images ----
GATE="$script_dir/run_native_codegen_link65.sh"
wb_extract="$tmp/wb65.py"
awk '/^cat > "\$WB" <<.PY.$/{f=1;next} f&&/^PY$/{exit} f' "$GATE" > "$wb_extract"
[[ -s "$wb_extract" ]] || { echo "FAIL: link65-mutation (could not extract the gate white-box)"; exit 1; }
wb() { python3 "$wb_extract" "$1" "$2" >/dev/null 2>&1; }

# ---- controls: the un-forged bases PASS the white-box (each RED below is the forge's) ----
wb "$base_t1d" t1d && pass=$((pass + 1)) || fail_test "control: base t1d fails white-box (checker broken)"
wb "$base_t3d" t3d && pass=$((pass + 1)) || fail_test "control: base t3d fails white-box (checker broken)"
wb "$base_t8t" t8t && pass=$((pass + 1)) || fail_test "control: base t8t fails white-box (checker broken)"

# GATE-TEETH A6: mutation non-vacuity. The controls above only ever exercised the white-box;
# add a genuine BASE BOOT here too, so this file independently proves its own bases are real
# (constant-stack, correct value) WITHOUT relying on the separate positive gate
# (run_native_codegen_link65.sh) ever having run.
boot "$base_t1d"
if boot_launched_cleanly && [[ "$GOT_RC" -eq 227 && "$GOT_E9" == "de40ad" ]]; then
    echo "control: base t1d BOOTS genuinely (rc=227 e9=de40ad, 1,000,000-deep constant-stack tail recursion completes) -- mutation harness is independently non-vacuous"
    pass=$((pass + 1))
else
    fail_test "control: base t1d does not boot genuinely (rc=$GOT_RC e9='$GOT_E9' err='$GOT_ERR' debugcon=$GOT_DEBUGCON; want rc=227 e9=de40ad) -- mutation harness base is broken"
fi

# ============ COMPILER mutations (mint via the committed seed; C-free) ============
# --- M-notco: tail detection forced FALSE -> deep tail run overflows -> RED
mfrag="$tmp/frag_notco.herb"
python3 - "$backend" "$mfrag" <<'PYEOF'
import sys
src=open(sys.argv[1]).read()
old="    if get(funcs, get(code, i).1).2 == nparams:\n        return true\n    end\n    return false\nend"
assert src.count(old)==1, "nc_tap_is_tco tail-detection site not found"
open(sys.argv[2],'w').write(src.replace(old,old.replace("return true","return false"),1))
PYEOF
mutc="$tmp/mutc_notco"
if mint_mutant "$mfrag" "$mutc"; then
    m="$tmp/m_notco.elf"
    if compile_with "$mutc" "$T1D_SRC" "$m"; then
        boot "$m"
        # fail-closed (GATE-TEETH A4, as M-reclaim already does): a dead/timed-out QEMU also shows rc!=227 /
        # e9!='' -- gate the RED on a CLEAN launch (debugcon attached + no QEMU stderr) and a non-timeout rc,
        # so an emulator/harness failure is a HARD FAIL, never mistaken for the overflow bite.
        if ! boot_launched_cleanly || [[ "$GOT_RC" -eq 124 ]]; then
            fail_test "M-notco: HARNESS failure (QEMU not cleanly launched / timed out: rc=$GOT_RC debugcon=$GOT_DEBUGCON err='$GOT_ERR') -- NOT a bite"
        elif [[ "$GOT_RC" -ne 227 || "$GOT_E9" != "de40ad" ]]; then
            echo "M-notco bit RED: tail detection disabled -> 1,000,000-deep tail run did NOT complete (rc=$GOT_RC e9='${GOT_E9}'; genuine de40ad/227), and QEMU launched cleanly (not a harness failure)"
            pass=$((pass + 1))
        else
            fail_test "M-notco: deep tail run STILL completed genuinely with detection disabled"
        fi
        wb "$m" t1d; expect_red $? "M-notco (white-box: no tail windows)"
    else
        fail_test "M-notco: probe did not compile under the no-TCO mutant ($LAST_MSG)"
    fi
fi

# --- M-610: non-tail op-20 size +1 -> MAIN-block length invariant (ERR 610), no a.out
mfrag="$tmp/frag_610.herb"
python3 - "$backend" "$mfrag" <<'PYEOF'
import sys
src=open(sys.argv[1]).read()
old="        return 5 + cl + 1\n    end\n    if op == 45:\n        return 18\n"
assert src.count(old)==1, "nc_tap_op_size op-20 arm not found"
open(sys.argv[2],'w').write(src.replace(old,old.replace("5 + cl + 1","5 + cl + 2"),1))
PYEOF
mutc="$tmp/mutc_610"
if mint_mutant "$mfrag" "$mutc"; then
    if compile_with "$mutc" "$T1D_SRC" "$tmp/m610.elf"; then
        fail_test "M-610: probe compiled despite a mis-sized main-block call"
    elif echo "$LAST_MSG" | grep -q 'ERR 610'; then
        echo "M-610 bit RED: main-block length invariant fired ($LAST_MSG)"
        pass=$((pass + 1))
    else
        fail_test "M-610: no a.out but the failure was not ERR 610 ($LAST_MSG)"
    fi
fi

# --- M-611: tail window undersized (24->23) -> CALLEE-block length invariant (ERR 611)
mfrag="$tmp/frag_611.herb"
python3 - "$backend" "$mfrag" <<'PYEOF'
import sys
src=open(sys.argv[1]).read()
old="    return 24 + 9 * nargs\n"
assert src.count(old)==1, "nc_tap_tail_len site not found"
open(sys.argv[2],'w').write(src.replace(old,"    return 23 + 9 * nargs\n",1))
PYEOF
mutc="$tmp/mutc_611"
if mint_mutant "$mfrag" "$mutc"; then
    if compile_with "$mutc" "$T1D_SRC" "$tmp/m611.elf"; then
        fail_test "M-611: probe compiled despite a mis-sized tail window"
    elif echo "$LAST_MSG" | grep -q 'ERR 611'; then
        echo "M-611 bit RED: callee-block length invariant fired ($LAST_MSG)"
        pass=$((pass + 1))
    else
        fail_test "M-611: no a.out but the failure was not ERR 611 ($LAST_MSG)"
    fi
fi

# --- M-604: PD loop 512->511 -> final code-length invariant (ERR 604)
mfrag="$tmp/frag_604.herb"
python3 - "$backend" "$mfrag" <<'PYEOF'
import sys
src=open(sys.argv[1]).read()
old="func nc_tap_emit_pd_loop(buf, i, guard_2m):\n    if i >= 512:\n"
assert src.count(old)==1, "nc_tap_emit_pd_loop site not found"
open(sys.argv[2],'w').write(src.replace(old,old.replace("512","511"),1))
PYEOF
mutc="$tmp/mutc_604"
if mint_mutant "$mfrag" "$mutc"; then
    if compile_with "$mutc" "$T1D_SRC" "$tmp/m604.elf"; then
        fail_test "M-604: probe compiled despite a short PD"
    elif echo "$LAST_MSG" | grep -q 'ERR 604'; then
        echo "M-604 bit RED: final code-length invariant fired ($LAST_MSG)"
        pass=$((pass + 1))
    else
        fail_test "M-604: no a.out but the failure was not ERR 604 ($LAST_MSG)"
    fi
fi

# ============ IMAGE forges (on genuine images) ============
# --- M-reclaim: E9 stays, reclamation NOPed -> deep run RED + white-box RED
# GATE-TEETH A4: require the SPECIFIC constant-stack failure -- zero well-formed grading
# frames (e9==''), not merely "!= genuine" (which would also (mis)pass a wrong-but-still-
# completed frame, a different failure mode than the one this mutation is meant to prove).
# boot_launched_cleanly distinguishes genuine non-completion from an emulator/harness error.
forge reclaim "$base_t1d" "$tmp/m_reclaim.elf" && {
    boot "$tmp/m_reclaim.elf"
    if [[ "$GOT_E9" == "" ]] && boot_launched_cleanly; then
        echo "M-reclaim bit RED: E9 kept but reclamation removed -> deep run produced ZERO well-formed grading frames (e9=''; rc=$GOT_RC; genuine de40ad/227) -- not merely a different outcome, the SPECIFIC constant-stack failure, and QEMU launched cleanly (debugcon attached, no stderr) so this is not an emulator/harness error"
        pass=$((pass + 1))
    else
        fail_test "M-reclaim: deep run did NOT produce the specific constant-stack failure (rc=$GOT_RC e9='${GOT_E9}' err='$GOT_ERR' debugcon=$GOT_DEBUGCON; want e9='' with a clean QEMU launch)"
    fi
    wb "$tmp/m_reclaim.elf" t1d; expect_red $? "M-reclaim (white-box: broken reclamation window)"
}

# --- M-shuffle: naive-order copy on the SWAP probe -> completes with the WRONG byte
# GATE-TEETH A5: require EXACTLY the predicted swap-wrong-byte outcome (e9=='de0dad' AND
# exit 121 -- hand-derived: un-swapped (a,b) held for all 1,000,001 iterations gives
# 2*a_orig+b_orig = 13*2^32, proof byte 0x0d), not merely "not the genuine de0bad/117",
# which would also (mis)pass a timeout or crash as if it were this specific forced outcome.
forge shuffle "$base_t3d" "$tmp/m_shuffle.elf" && {
    boot "$tmp/m_shuffle.elf"
    if [[ "$GOT_E9" == "de0dad" && "$GOT_RC" -eq 121 ]]; then
        echo "M-shuffle bit RED: naive-order shuffle delivered un-swapped args -> the EXACT predicted wrong byte (rc=121 e9=de0dad; genuine de0bad/117)"
        pass=$((pass + 1))
    else
        fail_test "M-shuffle: naive-order shuffle did not produce the EXACT predicted wrong outcome (rc=$GOT_RC e9='${GOT_E9}'; want rc=121 e9=de0dad -- a timeout/crash/other outcome does not prove this forge)"
    fi
    wb "$tmp/m_shuffle.elf" t3d; expect_red $? "M-shuffle (white-box: copy-pair disp8s off)"
}

# --- M-wrongtarget: tail E9 rel32+1 (lands inside the prologue) -> white-box + runtime RED
forge wrongtarget "$base_t1t" "$tmp/m_wt.elf" && {
    wb "$tmp/m_wt.elf" t1t; expect_red $? "M-wrongtarget (white-box: E9 target is not a callee entry)"
    boot "$tmp/m_wt.elf"
    # fail-closed (GATE-TEETH A4, as M-reclaim already does): a dead/timed-out QEMU also shows e9!=de06ad /
    # rc!=111 -- gate the RED on a CLEAN launch + non-timeout rc so a harness failure is a HARD FAIL, not a bite.
    if ! boot_launched_cleanly || [[ "$GOT_RC" -eq 124 ]]; then
        fail_test "M-wrongtarget: HARNESS failure (QEMU not cleanly launched / timed out: rc=$GOT_RC debugcon=$GOT_DEBUGCON err='$GOT_ERR') -- NOT a bite"
    elif [[ "$GOT_E9" == "de06ad" && "$GOT_RC" -eq 111 ]]; then
        fail_test "M-wrongtarget: mis-targeted tail jmp STILL graded genuinely"
    else
        echo "M-wrongtarget bit RED: tail jmp into the prologue interior diverged (rc=$GOT_RC e9='${GOT_E9}'; genuine de06ad/111), and QEMU launched cleanly (not a harness failure)"
        pass=$((pass + 1))
    fi
}

# --- M-nontailE9: flip the non-tail backward E8 to E9 -> site accounting RED
forge nontailE9 "$base_t8t" "$tmp/m_nte9.elf" && {
    wb "$tmp/m_nte9.elf" t8t; expect_red $? "M-nontailE9 (white-box: non-tail site must STAY E8)"
}

# --- M-golden: one perturbed byte -> committed-golden hash pin RED
forge golden "$base_t1d" "$tmp/m_gold.elf" && {
    want=$(cat "$goldens_dir/t1d.sha256" 2>/dev/null || echo MISSING)
    got_base=$(sha256sum "$base_t1d" | cut -d' ' -f1)
    got_forged=$(sha256sum "$tmp/m_gold.elf" | cut -d' ' -f1)
    if [[ "$got_base" == "$want" && "$got_forged" != "$want" ]]; then
        pass=$((pass + 1))
    else
        fail_test "M-golden: golden-hash leg vacuous (base==golden:$([[ "$got_base" == "$want" ]] && echo yes || echo NO) forged!=golden:$([[ "$got_forged" != "$want" ]] && echo yes || echo NO))"
    fi
}

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link65-mutation sub-test(s) failed."; exit 1; fi
echo "PASS: link65-mutation ($pass legs: controls GREEN x3 (t1d/t3d/t8t pass the site-aware white-box) + each mutation bit RED where it must: M-notco (detection off -> deep tail overflows; the permanent forcing proof) + M-reclaim (E9 kept, reclamation gone -> deep run RED; constant stack is proven, not E9 presence) + M-shuffle (naive-order copy -> swap probe wrong byte) + M-wrongtarget (E9 into prologue interior -> white-box + runtime RED) + M-nontailE9 (non-tail must stay E8 -> site accounting RED) + M-610/M-611/M-604 (main-block / callee-block / final code-length invariants fire at compile time) + M-golden (committed-golden pin))"
exit 0
