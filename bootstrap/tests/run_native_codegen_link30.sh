#!/usr/bin/env bash
# Native codegen Link 30 (trukfit / f3, the FOURTEENTH kernel-arc link): DEVICE INPUT.
# The first link that READS a device. A new emit mode (selected by the anchored first
# line "-- emit: multiboot32-input") compiles a body that READS one LATE-BOUND byte from
# COM1 via `in al,dx` (0xEC -- the first port-INPUT opcode; only immediate-form `out`
# existed before), transforms it through the proven 32-bit toakie subset, and emits the
# result framed 0xDE<byte>0xAD on debugcon 0xE9. The byte is NOT known at build time: the
# SAME image fed byte X vs byte Y emits f(X) vs f(Y), which defeats a "literal-baker" by
# construction. Graded on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs), now with a
# LATE-BOUND INPUT SUBSTRATE: a socket-backed COM1 (kernel_input_feed.py is a TCP server;
# QEMU -chardev socket / Bochs com1 mode=socket-client connect as clients). Bochs com1
# FILE mode is output-only, so socket mode is the forced symmetric channel.
#
# HONEST SCOPE (read this): this is a CANONICAL-CODEGEN proof, NOT a general input-semantics
# proof. The white-box gate pins the EXACT host-derived lowering of the THREE fixed probes,
# so it proves those probes read the live RBR byte and compute their source f -- it does NOT
# prove an arbitrary accepted input body computes its f. 32-bit protected mode (device read
# is orthogonal to bitness; the long64 links stay as regression). Single-byte read (the gate
# enforces exactly one RBR read). Emulator-graded, emulators unpinned. The input-DELIVERY
# fact is the first audited-assertion residue (no independent oracle), minimized by the
# dual-substrate AGREEMENT + the host-chosen late-bound value + the value-flow gate.
#
# THE VALUE-FLOW GATE (the crux -- the emitted byte is RUNTIME-input-dependent, so unlike
# every prior link the output value cannot be pinned; instead the whole reachable CODE is
# pinned so the byte provably FLOWS from the RBR read):
#   M1 WHOLE-IMAGE SCAN: disassemble the ENTIRE code span (entry -> cli;hlt) and whitelist
#     instructions; the ONLY `in` are the two `in al,dx` of the op45 lowering; BAN rdtsc,
#     lgdt/lidt, sti, pushf/popf, iret, int, ins, call -- so no async handler / 2nd reader /
#     nondeterminism can source the byte. (Codex+critic: a body pin alone is insufficient
#     because the RBR byte is a LIVE hardware channel that persists after the body runs.)
#   M3 UART-INIT PIN: the exact 56-byte robust init (force DLAB=0 first) pinned by value.
#   M4 PROVENANCE: the body bytes == the exact host-derived lowering of THIS probe, with the
#     RBR read -> movzx -> push bound as a contiguous window, ending at the epilogue.
#   ELF P12: e_entry==V0, single PT_LOAD.
#   RUNTIME: same image (sha asserted), bytes X and Y, both substrates agree with host f, and
#     f(X) != f(Y).
# The held-back MUTATION proof (run_native_codegen_link30_mutation.sh) binary-patches the RBR
# read to a literal and confirms the X/Y differential COLLAPSES + the gate goes RED.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L14_BOCHS_PROBES:-f3_echo f3_inc}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
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

occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

# ---- the EXACT pinned byte sequences (host-derived; see the empirical pre-build) ----------
# 56-byte robust COM1 init: LCR=03(DLAB=0 first); IER=0; LCR=80; DLL=1; DLM=0; LCR=03; FCR=0; MCR=03.
UART_HEX='66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee'
# the proven 58-byte epilogue (mov bl,al; frame DE<bl>AD on 0xE9; isa-debug-exit 0xF4; Bochs
# "Shutdown" on 0x8900; cli; hlt; jmp $).
EPILOGUE_HEX='88c366bae900b0deee88d8eeb0adee88d83431247f66baf400ee66ba0089b053eeb068eeb075eeb074eeb064eeb06feeb077eeb06eeefaf4ebfd'
# the 18-byte op_input_byte lowering: poll LSR(0x3FD); RBR read(0x3F8); movzx; push.
OP45_HEX='66bafd03eca80174f766baf803ec0fb6c050'

