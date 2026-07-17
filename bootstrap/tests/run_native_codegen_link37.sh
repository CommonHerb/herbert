#!/usr/bin/env bash
# Native codegen Link 37 (geeking / the TWENTY-FIRST kernel-arc link): THE KERNEL OUTLIVES ITS MODULE.
# Extends sitopia (link 20: a resumable int 0x30 syscall ABI on a CPL3-sandboxed build-unknown module) with
# the lifecycle's missing TERMINATE verb, in two halves -- the kernel now persists past a module that won't
# yield AND past a module that faults:
#   (i) ASYNC WATCHDOG-KILL: the module is entered with IF=1 at CPL3; a one-shot PIT (mode 0) is re-armed
#       before every iretd-to-CPL3, after a stale-IRR drain (sti;nop;nop;cli x<=4 + OCW3 IRR read). On a tick
#       that lands IN the module (a runaway EB FE spinner), the vec-0x20 handler is RPL-KEYED: RPL3 -> EOI,
#       dump a kill-witness frame CA<eip><cs><useresp><eflags>CB (the FIRST CPU-authored ASYNC ring-cross
#       frame -- TSS.esp0 stack switch exercised asynchronously), store 'K' to [answer], mov esp,kstack, jmp
#       body (NEVER iret back). A tick at RPL0 (drain window / COM1 poll) -> EOI + iretd (harmless discard).
#   (ii) FAULT->CONTINUE: the #GP/#PF handler tails (witness frames BYTE-IDENTICAL nokta) and the GENERALIZED
#       panic path no longer shutdown -- they NAME the fault ('G'=#GP, 'P'=#PF, 'F'=any other CPL3 exception
#       w/ no dedicated handler: #DB via popfd-TF, #DE div0, #UD bad opcode), mov esp,kstack, jmp body. ALL
#       THREE fault tails are RPL-KEYED uniformly: a genuine RPL0 KERNEL fault still panics+shutdowns (a kernel
#       bug must NEVER masquerade as a module fault) -- the dedicated #GP/#PF tails key on cs at [esp+8] (their
#       errcode frame), the generalized panic path on [esp+4] (no-errcode #DB/#DE/#UD). [HONEST: the only
#       un-keyed case is a panic-ROUTED errcode-pusher (#DF/#TS/#NP/#SS/#AC/#CP) whose [esp+4] is EIP not cs --
#       but NONE is CPL3-reachable on this flat-seg / CR0.AM=0 / IOPB-deny-all / single-DPL0-TSS / no-task-gate
#       artifact, and the master prefix-pin freezes the kernel so no gate-passing emitter can introduce one;
#       a future link adding a DPL3 gate / LDT / 2nd TSS / non-flat seg / CET / CR0.AM=1 must re-derive this.
#       Every REAL module fault is RPL3 so the continue path is unchanged; the RPL0->panic arms are
#       white-box-pinned by the exact prefix (unreachable on this artifact -- the pure-conduit body can't fault).]
#       The compiled body (PURE CONDUIT module_byte() echoes [answer]) emits
#       DE<answer>AD -> the kernel computed f(kill/fault-kind) AFTER revoking/surviving the module.
# Selected by "-- emit: multiboot32-geeking". Graded on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs) vs
# the silicon-proven reference (geeking_ref.py), proven byte-identical on QEMU + Bochs + KVM real silicon.
#
# THE MAKE-OR-BREAK: a runaway module that NEVER syscalls and NEVER faults (EB FE) hangs the machine forever
# TODAY; geeking revokes the CPU from it via a CPU-authored ASYNC interrupt frame a CPL0-only/synchronous
# kernel cannot author, and CONTINUES. The gate proves this with:
#  (1) EXACT 24564-byte prefix byte-pin + EXACT 58-byte epilogue vs the silicon+KVM-proven reference. This is
#      the MASTER structural gate: the prefix CONTAINS the whole watchdog (PIC remap, one-shot PIT, the drain,
#      the seeded IF=1 EFLAGS image, the RPL-keyed vec-0x20 handler incl. the jne-to-tick_kill displacement,
#      the kill path, the generalized RPL-keyed panic), so pinning every prefix byte pins ALL of it BY VALUE
#      -- stronger than any regex (a retargeted branch changes a displacement byte -> mismatch; the talkert
#      reachability lesson is satisfied structurally). Any watchdog mutation -> prefix RED.
#  (2) DISASM BODY SCAN (link30's M1): the body decodes to ZERO in/out/ins/outs/int/iret/syscall/call by
#      mnemonic (pure conduit; the only I/O + all traps live in the byte-pinned prefix).
#  (3) THE ASYNC KILL by value (gradevictim): kill-frame eip==mod_start (EB FE self-jump boundary),
#      cs==UCODE3 RPL3, useresp==alloc_hi, eflags RF-masked==0x202 (IF=1), answer=='K', and NO SYS_EXIT
#      (a spinner cannot syscall). READ-THEN-HANG proves the watchdog is RE-ARMED after a syscall.
#  (4) FAULT->CONTINUE by value (gradefaultcont/gradegeneric): #GP/#PF witness frames pinned BY VALUE
#      (carried nokta: errcode 7/5/7, CR2) + answer=='G'/'P' + no breach; the generalized #DB/#DE/#UD ->
#      E2<eip><cs>E3 frame cs==UCODE3 + answer=='F'. Without the generalization a 3-byte module halts the box.
#  (5) THE TWO-BYTE DIFFERENTIAL (the SOLE defense vs a dead/const-baking module, carried from sitopia): the
#      benign echo/inc/xor fed X!=Y -> T(X)!=T(Y), sha-pinned byte-identical across the X and Y runs.
#  (6) BENIGN-LEG ROBUSTNESS (link30) + THE SAME-INPUT REPLAY DISCRIMINATOR (parley; tranche 1a
#      2026-07-17, audits/discriminator-sweep-2026-07-17/CHARTER.md): feeder LISTENING + SENT +
#      exit-code bind on EVERY QEMU leg via the shared tri-state attempt API (replay_discriminator.sh)
#      -- a COMPLETED boot grading RED gets ONE same-input replay (constant inputs + the byte-pinned
#      kernel re-pose the exact question): recurrence -> hard RED with both signatures; non-recurrence
#      -> GREEN + a hedged FLAKE-DISCRIMINATED marker. No-completion re-rolls boundedly and FAILS
#      CLOSED on exhaustion; an UNADJUDICATED completed RED fails closed regardless of REQUIRE_EMU.
#
# HONEST SCOPE / RESIDUE (audited-assertion, named): CANONICAL-CODEGEN for the fixed probes; KILL-ONLY (a tick
# at CPL3 is terminal -- no resume, no run queue, no second task, no quantum accounting beyond the per-entry
# one-shot). The watchdog bounds CONTINUOUS CPL3 RESIDENCE PER ENTRY, NOT total CPU / progress / fairness /
# liveness: a pure CPL3 runaway (the EB FE victim) is killed within one ~55ms window, but a syscall-yielding
# read-spammer (int 0x30; jmp $) with a continuous input stream re-arms the one-shot each cycle and is killed
# only when starved of input (-> CPL0 hang) or when it faults -- it yields CPL3 frequently but makes no
# progress and never exits (fairness/liveness is a later scheduler concern, not this terminate beat). The
# 55ms one-shot deadline assumes benign CPL3 bursts << 55ms (here us); emulator/KVM-graded (CI
# versions pinned). QEMU-TCG sets a cosmetic RF (0x10000) in the captured preempted eflags (masked; the
# load-bearing IF bit is pinned on all 3 substrates). Witness frames embed loader-chosen addresses ->
# cross-substrate identity is SEMANTIC (host-recomputed), per-substrate byte-identical -- sitopia's status.
# D20 NOT widened (still one page). The held-back MUTATION proof (run_native_codegen_link37_mutation.sh) proves
# each design choice non-vacuous (M-naive/M-nodrain SILICON-kill-benign, M-ifzero/M-nokill victim-not-killed,
# M-panicshutdown #DB-halts, M-shutdowngp/pf fault-not-named, M-constbl differential, M-bodyio disasm-scan).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/geeking_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L21_BOCHS_PROBES:-geek_echo}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing geeking_ref.py $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"
source "$script_dir/replay_discriminator.sh" || { echo "FAIL: stack/native_compile_fragment.herb (missing replay_discriminator.sh)"; exit 1; }

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
# geeking NEW: the runaway victim (EB FE -> async timer kill), the read-then-hang victim (one round trip then
# spin -> proves the watchdog re-arms after a syscall), and the GENERALIZED-fault probes TF/#DB, DIV0/#DE,
# BADOP/#UD (a CPL3 CPU exception with NO dedicated handler -> named 'F' + continue; the Codex-gift completion).
MODVICT="$work/mod_vict.bin"; MODRTHV="$work/mod_rthv.bin"
MODTF="$work/mod_tf.bin"; MODDIV0="$work/mod_div0.bin"; MODBADOP="$work/mod_badop.bin"
python3 "$REF" module echo "$MODECHO"; python3 "$REF" module inc "$MODINC"; python3 "$REF" module xor "$MODXOR"
python3 "$REF" module HOIN "$MODHIN"; python3 "$REF" module HOST "$MODH"
python3 "$REF" module HOSW "$MODW"; python3 "$REF" module HOSR "$MODR"; python3 "$REF" module HOSPT "$MODPT"
python3 "$REF" module VICTIM "$MODVICT"; python3 "$REF" module RTHV "$MODRTHV"
python3 "$REF" module TF "$MODTF"; python3 "$REF" module DIV0 "$MODDIV0"; python3 "$REF" module BADOP "$MODBADOP"
# artifact guard (2026-07-17, tranche 1a): a missing/empty module bin must fail HERE, loudly. Under the
# replay driver a failed QEMU -initrd launch is classed a setup failure, so an unchecked generation
# defect would otherwise surface as a re-rolled harness error instead of naming the broken artifact.
for _mb in "$MODECHO" "$MODINC" "$MODXOR" "$MODHIN" "$MODH" "$MODW" "$MODR" "$MODPT" "$MODVICT" "$MODRTHV" "$MODTF" "$MODDIV0" "$MODBADOP"; do
    [[ -s "$_mb" ]] || { echo "FAIL: stack/native_compile_fragment.herb (geeking_ref module generation produced no/empty $_mb)"; exit 1; }
