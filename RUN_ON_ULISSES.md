# Run on Ulisses

The commands, in order. What each one does: [HOW_TO_RUN.md](HOW_TO_RUN.md), section 2.

## 1. Mac (FEUP VPN on)

Add to `~/.ssh/config`:

```
Host ulisses
    HostName 10.227.63.27
    User jcosta
    IdentityFile ~/.ssh/id_ed25519_work_key
```

```sh
cd ~/Documents/Dissertation/repositories/lisa-pipeline-runner_ze
git archive --prefix=lisa-pipeline-runner_ze/ -o ~/lpr.tgz HEAD   # what is committed
scp ~/lpr.tgz ulisses:
ssh ulisses                     # the first login may ask you to set a password
```

## 2. Ulisses: set up

```sh
screen -S trial                 # detach: Ctrl+A then D; back: ssh ulisses, screen -R trial
sudo -i                         # k8s-side.sh runs as root
tar -xzf ~jcosta/lpr.tgz -C /opt
cd /opt/lisa-pipeline-runner_ze/deploy/deucalion
cp deucalion.env.example deucalion.env && chmod 600 deucalion.env
vi deucalion.env                # GS_ACCESS_KEY, GS_SECRET_KEY (Isabel's MinIO keys)
source deucalion.env
scp -i "$SSH_KEY" -r /opt/lisa-pipeline-runner_ze "$HPC_USER@$HPC_LOGIN_HOST:$HPC_PROJECT_ROOT/"
```

## 3. Checks

```sh
mkdir -p results && ./k8s-side.sh check | tee results/check-k8s.txt
ssh -i "$SSH_KEY" "$HPC_USER@$HPC_LOGIN_HOST"
```

On the login node:

```sh
cd /projects/EEHPC-DEV-2026D02-075/lisa-pipeline-runner/lisa-pipeline-runner_ze/deploy/deucalion
./hpc-side.sh check | tee check-hpc.txt
./hpc-side.sh probe-compute | tee probe-compute.txt
exit
```

Fix every `FAIL` first. After editing `deucalion.env`, copy it again:

```sh
scp -i "$SSH_KEY" deucalion.env "$HPC_USER@$HPC_LOGIN_HOST:$HPC_REPO_DIR/deploy/deucalion/" && source deucalion.env
```

- Skip `reverse` if `probe-compute` prints `python3: NOT found`, `sshd: NOT found` or `srun --overlap ... FAILED`.
- Skip `split` if `hpc-side.sh check` prints `Global Storage ... not reachable from here`.

## 4. `reverse`

```sh
./k8s-side.sh install           # once, a few minutes: builds interLink 0.6.3
./k8s-side.sh mode reverse      # if a step fails: fix it, run the same command again
./k8s-side.sh test 00
./k8s-side.sh test
```

## 5. `split`

```sh
./k8s-side.sh clean
./k8s-side.sh mode split
./k8s-side.sh test 00
./k8s-side.sh test
```

## 6. Put everything back

```sh
./k8s-side.sh clean
./k8s-side.sh restore
./k8s-side.sh status            # both sides: none
```

## 7. Take the results home

On Ulisses:

```sh
scp -i "$SSH_KEY" "$HPC_USER@$HPC_LOGIN_HOST:$HPC_REPO_DIR/deploy/deucalion/*.txt" results/
tar -czf ~jcosta/results.tgz results && chown jcosta ~jcosta/results.tgz
```

On the Mac:

```sh
scp ulisses:results.tgz ~/Documents/Dissertation/
```

## If a test fails

`results/<time>-<mode>/summary.txt`, then `./k8s-side.sh diag` in `reverse`. More in
[HOW_TO_RUN.md](HOW_TO_RUN.md), section 3.
