# Run on Ulisses

The commands, in order. What each one does: [HOW_TO_RUN.md](HOW_TO_RUN.md), section 2. Every
`make` target is listed at the top of `deploy/deucalion/Makefile`.

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
ssh ulisses
```

## 2. Ulisses: set up and check

```sh
screen -S trial                 # detach: Ctrl+A then D; back: ssh ulisses, screen -R trial
sudo -i                         # the scripts run as root
tar -xzf ~jcosta/lpr.tgz -C /opt
cd /opt/lisa-pipeline-runner_ze/deploy/deucalion
make env && vi deucalion.env    # GS_ACCESS_KEY, GS_SECRET_KEY (Isabel's MinIO keys)
make tools                      # argo and mc, only if missing
make sync                       # copy to the login node; prints: none
make check                      # Ulisses, login node, one compute node; kept in results/
```

Fix every `FAIL` first. After editing `deucalion.env`, run `make sync` again.

- Skip `reverse` if `make check` prints `python3: NOT found`, `sshd: NOT found` or `srun --overlap ... FAILED`.
- Skip `split` if it prints `Global Storage ... not reachable from here`.

## 3. `reverse`

```sh
make reverse                    # builds interLink 0.6.3 the first time (a few minutes)
make test T=00
make test
```

If a step of `make reverse` fails, fix it and run it again.

## 4. `split`

```sh
make clean split
make test T=00
make test
```

## 5. Put everything back

```sh
make restore                    # ends with both sides: none
```

## 6. Take the results home

```sh
make results                    # on Ulisses: results.tgz in your home
scp ulisses:results.tgz ~/Documents/Dissertation/     # on the Mac
```

## If a test fails

`results/<time>-<mode>/summary.txt`, `make diag` in `reverse`, and `make login` for a shell on the
login node (the job folders). More in [HOW_TO_RUN.md](HOW_TO_RUN.md), section 3.