done
declare -A MODF=([echo]="$MODECHO" [inc]="$MODINC" [xor]="$MODXOR")
PTADDR="$(python3 "$REF" ptaddr)"
PREFIX_LEN=24564
# two distinct fed bytes, neither a likely baked literal (0x00/0xFF/0x5A/0xA7/ASCII), with injective T so
# T(X) != T(Y) for every probe -> a const-baking dead module fails at least one (here both).
FX=60   # 0x3C
FY=197  # 0xC5

prog_src() {
    case "$1" in
      geek_echo)  echo 'func main(): return module_byte() end' ;;          # pure conduit, no locals
      geek_local) echo 'func main(): let x = module_byte()  return x end' ;; # pure conduit via a local (rbp frame)
    esac
}
ALL_PROBES="geek_echo geek_local"
host_T() { python3 -c "v=$2
print({'echo':v,'inc':(v+7)&0xFF,'xor':v^0x5A}['$1'])"; }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-geeking\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
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

# QEMU benign round-trip with the late-bound socket COM1 feeder + exit-code bind (link30 robustness),
# run through the shared same-input replay driver (replay_discriminator.sh -- see header bullet 6).
attempt_benign() { # kelf kind fedbyte out  (tri-state: sets ATT/ATT_SIG/ATT_HERR/ATT_CTX, never fail_tests)
    local kelf="$1" kind="$2" byte="$3" out="$4"
    replay_capture_ctx "$kelf" "${MODF[$kind]}" || return 0   # validated PRE-LAUNCH (TOCTOU + empty-hash guard, Codex)
    local f ex; f=$(host_T "$kind" "$byte"); ex=$(host_qemu_exit "$f")
    local W="$out.d"; mkdir -p "$W"; local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    if ! grep -q LISTENING "$W/feed.log" 2>/dev/null; then
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        ATT=SETUP_FAILURE; ATT_HERR="feeder never reached LISTENING (socket-bind failure; QEMU not launched)"; return 0
    fi
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "${MODF[$kind]}" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
    local rc=$?; wait "$fp" 2>/dev/null
    qemu_classify "$rc" "$out" "$out.qerr" "$W/feed.log" || return 0
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    local g grc; g="$(python3 "$REF" grade "$out" "$kend" "$(printf '%x' "$byte")" "$kind" 2>&1)"; grc=$?
    if [[ "$grc" -eq 0 && "$rc" -eq "$ex" ]]; then ATT=COMPLETED_GREEN; return 0; fi
    ATT=COMPLETED_RED
    ATT_SIG="rc=$rc want=$ex(T=$f) grade=$([[ "$grc" -eq 0 ]] && echo GREEN || echo "RED: $(echo "$g" | tr '\n' ' ')")"
    return 0
}
qemu_benign() { # label kelf kind fedbyte -> 0 iff adjudicated GREEN (rc bound + grade, replay-discriminated)
    local label="$1" kelf="$2" kind="$3" byte="$4"
    run_qemu_leg "$label $kind byte=$byte" "$work/$label.$kind.$byte" attempt_benign "$kelf" "$kind" "$byte"
}

# geeking: a hostile probe now FAULTS *and the kernel CONTINUES* (fault->continue). So the grader is
# gradefaultcont: the #GP/#PF witness frame BY VALUE (carried nokta pins) AND answer=='G'/'P' (DE47AD/DE50AD)
# AND no SYS_EXIT breach. (sitopia graded these as "module never SYS_EXITs"; under geeking the kernel survives
# the fault and names it -- a STRICTLY STRONGER positive assertion.)
attempt_hostile() { # kelf mod faultkind cr2 out   (rc now CAPTURED and bound -- the ||-true discard is gone)
    local kelf="$1" mod="$2" kind="$3" cr2="$4" out="$5"
    replay_capture_ctx "$kelf" "$mod" || return 0   # validated PRE-LAUNCH (TOCTOU + empty-hash guard, Codex)
    local ans; case "$kind" in hostile|hostin) ans=71 ;; *) ans=80 ;; esac   # 'G'->237 / 'P'->195, empirically re-pinned 2026-07-17
    local ex; ex=$(host_qemu_exit "$ans")
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -monitor none -m 64M >/dev/null 2>"$out.qerr"
    local rc=$?
    qemu_classify "$rc" "$out" "$out.qerr" "" || return 0
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    local g grc; g="$(python3 "$REF" gradefaultcont "$out" "$kend" "$kind" $cr2 2>&1)"; grc=$?
    if [[ "$grc" -eq 0 && "$rc" -eq "$ex" ]]; then ATT=COMPLETED_GREEN; return 0; fi
    ATT=COMPLETED_RED
    ATT_SIG="rc=$rc want=$ex grade=$([[ "$grc" -eq 0 ]] && echo GREEN || echo "RED: $(echo "$g" | tr '\n' ' ')")"
    return 0
}
qemu_hostile() { # label kelf modfile faultkind [cr2]   (faultkind: hostile|hostin|pfault|pfault_read|pfault_pt)
    local label="$1" kelf="$2" mod="$3" kind="$4" cr2="${5:-}"
    run_qemu_leg "$label fault-continue $kind" "$work/$label.$kind" attempt_hostile "$kelf" "$mod" "$kind" "$cr2"
}

