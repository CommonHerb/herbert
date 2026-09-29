#!/usr/bin/env bash
# Mutation proof for native-codegen link 62 (taproot). Every row forges a break and grades it with the
# GATE'S OWN CODE, lifted out of run_native_codegen_link62.sh at run time by fixed-string anchors, so
# disabling one of the gate's decisive comparisons turns this proof RED. Until 2026-09-29 this file
# graded a hand copy of the gate's white-box, which had already drifted from it (the copy accepted a
# stack top moved off its 2-MiB boundary; G1-07), and redid the golden and QEMU comparisons itself, so
# it stayed GREEN with all six of the gate's decisive comparisons disabled (G1-01; C33 D1/D1b).
#
# LIFTED FROM THE GATE AND EXECUTED. Each lift fails this proof closed, before anything is graded, if
# its anchor is missing or not unique, or if the lifted text lacks what the rows rely on:
#   the white-box Python heredoc and the gate's whitebox() wrapper around it; host_proof and
#   host_qemu_exit; prog_v; qemu_run; have_bochs and bochs_run; guard_faults (shallow twin + deep leg);
#   the inline full-image golden-hash block of the probe loop.
# Each lifted FUNCTION must also be defined exactly once in the gate's text, counting the bash spellings
# the uniqueness check below lists (`name ()`, `function name`, indented, ...), so a second definition
# that would replace the lifted one at gate run time fails this proof closed; a control first shows the
# count sees each of those spellings.
# ROWS. Each forge must be REFUSED by the lifted gate code, and each piece has a control: the same gate
# code must ACCEPT the unforged input, so a RED is attributable to the forge, not to a broken grader.
#   white-box (base p1 must pass `guard`, `backward_e9` and `callwhitelist`):
#     M-noguard   guard PDE made present (identity 2 MiB)                  -> `guard` refuses
#     M-espskew   `mov esp` immediate moved 4 KiB off its 2-MiB boundary; the guard index is
#                 unchanged, so only the gate's boundary clause can refuse it (G1-07's forge) -> `guard` refuses
#     M-fwdcall   the backward tail-E9 rel32 zeroed                        -> `backward_e9` refuses
#     M-norecl    `lea rsp,[rbp+8]` in the reclamation window NOPed        -> `backward_e9` refuses
#     M-farcall   0x9A over the first unmasked push rax                    -> `callwhitelist` refuses
#     M-maskhole  0x9A at gt+10, the real instruction boundary the old masked-byte scan missed
#                 (GATE-TEETH B2)                                          -> `callwhitelist` refuses
#     The two 0x9A rows must be refused AT THE FORGED OFFSET. 0x9A is invalid in 64-bit mode, so the
#     decoder reports it `(bad)` and the gate says "undecodable instruction at <offset>"; its
#     "far-call opcode 0x9A at <offset>" branch is also accepted, but no forge here reaches it.
#   M-golden    one byte perturbed -> the golden block refuses it (the base must match the committed p1 golden)
#   M-value     the first movabs imm64 perturbed, so the proof byte changes. The proof's OWN boots come
#               first, as the harness-health control: the base must boot cleanly to exactly de01ad/exit 97,
#               and the forge must boot to exactly one well-formed divergent frame with its coherent exit
#               code, so a dead or timed-out QEMU is never scored as a bite. Then the gate's qemu_run must
#               accept the base and refuse the forge on that same divergent frame, and, where Bochs runs,
#               the gate's bochs_run must accept the base and refuse the forge after a completed boot
#               (shutdown seen, the divergent frame in its capture).
#   M-twin      a compiler wrapper rewrites the twin's `return nt(4) end` to nt(3)  -> guard_faults' twin leg refuses
#   M-deep      a compiler wrapper rewrites `return nt(1000000) end` to nt(4)       -> guard_faults' deep leg refuses
#               (control: guard_faults with the real compiler passes both legs; each wrapper must report
#               exactly one rewrite, and each refusal must carry the completed forged boot's witness)
# NOT GUARDED BY THIS FILE (no row reaches them): static_ok; the `backward_e8` (p2) and `noguard`
# (single-function) white-box modes; the distinctness panel; the reject probes; the KVM invocation of
# qemu_run (same comparison line, never booted here); and the gate's main loop that calls these pieces
# (which probes it compiles, which legs it calls, and how it counts their results). The text checks
# also cannot see a definition made at run time (eval of a built string, a sourced file), a gate
# definition of anything else the lifted code calls (a command such as python3 or cmp, or an oracle
# helper such as kernel_xvfb_capture), or a reassigned WB or second write to it in another spelling:
# each would change what the gate runs without changing the text lifted here.
# Bochs rows need the gate's own have_bochs; without it they are skipped, or fail closed under
# KERNEL_CODEGEN_REQUIRE_EMU=1, as in the gate.
set -u

