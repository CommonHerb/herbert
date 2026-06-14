#!/usr/bin/env bash
# Native-codegen Link 41 / mmj (link 25): THE UNION -- the first compiled ring-3 module that BOTH computes with
# recursion/control flow (ouroboros) AND emits its OWN multi-byte output (holler's op 48 sys_write). TYPE-I: a
# new emit mode `module-mmj` on the FROZEN holler kernel (no kernel change). The make-or-break is VARIABLE-LENGTH
# output: down(N) recursively sys_writes N words, so the OUTPUT LENGTH = f(runtime input) -- unfakeable by
# ouroboros (no op 48) or holler (straight-line => compile-time-fixed count).
#
# What this gate proves (graded on the far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, vs mmj_ref.py):
#   (A) BYTE-PIN: the emitted `module-mmj` module is BYTE-IDENTICAL to mmj_ref.target_module('down'). This is
#       THE union binding -- recursion is NOT observable in a runtime trace (a non-recursive jmp-loop forges the
#       descending-esp/count/eip signature on real silicon), so the union is bound at the EMITTER layer here.
#   (B) RECURSION (white-box): the emitted module carries a BACKWARD E8 self-call (assert_backward_call). A
#       backward jmp is UNEMITTABLE from Herbert (no while; ouro branches forward-only), so (A)+(B) forbid the forge.
#   (C) VARIABLE-LENGTH SILICON: the module RUNS on the frozen holler kernel and emits EXACTLY N write-frames
#       le32(N..1) for fed=N, with X(FX) != Y(FY) output LENGTH (the make-or-break neither parent can produce).
#   (D) FROZEN KERNEL: the `multiboot32-holler` kernel is still byte-identical to holler_ref.build_elf() -- the
#       mmj compiler change is module-only/additive (the kernel is reused unchanged).
#   (E) REJECT probes (renamed twins): module-mmj REQUIRES the union -- it rejects a straight-line op48 program
#       (holler re-skin), a forward-only call chain (no recursion), a recursion with no sys_write, module_byte().
#       Each rejected program COMPILES in its proper mode (holler/ouroboros), so the reject is mmj-specific.
# The held-back MUTATION proof (run_native_codegen_link41_mutation.sh) proves each design choice non-vacuous.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/mmj_ref.py"
HREF="$script_dir/holler_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing mmj_ref.py $REF)"; exit 1; fi
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

# two distinct fed bytes -> distinct OUTPUT LENGTHS (FX words vs FY words). Small enough to fit the one page.
FX=5;  FXH=5
FY=8;  FYH=8
# the union forcing program: down(N) recursively sys_writes N words (the `let` form -> the proven STEP-0 target).
MODSRC="$(python3 "$REF" src down)"

# ---- reference artifacts (the oracle) ----
REFM="$work/ref_module.bin"; python3 "$REF" module down "$REFM"
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK")"
HREFK="$work/href_kernel.elf"; python3 "$HREF" cleanelf "$HREFK"   # the frozen holler kernel (D)

emit() { # marker prog outfile label -> writes outfile on accept; fail on reject
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}
reject_probe() { # label marker prog -> PASS iff the compiler refuses (no a.out)
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then fail_test "reject $label: compiler ACCEPTED an out-of-subset program"; else ok "reject $label (refused: $(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; fi
}
accept_probe() { # label marker prog -> PASS iff the compiler ACCEPTS (the renamed-twin: rejected-in-mmj prog is valid elsewhere)
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/acc.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then ok "twin $label compiles in its proper mode ($(wc -c <"$cdir/a.out") B) -- mmj-reject is specific"; else fail_test "twin $label should compile in its proper mode but was rejected"; fi
}

CMOD="$work/mmj_module.bin"
KELF="$work/holler_kernel.elf"
emit '-- emit: module-mmj' "$MODSRC" "$CMOD" module || exit 1
emit '-- emit: multiboot32-holler' 'func main(): return module_byte() end' "$KELF" kernel || exit 1

# ---- (A) BYTE-PIN: emitted module == mmj_ref.target_module('down') byte-for-byte ----
if cmp -s "$CMOD" "$REFM"; then ok "(A) module byte-identical to mmj_ref.target_module('down') [$(wc -c <"$CMOD") bytes; the union is bound at the emitter layer]"
else fail_test "(A) module differs from mmj_ref.target_module('down') -- $(cmp "$CMOD" "$REFM" 2>&1 | head -1)"; fi

# ---- (B) RECURSION (white-box): the emitted module carries a BACKWARD E8 self-call ----
if python3 - "$CMOD" <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
bw = [i for i in range(len(d) - 4) if d[i] == 0xE8 and struct.unpack('<i', d[i+1:i+5])[0] < 0]
sys.exit(0 if bw else 1)
PY
then ok "(B) emitted module carries a BACKWARD E8 self-call (genuine recursion; a jmp-loop forge has none)"
else fail_test "(B) emitted module has NO backward E8 call -- not genuinely recursive (forge-class)"; fi

# ---- (D) FROZEN KERNEL: the holler kernel is unchanged (mmj is module-only/additive) ----
if cmp -s "$KELF" "$HREFK"; then ok "(D) multiboot32-holler kernel byte-identical to holler_ref.build_elf() (frozen; mmj is module-only)"
else fail_test "(D) holler kernel CHANGED by the mmj edit -- $(cmp "$KELF" "$HREFK" 2>&1 | head -1)"; fi

if grub-file --is-x86-multiboot "$KELF" >/dev/null 2>&1; then ok "kernel is a valid x86 Multiboot image"
else fail_test "kernel is not a valid x86 Multiboot image"; fi

