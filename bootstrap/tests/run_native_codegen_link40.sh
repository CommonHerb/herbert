#!/usr/bin/env bash
# Native-codegen Link 40 / holler (link 24): C3 / SYS_WRITE -- THE COMPILED RING-3 MODULE EMITS ITS OWN
# MULTI-BYTE OUTPUT. TYPE-II: a NEW kernel (geeking + a do_write/SYS_WRITE arm, the FIRST confused-deputy
# kernel-contract surface) AND a NEW compiled module that uses it (op 48 sys_write).
#
# What this gate proves (graded on the far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, vs holler_ref.py):
#   (A) MASTER BYTE-PIN: the emitted `multiboot32-holler` kernel ELF is BYTE-IDENTICAL to holler_ref.build_elf()
#       -- the do_write bounds-check lives in this byte-pinned prefix, so ANY mutation (partial drop, off-by-one,
#       signed jcc, baked immediate, reordered seg-reload, src swap, loop-guard) changes the prefix -> RED.
#   (B) COMPILED MODULE: the emitted `module-holler` module is BYTE-IDENTICAL to holler_ref.target_module(),
#       AND (the independent silicon leg) RUNS on the holler kernel and relays its OWN 8 bytes le32(b)++le32(3b)
#       BY VALUE, X != Y (a kernel that bakes a constant relay diverges across the fed byte).
#   (C) CONFUSED-DEPUTY: a hostile module SYS_WRITEs a kernel-code pointer (HOWR) / a page-straddling buffer
#       (STRD) -> the access_ok REJECTS it (no relay frame, a reject frame instead). The empirical leak under
#       M-nobounds is in the held-back MUTATION proof (run_native_codegen_link40_mutation.sh).
#   (D) NON-REGRESSION: the holler kernel (= geeking + do_write) still OUTLIVES its module -- a runaway is
#       async-killed (VICTIM) and a CPL3 #UD is named+continued (BADOP) -- so the do_write addition is additive.
#   (E) REJECT probes (renamed twins): the emit modes reject out-of-subset programs.
# The held-back MUTATION proof (run_native_codegen_link40_mutation.sh) proves each design choice non-vacuous.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/holler_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing holler_ref.py $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

PREFIX_LEN=24564
# two distinct fed bytes, neither a likely baked literal, injective under the module transform (le32(b),le32(3b))
FX=60;  FXH=3c
FY=197; FYH=c5
# the compiled forcing program: reads sys_read(), emits le32(b) then le32(b*3) via TWO sys_write calls, exits 0.
MODSRC='func main(): let b = sys_read()  let x = sys_write(b)  return sys_write(b * 3) end'

# ---- reference artifacts (the oracle) ----
REFK="$work/ref_kernel.elf"; python3 "$REF" cleanelf "$REFK"
REFM="$work/ref_module.bin"; python3 "$REF" targetmod "$REFM"
KEND="$(python3 "$REF" kend -)"
# hand-crafted hostiles (kernel-side confused-deputy probes; the compiled module is always in-bounds)
MHOWR="$work/m_howr.bin"; python3 "$REF" module HOWR "$MHOWR"   # ptr=ENTRY (kernel code), len=8  -> reject
MSTRD="$work/m_strd.bin"; python3 "$REF" module STRD "$MSTRD"   # ptr=esp-1, len=0x100 straddles page -> reject
# inherited geeking non-regression probes
MVICT="$work/m_vict.bin"; python3 "$REF" module VICTIM "$MVICT" # EB FE runaway -> async kill
MBAD="$work/m_badop.bin"; python3 "$REF" module BADOP "$MBAD"   # ud2 -> #UD named + continue

# ---- emit via the gen-1 native compiler ----
emit() { # marker prog outfile label  -> 0 + writes outfile on accept; 1 on (unexpected) reject
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}
reject_probe() { # label marker prog  -> PASS iff the compiler refuses (no a.out)
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then fail_test "reject $label: compiler ACCEPTED an out-of-subset program"; else ok "reject $label (refused: $(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; fi
}

