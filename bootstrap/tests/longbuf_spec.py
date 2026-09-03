#!/usr/bin/env python3
"""longbuf_spec -- a SPEC-RESTATED model of the long64 tap image layout, used by link66's
white-box USE legs.

WHAT THIS IS, STATED BEFORE ANYTHING ELSE, because overclaiming it is the failure mode this
file most invites.

  * It is a SECOND DERIVATION OF THE *RELATIVE* LAYOUT ONLY. Given a function's parameter
    count and its source op sequence, it re-computes every image offset, displacement and
    count from the PUBLISHED SIZE TABLE alone -- it never consults the emitter's own
    offset/layout code. That makes it a checker on a different path from the producer
    (A11.2 layer (ii) discipline: producer-path != checker-path).
  * It is NOT A11.2 layer (i). It is NOT an independently-authored image builder, and it is
    NOT an oracle for absolute correctness. The op sequences it is handed are a HAND-DERIVED
    reading of the source, and the size table below is restated from the emitter's own
    published sizes. Absolute correctness still rests on a producer-captured golden, which
    is exactly the debt LEDGER D27 records ("the sovereign long64 spine has no independent
    oracle"). This file is D27's FIRST INSTALMENT and partial credit, nothing more.
  * The one thing it is handed from the producer is the op SEQUENCE. What it derives
    independently is where every one of those ops LANDS, what bytes it must be, and how many
    of them there are. A wrong emitter moves an offset; a wrong spec moves it too, but not
    the same way, which is why the mutants must go RED on these legs.

The counts leg is the exception that IS rooted in the source text rather than the table: it
counts `bufget(` / `bufset(` / `bufbase(` CALL SITES in the source, because each lowers to
exactly one op (native_compile_fragment.herb:1830-1838) and ERR 429 (:5450-63) forbids a
user-defined shadow of a builtin name. That count survives the golden pin being disabled.

  HOW FAR THAT COUNTING CLAIM ACTUALLY GOES, since a review leg was right that the first draft
  overstated it. `source_counts` is a TEXTUAL count over a comment-stripped source, not a
  parse. It is sound for the probe sources THIS GATE WRITES -- which contain no strings, no
  identifier merely ending in `bufget`, and one call per line -- and that is the only claim
  made for it. It is NOT a general-purpose IR census: a call inside a string literal, or a
  call split across lines, would fool it. The regex requires a word boundary so `mybufget(`
  does not match, and every match must be followed by `(`, but neither closes the string case.
  For any source this gate did not author, the count is a lower bound on nothing and an
  upper bound on nothing -- use the emitted-window count instead.
"""

import re
import struct
import sys

# ---------------------------------------------------------------- the published size table
#
# Restated from the emitter's published sizes, NOT read from it. Every entry carries the
# instruction form it stands for, so a reader can check the arithmetic without the emitter.

NC64_OP_SIZE = {
    0:  11,  # PUSH_INT   48 B8 imm64 ; 50
    3:   5,  # LOAD_LOCAL 48 8B 45 ib ; 50
    4:   5,  # STORE_LOCAL 58 ; 48 89 45 ib
    5:   6,  # ADD
    6:   6,  # SUB
    11: 13,  # EQ
    12: 13,  # NE
    16:  5,  # BR
    17: 10,  # BR_IF_FALSE
    42:  7,  # MUL
}
TAP_OP_SIZE = {
    45: 18,  # input_byte   -- poll LSR, in RBR, movzx, push
    53: 18,  # output_byte  -- pop, out THR, poll TEMT, push
    49: 11,  # bufbase()    -- 48 B8 imm64 ; 50 push rax
    50:  7,  # bufget(b,k)  -- 59 5A 48 8B 04 CA 50
    51:  8,  # bufset(b,i,v)-- 5A 59 58 48 89 14 C8 52
}
RET_LAST, RET_INNER = 1, 6           # op 21
BUF_OPS = {49, 50, 51}

