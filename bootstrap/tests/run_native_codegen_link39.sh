#!/usr/bin/env bash
# Native codegen Link 39 (ouroboros / the TWENTY-THIRD kernel-arc link): THE KERNEL RUNS THE STACK'S OWN
# ALGORITHM.
#
# coalgate (link 38) ran a STRAIGHT-LINE single-function compiled module. ouroboros makes the compiled ring-3
# module a real ALGORITHM: a NEW emit mode (`-- emit: multiboot32-ouroboros`) compiles a RECURSIVE / branching
# / multi-function Herbert program into a raw, POSITION-INDEPENDENT i386 module (entry byte 0) the FROZEN
# geeking kernel runs at ring 3. Calculator -> Turing-complete computer: a coalgate module provably could not
# branch (ERR 585) or call (ERR 580), and Herbert has NO while loop, so recursion-via-call is the ONLY
# iteration the language has. The kernel is UNCHANGED (the int 0x30 ABI is geeking's; ouroboros only adds the
# compiler emit mode -- a TYPE-I, compiler-only link). NEW machinery: a per-function frame (push ebp; mov
# ebp,esp; sub esp,4S; copy params to negative slots; mov esp,ebp; pop ebp; ret), an op-20 CALL lowered as a
# SIGNED rel32 (the recursive self-call is a BACKWARD rel32 -- callee base < call site), and ungated branches.
#
# THE MAKE-OR-BREAK:
#  (1) RECURSION/ALGORITHM, not straight-line: the emitted module is byte-identical to ouroboros_ref.target,
#      whose 'tri' contains a BACKWARD call rel32 (E8 + negative rel32 to the function's own entry) -- the
#      recursion the lowering must produce; a forge that bakes a lookup table is not byte-identical.
#  (2) COMPILED, not hand-crafted, and GENERAL: the SAME frozen kernel fed DIFFERENT compiled programs
#      (tri triangular, dbl 2n, fact n!, chain 3n+1) emits DIFFERENT output forced by real compilation; a
#      non-identity recurrence means a forge that skips the recursion (echoes the byte) is caught.
#  (3) INPUT-dependent: each program fed fx != fy emits T(fx) != T(fy) -- defeats a const-baker.
#  (4) BYTE-EXACT (white-box pin) to the STEP-0 target proven on QEMU+Bochs+KVM BEFORE the emitter existed
#      (audits/link23-ouroboros/01-step0-proof.md), + a disasm assertion that 'tri' carries a backward
#      recursive call rel32 (provenance pinned to the VALUE, not a syntactic proxy).
#  (5) The FROZEN host kernel is re-emitted from `-- emit: multiboot32-geeking` == geeking_ref.build_elf.
# Graded on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs); the held-back MUTATION proof
# (run_native_codegen_link39_mutation.sh) proves the answer==host_T / X!=Y / recursion checks bite.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/ouroboros_ref.py"
GREF="$script_dir/geeking_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L23_BOCHS_PROBES:-tri fact}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing ouroboros_ref.py $REF)"; exit 1; fi
if [[ ! -f "$GREF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing geeking_ref.py $GREF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

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

KINDS="tri dbl fact branch chain threearg"

# ---- the FROZEN geeking kernel = grading host (re-emit from source, prove == geeking_ref.build_elf) ----
emit_kernel() {
    local kcdir="$work/kernel.d"; rm -rf "$kcdir"; mkdir -p "$kcdir"
    printf -- '-- emit: multiboot32-geeking\nfunc main(): return module_byte() end\n' > "$kcdir/k.herb"
    ( cd "$kcdir" && "$NATIVE_CODEGEN_COMPILER" < k.herb >/dev/null 2>"$kcdir/err" )
    if [[ ! -f "$kcdir/a.out" ]]; then fail_test "frozen kernel: -- emit: multiboot32-geeking produced no a.out ($(head -1 "$kcdir/err" 2>/dev/null))"; return 1; fi
    KELF="$work/geeking.elf"; cp "$kcdir/a.out" "$KELF"
    python3 "$GREF" cleanelf "$work/geeking_ref.elf"
    if cmp -s "$KELF" "$work/geeking_ref.elf"; then pass=$((pass + 1)); else fail_test "frozen host kernel: compiled geeking != geeking_ref.build_elf"; return 1; fi
    KEND="$(printf '%x' "$(elf_meta "$KELF")")"
    return 0
}

# ---- compile each ouroboros program + prove BYTE-IDENTICAL to the STEP-0 target (white-box pin) ----
declare -A MODF
compile_module() { # kind
    local kind="$1"; local cdir="$work/cg.$kind.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-ouroboros\n%s\n' "$(python3 "$REF" src "$kind")" > "$cdir/m.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "ouroboros $kind: compiler produced no module ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    local got want; got=$(xxd -p "$cdir/a.out" | tr -d '\n'); want=$(python3 "$REF" hex "$kind")
    if [[ "$got" != "$want" ]]; then fail_test "ouroboros $kind: emitted module != STEP-0 target (white-box byte-pin). got=$got want=$want"; return 1; fi
    cp "$cdir/a.out" "$work/$kind.bin"; MODF[$kind]="$work/$kind.bin"; pass=$((pass + 1)); return 0
}

# ---- provenance: 'tri' must carry a BACKWARD recursive call rel32 (E8 + negative rel32 reaching tri's entry).
#      Pins the recursion to the VALUE, defeating a structural-proxy forge. ----
assert_backward_call() {
    python3 - "$work/tri.bin" <<'PY'
import sys,struct
m=open(sys.argv[1],'rb').read()
# tri starts at the first 0x55 (push ebp) -- main never pushes ebp. find tri base.
tri_base=m.find(b'\x55')
found=False
for i in range(len(m)-5):
    if m[i]==0xE8:
        rel=struct.unpack('<i',m[i+1:i+5])[0]
        tgt=i+5+rel
        if rel<0 and tgt==tri_base:   # a BACKWARD call to tri's own entry == the recursive self-call
            found=True
sys.exit(0 if (found and tri_base>0) else 1)
PY
}

# ---- reject probes (+ twins): out-of-subset sources must NOT emit a module ----
reject_probe() { # label src
    local label="$1" src="$2"; local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-ouroboros\n%b\n' "$src" > "$cdir/r.herb"
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
    if [[ "$rc" -eq 124 ]]; then fail_test "$kind byte=$byte: 60s TIMEOUT (rc 124) -- feeder/timeout flake"; return 1; fi
    if [[ "$rc" -ne "$ex" ]]; then fail_test "$kind byte=$byte: exit rc=$rc != host_qemu_exit(T=$f)=$ex"; return 1; fi
    if python3 "$REF" grade "$out" "$KEND" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1; then return 0; fi
    fail_test "$kind byte=$byte: $(python3 "$REF" grade "$out" "$KEND" "$(printf '%x' "$byte")" "$kind" 2>&1 | tr '\n' ' ')"; return 1
}

# ---- Bochs benign round trip (independent second emulator): GRUB multiboot + module ----
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

# ---- overflow safety: a deep recursion overflowing the 4 KiB stack page must FAULT CLEANLY (caught by
#      geeking's fault->continue, answer = a fault status), NOT silently corrupt -- proving the one-page
#      recursion bound is a SAFE capacity bound (code and stack are SEPARATE pages). ----
overflow_faults_clean() {
    local cdir="$work/ovf.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-ouroboros\n%s\n' "$(python3 "$REF" overflowsrc)" > "$cdir/m.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < m.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "overflow probe: did not compile ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    local W="$work/ovf.run"; mkdir -p "$W"; local byte=250; local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$KELF" -initrd "$cdir/a.out" -debugcon file:"$W/e9" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    local ans; ans=$(xxd -p "$W/e9" 2>/dev/null | tr -d '\n' | grep -oE 'de..ad' | head -1 | sed -E 's/^de(..)ad$/\1/')
    if [[ -n "$ans" ]] && python3 "$REF" isfault "$ans" 2>/dev/null; then
        echo "ouroboros: deep recursion (byte=$byte) overflows the stack page -> fault status 0x$ans (caught by fault->continue; safe capacity bound)"; pass=$((pass + 1))
    else
        fail_test "overflow probe byte=$byte: answer=0x${ans:-NONE} is NOT a fault status -- deep recursion may SILENTLY CORRUPT"
    fi
}

# ===================== run =====================
emit_kernel || { echo "PASS=$pass FAIL=$fail (kernel emit failed)"; exit 1; }
echo "ouroboros: frozen geeking host kernel re-emitted from source, kend=0x$KEND"

# white-box byte-pin: each compiled program byte-identical to the STEP-0 target
for k in $KINDS; do compile_module "$k"; done

# provenance: tri carries a real BACKWARD recursive call rel32
if [[ -f "$work/tri.bin" ]]; then
    if assert_backward_call; then pass=$((pass + 1)); else fail_test "tri: no backward recursive call rel32 (E8 negative rel to tri entry)"; fi
fi

# per-program X!=Y differential must be non-vacuous
for k in $KINDS; do
    fx=$(python3 "$REF" fx "$k"); fy=$(python3 "$REF" fy "$k")
    tx=$(python3 "$REF" hostT "$k" "$fx"); ty=$(python3 "$REF" hostT "$k" "$fy")
    if [[ "$tx" != "$ty" ]]; then pass=$((pass + 1)); else fail_test "$k: differential vacuous T(fx)==T(fy)==$tx"; fi
done

# cross-program distinctness: DIFFERENT compiled algorithms, SAME byte -> DIFFERENT output
b=20
a_tri=$(python3 "$REF" hostT tri "$b"); a_dbl=$(python3 "$REF" hostT dbl "$b"); a_chain=$(python3 "$REF" hostT chain "$b")
if [[ "$a_tri" != "$a_dbl" && "$a_tri" != "$a_chain" && "$a_dbl" != "$a_chain" ]]; then pass=$((pass + 1)); else fail_test "cross-program distinctness vacuous: tri=$a_tri dbl=$a_dbl chain=$a_chain"; fi

# reject probes (+ twins): the ouroboros subset/discipline bites
reject_probe module_byte      'func main(): return module_byte() end'
reject_probe module_byte_twin 'func main(): return module_byte() + 1 end'
reject_probe input_byte       'func main(): return input_byte() end'
reject_probe noread           'func main(): return 5 end'
reject_probe noread_twin      'func main(): return 9 end'
reject_probe tworead          'func main(): return sys_read() + sys_read() end'
reject_probe tworead_twin     'func r(): return sys_read() end\nfunc main(): return r() + sys_read() end'
reject_probe mainarg          'func main(p): return sys_read() end'
reject_probe divop            'func main(): return sys_read() / 2 end'
reject_probe divop_twin       'func main(): return sys_read() / 3 end'
reject_probe strlit           'func main(): let s = "z"\n  return sys_read() end'
reject_probe arity            'func g(a, b): return a + b end\nfunc main(): return g(sys_read()) end'
# >30-param callee: the param-copy [ebp+disp8] read of param 0 would be +128 (sign-extends to -128) -> a
# CLEAN reject (ERR 599), not a silent mis-compile (the completeness-critic disp8 finding).
P31SRC="$(python3 -c "print('func f(' + ', '.join('p%d'%i for i in range(31)) + '):\n    return p0\nend\nfunc main():\n    return f(sys_read()' + ', 0'*30 + ')\nend')")"
reject_probe param31 "$P31SRC"

# emulator gating
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (qemu required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1; fi
    echo "SKIP: qemu not found; static + byte-pin + reject checks pass=$pass fail=$fail (set KERNEL_CODEGEN_REQUIRE_EMU=1 to force emulators)."
    [[ "$fail" -eq 0 ]] && exit 0 || exit 1
fi

# QEMU benign round trips on BOTH bytes + module-identity (sha) across the fx and fy runs
for k in $KINDS; do
    fx=$(python3 "$REF" fx "$k"); fy=$(python3 "$REF" fy "$k")
    sha_x=$(sha256sum "${MODF[$k]}" | cut -d' ' -f1)
    qemu_benign "$k" "$fx" && pass=$((pass + 1))
    qemu_benign "$k" "$fy" && pass=$((pass + 1))
    sha_y=$(sha256sum "${MODF[$k]}" | cut -d' ' -f1)
    if [[ "$sha_x" == "$sha_y" ]]; then pass=$((pass + 1)); else fail_test "$k: module image changed between the fx and fy runs"; fi
done

# overflow safety: deep recursion overflows the stack page -> clean fault, not silent corruption
overflow_faults_clean

# Bochs dual-substrate leg (authoritative under REQUIRE_EMU)
if have_bochs; then
    for k in $BOCHS_PROBES; do
        fx=$(python3 "$REF" fx "$k"); bochs_benign "$k" "$fx" && pass=$((pass + 1))
    done
elif [[ "$REQUIRE_EMU" == "1" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (Bochs required under KERNEL_CODEGEN_REQUIRE_EMU=1)"; exit 1
else
    echo "NOTE: Bochs leg skipped (no bochs/parted/grub/xvfb/sudo locally); QEMU is authoritative locally, CI runs Bochs."
fi

echo "ouroboros gate: pass=$pass fail=$fail"
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else exit 1; fi
