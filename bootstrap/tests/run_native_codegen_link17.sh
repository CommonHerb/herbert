#!/usr/bin/env bash
# Native codegen Link 17 (L1, "boot and emit a byte"): the first kernel-arc
# link, and the FIRST graded on the far-axis dual-substrate oracle instead of
# the C reference.
#
# The compiler grew a SECOND emit mode (selected by the anchored first-line
# directive "-- emit: multiboot32"): it compiles `func main(): return A*B` to a
# FREESTANDING 32-bit Multiboot1 image (no OS, no syscalls) that computes the
# byte on bare metal with a REAL runtime imul (0F AF C1, 32-bit -- not the
# x86-64 REX.W form) and writes it to debugcon 0xE9, framed 0xDE <byte> 0xAD.
# There is no C analogue for a bare-metal boot, so the byte is graded against a
# HOST-DERIVED golden (computed here, never captured from a guest) on TWO
# independent substrates: QEMU (-kernel direct multiboot) and Bochs (GRUB on a
# partitioned HDD). A single emulator could silently become the spec; two
# independent ones plus a host golden cannot.
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe):
#     - grub-file --is-x86-multiboot
#     - multiboot magic present in first 8 KiB AND 4-byte aligned
#     - ZERO syscall escapes: no 0F 05 / CD 80 / 0F 34 bytes, AND an
#       instruction-aware objdump scan finds no syscall/sysenter/int mnemonic
#     - imul (0F AF) present
#     - DATAFLOW: the emitted body is exactly `mov esp,imm32; push OPA; push
#       OPB; pop ecx; pop eax; imul eax,ecx; push eax; pop eax` with the two
#       push immediates EQUAL to the source literals -- so the byte cannot be a
#       hardcoded constant beside a dead imul (Codex red-team hole)
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit code == host golden, and the e9
#       capture == the host golden frame, with EXACTLY ONE frame
#     - Bochs: exactly one host-golden frame in stdout AND clean-shutdown
#       evidence (so a kernel that emits the frame then hangs cannot pass)
#   PROBE VECTORS: several distinct A*B with distinct host goldens prove the ALU
#     ran rather than a static immediate.
#   REJECTS (+ renamed/revalued twins): out-of-subset programs (+, locals,
#     calls) emit no valid multiboot image; the twin (same shape, different
#     names/values) must reject too, so the rejection is structural not fitted.
#
# Honest scope: this proves "boots as a freestanding 32-bit Multiboot image
# under QEMU's direct loader and Bochs+GRUB," NOT real silicon, arbitrary GRUB
# versions, paging, long mode, interrupts, or full u64 Herbert integer semantics
# (only the low byte of +,-,* is exercised). The dual-substrate + host golden is
# the far-axis replacement for the now-absent C differential, with the small
# permanent audited-assertion residue recorded in the ledger.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

# When set (the kernel-codegen CI workflow sets it), a missing emulator is a
# HARD FAILURE, not a skip -- the silicon gate must actually run in CI.
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
# Bochs leg is slow + needs passwordless sudo; run it on a representative subset.
BOCHS_PROBES="${L1_BOCHS_PROBES:-5x15 6x15}"