unset CDPATH
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)" || exit 1
repo_root="$(cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
gate="$script_dir/run_native_codegen_link62.sh"
goldens_dir="$script_dir/taproot_goldens"   # the gate's own value (gate :56); the lifted golden block reads it
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
source "$script_dir/native_codegen_oracle.sh" || { echo "FAIL: cannot source native-codegen oracle" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'kernel_test_cleanup "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: link62-mutation ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then echo "NOTE: no QEMU; link62-mutation skipped locally (authoritative in CI)."; [[ "$REQUIRE_EMU" == "1" ]] && { echo "FAIL: REQUIRE_EMU=1 but no QEMU"; exit 1; }; exit 0; fi
[[ -f "$gate" ]] || { echo "FAIL: link62-mutation (the gate $gate is missing)"; exit 1; }

# ---------------------------------------------------------------- lift the gate's own code
# The extractor, count_lines, assert_unique and lift are run_native_codegen_link66_mutation.sh's, copied:
# fixed-string anchors only (eq:/sw:/ew:), no awk and no regex, because an awk regex with `\$` read
# differently by mawk and gawk once made an extraction come back empty on CI (FLAKE-LOG F10).
cat > "$tmp/extract.py" <<'EXEOF'
import sys
# spec syntax, deliberately regex-free:  eq:TEXT | sw:TEXT | ew:TEXT
def match(line, spec):
    kind, text = spec.split(":", 1)
    line = line.rstrip("\n")
    if kind == "eq": return line == text
    if kind == "sw": return line.startswith(text)
    if kind == "ew": return line.endswith(text)
    raise SystemExit("extract.py: unknown spec kind %r" % kind)
mode, src, out, start_spec, end_spec = sys.argv[1:6]
lines = open(src).read().splitlines(True)
hits = [i for i, l in enumerate(lines) if match(l, start_spec)]
if len(hits) != 1:
    print("opener %r matched %d times, want 1" % (start_spec, len(hits))); raise SystemExit(2)
i = hits[0]
if mode == "between":        # exclusive of BOTH bounds
    body_start = i + 1
elif mode in ("through", "until"):   # inclusive of the opener
    body_start = i
else:
    raise SystemExit("extract.py: unknown mode %r" % mode)
body, j = [], body_start
while j < len(lines):
    if match(lines[j], end_spec):
        if mode == "through": body.append(lines[j])
        break
    body.append(lines[j]); j += 1
else:
    print("closer %r never matched after the opener" % end_spec); raise SystemExit(3)
if not body:
    print("extraction is empty"); raise SystemExit(4)
open(out, "w").writelines(body)
EXEOF
count_lines() { # spec -> how many lines of the gate the FIXED-STRING spec matches
    python3 -I - "$gate" "$1" <<'CEOF'
import sys
src, spec = sys.argv[1], sys.argv[2]
kind, text = spec.split(":", 1)
n = 0
for line in open(src).read().splitlines():
    if (kind == "eq" and line == text) or (kind == "sw" and line.startswith(text)) \
       or (kind == "ew" and line.endswith(text)) or (kind == "has" and text in line):
        n += 1
print(n)
CEOF
}
assert_unique() { # spec why
    local n; n="$(count_lines "$1")"
    [[ "$n" -eq 1 ]] || { echo "FAIL: link62-mutation (uniqueness: $2 -- spec '$1' matched $n lines, want 1)"; exit 1; }
}
lift() { # mode outfile why start_spec end_spec
    local mode="$1" out="$2" why="$3" ss="$4" es="$5" msg
    msg="$(python3 -I "$tmp/extract.py" "$mode" "$gate" "$out" "$ss" "$es" 2>&1)" \
        || { echo "FAIL: link62-mutation (extract $why: ${msg:-unknown})"; exit 1; }
    [[ -s "$out" ]] || { echo "FAIL: link62-mutation (extract $why: empty)"; exit 1; }
}
lift_check() { # file why fixed-string -> the lifted text must contain it
    grep -qF -- "$3" "$1" || { echo "FAIL: link62-mutation (extract $2: '$3' not in the lifted text)"; exit 1; }
}
# Each lift opener must match exactly one line of the gate. host_qemu_exit rides inside the host_proof
# lift, so its canonical line is asserted too.
for _spec_why in \
    "eq:cat > \"\$WB\" <<'PY'|the white-box heredoc opener" \
    "sw:whitebox() {|whitebox()" \
    "sw:host_proof() {|host_proof" \
    "sw:host_qemu_exit() {|host_qemu_exit" \
    "sw:have_bochs() {|have_bochs" \
    "sw:prog_v() {|prog_v" \
    "sw:qemu_run() {|qemu_run" \
    "sw:bochs_run() {|bochs_run" \
    "sw:guard_faults() {|guard_faults" \
    "eq:    if [[ -f \"\$goldens_dir/\$label.sha256\" ]]; then|the golden block" \
    ; do
    assert_unique "${_spec_why%%|*}" "${_spec_why#*|}"
done
# A unique canonical `name() {` line is not enough: bash also accepts `name ()`, `function name`,
# `function name()`, indented forms and more, and a second definition in any spelling silently replaces
# the lifted one when the gate runs. A gate with `function whitebox { return 0; }` before its run section
# once passed this proof with every white-box row graded by the superseded copy (review R1). So every
# lifted function must be defined exactly once in the gate text, counting every spelling below; with the
# canonical anchor also unique, that one definition is the lifted one. The count is textual: comments
# and heredoc data are scanned too, and a mention spelled like a definition fails this file closed.
lifted_functions=(whitebox host_proof host_qemu_exit have_bochs prog_v qemu_run bochs_run guard_faults)
cat > "$tmp/defs.py" <<'DEFEOF'
import sys
# Regex-free, like extract.py (FLAKE-LOG F10). A definition of NAME is NAME as a whole word followed by
# blanks, "(", blanks and ")", or the whole word `function`, blanks, then NAME. Counted on the text as
# written and again with every backslash-newline removed: bash drops those before it reads a word (a
# name may be split by one), but not in a comment, whose backslash cannot hide the next line. Both
# counts must be exactly 1.
WORD = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
BLANK = " \t"
def skip(text, k):
    while k < len(text) and text[k] in BLANK: k += 1
    return k
def count(text, name):
    n, i = 0, text.find(name)
    while i >= 0:
        j = i + len(name)
        if (i == 0 or text[i - 1] not in WORD) and (j == len(text) or text[j] not in WORD):
            k = skip(text, j)
            paren = text[k:k + 1] == "(" and text[skip(text, k + 1):][:1] == ")"
            k = i
            while k > 0 and text[k - 1] in BLANK: k -= 1
            keyword = k < i and k >= 8 and text[k - 8:k] == "function" and (k == 8 or text[k - 9] not in WORD)
            n += paren or keyword
        i = text.find(name, j)
    return n
def counts(text, name):
    return count(text, name), count(text.replace("\\\n", ""), name)
# Control: each spelling, planted once more for each lifted name, must raise a count; each clean use must not.
PLANTED = ["function NAME { return 0; }",            # review R1's reproducer
           "function NAME() { return 0; }", "function  NAME ( ) { return 0; }", "function\tNAME\n{ return 0; }",
           "NAME () { return 0; }", "NAME( ) { return 0; }", "    NAME() { return 0; }", "\tNAME\t(\t)\t{ return 0; }",
           "true; NAME() { return 0; }", "if true; then NAME() { return 0; }; fi", "{ NAME() { return 0; }; }",
           "NAME()\n{ return 0; }", "NAME() ( exit 0 )", "NAME\\\n() { return 0; }",
           "SPLIT() { return 0; }",               # the name itself split by a backslash-newline
           "# a comment ending in a backslash\\\nNAME() { return 0; }"]   # only the as-written count sees it
CLEAN = ['NAME "$elf" guard && pass=$((pass + 1))', 'out="$(NAME "$2" "$3" 2>&1)"', "NAME_x() { return 0; }",
         "x_NAME() { return 0; }", "my_function NAME"]
mode, src, names = sys.argv[1], sys.argv[2], sys.argv[3:]
if mode not in ("check", "control") or not names: raise SystemExit("defs.py: usage: check|control FILE NAME...")
text = open(src).read()
bad = []
for name in names:
    have = counts(text, name)
    if mode == "check":
        if have != (1, 1):
            bad.append("%s is defined %d times as written and %d with backslash-newlines joined, want 1"
                       % (name, have[0], have[1]))
        continue
    for line in PLANTED + CLEAN:
        planted = line.replace("SPLIT", name[:3] + "\\\n" + name[3:]).replace("NAME", name)
        got = counts(text + "\n" + planted + "\n", name)
        raised = got[0] > have[0] or got[1] > have[1]
        if raised != (line in PLANTED):
            bad.append("%r %s" % (planted, "was not counted as a definition" if line in PLANTED
                                  else "was counted as a definition"))
print("; ".join(bad))
sys.exit(1 if bad else 0)
DEFEOF
_msg="$(python3 -I "$tmp/defs.py" control "$gate" "${lifted_functions[@]}")" \
    || { echo "FAIL: link62-mutation (uniqueness control: ${_msg:-defs.py failed})"; exit 1; }
_msg="$(python3 -I "$tmp/defs.py" check "$gate" "${lifted_functions[@]}")" \
    || { echo "FAIL: link62-mutation (uniqueness: ${_msg:-defs.py failed})"; exit 1; }
WB="$tmp/gate_wb.py"
lift between "$WB"                       "the white-box heredoc"        "eq:cat > \"\$WB\" <<'PY'"  "eq:PY"
lift_check "$WB" "the white-box heredoc" "if mode=='guard':"
lift_check "$WB" "the white-box heredoc" "if mode=='backward_e9':"
lift_check "$WB" "the white-box heredoc" "if mode=='callwhitelist':"
# The gate and this file now run the same white-box, so a fixed scratch path in it would be shared by
# both and by concurrent runs, which then grade each other's bytes (G1-06). It stages its call window
# next to the image under test, inside each run's own mktemp directory; refuse a fixed /tmp path.
if grep -qF "/tmp/" "$WB"; then echo "FAIL: link62-mutation (extract the white-box heredoc: it names a fixed /tmp/ path, which the gate, this file and concurrent runs would share)"; exit 1; fi
# whitebox() by its PREFIX, up to the blank line after it: a whole-line anchor would refuse an edited
# wrapper at extraction, and a neutered wrapper must be lifted and graded, not refused.
lift until   "$tmp/gate_whitebox.sh"     "whitebox()"                   "sw:whitebox() {"          "eq:"
lift until   "$tmp/gate_host.sh"         "host_proof/host_qemu_exit"    "sw:host_proof() {"        "eq:"
lift until   "$tmp/gate_have_bochs.sh"   "have_bochs"                   "sw:have_bochs() {"        "eq:"
lift through "$tmp/gate_prog_v.sh"       "prog_v"                       "sw:prog_v() {"            "eq:}"
lift through "$tmp/gate_qemu_run.sh"     "qemu_run"                     "sw:qemu_run() {"          "eq:}"
lift through "$tmp/gate_bochs_run.sh"    "bochs_run"                    "sw:bochs_run() {"         "eq:}"
lift through "$tmp/gate_guard_faults.sh" "guard_faults"                 "sw:guard_faults() {"      "eq:}"
lift_check "$tmp/gate_guard_faults.sh" "guard_faults" "printf 'func main(): return nt(4) end\n'"
lift_check "$tmp/gate_guard_faults.sh" "guard_faults" "printf 'func main(): return nt(1000000) end\n'"
# The golden block is inline in the probe loop, not a function: it is only ever sourced inside the
# subshell of gate_golden below, never at top level (sourcing it here would execute it).
lift through "$tmp/gate_golden.sh"       "the golden block"             "eq:    if [[ -f \"\$goldens_dir/\$label.sha256\" ]]; then"  "eq:    fi"
lift_check "$tmp/gate_golden.sh" "the golden block" "image != committed golden"
for _f in whitebox host have_bochs prog_v qemu_run bochs_run guard_faults; do
    # shellcheck source=/dev/null
    source "$tmp/gate_$_f.sh" || { echo "FAIL: link62-mutation (cannot source the lifted $_f)"; exit 1; }
done
for _fn in "${lifted_functions[@]}"; do
    declare -F "$_fn" >/dev/null || { echo "FAIL: link62-mutation (the lifted gate code does not define $_fn)"; exit 1; }
done

# The lifted pieces report through the GATE's fail_test and pass. Each runs in a subshell where
# fail_test prints the gate's message and stops, so it cannot move this file's ledger. That also makes
# guard_faults' deep leg observable: in the gate its fail_test is the last command, so the function
# returns 0 with that leg RED.
gate_call() { # fn args... -> the lifted gate function's verdict (0 = accepted)
    ( pass=0; fail_test() { echo "GATE-FAIL: $1"; exit 1; }; "$@" )
}
gate_golden() { # elf -> the gate's golden block on it as probe p1 (0 = accepted)
    ( pass=0; fail_test() { echo "GATE-FAIL: $1"; exit 1; }; label=p1; elf="$1"
      # shellcheck source=/dev/null
      source "$tmp/gate_golden.sh"; [[ "$pass" -eq 1 ]] )
}
gate_guard_faults() { # compiler workdir -> the gate's guard_faults with that compiler (0 = both legs passed)
    mkdir -p "$2" || return 2
    ( tmp="$2"; NATIVE_CODEGEN_COMPILER="$1"; pass=0; fail_test() { echo "GATE-FAIL: $1"; exit 1; }
      guard_faults; [[ "$pass" -eq 2 ]] )
}

# ---------------------------------------------------------------- the base image and the forgers
# emit p1 (a recursive probe) as the mutation base
base="$tmp/p1.elf"; cdir="$tmp/p1.d"; mkdir -p "$cdir"
printf -- '-- emit: multiboot32-long64\nfunc rec(n, acc):\n    if n == 0: return acc end\n    return rec(n - 1, acc + 1073741824)\nend\nfunc main(): return rec(6, 0) end\n' > "$cdir/p.herb"
( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>/dev/null )
[[ -f "$cdir/a.out" ]] || { echo "FAIL: link62-mutation (base p1 did not compile)"; exit 1; }
cp "$cdir/a.out" "$base"

# The forgers are this file's own: they write a forged image to argv[3]. Nothing here grades.
PY="$tmp/forge.py"
cat > "$PY" <<'PYEOF'
import sys,struct
elf=bytearray(open(sys.argv[1],'rb').read()); mode=sys.argv[2]
filesz=struct.unpack('<I',elf[68:72])[0]; code_off=4108; code=elf[code_off:code_off+filesz-12]
code_len=len(code)
RECL=bytes.fromhex('4c895d08488d65084c89d5')   # mov [rbp+8],r11; lea rsp,[rbp+8]; mov rbp,r10
if mode=='mk_noguard':
    pds=code_off+code_len-4096; esp=struct.unpack('<I',code[57:61])[0]; gidx=(esp-0x400000)//0x200000
    struct.pack_into('<Q',elf,pds+gidx*8,gidx*0x200000+0x83)   # make guard PDE present
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_espskew':
    # G1-07's forge: the `mov esp, imm32` stack top (code[57:61]) moved 4 KiB off its 2-MiB boundary.
    # (esp-0x400000)//0x200000 is unchanged, so the guard PDE still sits at the computed index.
    esp=struct.unpack('<I',code[57:61])[0]
    struct.pack_into('<I',elf,code_off+57,esp+0x1000)
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_fwdcall':
    # zero the first backward TAIL-E9 rel32 -> target becomes the next instr (no recursion edge)
    for i in range(len(code)-5):
        if code[i]==0xE9 and i>=len(RECL) and code[i-len(RECL):i]==RECL:
            rel=struct.unpack('<i',code[i+1:i+5])[0]
            if rel<0:
                struct.pack_into('<i',elf,code_off+i+1,0); break
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_norecl':
    # NOP the 4-byte `lea rsp,[rbp+8]` inside the reclamation window before the first backward tail E9
    for i in range(len(code)-5):
        if code[i]==0xE9 and i>=len(RECL) and code[i-len(RECL):i]==RECL:
            rel=struct.unpack('<i',code[i+1:i+5])[0]
            if rel<0:
                lea=code_off+i-7            # window layout: [4C895D08][488D6508][4C89D5] E9
                elf[lea:lea+4]=b'\x90\x90\x90\x90'; break
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_farcall':
    # inject 0x9A as an OPCODE: the first UNMASKED push rax (0x50) inside the scanned region
    # [56, gdt) -- an injection into a masked rel32 payload would be invisible by design. Prints the
    # forged code offset; finding nothing to forge is an error, never an unforged image.
    sig=b'\xff\xff\x00\x00\x00\x9a\xaf\x00'; pos=code.find(sig)
    scan=code[56:pos-8]
    imm=[False]*len(scan)
    for i in range(len(scan)):
        if scan[i] in (0xE8,0xE9) and not imm[i] and i+4<len(scan):
            for j in range(i+1,i+5): imm[j]=True
    for i in range(len(scan)):
        if scan[i]==0x50 and not imm[i]:
            elf[code_off+56+i]=0x9A
            open(sys.argv[3],'wb').write(elf); print(hex(56+i)); sys.exit(0)
    sys.exit(1)
if mode=='mk_maskhole':
    # GATE-TEETH B2: inject 0x9A at gt+10, a REAL instruction boundary (the opcode byte of the fixed
    # epilogue's `mov al,0xde`) that the OLD masked-byte-scan whitelist demonstrably missed: the
    # coincidental 0xE8 inside the grading tail's own `48 C1 E8 20` (shr rax,0x20) falsely masked the
    # next 4 bytes, and the immediate of the following `66 BA E9 00` (mov dx,0xE9) supplied a second
    # coincidental 0xE9 whose false mask window shadowed gt+10. gt is the grading tail, which always
    # immediately follows main's body. Prints the forged code offset.
    gt=code.find(b'\x48\xc1\xe8\x20',56)
    assert gt>=0, "no grading tail"
    assert code[gt+10]==0xB0, (hex(code[gt+10]), "expected the epilogue's mov al,0xde opcode byte")
    elf[code_off+gt+10]=0x9A
    open(sys.argv[3],'wb').write(elf); print(hex(gt+10)); sys.exit(0)
if mode=='verify_maskhole':
    # B2: confirm the forge actually injected 0x9A at gt+10 in the file under test, so a failed/
    # inert forge cannot be misread as a genuine RED by the leg below.
    gt=code.find(b'\x48\xc1\xe8\x20',56)
    sys.exit(0 if (gt>=0 and code[gt+10]==0x9A) else 1)
if mode=='mk_value':
    # perturb the first movabs imm64 operand (change the computed result -> different proof byte)
    idx=code.find(b'\x48\xb8')
    if idx>=0: elf[code_off+idx+2]^=0xFF
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
sys.exit(3)
PYEOF

# ---------------------------------------------------------------- white-box rows (the lifted whitebox)
wb_accept() { # control elf mode -> the gate's white-box must ACCEPT the unforged image
    local out rc; out="$(whitebox "$2" "$3" 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then pass=$((pass + 1))
    else fail_test "$1: the gate's white-box '$3' refuses the UNFORGED base p1 (rc=$rc${out:+: $out}) -- no '$3' RED below is attributable"; fi
}
wb_refuse() { # row elf mode [offset] -> the gate's white-box must REFUSE the forged image (at offset, if given)
    local out rc; out="$(whitebox "$2" "$3" 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        fail_test "$1 (the gate's white-box '$3') did not bite: it passed the forged image"
    elif [[ "$rc" -ne 1 || "$out" == *Traceback* ]]; then
        fail_test "$1: the gate's white-box '$3' errored (rc=$rc${out:+: $out}) instead of refusing the forge"
    elif [[ -n "${4:-}" && "$out" != "undecodable instruction at $4 (decode desync or forged bytes)" \
            && "$out" != "far-call opcode 0x9A at $4" ]]; then
        fail_test "$1: the gate's white-box '$3' refused, but not at the forged offset $4 (it said: ${out:-nothing})"
    else
        echo "$1 bit RED through the gate's white-box '$3'${out:+: $out}"; pass=$((pass + 1))
    fi
}
forge() { # mode outfile -> runs a forger; any failure is this file's own fault, never a bite
    python3 "$PY" "$base" "$1" "$2" || { fail_test "forge $1 failed (rc=$?)"; return 1; }
    [[ -s "$2" ]] || { fail_test "forge $1 wrote no image"; return 1; }
}

wb_accept "control" "$base" guard
wb_accept "control" "$base" backward_e9
wb_accept "control" "$base" callwhitelist
forge mk_noguard "$tmp/m_noguard.elf" && wb_refuse "M-noguard" "$tmp/m_noguard.elf" guard
forge mk_espskew "$tmp/m_espskew.elf" && wb_refuse "M-espskew" "$tmp/m_espskew.elf" guard
forge mk_fwdcall "$tmp/m_fwd.elf"     && wb_refuse "M-fwdcall" "$tmp/m_fwd.elf" backward_e9
forge mk_norecl  "$tmp/m_norecl.elf"  && wb_refuse "M-norecl"  "$tmp/m_norecl.elf" backward_e9
far_off="$(python3 "$PY" "$base" mk_farcall "$tmp/m_far.elf")"; far_rc=$?
if [[ "$far_rc" -ne 0 || ! -s "$tmp/m_far.elf" || -z "$far_off" ]]; then
    fail_test "M-farcall forge found nothing to forge (rc=$far_rc)"
else
    wb_refuse "M-farcall" "$tmp/m_far.elf" callwhitelist "$far_off"
fi
# B2: prove the FORGE itself succeeded and actually injected 0x9A at gt+10 BEFORE interpreting the
# checker's refusal as RED -- a failed/inert forge (missing file, or the 0xB0-boundary assert tripping)
# must not be misread as a genuine bite.
mh_off="$(python3 "$PY" "$base" mk_maskhole "$tmp/m_maskhole.elf")"; forge_rc=$?
if [[ "$forge_rc" -ne 0 || ! -s "$tmp/m_maskhole.elf" || -z "$mh_off" ]]; then
    fail_test "M-maskhole forge did not produce a forged image (rc=$forge_rc)"
elif ! python3 "$PY" "$tmp/m_maskhole.elf" verify_maskhole; then
    fail_test "M-maskhole forge is inert (0x9A not present at gt+10 in the forged image)"
else
    wb_refuse "M-maskhole" "$tmp/m_maskhole.elf" callwhitelist "$mh_off"
fi

# ---------------------------------------------------------------- M-golden (the lifted golden block)
out="$(gate_golden "$base" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass=$((pass + 1))
else fail_test "control: the gate's golden block refuses the freshly emitted base p1 (${out:-rc=$rc}) -- M-golden is not attributable"; fi
cp "$base" "$tmp/m_gold.elf"; printf '\xff' | dd of="$tmp/m_gold.elf" bs=1 seek=5000 count=1 conv=notrunc status=none 2>/dev/null
if cmp -s "$base" "$tmp/m_gold.elf"; then
    fail_test "M-golden forge is inert (the perturbed image equals the base)"
else
    out="$(gate_golden "$tmp/m_gold.elf" 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then fail_test "M-golden (the gate's golden block) did not bite: it passed the perturbed image"
    elif [[ "$out" != *"GATE-FAIL: p1: image != committed golden ("* ]]; then fail_test "M-golden: the gate's golden block refused, but not as a hash mismatch (${out:-rc=$rc})"
    else echo "M-golden bit RED through the gate's golden block: $out"; pass=$((pass + 1)); fi
fi

# ---------------------------------------------------------------- M-value: this file's own boots first
# runtime CONTROL (fail-closed non-vacuity): the UNFORGED base must boot to the golden proof (rc=97 + de01ad)
# through the SAME QEMU path, so the M-value leg is provably live and a dead/timed-out QEMU cannot masquerade
# as the M-value bite (the fail-open bug: there was NO runtime control, so rc=124/empty scored the bite).
timeout 60 qemu-system-x86_64 -kernel "$base" -debugcon file:"$tmp/cv.bin" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M >/dev/null 2>"$tmp/cv.qerr"
crc=$?; c_e9=$(xxd -p "$tmp/cv.bin" 2>/dev/null | tr -d '\n')
c_clean=1; grep -qvE 'terminating on signal' "$tmp/cv.qerr" 2>/dev/null && c_clean=0   # F1/F3: a NON-timeout stderr line = QEMU launch failure (rc is NOT usable: isa-debug-exit yields odd codes to 255)
if [[ "$c_clean" -eq 1 && "$crc" -eq 97 && "$c_e9" == "de01ad" ]]; then echo "runtime control: unforged base cleanly boots to EXACTLY de01ad/exit97 -- the runtime leg is live/non-vacuous"; pass=$((pass + 1));
else fail_test "runtime control: unforged base did NOT cleanly boot to exactly de01ad/exit97 (rc=$crc e9='${c_e9:-EMPTY}' clean=$c_clean) -- HARNESS failure, the M-value leg cannot be trusted"; fi

# M-value: perturb the graded result -> the boot proof byte changes. Assert the POSITIVE forged outcome (the
# boot COMPLETED with a well-formed de..ad frame that DIVERGES from the golden de01ad/exit97), NOT the mere
# absence of de01ad (which a dead/timed-out QEMU would also satisfy -- the fail-open bug).
python3 "$PY" "$base" mk_value "$tmp/m_val.elf"
timeout 60 qemu-system-x86_64 -kernel "$tmp/m_val.elf" -debugcon file:"$tmp/mv.bin" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M >/dev/null 2>"$tmp/mv.qerr"
rc=$?; mv_e9=$(xxd -p "$tmp/mv.bin" 2>/dev/null | tr -d '\n')
mv_clean=1; grep -qvE 'terminating on signal' "$tmp/mv.qerr" 2>/dev/null && mv_clean=0    # F3/F1: a NON-timeout stderr line = QEMU launch failure
# F3: NO bare rc>=124 test -- isa-debug-exit yields odd, result-dependent exit codes up to 255, so rc alone is
# NOT a harness signal (124-vs-legit collides). A genuine M-value bite REQUIRES the e9 stream to be EXACTLY ONE
# well-formed de..ad frame whose byte is NON-golden (!= 01) AND whose isa-debug-exit code matches that byte
# (rc == ((byte^0x31)&0x7f)<<1|1, link62's host_qemu_exit formula) -- a golden frame with an abnormal exit
# (selective emulator death AFTER the frame landed) is a HARNESS failure, NOT the bite; so is a dead/timed-out
# QEMU (no frame) or a launch error (non-timeout stderr).
mv_byte=""; [[ "$mv_e9" =~ ^de([0-9a-f][0-9a-f])ad$ ]] && mv_byte="${BASH_REMATCH[1]}"
mv_ok=0
if [[ "$mv_clean" -eq 0 ]]; then
    fail_test "M-value: HARNESS failure -- QEMU launch error ($(grep -vE 'terminating on signal' "$tmp/mv.qerr" | head -1)); NOT a bite"
elif [[ -z "$mv_byte" ]]; then
    fail_test "M-value: HARNESS failure -- e9 stream is not exactly one well-formed de..ad frame (rc=$rc e9='${mv_e9:-EMPTY}'; dead/partial/timed-out QEMU); NOT a bite"
elif [[ "$mv_byte" == "01" ]]; then
    fail_test "M-value: forged result still graded as the golden byte de01ad (rc=$rc)"
elif [[ "$rc" -ne $(( (((0x$mv_byte ^ 0x31) & 0x7f) << 1) | 1 )) ]]; then
    fail_test "M-value: HARNESS failure -- divergent frame de${mv_byte}ad but exit code $rc mismatches its frame-derived expected $(( (((0x$mv_byte ^ 0x31) & 0x7f) << 1) | 1 )) (emulator died after the frame?); NOT a bite"
else
    pass=$((pass + 1)); mv_ok=1   # EXACTLY ONE non-golden frame + frame-coherent exit code -> genuine materialized divergence
fi

# ---------------------------------------------------------------- M-value through the gate's qemu_run and bochs_run
v_p1="$(prog_v p1)"
out="$(gate_call qemu_run gq.base "$base" "$v_p1" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass=$((pass + 1))
else fail_test "control: the gate's qemu_run refuses the unforged base p1 (${out:-rc=$rc}) -- its M-value RED is not attributable"; fi
if [[ "$mv_ok" -eq 1 ]]; then
    out="$(gate_call qemu_run gq.value "$tmp/m_val.elf" "$v_p1" 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then fail_test "M-value (the gate's qemu_run) did not bite: it passed the forged image"
    elif [[ "$out" != *"GATE-FAIL: gq.value QEMU: "*" e9=de${mv_byte}ad want=de01ad nframes=0"* ]]; then
        fail_test "M-value: the gate's qemu_run refused, but not on the divergent frame de${mv_byte}ad this file's own boot saw (${out:-rc=$rc})"
    else echo "M-value bit RED through the gate's qemu_run: $out"; pass=$((pass + 1)); fi
fi

run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 ]]; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        fail_test "KERNEL_CODEGEN_REQUIRE_EMU=1 but the gate's have_bochs is false: its bochs_run cannot be graded"
    else
        echo "NOTE: Bochs/sudo prerequisites missing (the gate's have_bochs); the bochs_run rows are SKIPPED locally."
    fi
else
    out="$(gate_call bochs_run gb.base "$base" "$v_p1" 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then pass=$((pass + 1))
    else fail_test "control: the gate's bochs_run refuses the unforged base p1 (${out:-rc=$rc}) -- its M-value RED is not attributable"; fi
    if [[ "$mv_ok" -eq 1 ]]; then
        out="$(gate_call bochs_run gb.value "$tmp/m_val.elf" "$v_p1" 2>&1)"; rc=$?
        bframes="$(grep -o "de${mv_byte}ad" "$tmp/gb.value.b/hex.txt" 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$rc" -eq 0 ]]; then fail_test "M-value (the gate's bochs_run) did not bite: it passed the forged image"
        elif [[ ! "$out" =~ "GATE-FAIL: gb.value Bochs: frames(de01ad)=0 shutdown="[1-9] ]]; then
            fail_test "M-value: the gate's bochs_run refused, but not after a completed boot (${out:-rc=$rc})"
        elif [[ "$bframes" -ne 1 ]]; then
            fail_test "M-value: the gate's bochs_run refused a completed boot whose capture holds $bframes de${mv_byte}ad frames, want 1 (${out})"
        else echo "M-value bit RED through the gate's bochs_run (the capture holds de${mv_byte}ad once): $out"; pass=$((pass + 1)); fi
    fi
