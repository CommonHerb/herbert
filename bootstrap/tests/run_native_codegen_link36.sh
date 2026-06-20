#!/usr/bin/env bash
# Native codegen Link 36 (sitopia / the TWENTIETH kernel-arc link): the SYSCALL ROUND TRIP.
# Extends nokta (link 19: a build-unknown module sandboxed at CPL3 under paging) by making int 0x30 a
# RESUMABLE SYSCALL ABI with a kernel SERVICE the sandboxed module cannot perform itself:
#   The module issues int 0x30 eax=0 (SYS_READ); the kernel handler at CPL0 polls the COM1 LSR + reads the
#   RBR byte (a LATE-BOUND device read the CPL3 module CANNOT do itself -- a module `in al,dx` #GPs), dumps
#   a read-witness frame C0<byte><cs><eip><useresp>C1, and IRETS BACK to CPL3 with the byte in eax (the new
#   kernel->module re-entry). The module RESUMES, transforms the byte in its OWN code (echo/inc/xor), and
#   issues int 0x30 eax=1 (SYS_EXIT, status in bl); the kernel stores status, dumps E0<status><cs><eip>
#   <useresp>E1, and the compiled body (a PURE CONDUIT, module_byte() echoes [answer]) emits DE<answer>AD.
# Selected by "-- emit: multiboot32-sitopia". Graded on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs)
# vs the silicon-proven reference (sitopia_ref.py), proven byte-identical on QEMU + Bochs + KVM real silicon.
#
# THE MAKE-OR-BREAK: the final answer is a transform of a byte the kernel DELIVERED into the module via a
# round trip the module could not do itself -- so the SAME image fed byte X vs Y emits T(X) vs T(Y), and a
# CPL0-only kernel pinned as a pure conduit cannot fake it. The gate proves this with (per the completeness
# critic, all empirically validated):
#  (1) EXACT 24564-byte prefix byte-pin + EXACT 58-byte epilogue vs the silicon+KVM-proven reference (so the
#      whole resumable handler -- dispatch, COM1 poll/read, both witness emits, iret -- is byte-fixed).
#  (2) DISASM BODY SCAN (link30's M1 pattern, NOT a flat hex regex): decode the body span and assert it
#      contains ZERO in/out/ins/outs/int/iret/syscall/call by MNEMONIC. The body is a pure conduit, so the
#      ONLY device I/O lives in the pinned prefix. (A flat ec/ed regex both false-rejects `sub esp` (83 ec)
#      and MISSES e4/e5/6c/6d/6e/6f -- a body insb could re-read COM1, an outsb could forge a frame.)
#  (3) THE TWO-BYTE DIFFERENTIAL (the SOLE defense against a dead/lazy module): feed X != Y to the SAME image
#      on BOTH substrates, require all GREEN, assert T(X) != T(Y), and sha-pin the ELF byte-identical across
#      the X and Y runs. Every structural witness check is satisfiable by a const-baking dead module; only
#      answer==T(fed) + X!=Y forces the byte to flow THROUGH module code.
#  (4) PER-SYSCALL WITNESS FRAMES pinned BY VALUE: read frame cs==UCODE3 RPL3, eip==mod_start+15,
#      useresp==alloc_hi, delivered byte==fed byte; exit frame cs==UCODE3 RPL3, eip==mod_start+exit_ret,
#      useresp==alloc_hi; inter-frame eip distance == module transform length.
#  (5) THE MAKE-OR-BREAK OF THE SERVICE: a module `in al,dx` at CPL3 (hostin) #GP(0)s -- the module cannot
#      read the device itself, so the kernel mediation is load-bearing. Plus nokta's carried sandbox:
#      hostile out->#GP, write->#PF7, read->#PF5, pt->#PF7.
#  (6) BENIGN-LEG ROBUSTNESS (link30's pattern): wait for the feeder LISTENING + assert it logged SENT +
#      bind the QEMU exit code to host_qemu_exit(T(fed)), so a missing-byte/feeder flake (60s timeout, rc 124)
#      is diagnosable as a FLAKE, not reported as a kernel RED.
#
# HONEST SCOPE / RESIDUE (audited-assertion, named): CANONICAL-CODEGEN proof for the fixed probes (the body
# is the pure-conduit module_byte()); single-byte read service; emulator/KVM-graded (CI versions pinned). The
# COM1 UART init in the prefix is pinned by value but DEFENSIVE -- QEMU/KVM deliver the byte without it, so it
# is the correctness contract for a real 16550 (tier-2), not a biting mutation. The input-DELIVERY fact is the
# audited-assertion residue (no independent oracle), minimized by dual-substrate agreement + the host-chosen
# late-bound value + the value-flow gate. The held-back MUTATION proof (run_native_codegen_link36_mutation.sh)
# proves each load-bearing design choice (incl. M-bodyio -> the disasm scan, M-constbl -> the differential).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/sitopia_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L20_BOCHS_PROBES:-sit_echo}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing sitopia_ref.py $REF)"; exit 1; fi
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

