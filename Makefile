# One entry point for the testbed (Lima VMs: cn, login, ulisses): plain Argo workflows on its offline
# compute node through interLink 0.6.3 and its reverse tunnel, run with the same scripts as on
# Deucalion (deploy/deucalion), as a user without root. Run 'make' to list the targets.
#
#   make init         build the VMs if needed, set up the trial user and 'make setup' as that user
#   make test         'make up' and the tests as that user (TESTS="00 11" for a subset)
#   make trial T=...  any target of deploy/deucalion/Makefile as that user (T="evidence", T="restore")
#   make clean-all    delete the VMs and their state, to start from zero
#
# The testbed's cluster is built with Isabel Moutinho's setup scripts, from her repository next to this
# one. The split executor (interLink 0.6.1) is in the tag split-interlink-0.6.1.
TESTBED_DIR ?= $(CURDIR)/testbed
# Isabel Moutinho's repository (needed only to build the ulisses VM).
LPR_DIR ?= $(abspath $(CURDIR)/../lisa-pipeline-runner)
ZE_DIR := $(CURDIR)
export TESTBED_DIR LPR_DIR ZE_DIR
TB := bash $(TESTBED_DIR)/testbed
# TESTS="00 05" runs a subset; empty runs all.
TESTS ?=
T ?= status
.DEFAULT_GOAL := help

help: ## List the targets
	@echo "Usage: make <target>   (TESTS=\"00 05\" selects tests)"
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

##@ Set up (builds the VMs the first time, about 30 min; afterwards just starts them)
init: vms ## VMs, the trial user (no root, cluster-admin), this repository in its home, 'make setup'
	$(TB) trial setup
	@echo "==> Next: make test TESTS=\"00 11\""

vms: # build what is missing, start what is stopped
	@command -v limactl >/dev/null || { echo "limactl not found (brew install lima)"; exit 1; }
	@vms="$$(limactl list -q 2>/dev/null)"; \
	if echo "$$vms" | grep -qx tb-cn && echo "$$vms" | grep -qx tb-login && echo "$$vms" | grep -qx tb-ulisses; then \
	  $(TB) start; \
	else \
	  if ! { echo "$$vms" | grep -qx tb-cn && echo "$$vms" | grep -qx tb-login; }; then $(TB) up; fi; \
	  $(TB) up-b; \
	fi

##@ Tests (compute node offline; as the trial user, with deploy/deucalion)
test: ## 'make up', then the tests; results in the trial user's deploy/deucalion/results/
	$(TB) trial make up
	$(TB) trial make test T="$(TESTS)"

trial: ## Any target of deploy/deucalion/Makefile as the trial user: make trial T=evidence | T=restore | T=status
	$(TB) trial make $(T)

test-check: ## Fidelity checks of the testbed itself
	$(TB) check

##@ Shells
ssh-login: ## Login node, as lisa (the HPC user)
	$(TB) shell login

ssh-login-root: ## Login node, as root
	$(TB) shell login --root

ssh-compute: ## Compute node, as lisa
	$(TB) shell cn

ssh-compute-root: ## Compute node, as root
	$(TB) shell cn --root

ssh-ulisses: ## Ulisses, as root (kubectl, argo, mc)
	$(TB) shell ulisses

##@ VMs
start: ## Start the VMs (after a reboot or 'make stop'); then 'make test' brings interLink up again
	$(TB) start

stop: ## Stop the VMs (frees the RAM; nothing is lost)
	$(TB) stop

status: ## VMs, compute node network mode, and the trial's status on both sides
	@$(TB) status
	@$(TB) trial make status 2>/dev/null || true

net-dev: ## Compute node WITH internet (like Deucalion dev-* partitions)
	$(TB) net dev

net-normal: ## Compute node WITHOUT internet (like Deucalion normal-* partitions)
	$(TB) net normal

net-status: ## Compute node network mode and firewall rules
	$(TB) net status

##@ Diagnostics and clean up
diag: ## interLink's processes and logs, the shadow pods (as the trial user)
	$(TB) trial make diag

clean: ## Remove what tests left in the VMs (jobs, data, images, caches); keeps the VMs
	$(TB) clean

clean-all: ## Delete the VMs and their generated state; 'make init' rebuilds from zero
	$(TB) destroy

.PHONY: help init vms test trial test-check ssh-login ssh-login-root ssh-compute ssh-compute-root \
        ssh-ulisses start stop status net-dev net-normal net-status diag clean clean-all