# geeking: the runaway VICTIM (EB FE) -- the async one-shot timer must fire AT CPL3 and KILL it (the first
# CPU-authored async ring-cross frame). No feeder (the spinner never syscalls). gradevictim pins the kill
# frame BY VALUE (eip==mod_start, cs==UCODE3, useresp==alloc_hi, eflags RF-masked==0x202, answer=='K').
attempt_victim() { # kelf out
    local kelf="$1" out="$2"
    replay_capture_ctx "$kelf" "$MODVICT" || return 0   # validated PRE-LAUNCH (TOCTOU + empty-hash guard, Codex)
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$MODVICT" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -serial null -monitor none -m 64M >/dev/null 2>"$out.qerr"
    local rc=$?
    qemu_classify "$rc" "$out" "$out.qerr" "" || return 0
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    local g grc; g="$(python3 "$REF" gradevictim "$out" "$kend" 2>&1)"; grc=$?
    if [[ "$grc" -eq 0 && "$rc" -eq 245 ]]; then ATT=COMPLETED_GREEN; return 0; fi   # 245 = host_qemu_exit('K')
    ATT=COMPLETED_RED
    ATT_SIG="rc=$rc want=245 grade=$([[ "$grc" -eq 0 ]] && echo GREEN || echo "RED: $(echo "$g" | tr '\n' ' ')")"
    return 0
}
qemu_victim() { # label kelf
    local label="$1" kelf="$2"
    run_qemu_leg "$label victim" "$work/$label.victim" attempt_victim "$kelf"
}

