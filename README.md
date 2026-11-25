# LISA Pipeline Runner

Plain Argo workflows, with native artifacts, on HPC compute nodes that have no network. This is a fork
of Isabel Moutinho's FEUP prototype.
- **How:** it uses interLink 0.6.3, whose SSH shadow gives each offloaded pod a reverse tunnel. The
  whole pod (`init`, `main` and `wait`) runs in one Slurm job on the compute node. It reaches the
  Global Storage and the Kubernetes API back through the login node.
- **What it changes:** neither Argo nor interLink is modified. One wrapper is left, for a gap in the
  Slurm plugin (`subPath` on emptyDirs), and a patch for it is ready to propose upstream.
- **Images:** with `IMAGE_MIRROR=on`, a workflow names any image. The job pulls it from an image
  mirror in the cluster, through the same tunnel (tested on the testbed so far).
- **[docs/diagrams/](docs/diagrams/):** the deployment, one submission, the communication and the
  images, drawn.

It has run on Deucalion's `normal-x86` partition from Ulisses (24 Nov 2026).
- **[RUN_ON_ULISSES.md](RUN_ON_ULISSES.md):** the commands, in order.
- **[HOW_TO_RUN.md](HOW_TO_RUN.md):** what they do, and how to run the same on the local testbed.
- **[APPROACH.md](APPROACH.md):** how it works, the results, and the limits.
- **[CHANGELOG.md](CHANGELOG.md):** why each thing is the way it is.
- **[NEXT_STEPS.md](NEXT_STEPS.md):** where the work stands and what is left to do.

## Layout

- **`deploy/deucalion/`**: the scripts that set everything up and run the tests, as your own
  accounts (no root).
  - `k8s-side.sh` runs on Ulisses.
  - `hpc-side.sh` runs on the Deucalion login node.
  - A `Makefile` wraps both.
  - `image-mirror.yaml`: the image mirror in the cluster (`IMAGE_MIRROR=on`), so workflows can name
    any image.
- **`setup/hpc/subpath-fix/`**: the one wrapper left, the plugin's `sbatch`.
- **`tests/argo-native/`**: Isabel's tests as plain Argo workflows, with TC00 (one step with artifacts)
  and TC11 (no internet from inside a step).
  - `run.py` runs them and `checks.py` says what each must produce, in Argo and in the Global
    Storage (Python, standard library only).
  - Their data is in `tests/datasets/`.
- **`docs/diagrams/`**: how it works, drawn: deployment, submission, communication, images.
- **`testbed/`**: a small copy of Deucalion on three Lima VMs. `make` at the repository root drives
  it, and runs the same `deploy/deucalion` scripts there as a user without root.
- **`experiments/reverse-tunnel/`**:
  - the record of the first trial of interLink 0.6.3 on the testbed;
  - in `upstream/`, the plugin patch that would remove the last wrapper.

## Versions in git

| Tag | What it holds |
|---|---|
| `split-interlink-0.6.1` | The earlier approach (below), together with the reverse tunnel as a second mode: `make split` / `make reverse` on Deucalion, tests T0 and T1 on the testbed. It also holds Isabel's original setup and tests as they were copied here |
| `reverse-interlink-0.6.3` | This version: interLink 0.6.3 and the reverse tunnel only |

To look at the earlier code without leaving `main`, run `git show split-interlink-0.6.1:<path>`, or
`git worktree add ../ze-split split-interlink-0.6.1`.

## How it worked before

Until 24 Nov 2026 the default was the **split executor**, on interLink 0.6.1.
- **The split:** a pod's `init` and `wait` containers, the only ones that need the network, ran on
  the HPC login node. Only `main` ran in the Slurm job, and they coordinated through the shared file
  system.
- **Its code:** three wrappers replaced the `sbatch`, `squeue` and `scancel` the plugin calls. A relay
  let the login node reach the Kubernetes API.
- **How it compared:** it passed the same tests and was faster, about 30 s against 1.5 min for a short
  step on the testbed. But it meant maintaining four pieces of code tied to interLink 0.6.1's job
  script, and `main` had no network.

interLink 0.6.3's reverse tunnel replaced it. [APPROACH.md](APPROACH.md), section 6, compares the
two, and the code is in the tag `split-interlink-0.6.1`.

## Credentials

No real keys are in this repository.
- **Where the Global Storage keys go:** in `deploy/deucalion/deucalion.env`, which git ignores. Copy it
  from `deucalion.env.example` with `make env`.
- **What the scripts keep private:** the keys never go to the login node, and interLink's logs are
  private. `make evidence` blanks every secret in what it collects, then checks that none is left.
