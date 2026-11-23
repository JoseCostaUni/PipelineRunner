# Run on Ulisses

The commands, in order. Everything runs as your own users: `jcosta` on Ulisses (no sudo; Isabel's
cluster-admin kubeconfig) and `jcosta.up` on Deucalion. What each step does and what it changes:
[deploy/deucalion/README.md](deploy/deucalion/README.md). Why it works this way:
[CHANGELOG.md](CHANGELOG.md).

## 0. Before you start

- **Kubernetes:** on Ulisses, `kubectl get nodes` lists the node `ulisses`.
- **Deucalion from Ulisses:** `ssh -i ~/.ssh/id_ed25519 jcosta.up@ln01.deucalion.macc.fccn.pt hostname`
  works. New keys can take hours to be accepted.
- **Global Storage:** Isabel's MinIO keys, for `GS_ACCESS_KEY` and `GS_SECRET_KEY`.
- **A folder on Deucalion** for `HPC_PROJECT_ROOT`, at most 59 characters. Isabel suggests the
  HPCvLAB shared folder. Job folders hold the MinIO keys and service-account tokens while a pod
  runs, so whoever can read that folder can read them.
- **Gustavo:** the cluster is shared. `make setup` installs Argo in namespace `argo` if it isn't
  there yet. While offload is on, every workflow of that Argo goes to your virtual node.

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
mv deucalion.env deucalion.env.old 2>/dev/null   # only if you have one from before 23 Nov
make env && vi deucalion.env      # HPC_PROJECT_ROOT, GS_ACCESS_KEY, GS_SECRET_KEY; check the rest
```

## 3. Set up and check (once)

```sh
make setup      # Argo if missing, argo + mc, interLink 0.6.1 and 0.6.3 (build: a few minutes),
                # this repository and the sidecar on the login node
make check      # Ulisses, login node, one compute node; output kept in results/
```

Fix every `FAIL` first. After editing `deucalion.env`, run `make sync`.

- Skip `reverse` if `make check` prints `python3: NOT found`, `sshd: NOT found` or
  `srun --overlap ... FAILED`.
- Skip `split` if it prints `Global Storage ... not reachable from here`.

## 4. `reverse`

```sh
make reverse                    # if a step fails: fix it, run it again
make test T=00
make test
```

## 5. `split`

```sh
make clean split
make test T=00
make test
```

## 6. Put everything back

```sh
make restore                    # ends with both sides: none
```

## 7. Take the results home

```sh
make results                                          # on Ulisses: ~/results.tgz
scp ulisses:results.tgz ~/Documents/Dissertation/     # on the Mac
```

## If something fails

- `make status` and `make diag`.
- interLink's logs are in `~/lisa-trial/log/` (`il-vk.log`, `il-api.log`, `il-tunnel.log`).
- `make login` opens a shell on the login node, in the repository's folder there. The job folders
  are in `$HPC_PROJECT_ROOT/.interlink/jobs/`.
- interLink runs as your own processes, not as services. After Ulisses reboots, run
  `make reverse` or `make split` again.
- More in [HOW_TO_RUN.md](HOW_TO_RUN.md), section 3.
