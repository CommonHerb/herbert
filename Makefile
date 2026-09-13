CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -Wpedantic -O2

BUILD   := build

# --- Guard scanner -----------------------------------------------------
SCANNER := $(BUILD)/scan
TRACKED := $(BUILD)/tracked.txt

# The C bootstrap interpreter was RETIRED at the switchover (sovereignty link 18):
# the native gen-1 ELF compiler -- the committed bootstrap/seed/gen1.seed, run as
# the production toolchain -- is now the sole way Herbert source becomes machine
# code. tools/scan.c (the from-scratch boundary guard, below) is KEPT: it is the
# Constitution's day-one governance meta-tool, not the Herbert interpreter.

.PHONY: all check verification-helpers test test-timeout compiler-conformance stdin-contract compiler-cli-contract evaluator-native vm-native parser-native lexer-native klondike-native emitter-native error-vocab-native lexer-copy-sync native-codegen-diagnostics kernel-verify switchover-cfree switchover-dry-run closed-loop-memory-diet reseed verify-local clean

all: $(SCANNER)

check: $(SCANNER)
	@git ls-files > $(TRACKED)
	@./$(SCANNER) $(TRACKED)
	@bash bootstrap/tests/run_tests.sh --check-pinned
	@python3 bootstrap/tests/compiler_conformance.py --check-corpus
	@python3 bootstrap/tests/stdin_contract.py --check-spec

test:
	@bash tools/check_full_test_host.sh
	@PATH=$(abspath tools):$$PATH bash bootstrap/tests/run_tests.sh
	@python3 bootstrap/tests/compiler_conformance.py
	@python3 bootstrap/tests/stdin_contract.py
	@python3 bootstrap/tests/compiler_cli_contract.py

# Hosted language behavior through the ordinary seed, independently counted from
# the historical 43-test bootstrap/switchover suite. CI reaches it via make test.
compiler-conformance:
	@python3 bootstrap/tests/compiler_conformance.py

verification-helpers:
	@python3 bootstrap/tests/check_verification_helpers.py
	@python3 bootstrap/tests/check_debugcon_frames.py

# Real descriptor error/EOF checks; no ptrace, emulator, or partition change.
stdin-contract:
	@python3 bootstrap/tests/stdin_contract.py

# Atomic-publication syscall fault injection + instruction-layout reference.
# Requires Linux owned-process tracing, strace, GDB and binutils.
compiler-cli-contract:
	@python3 bootstrap/tests/compiler_cli_contract.py --faults

# A maintained useful program: sustained input processing on the hosted runtime.
.PHONY: wordcount
wordcount:
	@python3 bootstrap/tests/check_wordcount.py

# Native Linux desktop checkpoint. These .herb library units are concatenated
# as source, then compiled ONLY by the committed Herbert seed. No host compiler,
# graphics library, runtime, or launcher is linked into the resulting executable.
DESKTOP_SOURCES := lib/linux.herb lib/x11.herb lib/pixel_text.herb examples/first_steps.herb
.PHONY: first-steps hosted-memory-io check-desktop
first-steps: $(BUILD)/first-steps

$(BUILD)/first-steps: $(DESKTOP_SOURCES) bootstrap/seed/gen1.seed bootstrap/seed/gen1.seed.sha256
	@cd bootstrap/seed && sha256sum -c gen1.seed.sha256
	@set -eu; \
	  mkdir -p $(BUILD)/first-steps-work; \
	  cat $(DESKTOP_SOURCES) > $(BUILD)/first-steps-work/source.herb; \
	  cp bootstrap/seed/gen1.seed $(BUILD)/first-steps-work/compiler; \
	  chmod u+x $(BUILD)/first-steps-work/compiler; \
	  (cd $(BUILD)/first-steps-work && ./compiler < source.herb > compiler.stdout 2> compiler.stderr) || { cat $(BUILD)/first-steps-work/compiler.stderr >&2; exit 1; }; \
	  printf '0\n' > $(BUILD)/first-steps-work/expected.stdout; \
	  cmp $(BUILD)/first-steps-work/expected.stdout $(BUILD)/first-steps-work/compiler.stdout; \
	  test ! -s $(BUILD)/first-steps-work/compiler.stderr; \
	  chmod u+x $(BUILD)/first-steps-work/a.out; \
	  mv $(BUILD)/first-steps-work/a.out $@

