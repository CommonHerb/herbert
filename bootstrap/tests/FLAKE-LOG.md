# Kernel-arc gate FLAKE LOG — adjudicate CI/local REDs from evidence, not habit

**Purpose.** A standing record of *known* flake classes on the kernel-arc gates (`run_native_codegen_link17..62.sh`
+ `_mutation.sh`), so a RED is adjudicated against evidence: "is this a known re-rollable flake, or a real
miscompile?" A miscompile changes the emitted bytes (the seed sha moves, or a byte-pin/white-box gate fails). A
flake is a transient emulator/harness event on an **unchanged, byte-identical** kernel (the seed sha stays
`8d08fe53…`; QEMU-TCG/KVM/Bochs disagree on a run that later passes clean). **When in doubt, re-roll once and
compare** — a real bug reproduces deterministically; a flake does not.

**How to use.** On a CI/local RED: (1) find the failing step + signature; (2) match it below; (3) if it's a known
flake class on an untouched gate, re-run (record the outcome); (4) if it does NOT match, or reproduces
deterministically, treat it as real and investigate before landing/declaring green. Append new classes here.

---

## Known flake classes (as of 2026-07-04)

| # | class | gate(s) | signature | adjudication | status |
|---|---|---|---|---|---|
| F1 | **chasemap degeneracy** (mutation output-invisible on a degenerate random map) | `link53` (platter) `_mutation` M-fixedlba | `M-fixedlba GREEN on the chase (vacuous)` ~1 run in 64 | the random author-unknown chasemap self-loops at START (`cm[START]&0x3F==START`, p=1/64) or otherwise collapses the honest chase to `[cm[START]]×K`, so M-fixedlba is output-identical → false-RED. NOT a kernel bug. | **FIXED** — herbert `68c69ad` (map gen rejects+regenerates degenerate maps in both gate + mutation). |
| F2 | **Bochs feed-log / no-output harness** (a COM1 feeder that never LISTENs, or a Bochs run that produces no output, cascades to a wrong on-disk state → mis-attributed as a kernel RED) | `link60` (tract); **same class present, unhardened**, in the other multi-boot Bochs legs `link54`/`link55`/`link58`/`link59` and the single-boot Bochs feed legs `link44/45/48-52/56/57/61` | e.g. `(C-Bochs) … RED … N0 not found in dir` while QEMU+KVM are GREEN in the SAME run | boot-1's feeder never bound its socket (feed*.log has no `LISTENING`) or Bochs produced no boot, so the kernel never got its late-bound input; the wrong FS state is a harness failure, not a miscompile. | **link60 HARDENED + COMPLETED** — herbert `3e2b450` (the SENT / feeder-delivered half) + the 2026-07-04 F2 sweep (COMPLETING the pattern): detects the harness failure (feeder never reached LISTENING, feeder never delivered its payload `SENT` — i.e. Bochs never connected COM1 — Bochs produced no output, **the boot never reached the kernel's `shutdown()` tail — `'shutdown requested'` absent — a boot killed or hung mid-run**, or **the GRUB config swap silently failed so Bochs booted the WRONG/stale module** (cross-model Codex); names the offending file), retries the 3-boot ×3 on a fresh disk, and grades reuseok as a kernel verdict ONLY once every boot LISTENED + delivered (SENT) + ran THROUGH `shutdown()`; 3 persistent harness failures → a loud, greppable `HARNESS-ERROR` marker (NOT the `FAIL: …` kernel-RED prefix), fail-closed only under REQUIRE_EMU=1, and the system-wide `pkill bochs` is scoped to this gate's own process. **Siblings: the F2 sweep (2026-07-04) is REPLICATING link60's completed pattern across them, one gate per commit — order: link59 + link55 first, then 54/58, then the single-boot feed legs 44/45/48-52/56/57/61. Hardened so far: link60 (the reference), link59, link55. Until a given sibling is pinned here, re-roll a `(C-Bochs) …` RED whose QEMU+KVM legs were green in the same run.** |
| F3 | **geeking QEMU abnormal-exit** | `link37` (L21, geeking) gate | `geek_local echo byte=60: exit rc=245 != host_qemu_exit(T=60)=27` (kernel-codegen-l1 run `28689240315`, 2026-07-04) | QEMU exited abnormally (245, not the isa-debug-exit code 27) on an untouched, historically-green kernel; seed sha stable `8d08fe53…`; the parent's cold local sweep had it green. A QEMU runtime flake, not a miscompile. | **FLAKE CONFIRMED** — geeking PASSED clean on run `28691692998` (HEAD 3e2b450, 2026-07-04): the L21 gate + L21 mutation (42 checks) + the whole l1-dual-substrate job all GREEN. The `rc=245` was a transient QEMU abnormal-exit, not a miscompile (the geeking kernel is byte-identical between the failed and passing runs). (The direct re-run of `28689240315` was cancelled by a subsequent push's concurrency; adjudication moved to the equivalent-kernel `28691692998`.) |
| F4 | **Bochs boot-timeout / wall-clock** (a loaded runner makes a correct-but-slow Bochs boot time out → no completion) | any Bochs leg; observed `link22`/`link23` locally under concurrent load | `<probe> Bochs: frames(de<b>ad)=0 shutdown-evidence=0` (0 frames, 0 shutdown) | Bochs did not finish the boot in time (no wrong byte — just no completion); observed only under concurrent local load (a codex process + git running during a full `make kernel-verify`). Not a miscompile. | Mitigation: run `make kernel-verify` **clean** (nothing else consuming CPU); re-roll. The KVM real-silicon leg (fast, reliable) is the CI-uncoverable local anchor; the full 17..62 QEMU+Bochs is CI's job. |
| F5 | **cairn two-boot COM1** | `link55` (cairn) `_mutation` control | `control kernel is NOT clean (TARGET GREEN=0; DECOY GREEN=1 …)` | the control (unmutated) two-boot two-query cairn probe's TARGET query did not grade green on one run (a late-bound COM1 two-boot timing event) while the DECOY did; observed under load. Not a miscompile (cairn is byte-identical + CI-green). | **link55 Bochs leg HARDENED** by the F2 sweep (2026-07-04): the two-boot Bochs path now requires each boot to LISTEN + deliver (SENT) + swap-GRUB cleanly + run THROUGH `shutdown()`, and re-rolls ×3 on a harness failure -- so a COM1-timing event on the Bochs leg re-rolls instead of false-REDding. (The `_mutation` control's own two-boot COM1 timing is a separate harness; re-roll it per this class until it too is swept.) |

---

## The invariant that separates flake from bug

- **Real miscompile:** the emitted bytes changed. Symptoms: the gen-1 seed sha moves off `8d08fe53…`; a full-image
  byte-pin (`… image != committed golden`) fails; a white-box `assert_*` fails; a mutation FAILS TO BITE
  *deterministically* across re-rolls. Investigate — do NOT re-roll away.
- **Flake:** the kernel is byte-identical (seed sha stable, byte-pins pass) and the disagreement is a substrate/harness
  event that does not reproduce. Re-roll and record.
