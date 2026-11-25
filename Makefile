BUILD   := build

# --- Guard scanner -----------------------------------------------------
# tools/scan.herb checks BOOTSTRAP-ALLOWLIST against the tracked files. Like every
# Herbert program here, the committed seed builds it (the rule beside the hosted
# apps, below), so make check needs no C compiler.
SCANNER := $(BUILD)/scan
TRACKED := $(BUILD)/tracked.txt
scan_SOURCES := lib/linux.herb tools/scan.herb
# The scanner's own checks, written in Herbert (checks/scans.herb): it runs the
# scanner on lists it makes, in a folder of its own under the one given here.
scans_SOURCES := lib/linux.herb lib/text.herb lib/folder.herb lib/child.herb checks/scans.herb

.PHONY: all check reseed verify-local clean

all: $(SCANNER)

check: $(SCANNER) $(BUILD)/scans compiler-source-check
	@$(BUILD)/scans "$(CURDIR)/$(SCANNER)" "$${TMPDIR:-/tmp}"
	@git ls-files > $(TRACKED)
	@./$(SCANNER) $(TRACKED)

# The checks written in Herbert (checks/). The committed seed builds the runner,
# and the runner holds a compiler (the seed, or COMPILER=/absolute/path) to
# every case in the files below: it must rebuild itself byte for byte, and each
# program must give its answer. VERIFYING.md says what a case is.
ANSWERS := checks/rebuild.cases checks/first.cases checks/language.cases checks/libraries.cases checks/fragments.cases checks/planted.cases
.PHONY: answers
answers:
	@work=$$(mktemp -d "$${TMPDIR:-/tmp}/herbert-answers.XXXXXX") && mkdir "$$work/build" "$$work/run" && \
	  (cd bootstrap/seed && sha256sum -c --quiet gen1.seed.sha256) && \
	  cp bootstrap/seed/gen1.seed "$$work/build/seed" && chmod u+x "$$work/build/seed" && \
	  cat lib/linux.herb lib/text.herb checks/run.herb > "$$work/build/run.herb" && \
	  (cd "$$work/build" && ./seed < run.herb > marker 2> errors) && chmod u+x "$$work/build/a.out" && \
	  "$$work/build/a.out" "$${COMPILER:-$$work/build/seed}" "$$work/run" "$(CURDIR)" $(addprefix $(CURDIR)/,$(ANSWERS)) && \
	  rm -rf "$${work:?}" || { echo "answers: FAILED; what it left is in $$work" >&2; exit 1; }

# The window checks, written in Herbert (checks/hands.herb). The committed seed
# builds Notes, Scope, Maze, First steps, the check and its stand-in; the check
# starts a display nobody sees (Xvfb, a host tool as the desktop's own display
# server is), opens the programs on it and presses their keys. It makes its own
# folder under the one given here and, when every check passes, removes from it
# what it made, name by name. VERIFYING.md says what it holds the programs to.
.PHONY: hands
hands: notes scope maze first-steps $(BUILD)/hands $(BUILD)/stand-in
	@$(BUILD)/hands "$(CURDIR)/$(BUILD)/notes" "$(CURDIR)/$(BUILD)/scope" "$(CURDIR)/$(BUILD)/maze" "$(CURDIR)/$(BUILD)/first-steps" "$(CURDIR)/$(BUILD)/stand-in" "$${TMPDIR:-/tmp}"

# Scope's helper's checks, written in Herbert (checks/helper.herb). The committed
# seed builds the helper and the check; the check starts the helper on this
# computer only (addresses in 127.77.0.0/16, ports 47700 to 47799), in a folder
# it makes under the one given here and removes again when every check passes.
# VERIFYING.md says what it holds the helper to.
.PHONY: helper
helper: $(BUILD)/scope-helper $(BUILD)/helper
	@$(BUILD)/helper "$(CURDIR)/$(BUILD)/scope-helper" "$${TMPDIR:-/tmp}"

# The seed maker's checks, written in Herbert (checks/seeds.herb). The committed
# seed builds the seed maker, the check runner, the check and a stand-in
# compiler; the check runs the seed maker on small checkouts of its own, in a
# folder it makes under the one given here and takes away again when every
# check passes, and never writes in this checkout. VERIFYING.md says what it
# holds the seed maker to.
.PHONY: seeds
seeds: $(BUILD)/seeds $(BUILD)/reseed $(BUILD)/run $(BUILD)/seed-stand-in
	@$(BUILD)/seeds "$(CURDIR)/$(BUILD)/reseed" "$(CURDIR)/$(BUILD)/run" "$(CURDIR)/$(BUILD)/seed-stand-in" "$(CURDIR)" "$${TMPDIR:-/tmp}"

# The compiler's command-line checks, written in Herbert (checks/cli.herb).
# The committed seed builds the check and the runner. The check starts the
# compiler (a copy of the seed, or COMPILER=/absolute/path) itself, in each
# state the runner never sets up: an old a.out, a link or a folder in its
# place, standard input closed, a folder or a pipe, standard output closed or
# full, a folder it cannot read or write in, a file-size or memory limit. It
# also runs the runner over planted cases with a stand-in compiler (the check
# itself, run with no arguments). It works in a folder it makes under the one
# given here and removes it when every check passes. About a minute: one
# planted compile waits out the runner's 60 seconds. VERIFYING.md says what
# it holds the compiler to.
.PHONY: cli
cli: $(BUILD)/cli $(BUILD)/run
	@cd bootstrap/seed && sha256sum -c --quiet gen1.seed.sha256
	@cp bootstrap/seed/gen1.seed $(BUILD)/cli-seed && chmod u+x $(BUILD)/cli-seed
	@$(BUILD)/cli "$${COMPILER:-$(CURDIR)/$(BUILD)/cli-seed}" "$(CURDIR)/$(BUILD)/run" "$(CURDIR)" "$${TMPDIR:-/tmp}"

