#!/usr/bin/env bash
# Native codegen Link 18 ("toakie", the SECOND kernel-arc link): widen the
# freestanding 32-bit Multiboot emit mode from lingo's {literal, *, return} to a
# real computation core -- CONTROL FLOW + LOCALS. The image now makes the first
# DATA-DEPENDENT BASIC-BLOCK SELECTION on bare metal: it computes a value into a
# frame local, compares it, and branches to one of two arms, emitting a byte that
# proves which arm ran. Graded, like lingo, on the far-axis DUAL-SUBSTRATE oracle
# (QEMU + Bochs vs a HOST-derived golden), not C -- there is no C analogue for a
# bare-metal boot.
#
# The subset toakie admits over lingo: LOAD_LOCAL/STORE_LOCAL (ebp frame), ADD,
# SUB, EQ (one comparator), BR + BR_IF_FALSE (resolved by a real 2-pass layout),
# and a mid-body RET (pop eax; jmp epilogue) beside lingo's terminal RET. Single
# acyclic `main`, no calls, no loops. Every admitted opcode is exercised by a
# probe below; nothing is admitted for ergonomics.
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe):
#     - grub-file --is-x86-multiboot; multiboot magic in first 8 KiB & 4-aligned
#     - ZERO syscall escapes: no 0F 05 / CD 80 / 0F 34 bytes AND an
#       instruction-aware objdump scan finds no syscall/sysenter/int mnemonic
#   WHITE-BOX (per branching probe; the static holes a black-box diff misses --
#   the zelph lesson that a mis-resolved rel is behaviorally invisible):
#     - a REAL conditional jump (je, 0F 84) is present -- not a branchless
#       setcc/cmov select or a folded compile-time constant
#     - the je's resolved target lands EXACTLY on an instruction boundary inside
#       the emitted body (objdump computes the target; it must equal a disasm
#       line offset) -- a mis-resolved rel8/rel32 cannot pass
#     - an actual frame STORE then later LOAD of the same slot (8F 45 d .. then
#       FF 75 d) -- proves the value round-trips memory, not constant-folded
#     - the unconditional BR (E9) target also lands on an instruction boundary
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit code == host golden, the e9 capture
#       == the host golden frame 0xDE<byte>0xAD, with EXACTLY ONE frame
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence
#   PROBE VECTORS: BOTH arms of BOTH branch shapes are proven on the GREEN path
#     (then-arm AND false-arm twins), with distinct host goldens differing in the
#     low 7 bits (the isa-debug-exit masks the payload with 0x7F, so arms must
#     differ below bit 7 for the exit-code check to bite, not only the e9 frame).
#   REJECTS (+ renamed/revalued twins): out-of-subset programs (other
#     comparators, calls, div/mod, bitwise, a parameterised main, a non-EQ bool
#     condition) emit NO valid image; the twin (same shape, different
#     names/values) must reject too, so the rejection is structural not fitted.
#
# Honest scope: proves "boots and branches as a freestanding 32-bit Multiboot
# image under QEMU's direct loader and Bochs+GRUB," NOT real silicon, arbitrary
# emulator versions, paging, long mode, interrupts, or full u64 integer semantics
# (32-bit wrap; only the low byte is graded). The dual-substrate + host golden is
# the far-axis replacement for the absent C differential.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L2_BOCHS_PROBES:-merge_then merge_else}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1
fi
if [[ ! -f "$backend" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1
fi

source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Reuse only the gen-1 mint (C out of the run path; the native compiler emits the
# image). L2 is graded on the dual-substrate oracle, not against C.
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 \
    && sudo -n true 2>/dev/null; }

# ---- host-derived golden exit code (computed here; never captured) ----------
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

# ---- the toakie forcing programs (source -> expected host-derived byte) ------
# Two branch SHAPES x both arms. MERGE: arms assign a result local then fall to a
# join + single return (forces BR_IF_FALSE + BR + a 3-local frame). RETURN: both
# arms return (forces a mid-body RET jmp beside the terminal RET).
prog_src() { # label
    case "$1" in
      merge_then)  echo 'func main(): let x = 6*7  let y = x+1  let r = 0  if y == 43: r = y+3 else: r = y-5 end  return r end' ;;
      merge_else)  echo 'func main(): let x = 6*7  let y = x-1  let r = 0  if y == 43: r = y+3 else: r = y-5 end  return r end' ;;
      return_then) echo 'func main(): let x = 6*7  let y = x-1  if y == 41: return y+4 else: return y-6 end end' ;;
      return_else) echo 'func main(): let x = 6*7  let y = x+1  if y == 41: return y+4 else: return y-6 end end' ;;
      alu_then)    echo 'func main(): let a = 9*9  let b = a-50  let r = 0  if b == 31: r = b+7 else: r = b-7 end  return r end' ;;
      alu_else)    echo 'func main(): let a = 9*9  let b = a-49  let r = 0  if b == 31: r = b+7 else: r = b-7 end  return r end' ;;
    esac
}
prog_byte() { # label -> host-derived expected low byte (computed independently here)
    case "$1" in
      merge_then)  echo 46 ;;   # x=42 y=43 (==43 true)  r=y+3=46
      merge_else)  echo 36 ;;   # x=42 y=41 (==43 false) r=y-5=36
      return_then) echo 45 ;;   # x=42 y=41 (==41 true)  return y+4=45
      return_else) echo 37 ;;   # x=42 y=43 (==41 false) return y-6=37
      alu_then)    echo 38 ;;   # a=81 b=31 (==31 true)  r=b+7=38
      alu_else)    echo 25 ;;   # a=81 b=32 (==31 false) r=b-7=25
    esac
}
ALL_PROBES="merge_then merge_else return_then return_else alu_then alu_else"