KELF="$work/holler_kernel.elf"
CMOD="$work/holler_module.bin"
emit '-- emit: multiboot32-holler' 'func main(): return module_byte() end' "$KELF" kernel || exit 1
emit '-- emit: module-holler' "$MODSRC" "$CMOD" module || exit 1

# ---- (A) MASTER BYTE-PIN: emitted kernel == holler_ref.build_elf() byte-for-byte ----
if cmp -s "$KELF" "$REFK"; then ok "(A) kernel byte-identical to holler_ref.build_elf() [master prefix byte-pin, do_write incl.]"
else fail_test "(A) kernel differs from holler_ref.build_elf() -- $(cmp "$KELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B) compiled module == holler_ref.target_module() byte-for-byte ----
if cmp -s "$CMOD" "$REFM"; then ok "(B) compiled module byte-identical to holler_ref.target_module() [$(wc -c <"$CMOD") bytes]"
else fail_test "(B) compiled module differs from holler_ref.target_module() -- $(cmp "$CMOD" "$REFM" 2>&1 | head -1)"; fi

# ---- cheap ELF/Multiboot static gates on the emitted kernel (defense in depth) ----
if grub-file --is-x86-multiboot "$KELF" >/dev/null 2>&1; then ok "kernel is a valid x86 Multiboot image"
else fail_test "kernel is not a valid x86 Multiboot image"; fi

# ---- (E) REJECT probes (renamed twins) ----
reject_probe modnowrite_a '-- emit: module-holler' 'func main(): let b = sys_read()  return b end'
reject_probe modnowrite_b '-- emit: module-holler' 'func main(): let q = sys_read()  return q end'
reject_probe modbranch    '-- emit: module-holler' 'func main(): let b = sys_read()  if b == 5: return sys_write(b) else: return sys_write(b) end end'
reject_probe modmodbyte   '-- emit: module-holler' 'func main(): let b = sys_read()  return sys_write(module_byte()) end'
reject_probe modnoread    '-- emit: module-holler' 'func main(): return sys_write(7) end'
reject_probe kbranch      '-- emit: multiboot32-holler' 'func main(): let x = module_byte()  if x == 5: return 1 else: return 2 end end'
reject_probe kcall        '-- emit: multiboot32-holler' 'func h(): return 2 end\nfunc main(): return h() + module_byte() end'
reject_probe knomod       '-- emit: multiboot32-holler' 'func main(): return 7 end'

# ============================ SILICON (dual substrate) ============================
emu_ran=0

