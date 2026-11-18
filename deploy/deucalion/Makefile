# Deucalion trial from Ulisses, as root (sudo -i), in this folder. Steps: ../../RUN_ON_ULISSES.md
#   make env              first time: deucalion.env from the example (then fill in the MinIO keys)
#   make tools            argo (CLI) and mc into ../../bin, if Ulisses has none (nothing installed system-wide)
#   make sync             copy this repository to the login node (again after any change)
#   make check            read-only checks of both sides and a compute node, kept in results/
#   make reverse | split  switch both sides to that mode
#   make test [T=00]      run the tests (default: all) in the mode that is on
#   make status | diag | clean
#   make restore          clean, then both sides as before the trial
#   make results          results.tgz in your home, to copy to the Mac
#   make login            a shell on the login node, in this folder
# ENV_FILE=testbed.env runs the same on the testbed.
SHELL := /bin/bash
ENV_FILE ?= deucalion.env
ROOT := $(abspath ../..)
# 'make tools' puts argo and mc here; every target finds them first.
BIN := $(ROOT)/bin
export PATH := $(BIN):$(PATH)
# mc from the pgsty fork: dl.min.io no longer serves it (HTTP 410). Ulisses is x86_64.
MC_URL := https://github.com/pgsty/mc/releases/download/RELEASE.2026-11-12T00-00-00Z/mcli_20261112000000.0.0_linux_amd64.tar.gz
K := SPLIT_ENV=$(abspath $(ENV_FILE)) ./k8s-side.sh
# Same login-node host key file as k8s-side.sh.
ENV := mkdir -p /var/lib/split-executor && source ./$(ENV_FILE) &&
SSHO := -i "$$SSH_KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/lib/split-executor/known_hosts
hpc = $(ENV) ssh $(SSHO) "$$HPC_USER@$$HPC_LOGIN_HOST" \
  "SPLIT_ENV='$$HPC_REPO_DIR/deploy/deucalion/$(ENV_FILE)' bash -l '$$HPC_REPO_DIR/deploy/deucalion/hpc-side.sh' $(1)"

.PHONY: env tools sync check reverse split test status diag clean restore results login

env:
	[ -f $(ENV_FILE) ] || { cp deucalion.env.example $(ENV_FILE) && chmod 600 $(ENV_FILE); }
	@echo "now fill in GS_ACCESS_KEY and GS_SECRET_KEY: vi $(ENV_FILE)"

# argo: the version of the Argo controller (the tag of its argoexec image).
tools:
	mkdir -p $(BIN)
	command -v argo || { v="$$($(K) executor-image)"; v="$${v##*:}"; \
	  curl -fsSL "https://github.com/argoproj/argo-workflows/releases/download/$$v/argo-linux-amd64.gz" | gunzip >$(BIN)/argo \
	  && chmod +x $(BIN)/argo; }
	command -v mc || { curl -fsSL "$(MC_URL)" | tar -xzO mcli >$(BIN)/mc && chmod +x $(BIN)/mc; }
	argo version --short
	mc --version | head -n 1

sync:
	$(ENV) tar -C $(ROOT) --exclude=./deploy/deucalion/results --exclude=./bin -cz . \
	  | ssh $(SSHO) "$$HPC_USER@$$HPC_LOGIN_HOST" "mkdir -p '$$HPC_REPO_DIR' && tar -xz -C '$$HPC_REPO_DIR'"
	$(call hpc,mode)

check:
	mkdir -p results
	$(K) check | tee results/check-k8s.txt
	$(call hpc,check) | tee results/check-hpc.txt
	$(call hpc,probe-compute) | tee results/probe-compute.txt

reverse split:
	$(K) mode $@

test:
	$(K) test $(T)

status diag clean:
	$(K) $@

restore:
	$(K) clean
	$(K) restore
	$(K) status

results:
	h="$$(getent passwd "$${SUDO_USER:?run make from sudo -i}" | cut -d: -f6)" \
	  && tar -czf "$$h/results.tgz" results && chown "$$SUDO_USER" "$$h/results.tgz" && echo "$$h/results.tgz"

login:
	$(ENV) ssh -t $(SSHO) "$$HPC_USER@$$HPC_LOGIN_HOST" "cd '$$HPC_REPO_DIR/deploy/deucalion' && exec bash -l"
