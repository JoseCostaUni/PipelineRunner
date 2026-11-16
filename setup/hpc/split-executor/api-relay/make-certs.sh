#!/bin/bash
# CA and server certificate for the relay (split-relay login; 127.0.0.1 / localhost). The CA goes to the virtual
# kubelet (KubernetesApiCaCrt), which puts it in the pods' ca.crt, so Argo's executor trusts the relay.
set -euo pipefail
D="${1:?folder}"
mkdir -p "$D"; cd "$D"
[ -s ca.crt ] && [ -s server.crt ] && exit 0
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout ca.key -out ca.crt -subj "/CN=split-executor api relay CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=127.0.0.1" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' >ext.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 -out server.crt -extfile ext.cnf 2>/dev/null
rm -f server.csr ext.cnf ca.srl
chmod 600 ca.key server.key
