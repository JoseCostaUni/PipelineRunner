# What this does differently from Isabel's solution

Same base: Kubernetes, Argo and interLink on Ulisses, the interLink Slurm sidecar on the Deucalion
login node, her MinIO as the Global Storage. Argo and interLink are not modified, and `restore`
undoes every change.

The difference: the scientist writes a plain Argo workflow, and Argo itself moves the data.

| | Isabel | `split` | `reverse` |
|---|---|---|---|
| Workflows | her sync modules and resource templates | plain Argo, native artifacts | plain Argo, native artifacts |
| Who moves the data | her wrapper `sync-data.sh` (`CommandPrefix`), with `mc`, around the job | Argo's `init` and `wait`, on the login node | Argo's `init` and `wait`, in the job, through interLink's reverse tunnel |
| What runs in the Slurm job | her wrapper and the user's container | only `main` | the whole pod |
| interLink | 0.6.1 | 0.6.1 | 0.6.3 |
| What we add | | 3 wrappers (`sbatch`, `squeue`, `scancel`) and an API relay | 1 wrapper (`sbatch`, the subPath fix) |
| Images | pulled by the job | pulled beforehand on the login node | pulled beforehand on the login node |

Details: [APPROACH.md](APPROACH.md), sections 2.1 and 7.4.
