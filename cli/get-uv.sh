#!/bin/bash
# Fetch uv (the Python tool that runs lisa with its pinned dependencies) into a folder of yours, without
# root, checked against the release's published SHA-256. Called by the Makefile when uv is missing.
# Usage: get-uv.sh <folder> <version>
set -euo pipefail
dest="$1"; version="$2"
case "$(uname -m)" in aarch64|arm64) arch=aarch64;; *) arch=x86_64;; esac
asset="uv-$arch-unknown-linux-gnu.tar.gz"
url="https://github.com/astral-sh/uv/releases/download/$version/$asset"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "fetching uv $version into $dest"
curl -fsSL --retry 3 -o "$tmp/$asset" "$url"
curl -fsSL --retry 3 -o "$tmp/$asset.sha256" "$url.sha256"
(cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null) || { echo "uv: checksum mismatch" >&2; exit 1; }
tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$dest"
install -m 0755 "$tmp/uv-$arch-unknown-linux-gnu/uv" "$dest/uv"