fi

# ---------------------------------------------------------------- M-twin, M-deep (the lifted guard_faults)
# guard_faults compiles its own twin and deep programs, so an image forge cannot reach it. The forge is a
# compiler wrapper instead: it rewrites one fixed string in the program on stdin, records each rewrite,
# and runs the real compiler on the result. The gate's text runs unchanged.
cat > "$tmp/rewrite.py" <<'RWEOF'
import subprocess, sys
real, old, new, mark = sys.argv[1:5]
src = sys.stdin.buffer.read()
n = src.count(old.encode())
if n:
    with open(mark, 'a') as f: f.write('%d\n' % n)
sys.exit(subprocess.run([real], input=src.replace(old.encode(), new.encode())).returncode)
RWEOF
make_rewriter() { # out old new -> an executable compiler: OLD -> NEW on stdin, then the real compiler
    printf '#!/usr/bin/env bash\nexec python3 -I %q %q %q %q %q\n' "$tmp/rewrite.py" "$NATIVE_CODEGEN_COMPILER" "$2" "$3" "$1.rewrites" > "$1" \
        && chmod +x "$1"
}
guard_row() { # row compiler workdir witness -> the gate's guard_faults must refuse, with this exact witness
    local out rc; out="$(gate_guard_faults "$2" "$3" 2>&1)"; rc=$?
    if [[ "$(cat "$2.rewrites" 2>/dev/null)" != "1" ]]; then
        fail_test "$1 forge is inert: the compiler wrapper did not rewrite exactly one program once (rewrites: '$(tr '\n' ' ' < "$2.rewrites" 2>/dev/null)')"
    elif [[ "$rc" -eq 0 ]]; then
        fail_test "$1 (the gate's guard_faults) did not bite: both of its legs passed the forged program"
    elif [[ "$out" != *"$4"* ]]; then
        fail_test "$1: the gate's guard_faults refused, but not with the completed forged boot's witness '$4' (${out:-rc=$rc})"
    else
        echo "$1 bit RED through the gate's guard_faults: $(grep -F 'GATE-FAIL:' <<< "$out")"; pass=$((pass + 1))
    fi
}
out="$(gate_guard_faults "$NATIVE_CODEGEN_COMPILER" "$tmp/gf.control" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == *"taproot: 1,000,000-deep NON-TAIL recursion overflows the 2-MiB stack"* ]]; then
    echo "control: the gate's guard_faults passes both legs with the real compiler"; pass=$((pass + 1))
