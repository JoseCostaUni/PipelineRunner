# LISA Pipeline Runner

A setup and testing framework for the LISA pipeline infrastructure, supporting Kubernetes, HPC, and cloud storage configurations.

## Overview

This repository provides automated setup scripts and test utilities for deploying and validating the LISA pipeline across different infrastructure environments. It is a fork of Isabel Moutinho's FEUP prototype that adds the **split executor**: plain Argo workflows, with native artifacts, run on HPC compute nodes that have no network. Argo's `init` and `wait` containers run on the HPC login node, and only `main` runs in the Slurm job. Three wrapper scripts replace the Slurm commands that the interLink sidecar calls, so neither Argo nor interLink is modified.

## How to run

**[HOW_TO_RUN.md](HOW_TO_RUN.md)** gives the steps to run the split executor, first on the local testbed and then on Deucalion through Ulisses. [APPROACH.md](APPROACH.md) explains how it works, what the three scripts do, and the test results.

## Important Notes
- This repository currently contains placeholder account keys only.
- Personal account key files required by the code are not present in the repository, so it is not possible to fully replicate the setup.
- The values shown in the scripts are not the real MinIO credentials and should be replaced with valid keys before running the storage setup and access.
> Later there will be variables for defining this account specific files.

## Directory Structure

- **setup/** - Infrastructure setup scripts
  - `global_storage/` - Cloud storage deployment. Contains `README.md`, `main.sh`, `cleanup.sh`, and `.env.example`
  - `hpc/` - High-Performance Computing deployment. Contains `README.md`, `main.sh`, `cleanup.sh`, and `.env.example`
    - `split-executor/` - The three wrappers (`sbatch`, `squeue`, `scancel`) and the Kubernetes API relay
  - `kubernetes/` - Kubernetes cluster deployment. Contains `README.md`, `main.sh`, `cleanup.sh`, and `.env.example`
- **deploy/deucalion/** - Scripts that switch the split executor on and off over the existing deployment (`hpc-side.sh`, `k8s-side.sh`)
- **tests/** - Test suites and validation
  - `datasets/` - test datasets for each workflow test
  - `workflows/` - Isabel's Argo workflow tests (sync modules and resource templates)
  - `argo-native/` - the same tests as plain Argo workflows with native artifacts, used with the split executor
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

To test the split executor instead, follow [HOW_TO_RUN.md](HOW_TO_RUN.md).
