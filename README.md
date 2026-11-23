# LISA Pipeline Runner

A setup and testing framework for the LISA pipeline infrastructure, supporting Kubernetes, HPC, and cloud storage configurations.

## Overview

This repository provides automated setup scripts and test utilities for deploying and validating the LISA pipeline across different infrastructure environments. It is a fork of Isabel Moutinho's FEUP prototype that runs plain Argo workflows, with native artifacts, on HPC compute nodes that have no network, in two ways (modes). Neither Argo nor interLink is modified in either.

- **`split`** (interLink 0.6.1): Argo's `init` and `wait` containers run on the HPC login node, and only `main` runs in the Slurm job. Three wrapper scripts replace the Slurm commands that the interLink sidecar calls.
- **`reverse`** (interLink 0.6.3): the whole pod runs in the Slurm job, and reaches the Global Storage and the Kubernetes API through the reverse tunnel of interLink's SSH shadow. One wrapper is left, for a gap in the Slurm plugin (`subPath` on emptyDirs).

One command switches between them, on the testbed (`make init-old` / `make init-new`) and on Deucalion (`make split` / `make reverse` in `deploy/deucalion`, steps in [RUN_ON_ULISSES.md](RUN_ON_ULISSES.md)). Why things are the way they are, change by change: [CHANGELOG.md](CHANGELOG.md).

## How to run

**[HOW_TO_RUN.md](HOW_TO_RUN.md)** gives the steps for both modes, first on the local testbed and then on Deucalion through Ulisses. [APPROACH.md](APPROACH.md) explains how they work, what the scripts do, and the test results.

## Important Notes
- This repository currently contains placeholder account keys only.
- Personal account key files required by the code are not present in the repository, so it is not possible to fully replicate the setup.
- The values shown in the scripts are not the real MinIO credentials and should be replaced with valid keys before running the storage setup and access.
> Later there will be variables for defining this account specific files.

## Directory Structure

- **setup/** - Infrastructure setup scripts
  - `global_storage/` - Cloud storage deployment. Contains `README.md`, `main.sh`, `cleanup.sh`, and `.env.example`
  - `hpc/` - High-Performance Computing deployment. Contains `README.md`, `main.sh`, `cleanup.sh`, and `.env.example`
    - `split-executor/` - `split`: the three wrappers (`sbatch`, `squeue`, `scancel`) and the Kubernetes API relay
    - `subpath-fix/` - `reverse`: the one wrapper still needed with interLink 0.6.3 (plugin ignores `subPath` on emptyDirs)
  - `kubernetes/` - Kubernetes cluster deployment. Contains `README.md`, `main.sh`, `cleanup.sh`, and `.env.example`
- **deploy/deucalion/** - Scripts that switch either mode on and off over the existing deployment (`hpc-side.sh`, `k8s-side.sh`)
- **tests/** - Test suites and validation
  - `datasets/` - test datasets for each workflow test
  - `workflows/` - Isabel's Argo workflow tests (sync modules and resource templates)
  - `argo-native/` - the same tests as plain Argo workflows with native artifacts, used by both modes
- **testbed/** - A small copy of Deucalion on Lima VMs; `make` at the repository root drives it
- **experiments/reverse-tunnel/** - How `reverse` was first tried on the testbed (`make init-new`), and the plugin patch to propose upstream
- **docs/img/** - Architecture diagrams

## Setup of the original prototype

### Prerequisites
- Kubernetes cluster machine access (ssh)
- HPC environment access (ssh)
- Access to cloud storage credentials

### Installation

Run the setup scripts in order:

```bash
# Global storage setup
sudo ./setup/global_storage/main.sh

# For Kubernetes
sudo ./setup/kubernetes/main.sh

# For HPC
sudo ./setup/hpc/main.sh
```
Each setup subdirectory includes its own `README.md` and a `cleanup.sh` helper.

### Testing

Run tests to validate your setup:
1. Add the files in `/tests/datasets` to the MinIO DB.
2. Run the tests in `/tests/workflows` in the Argo UI.

To test the plain Argo workflows in either mode instead, follow [HOW_TO_RUN.md](HOW_TO_RUN.md).
