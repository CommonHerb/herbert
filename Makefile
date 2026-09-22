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

check: $(SCANNER) compiler-source-check
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
	@python3 bootstrap/tests/check_link44_attempts.py

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

# Developer builds use the same committed compiler; support units are ordered
# source concatenation, not an external linker. Values travel via environment
# variables so source/output paths with spaces never become shell syntax.
.PHONY: program program-contract
program: SHELL := /bin/bash
# Do not recursively expand user filenames as Make expressions, including via
# Make's automatic export of command-line variables.
unexport SOURCE SUPPORT OUTPUT
program: export PROGRAM_SOURCE = $(value SOURCE)
program: export PROGRAM_SUPPORT = $(value SUPPORT)
program: export PROGRAM_OUTPUT = $(if $(value OUTPUT),$(value OUTPUT),build/program)
program:
	@set -euo pipefail; set -f; \
	  die() { printf 'program: %s\n' "$$*" >&2; exit 1; }; \
	  canonical_path() { \
	    local path; path=$$(realpath "$$@" && printf '.') || return; path=$${path%$$'\n.'}; \
	    [[ "$$path" != *$$'\t'* && "$$path" != *$$'\n'* ]] || die 'paths containing tabs/newlines are unsupported'; \
	    printf '%s' "$$path"; \
	  }; \
	  root=$$(canonical_path -e .); \
	  for path in "$$PROGRAM_SOURCE" "$$PROGRAM_OUTPUT" "$$root"; do \
	    [[ "$$path" != *$$'\t'* && "$$path" != *$$'\n'* ]] || die 'paths containing tabs/newlines are unsupported'; \
	  done; \
	  [[ -n "$$PROGRAM_SOURCE" ]] || die 'use make program SOURCE=path [SUPPORT="linux ..."] [OUTPUT=build/program]'; \
	  [[ -f "$$PROGRAM_SOURCE" && -r "$$PROGRAM_SOURCE" ]] || die "source is not a readable file: $$PROGRAM_SOURCE"; \
	  source=$$(canonical_path -e -- "$$PROGRAM_SOURCE"); \
	  [[ ! -L "$$PROGRAM_OUTPUT" && ! -d "$$PROGRAM_OUTPUT" ]] || die 'output must not be a symlink or directory'; \
	  output=$$(canonical_path -m -- "$$PROGRAM_OUTPUT"); \
	  [[ "$$output" != "$$source" && ! "$$output" -ef "$$source" ]] || die 'output would replace the source'; \
	  git_dir=$$(git rev-parse --absolute-git-dir && printf '.'); git_dir=$${git_dir%$$'\n.'}; \
	  git_dir=$$(canonical_path -e -- "$$git_dir"); \
	  common_dir=$$(git rev-parse --git-common-dir && printf '.'); common_dir=$${common_dir%$$'\n.'}; \
	  common_dir=$$(canonical_path -e -- "$$common_dir"); \
	  for protected in "$$root/.git" "$$git_dir" "$$common_dir"; do \
	    [[ "$$output" != "$$protected" && "$$output" != "$$protected/"* ]] || die 'output would replace repository metadata'; \
	  done; \
	  [[ ! "$$output" -ef "$$root/bootstrap/seed/gen1.seed" ]] || die 'output would replace the seed'; \
	  if [[ "$$output" == "$$root/"* ]]; then \
	    relative=$${output#"$$root/"}; \
	    if git --literal-pathspecs ls-files --error-unmatch -- "$$relative" >/dev/null 2>&1; then die 'output would replace a tracked project file'; \
	    else status=$$?; [[ "$$status" -eq 1 ]] || die 'cannot establish tracked-file protection'; fi; \
	  fi; \
	  units=(); \
	  for alias in $$PROGRAM_SUPPORT; do \
	    [[ "$$alias" =~ ^[a-zA-Z0-9_]+$$ && -f "$$root/lib/$$alias.herb" ]] || die "unknown support alias: $$alias"; \
	    units+=("$$root/lib/$$alias.herb"); \
	  done; \
	  units+=("$$source"); \
	  for unit in "$${units[@]}"; do \
	    [[ "$$unit" != *$$'\t'* && "$$unit" != *$$'\n'* ]] || die 'source paths containing tabs/newlines are unsupported'; \
	    [[ "$$output" != "$$unit" && ! "$$output" -ef "$$unit" ]] || die 'output would replace an input source'; \
	  done; \
	  mkdir -p -- "$$(dirname -- "$$output")"; \
	  work=$$(mktemp -d "$$(dirname -- "$$output")/.herbert-build.XXXXXXXX"); \
	  trap 'status=$$?; printf "program build evidence: %s\n" "$$work" >&2; exit "$$status"' EXIT; \
	  cp -- bootstrap/seed/gen1.seed "$$work/compiler"; \
	  want=$$(awk '{print $$1}' bootstrap/seed/gen1.seed.sha256); \
	  got=$$(sha256sum "$$work/compiler" | awk '{print $$1}'); \
	  [[ "$$got" == "$$want" ]] || die 'committed seed checksum mismatch'; \
	  printf '%s\n' "$$got" > "$$work/compiler.sha256"; \
	  chmod u+x "$$work/compiler"; \
	  : > "$$work/source.herb"; : > "$$work/source-map.tsv"; first=1; index=0; \
	  for unit in "$${units[@]}"; do \
	    cp -- "$$unit" "$$work/input.$$index.herb"; \
	    lines=$$(wc -l < "$$work/input.$$index.herb"); eof=$$((lines + 1)); \
	    cat -- "$$work/input.$$index.herb" >> "$$work/source.herb"; \
	    if [[ "$$(tail -c1 "$$work/input.$$index.herb" | od -An -tx1 | tr -d ' \n')" != 0a ]]; then \
	      printf '\n' >> "$$work/source.herb"; lines=$$((lines + 1)); \
	    fi; \
	    last=$$((first + lines - 1)); \
	    printf '%s\t%s\t1\t%s\n' "$$first" "$$last" "$$unit" >> "$$work/source-map.tsv"; \
	    first=$$((last + 1)); index=$$((index + 1)); \
	  done; \
	  printf '%s\t%s\t%s\t%s\n' "$$first" "$$first" "$$eof" "$$source" >> "$$work/source-map.tsv"; \
	  if (cd "$$work" && ./compiler < source.herb > compiler.stdout 2> compiler.stderr); then status=0; else status=$$?; fi; \
	  printf '%s\n' "$$status" > "$$work/compiler.status"; \
	  if [[ "$$status" -ne 0 ]]; then \
	    pattern='^line ([0-9]+):(.*)$$'; \
	    while IFS= read -r diagnostic || [[ -n "$$diagnostic" ]]; do \
	      mapped=0; \
	      if [[ "$$diagnostic" =~ $$pattern ]]; then \
	        number=$$((10#$${BASH_REMATCH[1]})); message=$${BASH_REMATCH[2]}; \
	        while IFS=$$'\t' read -r first last original_first unit; do \
	          if (( number >= first && number <= last )); then \
	            printf '%s:%s:%s\n' "$$unit" "$$((number - first + original_first))" "$$message" >&2; mapped=1; break; \
	          fi; \
	        done < "$$work/source-map.tsv"; \
	      fi; \
	      [[ "$$mapped" -eq 1 ]] || printf '%s\n' "$$diagnostic" >&2; \
	    done < "$$work/compiler.stderr"; \
	    die "compiler exited with status $$status"; \
	  fi; \
	  printf '0\n' > "$$work/expected.stdout"; \
	  cmp -s "$$work/expected.stdout" "$$work/compiler.stdout" && [[ ! -s "$$work/compiler.stderr" ]] || die 'compiler success must have stdout 0+LF and empty stderr'; \
	  [[ -f "$$work/a.out" && "$$(head -c4 "$$work/a.out" | od -An -tx1 | tr -d ' \n')" == 7f454c46 ]] || die 'compiler did not publish an ELF image'; \
	  sha256sum "$$work/a.out" > "$$work/image.sha256"; \
	  cp -- "$$work/a.out" "$$work/publish"; chmod u+x "$$work/publish"; \
	  mv -T -- "$$work/publish" "$$output"; \
	  printf 'Built %s\n' "$$output"

program-contract:
	@python3 bootstrap/tests/check_program_build.py

# Native Linux desktop checkpoint. These .herb library units are concatenated
# as source, then compiled ONLY by the committed Herbert seed. No host compiler,
# graphics library, runtime, or launcher is linked into the resulting executable.
DESKTOP_LIBS := lib/linux.herb lib/x11.herb lib/pixel_text.herb
first-steps_SOURCES := $(DESKTOP_LIBS) examples/first_steps.herb
maze_SOURCES := $(DESKTOP_LIBS) lib/grid_map.herb examples/maze.herb
notes_SOURCES := $(DESKTOP_LIBS) lib/utf8.herb lib/unicode_tables.herb lib/unicode_grapheme.herb lib/unicode_display.herb lib/file_io.herb lib/text_buffer.herb lib/session_recovery.herb examples/notes.herb
.PHONY: first-steps maze notes hosted-apps hosted-memory-io check-desktop check-hosted-apps
first-steps: $(BUILD)/first-steps
maze: $(BUILD)/maze
notes: $(BUILD)/notes
hosted-apps: first-steps maze notes

$(BUILD)/first-steps: $(first-steps_SOURCES)
$(BUILD)/maze: $(maze_SOURCES)
$(BUILD)/notes: $(notes_SOURCES)
$(BUILD)/first-steps $(BUILD)/maze $(BUILD)/notes: bootstrap/seed/gen1.seed bootstrap/seed/gen1.seed.sha256
	@cd bootstrap/seed && sha256sum -c gen1.seed.sha256
	@set -eu; \
	  mkdir -p $@-work; \
	  cat $($(notdir $@)_SOURCES) > $@-work/source.herb; \
	  cp bootstrap/seed/gen1.seed $@-work/compiler; \
	  chmod u+x $@-work/compiler; \
	  (cd $@-work && ./compiler < source.herb > compiler.stdout 2> compiler.stderr) || { cat $@-work/compiler.stderr >&2; exit 1; }; \
	  printf '0\n' > $@-work/expected.stdout; \
	  cmp $@-work/expected.stdout $@-work/compiler.stdout; \
	  test ! -s $@-work/compiler.stderr; \
	  chmod u+x $@-work/a.out; \
	  mv $@-work/a.out $@

hosted-memory-io:
	@python3 bootstrap/tests/check_hosted_memory_io.py

# Xvfb/libX11/libXtst are independent TEST tools, never program dependencies.
check-desktop: first-steps
	@python3 bootstrap/tests/check_desktop.py --image $(BUILD)/first-steps

.PHONY: check-app-support
check-app-support: maze
	@python3 bootstrap/tests/check_grid_map.py --maze $(BUILD)/maze
	@python3 bootstrap/tests/check_notes_support.py
	@python3 bootstrap/tests/check_utf8_text.py
	@python3 bootstrap/tests/check_x11_text.py

check-hosted-apps: maze notes
	@python3 bootstrap/tests/check_hosted_apps.py --maze $(BUILD)/maze --notes $(BUILD)/notes

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
# (individual gates enforce emulator availability). For KVM member
# links it checks device access when present; individual gates own execution.
# Its aggregate summary records gate status, not per-substrate boot receipts.
# Run this before kernel-arc pushes; see VERIFYING.md for the local/CI split.
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

# One authoring location per stage; the tracked assembled artifact preserves
# all established seed, byte-golden and historical test interfaces.
COMPILER_SOURCES := stack/compiler/frontend_vm.herb \
                    stack/compiler/types_and_inference.herb \
                    stack/compiler/metadata.herb \
                    stack/compiler/hosted_emitter.herb \
                    stack/compiler/kernel_targets.herb \
                    stack/compiler/driver.herb
.PHONY: compiler-source compiler-source-check compiler-source-membership compiler-metadata
compiler-source-membership:
	@set -eu; \
	  work=$$(mktemp -d /tmp/herbert-source-check.XXXXXXXX); \
	  printf '%s\n' $(COMPILER_SOURCES) | LC_ALL=C sort > "$$work/declared"; \
	  if ! find stack/compiler \( -name '*.herb' -o -type l \) > "$$work/present.raw"; then \
	    printf 'Cannot list compiler stages; evidence retained: %s\n' "$$work" >&2; exit 1; \
	  fi; \
	  LC_ALL=C sort "$$work/present.raw" > "$$work/present"; \
	  if ! cmp -s "$$work/declared" "$$work/present"; then \
	    printf 'Compiler stage membership differs (missing, duplicate or unlisted unit); inspect: %s\n' "$$work" >&2; exit 1; \
	  fi; \
	  for unit in $(COMPILER_SOURCES); do \
	    if test ! -f "$$unit" || test -L "$$unit"; then \
	      printf 'Compiler stage must be a regular non-symlink file: %s; evidence: %s\n' "$$unit" "$$work" >&2; exit 1; \
	    fi; \
	  done; \
	  rm -- "$$work/declared" "$$work/present" "$$work/present.raw"; rmdir "$$work"

compiler-source-check: compiler-source-membership
	@set -eu; \
	  combined=$$(mktemp /tmp/herbert-source-check.XXXXXXXX); \
	  if ! cat $(COMPILER_SOURCES) > "$$combined"; then \
	    printf 'Cannot compose compiler source; candidate retained: %s\n' "$$combined" >&2; exit 1; \
	  fi; \
	  if ! cmp -s "$$combined" stack/native_compile_fragment.herb; then \
	    printf 'Compiler composition differs. Inspect stage AND assembled edits before make compiler-source; it retains the previous assembled file. Candidate: %s\n' "$$combined" >&2; exit 1; \
	  fi; \
	  rm -- "$$combined"; \
	  printf 'PASS: compiler source composition is byte-exact\n'

compiler-source: compiler-source-membership
	@set -eu; \
	  work=$$(mktemp -d stack/.compiler-source.XXXXXXXX); \
	  printf 'Compiler assembly work/evidence: %s\n' "$$work"; \
	  cat $(COMPILER_SOURCES) > "$$work/source.herb"; \
	  if cmp -s "$$work/source.herb" stack/native_compile_fragment.herb; then \
	    rm -- "$$work/source.herb"; rmdir "$$work"; \
	    printf 'Compiler source already current.\n'; exit 0; \
	  fi; \
	  previous=0; \
	  if test -f stack/native_compile_fragment.herb; then \
	    cp -p -- stack/native_compile_fragment.herb "$$work/previous.herb"; previous=1; \
	  fi; \
	  chmod 644 "$$work/source.herb"; \
	  mv -T -- "$$work/source.herb" stack/native_compile_fragment.herb; \
	  if test "$$previous" -eq 1; then \
	    printf 'Assembled compiler; previous source retained in %s.\n' "$$work"; \
	  else printf 'Assembled new compiler source; no previous file existed.\n'; fi; \
	  printf 'Qualify and reseed after substantive changes.\n'

compiler-metadata:
	@python3 bootstrap/tests/check_compiler_metadata.py

# reseed: re-mint the gen-1 seed C-FREE (the committed seed recompiles the backend
# to its own fixpoint). Post-switchover this replaces the old C-mint reseed; run it
# ONLY when stack/native_compile_fragment.herb legitimately changes (the michoi seed
# gate goes RED). Checks the existing pin and both invocation envelopes, then
# qualifies a changed fixpoint with hosted conformance before publication.
# Full verify-local and applicable target qualification still follow. No C
# interpreter is involved.
reseed: compiler-source-check
	@bash bootstrap/tests/reseed_gen1.sh

# make test already dispatches the six fragment/mutation pairs and both
# switchover-cfree scripts. Preserve their standalone targets above for diagnosis;
# the C-free proof's absent/tombstone phases still run as distinct environments.
verify-local: compiler-metadata check verification-helpers program-contract test-timeout test error-vocab-native lexer-copy-sync native-codegen-diagnostics switchover-dry-run compiler-cli-contract wordcount hosted-memory-io check-desktop check-app-support check-hosted-apps

$(SCANNER): tools/scan.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