else fail_test "control: the gate's guard_faults fails with the real compiler (${out:-rc=$rc}) -- M-twin/M-deep are not attributable"; fi
# nt(3) = 4*2^32 -> proof byte 4 -> frame de04ad, exit ((4^0x31)&0x7f)<<1|1 = 107 (the gate wants nt(4): de05ad/105)
make_rewriter "$tmp/cc.twin" 'return nt(4) end' 'return nt(3) end' || fail_test "M-twin: cannot write the compiler wrapper"
guard_row "M-twin" "$tmp/cc.twin" "$tmp/gf.twin" \
    "GATE-FAIL: guard: shallow non-tail twin did not complete cleanly (rc=107 want 105, e9=de04ad want de05ad)"
# nt(4) completes: frame de05ad, exit 105 -- the gate's deep leg must see a completed boot and refuse it
make_rewriter "$tmp/cc.deep" 'return nt(1000000) end' 'return nt(4) end' || fail_test "M-deep: cannot write the compiler wrapper"
guard_row "M-deep" "$tmp/cc.deep" "$tmp/gf.deep" \
    "GATE-FAIL: guard: deep NON-TAIL recursion did NOT fault (rc=105 frames=1 e9=de05ad)"

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link62-mutation sub-test(s) failed."; exit 1; fi
if [[ "$run_bochs" -eq 1 ]]; then
    bochs_banner="the gate's bochs_run accepts the base and refuses M-value after a completed boot"
else
    bochs_banner="the gate's bochs_run rows SKIPPED (no Bochs/sudo; KERNEL_CODEGEN_REQUIRE_EMU is not 1)"
fi
echo "PASS: link62-mutation ($pass legs: rows graded by the gate's own code lifted from run_native_codegen_link62.sh, plus this file's two boot-health controls: the white-box accepts the base p1 in guard, backward_e9 and callwhitelist and refuses M-noguard + M-espskew (guard), M-fwdcall + M-norecl (backward_e9), M-farcall + M-maskhole (callwhitelist, at the forged offset); the golden block accepts the base and refuses M-golden; behind this file's own clean-boot control and positive divergence proof, the gate's qemu_run accepts the base and refuses M-value on the divergent frame; $bochs_banner; guard_faults passes with the real compiler and refuses M-twin (twin leg) and M-deep (deep leg). Not guarded here: static_ok, backward_e8, noguard, distinctness, reject probes, the KVM invocation, the gate's main loop)"
exit 0
