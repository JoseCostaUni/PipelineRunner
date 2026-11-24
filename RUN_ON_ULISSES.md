# Run on Ulisses

The commands, in order. Everything runs as your own users:
- `jcosta` on Ulisses, with no sudo and Isabel's cluster-admin kubeconfig;
- `jcosta.up` on Deucalion.

What each step does and what it changes: [deploy/deucalion/README.md](deploy/deucalion/README.md).
Why it works this way: [CHANGELOG.md](CHANGELOG.md).

## 0. Before you start

- **Kubernetes:** on Ulisses, `kubectl get nodes` lists the node `ulisses`.
- **Deucalion from Ulisses:** `ssh -i ~/.ssh/id_ed25519 jcosta.up@ln01.deucalion.macc.fccn.pt hostname`
  works. New keys can take hours to be accepted.
- **Global Storage:** `GS_ENDPOINT=cluster` runs a MinIO of ours inside the cluster. Choose its keys
  yourself: `GS_ACCESS_KEY=lisa`, `GS_SECRET_KEY=$(openssl rand -hex 16)`. Isabel's MinIO also works,
  if it answers (it was down on 23 Nov 2026).
- **A folder on Deucalion** for `HPC_PROJECT_ROOT`, at most 59 characters: `/home/jcosta.up/lisa`.
  `/projects` was full in Nov 2026. The folder is private, which matters because job folders hold the
  MinIO keys and service-account tokens while a pod runs.
- **Gustavo:** the cluster is shared. `make setup` installs Argo in namespace `argo` if it isn't
  there yet. While offload is on (`make up` until `make down`), every workflow of that Argo goes to
  your virtual node.

## 1. Mac (FEUP VPN on)

`~/.ssh/config`:

```
Host ulisses
    HostName 10.227.63.27
    User jcosta
    IdentityFile ~/.ssh/id_ed25519_work_key
```

Push your changes first, then:

```sh
ssh ulisses
```

## 2. Ulisses: code and settings

```sh
screen -S trial                   # detach: Ctrl+A then D; back: ssh ulisses, screen -R trial
cd ~/PipelineRunner && git pull
cd deploy/deucalion
make env && vi deucalion.env      # HPC_PROJECT_ROOT, GS_ENDPOINT, GS_ACCESS_KEY, GS_SECRET_KEY; check the rest
```

A `deucalion.env` from before 24 Nov still works: the split settings in it are ignored.

## 3. Set up and check (once)

```sh
make setup      # Argo if missing, the MinIO, argo + mc, interLink 0.6.3, the sidecar on the login node
make check      # Ulisses, login node, one compute node; output kept in results/
```

Fix every `FAIL` first. After editing `deucalion.env` or pulling new code, run `make sync`.

## 4. Run

```sh
make up                         # if a step fails: fix it, run it again
make test T=00
make test                       # all; Ctrl-C stops it
make evidence                   # versions, configuration, logs, Slurm's record of the last run
```

## 5. Put everything back

```sh
make restore                    # ends with: Ulisses: off, sidecar lisa-sidecar: inactive
make minio-off                  # only with GS_ENDPOINT=cluster, when the data is no longer needed
```

## 6. Take the results home

```sh
make results                                          # on Ulisses: ~/results.tgz
scp ulisses:results.tgz ~/Documents/Dissertation/     # on the Mac
```

## If something fails

- Run `make status` and `make diag`.
- interLink's logs are in `~/lisa-trial/log/`: `il-vk.log`, `il-api.log` and `il-tunnel.log`.
- `make login` opens a shell on the login node, in the repository's folder there. The job folders are
  in `$HPC_PROJECT_ROOT/.interlink/jobs/`.
- interLink runs as your own processes, not as services. After Ulisses reboots, run `make up` again.
- More in [HOW_TO_RUN.md](HOW_TO_RUN.md), section 3.