# the exact bytes each buffer op must be, at its predicted offset
OP_BYTES = {
    50: bytes.fromhex("595a488b04ca50"),
    51: bytes.fromhex("5a5958488914c852"),
}
MOVABS_PREFIX = bytes.fromhex("48b8")   # op 49 = 48 B8 <imm64> 50
SCALE8_MASK = 0xC0                      # SIB scale bits; 0xC0 == x8


def call_size(nargs):
    """op 20, non-tail: E8 rel32 (5) + caller cleanup + push rax (1)."""
    cl = 0
    if nargs > 0:
        cl = 4 if 8 * nargs <= 127 else 7
    return 5 + cl + 1


def tail_len(nargs, frame):
    """op 20 at a tail site: bare E9 from a frame-zero caller, else 24 + 9*nargs."""
    return 5 if frame == 0 else 24 + 9 * nargs


def prologue_len(is_main, nparams, frame):
    if frame == 0:
        return 0
    if is_main:
        return 7            # mov rbp,rsp (3) + sub rsp,8S (4)
    return 8 + 8 * nparams  # push rbp (1) + mov rbp,rsp (3) + sub rsp,8S (4) + param copies


def epilogue_len(is_main, frame):
    if is_main:
        return 0
    return 5 if frame > 0 else 1


class Func:
    """One function's spec: name, parameter count, slot count, and its op sequence.

    Each op is (opcode, arg, nargs). `arg` is the callee index for op 20 and is unused
    elsewhere; `nargs` is the call arity. `frame` is max(nlocals, nparams), matching the
    emitter's published rule.
    """

    def __init__(self, name, nparams, nslots, ops, is_main=False):
        self.name, self.nparams, self.is_main = name, nparams, is_main
        self.ops = ops
        self.frame = max(nslots, nparams)

    def is_tail(self, i, funcs):
        """The emitter's predicate, restated (`nc_tap_is_tco` + `nc_is_tail_call`): not main;
        a call at i whose IMMEDIATE successor is a RET -- anywhere in the body, not only at
        the end; nothing branches to that RET; and the callee's arity equals this function's
        (the equal-argument-words rule).

        The first draft required the call to be the second-to-last op. That is NOT the
        emitter's rule -- an early `return f(...)` inside an if-arm is also a tail site -- and
        a review leg caught it. It agreed by accident on the forcing program and would have
        mis-predicted every offset after an early tail return."""
        if self.is_main:
            return False
        op, callee, nargs = self.ops[i]
        if op != 20:
            return False
        if i + 1 >= len(self.ops) or self.ops[i + 1][0] != 21:
            return False
        if (i + 1) in self.branch_targets():
            return False
        return funcs[callee].nparams == self.nparams

    def branch_targets(self):
        """Op indices that any BR/BR_IF_FALSE in this body targets. `arg` carries the target
        index for ops 16/17 in the spec's op tuples."""
        return {arg for (op, arg, _) in self.ops if op in (16, 17)}

    def op_size(self, i, funcs):
        op, _, nargs = self.ops[i]
        if self.is_tail(i, funcs):
            return tail_len(nargs, self.frame)
        if op == 20:
            return call_size(nargs)
        if op == 21:
            return RET_LAST if i == len(self.ops) - 1 else RET_INNER
        if op in TAP_OP_SIZE:
            return TAP_OP_SIZE[op]
        if op in NC64_OP_SIZE:
            return NC64_OP_SIZE[op]
        raise SystemExit("longbuf_spec: no published size for op %d" % op)

    def body_size(self, funcs):
        return sum(self.op_size(i, funcs) for i in range(len(self.ops)))

    def total(self, funcs):
        return (prologue_len(self.is_main, self.nparams, self.frame)
                + self.body_size(funcs)
                + epilogue_len(self.is_main, self.frame))


