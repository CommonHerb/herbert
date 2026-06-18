#!/usr/bin/env bash
# Native codegen Link 38 (coalgate / the TWENTY-SECOND kernel-arc link): THE KERNEL RUNS ITS FIRST
# HERBERT-COMPILED MODULE.
#
# Every prior kernel link ran a HAND-ASSEMBLED module (the *_ref.py blobs). coalgate adds a new emit KIND
# (`-- emit: multiboot32-coalgate`) that compiles a Herbert SOURCE program into a raw, POSITION-INDEPENDENT
# i386 module (entry byte 0) the FROZEN geeking kernel runs at ring 3 -- the sovereign self-production
# moment. The module reuses nc32_lower_loop wholesale for the transform body; the module-side glue is op 47
# sys_read (int 0x30, eax=0 -- the only input path a CPL3 module has) plus an implicit sys_exit (main's
# return value -> mov bl,al; mov eax,1; int 0x30). The named ABI: audits/link22-coalgate/00-module-abi.md.
#
# THE MAKE-OR-BREAK:
#  (1) COMPILED, not hand-crafted: the SAME frozen geeking kernel, fed TWO DIFFERENT compiled modules
#      (different transforms), emits DIFFERENT output -- forced by real compilation (nc32_lower_loop lowers
#      the .herb; the gate COMPILES the source and runs the emitted blob).
#  (2) INPUT-dependent (carried): the same compiled module fed X != Y emits T(X) != T(Y) -- the two-byte
#      differential (FX=0x3C, FY=0xC5, T injective on the pair) defeats a const-baker.
#  (3) BYTE-EXACT (white-box pin): each emitted module is proven byte-identical to coalgate_ref.target_module
#      (the STEP-0 target proven on QEMU+KVM+Bochs BEFORE the emitter). This replaces the kernel prefix-pin
#      (the 4108/24564 kernel offsets do NOT apply to a module: entry byte 0, no ELF/MB header).
#  (4) The FROZEN host kernel is re-emitted from `-- emit: multiboot32-geeking` and proven byte-identical to
#      geeking_ref.build_elf -- the grading host is reproducible from source, not a committed binary.
# Graded on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs); the held-back MUTATION proof
# (run_native_codegen_link38_mutation.sh) proves the answer==host_T and X!=Y checks bite.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/coalgate_ref.py"
GREF="$script_dir/geeking_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L22_BOCHS_PROBES:-add7 local}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing coalgate_ref.py $REF)"; exit 1; fi
if [[ ! -f "$GREF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing geeking_ref.py $GREF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"
source "$script_dir/native_codegen_qemu_diag.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
elf_meta() { local elf="$1" eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n'); echo $(( 1048576 + $(le32_val "$eh" 144) )); }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

FX=60   # 0x3C
FY=197  # 0xC5
KINDS="echo add7 mul3 local"

# ---- the FROZEN geeking kernel = the grading host. Re-emit from -- emit: multiboot32-geeking and prove
#      byte-identical to geeking_ref.build_elf (reproducible from source; no committed binary). ----
emit_kernel() {
    local kcdir="$work/kernel.d"; rm -rf "$kcdir"; mkdir -p "$kcdir"
    printf -- '-- emit: multiboot32-geeking\nfunc main(): return module_byte() end\n' > "$kcdir/k.herb"
    ( cd "$kcdir" && "$NATIVE_CODEGEN_COMPILER" < k.herb >/dev/null 2>"$kcdir/err" )
    if [[ ! -f "$kcdir/a.out" ]]; then fail_test "frozen kernel: -- emit: multiboot32-geeking produced no a.out ($(head -1 "$kcdir/err" 2>/dev/null))"; return 1; fi
    KELF="$work/geeking.elf"; cp "$kcdir/a.out" "$KELF"
    python3 "$GREF" cleanelf "$work/geeking_ref.elf"
    if cmp -s "$KELF" "$work/geeking_ref.elf"; then pass=$((pass + 1)); else fail_test "frozen host kernel: compiled geeking != geeking_ref.build_elf (host not byte-reproducible from source)"; return 1; fi
    KEND="$(printf '%x' "$(elf_meta "$KELF")")"
    return 0
}

# ---- compile each coalgate module + prove BYTE-IDENTICAL to the STEP-0 target (the white-box pin) ----
declare -A MODF
compile_module() { # kind
    local kind="$1"; local cdir="$work/cg.$kind.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-coalgate\n%s\n' "$(python3 "$REF" src "$kind")" > "$cdir/m.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "coalgate $kind: compiler produced no module ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    local got want; got=$(xxd -p "$cdir/a.out" | tr -d '\n'); want=$(python3 "$REF" hex "$kind")
    if [[ "$got" != "$want" ]]; then fail_test "coalgate $kind: emitted module != STEP-0 target (white-box byte-pin). got=$got want=$want"; return 1; fi
    cp "$cdir/a.out" "$work/$kind.bin"; MODF[$kind]="$work/$kind.bin"; pass=$((pass + 1)); return 0
}

# ---- reject probes (+ twins): out-of-subset sources must NOT emit a module ----
reject_probe() { # label src
    local label="$1" src="$2"; local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-coalgate\n%b\n' "$src" > "$cdir/r.herb"
    ( cd "$cdir" && rm -f a.out; "$NATIVE_CODEGEN_COMPILER" < r.herb >/dev/null 2>"$cdir/err" )
    if [[ -s "$cdir/a.out" ]]; then fail_test "reject $label: out-of-subset source emitted a module a.out"; else pass=$((pass + 1)); fi
}

# ---- QEMU benign round trip: boot frozen kernel + compiled module, feed byte, grade answer==host_T ----
qemu_benign() { # kind byte
    local kind="$1" byte="$2"; local out="$work/$kind.$byte.e9" W="$work/$kind.$byte.d"; mkdir -p "$W"
    local f ex; f=$(python3 "$REF" hostT "$kind" "$byte"); ex=$(host_qemu_exit "$f")
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$KELF" -initrd "${MODF[$kind]}" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    local rc=$?; wait "$fp" 2>/dev/null
    if ! grep -q SENT "$W/feed.log" 2>/dev/null; then fail_test "$kind byte=$byte: FEEDER FLAKE (no SENT) rc=$rc"; return 1; fi
    if [[ "$rc" -eq 124 ]]; then fail_test "$kind byte=$byte: 60s TIMEOUT (rc 124) -- feeder/timeout flake, not a kernel RED"; return 1; fi
    if [[ "$rc" -ne "$ex" ]]; then
        local low7 detail e9
        low7="$(native_codegen_qemu_exit_low7_hex "$rc")"
        detail="$(native_codegen_grade_detail "$REF" "$out" "$KEND" "$(printf '%x' "$byte")" "$kind")"
        e9="$(native_codegen_e9_hex "$out")"
        fail_test "$kind byte=$byte: exit rc=$rc (debug-exit-low7=$low7) != host_qemu_exit(T=$f)=$ex; grade: $detail; e9=$e9"
        return 1
    fi
    if python3 "$REF" grade "$out" "$KEND" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1; then return 0; fi
    fail_test "$kind byte=$byte: $(python3 "$REF" grade "$out" "$KEND" "$(printf '%x' "$byte")" "$kind" 2>&1 | tr '\n' ' ')"; return 1
}

# ---- Bochs benign round trip (the independent second emulator): GRUB multiboot + module ----
bochs_benign() { # kind byte
    local kind="$1" byte="$2"
    local kelf; kelf="$(readlink -f "$KELF")"; local mod; mod="$(readlink -f "${MODF[$kind]}")"
    local W="$work/b.$kind.$byte"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$kind Bochs: BIOS/VGABIOS missing"; return 1; fi
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 25 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    ( cd "$W"
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
    wait "$fp" 2>/dev/null
    grep -q SENT "$W/feed.log" 2>/dev/null || { fail_test "$kind Bochs byte=$byte: FEEDER FLAKE (no SENT)"; return 1; }
    python3 - "$W/bochs_out.txt" "$W/e9.bin" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    for pat in (rb'\xde.\xad', rb'\xc0(.).{4}.{4}.{4}\xc1', rb'\xe0(.).{4}.{4}.{4}\xe1'):
        m=None
        for mm in re.finditer(pat, d[i:], re.S): m=mm
        if m: end=max(end, i+m.end())
    open(sys.argv[2],'wb').write(d[i:end] if end>i else b'')
else: open(sys.argv[2],'wb').write(b'')
PY
    local sd; sd=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null || echo 0)
    if python3 "$REF" grade "$W/e9.bin" "$KEND" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1 && [[ "$sd" -ge 1 ]]; then return 0; fi
    fail_test "$kind Bochs byte=$byte (shutdown=$sd): $(python3 "$REF" grade "$W/e9.bin" "$KEND" "$(printf '%x' "$byte")" "$kind" 2>&1 | tr '\n' ' ')"; return 1
}

# ===================== run =====================
emit_kernel || { echo "PASS=$pass FAIL=$fail (kernel emit failed)"; exit 1; }
echo "coalgate: frozen geeking host kernel re-emitted from source, kend=0x$KEND"

# white-box byte-pin: each compiled module byte-identical to the STEP-0 target
for k in $KINDS; do compile_module "$k"; done

# differential must be non-vacuous: T(FX) != T(FY) for every input-dependent transform
for k in add7 mul3 local; do
    tx=$(python3 "$REF" hostT "$k" "$FX"); ty=$(python3 "$REF" hostT "$k" "$FY")
    if [[ "$tx" != "$ty" ]]; then pass=$((pass + 1)); else fail_test "$k: differential vacuous T(FX)==T(FY)==$tx"; fi
done

# reject probes (+ twins): the verifier's coalgate constraints bite
reject_probe module_byte      'func main(): return module_byte() end'
reject_probe module_byte_twin 'func main(): return module_byte() + 1 end'
reject_probe input_byte       'func main(): return input_byte() end'
reject_probe noread           'func main(): return 5 end'
reject_probe noread_twin      'func main(): return 9 end'
reject_probe tworead          'func main(): return sys_read() + sys_read() end'
reject_probe tworead_twin     'func main(): return sys_read() - sys_read() end'
reject_probe usercall         'func h(): return 2 end\nfunc main(): return h() + sys_read() end'
reject_probe usercall_twin    'func g(): return 4 end\nfunc main(): return g() + sys_read() end'
reject_probe mainarg          'func main(p): return sys_read() end'
reject_probe branch           'func main(): let x = sys_read()\n  if x == 5: return 1 else: return 2 end\nend'
reject_probe branch_twin      'func main(): let y = sys_read()\n  if y == 9: return 3 else: return 4 end\nend'

# emulator gating
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (qemu required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1; fi
    echo "SKIP: qemu not found; static + byte-pin + reject checks pass=$pass fail=$fail (set KERNEL_CODEGEN_REQUIRE_EMU=1 to force emulators)."
    [[ "$fail" -eq 0 ]] && exit 0 || exit 1
fi

# QEMU benign round trips on BOTH bytes + module-identity (sha) across the X and Y runs
for k in $KINDS; do
    sha_x=$(sha256sum "${MODF[$k]}" | cut -d' ' -f1)
    qemu_benign "$k" "$FX" && pass=$((pass + 1))
    qemu_benign "$k" "$FY" && pass=$((pass + 1))
    sha_y=$(sha256sum "${MODF[$k]}" | cut -d' ' -f1)
    if [[ "$sha_x" == "$sha_y" ]]; then pass=$((pass + 1)); else fail_test "$k: module image changed between the X and Y runs"; fi
done

# make-or-break (1): two DIFFERENT compiled modules, same frozen kernel, same byte -> different output
a7=$(python3 "$REF" hostT add7 "$FX"); m3=$(python3 "$REF" hostT mul3 "$FX")
if [[ "$a7" != "$m3" ]]; then pass=$((pass + 1)); else fail_test "two-module distinctness vacuous: add7(FX)==mul3(FX)==$a7"; fi

# Bochs dual-substrate leg (authoritative under REQUIRE_EMU)
if have_bochs; then
    for k in $BOCHS_PROBES; do bochs_benign "$k" "$FX" && pass=$((pass + 1)); done
elif [[ "$REQUIRE_EMU" == "1" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (Bochs required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1
else
    echo "NOTE: Bochs leg skipped (no bochs/parted/grub/xvfb/sudo locally); QEMU is authoritative locally, CI runs Bochs."
fi

echo "coalgate gate: pass=$pass fail=$fail"
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