# ---- probes: source, exact body lowering, host transform f, two distinct bytes X/Y --------
prog_src() {
    case "$1" in
      f3_echo) echo 'func main(): return input_byte() end' ;;
      f3_inc)  echo 'func main(): return input_byte() + 7 end' ;;
      f3_mul)  echo 'func main(): let b = input_byte()  return b * 3 + 1 end' ;;
    esac
}
# body = op45 lowering + transform-lowering + terminal RET (58). nlocals: echo/inc 0, mul 1.
expected_body() {
    case "$1" in
      f3_echo) echo "${OP45_HEX}58" ;;
      f3_inc)  echo "${OP45_HEX}6807000000595801c85058" ;;   # push 7; add; ret
      f3_mul)  echo "${OP45_HEX}8f45fcff75fc680300000059580fafc1506801000000595801c85058" ;;
    esac
}
probe_nlocals() { case "$1" in f3_mul) echo 1 ;; *) echo 0 ;; esac; }
host_f() { # label byte -> f(byte) & 0xff
    case "$1" in
      f3_echo) echo $(( $2 & 0xff )) ;;
      f3_inc)  echo $(( ($2 + 7) & 0xff )) ;;
      f3_mul)  echo $(( ($2 * 3 + 1) & 0xff )) ;;
    esac
}
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }
probe_X() { case "$1" in f3_echo) echo 65 ;; f3_inc) echo 65 ;; f3_mul) echo 16 ;; esac; }
probe_Y() { case "$1" in f3_echo) echo 183 ;; f3_inc) echo 254 ;; f3_mul) echo 85 ;; esac; }
ALL_PROBES="f3_echo f3_inc f3_mul"