hosted-memory-io:
	@python3 bootstrap/tests/check_hosted_memory_io.py

# Xvfb/libX11/libXtst are independent TEST tools, never program dependencies.
check-desktop: first-steps
	@python3 bootstrap/tests/check_desktop.py --image $(BUILD)/first-steps

# Useful programs on the sovereign long64 runtime, built by the same seed.
.PHONY: long64-wordcount check-long64-wordcount long64-hexview long64-elfinfo check-long64-elfinfo
long64-wordcount: $(BUILD)/wordcount-long64.elf
long64-hexview: $(BUILD)/hexview-long64.elf
long64-elfinfo: $(BUILD)/elfinfo-long64.elf

$(BUILD)/%-long64.elf: examples/%_long64.herb bootstrap/seed/gen1.seed bootstrap/seed/gen1.seed.sha256
	@cd bootstrap/seed && sha256sum -c gen1.seed.sha256
	@set -eu; \
	  mkdir -p $(BUILD)/$*-long64; \
	  cp bootstrap/seed/gen1.seed $(BUILD)/$*-long64/compiler; \
	  chmod u+x $(BUILD)/$*-long64/compiler; \
	  (cd $(BUILD)/$*-long64 && ./compiler < ../../examples/$*_long64.herb > compiler.stdout 2> compiler.stderr) || { cat $(BUILD)/$*-long64/compiler.stderr >&2; exit 1; }; \
	  printf '0\n' > $(BUILD)/$*-long64/expected.stdout; \
	  cmp $(BUILD)/$*-long64/expected.stdout $(BUILD)/$*-long64/compiler.stdout; \
	  test ! -s $(BUILD)/$*-long64/compiler.stderr; \
	  mv $(BUILD)/$*-long64/a.out $@

check-long64-wordcount: $(BUILD)/wordcount-long64.elf
	@python3 bootstrap/tests/check_wordcount_long64.py --image $(BUILD)/wordcount-long64.elf

check-long64-elfinfo: $(BUILD)/elfinfo-long64.elf
	@python3 bootstrap/tests/check_elfinfo_long64.py --image $(BUILD)/elfinfo-long64.elf

test-timeout:
	@python3 tools/check_timeout.py

# The six metacircular-fragment NATIVE-EXECUTION gates: the committed gen-1 seed
# compiles each fragment to an ELF that runs with NO C. <FRAG>_NATIVE_NO_C=1 flips
# the (now-retired) C-faithfulness cross-check permanently off -- the enduring leg
# (native ELF == independent oracle) is all that remains and needs no C.
evaluator-native:
	@EVALUATOR_NATIVE_NO_C=1 bash bootstrap/tests/run_evaluator_native.sh
	@bash bootstrap/tests/run_evaluator_native_mutation.sh

vm-native:
	@VM_NATIVE_NO_C=1 bash bootstrap/tests/run_vm_native.sh
	@bash bootstrap/tests/run_vm_native_mutation.sh

parser-native:
	@PARSER_NATIVE_NO_C=1 bash bootstrap/tests/run_parser_native.sh
	@bash bootstrap/tests/run_parser_native_mutation.sh

lexer-native:
	@LEXER_NATIVE_NO_C=1 bash bootstrap/tests/run_lexer_native.sh
	@bash bootstrap/tests/run_lexer_native_mutation.sh

klondike-native:
	@KLONDIKE_NATIVE_NO_C=1 bash bootstrap/tests/run_klondike_native.sh
	@bash bootstrap/tests/run_klondike_native_mutation.sh