# geeking: READ-THEN-HANG -- the module does ONE round-trip SYS_READ (needs the feeder) then spins; proves the
# watchdog is RE-ARMED by do_read's drain_then_rearm() and bites AFTER a syscall, not just on initial entry.
attempt_readhang() { # kelf fedbyte out
    local kelf="$1" byte="$2" out="$3"
    replay_capture_ctx "$kelf" "$MODRTHV" || return 0   # validated PRE-LAUNCH (TOCTOU + empty-hash guard, Codex)
    local W="$out.d"; mkdir -p "$W"; local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$W/feed.log" && break; sleep 0.1; done
    if ! grep -q LISTENING "$W/feed.log" 2>/dev/null; then
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        ATT=SETUP_FAILURE; ATT_HERR="feeder never reached LISTENING (socket-bind failure; QEMU not launched)"; return 0
    fi
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$MODRTHV" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>"$out.qerr"
    local rc=$?; wait "$fp" 2>/dev/null
    qemu_classify "$rc" "$out" "$out.qerr" "$W/feed.log" || return 0
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    local g grc; g="$(python3 "$REF" gradereadhang "$out" "$kend" "$(printf '%x' "$byte")" 2>&1)"; grc=$?
    if [[ "$grc" -eq 0 && "$rc" -eq 245 ]]; then ATT=COMPLETED_GREEN; return 0; fi   # ends watchdog-killed -> 'K' -> 245
    ATT=COMPLETED_RED
    ATT_SIG="rc=$rc want=245 grade=$([[ "$grc" -eq 0 ]] && echo GREEN || echo "RED: $(echo "$g" | tr '\n' ' ')")"
    return 0
}
qemu_readhang() { # label kelf fedbyte
    local label="$1" kelf="$2" byte="$3"
    run_qemu_leg "$label readhang byte=$byte" "$work/$label.rthv.$byte" attempt_readhang "$kelf" "$byte"
}

