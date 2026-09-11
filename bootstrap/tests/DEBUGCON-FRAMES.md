# Debugcon record boundaries

`debugcon_frames.py` decodes the runtime tail of the OWN-table kernel lineage.
It covers gates 34 through 61. Gate 33's earlier lodger CACA/FEFE witness
protocol remains separate and is not migrated here.
The oracle's `parse_head` supplies the profile and process count. Its returned
`FramedTail` remains a byte string for compatibility, but frame queries use the
cached record boundaries. Plain byte strings are rejected by those queries.

The writer is the authority for each shape below. All integers are four-byte
little-endian unless stated otherwise. Source references name functions/labels
so these claims survive nearby line movement.

| Record | Bytes | Writer in `bootstrap/tests` |
| --- | --- | --- |
| read | C0, one byte, cs/eip/esp, C1 | `cairn_ref.py`, `build_code`, `do_read_ready` |
| write | D4, length/cs/eip/esp, length bytes, D5 | `cairn_ref.py`, `do_write` / `wrelay` |
| rejected write | D6, length/cs/eip/esp, D7 | `cairn_ref.py`, `reject_write` |
| wake | CC, process/byte, CD | `cairn_ref.py`, `sw_wfound` |
| demand commit | C2, error/cr2/PTE-before/PTE-after, C3 | `cairn_ref.py`, page-fault demand arm |
| switch counter | C8, count, C9 | `cairn_ref.py`, `finalize` |
| dispatch | CA, `nprocs` counters, CB | `cairn_ref.py`, `fdisp` |
| copy-on-write | C8, cr2/original-frame/private-frame, C9 | `cleave_ref.py`, COW arm |
| page fault | D0, error/eip/cs/cr2/esp, D1 | `cairn_ref.py`, `pf_nodemand` |
| protection fault | F0, error/eip/cs/esp, F1 | `cairn_ref.py`, `gp_handler` |
| other fault | E2, eip/cs, E3 | `cairn_ref.py`, `panic_handler` |
| answer | DE, one byte, AD | inherited `body_start` program epilogue |
| kernel panic | P | `cairn_ref.py`, `kpanic` |
| table-only stage | 77 | `cairn_ref.py`, stage-A branch after OWN dump |
| heap banner | literal `LARDER\xa5\x5a` | `larder_ref.py`, before iret-to-proc0 |
| allocation | E0, pointer | `larder_ref.py`, `la_emit` |
| live heap | E1, repeated pointer/value pairs, E2 | `larder_ref.py`, `do_dump` |
| frame allocation | F0, pointer | `highwater_ref.py`, `do_falloc` |
| live frames | F1, repeated pointer/value pairs, F3 | `highwater_ref.py`, `do_hwdump` |

Profiles admit the production shapes present in their own writer lineage
(`DISK_DEBUG=0`; optional DA/DB diagnostic builds require their own profile). Larder and its
successors remove the direct read witness. The two-process tickover/tandem
layouts pass their fixed process count; later OWN tables supply `nprocs`.

The decoder starts at byte zero and advances through whole records. Bodies and
integer fields are opaque. A chart counts complete interpretations, capped at
two: an ambiguous capture is an error. No candidate marker is picked simply
because its decoded value matches the expected answer. The uncounted heap and
frame dumps consider only complete eight-byte entry boundaries.

The default decoder requires a terminal record. The one explicit exception is
`FramedPrefix`, used only by furlough `grade_furlough(run="run1")`: that probe
withholds the byte deliberately and requires each peer's complete token three
times, proving progress while the reader remains blocked. It makes no completion
claim; empty or partial peers fail the unchanged token checks.

