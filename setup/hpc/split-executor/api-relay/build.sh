#!/bin/sh
# Rebuilds bin/split-relay-linux-{amd64,arm64} from src/ (Go 1.21+, standard library only).
# Static binaries (CGO off): nothing to install on the login node.
set -eu
cd "$(dirname "$0")/src"
for a in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH=$a go build -trimpath -ldflags "-s -w" -o ../bin/split-relay-linux-$a .
done
ls -l ../bin
