#!/bin/bash
# Run as root on tb-ulisses: a user like 'jcosta' on Ulisses, to rehearse the runner's setup there.
# No sudo, a kubeconfig with cluster-admin through a ServiceAccount token (as Isabel set up Ulisses),
# its own copy of kubectl (the testbed's /usr/bin/kubectl is for root only) and an SSH key. Prints the
# public key, to be added to lisa's authorized_keys on tb-login. Usage: trial-user.sh [user]
set -euo pipefail
U="${1:-jcosta}"
H="/home/$U"
export KUBECONFIG=/etc/kubernetes/admin.conf
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
kubectl -n default get sa "$U" >/dev/null 2>&1 || kubectl -n default create serviceaccount "$U" >/dev/null
kubectl get clusterrolebinding "$U" >/dev/null 2>&1 || kubectl create clusterrolebinding "$U" --clusterrole=cluster-admin --serviceaccount="default:$U" >/dev/null
kubectl -n default apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $U-token
  annotations:
    kubernetes.io/service-account.name: $U
type: kubernetes.io/service-account-token
YAML
t=""
for _ in $(seq 1 20); do t="$(kubectl -n default get secret "$U-token" -o jsonpath='{.data.token}' | base64 -d)"; [ -n "$t" ] && break; sleep 1; done
install -d -o "$U" -g "$U" -m 700 "$H/.kube" "$H/.ssh"
install -d -o "$U" -g "$U" "$H/lisa-trial" "$H/lisa-trial/bin"
install -o "$U" -g "$U" -m 755 /usr/bin/kubectl "$H/lisa-trial/bin/kubectl"
K="kubectl config --kubeconfig $H/.kube/config"
$K set-cluster tb --server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true >/dev/null
$K set-credentials "$U" --token="$t" >/dev/null
$K set-context tb --cluster=tb --user="$U" >/dev/null
$K use-context tb >/dev/null
chown "$U:$U" "$H/.kube/config"; chmod 600 "$H/.kube/config"
[ -f "$H/.ssh/id_ed25519" ] || sudo -u "$U" ssh-keygen -q -t ed25519 -N "" -f "$H/.ssh/id_ed25519" -C "$U@tb-ulisses"
cat "$H/.ssh/id_ed25519.pub"