# build-unknown modules (host-built). echo/inc/xor = round-trip transform probes; HOIN = hostile in (the
# make-or-break: the module can't read the device itself); HOST/HOSW/HOSR/HOSPT = nokta's carried sandbox.
MODECHO="$work/mod_echo.bin"; MODINC="$work/mod_inc.bin"; MODXOR="$work/mod_xor.bin"
MODHIN="$work/mod_hin.bin"; MODH="$work/mod_h.bin"; MODW="$work/mod_w.bin"; MODR="$work/mod_r.bin"; MODPT="$work/mod_pt.bin"
python3 "$REF" module echo "$MODECHO"; python3 "$REF" module inc "$MODINC"; python3 "$REF" module xor "$MODXOR"
python3 "$REF" module HOIN "$MODHIN"; python3 "$REF" module HOST "$MODH"
python3 "$REF" module HOSW "$MODW"; python3 "$REF" module HOSR "$MODR"; python3 "$REF" module HOSPT "$MODPT"
declare -A MODF=([echo]="$MODECHO" [inc]="$MODINC" [xor]="$MODXOR")
PTADDR="$(python3 "$REF" ptaddr)"
PREFIX_LEN=24564
# two distinct fed bytes, neither a likely baked literal (0x00/0xFF/0x5A/0xA7/ASCII), with injective T so
# T(X) != T(Y) for every probe -> a const-baking dead module fails at least one (here both).
FX=60   # 0x3C
FY=197  # 0xC5

