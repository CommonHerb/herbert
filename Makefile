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

.PHONY: all check test test-timeout evaluator-native vm-native parser-native lexer-native klondike-native emitter-native error-vocab-native lexer-copy-sync native-codegen-diagnostics switchover-cfree switchover-dry-run reseed verify-local clean

all: $(SCANNER)

check: $(SCANNER)
	@git ls-files > $(TRACKED)
	@./$(SCANNER) $(TRACKED)

test:
	@bash tools/check_full_test_host.sh
	@PATH=$(abspath tools):$$PATH bash bootstrap/tests/run_tests.sh

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

native-codegen-diagnostics:
	@bash bootstrap/tests/run_native_codegen_qemu_diag_tests.sh

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

# reseed: re-mint the gen-1 seed C-FREE (the committed seed recompiles the backend
# to its own fixpoint). Post-switchover this replaces the old C-mint reseed; run it
# ONLY when stack/native_compile_fragment.herb legitimately changes (the michoi seed
# gate goes RED). No C interpreter is involved.
reseed:
	@bash bootstrap/tests/reseed_gen1.sh

verify-local: check test-timeout test evaluator-native vm-native parser-native lexer-native klondike-native emitter-native error-vocab-native lexer-copy-sync native-codegen-diagnostics switchover-cfree switchover-dry-run

$(SCANNER): tools/scan.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