# ---- (E) REJECT probes (renamed twins): module-mmj REQUIRES recursion + sys_write ----
reject_probe straightline '-- emit: module-mmj' 'func main(): let b = sys_read()  let x = sys_write(b)  return sys_write(b) end'
accept_probe straightline_twin '-- emit: module-holler' 'func main(): let b = sys_read()  let x = sys_write(b)  return sys_write(b) end'
reject_probe forwardchain '-- emit: module-mmj' 'func emit2(v): let a = sys_write(v)  return sys_write(v) end\nfunc main(): let b = sys_read()  return emit2(b) end'
reject_probe nowrite '-- emit: module-mmj' 'func tri(n): if n == 0: return 0 end  return n + tri(n - 1) end\nfunc main(): let x = sys_read()  return tri(x) end'
accept_probe nowrite_twin '-- emit: multiboot32-ouroboros' 'func tri(n): if n == 0: return 0 end  return n + tri(n - 1) end\nfunc main(): let x = sys_read()  return tri(x) end'
reject_probe modbyte '-- emit: module-mmj' 'func down(k): if k == 0: return 0 end  return sys_write(k) + down(k - 1) end\nfunc main(): let x = sys_read()  let y = module_byte()  return down(x + y) end'
reject_probe noread '-- emit: module-mmj' 'func down(k): if k == 0: return 0 end  return sys_write(k) + down(k - 1) end\nfunc main(): return down(7) end'

# ============================ SILICON (dual substrate) ============================
emu_ran=0

qemu_feed() { # mod out fedbyte
    local mod="$1" out="$2" byte="$3"
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$byte" --hold 6 > "$d/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$KELF" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}

if have_qemu; then
    emu_ran=1
    qemu_feed "$CMOD" "$work/q.cx" "$FX"
    if python3 "$REF" grade "$work/q.cx" "$KEND" "$FXH" down >/dev/null 2>&1; then ok "QEMU module emits EXACTLY $FX write-frames le32(N..1), descending-esp recursion (fed=$FX)"
    else fail_test "QEMU mmj X -> $(python3 "$REF" grade "$work/q.cx" "$KEND" "$FXH" down 2>&1 | tr '\n' ';')"; fi
    qemu_feed "$CMOD" "$work/q.cy" "$FY"
    if python3 "$REF" grade "$work/q.cy" "$KEND" "$FYH" down >/dev/null 2>&1; then ok "QEMU module emits EXACTLY $FY write-frames (fed=$FY; the X!=Y output-LENGTH differential)"
    else fail_test "QEMU mmj Y -> $(python3 "$REF" grade "$work/q.cy" "$KEND" "$FYH" down 2>&1 | tr '\n' ';')"; fi
    if [[ "$(wc -c <"$work/q.cx")" != "$(wc -c <"$work/q.cy")" ]]; then ok "QEMU X!=Y: fed=$FX stream != fed=$FY stream -- OUTPUT LENGTH is data-dependent (the make-or-break)"
    else fail_test "QEMU X and Y output streams are the SAME LENGTH (variable-length make-or-break vacuous)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required (KERNEL_CODEGEN_REQUIRE_EMU=1) but qemu-system-x86_64 not found"; else echo "  SKIP: qemu-system-x86_64 not found (set KERNEL_CODEGEN_REQUIRE_EMU=1 to require)"; fi
fi

# ---- Bochs (2nd substrate, via GRUB disk) ----
extract_e9() { python3 - "$1" "$2" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    for pat in (rb'\xde.\xad', rb'\xd4.{16}[\s\S]*?\xd5', rb'\xd6.{16}\xd7', rb'\xca.{16}\xcb',
                rb'\xd0.{4}.{4}.{4}.{4}.{4}\xd1', rb'\xe0.{1}.{4}.{4}.{4}\xe1'):
        m=None
        for mm in re.finditer(pat, d[i:], re.S): m=mm
        if m: end=max(end, i+m.end())
    open(sys.argv[2],'wb').write(d[i:end] if end>i else b'')
else: open(sys.argv[2],'wb').write(b'')
PY
}
bochs_run() { # mod e9out feedbyte
    local mod; mod="$(readlink -f "$1")"; local e9="$2" byte="$3"
    local kelf; kelf="$(readlink -f "$KELF")"
    local d="$work/b.$(basename "$2").d"; mkdir -p "$d"
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
    bochs_run "$CMOD" "$work/b.cx" "$FX"
    if python3 "$REF" grade "$work/b.cx" "$KEND" "$FXH" down >/dev/null 2>&1; then ok "Bochs module emits EXACTLY $FX write-frames le32(N..1) (variable-length on the 2nd substrate)"
    else fail_test "Bochs mmj X -> $(python3 "$REF" grade "$work/b.cx" "$KEND" "$FXH" down 2>&1 | tr '\n' ';')"; fi
    bochs_run "$CMOD" "$work/b.cy" "$FY"
    if python3 "$REF" grade "$work/b.cy" "$KEND" "$FYH" down >/dev/null 2>&1; then ok "Bochs module emits EXACTLY $FY write-frames (fed=$FY; X!=Y on the 2nd substrate)"
    else fail_test "Bochs mmj Y -> $(python3 "$REF" grade "$work/b.cy" "$KEND" "$FYH" down 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required (KERNEL_CODEGEN_REQUIRE_EMU=1) but bochs/parted/grub-install/xvfb-run/sudo not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + backward-call + reject gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link41 (mmj / THE UNION): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link41 mmj / THE UNION)"
