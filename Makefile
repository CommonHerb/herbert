CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -Wpedantic -O2

BUILD   := build

# --- Guard scanner -----------------------------------------------------
SCANNER := $(BUILD)/scan
TRACKED := $(BUILD)/tracked.txt

# --- Herbert interpreter ----------------------------------------------
HERBERT      := $(BUILD)/herbert
HERBERT_SRCS := \
    bootstrap/util.c \
    bootstrap/lex.c \
    bootstrap/parse.c \
    bootstrap/value.c \
    bootstrap/reclaim.c \
    bootstrap/eval.c \
    bootstrap/main.c
HERBERT_HDR  := bootstrap/herbert.h

.PHONY: all check smoke test test-timeout lexer-equivalence parser-equivalence evaluator-native vm-native parser-native lexer-native klondike-native emitter-native lexer-copy-sync native-codegen-diagnostics switchover-cfree switchover-dry-run verify-local beta-full reseed clean

all: $(HERBERT)

check: $(SCANNER)
	@git ls-files > $(TRACKED)
	@./$(SCANNER) $(TRACKED)

test:
	@bash tools/check_full_test_host.sh
	@$(MAKE) $(HERBERT)
	@PATH=$(abspath tools):$$PATH HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_tests.sh

smoke: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_smoke.sh

test-timeout:
	@python3 tools/check_timeout.py

lexer-equivalence: $(HERBERT)
	@CC="$(CC)" CFLAGS="$(CFLAGS)" bash bootstrap/tests/run_lexer_equivalence.sh

parser-equivalence: $(HERBERT)
	@CC="$(CC)" CFLAGS="$(CFLAGS)" HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_parser_equivalence.sh

evaluator-native: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_evaluator_native.sh
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_evaluator_native_mutation.sh

vm-native: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_vm_native.sh
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_vm_native_mutation.sh

parser-native: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_parser_native.sh
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_parser_native_mutation.sh

lexer-native: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_lexer_native.sh
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_lexer_native_mutation.sh

klondike-native: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_klondike_native.sh
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_klondike_native_mutation.sh

emitter-native: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_emitter_native.sh
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_emitter_native_mutation.sh

lexer-copy-sync:
	@python3 bootstrap/tests/check_lexer_copy_sync.py

native-codegen-diagnostics:
	@bash bootstrap/tests/run_native_codegen_qemu_diag_tests.sh

# switchover-cfree: the FIRST switchover-machinery slice (sovereignty link 14).
# Prove the C-free production surface stands with the C interpreter PHYSICALLY
# ABSENT. NO $(HERBERT) prerequisite -- this target deliberately does NOT build
# the C interpreter; the driver self-scrubs cc/gcc/as/ld and runs the CFREE
# surface on the committed gen-1 seed, then proves it bites RED-first.
switchover-cfree:
	@bash bootstrap/tests/run_switchover_cfree.sh
	@bash bootstrap/tests/run_switchover_cfree_mutation.sh

# switchover-dry-run: sovereignty link 17. Extends the C-absent proof beyond
# drydock's 24-gate surface: proves the 7 C-free BITE-PROOFS still bite with the
# C interpreter PHYSICALLY ABSENT (the non-vacuity guards survive C's removal) +
# its RED-first bite-proof. The EXECUTABLE deletion recipe is
# bootstrap/tests/apply_switchover.sh <clean-worktree> (run on-demand; see
# SWITCHOVER.md). NO $(HERBERT) prereq -- this target does not build the C interpreter.
switchover-dry-run:
	@bash bootstrap/tests/run_switchover_dryrun.sh
	@bash bootstrap/tests/run_switchover_dryrun_mutation.sh

verify-local: check test-timeout smoke lexer-equivalence parser-equivalence evaluator-native vm-native parser-native lexer-native klondike-native emitter-native lexer-copy-sync native-codegen-diagnostics switchover-cfree switchover-dry-run

beta-full: $(HERBERT)
	@PATH=$(abspath tools):$$PATH HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_beta_full.sh

# michoi: re-mint the C-free gen-1 seed from the C bootstrap. Run ONLY when
# stack/native_compile_fragment.herb changes (which shifts gen-1's bytes and
# makes the committed seed stale). This is the one sanctioned C mint.
reseed: $(HERBERT)
	@HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/reseed_gen1.sh

$(SCANNER): tools/scan.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(HERBERT): $(HERBERT_SRCS) $(HERBERT_HDR) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(HERBERT_SRCS)

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
