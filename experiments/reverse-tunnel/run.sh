#!/bin/bash
# Reverse-tunnel experiment: plain Argo workflows on the testbed's offline compute node with
# interLink 0.6.3 and the reverse tunnel of its ssh shadow, instead of the split executor.
# Runs on the Mac, against the testbed's VMs (Stage B must be up: make vm-build-ulisses).
# See README.md in this folder.
#
#   ./run.sh install          interLink 0.6.3 on ulisses, plugin 0.6.3 + subPath fix on login
#   ./run.sh enable           switch to 0.6.3 and the reverse tunnel (both sides)
#   ./run.sh test [NN ...]    the plain-Argo tests (default: all), compute node offline
#   ./run.sh version          which interLink is active on ulisses (0.6.3 or 0.6.1)
#   ./run.sh diag             shadow pods, logs, sidecar settings
#   ./run.sh disable          back to Isabel's 0.6.1 and her settings
#
# Environment: TESTBED_DIR (default: found by walking up from here), IL_VERSION (default 0.6.3),
# RT_TESTS="00 05" (same as listing tests).
# Written for the macOS system bash (3.2).
set -eo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZE="$(cd "$HERE/../.." && pwd)"
IL_VERSION="${IL_VERSION:-0.6.3}"

find_testbed() {
  local d="$HERE" i=0
  while [ $i -lt 10 ] && [ "$d" != / ]; do
    [ -x "$d/testbed/testbed" ] && { echo "$d/testbed"; return; }
    [ -x "$d/repositories/testbed/testbed" ] && { echo "$d/repositories/testbed"; return; }
    d="$(dirname "$d")"; i=$((i + 1))
  done
}
TESTBED_DIR="${TESTBED_DIR:-$(find_testbed)}"
[ -n "$TESTBED_DIR" ] && [ -x "$TESTBED_DIR/testbed" ] || { echo "testbed not found: set TESTBED_DIR" >&2; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HERE/results/$TS"

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
vm() { echo "tb-$1"; }
vsh() { local v; v="$(vm "$1")"; shift; limactl shell --workdir / "$v" "$@" </dev/null; }
vroot() { local n="$1"; shift; vsh "$n" sudo bash "/opt/testbed/guest/$1" "${@:2}"; }   # testbed scripts
rt() { local n="$1"; shift; vsh "$n" sudo env IL_VERSION="$IL_VERSION" bash "/opt/rt/guest/$1" "${@:2}"; }   # ours
running() { [ "$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$(vm "$1")" '$1==n {print $2}')" = Running ]; }
step() { # name cmd...: output to the log, last lines on failure
  local name="$1"; shift
  mkdir -p "$OUT"; info "$name"
  if ! ( "$@" ) >>"$OUT/run.log" 2>&1 </dev/null; then
    tail -n 25 "$OUT/run.log" >&2; die "step '$name' failed (log: $OUT/run.log)"
  fi
}

# Copy this experiment and the tests into the VMs (/opt/rt; tests also where the testbed's T1
# runner reads them).
sync_rt() {
  local n v
  for n in cn login ulisses; do
    v="$(vm "$n")"
    vsh "$n" rm -rf /tmp/rt-sync; vsh "$n" mkdir -p /tmp/rt-sync
    limactl copy -r "$HERE/guest" "$ZE/setup/hpc/subpath-fix" "$v:/tmp/rt-sync/"
    vsh "$n" sudo rm -rf /opt/rt; vsh "$n" sudo cp -r /tmp/rt-sync /opt/rt; vsh "$n" sudo chmod -R a+rX /opt/rt
    vsh "$n" rm -rf /tmp/rt-sync
  done
  vsh ulisses rm -rf /tmp/rt-tests; limactl copy -r "$ZE/tests/argo-native" "$(vm ulisses):/tmp/rt-tests"
  vsh ulisses sudo mkdir -p /opt/testbed/ze; vsh ulisses sudo rm -rf /opt/testbed/ze/argo-native
  vsh ulisses sudo cp -r /tmp/rt-tests /opt/testbed/ze/argo-native; vsh ulisses sudo chmod -R a+rX /opt/testbed/ze
}

preflight() {
  command -v limactl >/dev/null || die "limactl not found"
  local n; for n in cn login ulisses; do running "$n" || die "VM $(vm "$n") is not running (cd $TESTBED_DIR && make vm-start)"; done
  vsh ulisses test -f /opt/testbed/guest/t1-ulisses.sh || die "testbed scripts missing in the VMs: cd $TESTBED_DIR && make vm-start"
  sync_rt
}

# Which interLink the virtual kubelet on ulisses runs: $IL_VERSION (ours) or 0.6.1 (Isabel's).
active_version() {
  case "$(vsh ulisses sudo systemctl show -p ExecStart interlink-vk 2>/dev/null)" in
    *"/opt/interlink-$IL_VERSION/"*) echo "$IL_VERSION";; *) echo 0.6.1;; esac
}

restore_test() {
  vroot ulisses t1-ulisses.sh offload off >/dev/null 2>&1 || true
  rt ulisses ulisses.sh offload off >/dev/null 2>&1 || true
  vroot login t0-login.sh set-prefix docker >/dev/null 2>&1 || true
  [ -n "${NET0:-}" ] && vroot cn netmode.sh "$NET0" >/dev/null 2>&1 || true
}