# derive the exact image sizes from the pinned body (so the gate binds esp + the PHDR sizes
# BY VALUE -- a forged esp into code, or a mismatched PT_LOAD memsz, is then rejected).
# echoes: "prefix_len bodylen code_len filesz memsz esp_val"
derive_sizes() {
    local label="$1" nlocals pl want bodylen code_len memsz
    nlocals=$(probe_nlocals "$label"); pl=61; [[ "$nlocals" -gt 0 ]] && pl=66
    want=$(expected_body "$label"); bodylen=$(( ${#want} / 2 ))
    code_len=$(( pl + bodylen + 58 )); memsz=$(( 12 + code_len + 16384 ))
    echo "$pl $bodylen $code_len $(( 12 + code_len )) $memsz $(( 1048576 + memsz ))"
}

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-input\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

static_gates() { # label elf
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
    [[ "$ok" -eq 1 ]]
}

elf_gates() { # label elf  (P12: e_entry==V0, single PT_LOAD)
    local label="$1" elf="$2" ok=1
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local e_entry e_phoff e_phnum p_type p_offset p_vaddr p_flags
    e_entry=$(le32_val "$eh" 48); e_phoff=$(le32_val "$eh" 56); e_phnum=$(( 16#${eh:90:2}${eh:88:2} ))
    [[ "$e_entry" -eq 1048588 ]] || { fail_test "$label elf(P12): e_entry ($e_entry) != 1048588 (V0)"; ok=0; }
    [[ "$e_phoff" -eq 52 ]] || { fail_test "$label elf(P12): e_phoff ($e_phoff) != 52"; ok=0; }
    [[ "$e_phnum" -eq 1 ]] || { fail_test "$label elf(P12): e_phnum ($e_phnum) != 1"; ok=0; }
    p_type=$(le32_val "$eh" 104); p_offset=$(le32_val "$eh" 112); p_vaddr=$(le32_val "$eh" 120); p_flags=$(le32_val "$eh" 152)
    [[ "$p_type" -eq 1 ]] || { fail_test "$label elf(P12): PT_LOAD type ($p_type) != 1"; ok=0; }
    [[ "$p_offset" -eq 4096 ]] || { fail_test "$label elf(P12): p_offset ($p_offset) != 4096"; ok=0; }
    [[ "$p_vaddr" -eq 1048576 ]] || { fail_test "$label elf(P12): p_vaddr ($p_vaddr) != 1048576"; ok=0; }
    [[ "$p_flags" -eq 7 ]] || { fail_test "$label elf(P12): p_flags ($p_flags) != 7"; ok=0; }
    # PHDR sizes bound BY VALUE to the derived layout (Codex hardening): p_paddr@64, p_filesz@68,
    # p_memsz@72 -> hexpos 128/136/144.
    local sz; sz=($(derive_sizes "$label")); local d_filesz="${sz[3]}" d_memsz="${sz[4]}"
    local p_paddr p_filesz p_memsz
    p_paddr=$(le32_val "$eh" 128); p_filesz=$(le32_val "$eh" 136); p_memsz=$(le32_val "$eh" 144)
    [[ "$p_paddr" -eq 1048576 ]] || { fail_test "$label elf(P12): p_paddr ($p_paddr) != 1048576"; ok=0; }
    [[ "$p_filesz" -eq "$d_filesz" ]] || { fail_test "$label elf(P12): p_filesz ($p_filesz) != derived ($d_filesz)"; ok=0; }
    [[ "$p_memsz" -eq "$d_memsz" ]] || { fail_test "$label elf(P12): p_memsz ($p_memsz) != derived ($d_memsz)"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$work/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    local nlocals; nlocals=$(probe_nlocals "$label")
    local prefix_len=61; [[ "$nlocals" -gt 0 ]] && prefix_len=66
    # (1) mov esp,imm32 at offset 0 -- and the immediate BOUND to the derived stack top, so esp
    #     cannot point into code/data (which push/pop could self-modify after the static scan).
    [[ "${chx:0:2}" == "bc" ]] || { fail_test "$label wb: no mov esp,imm32 (bc) at entry"; ok=0; }
    local sz; sz=($(derive_sizes "$label")); local d_esp="${sz[5]}"
    local esp_imm; esp_imm=$(le32_val "$chx" 2)
    [[ "$esp_imm" -eq "$d_esp" ]] || { fail_test "$label wb: mov esp imm ($esp_imm) != derived stack top ($d_esp) -- esp could point into code"; ok=0; }
    # (M3) the EXACT 56-byte UART init at offset 5 (hexpos 10), present EXACTLY ONCE.
    [[ "${chx:10:112}" == "$UART_HEX" ]] || { fail_test "$label wb: UART init bytes at offset 5 != pinned robust sequence"; ok=0; }
    [[ "$(occ "$chx" "$UART_HEX")" == 1 ]] || { fail_test "$label wb: UART init sequence not present exactly once"; ok=0; }
    # rbp frame (locals probe): 89 e5 83 ec XX right after the uart init (offset 61, hexpos 122).
    if [[ "$nlocals" -gt 0 ]]; then
        [[ "${chx:122:8}" == "89e583ec" ]] || { fail_test "$label wb: no rbp frame (89 e5 83 ec) after uart init"; ok=0; }
        local subimm=$(( 16#${chx:130:2} ))
        [[ "$subimm" -eq $(( 4 * nlocals )) ]] || { fail_test "$label wb: sub esp imm ($subimm) != 4*nlocals"; ok=0; }
    fi
    # (M4) PROVENANCE: body bytes == the exact host-derived lowering, ending at the epilogue.
    local body_hexstart=$(( prefix_len * 2 ))
    local want; want=$(expected_body "$label")
    [[ "${chx:body_hexstart:${#want}}" == "$want" ]] || { fail_test "$label wb: body != expected genuine lowering (provenance) -- got ${chx:body_hexstart:48}... want ${want:0:48}..."; ok=0; }
    # the epilogue follows the body immediately and is the exact proven 58 bytes.
    local epi_hexstart=$(( body_hexstart + ${#want} ))
    [[ "${chx:epi_hexstart:116}" == "$EPILOGUE_HEX" ]] || { fail_test "$label wb: epilogue != the proven 58-byte sequence (no bytes between body and epilogue)"; ok=0; }
    # (M4) the RBR read is bound: exactly one poll (66bafd03ec) + exactly one RBR read+consume
    #      (66baf803ec0fb6c050 -- read; movzx; push, contiguous) -- so the value traces to the RBR.
    [[ "$(occ "$chx" '66bafd03ec')" == 1 ]] || { fail_test "$label wb: LSR poll (66 ba fd 03 ec) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '66baf803ec0fb6c050')" == 1 ]] || { fail_test "$label wb: RBR read->movzx->push (66 ba f8 03 ec 0f b6 c0 50) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '74f7')" == 1 ]] || { fail_test "$label wb: poll back-edge (74 f7) not present exactly once"; ok=0; }
    # (M1) WHOLE-IMAGE SCAN: disassemble entry -> cli;hlt and whitelist; the ONLY `in` are the two
    #      `in (%dx),%al`; BAN any async/nondeterminism/2nd-reader opcode that could re-source the byte.
    local epi_end=$(( epi_hexstart + 116 ))         # hexpos just past faf4ebfd
    local span_bytes=$(( epi_end / 2 ))
    dd if="$code" of="$code.span" bs=1 count="$span_bytes" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M att "$code.span" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    local mnem; mnem=$(echo "$dis" | awk '{print $1}' | sort -u)
    local badm; badm=$(echo "$mnem" | grep -ivE '^(mov|movzbl|movzwl|push|pushl|pop|popl|add|addl|sub|subl|imul|cmp|cmpl|sete|setne|test|testb|testl|je|jne|jmp|in|out|outb|inb|xor|xorb|and|andb|cli|hlt|nop)$' | tr '\n' ' ')
    [[ -z "${badm// /}" ]] || { fail_test "$label wb(M1): code-span contains non-whitelisted instruction(s) [$badm]"; ok=0; }
    # explicit forbidden-class scan (defense in depth, in case objdump mnemonic differs):
    local forb; forb=$(echo "$dis" | grep -iE '\b(rdtsc|lgdt|lidt|lldt|sti|pushf|popf|iret|int|ins|insb|insl|insw|call|sysenter|syscall|rdmsr|wrmsr|cpuid)\b' | head -3 | tr '\n' ';')
    [[ -z "$forb" ]] || { fail_test "$label wb(M1): forbidden instruction in code span [$forb]"; ok=0; }
    # exactly TWO `in` (poll + RBR), both `in (%dx),%al`; ZERO `in $imm`/`in ...,%eax`.
    local in_count; in_count=$(echo "$dis" | grep -cE '^(in|inb)\b')
    [[ "$in_count" -eq 2 ]] || { fail_test "$label wb(M1): code span has $in_count `in` instructions (want exactly 2: poll+RBR)"; ok=0; }
    local in_bad; in_bad=$(echo "$dis" | grep -E '^(in|inb)\b' | grep -ivE 'in +\(%dx\),%al' | tr '\n' ';')
    [[ -z "$in_bad" ]] || { fail_test "$label wb(M1): an `in` is not `in (%dx),%al` [$in_bad]"; ok=0; }
    # (ELF) e_entry bytes that run.
    local eentry; eentry=$(dd if="$elf" bs=1 skip=24 count=4 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$eentry" == "0c001000" ]] || { fail_test "$label wb: e_entry (0x$eentry) != 0x0010000c"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

# ---- QEMU substrate with the late-bound socket input feeder --------------------------------
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
qemu_run_byte() { # label elf byte -> 0 if output == host f(byte) and exit matches
    local label="$1" elf="$2" byte="$3"
    local f ex fh; f=$(host_f "$label" "$byte"); ex=$(host_qemu_exit "$f"); fh=$(printf '%02x' "$f")
    local W="$work/$label.q.$byte"; mkdir -p "$W"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none -cpu qemu64 -m 64M
    local rc=$?; wait "$fp" 2>/dev/null
    local got; got=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    local nframes; nframes=$(echo "$got" | grep -o "de${fh}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && [[ "$got" == "de${fh}ad" ]] && [[ "$nframes" -eq 1 ]]; then return 0; fi
    fail_test "$label QEMU byte=$byte: exit=$rc(want $ex) e9=$got want=de${fh}ad nframes=$nframes"; return 1
}

bochs_run_byte() { # label elf byte
    local label="$1" elf="$2" byte="$3"
    local f fh; f=$(host_f "$label" "$byte"); fh=$(printf '%02x' "$f")
    local W="$work/$label.b.$byte"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS missing"; return 1; fi
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
      sudo mkdir -p mnt/boot/grub; sudo cp "$elf" mnt/boot/kernel.elf
      printf 'set timeout=0\nset default=0\nmenuentry "i" {\n multiboot /boot/kernel.elf\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nframes shutdown
    nframes=$(grep -o "de${fh}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    shutdown=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    if [[ "$nframes" -eq 1 ]] && [[ "$shutdown" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs byte=$byte: frames(de${fh}ad)=$nframes shutdown=$shutdown"; return 1
}

reject_probe() { # label directive "<body>"  -- must NOT emit a valid multiboot image
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
    echo "SKIP: native-codegen link30 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

for label in $ALL_PROBES; do
    elf="$work/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox_gates "$label" "$elf" || continue
    X=$(probe_X "$label"); Y=$(probe_Y "$label")
    fx=$(host_f "$label" "$X"); fy=$(host_f "$label" "$Y")
    [[ "$fx" -ne "$fy" ]] || { fail_test "$label: f(X)==f(Y) -- probe not input-distinguishing"; continue; }
    # SAME IMAGE for both bytes (a literal-baker can't bake an answer it doesn't know at build time):
    # assert the elf is byte-identical across the X and Y runs (no run mutates it).
    sha_before=$(sha256sum "$elf" | cut -d' ' -f1)
    ok=1
    qemu_run_byte "$label" "$elf" "$X" || ok=0
    qemu_run_byte "$label" "$elf" "$Y" || ok=0
    if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
        bochs_run_byte "$label" "$elf" "$X" || ok=0
        bochs_run_byte "$label" "$elf" "$Y" || ok=0
    fi
    sha_after=$(sha256sum "$elf" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || { fail_test "$label: image changed between the X and Y runs (not the same binary)"; ok=0; }
    [[ "$ok" -eq 1 ]] && pass=$((pass + 1))
done

# ---- reject probes (+ renamed twins): the input op is ISOLATED to the input mode -----------
# near-axis (NO directive) input_byte -> rejected (ERR 408 catch-all), no valid image (M5).
reject_probe na_input      ''                            'func main(): return input_byte() end'
reject_probe na_input_twin ''                            'func main(): return input_byte() + 1 end'
# plain multiboot32 + input_byte -> rejected (build_depths rejects op 45).
reject_probe plain_input   '-- emit: multiboot32'        'func main(): return input_byte() end'
reject_probe idt_input     '-- emit: multiboot32-idt'    'func main(): return input_byte() end'
# input mode requires EXACTLY ONE read -> two reads rejected (single-byte scope).
reject_probe two_reads     '-- emit: multiboot32-input'  'func main(): return input_byte() + input_byte() end'
# input mode with NO read -> rejected (must genuinely read a device).
reject_probe no_read       '-- emit: multiboot32-input'  'func main(): return 42 end'
# input mode + out-of-subset construct (div / bitwise) -> rejected, with twins.
reject_probe in_div        '-- emit: multiboot32-input'  'func main(): return input_byte() / 2 end'
reject_probe in_div_twin   '-- emit: multiboot32-input'  'func main(): return input_byte() / 3 end'
reject_probe in_band       '-- emit: multiboot32-input'  'func main(): return input_byte() & 15 end'
# control flow (branches) is NOT in the straight-line input subset -> rejected, with a twin. This
# closes the "dead read on a branch arm" case: a branchy input body cannot compile, so the single
# static input_byte is provably the single DYNAMIC read (Codex diff-review hardening).
reject_probe in_branch     '-- emit: multiboot32-input'  'func main(): let b = input_byte()  if b == 5: return 1 else: return 2 end end'
reject_probe in_branch_twin '-- emit: multiboot32-input' 'func main(): let b = input_byte()  if b == 9: return 7 else: return 8 end end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 11))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link30 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link30 / trukfit / f3 / fourteenth kernel-arc link: DEVICE INPUT -- a freestanding 32-bit image READS one late-bound byte from COM1 via in al,dx (0xEC), transforms it, and emits f(byte); $pass checks: static + ELF-P12 + white-box [mov esp; the exact 56-byte robust UART init pinned by value; (locals) rbp frame; M4 PROVENANCE body == host-derived lowering ending at the proven 58-byte epilogue; the LSR poll + RBR-read->movzx->push bound exactly-once so the byte traces to the RBR; M1 WHOLE-IMAGE disasm whitelist banning rdtsc/lgdt/lidt/sti/pushf/popf/iret/int/ins/call so no async/2nd-reader/nondeterminism re-sources the byte, exactly TWO in (%dx),%al], QEMU substrate (3 probes f3_echo/f3_inc/f3_mul, late-bound socket COM1 feeder, same image fed X and Y -> f(X) and f(Y), f(X)!=f(Y)), Bochs substrate ($BOCHS_PROBES, socket com1, frame + clean shutdown), 9 rejects with twins (near-axis/plain/idt input_byte, two-read, no-read, in+div/bitwise); graded vs host-derived golden on the dual-substrate oracle with a late-bound input substrate -- a CANONICAL-CODEGEN proof for the fixed probes)"
exit 0