# geeking GENERALIZED fault->continue (Codex gift): a CPL3 CPU exception with NO dedicated handler
# (#DB via TF, #DE div0, #UD bad opcode) -> named 'F'(0x46) + continue. gradegeneric pins the E2/E3 frame
# cs==UCODE3 + answer==0x46. Without this generalization a 3-byte module halts the machine.
attempt_generic() { # kelf modfile out
    local kelf="$1" mod="$2" out="$3"
    replay_capture_ctx "$kelf" "$mod" || return 0   # validated PRE-LAUNCH (TOCTOU + empty-hash guard, Codex)
    timeout 60 qemu-system-x86_64 -kernel "$kelf" -initrd "$mod" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 -serial null -monitor none -m 64M >/dev/null 2>"$out.qerr"
    local rc=$?
    qemu_classify "$rc" "$out" "$out.qerr" "" || return 0
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    local g grc; g="$(python3 "$REF" gradegeneric "$out" "$kend" 2>&1)"; grc=$?
    if [[ "$grc" -eq 0 && "$rc" -eq 239 ]]; then ATT=COMPLETED_GREEN; return 0; fi   # 239 = host_qemu_exit('F')
    ATT=COMPLETED_RED
    ATT_SIG="rc=$rc want=239 grade=$([[ "$grc" -eq 0 ]] && echo GREEN || echo "RED: $(echo "$g" | tr '\n' ' ')")"
    return 0
}
qemu_generic() { # label kelf modfile probe
    local label="$1" kelf="$2" mod="$3" probe="$4"
    run_qemu_leg "$label generic-fault $probe" "$work/$label.gf.$probe" attempt_generic "$kelf" "$mod"
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
                rb'\xf0.{4}.{4}.{4}.{4}\xf1', rb'\xd0.{4}.{4}.{4}.{4}.{4}\xd1',
                rb'\xca.{4}.{4}.{4}.{4}\xcb', rb'\xe2.{4}.{4}\xe3'):
        m=None
        for mm in re.finditer(pat, d[i:], re.S): m=mm
        if m: end=max(end, i+m.end())
    open(sys.argv[2],'wb').write(d[i:end] if end>i else b'')
