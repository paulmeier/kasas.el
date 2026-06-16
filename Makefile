# Makefile for kasas.el
#
# Dependency-light: every target shells out to `emacs --batch`, so the only
# requirement is an Emacs (>= 27.1) on PATH. `make help` lists the targets.

EMACS ?= emacs
# Source files, in dependency order (kasas.el first; it provides the core).
SRC = kasas.el kasas-accounts.el kasas-transactions.el kasas-events.el \
      kasas-plot.el
TESTS = test/kasas-test.el
ELC = $(SRC:.el=.elc)

# Load the project root so (require 'kasas...) resolves during batch runs.
LOADPATH = -L . -L test
BATCH = $(EMACS) -Q --batch $(LOADPATH)

.PHONY: all
all: compile test ## Compile and run the test suite

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: compile
compile: ## Byte-compile all sources, treating warnings as errors
	$(BATCH) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)

.PHONY: test
test: ## Run the ERT test suite
	$(BATCH) \
	  $(foreach f,$(SRC),--eval '(load (expand-file-name "$(f)") nil t)') \
	  -l test/kasas-test.el \
	  -f ert-run-tests-batch-and-exit

.PHONY: checkdoc
checkdoc: ## Check docstring conventions
	$(BATCH) -l test/checkdoc-batch.el $(SRC)

.PHONY: lint
lint: ## Run package-lint (installs it from MELPA if missing)
	$(BATCH) -l test/package-lint-batch.el $(SRC)

.PHONY: clean
clean: ## Remove byte-compiled files
	rm -f $(ELC) test/*.elc