class Layout:
    """The whole-image relative layout, re-derived from the size table."""

    V0 = 1048588          # 0x10000C -- the code's own vaddr; the segment loads at 0x100000
    HEAD = 56
    GRADING_TAIL = 4      # 48 C1 E8 20  shr rax,0x20
    SHARED_EPILOGUE = 58

    def __init__(self, funcs, uses_uart=True):
        self.funcs = funcs
        main = funcs[0]
        main_prefix = 12 if main.frame > 0 else 5     # mov esp,imm32 (5) [+ main rbp frame 7]
        uart_len = 56 if uses_uart else 0
        self.main_body_base = self.HEAD + main_prefix + uart_len
        main_epi_abs = self.main_body_base + main.body_size(funcs)
        self.callee_block_start = main_epi_abs + self.GRADING_TAIL + self.SHARED_EPILOGUE
        self.bases = [self.HEAD]
        cur = self.callee_block_start
        for f in funcs[1:]:
            self.bases.append(cur)
            cur += f.total(funcs)

    def body_base(self, k):
        f = self.funcs[k]
        return (self.main_body_base if k == 0
                else self.bases[k] + prologue_len(False, f.nparams, f.frame))

    def op_offsets(self, k):
        """Absolute image offsets (relative to V0) of every op in function k."""
        f, cur, out = self.funcs[k], self.body_base(k), []
        for i in range(len(f.ops)):
            out.append(cur)
            cur += f.op_size(i, self.funcs)
        return out

    def buf_sites(self):
        """Every op-49/50/51 site as (func_index, op_index, opcode, image offset)."""
        sites = []
        for k, f in enumerate(self.funcs):
            offs = self.op_offsets(k)
            for i, (op, _, _) in enumerate(f.ops):
                if op in BUF_OPS:
                    sites.append((k, i, op, offs[i]))
        return sites

    def param_copy_disps(self, k):
        """The prologue's param copies: src [rbp + 16 + 8*(nparams-1-i)], dst [rbp - 8*(i+1)].
        Emitted as 48 8B 45 ib / 48 89 45 ib -- the `48 8B 45 ib` form that legitimately
        collides with LOAD_LOCAL, which is why each site is predicted individually."""
        f = self.funcs[k]
        if f.is_main or f.frame == 0:
            return []
        base = self.bases[k] + 8          # after push rbp + mov rbp,rsp + sub rsp,8S
        return [(base + 8 * i, 16 + 8 * (f.nparams - 1 - i), (256 - 8 * (i + 1)) & 0xFF)
                for i in range(f.nparams)]


# ---------------------------------------------------------------- source-rooted counts

def source_counts(src):
    """n_get / n_set / n_base from the SOURCE text -- call sites, not emitted bytes.

    Each builtin call lowers to exactly one op (:1830-1838) and ERR 429 (:5450-63) forbids a
    user-defined function shadowing a builtin name, so a call-site count IS the op count.
    Comment lines are stripped first so a commented-out call cannot inflate the count."""
    body = "\n".join(l.split("--", 1)[0] for l in src.splitlines())
    return {
        "n_get":  len(re.findall(r"\bbufget\s*\(", body)),
        "n_set":  len(re.findall(r"\bbufset\s*\(", body)),
        "n_base": len(re.findall(r"\bbufbase\s*\(", body)),
    }


# ---------------------------------------------------------------- the image, read back

