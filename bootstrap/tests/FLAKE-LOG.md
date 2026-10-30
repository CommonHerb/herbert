# Kernel-arc gate FLAKE LOG — adjudicate CI/local REDs from evidence, not habit

**Purpose.** Record known failure classes on the kernel-arc gates
(`run_native_codegen_link17..67.sh` and mutation siblings), so each RED is
investigated against evidence. Unchanged compiler and kernel bytes are useful
controls, but can still contain input-dependent or intermittent defects. Each
class below gives its current diagnosis and handling; its history is in git.

**How to use.** Preserve the failing input, raw captures, statuses, tool versions
and artifact hashes before any replay. Match the signature against the known
classes below and investigate the compiler, kernel, grader and harness as
appropriate. A controlled replay should retain the same input and record its
outcome separately. One successful replay, unchanged pins or disagreement
between emulators does not establish a benign transient cause. An unexplained
failure remains unresolved; do not rerun until green and discard the failure.
A green on a second attempt is never a first-attempt green.

---

## Known classes

### F1 — chasemap degeneracy (fixed)

`link53` (platter) mutation proof, `M-fixedlba GREEN on the chase (vacuous)`, about one run in 64. The random chase
map self-looped at START (`cm[START]&0x3F==START`, p = 1/64) or otherwise collapsed the honest chase, so the mutant's
output equalled the honest one. Not a kernel bug. Fixed in herbert `68c69ad`: gate and mutation proof both reject and
regenerate degenerate maps.

### F2 — Bochs feed-log / no-output harness (hardened)

Any Bochs leg. A COM1 feeder that never listens, a Bochs run that produces no output, a host-side loop-mount race
that hands Bochs a stale disk, or a GRUB configuration swap that silently fails leaves a wrong on-disk state that looks
like a kernel RED. Signatures: `(C-Bochs) … RED … N0 not found in dir` while QEMU and KVM are green in the same run;
`mount: … wrong fs type, bad option, bad superblock on /dev/loop0p1` followed by a `shutdown=0` count.

Every Bochs boot in a CI gate now goes through the shared `bochs_f2_harness.sh` or an equivalent inline block: a
checked disk build on a fresh disk for each attempt, with explicit mount and loop cleanup on every exit path; each
attempt classed as `DISK-BUILD(step)`, `NO-OUTPUT`, `NO-SHUTDOWN`, `EXTRACT-FAILURE` (feed legs also
`FEED-NO-LISTEN`, `FEED-NO-SENT`) or `COMPLETED`; and only a boot whose feeder listened and delivered its payload
(`SENT`) and that ran through the kernel's `shutdown requested` graded as a kernel verdict. Harness classes re-roll up
to three times; exhaustion prints a greppable `HARNESS-ERROR` (never the `FAIL:` kernel-RED prefix) and fails closed,
unconditionally in the shared harness and link33, and under `KERNEL_CODEGEN_REQUIRE_EMU=1` (as CI runs) in the older
inline gates. Each gate's `pkill bochs` is scoped to its own process. Feeder-side `SENT` does not prove the guest
received the byte: a lost or late COM1 byte can still misframe the input, so a lone completed RED is adjudicated with
the same-input replay discriminator (`replay_discriminator.sh`), not by the completion witnesses alone.

### F3 — geeking QEMU abnormal exit (flake)

`link37` (geeking) gate: `geek_local echo byte=60: exit rc=245 != host_qemu_exit(T=60)=27`. QEMU exited abnormally
(245, not the isa-debug-exit code) on a byte-identical, previously green kernel, and the next run passed. A QEMU runtime
flake, not a miscompile. Re-run once and record both attempts; a recurrence needs its own investigation.

### F4 — Bochs boot timeout under load (environment)

Any Bochs leg: `<probe> Bochs: frames(de<b>ad)=0 shutdown-evidence=0` (no frames, no shutdown). A correct but slow boot
did not finish in time; seen only while other heavy work ran on the same machine. Run `make kernel-verify` on a quiet
machine and re-run.

### F5 — cairn two-boot COM1 (cause is F11)