emitter-native:
	@EMITTER_NATIVE_NO_C=1 bash bootstrap/tests/run_emitter_native.sh
	@bash bootstrap/tests/run_emitter_native_mutation.sh

# Front-end error-vocabulary native gate: the C-free rehome of klondike.herb's located
# ERR 101-316 diagnostics (the assurance castoff spent at the switchover). No NO_C flag --
# there is no C-faithfulness leg to retire; the gate is C-free by construction.
error-vocab-native:
	@bash bootstrap/tests/run_error_vocab_native.sh
	@bash bootstrap/tests/run_error_vocab_native_mutation.sh

lexer-copy-sync:
	@python3 bootstrap/tests/check_lexer_copy_sync.py

# native-codegen-diagnostics: a small QEMU DIAGNOSTICS suite for the native-codegen
# emitter -- NOT the kernel-arc boot gate. The boot gate is `make kernel-verify` (the
# link17..67 dual/tri-substrate gates + mutation proofs under KERNEL_CODEGEN_REQUIRE_EMU=1)
# and its CI mirror `.github/workflows/kernel-codegen-l1.yml`. Do not read this target's
# green as "the kernels boot" -- it is diagnostics, not the tri-substrate boot proof.
native-codegen-diagnostics:
	@bash bootstrap/tests/run_native_codegen_qemu_diag_tests.sh

# kernel-verify: the LOCAL kernel-arc boot gate. Runs every kernel-codegen link gate
# (link17..67) + its mutation proof with KERNEL_CODEGEN_REQUIRE_EMU=1
# (a missing QEMU/Bochs is a HARD failure, never a silent skip), and REQUIRES the KVM
# real-silicon leg when /dev/kvm is present -- the A11 tier-1 anchor CI cannot cover
# (GitHub runners have no /dev/kvm). Run this before any kernel-arc push. See the driver
# header for the local/CI substrate split.
kernel-verify:
	@bash bootstrap/tests/kernel_verify.sh

# switchover-cfree: prove the C-free production surface stands with the C
# interpreter PHYSICALLY ABSENT (the driver self-scrubs cc/gcc/as/ld and runs the
# CFREE surface on the committed gen-1 seed), then proves it bites RED-first.
switchover-cfree:
	@bash bootstrap/tests/run_switchover_cfree.sh
	@bash bootstrap/tests/run_switchover_cfree_mutation.sh

# switchover-dry-run: now a standing C-free guard. Post-switchover the C
# interpreter is gone, so this proves the 7 C-free bite-proofs STILL bite with C
# physically absent (the permanent reality) -- a stronger regression guard against
# C creeping back. The on-demand deletion recipe (apply_switchover.sh) + SWITCHOVER.md
# remain as the historical record of the event.
switchover-dry-run:
	@bash bootstrap/tests/run_switchover_dryrun.sh
	@bash bootstrap/tests/run_switchover_dryrun_mutation.sh

# Self-compile must reproduce the seed within the pinned RSS ceiling.
# make test already reaches this through the frozen C-free surface in both its
# absent and tombstone phases. This standalone target diagnoses that same gate;
# adding it again to verify-local would duplicate enforcement. Prior enforcement
# evidence: MEWTWO/audits/step0-diet-gate-2026-09-02/REPORT.md.
closed-loop-memory-diet:
	@bash bootstrap/tests/run_closed_loop_memory_diet.sh

# reseed: re-mint the gen-1 seed C-FREE (the committed seed recompiles the backend
# to its own fixpoint). Post-switchover this replaces the old C-mint reseed; run it
# ONLY when stack/native_compile_fragment.herb legitimately changes (the michoi seed
# gate goes RED). No C interpreter is involved.
reseed:
	@bash bootstrap/tests/reseed_gen1.sh

verify-local: check verification-helpers test-timeout test evaluator-native vm-native parser-native lexer-native klondike-native emitter-native error-vocab-native lexer-copy-sync native-codegen-diagnostics switchover-cfree switchover-dry-run compiler-cli-contract wordcount hosted-memory-io check-desktop

$(SCANNER): tools/scan.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
