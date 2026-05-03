#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <dst-dir> <egos-url> <xv6-url>" >&2
  exit 1
fi

DST_DIR="$1"
EGOS_URL="$2"
XV6_URL="$3"

mkdir -p "$DST_DIR"

clone_or_update() {
  local url="$1"
  local dst="$2"
  if [[ -d "$dst/.git" ]]; then
    echo "[tinyos] update: $dst"
    git -C "$dst" fetch --all --tags --prune
    git -C "$dst" pull --ff-only
  elif [[ -e "$dst" ]]; then
    echo "[tinyos] skip: $dst exists but is not a git repo"
  else
    echo "[tinyos] clone: $url -> $dst"
    git clone "$url" "$dst"
  fi
}

clone_or_update "$EGOS_URL" "$DST_DIR/egos-2000"
clone_or_update "$XV6_URL" "$DST_DIR/xv6-riscv"

echo "[tinyos] source trees ready under: $DST_DIR"