# Developer builds use the same committed compiler; support units are ordered
# source concatenation, not an external linker. Values travel via environment
# variables so source/output paths with spaces never become shell syntax.
.PHONY: program
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

# Native Linux desktop checkpoint. These .herb library units are concatenated
# as source, then compiled ONLY by the committed Herbert seed. No host compiler,
# graphics library, runtime, or launcher is linked into the resulting executable.
DESKTOP_LIBS := lib/linux.herb lib/x11.herb lib/pixel_text.herb
first-steps_SOURCES := $(DESKTOP_LIBS) examples/first_steps.herb
maze_SOURCES := $(DESKTOP_LIBS) lib/grid_map.herb examples/maze.herb
notes_SOURCES := $(DESKTOP_LIBS) lib/x11_clipboard.herb lib/utf8.herb lib/unicode_tables.herb lib/unicode_grapheme.herb lib/unicode_display.herb lib/file_io.herb lib/text_buffer.herb lib/session_recovery.herb examples/notes.herb
scope_SOURCES := $(DESKTOP_LIBS) lib/text.herb lib/net.herb lib/figures.herb examples/scope.herb
scope-helper_SOURCES := lib/linux.herb lib/text.herb lib/net.herb lib/figures.herb examples/scope_helper.herb
knock_SOURCES := lib/linux.herb lib/text.herb lib/net.herb examples/knock.herb
hands_SOURCES := lib/linux.herb lib/text.herb lib/x11.herb checks/hands.herb
stand-in_SOURCES := lib/linux.herb lib/x11.herb checks/stand_in.herb
SEED_LIBS := lib/linux.herb lib/text.herb lib/sha256.herb lib/folder.herb lib/child.herb
run_SOURCES := lib/linux.herb lib/text.herb checks/run.herb
reseed_SOURCES := $(SEED_LIBS) tools/reseed.herb
seeds_SOURCES := $(SEED_LIBS) checks/seeds.herb
seed-stand-in_SOURCES := lib/linux.herb checks/seed_stand_in.herb
cli_SOURCES := lib/linux.herb lib/text.herb lib/folder.herb checks/cli.herb
helper_SOURCES := lib/linux.herb lib/text.herb lib/net.herb lib/figures.herb lib/fault.herb checks/helper.herb
.PHONY: first-steps maze notes scope scope-helper knock hosted-apps
first-steps: $(BUILD)/first-steps
maze: $(BUILD)/maze
notes: $(BUILD)/notes
scope: $(BUILD)/scope
scope-helper: $(BUILD)/scope-helper
knock: $(BUILD)/knock
hosted-apps: first-steps maze notes scope scope-helper knock

$(BUILD)/first-steps: $(first-steps_SOURCES)
$(BUILD)/maze: $(maze_SOURCES)
$(BUILD)/notes: $(notes_SOURCES)
$(BUILD)/scope: $(scope_SOURCES)
$(BUILD)/scope-helper: $(scope-helper_SOURCES)
$(BUILD)/knock: $(knock_SOURCES)
$(BUILD)/hands: $(hands_SOURCES)
$(BUILD)/stand-in: $(stand-in_SOURCES)
$(BUILD)/run: $(run_SOURCES)
$(BUILD)/reseed: $(reseed_SOURCES)
$(BUILD)/seeds: $(seeds_SOURCES)
$(BUILD)/seed-stand-in: $(seed-stand-in_SOURCES)
$(BUILD)/cli: $(cli_SOURCES)
$(BUILD)/helper: $(helper_SOURCES)
$(BUILD)/scans: $(scans_SOURCES)
$(SCANNER): $(scan_SOURCES)
$(BUILD)/first-steps $(BUILD)/maze $(BUILD)/notes $(BUILD)/scope $(BUILD)/scope-helper $(BUILD)/knock $(BUILD)/hands $(BUILD)/stand-in $(BUILD)/run $(BUILD)/reseed $(BUILD)/seeds $(BUILD)/seed-stand-in $(BUILD)/cli $(BUILD)/helper $(BUILD)/scans $(SCANNER): bootstrap/seed/gen1.seed bootstrap/seed/gen1.seed.sha256
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

# One authoring location per stage; the tracked assembled file is what the
# seed maker, make answers and make cli compile as the compiler's source.
COMPILER_SOURCES := stack/compiler/frontend_vm.herb \
                    stack/compiler/types_and_inference.herb \
                    stack/compiler/metadata.herb \
                    stack/compiler/hosted_emitter.herb \
                    stack/compiler/routes.herb \
                    stack/compiler/driver.herb
.PHONY: compiler-source compiler-source-check compiler-source-membership
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

# reseed: make the seed again after the compiler's source changed. The seed maker
# is the Herbert program tools/reseed.herb, built like the check runner by the
# committed seed. It has that seed build the new compiler, requires the new
# compiler to rebuild itself byte for byte and to give its answer to every case
# of make answers outside checks/rebuild.cases (whose one case, building the
# committed seed, a new compiler cannot pass), and only then replaces the seed
# and its checksum.
# bootstrap/seed/README.md says when to run it; make verify-local follows it.
reseed: compiler-source-check $(BUILD)/reseed $(BUILD)/run
	@$(BUILD)/reseed "$(CURDIR)" "$(CURDIR)/$(BUILD)/run" "$${TMPDIR:-/tmp}" $(addprefix $(CURDIR)/,$(filter-out checks/rebuild.cases,$(ANSWERS)))

# Every check, all written in Herbert; VERIFYING.md says what each holds.
verify-local: check answers cli hands seeds helper

clean:
	rm -rf $(BUILD)