if [[ ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"
    exit 1
fi
if [[ ! -f "$backend" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing backend)"
    exit 1
fi

source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Reuse only the gen-1 mint (C out of the run path; the native compiler emits
# the image). The C-golden manifest machinery does not apply -- L1 is graded on
# the dual-substrate oracle, not against C. Mint into the per-run tmp.
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0
fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 \
    && sudo -n true 2>/dev/null; }

# ---- host-derived goldens (computed here; never captured from a guest) ------
host_payload() { echo $(( ($1 * $2) & 0xff )); }
host_qemu_exit() { local p; p=$(host_payload "$1" "$2"); echo $(( ((( p ^ 0x31) & 0x7f) << 1) | 1 )); }

# ---- compile a freestanding A*B probe with the NATIVE gen-1 compiler --------
compile_mb() { # label A B outfile  -> 0 on a valid multiboot ELF
    local label="$1" a="$2" b="$3" out="$4"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32\nfunc main(): return %d*%d end\n' "$a" "$b" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"
        return 1
    fi
    cp "$cdir/a.out" "$out"
    return 0
}

# ---- static gates -----------------------------------------------------------
static_gates() { # label A B elf
    local label="$1" a="$2" b="$3" elf="$4" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    # multiboot magic 0x1BADB002 -> LE bytes 02 b0 ad 1b
    local hx magoff; hx=$(xxd -p "$elf" | tr -d '\n')
    magoff=$(( $(echo "$hx" | grep -bo '02b0ad1b' | head -1 | cut -d: -f1) / 2 ))
    if ! { [[ -n "$magoff" ]] && [[ "$magoff" -lt 8192 ]] && [[ $((magoff % 4)) -eq 0 ]]; }; then
        fail_test "$label static: multiboot magic placement ($magoff)"; ok=0
    fi
    # extract the loaded code region (file offset 0x100c = 4108) for byte + disasm gates
    local code="$tmp/$label.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    echo "$chx" | grep -q '0f05' && { fail_test "$label static: 0F 05 (syscall) byte present"; ok=0; }
    echo "$chx" | grep -q 'cd80' && { fail_test "$label static: CD 80 (int 0x80) byte present"; ok=0; }
    echo "$chx" | grep -q '0f34' && { fail_test "$label static: 0F 34 (sysenter) byte present"; ok=0; }
    echo "$chx" | grep -q '0faf' || { fail_test "$label static: imul (0F AF) absent"; ok=0; }
    # instruction-aware escape scan (disassemble the code as 32-bit)
    local dis; dis=$(objdump -D -b binary -m i386 "$code" 2>/dev/null)
    if echo "$dis" | grep -qiE '\b(syscall|sysenter)\b|\bint[ ]+\$?0x'; then
        fail_test "$label static: disasm shows a syscall/sysenter/int instruction"; ok=0
    fi
    # DATAFLOW: body must be mov esp,imm32 ; push A ; push B ; MUL ; pop eax.
    # (operands tied to the SOURCE literals -> a hardcoded byte cannot pass.)
    local pa pb want
    pa=$(printf '%08x' "$a" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')  # LE32 of A
    pb=$(printf '%08x' "$b" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')  # LE32 of B
    # bytes 0:BC ..esp.. 5:68 <A> 10:68 <B> 15:5958 0fafc1 50 21:58
    local body="${chx:0:2}"          # BC
    local pushA="${chx:10:2}${chx:12:8}"   # 68 + A
    local pushB="${chx:20:2}${chx:22:8}"   # 68 + B
    local mul="${chx:30:12}"               # 59 58 0f af c1 50
    local ret="${chx:42:2}"                # 58
    [[ "$body" == "bc" ]] || { fail_test "$label dataflow: missing mov esp,imm32 (got $body)"; ok=0; }
    [[ "$pushA" == "68$pa" ]] || { fail_test "$label dataflow: push A != source literal (got $pushA want 68$pa)"; ok=0; }
    [[ "$pushB" == "68$pb" ]] || { fail_test "$label dataflow: push B != source literal (got $pushB want 68$pb)"; ok=0; }
    [[ "$mul" == "5958""0faf""c1""50" ]] || { fail_test "$label dataflow: MUL sequence (got $mul)"; ok=0; }
    [[ "$ret" == "58" ]] || { fail_test "$label dataflow: terminal RET pop eax (got $ret)"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

# ---- QEMU substrate ---------------------------------------------------------
qemu_run() { # label A B elf
    local label="$1" a="$2" b="$3" elf="$4"
    local p ex ph; p=$(host_payload "$a" "$b"); ex=$(host_qemu_exit "$a" "$b"); ph=$(printf '%02x' "$p")
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
bochs_run() { # label A B elf
    local label="$1" a="$2" b="$3" elf="$4"
    local p ph; p=$(host_payload "$a" "$b"); ph=$(printf '%02x' "$p")
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
      printf 'set timeout=0\nset default=0\nmenuentry "l1" {\n multiboot /boot/kernel.elf\n boot\n}\n' \
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

# ---- reject probe: an out-of-subset program must NOT emit a valid image -----
reject_probe() { # label "<herbert body lines>"
    local label="$1" prog="$2"
    local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "-- emit: multiboot32\n%b\n" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset program emitted a valid multiboot image"
        return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu-system-x86_64 not found)"
        exit 1
    fi
    echo "SKIP: native-codegen link17 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
    exit 0
fi

QEMU_PROBES="5x15 6x15 7x15 9x9 11x13 13x17"
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"
    exit 1
fi

for spec in $QEMU_PROBES; do
    a="${spec%x*}"; b="${spec#*x}"; label="p_${a}_${b}"
    elf="$tmp/$label.elf"
    compile_mb "$label" "$a" "$b" "$elf" || continue
    static_gates "$label" "$a" "$b" "$elf" || continue
    if qemu_run "$label" "$a" "$b" "$elf"; then
        bochs_ok=1
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" ${a}x${b} "* ]]; then
            bochs_run "$label" "$a" "$b" "$elf" || bochs_ok=0
        fi
        [[ "$bochs_ok" -eq 1 ]] && pass=$((pass + 1))
    fi
done

# rejects + renamed/revalued twins (rejection must be structural, not fitted)
reject_probe add        'func main(): return 5+15 end'
reject_probe add_twin   'func main(): return 7+9 end'
reject_probe local      'func main(): let x = 3 return x*5 end'
reject_probe local_twin 'func main(): let y = 8 return y*9 end'
reject_probe call       'func helper(): return 2 end\nfunc main(): return helper()*5 end'
reject_probe call_twin  'func other(): return 4 end\nfunc main(): return other()*9 end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 6))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then
    echo "$fail native-codegen-link17 sub-test(s) failed."
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link17 / L1: freestanding 32-bit Multiboot image boots and emits a runtime-computed byte; $pass checks: static+dataflow gates, QEMU substrate (6 probes, result-dependent exit), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 6 out-of-subset rejects with twins; graded vs host-derived golden on the dual-substrate oracle)"
exit 0