`link55` (cairn): `control kernel is NOT clean (TARGET GREEN=0; DECOY GREEN=1 …)` in the mutation proof's control, and
an empty emission (`emitted=,`) in the main gate's hostile legs on a byte-identical kernel. It was first read as a lost
BOOT-1 COM1 byte. It was later reproduced on demand, on both emulators and the byte-pinned kernel, with a clean
transport, by choosing a seed whose query carries a `0xD4` within three bytes of its end: the cause is the frame-parser
defect F11. The hostile legs that have a BOOT-1 (`C-HOSTILE-CARRY`, `C-HOSTILE-DF`) carry a guest-side receipt (the
putter echoes the bytes it read) and a host-side storage read-back that outranks it; `C-HOSTILE-LBA`, which has no
BOOT-1, has a frame-count liveness receipt. An absent receipt (transport) is re-rolled, a wrong one is adjudicated and
never re-rolled, with one same-seed replay each and a wall-clock ceiling.

### F6 — watchdog kill on abnormal QEMU exit (flake)

Frozen links: `add7 byte=60: exit rc=245 … grade: RED … benign module was KILLED by the watchdog (kill-witness
present)` on a link the change did not touch. F3's abnormal QEMU exit, seen through a kill-witness leg; the kernel was
byte-identical and the next attempt passed. Adjudicate as F3, with the same-input replay discriminator.

### F7 — load-correlated QEMU timeout (environment)

Any QEMU leg times out or completes with no output while the machine carries other load; the same gate is clean on a
quiet machine. The same-input replay cannot separate this: under sustained load the replay fails the same way, so a
harness event can look like a reproduced hard RED. Never grade kernel gates on a saturated machine; re-adjudicate a RED
seen under load on a quiet one.

### F8 — emulator version (fixed; current pin policy below)

CI's earlier pinned QEMU 8.2.2 deterministically aborted the `link34` (trikonderoga) mutation guest, 3 of 3 attempts:
`run_native_codegen_link34_mutation.sh: line 45: NNNNN Aborted  timeout 60 qemu-system-x86_64 ...`, then
`FAIL: link34 HARNESS FAILURE -- a QEMU run was dead/timed-out (empty output); fail-closed, NOT a genuine pass`. Not a
flake and not a miscompile: QEMU 10.2.1 runs it green. Re-rolling never clears it, and the fail-closed harness that
reports it must not be reverted (the old one scored the dead run as a pass). Fixed in herbert `2494945` by moving CI to
`ubuntu-26.04` with QEMU 10.2.1 and Bochs 2.8.

**F8 current policy.** The kernel workflow installs exact versions, qemu `1:10.2.1+ds-1ubuntu3.2` and bochs
`2.8+dfsg-1` with the other packages built from those two sources (seven packages), from Ubuntu's snapshot service.
Ubuntu updates no longer turn runs red; versions move on purpose. Everything else comes from the runner's own archive
and floats: the firmware the emulators load (seabios, ipxe-qemu, vgabios; the assert step prints their versions), the
`ubuntu-helper-virt-hwe` apt hook, every library and the image's GRUB tools. The install step requires
qemu-system-x86, qemu-system-common and ubuntu-virt to arrive as `…_amd64v3.deb` and stops with an `EMULATOR PIN:`
line otherwise; nothing checks the installed record's variant. If the snapshot cannot be used the step fails after
three attempts (F14) and never installs another version. The version assert stays behind it as a backstop: if it
fires, the install and its literals disagree or apt installed something it was not asked for; investigate, never
re-roll. To move to a new version, follow the steps in the install step's comment in
`.github/workflows/kernel-codegen-l1.yml`; the `ci/` run that first installs the new versions is the golden
re-validation, and is recorded here.

- 2026-09-29: snapshot `20260929T135500Z`, the archive as it stood when kernel run `36578733589` (`f8665e8`, green)
  installed exactly these versions.

### F9 — a gate that orphans its own emulators (harness bug)

Any gate that backgrounds `timeout N qemu … &` and later kills `$!`: `$!` is the `timeout` wrapper, so killing it
leaves the emulator running with nothing left to stop it. The symptom is on the machine, not in the gate: emulator
processes outlive their run, each holding most of a core, and the load climbs run over run (seen: 24 orphans, load
average 0.4 to 27), which then reproduces F4 and F7 on the next run. Fixed in `link66_mutation`: the emulator itself
is the background job, and the wall-clock ceiling is a separate watchdog that leaves a marker file. Before grading,
count emulators with `ps -eo comm | grep -cx 'qemu-system-x86'`, not `pgrep -fc qemu-system-x86_64`, which matches the
checking shell's own command line.

### F10 — mawk versus gawk: the portability class (not a flake)

