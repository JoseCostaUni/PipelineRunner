# One entry point for the testbed (Lima VMs: cn, login, ulisses) and the two ways of running
# plain Argo workflows on it. Run 'make' to list the targets.
#
#   make init-old     testbed with interLink 0.6.1 (Isabel's setup) -> tests use the split executor
#   make init-new     testbed with interLink 0.6.3 + reverse tunnel  -> tests use no wrapper scripts
#   make test         run the tests that match what is active (TESTS="00 05" for a subset)
#   make clean-all    delete the VMs and their state, to start from zero
#
# This file covers everything testbed/makefile does, so that one can be deleted.

TESTBED_DIR ?= $(CURDIR)/testbed
# Isabel Moutinho's repository (needed only to build the ulisses VM).
LPR_DIR ?= $(abspath $(CURDIR)/../lisa-pipeline-runner)
ZE_DIR := $(CURDIR)
export TESTBED_DIR LPR_DIR ZE_DIR

TB := bash $(TESTBED_DIR)/testbed
RT := bash $(CURDIR)/experiments/reverse-tunnel/run.sh
LOGS := $(TESTBED_DIR)/logs
RESULTS := $(CURDIR)/experiments/reverse-tunnel/results
# TESTS="00 05" runs a subset; empty runs all.
TESTS ?=
MODES ?= dev normal normal-images

.DEFAULT_GOAL := help

help: ## List the targets
	@echo "Usage: make <target>   (TESTS=\"00 05\" selects tests)"
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

##@ Set up (builds the VMs the first time, about 30 min; afterwards just starts them)
init-old: vms ## Testbed with interLink 0.6.1 (Isabel's setup; tests use the split executor)
	$(RT) disable
	@echo "==> active interLink: $$($(RT) version). Next: make test"

init-new: vms ## Testbed with interLink 0.6.3 and the reverse tunnel (no wrapper scripts)
	$(RT) install
	$(RT) enable
	@echo "==> active interLink: $$($(RT) version). Next: make test TESTS=00"

vms: # build what is missing, start what is stopped
	@command -v limactl >/dev/null || { echo "limactl not found (brew install lima)"; exit 1; }
	@vms="$$(limactl list -q 2>/dev/null)"; \
	if echo "$$vms" | grep -qx tb-cn && echo "$$vms" | grep -qx tb-login && echo "$$vms" | grep -qx tb-ulisses; then \
	  $(TB) start; \
	else \
	  if ! { echo "$$vms" | grep -qx tb-cn && echo "$$vms" | grep -qx tb-login; }; then $(TB) up; fi; \
	  $(TB) up-b; \
	fi

version: ## Which interLink is active (0.6.1 or 0.6.3)
	@$(RT) version

##@ Tests (compute node offline; one at a time)
test: ## Run the tests for the active interLink (test-old or test-new)
	@v="$$($(RT) version)" || exit 1; \
	if [ "$$v" = 0.6.1 ]; then $(MAKE) --no-print-directory test-old; else $(MAKE) --no-print-directory test-new; fi

test-old: ## 0.6.1 + split executor (sbatch/squeue/scancel wrappers); report in testbed/logs/t1-*
	@[ "$$($(RT) version)" = 0.6.1 ] || { echo "interLink 0.6.3 is active: run 'make init-old' first"; exit 1; }
	$(if $(TESTS),T1_TESTS="$(TESTS)") $(TB) t1 normal-images

test-new: ## 0.6.3 + reverse tunnel; results in experiments/reverse-tunnel/results/
	$(RT) test $(TESTS)

test-check: ## Fidelity checks of the testbed itself
	$(TB) check

test-t0: ## Isabel's own tests TC01-TC10 (needs init-old; MODES="dev normal normal-images")
	@[ "$$($(RT) version)" = 0.6.1 ] || { echo "interLink 0.6.3 is active: run 'make init-old' first"; exit 1; }
	$(TB) t0 $(MODES)

##@ Shells
ssh-login: ## Login node, as lisa (the HPC user)
	$(TB) shell login

ssh-login-root: ## Login node, as root
	$(TB) shell login --root

ssh-compute: ## Compute node, as lisa
	$(TB) shell cn

ssh-compute-root: ## Compute node, as root
	$(TB) shell cn --root

ssh-ulisses: ## Ulisses, as root (kubectl, argo, mc, journalctl -u interlink-*)
	$(TB) shell ulisses

##@ VMs
start: ## Start the VMs (after a reboot or 'make stop'); keeps whichever interLink was active
	$(TB) start

stop: ## Stop the VMs (frees the RAM; nothing is lost)
	$(TB) stop

status: ## VMs, compute node network mode, virtual node, active interLink
	@$(TB) status
	@echo "active interLink: $$($(RT) version 2>/dev/null || echo unknown)"

net-dev: ## Compute node WITH internet (like Deucalion dev-* partitions)
	$(TB) net dev

net-normal: ## Compute node WITHOUT internet (like Deucalion normal-* partitions)
	$(TB) net normal

net-status: ## Compute node network mode and firewall rules
	$(TB) net status

##@ Results and diagnostics
report: ## Latest result of each kind of test
	@d=$$(ls -1dt $(LOGS)/t1-* 2>/dev/null | head -n 1); echo "== old (split executor): $${d:-none}"; \
	 [ -n "$$d" ] && cat "$$d/report.md" 2>/dev/null || true
	@d=$$(ls -1dt $(RESULTS)/*/ 2>/dev/null | head -n 1); echo "== new (reverse tunnel): $${d:-none}"; \
	 [ -n "$$d" ] && cat "$$d/summary.txt" 2>/dev/null || true

diag: ## Diagnose the interLink chain (shadow pods and tunnel too, when 0.6.3 is active)
	$(TB) diag
	@if [ "$$($(RT) version)" != 0.6.1 ]; then $(RT) diag; fi

##@ Clean up
clean: ## Remove what tests left in the VMs (jobs, data, images, caches); keeps the VMs
	$(TB) clean

clean-all: ## Delete the VMs and their generated state; 'make init-*' rebuilds from zero
	$(TB) destroy

.PHONY: help init-old init-new vms version test test-old test-new test-check test-t0 ssh-login \
        ssh-login-root ssh-compute ssh-compute-root ssh-ulisses start stop status net-dev \
        net-normal net-status report diag clean clean-all
