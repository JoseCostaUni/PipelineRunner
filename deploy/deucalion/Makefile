# Deucalion trial from Ulisses, as your own user (no sudo), in this folder. Steps: ../../RUN_ON_ULISSES.md
#   make env              first time: deucalion.env from the example (then fill it in)
#   make setup            once: Argo (if the cluster has none), the MinIO (GS_ENDPOINT=cluster), argo + mc,
#                         interLink 0.6.1 and 0.6.3, the scripts on the login node, the sidecar there
#   make sync             copy the scripts and the settings to the login node again (after a change)
#   make minio, minio-off with GS_ENDPOINT=cluster: a MinIO in the cluster as the Global Storage (reverse only)
#   make check            read-only checks of both sides and a compute node, kept in results/
#   make reverse | split  switch both sides to that mode
#   make test [T=00]      run the tests (default: all) in the mode that is on
#   make status | diag | clean
#   make restore          clean, then both sides off: offload off, sidecar and interLink stopped, node deleted
#   make evidence [RUN=<results folder>]  configuration, versions, logs (secrets blanked) and Slurm's
#                         record of a run (default: the last) into results/<run>/evidence
#   make results          results.tgz in your home folder, to copy to the Mac
#   make login            a shell on the login node, in this folder
# Every target calls k8s-side.sh, which runs hpc-side.sh on the login node when needed.
# ENV_FILE=testbed.env runs the same on the testbed.
SHELL := /bin/bash
ENV_FILE ?= deucalion.env
K := SPLIT_ENV=$(abspath $(ENV_FILE)) ./k8s-side.sh

.PHONY: env setup sync check reverse split test status diag clean restore results login minio minio-off evidence

env:
	[ -f $(ENV_FILE) ] || { cp deucalion.env.example $(ENV_FILE) && chmod 600 $(ENV_FILE); }
	@echo "now fill it in: vi $(ENV_FILE)"

setup:
	$(K) argo
	if grep -q '^GS_ENDPOINT=cluster' $(ENV_FILE); then $(K) minio on; fi
	$(K) tools
	$(K) install
	$(K) sync
	$(K) hpc install

sync:
	$(K) sync

check:
	mkdir -p results
	$(K) check | tee results/check-k8s.txt
	$(K) hpc check | tee results/check-hpc.txt
	$(K) hpc probe-compute | tee results/probe-compute.txt

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
	tar -czf "$$HOME/results.tgz" results && echo "$$HOME/results.tgz"

login:
	$(K) login

minio:
	$(K) minio on

minio-off:
	$(K) minio off

evidence:
	$(K) evidence $(RUN)