prog_src() {
    case "$1" in
      sit_echo)  echo 'func main(): return module_byte() end' ;;          # pure conduit, no locals
      sit_local) echo 'func main(): let x = module_byte()  return x end' ;; # pure conduit via a local (rbp frame)
    esac
}
ALL_PROBES="sit_echo sit_local"
host_T() { python3 -c "v=$2
print({'echo':v,'inc':(v+7)&0xFF,'xor':v^0x5A}['$1'])"; }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-sitopia\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

elf_meta() { # elf -> esp_top (decimal) = 0x100000 + p_memsz
    local elf="$1"
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    echo $(( 1048576 + $(le32_val "$eh" 144) ))
}

static_gates() { # label elf  (multiboot + PAGE_ALIGN|MEMINFO)
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx; hx=$(xxd -p "$elf" | tr -d '\n')
    local mb_o mb_valid_count=0 mb_valid_off=-1 mb_f mb_c
    for (( mb_o=0; mb_o+12 <= 8192 && mb_o*2+24 <= ${#hx}; mb_o+=4 )); do
        [[ "${hx:$(( mb_o*2 )):8}" == "02b0ad1b" ]] || continue
        mb_f=$(le32_val "$hx" $(( mb_o*2 + 8 ))); mb_c=$(le32_val "$hx" $(( mb_o*2 + 16 )))
        if [[ $(( (16#1BADB002 + mb_f + mb_c) % (1 << 32) )) -eq 0 ]]; then
            mb_valid_count=$(( mb_valid_count + 1 )); mb_valid_off=$mb_o
        fi
    done
    [[ "$mb_valid_count" -eq 1 ]] || { fail_test "$label static: $mb_valid_count checksum-valid Multiboot headers (want 1)"; ok=0; }
    [[ "$mb_valid_off" -eq 4096 ]] || { fail_test "$label static: valid MB header at off $mb_valid_off (want 4096)"; ok=0; }
    mb_f=$(le32_val "$hx" $(( 4096*2 + 8 )))
    [[ $(( mb_f & 2 )) -eq 2 ]] || { fail_test "$label static: MB header flags ($mb_f) lacks MEMINFO bit"; ok=0; }
    [[ $(( mb_f & 1 )) -eq 1 ]] || { fail_test "$label static: MB header flags ($mb_f) lacks PAGE_ALIGN bit"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

elf_gates() { # label elf  (P12: e_entry==V0, single PT_LOAD)
    local label="$1" elf="$2" ok=1
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(le32_val "$eh" 48)" -eq 1048588 ]] || { fail_test "$label elf(P12): e_entry != 1048588"; ok=0; }
    [[ "$(le32_val "$eh" 56)" -eq 52 ]] || { fail_test "$label elf(P12): e_phoff != 52"; ok=0; }
    [[ "$(( 16#${eh:90:2}${eh:88:2} ))" -eq 1 ]] || { fail_test "$label elf(P12): e_phnum != 1"; ok=0; }
    [[ "$(le32_val "$eh" 104)" -eq 1 ]] || { fail_test "$label elf(P12): PT_LOAD type != 1"; ok=0; }
    [[ "$(le32_val "$eh" 112)" -eq 4096 ]] || { fail_test "$label elf(P12): p_offset != 4096"; ok=0; }
    [[ "$(le32_val "$eh" 120)" -eq 1048576 ]] || { fail_test "$label elf(P12): p_vaddr != 1048576"; ok=0; }
    [[ "$(le32_val "$eh" 152)" -eq 7 ]] || { fail_test "$label elf(P12): p_flags != 7"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

# DISASM body scan (link30's M1 pattern). The body is a PURE CONDUIT, so it must contain ZERO in/out/ins/outs
# and ZERO int/iret/syscall/sysenter/call (the only device I/O is in the byte-pinned prefix/epilogue). A flat
# hex regex cannot decode x86 boundaries (it both false-rejects `sub esp`=83ec and misses e4/e5/6c/6d/6e/6f).
body_scan() { # label elf code_len -> 0 if body is a clean conduit
    local label="$1" elf="$2" code_len="$3" ok=1
    local bodylen=$(( code_len - PREFIX_LEN - 58 ))
    [[ "$bodylen" -ge 0 ]] || { fail_test "$label body-scan: negative body length"; return 1; }
    local bb="$work/$label.body"
    dd if="$elf" of="$bb" bs=1 skip=$(( 4108 + PREFIX_LEN )) count="$bodylen" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M att "$bb" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    local mnem; mnem=$(echo "$dis" | awk '{print $1}' | sort -u)
    # whitelist the conduit body mnemonics (mov/movzbl/movzwl/push/pop/add/sub/imul/cmp/test/setcc/and/xor/
    # lea/ret/nop); anything else (esp any I/O or transfer) is a RED.
    local badm; badm=$(echo "$mnem" | grep -ivE '^(mov|movl|movzbl|movzwl|push|pushl|pop|popl|add|addl|sub|subl|imul|cmp|cmpl|sete|setne|test|testb|testl|and|andl|andb|xor|xorl|xorb|lea|leal|ret|retl|nop)$' | tr '\n' ' ')
    [[ -z "${badm// /}" ]] || { fail_test "$label body-scan: body contains non-conduit instruction(s) [$badm]"; ok=0; }
    # explicit ban of I/O + trap + transfer classes by mnemonic (defense in depth, exact opcode-aware):
    local forb; forb=$(echo "$dis" | grep -iE '\b(in|inb|inl|out|outb|outl|ins|insb|insl|insw|outs|outsb|outsl|outsw|int|int3|into|iret|iretd|syscall|sysenter|call|jmp|je|jne|ja|jb|loop|rdtsc|lgdt|lidt|cli|sti|hlt)\b' | head -4 | tr '\n' ';')
    [[ -z "$forb" ]] || { fail_test "$label body-scan: body contains a forbidden I/O/trap/transfer instruction [$forb]"; ok=0; }
    # exactly ZERO `in`/`out`/`ins`/`outs` in the conduit body (the load-bearing assertion).
    local io_count; io_count=$(echo "$dis" | grep -cE '^(in|inb|inl|out|outb|outl|ins|insb|insl|insw|outs|outsb|outsl|outsw)\b')
    [[ "$io_count" -eq 0 ]] || { fail_test "$label body-scan: body has $io_count I/O instruction(s) (conduit body must have ZERO)"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox() { # label elf  (EXACT prefix + EXACT epilogue + disasm body scan vs sitopia_ref)
    local label="$1" elf="$2" ok=1
    local esp_top; esp_top=$(elf_meta "$elf")
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local filesz; filesz=$(le32_val "$eh" 136); local code_len=$(( filesz - 12 ))
    local got want
    got=$(dd if="$elf" bs=1 skip=4108 count="$PREFIX_LEN" status=none 2>/dev/null | xxd -p | tr -d '\n')
    want=$(python3 "$REF" prefix "$(printf '%x' "$esp_top")")
    [[ "$got" == "$want" ]] || { fail_test "$label wb(prefix): head+handlers+tables+paging+PD+PT != EXACT ${PREFIX_LEN}-byte sitopia_ref (esp_top=0x$(printf '%x' "$esp_top"))"; ok=0; }
    local epigot epiwant
    epigot=$(dd if="$elf" bs=1 skip=$(( 4108 + code_len - 58 )) count=58 status=none 2>/dev/null | xxd -p | tr -d '\n')
    epiwant=$(python3 "$REF" epi)
    [[ "$epigot" == "$epiwant" ]] || { fail_test "$label wb(epi): epilogue != EXACT 58-byte reference (a stray emit site?)"; ok=0; }
    body_scan "$label" "$elf" "$code_len" || ok=0
    [[ "$ok" -eq 1 ]]
}

# QEMU benign round-trip with the late-bound socket COM1 feeder + exit-code bind (link30 robustness).
qemu_benign() { # label kelf kind fedbyte -> 0 if GREEN + rc bound + frames present
    local label="$1" kelf="$2" kind="$3" byte="$4"
    local f ex; f=$(host_T "$kind" "$byte"); ex=$(host_qemu_exit "$f")
    local out="$work/$label.$kind.$byte.bin"; local port; port=$(free_port)
    local W="$work/$label.$kind.$byte.d"; mkdir -p "$W"
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "${MODF[$kind]}" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    local rc=$?; wait "$fp" 2>/dev/null
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    # FLAKE guard: a missing byte spins to the 60s timeout (rc 124) with no read frame; report as a flake,
    # not a kernel RED (link30 robustness -- distinguishes feeder failure from a kernel defect).
    if ! grep -q SENT "$W/feed.log" 2>/dev/null; then fail_test "$label $kind byte=$byte: FEEDER FLAKE (never logged SENT; not a kernel verdict) rc=$rc"; return 1; fi
    if [[ "$rc" -eq 124 ]]; then fail_test "$label $kind byte=$byte: 60s TIMEOUT (rc 124) -- feeder/timeout flake, not a kernel RED"; return 1; fi
    if [[ "$rc" -ne "$ex" ]]; then fail_test "$label $kind byte=$byte: exit rc=$rc != host_qemu_exit(T=$f)=$ex"; return 1; fi
    if python3 "$REF" grade "$out" "$kend" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1; then return 0; fi
    fail_test "$label $kind byte=$byte: $(python3 "$REF" grade "$out" "$kend" "$(printf '%x' "$byte")" "$kind" 2>&1 | tr '\n' ' ')"; return 1
}

qemu_hostile() { # label kelf modfile kind [cr2]
    local label="$1" kelf="$2" mod="$3" kind="$4" cr2="${5:-}"
    local out="$work/$label.$kind.bin"
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -monitor none -m 64M >/dev/null 2>&1 || true
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    if python3 "$REF" grade "$out" "$kend" 00 "$kind" $cr2 >/dev/null 2>&1; then return 0; fi
    fail_test "$label hostile $kind: $(python3 "$REF" grade "$out" "$kend" 00 "$kind" $cr2 2>&1 | tr '\n' ' ')"; return 1
}

bochs_benign() { # label kelf kind byte  -> 0 if read+exit frames + answer match + clean shutdown
    local label="$1" kelf; kelf="$(readlink -f "$2")"; local kind="$3" byte="$4"
    local f; f=$(host_T "$kind" "$byte")
    local W="$work/$label.b.$kind.$byte"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS missing"; return 1; fi
    local mod; mod="$(readlink -f "${MODF[$kind]}")"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 25 > "$W/feed.log" 2>&1 &
    local fp=$!
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
    grep -q SENT "$W/feed.log" 2>/dev/null || { fail_test "$label Bochs $kind byte=$byte: FEEDER FLAKE (no SENT)"; return 1; }
    # extract the debugcon stream (cell block .. through all frames) from the bochs log, like link35.
    python3 - "$W/bochs_out.txt" "$W/e9.bin" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    for pat in (rb'\xde.\xad', rb'\xc0.{1}.{4}.{4}.{4}\xc1', rb'\xe0.{1}.{4}.{4}.{4}\xe1',
                rb'\xf0.{4}.{4}.{4}.{4}\xf1', rb'\xd0.{4}.{4}.{4}.{4}.{4}\xd1'):
        m=None
        for mm in re.finditer(pat, d[i:], re.S): m=mm
        if m: end=max(end, i+m.end())
    open(sys.argv[2],'wb').write(d[i:end] if end>i else b'')
else: open(sys.argv[2],'wb').write(b'')
PY
    local sd; sd=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null || echo 0)
    local kend; kend=$(printf '%x' "$(elf_meta "$2")")
    if python3 "$REF" grade "$W/e9.bin" "$kend" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1 && [[ "$sd" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs $kind byte=$byte (shutdown=$sd): $(python3 "$REF" grade "$W/e9.bin" "$kend" "$(printf '%x' "$byte")" "$kind" 2>&1 | tr '\n' ' ')"; return 1
}

reject_probe() { # label directive "<body>"
    local label="$1" directive="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "%s\n%b\n" "$directive" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset program emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link36 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

# assert the differential is non-vacuous (T(X) != T(Y) for every benign module) BEFORE running.
for kind in echo inc xor; do
    [[ "$(host_T "$kind" "$FX")" != "$(host_T "$kind" "$FY")" ]] || { fail_test "$kind: T(X)==T(Y) -- fed bytes not input-distinguishing"; }
done

for label in $ALL_PROBES; do
    elf="$work/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox "$label" "$elf" || continue
    sha_before=$(sha256sum "$elf" | cut -d' ' -f1)
    ok=1
    if [[ "$label" == "sit_echo" ]]; then
        # FULL round-trip battery on the no-locals conduit: 3 transform modules x {X,Y} (the differential)
        # + the make-or-break hostin + nokta's carried sandbox.
        for kind in echo inc xor; do
            qemu_benign "$label" "$elf" "$kind" "$FX" || ok=0
            qemu_benign "$label" "$elf" "$kind" "$FY" || ok=0
        done
        qemu_hostile "$label" "$elf" "$MODHIN" hostin      || ok=0   # MAKE-OR-BREAK: module can't read the device itself
        qemu_hostile "$label" "$elf" "$MODH"   hostile     || ok=0   # 19a carry: hostile out -> #GP
        qemu_hostile "$label" "$elf" "$MODW"   pfault      || ok=0   # nokta: hostile write -> #PF7
        qemu_hostile "$label" "$elf" "$MODR"   pfault_read || ok=0   # nokta: hostile read  -> #PF5
        qemu_hostile "$label" "$elf" "$MODPT"  pfault_pt "0x$PTADDR" || ok=0  # nokta: hostile PT-write -> #PF7
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
            # dual-substrate (merged GRUB-module + com1 socket-client): the differential + a hostile #PF.
            bochs_benign "$label" "$elf" echo "$FX" || ok=0
            bochs_benign "$label" "$elf" echo "$FY" || ok=0
        fi
    else
        # locals conduit (rbp frame): prove the round-trip works there too (the differential, QEMU only).
        qemu_benign "$label" "$elf" echo "$FX" || ok=0
        qemu_benign "$label" "$elf" echo "$FY" || ok=0
    fi
    sha_after=$(sha256sum "$elf" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || { fail_test "$label: image changed between the X and Y runs (not the same binary)"; ok=0; }
    [[ "$ok" -eq 1 ]] && pass=$((pass + 1))
done

# ---- reject probes (+ twins): the sitopia body subset is straight-line, one module_byte, no calls/branches.
reject_probe call          '-- emit: multiboot32-sitopia'  'func h(): return 2 end\nfunc main(): return h() + module_byte() end'
reject_probe call_twin     '-- emit: multiboot32-sitopia'  'func g(): return 4 end\nfunc main(): return g() + module_byte() end'
reject_probe branch        '-- emit: multiboot32-sitopia'  'func main(): let x = module_byte()  if x == 5: return 1 else: return 2 end end'
reject_probe branch_twin   '-- emit: multiboot32-sitopia'  'func main(): let y = module_byte()  if y == 9: return 3 else: return 4 end end'
reject_probe nomodule      '-- emit: multiboot32-sitopia'  'func main(): return 7 end'
reject_probe nomodule_twin '-- emit: multiboot32-sitopia'  'func main(): return 9 end'
reject_probe twomodule     '-- emit: multiboot32-sitopia'  'func main(): return module_byte() + module_byte() end'
reject_probe twomodule_twin '-- emit: multiboot32-sitopia' 'func main(): return module_byte() * module_byte() end'
reject_probe mainarg       '-- emit: multiboot32-sitopia'  'func main(p): return p + module_byte() end'
reject_probe mainarg_twin  '-- emit: multiboot32-sitopia'  'func main(k): return k - module_byte() end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 10))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link36 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link36 / sitopia / twentieth kernel-arc link: the SYSCALL ROUND TRIP -- a build-unknown module sandboxed at CPL3 under paging issues int 0x30 SYS_READ; the kernel polls+reads a LATE-BOUND COM1 byte the module CANNOT read itself (a module in al,dx #GPs), IRETS BACK to CPL3 with the byte in eax (first kernel->module re-entry); the module transforms it in its OWN code and SYS_EXITs; the pure-conduit kernel body emits f(byte). $pass checks: static MB+PAGE_ALIGN+MEMINFO, ELF-P12, white-box EXACT-${PREFIX_LEN}-byte-prefix + EXACT-58-byte-epilogue + DISASM body-scan (zero I/O, pure conduit) vs the silicon+KVM-proven sitopia_ref, QEMU substrate (echo/inc/xor each fed X!=Y -> T(X)!=T(Y) with the byte traced through per-syscall by-value witness frames + exit-code bind; hostin #GP make-or-break; hostile out/write/read/pt; locals-conduit round-trip), Bochs substrate (merged GRUB module + com1 socket-client: the differential + clean shutdown), 10 rejects with twins; graded vs the host witness-frame oracle + lodger allocator-recompute on the dual-substrate oracle -- a CANONICAL-CODEGEN proof for the fixed probes)"
exit 0