class Image:
    """The compiled ELF, parsed POSITIONALLY -- never by scanning for a signature."""

    def __init__(self, path):
        self.raw = open(path, "rb").read()
        (self.p_type, self.p_offset, self.p_vaddr, self.p_paddr,
         self.p_filesz, self.p_memsz, self.p_flags,
         self.p_align) = struct.unpack("<8I", self.raw[52:84])
        self.code_len = self.p_filesz - 12
        self.code = self.raw[4108:4108 + self.code_len]
        self.load_end = Layout.V0 + self.code_len

    def header_ok(self):
        """The location fields this class relies on, ASSERTED rather than parsed and ignored
        (a review leg's finding). The code is at file offset 4096+12 because the segment
        begins at 4096 and carries a 12-byte multiboot header; the segment loads at 0x100000
        and V0 = 0x10000C is 12 past it."""
        return (self.p_type == 1
                and self.p_offset == 4096
                and self.p_vaddr == 0x100000
                and self.p_vaddr + 12 == Layout.V0
                and self.p_filesz >= 12
                and self.p_memsz >= self.p_filesz
                and len(self.raw) >= 4108 + self.code_len)

    # -- geometry, derived from p_filesz ONLY.
    #
    # This is deliberately INDEPENDENT OF p_memsz, and the first draft of it was not. A
    # RED-first battery caught that: deriving guard_hi as `p_memsz + 0x100000` and then
    # asserting `p_memsz == guard_hi - 0x100000` is a tautology, so M-memsz -- reverting
    # p_memsz to filesz+16384 -- graded GREEN. The leg was vacuous, which is exactly the
    # producer-path == checker-path circularity A11.2 exists to forbid.
    #
    # The honest derivation walks the SAME road the emitter walks, from the file size:
    #   code_len = p_filesz - 12 ; load_end = V0 + code_len
    #   guard_lo = roundup_2m(load_end) ; buf_2m = guard_lo + 2 MiB ; guard_hi = buf + 2 MiB
    # p_memsz is then something to CHECK against this, never an input to it.
    @property
    def guard_lo(self):
        return roundup_2m(self.load_end)

    @property
    def buf_2m(self):
        return self.guard_lo + 2097152

    @property
    def guard_hi(self):
        return self.buf_2m + 2097152

    @property
    def memsz_from_p(self):
        """The high guard as p_memsz CLAIMS it, for the pmemsz leg to compare against the
        filesz-derived value above. Never used to derive anything."""
        return self.p_memsz + 0x100000

    def pd_entries(self):
        """The 512 PD entries. The PD is the LAST 4 KiB of the code."""
        pd = self.code[self.code_len - 4096:]
        return [struct.unpack("<Q", pd[i * 8:i * 8 + 8])[0] for i in range(512)]

    def pd_nonpresent(self):
        """2-MiB indices whose PDE has the PRESENT bit clear.

        Bit 0, not `entry == 0`: a review leg pointed out that testing the whole entry for
        zero both misses a non-present entry carrying stale bits and cannot tell a corrupted
        present mapping from a good one. `pd_present_ok` below is the other half."""
        return [i for i, e in enumerate(self.pd_entries()) if (e & 1) == 0]

    def pd_present_ok(self):
        """Every PRESENT entry must be exactly the identity 2-MiB PS mapping the emitter
        publishes: `i*2097152 + 131` (P|RW|PS), high dword zero."""
        bad = []
        for i, e in enumerate(self.pd_entries()):
            if e & 1:
                want = i * 2097152 + 131
                if e != want:
                    bad.append((i, hex(e), hex(want)))
        return bad

    def raw_count(self, hexstr):
        pat, n, i = bytes.fromhex(hexstr), 0, 0
        while True:
            j = self.code.find(pat, i)
            if j < 0:
                return n
            n, i = n + 1, j + 1


def parse_positional(stream, n_echo, n_query):
    """THE production answer-stream parser for this link. POSITIONAL, never a scan.

    Strict alternation fixes every byte's position: n_echo fill echoes, then per query a
    hi-echo, a lo-echo and an answer. So the only well-formed length is n_echo + 3*n_query,
    the answers sit at fixed indices, and the LAST answer is the terminal one by construction.

    This exists because LEDGER D26 records what scanning costs: the shared answer parser binds
    the FIRST `DE..AD` frame by bare `re.search`, so a two-frame stream grades on the frame the
    boot did not end on. Nothing here searches for a signature; a stream one byte short or one
    byte long is rejected by COUNT.

    Returns (answers, terminal_ok, cardinality). cardinality is 1 for a well-formed stream and
    -1 for any other length -- never 0, so "no frame found" and "wrong length" cannot be
    confused by a caller that only truth-tests the value.
    """
    need = n_echo + 3 * n_query
    if not isinstance(stream, (bytes, bytearray)) or len(stream) != need:
        return None, False, -1
    answers = [stream[n_echo + 3 * j + 2] for j in range(n_query)]
    return answers, True, 1


def roundup_2m(v):
    r = v % 2097152
    return v if r == 0 else v + 2097152 - r
