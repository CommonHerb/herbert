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

.PHONY: all check smoke test test-timeout lexer-equivalence lexer-copy-sync native-codegen-diagnostics verify-local beta-full clean

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

lexer-copy-sync:
	@python3 bootstrap/tests/check_lexer_copy_sync.py

native-codegen-diagnostics:
	@bash bootstrap/tests/run_native_codegen_qemu_diag_tests.sh

verify-local: check test-timeout smoke lexer-equivalence lexer-copy-sync native-codegen-diagnostics

beta-full: $(HERBERT)
	@PATH=$(abspath tools):$$PATH HERBERT=$(abspath $(HERBERT)) bash bootstrap/tests/run_beta_full.sh

$(SCANNER): tools/scan.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(HERBERT): $(HERBERT_SRCS) $(HERBERT_HDR) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(HERBERT_SRCS)

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