else: open(sys.argv[2],'wb').write(b'')
PY
    local sd; sd=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null); sd="${sd:-0}"   # no ||-echo: grep -c already prints 0 on no-match (the old `|| echo 0` emitted "0\n0", non-numeric in [[ -ge ]])
    local kend; kend=$(printf '%x' "$(elf_meta "$2")")
    if python3 "$REF" grade "$W/e9.bin" "$kend" "$(printf '%x' "$byte")" "$kind" >/dev/null 2>&1 && [[ "$sd" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs $kind byte=$byte (shutdown=$sd): $(python3 "$REF" grade "$W/e9.bin" "$kend" "$(printf '%x' "$byte")" "$kind" 2>&1 | tr '\n' ' ')"; return 1
}

# geeking: shared Bochs boot for a NON-reading module (victim / generalized-fault). A dummy feeder must still
# LISTEN (com1 is socket-client -> Bochs blocks on connect), but the module never reads it (no SENT check).
# Boots GRUB+module under Bochs, extracts the debugcon stream (incl. the CA/CB kill + E2/E3 generic frames),
# returns the e9 path + shutdown count via globals BX_E9 / BX_SD.
bochs_boot_noread() { # label kelf modfile
    local label="$1" kelf; kelf="$(readlink -f "$2")"; local mod; mod="$(readlink -f "$3")"
    local W="$work/$label.bx.$(basename "$3")"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS missing"; return 1; fi
    local port; port=$(free_port)
    python3 "$feeder" "$port" 60 --hold 25 > "$W/feed.log" 2>&1 & local fp=$!
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
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    python3 - "$W/bochs_out.txt" "$W/e9.bin" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    for pat in (rb'\xde.\xad', rb'\xc0.{1}.{4}.{4}.{4}\xc1', rb'\xe0.{1}.{4}.{4}.{4}\xe1',
                rb'\xf0.{4}.{4}.{4}.{4}\xf1', rb'\xd0.{4}.{4}.{4}.{4}.{4}\xd1',
                rb'\xca.{4}.{4}.{4}.{4}\xcb', rb'\xe2.{4}.{4}\xe3'):
        m=None
        for mm in re.finditer(pat, d[i:], re.S): m=mm
        if m: end=max(end, i+m.end())
    open(sys.argv[2],'wb').write(d[i:end] if end>i else b'')
else: open(sys.argv[2],'wb').write(b'')
PY
    BX_E9="$W/e9.bin"
    BX_SD=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null); BX_SD="${BX_SD:-0}"   # no ||-echo: grep -c already prints 0 on no-match (the old `|| echo 0` emitted "0\n0", non-numeric in [[ -ge ]])
    return 0
}

