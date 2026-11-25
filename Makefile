# The one entry point. On Ulisses: make <target> (settings/deucalion.env). On the Mac, the testbed:
# make testbed-<target>. 'make' lists the targets; docs/operations.md explains them.
#
# Every site target runs 'lisa <command>' (cli/lisa, Python) with uv, which brings the pinned Python
# dependencies (uv.lock) without root. If uv is not installed, it is fetched into LISA_HOME/bin.
SITE ?= deucalion
SETTINGS ?= settings/$(SITE).env
LISA_HOME ?= $(HOME)/lisa-runner
UV_VERSION := 0.13.7
UV ?= $(shell command -v uv 2>/dev/null || echo $(LISA_HOME)/bin/uv)
# uv copies packages from its cache into .venv instead of cloning or hard-linking them: on Ulisses's home
# file system cloning fails ("Failed to clone ... Resource temporarily unavailable").
export UV_LINK_MODE ?= copy
LISA =$(UV) run --frozen --quiet lisa --settings $(SETTINGS)
T ?=
A ?= status
.DEFAULT_GOAL := help

help: ## List the targets
	@echo "Usage: make <target>   (SITE=testbed for the testbed's settings; T=\"00 11\" selects tests)"
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

uv: # uv, if missing
	@[ -x "$(UV)" ] || bash cli/get-uv.sh "$(LISA_HOME)/bin" "$(UV_VERSION)"

##@ A site (Ulisses -> Deucalion): in this order
settings: ## The settings file from its example, to fill in (settings/$(SITE).env)
	@[ -f $(SETTINGS) ] || { cp settings/$(SITE).env.example $(SETTINGS) && chmod 600 $(SETTINGS); }
	@echo "now fill it in: vi $(SETTINGS)"

setup: uv ## Once: Argo if missing, the MinIO, interLink, the sidecar on the login node
	$(LISA) setup

check: uv ## Read-only checks of both sides and a compute node (output kept in results/)
	$(LISA) check

up: uv ## Both sides up: sidecar, interLink with the reverse tunnel, artifacts, offload
	$(LISA) up

test: uv ## Run the tests (T="00 11" for some; TIMEOUT=3600 for longer ones); report in results/<run>/report.md
	$(LISA) test $(T) $(if $(TIMEOUT),--timeout $(TIMEOUT))

evidence: uv ## Configuration, versions, logs and Slurm's record of the last run (RUN=<folder> for another)
	$(LISA) evidence $(RUN)

restore: uv ## Everything off: test workflows, offload, interLink, the sidecar, the virtual node
	$(LISA) restore

results: ## results/ packed into ~/results.tgz, to copy home
	tar -czf "$$HOME/results.tgz" results && echo "$$HOME/results.tgz"

##@ Looking and fixing
status: uv ## What runs on both sides
	$(LISA) status

diag: uv ## interLink's processes and logs, the shadow pods
	$(LISA) diag

progress: uv ## The workflows running: each step, its times, phase and Slurm job (watch -n 30 make -s progress)
	$(LISA) progress

down: uv ## Offload off and interLink stopped (the sidecar keeps running)
	$(LISA) down

clean: uv ## Delete the test workflows (interLink removes their job folders)
	$(LISA) clean

sync: uv ## Copy hpc.sh and the sidecar's files to the login node (up and check do it too)
	$(LISA) sync

hpc: uv ## hpc.sh on the login node: make hpc A=images | A=status | A=jobs
	$(LISA) hpc $(A)

login: uv ## A shell on the login node
	$(LISA) login

minio minio-off: uv ## A MinIO in the cluster as the Global Storage (GS_ENDPOINT=cluster) / remove it
	$(LISA) minio $(if $(findstring off,$@),off,on)

mirror mirror-off: uv ## The image mirror (IMAGE_MIRROR=on; 'up' starts it) / remove it
	$(LISA) mirror $(if $(findstring off,$@),off,on)

cnes: uv ## CNES's templates from ~/cnes, to run them by hand (Argo's UI); INPUTS="asterix" also makes inputs
	$(LISA) cnes $(INPUTS)

##@ The testbed (on the Mac: Lima VMs cn, login, ulisses; testbed/README.md)
TESTBED_DIR ?= $(CURDIR)/testbed
LPR_DIR ?= $(abspath $(CURDIR)/../lisa-pipeline-runner)
export TESTBED_DIR LPR_DIR
export ZE_DIR := $(CURDIR)
TB := bash $(TESTBED_DIR)/testbed

testbed-init: testbed-vms ## VMs (first time about an hour), the trial user, this repository there, 'make setup'
	$(TB) trial setup
	@echo "==> Next: make testbed-test T=\"00 11\""

testbed-vms: # build what is missing, start what is stopped
	@command -v limactl >/dev/null || { echo "limactl not found (brew install lima)"; exit 1; }
	@vms="$$(limactl list -q 2>/dev/null)"; \
	if echo "$$vms" | grep -qx tb-cn && echo "$$vms" | grep -qx tb-login && echo "$$vms" | grep -qx tb-ulisses; then \
	  $(TB) start; \
	else \
	  if ! { echo "$$vms" | grep -qx tb-cn && echo "$$vms" | grep -qx tb-login; }; then $(TB) up; fi; \
	  $(TB) up-b; \
	fi

testbed-test: ## 'make up', then the tests, as the trial user on the testbed
	$(TB) trial make up
	$(TB) trial make test T="$(T)"

testbed: ## Any site target on the testbed: make testbed A=evidence | A=restore | A=status
	$(TB) trial make $(A)

testbed-check: ## Fidelity checks of the testbed itself
	$(TB) check

testbed-start testbed-stop testbed-status testbed-clean: ## Start / stop the VMs, their status, clean what tests left
	$(TB) $(subst testbed-,,$@)

testbed-destroy: ## Delete the VMs and their state ('make testbed-init' rebuilds from zero)
	$(TB) destroy

testbed-shell: ## A shell on a VM: make testbed-shell VM=login|cn|ulisses (ROOT=1 as root)
	$(TB) shell $(VM) $(if $(ROOT),--root)

testbed-net: ## The compute node's network: make testbed-net N=normal (offline) | N=dev | N=status
	$(TB) net $(N)

##@ Development (on any machine with uv)
lint: uv ## ruff on cli/, shellcheck on the shell scripts if installed
	$(UV) run --frozen ruff check cli
	@command -v shellcheck >/dev/null && shellcheck cli/*.sh runner/hpc/resources.sh runner/hpc/subpath-fix/sbatch || true

unit: uv ## The tool's own tests (cli/tests): no cluster needed
	$(UV) run --frozen pytest -q

.PHONY: help uv settings setup check up test evidence restore results status diag progress down clean sync hpc login \
        minio minio-off mirror mirror-off cnes testbed-init testbed-vms testbed-test testbed testbed-check \
        testbed-start testbed-stop testbed-status testbed-clean testbed-destroy testbed-shell testbed-net lint unit
