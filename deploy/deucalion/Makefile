# Plain Argo workflows on Deucalion's offline compute nodes, from Ulisses, as your own user (no sudo),
# in this folder. Steps: ../../RUN_ON_ULISSES.md
#   make env              first time: deucalion.env from the example (then fill it in)
#   make setup            once: Argo (if the cluster has none), the MinIO (GS_ENDPOINT=cluster), argo + mc,
#                         interLink 0.6.3, the scripts on the login node, the sidecar there
#   make sync             copy the scripts and the settings to the login node again (after a change)
#   make check            read-only checks of both sides and a compute node, kept in results/
#   make up               both sides up: sidecar, interLink with the reverse tunnel, artifacts, offload
#   make test [T=00]      run the tests (default: all)
#   make evidence [RUN=<results folder>]  configuration, versions, logs (secrets blanked) and Slurm's
#                         record of a run (default: the last) into results/<run>/evidence
#   make status | diag | clean | down
#   make restore          clean, down, the sidecar stopped, the virtual node deleted
#   make minio, minio-off with GS_ENDPOINT=cluster: a MinIO in the cluster as the Global Storage
#   make results          results.tgz in your home folder, to copy to the Mac
#   make login            a shell on the login node, in this folder
# Every target calls k8s-side.sh, which runs hpc-side.sh on the login node when needed.
# ENV_FILE=testbed.env runs the same on the testbed.
SHELL := /bin/bash
ENV_FILE ?= deucalion.env
K := TRIAL_ENV=$(abspath $(ENV_FILE)) ./k8s-side.sh

.PHONY: env setup sync check up down test status diag clean restore results login minio minio-off evidence

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

up down status diag clean:
	$(K) $@

test:
	$(K) test $(T)

restore:
	$(K) restore
	$(K) status

evidence:
	$(K) evidence $(RUN)

results:
	tar -czf "$$HOME/results.tgz" results && echo "$$HOME/results.tgz"

login:
	$(K) login

minio:
	$(K) minio on

minio-off:
	$(K) minio off