cmd="${1:-}"; shift || true
case "$cmd" in
  install)
    preflight
    step "cn: what the reverse tunnel needs" rt cn cn.sh check
    step "ulisses: interLink $IL_VERSION and the shadow image (first time: Go build, ~10 min)" rt ulisses ulisses.sh install
    step "login: Slurm plugin $IL_VERSION and the subPath fix" rt login login.sh install
    info "installed; next: ./run.sh enable"
    ;;
  enable)
    preflight
    # Login node first: the virtual node on ulisses only becomes Ready when the plugin answers.
    step "login: plugin $IL_VERSION" rt login login.sh use new norestart
    step "login: SocketDirRoot, subPath fix, no data wrapper (restarts the plugin)" rt login login.sh config on
    step "ulisses: interLink $IL_VERSION" rt ulisses ulisses.sh use new
    step "ulisses: ssh shadow with reverse tunnel" rt ulisses ulisses.sh reverse on
    info "enabled; next: ./run.sh test 00"
    ;;
  test)
    preflight
    [ "$(active_version)" = "$IL_VERSION" ] \
      || die "interLink $IL_VERSION is not the one running on ulisses: run ./run.sh enable first (or make init-new)"
    tests="$*"; [ -n "$tests" ] || tests="${RT_TESTS:-00 01 02 03 04 05 06 07 09 10}"
    mkdir -p "$OUT"
    NET0="$(vroot cn netmode.sh get)"
    trap restore_test EXIT
    vroot login loginnet.sh apply >/dev/null
    vroot cn netmode.sh normal >/dev/null
    info "run $TS: tests $tests, compute node offline, login node cannot reach ulisses"
    step "Argo artifact repository, test modules" vroot ulisses t1-ulisses.sh setup
    step "artifact repository endpoint through the tunnel" rt ulisses ulisses.sh artifacts
    exec_img="$(vroot ulisses t1-ulisses.sh executor-image | tail -n 1)"
    step "images pulled on the login node ($exec_img)" vroot login t1-login.sh prepare-images "$exec_img"
    step "ImagePrefix -> pulled images" vroot login t0-login.sh set-prefix images
    step "offload with reverse-forwards" rt ulisses ulisses.sh offload on
    step "Global Storage test data" vroot ulisses t1-ulisses.sh reset-data
    for t in $tests; do
      line="$(vroot ulisses t1-ulisses.sh run "$TS" rt "$t" 2>>"$OUT/run.log" | tail -n 1)"
      [ -n "$line" ] || line="no result (see run.log)"
      echo "   TC$t  $line" | tee -a "$OUT/summary.txt"
      uids="$(vroot ulisses t1-ulisses.sh pods "$TS" rt "$t" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
      # shellcheck disable=SC2086
      [ -n "$uids" ] && vroot login t1-login.sh collect-test "$TS" "rt/TC$t" $uids >>"$OUT/run.log" 2>&1 || true
      case "$line" in PASS*) ;; *) rt ulisses ulisses.sh diag >"$OUT/diag-TC$t.txt" 2>&1 || true;; esac
      vroot ulisses t1-ulisses.sh delete "$TS" rt "$t" >>"$OUT/run.log" 2>&1 || true
      vroot login clean.sh slurm >>"$OUT/run.log" 2>&1 || true
    done
    restore_test; trap - EXIT
    vroot ulisses t1-ulisses.sh pack "$TS" >>"$OUT/run.log" 2>&1 || true
    vroot login t1-login.sh pack "$TS" >>"$OUT/run.log" 2>&1 || true
    limactl copy "$(vm ulisses):/var/tmp/t1-argo-$TS.tar.gz" "$OUT/" 2>/dev/null || true
    limactl copy "$(vm login):/var/tmp/t1-jobs-$TS.tar.gz" "$OUT/" 2>/dev/null || true
    ( cd "$OUT" && mkdir -p argo jobs && { tar xzf "t1-argo-$TS.tar.gz" -C argo 2>/dev/null || true; } \
      && { tar xzf "t1-jobs-$TS.tar.gz" -C jobs 2>/dev/null || true; } && rm -f ./*.tar.gz )
    info "summary: $OUT/summary.txt (Argo objects in argo/, job folders in jobs/)"
    ;;
  version)
    running ulisses || die "VM $(vm ulisses) is not running"
    active_version
    ;;
  diag)
    preflight
    rt ulisses ulisses.sh diag
    echo "== login"; rt login login.sh status
    ;;
  disable)
    preflight
    step "login: Isabel's SlurmConfig.yaml" rt login login.sh config off
    step "login: plugin 0.6.1" rt login login.sh use 0.6.1
    step "ulisses: reverse tunnel off" rt ulisses ulisses.sh reverse off
    step "ulisses: interLink 0.6.1" rt ulisses ulisses.sh use 0.6.1
    info "back to Isabel's 0.6.1 setup"
    ;;
  *) sed -n '2,17p' "$0"; exit 2;;
esac