Any gate or proof whose shell uses `awk` with a dialect-sensitive regex. Signature:
`` awk: warning: escape sequence `\$' treated as plain `$' `` followed by the gate's own fail-closed line, for example
`FAIL: link66-mutation (extract the forcing source: empty)`: a 0-second failure with no emulator involved.
Deterministic per machine: mawk reads `\$` in a regex as a literal dollar, gawk (CI's awk) as the end anchor, and mawk
mishandles open-ended intervals (`{n,}`). Closed for `link66_mutation` and `link62_mutation`, which extract with
fixed-string matching in Python. Rule: no dialect-sensitive construct in an `awk` program in a gate (no backslash
escapes inside a regex such as `\$`, `\(`, `\{`, no open-ended intervals). Plain POSIX regexes and field access
(`{print $2}`) are portable; fixed strings in `grep -F`, `sed` or Python are safest.

### F11 — the debugcon frame parser was not binary-safe (fixed for migrated readers)

The old `_wframes` scanners in the `*_ref.py` oracles (and `holler_ref.py`'s whole-stream `_wframe`) searched the
whole trace for the write-frame opener `0xD4` and trusted the length read at that offset. A late-bound COM1 byte equal
to `0xD4`, echoed raw in a read record, was taken for a frame header, and the scan stepped over the genuine answer
frame. It worked both ways: a false RED (an empty `emitted=` on a byte-identical kernel, F5's signature) and a false
GREEN (a leaking kernel graded as the clean reject, because the hidden frame carried the leak). About 1.17% per graded
emission (`1-(255/256)^3`), deterministic per seed: a same-seed replay reproduces it, and a fresh seed usually but not
always clears it (`78061b1fe2c3175b` and `ea9bb6f2d93a16e1` both reproduce it), so a passing re-roll is evidence of
nothing.

Readers migrated to the shared binary-safe parser [`debugcon_frames.py`](debugcon_frames.py) (herbert `c61d274`,
landed through `fac05ce5`) validate record boundaries and positive answer witnesses; its regression gate is
[`check_debugcon_frames.py`](check_debugcon_frames.py), run by `make verification-helpers` and hosted CI, and its
record grammar is in [DEBUGCON-FRAMES.md](DEBUGCON-FRAMES.md). This does not explain old runs whose raw trace was not
kept, nor certify other or future parsers. Every seed-drawing gate prints `  SEED <var>=<hex>`: re-run an
`emitted=`-empty RED on a late-bound gate with the same seed; same-seed recurrence with a clean transport receipt
points at parsing, not at the kernel.

### F12 — xvfb-run's own diagnostics in the graded Bochs capture (hardened)

Every Bochs leg. The capture ends
`…[UNMAP ] Shutdown port: shutdown requested\n====…\n(0).[…] … out dx, al ; ee\nxvfb-run: error: problem while cleaning up temporary directory\n`;
the gate prints `PARSER-ERROR …` and `<profile> malformed/truncated debugcon record at byte N of M`, on a completed,
correct boot. xvfb-run writes its own `error()` to stderr, and the gates' outer `2>&1` merged it into the capture. The
line comes from its EXIT trap when `rm -r "$XVFB_RUN_TMPDIR"` fails, which exits 5 before killing Xvfb, so each
occurrence also leaks an Xvfb server. Why `rm` failed is not established. The parser's refusal is correct and is not
relaxed.

Every Bochs boot now goes through `kernel_xvfb_capture` (`kernel_evidence.sh`). It runs the command through an exec
shim, `sh -c 'exec "$@" 2>&1'`, so the helper itself merges the command's stdout and stderr into the capture. That
matters because xvfb-run versions differ: `2:21.1.12-1ubuntu1.8` (Ubuntu 24.04) runs the command as `"$@" 2>&1`, while
`2:21.1.22-1ubuntu1.2` (the ubuntu-26.04 runner) runs it as `"$@" 3>&-` and leaves its stderr on the wrapper's. The
shim `exec`s, so the running process is still exactly `bash -c "<inner>"` for scoped `pkill -f` patterns. xvfb-run's
own stderr goes to `<capture>.xvfb-run.stderr`, removed when empty; when not, it is kept beside the capture, xvfb-run's
status is written to `<capture>.xvfb-run.exit`, and a `HARNESS-NOTE:` line names any Xvfb still running from the boot
directory (reported, never signalled). The helper accepts only `-a`/`--auto-servernum` before the command; any other
shape is a `HARNESS-ERROR` with status 2, nothing run, and the capture removed (or emptied, if it cannot be removed,
with a second `HARNESS-ERROR` naming it). Verdicts are unchanged: a completed boot is graded once, on guest bytes alone,
and never re-rolled for a wrapper complaint. Proof: `check_bochs_xvfb_capture.py` and `check_link44_attempts.py`
(`make verification-helpers`).

Residuals. (HF-01) A capture that can be neither removed nor emptied (read-only, in a read-only directory) keeps its
bytes through a refusal, and no caller acts on the refusal, so those bytes would be graded as this boot; no current
caller reaches the refusal, since every call site passes `CAPTURE -a bash -c …` into a directory its gate made in the
same run. xvfb-run's silent `set -e` abort (a failing `xauth remove`, say) can still leak a server with no stderr,
undetected. Row J of `check_bochs_xvfb_capture.py` catches literal direct `xvfb-run` calls outside the helper in
tracked non-Markdown files; it does not see calls through a variable, alias, function or computed path, a name split by
quoting or a line continuation, other Python argv forms or untracked files, and some literal bypasses are known (a call
glued to an availability probe on one line, a quoted name followed by a word its Python-word exclusion matches, a
command word starting with a glob). It guards against the old pattern coming back; it does not prove no direct call
exists.

Reading it: an `xvfb-run: error:` line belongs in a `HARNESS-NOTE`, never in a capture. A `PARSER-ERROR` is not this
class and needs its own investigation. A `HARNESS-NOTE` that quotes Bochs's own output (for example
`00000000000i[      ] LTDL_LIBRARY_PATH not set`) means the command's stderr reached the side file: the shim is
missing or bypassed.

### F13 — Bochs crash at exit (hardened)

The emulator died of a signal after the kernel's shutdown banner, and bash's job report for the boot pipeline entered
the graded capture. The capture ends
`…[UNMAP ] Shutdown port: shutdown requested\n====…\n(0).[…] … out dx, al ; ee\nyes: standard output: Broken pipe\nbash: line 1: 12281 Exit 1 yes c\n 12282 Segmentation fault (core dumped) | timeout -s KILL 90 bochs -q -f bochsrc.txt\n`,
and the gate printed `REPLAY tri Bochs byte=20: completed Bochs boot graded RED (… geeking malformed/truncated debugcon
record at byte 30 of 550)`. Observed once, on `link39` in GitHub run `36583224514` (job `kernel links 33..43`, Bochs
`2.8+dfsg-1`): about one boot in 44 of that job, and no crash trailer in 349 retained shutdown-bearing capture files
from two earlier runs. The same byte-pinned kernel passed on run `36578733589`.

Now the inner command of every Bochs boot in a CI gate records the boot pipeline's own status in
`<capture>.pipeline-status`, before xvfb-run's cleanup can replace xvfb-run's status (kept as evidence only, in
`<capture>.wrapper-status`). A boot that ran through `shutdown requested` is classed only from that file
(`f2__status_class` in `bochs_f2_harness.sh`), never from the capture's text:

- a missing, empty or non-numeric file is `NO-STATUS(…)`;
- death by SIGILL, SIGABRT, SIGBUS, SIGFPE or SIGSEGV (status 132, 134, 135, 136 or 139; the harness's
  `F2_CRASH_SIGNALS`) is `EMULATOR-CRASH(status S = signal N after the shutdown banner)`;
- both are harness classes: never graded, and re-rolled on a fresh disk within the caller's attempt budget (three in
  most places, four in link55's Bochs loop); running out fails closed under `KERNEL_CODEGEN_REQUIRE_EMU=1`;
- any other signal after the banner, SIGKILL (137) and SIGTERM included, is `KILLED-AFTER-BANNER(…)`: never graded and
  never re-rolled; the leg fails at once with `HARNESS-ERROR: … not re-rolled … fail-closed`, and a completed RED whose
  same-input replay is killed stays unadjudicated and fails closed, since re-rolling a kill could clear a wrong answer
  that came before it;
- a signal death before the banner stays `NO-SHUTDOWN`; a boot whose emulator exited on its own is graded as always,
  so a malformed capture from a normal exit is still RED.

This covers the shared attempt functions, the own loops of links 53, 64 and 66, every inline Bochs boot (links 33,
44, 45, 48–52 and 54–61; a crash or kill in any boot of a multi-boot attempt ends the attempt) and
`check_boot_input.py` (link67, and `check_elfinfo_long64.py` through it). Each attempt's cleanup runs in its own
parse-error scope, so a graded parse error no longer blanks later attempts' classes. Proof:
`check_bochs_emulator_crash.py` and `check_link44_attempts.py` (`make verification-helpers`).

Residuals. (a) link49's RUN-1 park test never reaches the banner and ends by its timeout's kill by design, so its boots
are not classed; a crash there is graded, and its frame grader fails closed on the trailer. (b) A timed-out boot is
terminal only where `timeout` reports its own KILL as 137, as GNU timeout does. The ubuntu-26.04 runner's
`/usr/bin/timeout` is uutils 0.10.0, which reports 124, so on CI a Bochs that hangs after the banner until its timeout
is graded as a finished boot, and only a direct SIGKILL (the OOM killer's, say) is `KILLED-AFTER-BANNER`. On runner
image `20260920.143` a stand-in that died of SIGTERM after the banner did not yield 143 (SIGSEGV, SIGABRT and SIGKILL
came through as 139, 134 and 137), so there a Bochs killed by SIGTERM after the banner is also graded as finished;
`check_bochs_emulator_crash.py`'s SIGTERM row feeds status 143 directly.

Not this class: a job report after a Bochs fault before any boot, such as a stale `disk.img.lock` (`image locked:
'disk.img'`, then `>>PANIC<< ata0-0: could not open hard drive image file 'disk.img'`), the reused-locked-disk retry
shape that links 44, 45 and 48 had; their retries now use a fresh directory.

Reading it: an `EMULATOR-CRASH` re-roll line is this class. The same crash on every attempt is not a flake and needs
its own investigation, and so does a `KILLED-AFTER-BANNER` line.

### F14 — emulator snapshot unusable (infrastructure)

`kernel-codegen-l1`, the "install emulators + boot tooling" step of every job, before any gate runs. The step ends
`EMULATOR PIN: snapshot <ID> unusable after 3 attempts: <reason> -- refusing to install any other version` (exit 1),
after `emulator pin: attempt 1 of 3 failed (<reason>); retrying in 20 s` and the same line for attempt 2
(`retrying in 60 s`). A pruned or wrong snapshot ID also prints, on every attempt, apt's
`E: The repository 'https://snapshot.ubuntu.com/ubuntu/<ID> resolute Release' does not have a Release file.`; an
outage prints `Err:` and `W: Failed to fetch https://snapshot.ubuntu.com/…` lines. `<reason>` is
`apt-get update failed` (the `E:` lines above it say why), `apt has no index from it (snapshot.ubuntu.com
unreachable?)` (an outage), `downloading the pinned packages from it failed`, or `it does not serve <package>
<version>` (the index was fetched but lacks the pinned version: a wrong pin, or an ID from before that version was
published).

Seen 2026-10-30: kernel run 41022308019 failed in all eight jobs with `503  Service Unavailable` from
snapshot.ubuntu.com and `apt has no index from it (snapshot.ubuntu.com unreachable?)`; no gate ran. The re-run
41024064145, sixteen minutes later on the same commit, was green.

Nothing is graded before this step succeeds, so re-running the job is legitimate; keep the failed run's log, and a
green re-run does not erase the failure. One failure that clears on a re-run is a transient outage. A failure that
persists across re-runs, or any `does not have a Release file` signature, means a longer outage, a pruned snapshot ID
or a pin naming a version the ID predates: move the snapshot through the version-move steps (F8 current policy), and
never install an unpinned version instead. Not this class, and not cleared by a re-run: any other `EMULATOR PIN:` line
(for example `EMULATOR PIN: runner is <codename> …`, a runner release change; move the pin deliberately) and
`UNPINNED EMULATOR PACKAGE: …` (a new binary from source qemu or bochs; add it to `PINNED`).

---

## What the evidence can establish

- A seed hash differing from its committed pin, failed byte pin, failed
  structural assertion or mutation that does not bite requires investigation.
  These are signals, not a complete
  definition of a compiler defect; byte-identical output can still be wrong.
- A specific emulator or harness diagnosis needs supporting captures and a
  controlled discriminator. Non-recurrence alone leaves the cause unproved.
  Intermittent defects remain defects, and a later pass never erases a failed
  attempt or substitutes for its missing evidence.
