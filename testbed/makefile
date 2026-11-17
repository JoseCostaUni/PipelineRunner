# Shortcuts for the testbed. Run 'make' (or 'make help') to list them.
# Names are grouped by prefix: vm-* (the VMs), net-* (compute node network), ssh-* (shells),
# test-* (checks and tests), report-* (results). Everything goes through ./testbed.

TB := bash ./testbed
MODES ?= dev normal normal-images
T1_MODES ?= normal-images

.DEFAULT_GOAL := help

help: ## List the targets
	@echo "Testbed (Deucalion-like HPC on Lima). Usage: make <target>"
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

##@ VMs: build
vm-build: ## Stage A: build the login and compute node VMs
	$(TB) up

vm-build-ulisses: ## Stage B: add ulisses (Kubernetes, Argo, interLink, MinIO) with Isabel's scripts
	$(TB) up-b

##@ VMs: run
vm-start: ## Start all VMs (after a reboot or vm-stop)
	$(TB) start

vm-stop: ## Stop all VMs (frees the RAM; nothing is lost)
	$(TB) stop

vm-status: ## Show the VMs, the compute node's network mode and the virtual node
	$(TB) status

vm-list: ## All Lima VMs on this Mac (limactl list; Colima's live elsewhere)
	limactl list

##@ VMs: clean up
vm-clean: ## Remove what tests/checks left in the VMs (jobs, data, images, caches); keeps VMs and logs/
	$(TB) clean

vm-remove: ## Delete the VMs (keeps keys, Slurm build cache, logs/); rebuild with vm-build + vm-build-ulisses
	$(TB) remove

vm-destroy: ## Delete the VMs and all generated state (keys, VM configs); keeps cache/ and logs/
	$(TB) destroy

##@ Compute node network
net-dev: ## Compute node WITH internet (like Deucalion dev-* partitions)
	$(TB) net dev

net-normal: ## Compute node WITHOUT internet (like Deucalion normal-* partitions)
	$(TB) net normal

net-status: ## Show the compute node's network mode and firewall rules
	$(TB) net status

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

##@ Tests (one at a time: each switches the compute node's network)
test-check: ## Fidelity checks of the testbed (report in logs/check-*.md)
	$(TB) check

test-t0: ## T0: Isabel's tests TC01-TC10 in all modes (MODES="dev normal normal-images"; 1-1.5 h)
	$(TB) t0 $(MODES)

test-t0-dev: ## T0 with the compute node online only (baseline, about 20 min)
	$(TB) t0 dev

test-t0-normal: ## T0 with the compute node offline only (normal and normal-images)
	$(TB) t0 normal normal-images

test-t1: ## T1: plain Argo workflows (TC00 + Isabel's tests) with the split executor, compute offline (~25 min)
	$(TB) t1 $(T1_MODES)

##@ Results and diagnostics
report-check: ## Print the latest fidelity check report
	@f=$$(ls -1t logs/check-*.md 2>/dev/null | head -n 1); [ -n "$$f" ] && cat "$$f" || echo "no check report yet"

report-t0: ## Print the latest T0 report
	@d=$$(ls -1dt logs/t0-* 2>/dev/null | head -n 1); [ -n "$$d" ] && cat "$$d/report.md" 2>/dev/null || echo "no T0 report yet"

report-t1: ## Print the latest T1 report
	@d=$$(ls -1dt logs/t1-* 2>/dev/null | head -n 1); [ -n "$$d" ] && cat "$$d/report.md" 2>/dev/null || echo "no T1 report yet"

report-list: ## List the most recent logs and reports
	@ls -1t logs 2>/dev/null | head -n 15 || echo "no logs yet"

diag-interlink: ## Diagnose the interLink chain: VK, API, tunnel, sidecar (logs/diag-*.txt)
	$(TB) diag

# Old names, kept so older notes and commands still work (not listed in help).
up: vm-build
up-b: vm-build-ulisses
start: vm-start
stop: vm-stop
status: vm-status
clean: vm-clean
remove: vm-remove
down: vm-remove
destroy: vm-destroy
check: test-check
t0: test-t0
t0-dev: test-t0-dev
t0-normal: test-t0-normal
login: ssh-login
root-login: ssh-login-root
cn: ssh-compute
root-cn: ssh-compute-root
ulisses: ssh-ulisses
logs: report-list
last-check: report-check
last-t0: report-t0
diag: diag-interlink
lima-list: vm-list

.PHONY: help vm-build vm-build-ulisses vm-start vm-stop vm-status vm-list vm-clean vm-remove \
        vm-destroy net-dev net-normal net-status ssh-login ssh-login-root ssh-compute \
        ssh-compute-root ssh-ulisses test-check test-t0 test-t0-dev test-t0-normal test-t1 report-check \
        report-t0 report-t1 report-list diag-interlink up up-b start stop status clean remove down destroy \
        check t0 t0-dev t0-normal login root-login cn root-cn ulisses logs last-check last-t0 diag \
        lima-list