In the default decoder, a valid prefix without a terminal record is `IncompleteTrace`: the kernel has
not supplied a complete runtime result. `parse_head` reports no complete result,
so existing runtime graders reject it, including intentional mutant hangs.
Malformed or ambiguous captures raise `TraceError`. An uncounted heap dump may
still be a valid unfinished record even through otherwise unrecognized bytes;
without a complete parse this is conservatively `IncompleteTrace`, never a
successful result. Each affected normal and
mutation gate (links 34..61) sets a marker in its existing work directory.
An uncaught `TraceError` records that marker even when a negative shell
predicate discards stderr; verdict helpers and shared cleanup force exit 1.
Caught exceptions and ordinary semantic mismatches do not write the marker. Such an error cannot certify a
mutation. This is scoped to those gate invocations; direct Python users must
handle `TraceError` themselves. A table-only stage cannot supply write evidence.

Bochs preamble extraction requires printable ASCII (plus tab/CR/LF) before
the first OWN-table marker and preserves every subsequent byte. Bochs also
mixes a host shutdown trailer into its port-e9 stdout. The decoder accepts
only the fixed shutdown envelope and its ASCII debugger line syntax, anchored
immediately after a terminal record. It never searches payloads for the envelope
or strips arbitrary printable bytes. Unknown diagnostic formats fail closed.
The exact `yes: standard output: Broken pipe` diagnostic from the shell's
`yes c | timeout ... bochs` pipeline is admitted at a reached record boundary.
After an incomplete prefix it remains `IncompleteTrace`; it cannot supply a
missing guest terminal. Unrecognized diagnostics cannot complete a result.
The furlough RUN-1 prefix also permits the observed two-line Bash pipeline
status for `yes c | timeout -s KILL 50 bochs -q -f bochsrc.txt`, with variable
process IDs and spacing. That exact source command intentionally kills the
withheld-input run after 50 seconds. Default mode reports an incomplete result;
only the named prefix mode can validate the observed progress. Neither claims
guest completion.

Both local Bochs 2.7 and pinned CI Bochs 2.8 raw captures anchor this rule.
`fixtures/rollcall-bochs-2.8.e9` is the unchanged link46 `b3` capture from
GitHub run34570498624, group44..51, capture20260911T064008.567276Z-8_chlhxp;
SHA256 `f604235d8f8577cfddff269bef565a4059f36df4cf3e9e2bbb05eac6c119ef59`.
The existing kernel and mutation gates must still run against the repaired parser.

`fixtures/cairn-bochs-ci-seed.e9` is the actual September 11 audit capture for seed
`691708f82b0bf856`, copied unchanged from
`BLUESTONE/audits/independent-assessment-2026-09-11/logs/cairn-bochs-get.e9`.
Its expected payload is independently fixed in `check_debugcon_frames.py`.
The early D4 is a wake-record value; the later closed write is the answer.
`CAIRN_BOCHS_SEED=691708f82b0bf856` reproduces the same live link55 Bochs
input; the default remains a fresh random seed.

The earlier holler lineage (also used by mmj/chiefturbo/mumbani) has its own
profile: `exit_handler` emits E0 + status byte + cs/eip/esp + E1; `tick_kill`
emits CA + eip/cs/esp/eflags + CB. Its `mod_hostile` attempts to OUT the two
literal bytes 77 and BB; they are module escape observations, not a table-only
stage. These shapes are not admitted by the later profiles. Its OWN header
uses `holler_ref.py`'s cell layout and fixed one-process context.

The earlier trikon/nokta/sitopia/geeking parsers use narrow subsets of the holler
profile: trikon emits exit/GP/answer/panic-P; nokta adds PF; sitopia adds read;
geeking adds watchdog kill and generic-fault records. Their `exit_handler`,
`gp_handler`, `pf_handler`, `tick_kill` and `panic_handler` labels define those
shapes. Coalgate and ouroboros reuse the frozen geeking kernel and parser.

The link40 `norelay` mutant intentionally emits a D4 header declaring three
bytes, omits all three bytes, then emits D5. The strict production parser rejects
that malformed frame. Its mutation gate therefore proves this exact defect
positively: require the source-sized OWN/read/empty-relay/exit/answer sequence,
restore only the three expected bytes at the known relay boundary, and require
unchanged `holler_ref.grade_write` to validate every remaining witness. The real
captured mutant passes this narrow missing-relay proof; an ordinary good control
fails it. No malformed or ambiguous capture error certifies this mutant or any other mutation.