# ---- compile a freestanding probe with the NATIVE gen-1 compiler -------------
compile_probe() { # label outfile -> 0 on a valid multiboot ELF
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1
    fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- static escape gate -----------------------------------------------------
static_gates() { # label elf
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx magoff; hx=$(xxd -p "$elf" | tr -d '\n')
    magoff=$(( $(echo "$hx" | grep -bo '02b0ad1b' | head -1 | cut -d: -f1) / 2 ))
    if ! { [[ -n "$magoff" ]] && [[ "$magoff" -lt 8192 ]] && [[ $((magoff % 4)) -eq 0 ]]; }; then
        fail_test "$label static: multiboot magic placement ($magoff)"; ok=0
    fi
    local code="$tmp/$label.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    echo "$chx" | grep -q '0f05' && { fail_test "$label static: 0F 05 (syscall) byte present"; ok=0; }
    echo "$chx" | grep -q 'cd80' && { fail_test "$label static: CD 80 (int 0x80) byte present"; ok=0; }
    echo "$chx" | grep -q '0f34' && { fail_test "$label static: 0F 34 (sysenter) byte present"; ok=0; }
    local dis; dis=$(objdump -D -b binary -m i386 "$code" 2>/dev/null)
    if echo "$dis" | grep -qiE '\b(syscall|sysenter)\b|\bint[ ]+\$?0x'; then
        fail_test "$label static: disasm shows a syscall/sysenter/int instruction"; ok=0
    fi
    [[ "$ok" -eq 1 ]]
}

# ---- white-box control-flow gate (the zelph lesson: a mis-resolved branch is
#      invisible to a black-box differential, so prove it statically) ----------
whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # Bound the disasm to the real code (body+epilogue). The epilogue terminal is
    # faf4ebfd (cli; hlt; jmp $-1); trailing zero padding past it must not let a
    # mis-resolved target false-pass onto an accidental boundary.
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label whitebox: epilogue terminal (cli;hlt;jmp) absent"; return 1; fi
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    # Select objdump instruction lines by the address-colon prefix. (Do NOT use
    # grep ':\t' -- \t is treated as a literal there and matches nothing; verified
    # at toakie that this false-failed every good image.)
    local dis; dis=$(objdump -D -b binary -m i386 -M intel "$code.t" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
    if [[ -z "$dis" ]]; then fail_test "$label whitebox: empty disassembly"; ok=0; fi
    # (a) a REAL conditional jump must exist (not a branchless setcc/cmov select)
    if ! echo "$dis" | grep -qE '\bje\b'; then fail_test "$label whitebox: no real conditional jump (je)"; ok=0; fi
    # (b) every je/jmp target must land on an instruction boundary -- a mis-resolved
    #     rel8/rel32 is behaviorally invisible to a black-box differential (zelph).
    local addrs; addrs=$(echo "$dis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
    local t
    for t in $(echo "$dis" | grep -oE '\b(je|jmp) +0x[0-9a-f]+' | grep -oE '[0-9a-f]+$' | sort -u); do
        if ! echo "$addrs" | grep -qiE "^0*${t}$"; then
            fail_test "$label whitebox: branch target 0x${t} not an instruction boundary (mis-resolved rel)"; ok=0
        fi
    done
    # (c) a NEGATIVE-displacement frame store then load of the same slot (8F 45 dd
    #     .. FF 75 dd, dd in fc/f8/f4/f0/ec) -- proves the value round-trips memory
    #     and the frame grows DOWN; a sign-flip to [ebp+N] is caught here (the boot
    #     differential cannot see it: store and load use the same wrong disp).
    local d found=0
    for d in fc f8 f4 f0 ec; do
        if echo "$chx" | grep -q "8f45${d}" && echo "$chx" | grep -q "ff75${d}"; then found=1; break; fi
    done
    if [[ "$found" -eq 0 ]]; then fail_test "$label whitebox: no negative-disp frame store-then-load round-trip"; ok=0; fi
    [[ "$ok" -eq 1 ]]
}

# ---- QEMU substrate ---------------------------------------------------------
qemu_run() { # label byte elf
    local label="$1" p="$2" elf="$3"
    local ex ph; ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.q"; mkdir -p "$W"
    printf "\\xde\\x${ph}\\xad" > "$W/golden_frame.bin"
    timeout 60 qemu-system-x86_64 -kernel "$elf" \
        -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M
    local rc=$?
    local nframes; nframes=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n' | grep -o "de${ph}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && cmp -s "$W/e9.bin" "$W/golden_frame.bin" && [[ "$nframes" -eq 1 ]]; then
        return 0
    fi
    fail_test "$label QEMU: exit=$rc(want $ex) e9=$(xxd -p "$W/e9.bin" 2>/dev/null) want=de${ph}ad nframes=$nframes"
    return 1
}

# ---- Bochs substrate (independent codebase, via GRUB on a partitioned HDD) ---
bochs_run() { # label byte elf
    local label="$1" p="$2" elf="$3"
    local ph; ph=$(printf '%02x' "$p")
    local W="$tmp/$label.b"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS files missing"; return 1; fi
    ( cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$elf" mnt/boot/kernel.elf
      printf 'set timeout=0\nset default=0\nmenuentry "l2" {\n multiboot /boot/kernel.elf\n boot\n}\n' \
          | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot \
          --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 32
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 60 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1
    )
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nframes shutdown
    nframes=$(grep -o "de${ph}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    shutdown=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    if [[ "$nframes" -eq 1 ]] && [[ "$shutdown" -ge 1 ]]; then
        return 0
    fi
    fail_test "$label Bochs: frames(de${ph}ad)=$nframes shutdown-evidence=$shutdown"
    return 1
}

# ---- reject probe: an out-of-subset program must NOT emit a valid image ------
reject_probe() { # label "<herbert program>"
    local label="$1" prog="$2"
    local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "-- emit: multiboot32\n%b\n" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset program emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ---- lingo superset invariant: a 0-local literal*literal program must STILL
#      emit lingo's exact bytes (so the native self-host fixpoint is unperturbed) -
superset_invariant() {
    local cdir="$tmp/superset.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32\nfunc main(): return 5*15 end\n' > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "superset: lingo 5*15 did not compile"; return 1; fi
    # lingo body (file off 4108) = mov esp imm32(5) + push5 + push15 + MUL + RET(58) = 80 B,
    # and the bytes after the 5-byte mov-esp are FIXED.
    local body; body=$(dd if="$cdir/a.out" bs=1 skip=4113 count=17 status=none | xxd -p | tr -d '\n')
    local want="6805000000680f00000059580fafc15058"
    if [[ "$body" == "$want" ]]; then return 0; fi
    fail_test "superset: lingo 5*15 body changed (got $body want $want) -- fixpoint risk"; return 1
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu-system-x86_64 not found)"; exit 1
    fi
    echo "SKIP: native-codegen link18 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
    # Still run the emulator-free gates (compile, static, white-box, rejects,
    # superset) so make test has real coverage without an emulator.
fi

run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1
fi

superset_invariant && pass=$((pass + 1))

for label in $ALL_PROBES; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    whitebox_gates "$label" "$elf" || continue
    if ! have_qemu; then pass=$((pass + 1)); continue; fi   # statics+whitebox only
    byte=$(prog_byte "$label")
    if qemu_run "$label" "$byte" "$elf"; then
        bochs_ok=1
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
            bochs_run "$label" "$byte" "$elf" || bochs_ok=0
        fi
        [[ "$bochs_ok" -eq 1 ]] && pass=$((pass + 1))
    fi
done

# rejects + renamed/revalued twins (rejection must be structural, not fitted)
reject_probe lt          'func main(): let x = 6  if x < 5: return 1 else: return 2 end end'
reject_probe lt_twin     'func main(): let q = 9  if q < 2: return 7 else: return 8 end end'
reject_probe call        'func h(): return 2 end\nfunc main(): return h()+1 end'
reject_probe call_twin   'func g(): return 4 end\nfunc main(): return g()+9 end'
reject_probe divmod      'func main(): let x = 6  return x % 4 end'
reject_probe divmod_twin 'func main(): let z = 8  return z / 3 end'
reject_probe bitor       'func main(): let x = 6  return x | 1 end'
reject_probe bitor_twin  'func main(): let w = 5  return w & 3 end'
reject_probe mainarg     'func main(p): return p+1 end'
reject_probe mainarg_twin 'func main(k): return k-1 end'
reject_probe boolcond    'func main(): if true: return 1 else: return 2 end end'
reject_probe boolcond_twin 'func main(): if false: return 8 else: return 9 end end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 12))

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then
    echo "$fail native-codegen-link18 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link18 / toakie: freestanding 32-bit Multiboot image makes a data-dependent branch on bare metal; $pass checks: superset invariant, static+white-box (real jcc, target-on-boundary, frame store/load round-trip), QEMU substrate (6 probes both arms both branch shapes, result-dependent exit), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 12 out-of-subset rejects with twins; graded vs host-derived golden on the dual-substrate oracle)"
exit 0