# QEMU feeder boot (SYS_READ-driven module) -> debugcon to $out
qemu_feed() { # kelf mod out fedbyte
    local kelf="$1" mod="$2" out="$3" byte="$4"
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$byte" --hold 6 > "$d/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
# QEMU no-input boot (hostile/runaway modules that never SYS_READ)
qemu_noin() { # kelf mod out
    local kelf="$1" mod="$2" out="$3"
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -serial null -monitor none -m 64M >/dev/null 2>&1 || true
}

if have_qemu; then
    emu_ran=1
    # (B-silicon) compiled module relays its OWN bytes, X and Y
    qemu_feed "$KELF" "$CMOD" "$work/q.cx" "$FX"
    if python3 "$REF" gradecompiled "$work/q.cx" "$KEND" "$FXH" >/dev/null 2>&1; then ok "QEMU compiled module relays le32(b)/le32(3b) BY VALUE, fed=0x$FXH"
    else fail_test "QEMU compiled X -> $(python3 "$REF" gradecompiled "$work/q.cx" "$KEND" "$FXH" 2>&1 | tr '\n' ';')"; fi
    qemu_feed "$KELF" "$CMOD" "$work/q.cy" "$FY"
    if python3 "$REF" gradecompiled "$work/q.cy" "$KEND" "$FYH" >/dev/null 2>&1; then ok "QEMU compiled module fed=0x$FYH (X!=Y differential arm)"
    else fail_test "QEMU compiled Y -> $(python3 "$REF" gradecompiled "$work/q.cy" "$KEND" "$FYH" 2>&1 | tr '\n' ';')"; fi
    if cmp -s "$work/q.cx" "$work/q.cy"; then fail_test "QEMU compiled X and Y outputs IDENTICAL (differential vacuous)"; else ok "QEMU compiled X != Y (relayed output is a value-function of the fed byte)"; fi
    # (C) confused-deputy: hostile OOB SYS_WRITE rejected (no leak) on the benign kernel
    qemu_noin "$KELF" "$MHOWR" "$work/q.howr"
    if python3 "$REF" gradehostwrite "$work/q.howr" "$KEND" >/dev/null 2>&1; then ok "QEMU hostile kernel-ptr SYS_WRITE REJECTED (no relay frame; confused-deputy defense)"
    else fail_test "QEMU hostwrite -> $(python3 "$REF" gradehostwrite "$work/q.howr" "$KEND" 2>&1 | tr '\n' ';')"; fi
    qemu_noin "$KELF" "$MSTRD" "$work/q.strd"
    if python3 "$REF" gradenoleak "$work/q.strd" "$KEND" >/dev/null 2>&1; then ok "QEMU page-straddling SYS_WRITE REJECTED (no relay past alloc_hi)"
    else fail_test "QEMU straddle -> $(python3 "$REF" gradenoleak "$work/q.strd" "$KEND" 2>&1 | tr '\n' ';')"; fi
    # (D) non-regression: the holler kernel still outlives its module.
    # SAME-INPUT REPLAY DISCRIMINATOR (parley, 2026-07-06): these two legs expect a POSITIVE frame
    # (watchdog-kill / generic-fault) from a byte-pinned kernel on a CONSTANT input -- behavior is
    # deterministic per boot, so a genuine defect recurs on EVERY boot while a transient debugcon
    # frame-capture miss does not (the class that RED'd this leg on CI 2026-07-06, run 28763960036
    # attempt 2). Budget: ONE completed replay; a second completed RED (any signature) is hard RED.
    # Non-recurrence is NOT proof against an intermittent same-input race; the marker hedges.
    # (The hostile-REJECT legs above expect NO frame and fail OPEN on a capture miss -- a replay
    # cannot help those; recorded as a canon residual.)
    qemu_noin "$KELF" "$MVICT" "$work/q.vict"
    if python3 "$REF" gradevictim "$work/q.vict" "$KEND" >/dev/null 2>&1; then ok "QEMU holler kernel async-KILLS a runaway (geeking watchdog intact under do_write)"
    else
        echo "  REPLAY (QEMU victim): completed boot graded RED -- ONE same-input replay (constant input + byte-pinned kernel: recurrence -> deterministic RED, non-recurrence -> transient capture miss)" >&2
        qemu_noin "$KELF" "$MVICT" "$work/q.vict2"
        if python3 "$REF" gradevictim "$work/q.vict2" "$KEND" >/dev/null 2>&1; then ok "QEMU holler kernel async-KILLS a runaway (geeking watchdog intact under do_write) [FLAKE-DISCRIMINATED: attempt-1 completed RED did NOT recur under one same-input replay -- no deterministic RED reproduced; classed a transient frame-capture miss, NOT proof against an intermittent race]"
        else fail_test "QEMU victim REPRODUCED under same-input replay -> hard RED: deterministic same-input failure, not a one-shot capture miss (attempt-1 -> $(python3 "$REF" gradevictim "$work/q.vict" "$KEND" 2>&1 | tr '\n' ';'); replay -> $(python3 "$REF" gradevictim "$work/q.vict2" "$KEND" 2>&1 | tr '\n' ';'))"; fi
    fi
    qemu_noin "$KELF" "$MBAD" "$work/q.bad"
    if python3 "$REF" gradegeneric "$work/q.bad" "$KEND" >/dev/null 2>&1; then ok "QEMU holler kernel NAMES+CONTINUES a CPL3 #UD (fault->continue intact)"
    else
        echo "  REPLAY (QEMU badop): completed boot graded RED -- ONE same-input replay (constant input + byte-pinned kernel: recurrence -> deterministic RED, non-recurrence -> transient capture miss)" >&2
        qemu_noin "$KELF" "$MBAD" "$work/q.bad2"
        if python3 "$REF" gradegeneric "$work/q.bad2" "$KEND" >/dev/null 2>&1; then ok "QEMU holler kernel NAMES+CONTINUES a CPL3 #UD (fault->continue intact) [FLAKE-DISCRIMINATED: attempt-1 completed RED did NOT recur under one same-input replay -- no deterministic RED reproduced; classed a transient frame-capture miss, NOT proof against an intermittent race]"
        else fail_test "QEMU badop REPRODUCED under same-input replay -> hard RED: deterministic same-input failure, not a one-shot capture miss (attempt-1 -> $(python3 "$REF" gradegeneric "$work/q.bad" "$KEND" 2>&1 | tr '\n' ';'); replay -> $(python3 "$REF" gradegeneric "$work/q.bad2" "$KEND" 2>&1 | tr '\n' ';'))"; fi
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required (KERNEL_CODEGEN_REQUIRE_EMU=1) but qemu-system-x86_64 not found"; else echo "  SKIP: qemu-system-x86_64 not found (set KERNEL_CODEGEN_REQUIRE_EMU=1 to require)"; fi
fi

# ---- Bochs (2nd substrate, via GRUB disk) ----
extract_e9() { python3 - "$1" "$2" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    for pat in (rb'\xde.\xad', rb'\xc0.{1}.{4}.{4}.{4}\xc1', rb'\xe0.{1}.{4}.{4}.{4}\xe1',
                rb'\xd4.{16}[\s\S]*?\xd5', rb'\xd6.{16}\xd7',
                rb'\xf0.{4}.{4}.{4}.{4}\xf1', rb'\xd0.{4}.{4}.{4}.{4}.{4}\xd1',
                rb'\xca.{4}.{4}.{4}.{4}\xcb', rb'\xe2.{4}.{4}\xe3'):
        m=None
        for mm in re.finditer(pat, d[i:], re.S): m=mm
        if m: end=max(end, i+m.end())
    open(sys.argv[2],'wb').write(d[i:end] if end>i else b'')
else: open(sys.argv[2],'wb').write(b'')
PY
}
bochs_run() { # kelf mod e9out feedbyte
    local kelf; kelf="$(readlink -f "$1")"; local mod; mod="$(readlink -f "$2")"; local e9="$3" byte="$4"
    local d="$work/b.$(basename "$3").d"; mkdir -p "$d"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 25 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$mod" mnt/boot/app.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/app.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 32
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 90 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    extract_e9 "$d/bochs_out.txt" "$e9"
}

if have_bochs; then
    emu_ran=1
    bochs_run "$KELF" "$CMOD" "$work/b.cx" "$FX"
    if python3 "$REF" gradecompiled "$work/b.cx" "$KEND" "$FXH" >/dev/null 2>&1; then ok "Bochs compiled module relays le32(b)/le32(3b) BY VALUE, fed=0x$FXH (2nd substrate)"
    else fail_test "Bochs compiled X -> $(python3 "$REF" gradecompiled "$work/b.cx" "$KEND" "$FXH" 2>&1 | tr '\n' ';')"; fi
    bochs_run "$KELF" "$MHOWR" "$work/b.howr" "$FX"
    if python3 "$REF" gradehostwrite "$work/b.howr" "$KEND" >/dev/null 2>&1; then ok "Bochs hostile kernel-ptr SYS_WRITE REJECTED (confused-deputy defense, 2nd substrate)"
    else fail_test "Bochs hostwrite -> $(python3 "$REF" gradehostwrite "$work/b.howr" "$KEND" 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required (KERNEL_CODEGEN_REQUIRE_EMU=1) but bochs/parted/grub-install/xvfb-run/sudo not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + reject gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link40 (holler / SYS_WRITE): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link40 holler / SYS_WRITE)"