# geeking: the async KILL on the 2nd substrate (the link's signature -- a CPU-authored async ring-cross frame
# from CPL3 must reproduce on Bochs, not just QEMU/KVM).
bochs_victim() { # label kelf
    local label="$1" kelf="$2"
    bochs_boot_noread "$label" "$kelf" "$MODVICT" || return 1
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    if python3 "$REF" gradevictim "$BX_E9" "$kend" >/dev/null 2>&1 && [[ "$BX_SD" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs victim (shutdown=$BX_SD): $(python3 "$REF" gradevictim "$BX_E9" "$kend" 2>&1 | tr '\n' ' ')"; return 1
}

# geeking: the generalized fault->continue on the 2nd substrate (the #DB single-step path -- the one with
# genuine cross-substrate risk; Bochs is instruction-counted, QEMU/KVM wall-clock).
bochs_generic() { # label kelf modfile probe
    local label="$1" kelf="$2" mod="$3" probe="$4"
    bochs_boot_noread "$label" "$kelf" "$mod" || return 1
    local kend; kend=$(printf '%x' "$(elf_meta "$kelf")")
    if python3 "$REF" gradegeneric "$BX_E9" "$kend" >/dev/null 2>&1 && [[ "$BX_SD" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs generic-fault $probe (shutdown=$BX_SD): $(python3 "$REF" gradegeneric "$BX_E9" "$kend" 2>&1 | tr '\n' ' ')"; return 1
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
    echo "SKIP: native-codegen link37 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
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
    if [[ "$label" == "geek_echo" ]]; then
        # FULL round-trip battery on the no-locals conduit: 3 transform modules x {X,Y} (the differential)
        # + the make-or-break hostin + nokta's carried sandbox.
        for kind in echo inc xor; do
            qemu_benign "$label" "$elf" "$kind" "$FX" || ok=0
            qemu_benign "$label" "$elf" "$kind" "$FY" || ok=0
        done
        # geeking: the carried hostile battery now FAULTS *and the kernel CONTINUES* (fault->continue grading).
        qemu_hostile "$label" "$elf" "$MODHIN" hostin      || ok=0   # MAKE-OR-BREAK: module can't read the device itself (#GP + continue)
        qemu_hostile "$label" "$elf" "$MODH"   hostile     || ok=0   # hostile out -> #GP + continue (answer 'G')
        qemu_hostile "$label" "$elf" "$MODW"   pfault      || ok=0   # nokta: hostile write -> #PF7 + continue (answer 'P')
        qemu_hostile "$label" "$elf" "$MODR"   pfault_read || ok=0   # nokta: hostile read  -> #PF5 + continue
        qemu_hostile "$label" "$elf" "$MODPT"  pfault_pt "0x$PTADDR" || ok=0  # nokta: hostile PT-write -> #PF7 + continue
        # geeking NEW -- THE LINK'S MAKE-OR-BREAK: the kernel OUTLIVES its module.
        qemu_victim   "$label" "$elf"                || ok=0   # runaway EB FE -> async one-shot timer KILL at CPL3 (the first async ring-cross frame)
        qemu_readhang "$label" "$elf" "$FX"          || ok=0   # one round trip then spin -> the RE-ARMED watchdog bites after a syscall
        qemu_generic  "$label" "$elf" "$MODTF"    tf    || ok=0   # #DB via popfd-TF  -> generalized fault->continue (answer 'F')
        qemu_generic  "$label" "$elf" "$MODDIV0"  div0  || ok=0   # #DE div0          -> generalized fault->continue
        qemu_generic  "$label" "$elf" "$MODBADOP" badop || ok=0   # #UD bad opcode    -> generalized fault->continue
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
            # dual-substrate (merged GRUB-module + com1 socket-client): the differential + the async KILL +
            # a generalized fault (the #DB single-step path, the cross-substrate-risk one).
            bochs_benign "$label" "$elf" echo "$FX" || ok=0
            bochs_benign "$label" "$elf" echo "$FY" || ok=0
            bochs_victim "$label" "$elf"            || ok=0
            bochs_generic "$label" "$elf" "$MODTF" tf || ok=0
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
reject_probe call          '-- emit: multiboot32-geeking'  'func h(): return 2 end\nfunc main(): return h() + module_byte() end'
reject_probe call_twin     '-- emit: multiboot32-geeking'  'func g(): return 4 end\nfunc main(): return g() + module_byte() end'
reject_probe branch        '-- emit: multiboot32-geeking'  'func main(): let x = module_byte()  if x == 5: return 1 else: return 2 end end'
reject_probe branch_twin   '-- emit: multiboot32-geeking'  'func main(): let y = module_byte()  if y == 9: return 3 else: return 4 end end'
reject_probe nomodule      '-- emit: multiboot32-geeking'  'func main(): return 7 end'
reject_probe nomodule_twin '-- emit: multiboot32-geeking'  'func main(): return 9 end'
reject_probe twomodule     '-- emit: multiboot32-geeking'  'func main(): return module_byte() + module_byte() end'
reject_probe twomodule_twin '-- emit: multiboot32-geeking' 'func main(): return module_byte() * module_byte() end'
reject_probe mainarg       '-- emit: multiboot32-geeking'  'func main(p): return p + module_byte() end'
reject_probe mainarg_twin  '-- emit: multiboot32-geeking'  'func main(k): return k - module_byte() end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 10))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link37 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link37 / geeking / twenty-first kernel-arc link: THE KERNEL OUTLIVES ITS MODULE -- on sitopia's resumable-syscall sandbox, the kernel now (i) ASYNC-KILLS a runaway module: with IF=1 at CPL3, a one-shot PIT + stale-IRR drain + RPL-keyed vec-0x20 handler fires the first CPU-authored ASYNC ring-cross frame and revokes the CPU from an EB FE spinner (kill-witness eip==mod_start, cs==UCODE3, useresp==alloc_hi, eflags RF-masked==0x202, answer 'K'), then CONTINUES to emit f(kill); and (ii) FAULT->CONTINUEs: #GP/#PF (hostile out/write/read/pt) and the generalized panic path for any other CPL3 exception (#DB via TF, #DE div0, #UD bad opcode) name the fault ('G'/'P'/'F') and the kernel survives instead of shutdown -- a genuine RPL0 kernel fault still panics. $pass checks: static MB+PAGE_ALIGN+MEMINFO, ELF-P12, white-box EXACT-${PREFIX_LEN}-byte-prefix (which BY VALUE pins the whole watchdog -- PIC/PIT/drain/vec-0x20 RPL-key/kill-path/seeded-IF/generalized-panic) + EXACT-58-byte-epilogue + DISASM body-scan (zero I/O, pure conduit) vs the silicon+KVM-proven geeking_ref, QEMU substrate (echo/inc/xor each fed X!=Y -> T(X)!=T(Y) per-syscall by-value witness frames + exit-code bind; runaway-KILL + read-then-hang re-arm + #DB/#DE/#UD generalized continue + hostile out/write/read/pt fault-continue; locals-conduit round-trip), Bochs substrate (merged GRUB module + com1 socket-client: the differential + the async KILL + the #DB generalized fault + clean shutdown), 10 rejects with twins; graded vs the host witness-frame oracle on the dual-substrate oracle -- a CANONICAL-CODEGEN proof for the fixed probes. Held-back mutation proof: run_native_codegen_link37_mutation.sh)"
exit 0
